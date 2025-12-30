"""TOML decoder implementation for Starlark."""

load("@re.bzl", "re")

# --- Constants for Tokenization ---
_BARE_KEY_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
_VALID_ASCII_CHARS = "\n\t !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
_TOML_ESCAPES = {
    "b": "\b",
    "t": "\t",
    "n": "\n",
    "f": "\f",
    "r": "\r",
    "\\": "\\",
    '"': '"',
    "e": "\033",
}

# --- Regex Patterns for Scalars ---
_RE_SCALAR = re.compile(
    r"""
    (?P<datetime>
        (?P<dt_year>\d{4})-(?P<dt_month>\d{2})-(?P<dt_day>\d{2})  # Date
        (?:
            (?P<dt_tsep>[Tt ])                                    # Separator
            (?P<dt_hour>\d{2}):(?P<dt_minute>\d{2})               # Time
            (?::(?P<dt_second>\d{2})(?:\.(?P<dt_frac>\d+))?)?     # Optional seconds/frac
        )?
        (?P<dt_offset>[Zz]|[+-]\d{2}:\d{2})?                      # Optional offset
    )|
    (?P<time>
        (?P<tm_hour>\d{2}):(?P<tm_minute>\d{2})                   # Time
        (?::(?P<tm_second>\d{2})(?:\.(?P<tm_frac>\d+))?)?         # Optional seconds/frac
    )|
    (?P<hex>0x[0-9a-fA-F_]+)|
    (?P<oct>0o[0-7_]+)|
    (?P<bin>0b[01_]+)|
    (?P<boolean>true|false)|
    (?P<inf_nan>[+-]?(?:inf|nan))|
    (?P<number>
        [+-]?(?:0|[1-9](?:_?\d)*)         # Integer part
        (?:\.(?:\d(?:_?\d)*))?            # Optional fraction
        (?:[eE][+-]?(?:\d(?:_?\d)*))?     # Optional exponent
    )
    """,
    re.VERBOSE,
)

# Multiplier applied to input length to set a safe upper bound for loops
# that substitute for 'while' (which Starlark does not support).
_MAX_ITERATIONS_MULTIPLIER = 2

# The Unicode replacement character (U+FFFD). Used to detect invalid UTF-8
# that may have been automatically replaced by the Starlark loader.
_REPLACEMENT_CHAR = json.decode('"\\uFFFD"')

# --- Status & Error Handling ---

def _errors():
    """Creates a basic error collection structure."""
    errors = []

    def add(msg):
        errors.append(msg)

    def get():
        return errors

    return struct(add = add, get = get)

def _parser(data, default, datetime_formatter, max_depth, expand_values):
    """Initializes the parser state structure."""
    root_dict = {}
    return {
        "pos": 0,
        "len": len(data),
        "data": data,
        "root": root_dict,
        "current_table": root_dict,
        "current_path": [],
        "errors": _errors(),
        "error": None,
        "is_safe": False,
        "has_default": default != None,
        "path_types": {(): "table"},
        "explicit_paths": {(): True},
        "header_paths": {},
        "datetime_formatter": datetime_formatter,
        "max_depth": max_depth,
        "expand_values": expand_values,
    }

def _fail(state, msg):
    """Reports a parsing error and fails the build unless a default is provided."""
    if state["error"] == None:
        state["error"] = msg

    if not state["has_default"]:
        fail(msg)

def _skip_ws(state, skip_nl = False):
    """Skips whitespace and comments in the input stream."""
    pos = state["pos"]
    length = state["len"]
    if pos >= length:
        return
    data = state["data"]
    skip_chars = " \t\n" if skip_nl else " \t"

    # HYPER-FAST PATH: Skip a single whitespace char
    char = data[pos]
    if char in skip_chars:
        pos += 1
        if pos < length:
            nc = data[pos]
            if nc not in skip_chars and nc != "#":
                state["pos"] = pos
                return
        else:
            state["pos"] = pos
            return
    elif char != "#":
        return

    # SLOW PATH: Multiple spaces, tabs, or comments
    state["pos"] = pos
    for _ in range(length):
        pos = state["pos"]
        if pos >= length:
            break

        char = data[pos]
        if char in skip_chars:
            # Use small window lstrip to skip contiguous whitespace blocks
            chunk = data[pos:pos + 256]
            state["pos"] += len(chunk) - len(chunk.lstrip(skip_chars))
            continue

        if char == "#":
            newline_pos = data.find("\n", pos)
            comment_end = newline_pos if newline_pos != -1 else length
            comment_text = data[pos:comment_end]
            if not _validate_text(state, comment_text, "comment", allow_nl = False):
                return
            state["pos"] = comment_end
            continue
        break

def _expect(state, char):
    """Asserts that the next character in the stream is `char` and consumes it."""
    if state["error"] != None:
        return
    if state["pos"] >= state["len"] or state["data"][state["pos"]] != char:
        _fail(state, "Expected '%s' at %d" % (char, state["pos"]))
        return
    state["pos"] += 1

# --- Types & Validation ---

def _is_dict(value):
    """Returns True if the value is a dictionary."""
    return type(value) == "dict"

# buildifier: disable=list-append
def _validate_text(state, text, context, allow_nl = False):
    """Validates that text contains only valid TOML characters and UTF-8."""

    # GLOBAL FAST PATH: If the whole document was pre-validated as safe.
    if state["is_safe"]:
        if not allow_nl and "\n" in text:
            _fail(state, "Control char in %s" % context)
            return False
        return True

    # FAST PATH: Check if string is pure valid ASCII
    # We include NL in common set as it's very common and safe to check once up front.
    if not text.lstrip(_VALID_ASCII_CHARS):
        return True

    # SLOW PATH: Robust byte-level validation.
    length = len(text)
    idx = 0
    for _ in range(length):
        if idx >= length:
            return True
        char = text[idx]

        byte_len = 0
        if char <= "\177":
            byte_len = 1
            if char == "\r":
                msg = "Bare CR in %s" % context if allow_nl else "Control char in %s" % context
                _fail(state, msg)
                return False
            elif (char < " " and char != "\t" and char != "\n") or char == "\177":
                _fail(state, "Control char in %s" % context)
                return False
        elif char >= "\302" and char <= "\337":
            byte_len = 2
        elif char >= "\340" and char <= "\357":
            byte_len = 3
            if char == "\355" and idx + 1 < length:
                next_char = text[idx + 1]
                if next_char >= "\240" and next_char <= "\277":
                    _fail(state, "Surrogate in %s" % context)
                    return False
        elif char >= "\360" and char <= "\364":
            byte_len = 4
        elif char == _REPLACEMENT_CHAR:
            # If Bazel's loader replaced invalid bytes with U+FFFD, fail.
            _fail(state, "Invalid UTF-8 in %s" % context)
            return False
        else:
            _fail(state, "Invalid UTF-8 in %s" % context)
            return False

        if byte_len > 1:
            for j in range(1, byte_len):
                if idx + j >= length or not (text[idx + j] >= "\200" and text[idx + j] <= "\277"):
                    _fail(state, "Truncated UTF-8 in %s" % context)
                    return False
        idx += byte_len

    return True

def _is_hex(hex_str):
    """Returns True if the string is a valid hexadecimal sequence."""
    return not hex_str.lstrip("0123456789abcdefABCDEF")

def _to_hex(val, width):
    """Formats an integer as a zero-padded hexadecimal string."""
    s = "%x" % val
    return ("0" * (width - len(s))) + s if len(s) < width else s

def _pad_num(n, width):
    """Pads an integer with leading zeros."""
    s = str(n)
    return "0" * (width - len(s)) + s if len(s) < width else s

def _codepoint_to_string(code):
    """Converts a Unicode codepoint to a Starlark string."""
    if code <= 0xFFFF:
        return json.decode('"\\u' + _to_hex(code, 4) + '"')
    v = code - 0x10000
    hi = 0xD800 + (v // 1024)
    lo = 0xDC00 + (v % 1024)
    return json.decode('"\\u' + _to_hex(hi, 4) + "\\u" + _to_hex(lo, 4) + '"')

def _is_leap(year):
    """Returns True if the year is a leap year."""
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)

def _get_days_in_month(month, year):
    """Returns the number of days in a given month and year."""
    if month in [1, 3, 5, 7, 8, 10, 12]:
        return 31
    if month in [4, 6, 9, 11]:
        return 30
    if month == 2:
        return 29 if _is_leap(year) else 28
    return 0

def _validate_date(state, year, month, day):
    """Validates that the given date components form a valid calendar date."""
    if year < 0 or year > 9999 or month < 1 or month > 12 or day < 1 or day > _get_days_in_month(month, year):
        _fail(state, "Invalid date: %d-%d-%d" % (year, month, day))
        return False
    return True

def _validate_time(state, hour, minute, second):
    """Validates that the given time components form a valid wall clock time."""
    if hour < 0 or hour > 23 or minute < 0 or minute > 59 or (second < 0 or second > 60):
        _fail(state, "Invalid time: %d:%d:%d" % (hour, minute, second))
        return False
    return True

def _validate_offset(state, hour, minute):
    """Validates that the given hour/minute offset is within allowed bounds."""
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        _fail(state, "Invalid offset: %d:%d" % (hour, minute))
        return False
    return True

# --- String Parsing ---

def _escape_char(char):
    """Returns the literal character for a standard TOML escape sequence."""
    return _TOML_ESCAPES.get(char)

# buildifier: disable=list-append
def _parse_basic_string(state):
    """Parses a basic string (double quoted)."""
    if state["pos"] >= state["len"] or state["data"][state["pos"]] != '"':
        _fail(state, "Expected '\"' at %d" % state["pos"])
        return ""
    state["pos"] += 1

    if state["error"] != None:
        return ""

    data = state["data"]
    length = state["len"]
    pos = state["pos"]

    # Optimized search for next quote
    quote_idx = data.find('"', pos)
    if quote_idx == -1:
        _fail(state, "Unterminated string")
        return ""

    # Bounded search for first escape
    escape_idx = data.find("\\", pos, quote_idx)

    # FAST PATH: No escapes in the string
    if escape_idx == -1:
        chunk = data[pos:quote_idx]
        if not _validate_text(state, chunk, "string", allow_nl = False):
            return ""
        state["pos"] = quote_idx + 1
        return chunk

    # SLOW PATH: Has escapes, process in chunks
    chars = []
    cached_quote_idx = quote_idx
    cached_backslash_idx = escape_idx  # Initialize with the first found escape_idx
    for _ in range(length * _MAX_ITERATIONS_MULTIPLIER):
        pos = state["pos"]
        if pos >= length:
            _fail(state, "Unterminated string")
            return ""

        # Update cached search points if we've moved past them
        if pos >= cached_quote_idx:
            cached_quote_idx = data.find('"', pos)
        if pos >= cached_backslash_idx:
            cached_backslash_idx = data.find("\\", pos)

        next_idx = _min_idx(cached_quote_idx, cached_backslash_idx)
        if next_idx == -1:
            _fail(state, "Unterminated string")
            return ""

        if next_idx > pos:
            chunk = data[pos:next_idx]
            if not _validate_text(state, chunk, "string", allow_nl = False):
                return ""
            chars += [chunk]
            state["pos"] = next_idx

        # If we hit a quote, we are done
        if data[state["pos"]] == '"':
            state["pos"] += 1
            return "".join(chars)

        # Handle backslash escape
        if data[state["pos"]] == "\\":
            state["pos"] += 1
            if state["pos"] >= length:
                _fail(state, "Unterminated string")
                return ""
            esc = data[state["pos"]]
            state["pos"] += 1
            sm = _escape_char(esc)
            if sm:
                chars += [sm]
                continue

            if esc == "x":
                hex_str = data[state["pos"]:state["pos"] + 2]
                if len(hex_str) == 2 and _is_hex(hex_str):
                    chars += [_codepoint_to_string(int(hex_str, 16))]
                    state["pos"] += 2
                    continue
            if esc == "u" or esc == "U":
                size = 4 if esc == "u" else 8
                hex_str = data[state["pos"]:state["pos"] + size]
                if len(hex_str) == size and _is_hex(hex_str):
                    code = int(hex_str, 16)
                    if _is_valid_codepoint(code):
                        chars += [_codepoint_to_string(code)]
                        state["pos"] += size
                        continue
        _fail(state, "Invalid escape")
        return ""
    return ""

def _parse_literal_string(state):
    """Parses a literal string (single quoted)."""
    _expect(state, "'")
    if state["error"] != None:
        return ""
    pos = state["pos"]
    data = state["data"]
    idx = data.find("'", pos)
    if idx == -1:
        _fail(state, "Unterminated literal string")
        return ""
    content = data[pos:idx]
    if not _validate_text(state, content, "literal string", allow_nl = False):
        return ""
    state["pos"] = idx + 1
    return content

# buildifier: disable=list-append
def _parse_multiline_basic_string(state):
    """Parses a multi-line basic string (triple double quoted)."""
    state["pos"] += 2
    if state["pos"] < state["len"] and state["data"][state["pos"]] == "\n":
        state["pos"] += 1

    chars = []
    d = state["data"]
    n = state["len"]

    # Total characters to process is bounded by n
    for _ in range(n * _MAX_ITERATIONS_MULTIPLIER):
        p = state["pos"]
        if p >= n:
            _fail(state, "Unterminated multiline string")
            return ""

        # Find next delimiter, escape, or newline (for skipping)
        q_idx = d.find('"""', p)
        if q_idx == -1:
            _fail(state, "Unterminated multiline string")
            return ""

        e_idx = d.find("\\", p, q_idx)

        next_idx = q_idx
        is_esc = False
        if e_idx != -1:
            next_idx = e_idx
            is_esc = True

        if next_idx > p:
            chunk = d[p:next_idx]
            if not _validate_text(state, chunk, "multiline string", allow_nl = True):
                return ""
            chars += [chunk]

        state["pos"] = next_idx
        if not is_esc:
            # Handle potential trailing quotes
            state["pos"] += 3
            ex = 0
            for _ in range(1, 3):
                if state["pos"] < n and d[state["pos"]] == '"':
                    ex += 1
                    state["pos"] += 1
                else:
                    break
            for _ in range(ex):
                chars += ['"']
            return "".join(chars)

        # Handle backslash
        if d[state["pos"]] == "\\":
            state["pos"] += 1
            if state["pos"] >= n:
                break
            esc = d[state["pos"]]
            if esc in " \t\n\r":
                # line-ending backslash
                tp = state["pos"]

                # Scan subsequent whitespace until newline
                for _ in range(n - tp):
                    if tp >= n:
                        break
                    c = d[tp]
                    if c == " " or c == "\t":
                        tp += 1
                        continue
                    break

                found_nl = False
                if tp < n and d[tp] == "\r":
                    tp += 1
                if tp < n and d[tp] == "\n":
                    tp += 1
                    found_nl = True

                    # Skip all subsequent whitespace/newlines
                    for _ in range(n - tp):
                        if tp >= n:
                            break
                        c = d[tp]
                        if c == " " or c == "\t" or c == "\n" or c == "\r":
                            tp += 1
                            continue
                        break
                if not found_nl:
                    _fail(state, "Invalid backslash escape")
                    return ""

                state["pos"] = tp
                continue

            sm = _escape_char(esc)
            if sm:
                chars += [sm]
                state["pos"] += 1
                continue
            if esc in "uUx":
                sz = 2 if esc == "x" else (4 if esc == "u" else 8)
                state["pos"] += 1
                hs = d[state["pos"]:state["pos"] + sz]
                if len(hs) == sz and _is_hex(hs):
                    code = int(hs, 16)
                    if _is_valid_codepoint(code):
                        chars += [_codepoint_to_string(code)]
                        state["pos"] += sz
                        continue
        _fail(state, "Invalid escape")
        return ""
    return ""

def _parse_multiline_literal_string(state):
    """Parses a multiline literal string (triple single-quoted)."""
    state["pos"] += 2
    if state["pos"] < state["len"] and state["data"][state["pos"]] == "\n":
        state["pos"] += 1

    p = state["pos"]
    d = state["data"]
    idx = d.find("'''", p)
    if idx == -1:
        _fail(state, "Unterminated multiline literal string")
        return ""

    # Handle potential trailing quotes
    ex = 0
    for _ in range(1, 3):
        if idx + 3 + _ <= state["len"] and d[idx + 3:idx + 3 + _] == "'" * _:
            ex = _
        else:
            break
    content = d[p:idx + ex]
    if not _validate_text(state, content, "multiline literal", allow_nl = True):
        return ""

    state["pos"] = idx + 3 + ex
    return content

def _parse_string(state):
    """Dispatches to the appropriate string parsing function based on quotes."""
    p = state["pos"]
    d = state["data"]
    if d[p] == '"':
        if p + 2 < state["len"] and d[p + 1:p + 3] == '""':
            state["pos"] += 1
            return _parse_multiline_basic_string(state)
        return _parse_basic_string(state)
    if d[p] == "'":
        if p + 2 < state["len"] and d[p + 1:p + 3] == "''":
            state["pos"] += 1
            return _parse_multiline_literal_string(state)
        return _parse_literal_string(state)
    return ""

def _parse_key(state):
    """Parses a TOML key (bare, basic, or literal)."""
    pos = state["pos"]
    data = state["data"]
    if data[pos] == '"':
        if pos + 2 < state["len"] and data[pos + 1:pos + 3] == '""':
            _fail(state, "Multiline key not allowed")
            return ""
        return _parse_basic_string(state)
    if data[pos] == "'":
        if pos + 2 < state["len"] and data[pos + 1:pos + 3] == "''":
            _fail(state, "Multiline key not allowed")
            return ""
        return _parse_literal_string(state)

    # Hand-parse bare keys: [A-Za-z0-9_-]+
    start = pos

    # Use windowed lstrip to avoid character loop overhead
    # Bounded range to avoid allocation
    for _ in range(state["len"]):
        if pos >= state["len"]:
            break
        window = data[pos:pos + 64]
        stripped = window.lstrip(_BARE_KEY_CHARS)
        consumed = len(window) - len(stripped)
        pos += consumed
        if consumed < len(window):
            break

    if pos > start:
        key = data[start:pos]
        state["pos"] = pos
        return key

    _fail(state, "Invalid key format")
    return ""

# buildifier: disable=list-append
def _parse_dotted_key(state):
    """Parses a dotted key into a list of components."""
    keys = []
    for _ in range(state["len"]):
        _skip_ws(state)
        k = _parse_key(state)
        if state["error"] != None:
            return keys
        keys += [k]
        _skip_ws(state)
        if state["pos"] < state["len"] and state["data"][state["pos"]] == ".":
            state["pos"] += 1
            continue
        break
    return keys

def _get_or_create_table(state, keys, is_array):
    """Navigates to or creates the table structure specified by the dotted keys."""
    current = state["root"]
    path = []
    for i in range(len(keys) - 1):
        key = keys[i]
        path.append(key)
        path_tuple = tuple(path)
        if key in current:
            existing = current[key]
            existing_type = state["path_types"].get(path_tuple)
            if existing_type != "table" and existing_type != "aot":
                _fail(state, "Traversal conflict with %s" % key)
                return {}
            current = existing if existing_type == "table" else (existing[-1] if existing else None)
            if current == None:
                _fail(state, "Empty AOT conflict")
                return {}
        else:
            new_tab = {}
            current[key] = new_tab
            current = new_tab
            state["path_types"][path_tuple] = "table"
    last_key = keys[-1]
    path.append(last_key)
    path_tuple = tuple(path)
    if is_array:
        existing_type = state["path_types"].get(path_tuple)
        if existing_type and existing_type != "aot":
            _fail(state, "AOT conflict on %s" % last_key)
            return {}
        if last_key in current:
            current[last_key].append({})
            state["explicit_paths"][path_tuple] = True
            state["header_paths"][path_tuple] = True
            return current[last_key][-1]
        else:
            current[last_key] = [{}]
            state["path_types"][path_tuple] = "aot"
            state["explicit_paths"][path_tuple] = True
            state["header_paths"][path_tuple] = True
            return current[last_key][0]
    elif last_key in current:
        if state["explicit_paths"].get(path_tuple):
            _fail(state, "Redefinition of %s" % last_key)
            return {}
        existing_type = state["path_types"].get(path_tuple)
        if existing_type != "table":
            _fail(state, "Table conflict on %s" % last_key)
            return {}
        state["explicit_paths"][path_tuple] = True
        state["header_paths"][path_tuple] = True
        return current[last_key]
    else:
        new_tab = {}
        current[last_key] = new_tab
        state["path_types"][path_tuple] = "table"
        state["explicit_paths"][path_tuple] = True
        state["header_paths"][path_tuple] = True
        return new_tab

def _parse_table(state):
    """Parses a table header [foo.bar] or [[foo.bar]]."""
    _expect(state, "[")
    is_array_of_tables = False
    if state["pos"] < state["len"] and state["data"][state["pos"]] == "[":
        is_array_of_tables = True
        state["pos"] += 1
    keys = _parse_dotted_key(state)
    _expect(state, "]")
    if is_array_of_tables:
        _expect(state, "]")
    if state["error"] != None:
        return
    state["current_path"] = keys
    state["current_table"] = _get_or_create_table(state, keys, is_array_of_tables)

def _parse_key_value(state, target):
    """Parses a key = value pair and inserts it into the target dictionary."""
    keys = _parse_dotted_key(state)
    if state["error"] != None or not keys:
        return
    _skip_ws(state)
    _expect(state, "=")
    _skip_ws(state)
    value = _parse_value(state)
    if state["error"] != None:
        return
    current = target
    base_path = state["current_path"]
    for i in range(len(keys) - 1):
        k = keys[i]
        path_tuple = tuple(base_path + keys[:i + 1])
        if k in current:
            existing_type = state["path_types"].get(path_tuple)
            if existing_type != "table":
                _fail(state, "Key conflict with %s" % k)
                return
            if state["header_paths"].get(path_tuple):
                _fail(state, "Key conflict with table: " + k)
                return
            if existing_type == "table":
                state["explicit_paths"][path_tuple] = True
            current = current[k]
        else:
            new_tab = {}
            current[k] = new_tab
            state["path_types"][path_tuple] = "table"
            state["explicit_paths"][path_tuple] = True
            current = new_tab

    last_key = keys[-1]
    last_path_tuple = tuple(base_path + keys)
    if last_key in current:
        _fail(state, "Redefinition of " + last_key)
        return
    current[last_key] = value
    state["path_types"][last_path_tuple] = "inline" if type(value) == "dict" else ("array" if type(value) == "list" else "scalar")

def _parse_scalar(state):
    """Parses simple scalar values like numbers, booleans, and dates."""
    pos = state["pos"]
    data = state["data"]

    m = _RE_SCALAR.match(data, pos)
    if m:
        val_str = m.group(0)
        groups = m.groupdict()

        if groups["number"]:
            is_float = "." in val_str or "e" in val_str or "E" in val_str

            # Leading zero check for integers
            if not is_float:
                check_str = val_str
                if check_str.startswith("+") or check_str.startswith("-"):
                    check_str = check_str[1:]
                if len(check_str) > 1 and check_str[0] == "0":
                    _fail(state, "Leading zero not allowed in integer: " + val_str)
                    return None

                # Check for trailing junk that regex might have missed (like another digit after 0)
                if check_str == "0" and pos + len(val_str) < state["len"] and state["data"][pos + len(val_str)].isdigit():
                    _fail(state, "Invalid integer suffix: " + val_str)
                    return None

            # Float-specific underscore validation
            if is_float and ("_." in val_str or "._" in val_str or "_e" in val_str or "e_" in val_str or "_E" in val_str or "E_" in val_str):
                _fail(state, "Invalid underscore in float: " + val_str)
                return None
            state["pos"] += len(val_str)
            val_clean = val_str.replace("_", "")
            if is_float:
                return float(val_clean)
            else:
                return int(val_clean)

        elif groups["boolean"]:
            state["pos"] += len(val_str)
            return val_str == "true"

        elif groups["datetime"]:
            state["pos"] += len(val_str)
            year = int(groups["dt_year"])
            month = int(groups["dt_month"])
            day = int(groups["dt_day"])
            if not _validate_date(state, year, month, day):
                _fail(state, "Invalid date: " + val_str)
                return None

            hour_str = groups["dt_hour"]
            if hour_str != None:
                # OffsetDateTime or LocalDateTime
                hour = int(hour_str)
                minute = int(groups["dt_minute"])
                sec_str = groups["dt_second"]
                second = int(sec_str) if sec_str != None else 0
                if not _validate_time(state, hour, minute, second):
                    _fail(state, "Invalid time in datetime: " + val_str)
                    return None

                micros = 0
                frac = groups["dt_frac"]
                if frac:
                    micros = int((frac + "000000")[:6])

                off_str = groups["dt_offset"]
                if off_str != None:
                    # OffsetDateTime
                    if off_str in ["Z", "z"]:
                        off_mins = 0
                    else:
                        off_sign = 1 if off_str[0] == "+" else -1
                        off_hour = int(off_str[1:3])
                        off_min = int(off_str[4:6])
                        if not _validate_offset(state, off_hour, off_min):
                            _fail(state, "Invalid offset: " + off_str)
                            return None
                        off_mins = off_sign * (off_hour * 60 + off_min)
                    res = struct(
                        _toml_type = "OffsetDateTime",
                        year = year,
                        month = month,
                        day = day,
                        hour = hour,
                        minute = minute,
                        second = second,
                        microsecond = micros,
                        offset_minutes = off_mins,
                    )
                else:
                    # LocalDateTime
                    res = struct(
                        _toml_type = "LocalDateTime",
                        year = year,
                        month = month,
                        day = day,
                        hour = hour,
                        minute = minute,
                        second = second,
                        microsecond = micros,
                    )
            else:
                # LocalDate
                res = struct(
                    _toml_type = "LocalDate",
                    year = year,
                    month = month,
                    day = day,
                )

            if state["datetime_formatter"]:
                return state["datetime_formatter"](res)
            return res

        elif groups["time"]:
            state["pos"] += len(val_str)
            hour = int(groups["tm_hour"])
            minute = int(groups["tm_minute"])
            sec_str = groups["tm_second"]
            second = int(sec_str) if sec_str != None else 0
            if not _validate_time(state, hour, minute, second):
                _fail(state, "Invalid time: " + val_str)
                return None
            micros = 0
            frac = groups["tm_frac"]
            if frac:
                micros = int((frac + "000000")[:6])
            res = struct(
                _toml_type = "LocalTime",
                hour = hour,
                minute = minute,
                second = second,
                microsecond = micros,
            )
            if state["datetime_formatter"]:
                return state["datetime_formatter"](res)
            return res

        elif groups["hex"]:
            val = val_str[2:]
            if len(val) > 0 and (val[-1] == "_" or val[0] == "_"):
                return None
            state["pos"] += len(val_str)
            return int(val.replace("_", ""), 16)

        elif groups["oct"]:
            val = val_str[2:]
            if len(val) > 0 and (val[-1] == "_" or val[0] == "_"):
                return None
            state["pos"] += len(val_str)
            return int(val.replace("_", ""), 8)

        elif groups["bin"]:
            val = val_str[2:]
            if len(val) > 0 and (val[-1] == "_" or val[0] == "_"):
                return None
            state["pos"] += len(val_str)
            return int(val.replace("_", ""), 2)

        elif groups["inf_nan"]:
            state["pos"] += len(val_str)

            # Normalize inf/nan string
            lower_val = val_str.lower()
            if "nan" in lower_val:
                # Use float() to support nan, +nan, -nan. Starlark treats -nan as nan.
                return float(lower_val)
            else:
                # inf or -inf or +inf
                return float(lower_val)

    _fail(state, "Invalid scalar value")
    return None

_MODE_ARRAY_VAL = 1
_MODE_ARRAY_COMMA = 2
_MODE_TABLE_KEY = 3
_MODE_TABLE_VAL = 4
_MODE_TABLE_COMMA = 5

# buildifier: disable=list-append
def _parse_complex_iterative(state):
    """Parses inline tables and arrays iteratively using a manual stack."""
    char = state["data"][state["pos"]]
    res = [] if char == "[" else {}
    stack = [[res, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
    state["pos"] += 1

    for _ in range(state["len"] * _MAX_ITERATIONS_MULTIPLIER):
        if not stack or state["error"] != None:
            return res
        fr = stack[-1]
        cont = fr[0]
        mode = fr[1]
        _skip_ws(state, skip_nl = True)
        if state["pos"] >= state["len"]:
            _fail(state, "EOF in complex")
            return res
        char = state["data"][state["pos"]]
        if mode == _MODE_ARRAY_VAL:
            if char == "]":
                state["pos"] += 1
                stack.pop()
                continue
            if char == "[" or char == "{":
                if state["max_depth"] != None and len(stack) >= state["max_depth"]:
                    _fail(state, "Max nesting depth exceeded")
                    return res
                new_container = [] if char == "[" else {}
                cont += [new_container]
                state["pos"] += 1
                stack += [[new_container, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
                fr[1] = _MODE_ARRAY_COMMA
                continue
            val = _parse_val_nested(state)
            if val != None:
                cont += [val]
                fr[1] = _MODE_ARRAY_COMMA
                continue
            _fail(state, "Value expected in array")
        elif mode == _MODE_ARRAY_COMMA:
            if char == "]":
                fr[1] = _MODE_ARRAY_VAL
                continue
            if char == ",":
                state["pos"] += 1
                fr[1] = _MODE_ARRAY_VAL
                continue
            _fail(state, "Array comma expected")
        elif mode == _MODE_TABLE_KEY:
            if char == "}":
                state["pos"] += 1
                stack.pop()
                continue
            ks = _parse_dotted_key(state)
            _skip_ws(state)
            _expect(state, "=")
            _skip_ws(state)
            fr[2] = ks
            fr[1] = _MODE_TABLE_VAL
        elif mode == _MODE_TABLE_VAL:
            ks = fr[2]
            explicit_map = stack[-1][3]
            if char == "[" or char == "{":
                if state["max_depth"] != None and len(stack) >= state["max_depth"]:
                    _fail(state, "Max nesting depth exceeded")
                    return res
                new_container = [] if char == "[" else {}
                curr = cont
                for i in range(len(ks) - 1):
                    k = ks[i]
                    if tuple(ks[:i + 1]) in explicit_map:
                        _fail(state, "Key conflict with %s" % k)
                        break
                    if k in curr:
                        if not _is_dict(curr[k]):
                            _fail(state, "Key conflict with %s" % k)
                            break
                        curr = curr[k]
                    else:
                        new_tab = {}
                        curr[k] = new_tab
                        curr = new_tab
                if state["error"] != None:
                    return res
                lk = ks[-1]
                if lk in curr:
                    _fail(state, "Duplicate key %s" % lk)
                    return res
                explicit_map[tuple(ks)] = True
                curr[lk] = new_container
                state["pos"] += 1
                stack += [[new_container, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
                fr[1] = _MODE_TABLE_COMMA
            else:
                val = _parse_val_nested(state)
                if state["error"] != None:
                    return res
                curr = cont
                for i in range(len(ks) - 1):
                    k = ks[i]
                    if tuple(ks[:i + 1]) in explicit_map:
                        _fail(state, "Key conflict with %s" % k)
                        break
                    if k in curr:
                        if not _is_dict(curr[k]):
                            _fail(state, "Key conflict with %s" % k)
                            break
                        curr = curr[k]
                    else:
                        new_tab = {}
                        curr[k] = new_tab
                        curr = new_tab
                if state["error"] != None:
                    return res
                lk = ks[-1]
                if lk in curr:
                    _fail(state, "Duplicate key %s" % lk)
                    return res
                explicit_map[tuple(ks)] = True
                curr[lk] = val
                fr[1] = _MODE_TABLE_COMMA
        elif mode == _MODE_TABLE_COMMA:
            if char == "}":
                fr[1] = _MODE_TABLE_KEY
                continue
            if char == ",":
                state["pos"] += 1
                fr[1] = _MODE_TABLE_KEY
                continue
            _fail(state, "Inline table comma expected")
    return res

def _parse_val_nested(state):
    """Parses a value when nested inside a complex iterative structure."""
    pos = state["pos"]
    data = state["data"]
    if data[pos] == '"' or data[pos] == "'":
        return _parse_string(state)
    return _parse_scalar(state)

def _format_scalar_for_test(v):
    """Formats a scalar value into the `toml-test` JSON compatible format."""
    t = type(v)
    if t == "bool":
        return {"type": "bool", "value": "true" if v else "false"}
    if t == "int":
        return {"type": "integer", "value": str(v)}
    if t == "float":
        # toml-test expects "inf" instead of "+inf"
        s = str(v)
        if s == "+inf":
            s = "inf"
        return {"type": "float", "value": s}
    if t == "string":
        return {"type": "string", "value": v}
    if t == "struct":
        tt = getattr(v, "_toml_type", None)
        if tt == "OffsetDateTime":
            return {"type": "datetime", "value": datetime_to_string(v)}
        if tt == "LocalDateTime":
            return {"type": "datetime-local", "value": datetime_to_string(v)}
        if tt == "LocalDate":
            return {"type": "date-local", "value": datetime_to_string(v)}
        if tt == "LocalTime":
            return {"type": "time-local", "value": datetime_to_string(v)}
        return {"type": v.toml_type, "value": v.value}
    return None

def _expand_to_toml_test(raw, size_hint):
    """Converts a standard Starlark structure into the `toml-test` format."""
    root = {} if type(raw) == "dict" else []
    stack = [[raw, root]]
    for _ in range(size_hint * 2 + 100):
        if not stack:
            break
        raw_node, target_node = stack.pop()
        if type(raw_node) == "dict":
            for key, value in raw_node.items():
                if type(value) in ["dict", "list"]:
                    target_node[key] = {} if type(value) == "dict" else []
                    stack.append([value, target_node[key]])
                else:
                    target_node[key] = _format_scalar_for_test(value)
        else:
            for value in raw_node:
                if type(value) in ["dict", "list"]:
                    target_node.append({} if type(value) == "dict" else [])
                    stack.append([value, target_node[-1]])
                else:
                    target_node.append(_format_scalar_for_test(value))
    return root

def _parse_value(state):
    """Delegates parsing to scalars, strings, or complex structures."""
    _skip_ws(state)
    if state["pos"] >= state["len"]:
        _fail(state, "Value expected at EOF")
        return None
    char = state["data"][state["pos"]]
    if char in "[{":
        return _parse_complex_iterative(state)
    if char in "\"'":
        return _parse_string(state)
    res = _parse_scalar(state)
    if res == None and state["error"] == None:
        _fail(state, "Value expected")
    return res

def _is_globally_safe(data):
    """Returns True if the document is pure safe ASCII (0-127).

    This uses a single native lstrip pass. If the result is empty, the document
    is guaranteed to contain only printable ASCII and safe whitespace (Tab/NL).
    """
    return not data.lstrip(_VALID_ASCII_CHARS)

def OffsetDateTime(year, month, day, hour, minute, second, microsecond, offset_minutes):
    """Creates an OffsetDateTime struct.

    Args:
      year: The year.
      month: The month (1-12).
      day: The day of the month (1-31).
      hour: The hour (0-23).
      minute: The minute (0-59).
      second: The second (0-60).
      microsecond: The microsecond (0-999999).
      offset_minutes: The offset from UTC in minutes.

    Returns:
      A struct representing an OffsetDateTime.
    """
    return struct(
        _toml_type = "OffsetDateTime",
        year = year,
        month = month,
        day = day,
        hour = hour,
        minute = minute,
        second = second,
        microsecond = microsecond,
        offset_minutes = offset_minutes,
    )

def LocalDateTime(year, month, day, hour, minute, second, microsecond):
    """Creates a LocalDateTime struct.

    Args:
      year: The year.
      month: The month (1-12).
      day: The day of the month (1-31).
      hour: The hour (0-23).
      minute: The minute (0-59).
      second: The second (0-60).
      microsecond: The microsecond (0-999999).

    Returns:
      A struct representing a LocalDateTime.
    """
    return struct(
        _toml_type = "LocalDateTime",
        year = year,
        month = month,
        day = day,
        hour = hour,
        minute = minute,
        second = second,
        microsecond = microsecond,
    )

def LocalDate(year, month, day):
    """Creates a LocalDate struct.

    Args:
      year: The year.
      month: The month (1-12).
      day: The day of the month (1-31).

    Returns:
      A struct representing a LocalDate.
    """
    return struct(
        _toml_type = "LocalDate",
        year = year,
        month = month,
        day = day,
    )

def LocalTime(hour, minute, second, microsecond):
    """Creates a LocalTime struct.

    Args:
      hour: The hour (0-23).
      minute: The minute (0-59).
      second: The second (0-60).
      microsecond: The microsecond (0-999999).

    Returns:
      A struct representing a LocalTime.
    """
    return struct(
        _toml_type = "LocalTime",
        hour = hour,
        minute = minute,
        second = second,
        microsecond = microsecond,
    )

def datetime_to_string(dt):
    """Formats a TOML temporal struct as an RFC 3339 standardized string.

    Args:
      dt: One of the TOML temporal structs.

    Returns:
      An RFC 3339 standardized string representation.
    """
    t = getattr(dt, "_toml_type", None)
    if t == "OffsetDateTime":
        s = "%s-%s-%sT%s:%s:%s" % (
            _pad_num(dt.year, 4),
            _pad_num(dt.month, 2),
            _pad_num(dt.day, 2),
            _pad_num(dt.hour, 2),
            _pad_num(dt.minute, 2),
            _pad_num(dt.second, 2),
        )
        if dt.microsecond > 0:
            s += "." + _pad_num(dt.microsecond, 6).rstrip("0")
        if dt.offset_minutes == 0:
            s += "Z"
        else:
            om = abs(dt.offset_minutes)
            s += ("+" if dt.offset_minutes >= 0 else "-") + "%s:%s" % (
                _pad_num(om // 60, 2),
                _pad_num(om % 60, 2),
            )
        return s
    if t == "LocalDateTime":
        s = "%s-%s-%sT%s:%s:%s" % (
            _pad_num(dt.year, 4),
            _pad_num(dt.month, 2),
            _pad_num(dt.day, 2),
            _pad_num(dt.hour, 2),
            _pad_num(dt.minute, 2),
            _pad_num(dt.second, 2),
        )
        if dt.microsecond > 0:
            s += "." + _pad_num(dt.microsecond, 6).rstrip("0")
        return s
    if t == "LocalDate":
        return "%s-%s-%s" % (_pad_num(dt.year, 4), _pad_num(dt.month, 2), _pad_num(dt.day, 2))
    if t == "LocalTime":
        s = "%s:%s:%s" % (_pad_num(dt.hour, 2), _pad_num(dt.minute, 2), _pad_num(dt.second, 2))
        if dt.microsecond > 0:
            s += "." + _pad_num(dt.microsecond, 6).rstrip("0")
        return s
    fail("Expected a TOML temporal struct, got %s" % type(dt))

def decode(data, default = None, datetime_formatter = None, max_depth = 128, expand_values = False):
    """Decodes a TOML string into a Starlark structure.

    Args:
        data: The TOML string to decode.
        default: Optional default value to return on failure.
        datetime_formatter: Optional function to format temporal values.
        max_depth: Maximum nesting depth for tables and arrays.
        expand_values: Whether to return a "toml-test" compatible format.

    Returns:
        The decoded Starlark structure, or the default value on failure.
    """
    data = data.replace("\r\n", "\n")
    state = _parser(data, default, datetime_formatter, max_depth, expand_values)

    # Initial safety check
    state["is_safe"] = _is_globally_safe(data)

    for _ in range(state["len"] * _MAX_ITERATIONS_MULTIPLIER):
        _skip_ws(state, skip_nl = True)
        if state["pos"] >= state["len"]:
            break

        char = state["data"][state["pos"]]
        if char == "[":
            _parse_table(state)
        elif char == "#":
            _skip_ws(state)  # handles comment until newline
        else:
            _parse_key_value(state, state["current_table"])

        if state["error"] != None:
            break

        # Check for trailing junk on the same line
        _skip_ws(state)
        if state["pos"] < state["len"]:
            char = state["data"][state["pos"]]
            if char != "\n" and char != "\r" and char != "#":
                _fail(state, "Expected newline or EOF")
                break

    if state["error"] != None:
        return default

    return _expand_to_toml_test(state["root"], len(data)) if expand_values else state["root"]

def _min_idx(a, b):
    if a == -1:
        return b
    if b == -1:
        return a
    return a if a < b else b

def _is_valid_codepoint(code):
    return (0 <= code and code <= 0x10FFFF) and not (0xD800 <= code and code <= 0xDFFF)

"""Starlark TOML Decoder implementation."""

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
    "\"": "\"",
    "e": "\033",
}

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
    for _ in range(length):
        if pos >= length:
            break

        char = data[pos]
        if char in skip_chars:
            # Use small window lstrip to skip contiguous whitespace blocks
            chunk = data[pos:pos + 256]
            pos += len(chunk) - len(chunk.lstrip(skip_chars))
            continue

        if char == "#":
            newline_pos = data.find("\n", pos)
            comment_end = newline_pos if newline_pos != -1 else length
            comment_text = data[pos:comment_end]

            # Sync pos before validation as it might fail
            state["pos"] = pos
            if not _validate_text(state, comment_text, "comment", allow_nl = False):
                return
            pos = comment_end
            continue
        break
    state["pos"] = pos

def _expect(state, char):
    """Asserts that the next character in the stream is `char` and consumes it."""
    if state["error"] != None:
        return
    pos = state["pos"]
    if pos >= state["len"] or state["data"][pos] != char:
        _fail(state, "Expected '%s' at %d" % (char, pos))
        return
    state["pos"] = pos + 1

# --- Types & Validation ---

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

def _min_idx(a, b):
    if a == -1:
        return b
    if b == -1:
        return a
    return a if a < b else b

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
    data = state["data"]
    length = state["len"]
    pos = state["pos"]

    if pos >= length or data[pos] != '"':
        _fail(state, "Expected '\"' at %d" % pos)
        return ""
    pos += 1

    if state["error"] != None:
        return ""

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
    cached_backslash_idx = escape_idx
    for _ in range(length * _MAX_ITERATIONS_MULTIPLIER):
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
            pos = next_idx

        # If we hit a quote, we are done
        if data[pos] == '"':
            state["pos"] = pos + 1
            return "".join(chars)

        # Handle backslash escape
        if data[pos] == "\\":
            pos += 1
            if pos >= length:
                _fail(state, "Unterminated string")
                return ""
            esc = data[pos]
            pos += 1
            sm = _escape_char(esc)
            if sm:
                chars += [sm]
                continue

            if esc == "x":
                hex_str = data[pos:pos + 2]
                if len(hex_str) == 2 and _is_hex(hex_str):
                    chars += [_codepoint_to_string(int(hex_str, 16))]
                    pos += 2
                    continue
            if esc == "u" or esc == "U":
                size = 4 if esc == "u" else 8
                hex_str = data[pos:pos + size]
                if len(hex_str) == size and _is_hex(hex_str):
                    code = int(hex_str, 16)
                    if _is_valid_codepoint(code):
                        chars += [_codepoint_to_string(code)]
                        pos += size
                        continue
        _fail(state, "Invalid escape")
        return ""
    return ""

def _parse_literal_string(state):
    """Parses a literal string (single quoted)."""
    pos = state["pos"]
    data = state["data"]
    length = state["len"]
    if pos >= length or data[pos] != "'":
        _fail(state, "Expected \"'\" at %d" % pos)
        return ""
    pos += 1

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
    data = state["data"]
    length = state["len"]
    pos = state["pos"]

    pos += 2
    if pos < length and data[pos] == "\n":
        pos += 1

    chars = []

    # Total characters to process is bounded by length
    for _ in range(length * _MAX_ITERATIONS_MULTIPLIER):
        if pos >= length:
            _fail(state, "Unterminated multiline string")
            return ""

        # Find next delimiter, escape, or newline (for skipping)
        q_idx = data.find('"""', pos)
        if q_idx == -1:
            _fail(state, "Unterminated multiline string")
            return ""

        e_idx = data.find("\\", pos, q_idx)

        next_idx = q_idx
        is_esc = False
        if e_idx != -1:
            next_idx = e_idx
            is_esc = True

        if next_idx > pos:
            chunk = data[pos:next_idx]
            if not _validate_text(state, chunk, "multiline string", allow_nl = True):
                return ""
            chars += [chunk]

        pos = next_idx
        if not is_esc:
            # Handle potential trailing quotes
            pos += 3
            ex = 0
            for _ in range(1, 3):
                if pos < length and data[pos] == '"':
                    ex += 1
                    pos += 1
                else:
                    break
            for _ in range(ex):
                chars += ['"']
            state["pos"] = pos
            return "".join(chars)

        # Handle backslash
        if data[pos] == "\\":
            pos += 1
            if pos >= length:
                break
            esc = data[pos]
            if esc in " \t\n\r":
                # line-ending backslash
                tp = pos

                # Scan subsequent whitespace until newline
                for _ in range(length - tp):
                    if tp >= length:
                        break
                    c = data[tp]
                    if c == " " or c == "\t":
                        tp += 1
                        continue
                    break

                found_nl = False
                if tp < length and data[tp] == "\r":
                    tp += 1
                if tp < length and data[tp] == "\n":
                    tp += 1
                    found_nl = True

                    # Skip all subsequent whitespace/newlines
                    for _ in range(length - tp):
                        if tp >= length:
                            break
                        c = data[tp]
                        if c == " " or c == "\t" or c == "\n" or c == "\r":
                            tp += 1
                            continue
                        break
                if not found_nl:
                    _fail(state, "Invalid backslash escape")
                    return ""

                pos = tp
                continue

            sm = _escape_char(esc)
            if sm:
                chars += [sm]
                pos += 1
                continue
            if esc in "uUx":
                sz = 2 if esc == "x" else (4 if esc == "u" else 8)
                pos += 1
                hs = data[pos:pos + sz]
                if len(hs) == sz and _is_hex(hs):
                    code = int(hs, 16)
                    if _is_valid_codepoint(code):
                        chars += [_codepoint_to_string(code)]
                        pos += sz
                        continue
        _fail(state, "Invalid escape")
        return ""
    return ""

def _parse_multiline_literal_string(state):
    """Parses a multiline literal string (triple single-quoted)."""
    data = state["data"]
    length = state["len"]
    pos = state["pos"]

    pos += 2
    if pos < length and data[pos] == "\n":
        pos += 1

    idx = data.find("'''", pos)
    if idx == -1:
        _fail(state, "Unterminated multiline literal string")
        return ""

    # Handle potential trailing quotes
    ex = 0
    for _ in range(1, 3):
        if idx + 3 + _ <= length and data[idx + 3:idx + 3 + _] == "'" * _:
            ex = _
        else:
            break
    content = data[pos:idx + ex]
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
    length = state["len"]
    if pos >= length:
        _fail(state, "Expected key")
        return ""

    if data[pos] == '"':
        if pos + 2 < length and data[pos + 1:pos + 3] == '""':
            _fail(state, "Multiline key not allowed")
            return ""
        return _parse_basic_string(state)
    if data[pos] == "'":
        if pos + 2 < length and data[pos + 1:pos + 3] == "''":
            _fail(state, "Multiline key not allowed")
            return ""
        return _parse_literal_string(state)

    # Hand-parse bare keys: [A-Za-z0-9_-]+
    start = pos

    # Use windowed lstrip to avoid character loop overhead
    # Bounded range to avoid allocation
    for _ in range(length):
        if pos >= length:
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
    state["path_types"][last_path_tuple] = "inline" if type(value) == "dict" else ("array" if type(value) == "list" else "scalar")
    current[last_key] = value

def _parse_int_base(state, prefix, valid_chars, base):
    """Parses a hex, octal, or binary integer."""
    pos = state["pos"]
    data = state["data"]
    length = state["len"]

    # We assume '0x', '0o', '0b' is already checked
    pos += len(prefix)
    start = pos

    # Simple loop because these strings are usually short
    idx = pos
    for _ in range(length):
        if idx >= length:
            break
        c = data[idx]
        if c == "_":
            idx += 1
            continue
        if c in valid_chars:
            idx += 1
            continue
        break

    end = idx
    if end == start:
        return None  # No digits

    val_str = data[start:end]

    # Validate underscores: No leading, no trailing, no double
    if val_str.startswith("_") or val_str.endswith("_") or "__" in val_str:
        return None

    cleaned = val_str.replace("_", "")
    state["pos"] = end
    return int(cleaned, base)

def _parse_number_strict(text):
    """Strictly validates a TOML number (float or integer)."""
    idx = 0
    length = len(text)

    # 1. Sign
    if idx < length and (text[idx] == "+" or text[idx] == "-"):
        idx += 1

    if idx >= length:
        return None

    # 2. Integer Part
    if text[idx] == "0":
        idx += 1
        if idx < length:
            c = text[idx]
            if c != "." and c != "e" and c != "E":
                return None
    elif text[idx] in "123456789":
        idx += 1
        for _ in range(length):
            if idx >= length:
                break
            c = text[idx]
            if c in "0123456789":
                idx += 1
            elif c == "_":
                if idx + 1 >= length:
                    return None
                if text[idx + 1] == "_":
                    return None
                if text[idx + 1] not in "0123456789":
                    return None
                idx += 1
            else:
                break
    else:
        return None

    # 3. Fraction Part
    if idx < length and text[idx] == ".":
        idx += 1
        if idx >= length:
            return None
        if not text[idx].isdigit():
            return None

        for _ in range(length):
            if idx >= length:
                break
            c = text[idx]
            if c.isdigit():
                idx += 1
            elif c == "_":
                if idx + 1 >= length:
                    return None
                if not text[idx + 1].isdigit():
                    return None
                idx += 1
            else:
                break

    # 4. Exponent Part
    if idx < length and (text[idx] == "e" or text[idx] == "E"):
        idx += 1
        if idx >= length:
            return None
        if text[idx] == "+" or text[idx] == "-":
            idx += 1
            if idx >= length:
                return None

        if not text[idx].isdigit():
            return None

        for _ in range(length):
            if idx >= length:
                break
            c = text[idx]
            if c.isdigit():
                idx += 1
            elif c == "_":
                if idx + 1 >= length:
                    return None
                if not text[idx + 1].isdigit():
                    return None
                idx += 1
            else:
                return None

    if idx != length:
        return None

    return True

def _parse_datetime_strict(text):
    """Parses a TOML datetime string."""
    if len(text) < 10:
        return None

    date_part = text[:10]
    if date_part[4] != "-" or date_part[7] != "-":
        return None

    year_s = date_part[:4]
    month_s = date_part[5:7]
    day_s = date_part[8:10]

    if not (year_s.isdigit() and month_s.isdigit() and day_s.isdigit()):
        return None

    res = {
        "year": int(year_s),
        "month": int(month_s),
        "day": int(day_s),
        "hour": None,
        "minute": None,
        "second": None,
        "microsecond": 0,
        "offset": None,
    }

    if len(text) == 10:
        return res

    rest = text[10:]
    if not (rest.startswith("T") or rest.startswith("t") or rest.startswith(" ")):
        return None

    if len(rest) < 6:
        return None

    time_part = rest[1:]
    # Check if we have enough for HH:MM:SS (8 chars) or just HH:MM (5 chars)
    # But wait, logic below assumes index access.

    if len(time_part) < 5:
        return None

    if time_part[2] != ":":
        return None

    hour_s = time_part[:2]
    minute_s = time_part[3:5]
    if not (hour_s.isdigit() and minute_s.isdigit()):
        return None

    res["hour"] = int(hour_s)
    res["minute"] = int(minute_s)
    res["second"] = 0

    processed_len = 5

    if len(time_part) >= 8 and time_part[5] == ":":
        second_s = time_part[6:8]
        if not second_s.isdigit():
            return None
        res["second"] = int(second_s)
        processed_len = 8

    rest = rest[1 + processed_len:]

    if rest.startswith("."):
        idx = 1

        # Loop bounded by rest length
        for _ in range(len(rest)):
            if idx < len(rest) and rest[idx].isdigit():
                idx += 1
            else:
                break

        frac_s = rest[1:idx]
        if not frac_s:
            return None
        micros_s = (frac_s + "000000")[:6]
        res["microsecond"] = int(micros_s)

        rest = rest[idx:]

    if not rest:
        return res

    if rest == "Z" or rest == "z":
        res["offset"] = 0
    elif rest.startswith("+") or rest.startswith("-"):
        if len(rest) < 6:
            return None  # +HH:MM

        # Handle +HH:MM
        if rest[3] == ":":
            oh_s = rest[1:3]
            om_s = rest[4:6]
            if not (oh_s.isdigit() and om_s.isdigit()):
                return None
            if int(om_s) >= 60:
                return None
            sign = 1 if rest[0] == "+" else -1
            res["offset"] = sign * (int(oh_s) * 60 + int(om_s))
        else:
            return None
    else:
        return None

    return res

def _parse_time_strict(text):
    """Parses a TOML local time string HH:MM:SS(.frac)? or HH:MM."""
    if len(text) < 5:
        return None
    if text[2] != ":":
        return None

    hour_s = text[:2]
    minute_s = text[3:5]
    if not (hour_s.isdigit() and minute_s.isdigit()):
        return None

    res = {
        "hour": int(hour_s),
        "minute": int(minute_s),
        "second": 0,
        "microsecond": 0,
    }

    if len(text) == 5:
        return res

    if len(text) < 8 or text[5] != ":":
        return None

    second_s = text[6:8]
    if not second_s.isdigit():
        return None
    res["second"] = int(second_s)

    rest = text[8:]
    if rest.startswith("."):
        if not rest[1:].isdigit():
            return None
        micros_s = (rest[1:] + "000000")[:6]
        res["microsecond"] = int(micros_s)
    elif rest:
        return None

    return res

def _parse_scalar(state):
    """Parses a scalar value using specialized regexes and character lookahead."""
    pos = state["pos"]
    data = state["data"]
    length = state["len"]

    char = data[pos]

    # --- Boolean ---
    if char == "t":
        if data.startswith("true", pos):
            state["pos"] = pos + 4
            return True
    elif char == "f":
        if data.startswith("false", pos):
            state["pos"] = pos + 5
            return False

        # --- Inf / Nan (leading i / n) ---
    elif char == "i":
        if data.startswith("inf", pos):
            state["pos"] = pos + 3
            return float("inf")
    elif char == "n":
        if data.startswith("nan", pos):
            state["pos"] = pos + 3
            return float("nan")

        # --- Numbers / Dates / Times / Hex / Oct / Bin / Signed Inf ---
    elif char.isdigit() or char == "+" or char == "-":
        # Check for Hex/Oct/Bin (only if starts with 0)
        if char == "0" and pos + 1 < length:
            next_char = data[pos + 1]
            if next_char == "x":
                val = _parse_int_base(state, "0x", "0123456789abcdefABCDEF", 16)
                if val != None:
                    return val
                _fail(state, "Invalid hex integer")
                return None
            elif next_char == "o":
                val = _parse_int_base(state, "0o", "01234567", 8)
                if val != None:
                    return val
                _fail(state, "Invalid octal integer")
                return None
            elif next_char == "b":
                val = _parse_int_base(state, "0b", "01", 2)
                if val != None:
                    return val
                _fail(state, "Invalid binary integer")
                return None

        # Check for Signed Inf/Nan (+inf, -nan)
        if (char == "+" or char == "-") and pos + 1 < length:
            c2 = data[pos + 1]
            if c2 == "i":
                if data.startswith("inf", pos + 1):
                    state["pos"] = pos + 4
                    val = float("inf")
                    return val if char == "+" else -val
            elif c2 == "n":
                if data.startswith("nan", pos + 1):
                    state["pos"] = pos + 4
                    return float("nan")

        # Scan the full token for generic number/date parsing
        start = pos
        idx = pos
        for _ in range(length):
            if idx >= length:
                break
            c = data[idx]
            if c in "0123456789+-.eE_:TtZz ":
                idx += 1
                continue
            break

        token_candidate = data[start:idx]

        # 1. Try Datetime strict
        if "-" in token_candidate and len(token_candidate) >= 10:
            clean_token = token_candidate.rstrip()
            dt = _parse_datetime_strict(clean_token)
            if dt:
                year = dt["year"]
                month = dt["month"]
                day = dt["day"]
                if not _validate_date(state, year, month, day):
                    _fail(state, "Invalid date")
                    return None

                hour = dt["hour"]
                if hour != None:
                    if not _validate_time(state, hour, dt["minute"], dt["second"]):
                        _fail(state, "Invalid time in datetime")
                        return None

                    offset = dt["offset"]
                    if offset != None:
                        # OffsetDateTime
                        off_hour = abs(offset) // 60
                        off_min = abs(offset) % 60
                        if not _validate_offset(state, off_hour, off_min):
                            _fail(state, "Invalid offset")
                            return None

                        res = struct(
                            _toml_type = "OffsetDateTime",
                            year = year,
                            month = month,
                            day = day,
                            hour = hour,
                            minute = dt["minute"],
                            second = dt["second"],
                            microsecond = dt["microsecond"],
                            offset_minutes = offset,
                        )
                    else:
                        # LocalDateTime
                        res = struct(
                            _toml_type = "LocalDateTime",
                            year = year,
                            month = month,
                            day = day,
                            hour = hour,
                            minute = dt["minute"],
                            second = dt["second"],
                            microsecond = dt["microsecond"],
                        )
                else:
                    # LocalDate
                    res = struct(
                        _toml_type = "LocalDate",
                        year = year,
                        month = month,
                        day = day,
                    )

                # Success
                state["pos"] += len(clean_token)
                if state["datetime_formatter"]:
                    return state["datetime_formatter"](res)
                return res

        # Try Time
        if ":" in token_candidate and len(token_candidate) >= 5:
            # Time cannot contain space. Date can.
            token_no_space = token_candidate.split(" ")[0]
            tm2 = _parse_time_strict(token_no_space)
            if tm2:
                if not _validate_time(state, tm2["hour"], tm2["minute"], tm2["second"]):
                    _fail(state, "Invalid time")
                    return None

                # Success
                res = struct(
                    _toml_type = "LocalTime",
                    hour = tm2["hour"],
                    minute = tm2["minute"],
                    second = tm2["second"],
                    microsecond = tm2["microsecond"],
                )
                state["pos"] += len(token_no_space)
                if state["datetime_formatter"]:
                    return state["datetime_formatter"](res)
                return res

        # 2. Try Number
        first_part = token_candidate.split(" ")[0]

        if _parse_number_strict(first_part):
            state["pos"] += len(first_part)
            is_float = "." in first_part or "e" in first_part or "E" in first_part
            if is_float:
                return float(first_part.replace("_", ""))
            else:
                return int(first_part.replace("_", ""))

        _fail(state, "Invalid scalar (number/date) format: " + token_candidate)
        return None

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
    data = state["data"]
    length = state["len"]
    pos = state["pos"]

    char = data[pos]
    res = [] if char == "[" else {}
    stack = [[res, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
    pos += 1

    for _ in range(length * _MAX_ITERATIONS_MULTIPLIER):
        state["pos"] = pos
        if not stack or state["error"] != None:
            return res
        fr = stack[-1]
        cont = fr[0]
        mode = fr[1]
        _skip_ws(state, skip_nl = True)
        pos = state["pos"]

        if pos >= length:
            _fail(state, "EOF in complex")
            return res
        char = data[pos]

        if mode <= 2:  # Array modes (_MODE_ARRAY_VAL=1, _MODE_ARRAY_COMMA=2)
            if mode == _MODE_ARRAY_VAL:
                if char == "]":
                    pos += 1
                    state["pos"] = pos
                    stack.pop()
                    continue
                if char in "[{":
                    if state["max_depth"] != None and len(stack) >= state["max_depth"]:
                        _fail(state, "Max nesting depth exceeded")
                        return res
                    new_container = [] if char == "[" else {}
                    cont += [new_container]
                    pos += 1
                    state["pos"] = pos
                    stack += [[new_container, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
                    fr[1] = _MODE_ARRAY_COMMA
                    continue
                val = _parse_val_nested(state)
                pos = state["pos"]
                if val != None:
                    cont += [val]
                    fr[1] = _MODE_ARRAY_COMMA
                    continue
                _fail(state, "Value expected in array")
            else:  # _MODE_ARRAY_COMMA
                if char == "]":
                    fr[1] = _MODE_ARRAY_VAL
                    continue
                if char == ",":
                    pos += 1
                    state["pos"] = pos
                    fr[1] = _MODE_ARRAY_VAL
                    continue
                _fail(state, "Array comma expected")
        else:  # Table modes (_MODE_TABLE_KEY=3, _MODE_TABLE_VAL=4, _MODE_TABLE_COMMA=5)
            if mode == _MODE_TABLE_KEY:
                if char == "}":
                    pos += 1
                    state["pos"] = pos
                    stack.pop()
                    continue
                ks = _parse_dotted_key(state)
                _skip_ws(state)
                _expect(state, "=")
                _skip_ws(state)
                pos = state["pos"]
                fr[2] = ks
                fr[1] = _MODE_TABLE_VAL
            elif mode == _MODE_TABLE_VAL:
                ks = fr[2]
                explicit_map = fr[3]

                top_k = ks[0]
                is_dotted = len(ks) > 1
                was_dotted = explicit_map.get(top_k)

                if was_dotted != None:
                    if not is_dotted:
                        _fail(state, "Duplicate key " + top_k)
                        return res
                    if not was_dotted:
                        _fail(state, "Key conflict " + top_k)
                        return res
                else:
                    explicit_map[top_k] = is_dotted
                is_nested = char in "[{"
                if is_nested:
                    if state["max_depth"] != None and len(stack) >= state["max_depth"]:
                        _fail(state, "Max nesting depth exceeded")
                        return res
                    val = [] if char == "[" else {}
                else:
                    val = _parse_val_nested(state)
                    pos = state["pos"]
                    if state["error"] != None:
                        return res

                # Insert val into dict
                current = cont
                for k in ks[:-1]:
                    # Intermediate keys are implicitly tables
                    if k not in current:
                        current[k] = {}
                    current = current[k]
                    if type(current) != "dict":
                        _fail(state, "Key conflict")
                        return res
                last_k = ks[-1]
                if last_k in current:
                    _fail(state, "Duplicate key %s" % last_k)
                    return res
                current[last_k] = val

                if is_nested:
                    # Push nested container
                    stack += [[val, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
                    fr[1] = _MODE_TABLE_COMMA
                    pos += 1  # consume [ or {
                    state["pos"] = pos
                else:
                    fr[1] = _MODE_TABLE_COMMA

            else:  # _MODE_TABLE_COMMA
                if char == "}":
                    fr[1] = _MODE_TABLE_KEY
                    continue
                if char == ",":
                    pos += 1
                    state["pos"] = pos
                    fr[1] = _MODE_TABLE_KEY
                    continue
                _fail(state, "Inline table comma expected")
    return res

def _parse_val_nested(state):
    """Parses a value when nested inside a complex iterative structure."""
    pos = state["pos"]
    data = state["data"]
    if data[pos] in ("\"", "'"):
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
    pos = state["pos"]
    if pos >= state["len"]:
        _fail(state, "Value expected at EOF")
        return None
    char = state["data"][pos]
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

def datetime_to_string(dt):
    """Converts a datetime/date/time struct to an ISO 8601 string.

    Args:
        dt: The struct to convert.

    Returns:
        String representation of the datetime.
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

    data = state["data"]
    length = state["len"]

    for _ in range(length * _MAX_ITERATIONS_MULTIPLIER):
        _skip_ws(state, skip_nl = True)
        pos = state["pos"]
        if pos >= length:
            break

        char = data[pos]
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
        pos = state["pos"]
        if pos < length:
            char = data[pos]
            if char != "\n" and char != "\r" and char != "#":
                _fail(state, "Expected newline or EOF")
                break

    if state["error"] != None:
        return default

    return _expand_to_toml_test(state["root"], len(data)) if expand_values else state["root"]

def _is_valid_codepoint(code):
    return (0 <= code and code <= 0x10FFFF) and not (0xD800 <= code and code <= 0xDFFF)

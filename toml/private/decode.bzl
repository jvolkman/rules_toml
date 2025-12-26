"""TOML decoder implementation for Starlark.

This module provides functions for parsing TOML documents into Starlark structures.
It is optimized for performance in the Starlark interpreter via several key strategies:

1. Performance Considerations:
   - Windowed String Operations: To avoid O(N) string slicing costs (which are
     inherent in Java-based Starlark strings), this parser uses small fixed-size
     windows (e.g., 64 bytes) for searches and `lstrip` calls. This prevents
     pathological O(N^2) behavior on large documents.
   - Iterative Design: Since Starlark disallows recursion, the parser is
     implemented iteratively with a manual stack. This also helps reduce
     function call overhead in hot loops.
   - Global Document Safety: An initial O(N) pass checks if the entire document is
     pure printable ASCII. If so, robust UTF-8 and control character validation
     is skipped, providing a significant speedup for common TOML files.
   - Operator Efficiency: Prefer built-in operators (e.g., `list += [item]`) over
     method calls (e.g., `list.append(item)`) as they are significantly faster
     in the Starlark interpreter.
"""

# --- Constants for Tokenization ---
_DIGITS = "0123456789_"
_HEX_DIGITS = "0123456789abcdefABCDEF_"
_OCT_DIGITS = "01234567_"
_BIN_DIGITS = "01_"

_BARE_KEY_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
_VALID_ASCII_CHARS = "\n\t !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

_MAX_ITERATIONS_MULTIPLIER = 5
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

def _parser(data, default, return_complex_types_as_string):
    """Initializes the parser state structure."""
    root_dict = {}
    return struct(
        pos = [0],
        len = len(data),
        data = data,
        root = root_dict,
        current_table = [root_dict],
        current_path = [[]],
        errors = _errors(),
        error = [None],
        is_safe = [False],
        has_default = default != None,
        path_types = {(): "table"},
        explicit_paths = {(): True},
        header_paths = {},
        return_complex_types_as_string = return_complex_types_as_string,
    )

def _fail(state, msg):
    """Reports a parsing error and fails the build unless a default is provided."""
    if state.error[0] == None:
        state.error[0] = msg

    if not state.has_default:
        fail(msg)

def _skip_ws(state):
    """Skips whitespace and comments in the input stream."""
    data = state.data
    length = state.len
    for _ in range(length):
        pos = state.pos[0]
        if pos >= length:
            break

        char = data[pos]
        if char == " " or char == "\t":
            state.pos[0] += 1

            # FAST PATH: If next char is not space/tab/comment, we are done
            # This handles most 'key = value' cases instantly.
            if pos + 1 < length:
                next_char = data[pos + 1]
                if next_char != " " and next_char != "\t" and next_char != "#":
                    return
            continue

        if char == "#":
            newline_pos = data.find("\n", pos)
            end = newline_pos if newline_pos != -1 else length

            comment = data[pos + 1:end]
            if not _validate_text(state, comment, "comment", allow_nl = False):
                break
            state.pos[0] = end
            continue
        break

def _expect(state, char):
    """Asserts that the next character in the stream is `char` and consumes it."""
    if state.error[0] != None:
        return
    if state.pos[0] >= state.len or state.data[state.pos[0]] != char:
        _fail(state, "Expected '%s' at %d" % (char, state.pos[0]))
        return
    state.pos[0] += 1

# --- Types & Validation ---

def _is_dict(value):
    """Returns True if the value is a dictionary."""
    return type(value) == "dict"

# buildifier: disable=list-append
def _validate_text(state, text, context, allow_nl = False):
    """Validates that text contains only valid TOML characters and UTF-8."""

    # GLOBAL FAST PATH: If the whole document was pre-validated as safe.
    if state.is_safe[0]:
        if not allow_nl and "\n" in text:
            _fail(state, "Control char in %s" % context)
            return False
        return True

    # Check for bare CR if allow_nl is False, or other simple constraints.

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
    if char == "b":
        return "\b"
    if char == "t":
        return "\t"
    if char == "n":
        return "\n"
    if char == "f":
        return "\f"
    if char == "r":
        return "\r"
    if char == "\\":
        return "\\"
    if char == "e":
        return json.decode('"\\u001b"')
    if char == '"':
        return '"'
    return None

# buildifier: disable=list-append
def _parse_basic_string(state):
    """Parses a basic string (double quoted)."""
    if state.pos[0] >= state.len or state.data[state.pos[0]] != '"':
        _fail(state, "Expected '\"' at %d" % state.pos[0])
        return ""
    state.pos[0] += 1

    if state.error[0] != None:
        return ""

    data = state.data
    length = state.len
    pos = state.pos[0]

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
        state.pos[0] = quote_idx + 1
        return chunk

    # SLOW PATH: Has escapes, process in chunks
    chars = []
    cached_quote_idx = quote_idx
    for _ in range(length * _MAX_ITERATIONS_MULTIPLIER):
        pos = state.pos[0]
        if pos >= length:
            _fail(state, "Unterminated string")
            return ""

        # Update cached search points if we've moved past them
        if pos > cached_quote_idx:
            cached_quote_idx = data.find('"', pos)
            if cached_quote_idx == -1:
                _fail(state, "Unterminated string")
                return ""

        # In SLOW path we always search for next escape bounded by the current quote
        escape_idx = data.find("\\", pos, cached_quote_idx)

        next_idx = cached_quote_idx
        is_esc = False
        if escape_idx != -1:
            next_idx = escape_idx
            is_esc = True

        if next_idx > pos:
            chunk = data[pos:next_idx]
            if not _validate_text(state, chunk, "string", allow_nl = False):
                return ""
            chars += [chunk]

        state.pos[0] = next_idx
        if not is_esc:
            state.pos[0] += 1
            return "".join(chars)

        # Handle escape
        state.pos[0] += 1
        if state.pos[0] >= length:
            _fail(state, "Unterminated string")
            return ""
        esc = data[state.pos[0]]
        state.pos[0] += 1
        sm = _escape_char(esc)
        if sm:
            chars += [sm]
            continue
        if esc == "x":
            hex_str = data[state.pos[0]:state.pos[0] + 2]
            if len(hex_str) == 2 and _is_hex(hex_str):
                chars += [_codepoint_to_string(int(hex_str, 16))]
                state.pos[0] += 2
                continue
        if esc == "u" or esc == "U":
            size = 4 if esc == "u" else 8
            hex_str = data[state.pos[0]:state.pos[0] + size]
            if len(hex_str) == size and _is_hex(hex_str):
                code = int(hex_str, 16)
                if (0 <= code and code <= 0x10FFFF) and not (0xD800 <= code and code <= 0xDFFF):
                    chars += [_codepoint_to_string(code)]
                    state.pos[0] += size
                    continue
        _fail(state, "Invalid escape")
        return ""
    return ""

def _parse_literal_string(state):
    """Parses a literal string (single quoted)."""
    _expect(state, "'")
    if state.error[0] != None:
        return ""
    pos = state.pos[0]
    data = state.data
    idx = data.find("'", pos)
    if idx == -1:
        _fail(state, "Unterminated literal string")
        return ""
    content = data[pos:idx]
    if not _validate_text(state, content, "literal string", allow_nl = False):
        return ""
    state.pos[0] = idx + 1
    return content

# buildifier: disable=list-append
def _parse_multiline_basic_string(state):
    """Parses a multiline basic string (triple quoted)."""
    state.pos[0] += 2
    if state.pos[0] < state.len and state.data[state.pos[0]] == "\n":
        state.pos[0] += 1

    chars = []
    d = state.data
    n = state.len
    for _ in range(n * _MAX_ITERATIONS_MULTIPLIER):
        p = state.pos[0]
        if p >= n:
            _fail(state, "Unterminated multiline string")
            return ""

        # Find next delimiter or next escape (bounded by delimiter)
        q_idx = d.find('"""', p)
        if q_idx == -1:
            _fail(state, "Unterminated multiline string")
            return ""

        e_idx = d.find("\\", p, q_idx)

        next_idx = q_idx
        is_esc = False
        if e_idx != -1:  # Guaranteed < q_idx by find bound
            next_idx = e_idx
            is_esc = True

        if next_idx > p:
            chunk = d[p:next_idx]
            if not _validate_text(state, chunk, "multiline string", allow_nl = True):
                return ""

            chars += [chunk]

        state.pos[0] = next_idx
        if not is_esc:
            # Handle potential trailing quotes
            state.pos[0] += 3
            ex = 0
            for _ in range(1, 3):
                if state.pos[0] < n and d[state.pos[0]] == '"':
                    ex += 1
                    state.pos[0] += 1
                else:
                    break
            for _ in range(ex):
                chars += ['"']
            return "".join(chars)

        # Handle escape
        state.pos[0] += 1
        if state.pos[0] >= n:
            break
        esc = d[state.pos[0]]
        if esc in " \t\n":
            # line-ending backslash
            tp = state.pos[0]
            hl = False

            # Scan for first newline
            for _ in range(n):
                if tp >= n:
                    break
                window = d[tp:tp + 64]
                stripped = window.lstrip(" \t")
                consumed = len(window) - len(stripped)
                tp += consumed
                if consumed < len(window):
                    break

            if tp < n and d[tp] == "\n":
                hl = True
                tp += 1

            if hl:
                # Skip all subsequent whitespace/newlines
                for _ in range(n):
                    if tp >= n:
                        break
                    window = d[tp:tp + 64]
                    stripped = window.lstrip(" \t\n")
                    consumed = len(window) - len(stripped)
                    tp += consumed
                    if consumed < len(window):
                        break
                state.pos[0] = tp
                continue
        sm = _escape_char(esc)
        if sm:
            chars += [sm]
            state.pos[0] += 1
            continue
        if esc in "uUx":
            sz = 2 if esc == "x" else (4 if esc == "u" else 8)
            state.pos[0] += 1
            hs = d[state.pos[0]:state.pos[0] + sz]
            if len(hs) == sz and _is_hex(hs):
                code = int(hs, 16)
                if (0 <= code and code <= 0x10FFFF) and not (0xD800 <= code and code <= 0xDFFF):
                    chars += [_codepoint_to_string(code)]
                    state.pos[0] += sz
                    continue
        _fail(state, "Invalid escape")
        return ""
    return ""

def _parse_multiline_literal_string(state):
    """Parses a multiline literal string (triple single-quoted)."""
    state.pos[0] += 2
    if state.pos[0] < state.len and state.data[state.pos[0]] == "\n":
        state.pos[0] += 1

    p = state.pos[0]
    d = state.data
    idx = d.find("'''", p)
    if idx == -1:
        _fail(state, "Unterminated multiline literal string")
        return ""

    # Handle potential trailing quotes
    ex = 0
    for _ in range(1, 3):
        if idx + 3 + _ <= state.len and d[idx + 3:idx + 3 + _] == "'" * _:
            ex = _
        else:
            break
    content = d[p:idx + ex]
    if not _validate_text(state, content, "multiline literal", allow_nl = True):
        return ""

    state.pos[0] = idx + 3 + ex
    return content

def _parse_string(state):
    """Dispatches to the appropriate string parsing function based on quotes."""
    p = state.pos[0]
    d = state.data
    if d[p] == '"':
        if p + 2 < state.len and d[p + 1:p + 3] == '""':
            state.pos[0] += 1
            return _parse_multiline_basic_string(state)
        return _parse_basic_string(state)
    if d[p] == "'":
        if p + 2 < state.len and d[p + 1:p + 3] == "''":
            state.pos[0] += 1
            return _parse_multiline_literal_string(state)
        return _parse_literal_string(state)
    return ""

def _parse_key(state):
    """Parses a TOML key (bare, basic, or literal)."""
    pos = state.pos[0]
    data = state.data
    if data[pos] == '"':
        if pos + 2 < state.len and data[pos + 1:pos + 3] == '""':
            _fail(state, "Multiline key not allowed")
            return ""
        return _parse_basic_string(state)
    if data[pos] == "'":
        if pos + 2 < state.len and data[pos + 1:pos + 3] == "''":
            _fail(state, "Multiline key not allowed")
            return ""
        return _parse_literal_string(state)

    # Hand-parse bare keys: [A-Za-z0-9_-]+
    start = pos

    # Use windowed lstrip to avoid character loop overhead
    # Bounded range to avoid allocation
    for _ in range(state.len):
        if pos >= state.len:
            break
        window = data[pos:pos + 64]
        stripped = window.lstrip(_BARE_KEY_CHARS)
        consumed = len(window) - len(stripped)
        pos += consumed
        if consumed < len(window):
            break

    if pos > start:
        key = data[start:pos]
        state.pos[0] = pos
        return key

    _fail(state, "Invalid key format")
    return ""

# buildifier: disable=list-append
def _parse_dotted_key(state):
    """Parses a dotted key into a list of components."""
    keys = []
    for _ in range(state.len):
        _skip_ws(state)
        k = _parse_key(state)
        if state.error[0] != None:
            return keys
        keys += [k]
        _skip_ws(state)
        if state.pos[0] < state.len and state.data[state.pos[0]] == ".":
            state.pos[0] += 1
            continue
        break
    return keys

def _get_or_create_table(state, keys, is_array):
    """Navigates to or creates the table structure specified by the dotted keys."""
    current = state.root
    path = []
    for i in range(len(keys) - 1):
        key = keys[i]
        path.append(key)
        path_tuple = tuple(path)
        if key in current:
            existing = current[key]
            existing_type = state.path_types.get(path_tuple)
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
            state.path_types[path_tuple] = "table"
    last_key = keys[-1]
    path.append(last_key)
    path_tuple = tuple(path)
    if is_array:
        existing_type = state.path_types.get(path_tuple)
        if existing_type and existing_type != "aot":
            _fail(state, "AOT conflict on %s" % last_key)
            return {}
        if last_key in current:
            current[last_key].append({})
            state.explicit_paths[path_tuple] = True
            state.header_paths[path_tuple] = True
            return current[last_key][-1]
        else:
            current[last_key] = [{}]
            state.path_types[path_tuple] = "aot"
            state.explicit_paths[path_tuple] = True
            state.header_paths[path_tuple] = True
            return current[last_key][0]
    elif last_key in current:
        if state.explicit_paths.get(path_tuple):
            _fail(state, "Redefinition of %s" % last_key)
            return {}
        existing_type = state.path_types.get(path_tuple)
        if existing_type != "table":
            _fail(state, "Table conflict on %s" % last_key)
            return {}
        state.explicit_paths[path_tuple] = True
        state.header_paths[path_tuple] = True
        return current[last_key]
    else:
        new_tab = {}
        current[last_key] = new_tab
        state.path_types[path_tuple] = "table"
        state.explicit_paths[path_tuple] = True
        state.header_paths[path_tuple] = True
        return new_tab

def _parse_table(state):
    """Parses a table header [foo.bar] or [[foo.bar]]."""
    _expect(state, "[")
    is_array_of_tables = False
    if state.pos[0] < state.len and state.data[state.pos[0]] == "[":
        is_array_of_tables = True
        state.pos[0] += 1
    keys = _parse_dotted_key(state)
    _expect(state, "]")
    if is_array_of_tables:
        _expect(state, "]")
    if state.error[0] != None:
        return
    state.current_path[0] = keys
    state.current_table[0] = _get_or_create_table(state, keys, is_array_of_tables)

def _parse_key_value(state, target):
    """Parses a key = value pair and inserts it into the target dictionary."""
    keys = _parse_dotted_key(state)
    if state.error[0] != None or not keys:
        return
    _skip_ws(state)
    _expect(state, "=")
    _skip_ws(state)
    value = _parse_value(state)
    if state.error[0] != None:
        return
    current = target
    base_path = state.current_path[0]
    for i in range(len(keys) - 1):
        key = keys[i]
        path_tuple = tuple(base_path + keys[:i + 1])
        if key in current:
            existing_type = state.path_types.get(path_tuple)
            if existing_type != "table":
                _fail(state, "KV traversal conflict with %s" % key)
                return
            if state.header_paths.get(path_tuple):
                _fail(state, "Cannot traverse header-defined table via dotted key %s" % key)
                return
            if existing_type == "table":
                state.explicit_paths[path_tuple] = True
            current = current[key]
        else:
            new_tab = {}
            current[key] = new_tab
            current = new_tab
            state.path_types[path_tuple] = "table"
            state.explicit_paths[path_tuple] = True
    last_key = keys[-1]
    last_path_tuple = tuple(base_path + keys)
    if last_key in current:
        _fail(state, "Duplicate key %s" % last_key)
        return
    current[last_key] = value
    state.path_types[last_path_tuple] = "inline" if type(value) == "dict" else ("array" if type(value) == "list" else "scalar")

def _parse_time_manual(state):
    """Manually parses a TOML time string (HH:MM:SS.ffffff) from the input."""
    pos = state.pos[0]
    data = state.data
    length = state.len
    if pos + 5 > length or not (data[pos].isdigit() and data[pos + 1].isdigit() and data[pos + 2] == ":" and data[pos + 3].isdigit() and data[pos + 4].isdigit()):
        return None
    timestr = data[pos:pos + 5]
    pos += 5
    if pos + 3 <= length and data[pos] == ":" and data[pos + 1].isdigit() and data[pos + 2].isdigit():
        timestr += data[pos:pos + 3]
        pos += 3
        if pos < length and data[pos] == ".":
            dp = pos
            pos += 1

            # Consume fractional digits
            rest = data[pos:]
            stripped = rest.lstrip("0123456789")
            consumed = len(rest) - len(stripped)

            if consumed == 0:
                _fail(state, "Fractional part must have digits")
                return None

            pos += consumed
            timestr += data[dp:pos]
    else:
        timestr += ":00"
    return timestr, pos - state.pos[0]

def _parse_scalar(state):
    """Parses simple scalar values like numbers, booleans, and dates."""
    pos = state.pos[0]
    data = state.data
    length = state.len

    # Fast-path Booleans
    if data[pos:pos + 4] == "true":
        state.pos[0] += 4
        return True
    if data[pos:pos + 5] == "false":
        state.pos[0] += 5
        return False

    # Fast-path Inf/NaN
    char = data[pos]
    if char == "n":
        if data[pos:pos + 3] == "nan":
            state.pos[0] += 3
            if state.return_complex_types_as_string:
                return "nan"
            return struct(toml_type = "float", value = "nan")
    elif char == "i":
        if data[pos:pos + 3] == "inf":
            state.pos[0] += 3
            if state.return_complex_types_as_string:
                return "inf"
            return struct(toml_type = "float", value = "inf")
    elif char == "+" or char == "-":
        if data[pos + 1:pos + 4] == "nan":
            state.pos[0] += 4
            if state.return_complex_types_as_string:
                return "nan"
            return struct(toml_type = "float", value = "nan")
        if data[pos + 1:pos + 4] == "inf":
            state.pos[0] += 4
            val = "-inf" if char == "-" else "inf"
            if state.return_complex_types_as_string:
                return val
            return struct(toml_type = "float", value = val)

    # Manual dispatch for scalars
    char = data[pos]

    # Hex/Oct/Bin
    # Hex/Oct/Bin
    if char == "0" and pos + 1 < length:
        next_char = data[pos + 1]
        if next_char == "x":
            # Hex
            # consume until non-hex
            # valid hex: 0-9 a-f A-F _
            # rough scan
            # Optimization: slice a window to avoid huge copy
            window = data[pos:min(length, pos + 64)]

            tail = window[2:].lstrip(_HEX_DIGITS)
            match_len = len(window) - len(tail)
            val = data[pos:pos + match_len]
            if not val or val[-1] == "_" or ("_" not in val and match_len == 2):
                return None
            if len(val) > 2 and val[2] == "_":
                return None
            state.pos[0] += match_len
            return int(val.replace("_", ""), 16)
        elif next_char == "o":
            window = data[pos:min(length, pos + 64)]
            tail = window[2:].lstrip(_OCT_DIGITS)
            match_len = len(window) - len(tail)
            val = data[pos:pos + match_len]
            if not val or val[-1] == "_" or ("_" not in val and match_len == 2):
                return None
            if len(val) > 2 and val[2] == "_":
                return None
            state.pos[0] += match_len
            return int(val.replace("_", ""), 8)
        elif next_char == "b":
            window = data[pos:min(length, pos + 64)]
            tail = window[2:].lstrip(_BIN_DIGITS)
            match_len = len(window) - len(tail)
            val = data[pos:pos + match_len]
            if not val or val[-1] == "_" or ("_" not in val and match_len == 2):
                return None
            if len(val) > 2 and val[2] == "_":
                return None
            state.pos[0] += match_len
            return int(val.replace("_", ""), 2)

    # Date vs Number
    # Dates start with digit.
    # Numbers start with digit or +/-.
    if char.isdigit() or char == "+" or char == "-":
        # Check for date: YYYY-MM-DD
        # Minimal check: \d{4}-

        # We peek 5 chars for date/time signature
        signature = data[pos:min(length, pos + 5)]
        is_date = False
        if len(signature) == 5 and signature[4] == "-" and signature[0].isdigit() and signature[1].isdigit() and signature[2].isdigit() and signature[3].isdigit():
            is_date = True

        if is_date:
            # Extract date string YYYY-MM-DD
            date_str = data[pos:pos + 10]
            if len(date_str) == 10 and date_str[4] == "-" and date_str[7] == "-" and date_str[:4].isdigit() and date_str[5:7].isdigit() and date_str[8:].isdigit():
                if not _validate_date(state, int(date_str[0:4]), int(date_str[5:7]), int(date_str[8:10])):
                    return None
                state.pos[0] += 10

                # Check for Time and Offset
                if state.pos[0] < length and data[state.pos[0]] in "Tt ":
                    separator = data[state.pos[0]]
                    state.pos[0] += 1
                    time_result = _parse_time_manual(state)
                    if time_result:
                        time_str, time_len = time_result
                        state.pos[0] += time_len

                        # Offset ...
                        # Reuse the logic from the old function?
                        # The old function had heavy nesting.
                        # Simplified:
                        if not _validate_time(state, int(time_str[0:2]), int(time_str[3:5]), int(time_str[6:8])):
                            return None

                        value_str = date_str + separator + time_str
                        if state.pos[0] < length:
                            if data[state.pos[0]] in "Zz":
                                state.pos[0] += 1
                                if state.return_complex_types_as_string:
                                    return (value_str + "Z")
                                return struct(toml_type = "datetime", value = (value_str + "Z").replace(" ", "T").replace("t", "T"))
                            if data[state.pos[0]] in "+-":
                                offset_str = data[state.pos[0]:state.pos[0] + 6]
                                if (len(offset_str) == 6 and offset_str[0] in "+-" and offset_str[1].isdigit() and offset_str[2].isdigit() and offset_str[3] == ":" and offset_str[4].isdigit() and offset_str[5].isdigit()):
                                    offset_hours = int(offset_str[1:3])
                                    offset_minutes = int(offset_str[4:6])
                                    if not _validate_offset(state, offset_hours, offset_minutes):
                                        return None
                                    state.pos[0] += 6
                                    if state.return_complex_types_as_string:
                                        return (value_str + offset_str)
                                    return struct(toml_type = "datetime", value = (value_str + offset_str).replace(" ", "T").replace("t", "T"))
                        if state.return_complex_types_as_string:
                            return value_str
                        return struct(toml_type = "datetime-local", value = value_str.replace(" ", "T").replace("t", "T"))
                    else:
                        state.pos[0] -= 1
                if state.return_complex_types_as_string:
                    return date_str
                return struct(toml_type = "date-local", value = date_str)

        # Time check
        if len(signature) >= 3 and signature[2] == ":":
            # Likely time "HH:MM"
            # 01234567
            # HH:MM:SS
            # HH:MM:SS.ffffff

            # Let's rely on _parse_time_manual logic but we need to invoke it.
            # Note: _parse_time_manual increments state.pos!
            # We should reset if it fails?

            old_pos = state.pos[0]
            time_result = _parse_time_manual(state)
            if time_result:
                time_str, time_len = time_result
                state.pos[0] = old_pos + time_len
                if not _validate_time(state, int(time_str[0:2]), int(time_str[3:5]), int(time_str[6:8])):
                    return None
                if state.return_complex_types_as_string:
                    return time_str
                return struct(toml_type = "time-local", value = time_str)
            state.pos[0] = old_pos

        # Number (Int or Float)
        # We must scan strictly to avoid consuming invalid sequences like "1e2.3" as a single chunk

        # 1. Integer part
        num_len = 0
        if data[pos] in "+-":
            num_len += 1

        # Consume integer digits
        # We use lstrip on a window from current pos
        w_start = pos + num_len
        if w_start < length:
            window = data[w_start:min(length, w_start + 64)]
            tail = window.lstrip(_DIGITS)

            # Digits consumed
            digits_len = len(window) - len(tail)
            num_len += digits_len

        # Check for fractional part
        is_float = False
        if pos + num_len < length and data[pos + num_len] == ".":
            # We must strict check: TOML requires digits after dot
            if pos + num_len + 1 < length and data[pos + num_len + 1].isdigit():
                is_float = True
                num_len += 1  # Consume '.'

                w_start = pos + num_len
                window = data[w_start:min(length, w_start + 64)]
                tail = window.lstrip(_DIGITS)
                frac_len = len(window) - len(tail)
                num_len += frac_len

        # Check for exponent
        # Check for exponent
        if pos + num_len < length and data[pos + num_len] in "eE":
            # We must check for optional sign then digits
            exp_len = 1
            idx = pos + num_len + 1
            if idx < length and data[idx] in "+-":
                exp_len += 1
                idx += 1

            # Check for digits
            if idx < length and data[idx].isdigit():
                is_float = True
                num_len += exp_len

                w_start = idx
                window = data[w_start:min(length, w_start + 64)]
                tail = window.lstrip(_DIGITS)
                exp_digits_len = len(window) - len(tail)
                num_len += exp_digits_len

        # Now we have the strictly scanned number string.
        val = data[pos:pos + num_len]

        # Sanity check: if we just matched a sign "+", that's not a number.
        if num_len == 0 or (num_len == 1 and val in "+-"):
            return None

        # Validate underscores and leading zeros
        check_val = val
        if check_val[0] in "+-":
            check_val = check_val[1:]

        if not check_val:
            return None

        if check_val[0] == "_" or check_val[-1] == "_" or "__" in check_val:
            return None  # Invalid structure

        # Validate integer start (must be digit, cannot be '.' or 'e')
        if not check_val[0].isdigit():
            return None

        # Leading zero check
        # If starts with 0, must be single "0" or followed by "." or "e/E".
        # "01" -> invalid. "0_1" -> invalid.
        if len(check_val) > 1 and check_val[0] == "0" and check_val[1] not in ".eE":
            return None

        if is_float:
            # Additional float validation
            if "_." in val or "._" in val or "_e" in val or "e_" in val or "_E" in val or "E_" in val:
                return None

            state.pos[0] += num_len
            return float(val.replace("_", ""))
        else:
            state.pos[0] += num_len
            return int(val.replace("_", ""))

    return None

_MODE_ARRAY_VAL = 1
_MODE_ARRAY_COMMA = 2
_MODE_TABLE_KEY = 3
_MODE_TABLE_VAL = 4
_MODE_TABLE_COMMA = 5

# buildifier: disable=list-append
def _parse_complex_iterative(state):
    """Parses inline tables and arrays iteratively using a manual stack."""
    char = state.data[state.pos[0]]
    res = [] if char == "[" else {}
    stack = [[res, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
    state.pos[0] += 1

    for _ in range(state.len * _MAX_ITERATIONS_MULTIPLIER):
        if not stack or state.error[0] != None:
            return res
        fr = stack[-1]
        cont = fr[0]
        mode = fr[1]
        _skip_ws_nl(state)
        if state.pos[0] >= state.len:
            _fail(state, "EOF in complex")
            return res
        char = state.data[state.pos[0]]
        if mode == _MODE_ARRAY_VAL:
            if char == "]":
                state.pos[0] += 1
                stack.pop()
                continue
            if char == "[" or char == "{":
                new_container = [] if char == "[" else {}
                cont += [new_container]
                state.pos[0] += 1
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
                state.pos[0] += 1
                fr[1] = _MODE_ARRAY_VAL
                continue
            _fail(state, "Array comma expected")
        elif mode == _MODE_TABLE_KEY:
            if char == "}":
                state.pos[0] += 1
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
                if state.error[0] != None:
                    return res
                lk = ks[-1]
                if lk in curr:
                    _fail(state, "Duplicate key %s" % lk)
                    return res
                explicit_map[tuple(ks)] = True
                curr[lk] = new_container
                state.pos[0] += 1
                stack += [[new_container, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
                fr[1] = _MODE_TABLE_COMMA
            else:
                val = _parse_val_nested(state)
                if state.error[0] != None:
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
                if state.error[0] != None:
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
                state.pos[0] += 1
                fr[1] = _MODE_TABLE_KEY
                continue
            _fail(state, "Inline table comma expected")
    return res

def _parse_val_nested(state):
    """Parses a value when nested inside a complex iterative structure."""
    pos = state.pos[0]
    data = state.data
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
        return {"type": "float", "value": str(v)}
    if t == "string":
        return {"type": "string", "value": v}
    if t == "struct":
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
    char = state.data[state.pos[0]]
    if char in "[{":
        return _parse_complex_iterative(state)
    if char in "\"'":
        return _parse_string(state)
    res = _parse_scalar(state)
    if res == None and state.error[0] == None:
        _fail(state, "Value expected")
    return res

def _is_globally_safe(data):
    """Returns True if the document is pure safe ASCII (0-127).

    This uses a single native lstrip pass. If the result is empty, the document
    is guaranteed to contain only printable ASCII and safe whitespace (Tab/NL).
    """
    return not data.lstrip(_VALID_ASCII_CHARS)

def decode(data, default = None, expand_values = False, return_complex_types_as_string = False):
    """Decodes a TOML string into a Starlark structure.

    Args:
      data: The TOML string to decode.
      default: Optional value to return if parsing fails. If None, the parser will fail.
      expand_values: If True, returns values in the toml-test JSON-compatible format
        (e.g., {"type": "integer", "value": "123"}).
      return_complex_types_as_string: If True, returns datetime, date, time, nan,
        and inf as raw strings instead of structs.

    Returns:
      The decoded Starlark structure (dict/list) or the default value on error.
    """

    # TOML allows parsers to normalize newlines. Doing it up front
    # significantly simplifies the rest of the parsing logic.
    data = data.replace("\r\n", "\n")
    state = _parser(data, default, return_complex_types_as_string)
    state.is_safe[0] = _is_globally_safe(data)

    # Process line by line (roughly)
    # The main loop needs to handle comments, empty lines, and table headers

    # We use a loop bounded by string length for safety
    for _ in range(state.len * _MAX_ITERATIONS_MULTIPLIER):
        _skip_ws(state)
        if state.pos[0] >= state.len:
            break

        char = state.data[state.pos[0]]

        if char == "\n":
            state.pos[0] += 1
            continue
        if char == "\r":
            _fail(state, "Bare CR invalid")
            break

        if char == "[":
            _parse_table(state)
            if state.error[0] != None:
                break
        else:
            _parse_key_value(state, state.current_table[0])
            if state.error[0] != None:
                break

        # Expect newline or EOF after a statement
        _skip_ws(state)
        if state.pos[0] < state.len:
            char = state.data[state.pos[0]]
            if char == "\n":
                state.pos[0] += 1
            elif char == "#":
                _skip_ws(state)  # handles comment until newline
            else:
                _fail(state, "Expected newline or EOF")
                break

    if state.error[0] != None:
        return default

    return _expand_to_toml_test(state.root, len(data)) if expand_values else state.root

def _skip_ws_nl(state):
    """Skips whitespace, comments, and newlines in the input stream."""
    data = state.data
    length = state.len

    # FAST PATH: Single ws/nl
    pos = state.pos[0]
    if pos < length:
        char = data[pos]
        if char in " \t\n":
            state.pos[0] = pos + 1
            if pos + 1 < length:
                nc = data[pos + 1]
                if nc not in " \t\n#":
                    return

    for _ in range(length):
        pos = state.pos[0]
        if pos >= length:
            break
        char = data[pos]
        if char == " " or char == "\t" or char == "\n":
            state.pos[0] += 1
            continue
        if char == "#":
            newline_pos = data.find("\n", pos)
            if newline_pos == -1:
                state.pos[0] = length
                break
            state.pos[0] = newline_pos
            continue
        break

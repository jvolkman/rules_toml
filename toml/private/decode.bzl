"""TOML decoder."""

load("@re.bzl", "re")

# --- Tokens ---
_RE_INTEGER = re.compile(r"^[+-]?(?:0|[1-9](?:[0-9]|_[0-9])*)")
_RE_HEX = re.compile(r"^0x[0-9a-fA-F]+(?:_[0-9a-fA-F]+)*")
_RE_OCT = re.compile(r"^0o[0-7]+(?:_[0-7]+)*")
_RE_BIN = re.compile(r"^0b[01]+(?:_[01]+)*")
_RE_FLOAT = re.compile(r"^[+-]?(?:0|[1-9](?:[0-9]|_[0-9])*)(?:\.[0-9](?:[0-9]|_[0-9])*)?(?:[eE][+-]?[0-9](?:[0-9]|_[0-9])*)?")
_RE_LOCAL_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}")

_DEL = "\177"
_MAX_ITERATIONS_MULTIPLIER = 5

# --- Status & Error Handling ---

def _errors():
    errors = []

    def add(msg):
        errors.append(msg)

    def get():
        return errors

    return struct(add = add, get = get)

def _parser(data, default):
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
        has_default = default != None,
        path_types = {(): "table"},
        explicit_paths = {(): True},
        header_paths = {},
    )

def _fail(state, msg):
    if not state.error[0]:
        state.error[0] = msg
    if not state.has_default:
        fail(msg)

def _has_error(state):
    return state.error[0] != None

def _skip_ws(state):
    d = state.data
    n = state.len
    for _ in range(n):
        p = state.pos[0]
        if p >= n:
            break
        c = d[p]
        if c == " " or c == "\t":
            state.pos[0] += 1
            continue
        if c == "#":
            nl = d.find("\n", p)
            end = nl if nl != -1 else n

            # If CRLF, the CR is part of the line break, not the comment content.
            comment_end = end
            if comment_end > p + 1 and d[comment_end - 1] == "\r":
                comment_end -= 1

            comment = d[p + 1:comment_end]
            if not _validate_text(state, comment, "comment", allow_nl = False):
                break
            state.pos[0] = end
            continue
        break

def _expect(state, char):
    if _has_error(state):
        return
    if state.pos[0] >= state.len or state.data[state.pos[0]] != char:
        _fail(state, "Expected '%s' at %d" % (char, state.pos[0]))
        return
    state.pos[0] += 1

# --- Types & Validation ---

def _is_dict(v):
    return type(v) == "dict"

def _validate_text(state, s, context, allow_nl = False):
    n = len(s)
    i = 0
    for _ in range(n):
        if i >= n:
            break
        c = s[i]

        blen = 0
        if c <= "\177":
            blen = 1
            if c == "\r":
                if i + 1 < n and s[i + 1] == "\n":
                    # Allow CRLF if it's a newline context
                    if not allow_nl:
                        _fail(state, "Control char in %s" % context)
                        return False
                elif allow_nl:  # Bare CR in multiline is bad
                    _fail(state, "Bare CR in %s" % context)
                    return False
                else:
                    _fail(state, "Control char in %s" % context)
                    return False
            elif (c < " " and c != "\t" and not (allow_nl and c == "\n")) or c == _DEL:
                _fail(state, "Control char in %s" % context)
                return False
        elif c >= "\302" and c <= "\337":
            blen = 2
        elif c >= "\340" and c <= "\357":
            blen = 3
            if c == "\355" and i + 1 < n:
                nc = s[i + 1]
                if nc >= "\240" and nc <= "\277":
                    _fail(state, "Surrogate in %s" % context)
                    return False
        elif c >= "\360" and c <= "\364":
            blen = 4
        else:
            _fail(state, "Invalid UTF-8 in %s" % context)
            return False

        if blen > 1:
            for j in range(1, blen):
                if i + j >= n or not (s[i + j] >= "\200" and s[i + j] <= "\277"):
                    _fail(state, "Truncated UTF-8 in %s" % context)
                    return False
        i += blen
    return True

def _is_hex(s):
    for i in range(len(s)):
        ch = s[i]
        if not ((ch >= "0" and ch <= "9") or (ch >= "a" and ch <= "f") or (ch >= "A" and ch <= "F")):
            return False
    return True

def _to_hex(val, width):
    s = "%x" % val
    return ("0" * (width - len(s))) + s if len(s) < width else s

def _codepoint_to_string(code):
    if code <= 0xFFFF:
        return json.decode('"\\u' + _to_hex(code, 4) + '"')
    v = code - 0x10000
    hi = 0xD800 + (v // 1024)
    lo = 0xDC00 + (v % 1024)
    return json.decode('"\\u' + _to_hex(hi, 4) + "\\u" + _to_hex(lo, 4) + '"')

def _is_leap(y):
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)

def _get_days_in_month(m, y):
    if m in [1, 3, 5, 7, 8, 10, 12]:
        return 31
    if m in [4, 6, 9, 11]:
        return 30
    if m == 2:
        return 29 if _is_leap(y) else 28
    return 0

def _validate_date(state, y, m, d):
    if y < 0 or y > 9999 or m < 1 or m > 12 or d < 1 or d > _get_days_in_month(m, y):
        _fail(state, "Invalid date: %d-%d-%d" % (y, m, d))
        return False
    return True

def _validate_time(state, h, m, s):
    if h < 0 or h > 23 or m < 0 or m > 59 or (s < 0 or s > 60):
        _fail(state, "Invalid time: %d:%d:%d" % (h, m, s))
        return False
    return True

def _validate_offset(state, h, m):
    if h < 0 or h > 23 or m < 0 or m > 59:
        _fail(state, "Invalid offset: %d:%d" % (h, m))
        return False
    return True

# --- String Parsing ---

def _escape_char(c):
    if c == "b":
        return "\b"
    if c == "t":
        return "\t"
    if c == "n":
        return "\n"
    if c == "f":
        return "\f"
    if c == "r":
        return "\r"
    if c == "\\":
        return "\\"
    if c == "e":
        return json.decode('"\\u001b"')
    if c == '"':
        return '"'
    return None

def _parse_basic_string(state):
    _expect(state, '"')
    if _has_error(state):
        return ""
    chars = []
    d = state.data
    n = state.len
    for _ in range(n):
        p = state.pos[0]
        if p >= n:
            _fail(state, "Unterminated string")
            return ""

        # Find next delimiter or escape
        q_idx = d.find('"', p)
        e_idx = d.find("\\", p)

        if q_idx == -1:
            _fail(state, "Unterminated string")
            return ""

        next_idx = q_idx
        is_esc = False
        if e_idx != -1 and e_idx < q_idx:
            next_idx = e_idx
            is_esc = True

        if next_idx > p:
            chunk = d[p:next_idx]
            if not _validate_text(state, chunk, "string", allow_nl = False):
                return ""
            chars.append(chunk)

        state.pos[0] = next_idx
        if not is_esc:
            state.pos[0] += 1
            return "".join(chars)

        # Handle escape
        state.pos[0] += 1
        if state.pos[0] >= n:
            _fail(state, "TLS")
            return ""
        esc = d[state.pos[0]]
        state.pos[0] += 1
        sm = _escape_char(esc)
        if sm:
            chars.append(sm)
            continue
        if esc == "x":
            h2 = d[state.pos[0]:state.pos[0] + 2]
            if len(h2) == 2 and _is_hex(h2):
                chars.append(_codepoint_to_string(int(h2, 16)))
                state.pos[0] += 2
                continue
        if esc == "u" or esc == "U":
            sz = 4 if esc == "u" else 8
            hx = d[state.pos[0]:state.pos[0] + sz]
            if len(hx) == sz and _is_hex(hx):
                code = int(hx, 16)
                if (0 <= code and code <= 0x10FFFF) and not (0xD800 <= code and code <= 0xDFFF):
                    chars.append(_codepoint_to_string(code))
                    state.pos[0] += sz
                    continue
        _fail(state, "Invalid escape")
        return ""
    return ""

def _parse_literal_string(state):
    _expect(state, "'")
    if _has_error(state):
        return ""
    p = state.pos[0]
    d = state.data
    idx = d.find("'", p)
    if idx == -1:
        _fail(state, "Unterminated literal string")
        return ""
    content = d[p:idx]
    if not _validate_text(state, content, "literal string", allow_nl = False):
        return ""
    state.pos[0] = idx + 1
    return content

def _parse_multiline_basic_string(state):
    state.pos[0] += 2
    if state.pos[0] < state.len and state.data[state.pos[0]] == "\n":
        state.pos[0] += 1
    elif state.pos[0] + 1 < state.len and state.data[state.pos[0]] == "\r" and state.data[state.pos[0] + 1] == "\n":
        state.pos[0] += 2

    chars = []
    d = state.data
    n = state.len
    for _ in range(n):
        p = state.pos[0]
        if p >= n:
            _fail(state, "Unterminated multiline string")
            return ""

        # Find next " or \
        q_idx = d.find('"""', p)
        e_idx = d.find("\\", p)

        if q_idx == -1:
            _fail(state, "Unterminated multiline string")
            return ""

        next_idx = q_idx
        is_esc = False
        if e_idx != -1 and e_idx < q_idx:
            next_idx = e_idx
            is_esc = True

        if next_idx > p:
            chunk = d[p:next_idx]
            if not _validate_text(state, chunk, "multiline basic", allow_nl = True):
                return ""

            # Normalize CRLF to LF, and check for bare CR (handled by _validate_text)
            chunk = chunk.replace("\r\n", "\n")
            chars.append(chunk)

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
                chars.append('"')
            return "".join(chars)

        # Handle escape
        state.pos[0] += 1
        if state.pos[0] >= n:
            break
        esc = d[state.pos[0]]
        if esc in " \t\r\n":
            # line-ending backslash
            tp = state.pos[0]
            hl = False

            # Scan for first newline
            for _ in range(n - tp):
                if tp >= n:
                    break
                if tp + 1 < n and d[tp] == "\r" and d[tp + 1] == "\n":
                    hl = True
                    tp += 2
                    break
                if d[tp] == "\n":
                    hl = True
                    tp += 1
                    break
                if d[tp] in " \t\r":
                    tp += 1
                else:
                    break
            if hl:
                # Skip all subsequent whitespace/newlines
                for _ in range(n - tp):
                    if tp >= n:
                        break
                    if tp + 1 < n and d[tp] == "\r" and d[tp + 1] == "\n":
                        tp += 2
                    elif d[tp] in " \t\n":
                        tp += 1
                    else:
                        break
                state.pos[0] = tp
                continue
        sm = _escape_char(esc)
        if sm:
            chars.append(sm)
            state.pos[0] += 1
            continue
        if esc in "uUx":
            sz = 2 if esc == "x" else (4 if esc == "u" else 8)
            state.pos[0] += 1
            hs = d[state.pos[0]:state.pos[0] + sz]
            if len(hs) == sz and _is_hex(hs):
                code = int(hs, 16)
                if (0 <= code and code <= 0x10FFFF) and not (0xD800 <= code and code <= 0xDFFF):
                    chars.append(_codepoint_to_string(code))
                    state.pos[0] += sz
                    continue
        _fail(state, "Invalid escape")
        return ""
    return ""

def _parse_multiline_literal_string(state):
    state.pos[0] += 2
    if state.pos[0] < state.len and state.data[state.pos[0]] == "\n":
        state.pos[0] += 1
    elif state.pos[0] + 1 < state.len and state.data[state.pos[0]] == "\r" and state.data[state.pos[0] + 1] == "\n":
        state.pos[0] += 2

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

    # Normalize CRLF to LF, and check for bare CR (handled by _validate_text)
    res = content.replace("\r\n", "\n")
    state.pos[0] = idx + 3 + ex
    return res

def _parse_string(state):
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
    p = state.pos[0]
    d = state.data
    if d[p] == '"':
        if p + 2 < state.len and d[p + 1:p + 3] == '""':
            _fail(state, "Multiline key not allowed")
            return ""
        return _parse_basic_string(state)
    if d[p] == "'":
        if p + 2 < state.len and d[p + 1:p + 3] == "''":
            _fail(state, "Multiline key not allowed")
            return ""
        return _parse_literal_string(state)
    p = state.pos[0]
    d = state.data
    n = state.len

    # Hand-parse bare keys: [A-Za-z0-9_-]+
    start = p
    for _ in range(n - p):
        if p >= n:
            break
        c = d[p]
        if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_" or c == "-":
            p += 1
            continue
        break

    if p > start:
        key = d[start:p]
        state.pos[0] = p
        return key

    _fail(state, "Invalid key format")
    return ""

def _parse_dotted_key(state):
    keys = []
    for _ in range(state.len):
        _skip_ws(state)
        k = _parse_key(state)
        if _has_error(state):
            return keys
        keys.append(k)
        _skip_ws(state)
        if state.pos[0] < state.len and state.data[state.pos[0]] == ".":
            state.pos[0] += 1
            continue
        break
    return keys

def _get_or_create_table(state, keys, is_array):
    curr = state.root
    path = []
    for i in range(len(keys) - 1):
        k = keys[i]
        path.append(k)
        tp = tuple(path)
        if k in curr:
            v = curr[k]
            etc = state.path_types.get(tp)
            if etc != "table" and etc != "aot":
                _fail(state, "Traversal conflict with %s" % k)
                return {}
            curr = v if etc == "table" else (v[-1] if v else None)
            if curr == None:
                _fail(state, "Empty AOT conflict")
                return {}
        else:
            new_tab = {}
            curr[k] = new_tab
            curr = new_tab
            state.path_types[tp] = "table"
    lk = keys[-1]
    path.append(lk)
    tp = tuple(path)
    if is_array:
        et = state.path_types.get(tp)
        if et and et != "aot":
            _fail(state, "AOT conflict on %s" % lk)
            return {}
        if lk in curr:
            curr[lk].append({})
            state.explicit_paths[tp] = True
            state.header_paths[tp] = True
            return curr[lk][-1]
        else:
            curr[lk] = [{}]
            state.path_types[tp] = "aot"
            state.explicit_paths[tp] = True
            state.header_paths[tp] = True
            return curr[lk][0]
    elif lk in curr:
        if state.explicit_paths.get(tp):
            _fail(state, "Redefinition of %s" % lk)
            return {}
        et = state.path_types.get(tp)
        if et != "table":
            _fail(state, "Table conflict on %s" % lk)
            return {}
        state.explicit_paths[tp] = True
        state.header_paths[tp] = True
        return curr[lk]
    else:
        new_tab = {}
        curr[lk] = new_tab
        state.path_types[tp] = "table"
        state.explicit_paths[tp] = True
        state.header_paths[tp] = True
        return new_tab

def _parse_table(state):
    _expect(state, "[")
    is_a = False
    if state.pos[0] < state.len and state.data[state.pos[0]] == "[":
        is_a = True
        state.pos[0] += 1
    ks = _parse_dotted_key(state)
    _expect(state, "]")
    if is_a:
        _expect(state, "]")
    if _has_error(state):
        return
    state.current_path[0] = ks
    state.current_table[0] = _get_or_create_table(state, ks, is_a)

def _parse_key_value(state, target):
    ks = _parse_dotted_key(state)
    if _has_error(state) or not ks:
        return
    _skip_ws(state)
    _expect(state, "=")
    _skip_ws(state)
    val = _parse_value(state)
    if _has_error(state):
        return
    curr = target
    base = state.current_path[0]
    for i in range(len(ks) - 1):
        k = ks[i]
        tp = tuple(base + ks[:i + 1])
        if k in curr:
            etc = state.path_types.get(tp)
            if etc != "table":
                _fail(state, "KV traversal conflict with %s" % k)
                return
            if state.header_paths.get(tp):
                _fail(state, "Cannot traverse header-defined table via dotted key %s" % k)
                return
            if etc == "table":
                state.explicit_paths[tp] = True
            curr = curr[k]
        else:
            new_tab = {}
            curr[k] = new_tab
            curr = new_tab
            state.path_types[tp] = "table"
            state.explicit_paths[tp] = True
    lk = ks[-1]
    ltp = tuple(base + ks)
    if lk in curr:
        _fail(state, "Duplicate key %s" % lk)
        return
    curr[lk] = val
    state.path_types[ltp] = "inline" if type(val) == "dict" else ("array" if type(val) == "list" else "scalar")

def _parse_time_manual(state):
    p = state.pos[0]
    d = state.data
    n = state.len
    if p + 5 > n or not (d[p].isdigit() and d[p + 1].isdigit() and d[p + 2] == ":" and d[p + 3].isdigit() and d[p + 4].isdigit()):
        return None
    v = d[p:p + 5]
    p += 5
    if p + 3 <= n and d[p] == ":" and d[p + 1].isdigit() and d[p + 2].isdigit():
        v += d[p:p + 3]
        p += 3
        if p < n and d[p] == ".":
            dp = p
            p += 1
            has_f = False
            for _ in range(n - p):
                if p < n and d[p].isdigit():
                    p += 1
                    has_f = True
                else:
                    break
            if not has_f:
                _fail(state, "Fractional part must have digits")
                return None
            v += d[dp:p]
    else:
        v += ":00"
    return v, p - state.pos[0]

def _parse_scalar(state):
    p = state.pos[0]
    d = state.data
    n = state.len

    # Fast-path Booleans
    if d[p:p + 4] == "true":
        state.pos[0] += 4
        return True
    if d[p:p + 5] == "false":
        state.pos[0] += 5
        return False

    # Fast-path Inf/NaN
    # Check for inf, nan, +inf, -inf, etc. without sub = d[p:]
    c = d[p]
    if c == "n":
        if d[p:p + 3] == "nan":
            state.pos[0] += 3
            return struct(toml_type = "float", value = "nan")
    elif c == "i":
        if d[p:p + 3] == "inf":
            state.pos[0] += 3
            return struct(toml_type = "float", value = "inf")
    elif c == "+" or c == "-":
        if d[p + 1:p + 4] == "nan":
            state.pos[0] += 4
            return struct(toml_type = "float", value = "nan")
        if d[p + 1:p + 4] == "inf":
            state.pos[0] += 4
            return struct(toml_type = "float", value = "-inf" if c == "-" else "inf")

    # For regex matching, use a window of 128 characters to avoid slicing the remainder of the file.
    # 128 is plenty for any valid TOML scalar (Dates, Floats, Hex, etc).
    window = d[p:p + 128]

    # Try Dates (Local Date)
    m = _RE_LOCAL_DATE.match(window)
    if m:
        ds = m.group()
        state.pos[0] += len(ds)
        if not _validate_date(state, int(ds[0:4]), int(ds[5:7]), int(ds[8:10])):
            return None
        if state.pos[0] < n and d[state.pos[0]] in "Tt ":
            sep = d[state.pos[0]]
            state.pos[0] += 1
            tr = _parse_time_manual(state)
            if tr:
                ts, tl = tr
                state.pos[0] += tl
                if not _validate_time(state, int(ts[0:2]), int(ts[3:5]), int(ts[6:8])):
                    return None
                vs = ds + sep + ts
                if state.pos[0] < n:
                    if d[state.pos[0]] in "Zz":
                        state.pos[0] += 1
                        return struct(toml_type = "datetime", value = (vs + "Z").replace(" ", "T").replace("t", "T"))
                    if d[state.pos[0]] in "+-":
                        ch = d[state.pos[0]:state.pos[0] + 6]
                        if (len(ch) == 6 and ch[0] in "+-" and ch[1].isdigit() and ch[2].isdigit() and ch[3] == ":" and ch[4].isdigit() and ch[5].isdigit()):
                            oh = int(ch[1:3])
                            om = int(ch[4:6])
                            if not _validate_offset(state, oh, om):
                                return None
                            state.pos[0] += 6
                            return struct(toml_type = "datetime", value = (vs + ch).replace(" ", "T").replace("t", "T"))
                return struct(toml_type = "datetime-local", value = vs.replace(" ", "T").replace("t", "T"))
            else:
                state.pos[0] -= 1
        return struct(toml_type = "date-local", value = ds)

    # Try Time (Local Time)
    tr = _parse_time_manual(state)
    if tr:
        ts, tl = tr
        state.pos[0] += tl
        if not _validate_time(state, int(ts[0:2]), int(ts[3:5]), int(ts[6:8])):
            return None
        return struct(toml_type = "time-local", value = ts)

    # Floats (checking '.' or 'e' to distinguish from integers)
    m = _RE_FLOAT.match(window)
    if m and ("." in m.group() or "e" in m.group() or "E" in m.group()):
        v = m.group()
        state.pos[0] += len(v)
        return float(v.replace("_", ""))

    # Integers (Hex, Oct, Bin, Dec)
    if window.startswith("0x"):
        m = _RE_HEX.match(window)
        if m:
            v = m.group()
            state.pos[0] += len(v)
            return int(v.replace("_", ""), 16)
    elif window.startswith("0o"):
        m = _RE_OCT.match(window)
        if m:
            v = m.group()
            state.pos[0] += len(v)
            return int(v.replace("_", ""), 8)
    elif window.startswith("0b"):
        m = _RE_BIN.match(window)
        if m:
            v = m.group()
            state.pos[0] += len(v)
            return int(v.replace("_", ""), 2)

    m = _RE_INTEGER.match(window)
    if m:
        v = m.group()
        state.pos[0] += len(v)
        return int(v.replace("_", ""))

    return None

_MODE_ARRAY_VAL = 1
_MODE_ARRAY_COMMA = 2
_MODE_TABLE_KEY = 3
_MODE_TABLE_VAL = 4
_MODE_TABLE_COMMA = 5

def _parse_complex_iterative(state):
    c = state.data[state.pos[0]]
    res = [] if c == "[" else {}
    stack = [[res, _MODE_ARRAY_VAL if c == "[" else _MODE_TABLE_KEY, None, {}]]
    state.pos[0] += 1
    for _ in range(state.len * _MAX_ITERATIONS_MULTIPLIER):
        if not stack or _has_error(state):
            break
        fr = stack[-1]
        cont = fr[0]
        mode = fr[1]
        inlines = fr[3]
        _skip_ws_nl(state)
        if state.pos[0] >= state.len:
            _fail(state, "EOF in complex")
            break
        c = state.data[state.pos[0]]
        if mode == _MODE_ARRAY_VAL:
            if c == "]":
                state.pos[0] += 1
                stack.pop()
                continue
            if c in "[{":
                nc = [] if c == "[" else {}
                cont.append(nc)
                state.pos[0] += 1
                stack.append([nc, _MODE_ARRAY_VAL if c == "[" else _MODE_TABLE_KEY, None, {}])
                fr[1] = _MODE_ARRAY_COMMA
                continue
            v = _parse_val_nested(state)
            if v != None:
                cont.append(v)
                fr[1] = _MODE_ARRAY_COMMA
                continue
            _fail(state, "Value expected in array")
        elif mode == _MODE_ARRAY_COMMA:
            if c == "]":
                fr[1] = _MODE_ARRAY_VAL
                continue
            if c == ",":
                state.pos[0] += 1
                fr[1] = _MODE_ARRAY_VAL
                continue
            _fail(state, "Array comma expected")
        elif mode == _MODE_TABLE_KEY:
            if c == "}":
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
            if c in "[{":
                nc = [] if c == "[" else {}
                curr = cont
                for i in range(len(ks) - 1):
                    k = ks[i]
                    if k in curr:
                        if not _is_dict(curr[k]):
                            _fail(state, "Inline traverse conflict with %s" % k)
                            return res
                        if inlines.get(k):
                            _fail(state, "Cannot add to closed inline table %s" % k)
                            return res
                        curr = curr[k]
                    else:
                        curr[k] = {}
                        curr = curr[k]
                if not _is_dict(curr):
                    _fail(state, "Inline terminal conflict on %s" % ks[-1])
                    return res
                if ks[-1] in curr:
                    _fail(state, "Duplicate complex key %s" % ks[-1])
                    return res
                curr[ks[-1]] = nc
                state.pos[0] += 1
                if c == "{":
                    inlines[ks[-1]] = True
                stack.append([nc, _MODE_ARRAY_VAL if c == "[" else _MODE_TABLE_KEY, None, {}])
                fr[1] = _MODE_TABLE_COMMA
                fr[2] = None
                continue
            v = _parse_val_nested(state)
            if v != None:
                curr = cont
                for i in range(len(ks) - 1):
                    k = ks[i]
                    if k in curr:
                        if not _is_dict(curr[k]):
                            _fail(state, "Inline traverse conflict with %s" % k)
                            return res
                        if inlines.get(k):
                            _fail(state, "Cannot add to closed inline table %s" % k)
                            return res
                        curr = curr[k]
                    else:
                        curr[k] = {}
                        curr = curr[k]
                if not _is_dict(curr):
                    _fail(state, "Inline terminal conflict on %s" % ks[-1])
                    return res
                if ks[-1] in curr:
                    _fail(state, "Duplicate scalar key %s" % ks[-1])
                    return res
                curr[ks[-1]] = v
                fr[1] = _MODE_TABLE_COMMA
                fr[2] = None
                continue
            _fail(state, "Value expected in table")
        elif mode == _MODE_TABLE_COMMA:
            if c == "}":
                fr[1] = _MODE_TABLE_KEY
                continue
            if c == ",":
                state.pos[0] += 1
                fr[1] = _MODE_TABLE_KEY
                continue
            _fail(state, "Table comma expected")
    return res

def _parse_val_nested(state):
    ch = state.data[state.pos[0]]
    if ch in "\"'":
        return _parse_string(state)
    return _parse_scalar(state)

def _skip_ws_nl(state):
    d = state.data
    n = state.len
    for _ in range(n):
        if state.pos[0] >= n:
            break
        c = d[state.pos[0]]
        if c in " \t":
            state.pos[0] += 1
            continue
        if c == "\n":
            state.pos[0] += 1
            continue
        if c == "\r":
            if state.pos[0] + 1 < n and d[state.pos[0] + 1] == "\n":
                state.pos[0] += 2
                continue
            else:
                _fail(state, "Bare CR in ws_nl")
                break
        if c == "#":
            for _ in range(n - state.pos[0]):
                if state.pos[0] >= n or d[state.pos[0]] == "\n":
                    break
                cc = d[state.pos[0]]
                if cc < " " and cc not in ["\n", "\t", "\r"]:
                    _fail(state, "Invalid comment cc")
                    break
                state.pos[0] += 1
            if _has_error(state):
                break
            continue
        break

def _format_scalar_for_test(v):
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
    root = {} if type(raw) == "dict" else []
    stack = [[raw, root]]
    for _ in range(size_hint * 2 + 100):
        if not stack:
            break
        r, t = stack.pop()
        if type(r) == "dict":
            for k, v in r.items():
                if type(v) in ["dict", "list"]:
                    t[k] = {} if type(v) == "dict" else []
                    stack.append([v, t[k]])
                else:
                    t[k] = _format_scalar_for_test(v)
        else:
            for v in r:
                if type(v) in ["dict", "list"]:
                    t.append({} if type(v) == "dict" else [])
                    stack.append([v, t[-1]])
                else:
                    t.append(_format_scalar_for_test(v))
    return root

def _parse_value(state):
    c = state.data[state.pos[0]]
    if c in "[{":
        return _parse_complex_iterative(state)
    if c in "\"'":
        return _parse_string(state)
    res = _parse_scalar(state)
    if res == None and not _has_error(state):
        _fail(state, "Value expected")
    return res

def decode_internal(data, default = None, expand_values = False):
    """Decodes a TOML string into a Starlark structure.

    Args:
      data: The TOML string to decode.
      default: Optional value to return if parsing fails. If None, the parser will fail.
      expand_values: If True, returns values in the toml-test JSON-compatible format
        (e.g., {"type": "integer", "value": "123"}).

    Returns:
      The decoded Starlark structure (dict/list) or the default value on error.
    """
    state = _parser(data, default)
    for _ in range(len(data) + 1):
        if _has_error(state):
            break
        _skip_ws(state)
        p = state.pos[0]
        if p >= state.len:
            break
        if state.data[p] == "\n":
            state.pos[0] += 1
            continue
        if state.data[p] == "\r":
            if p + 1 < state.len and state.data[p + 1] == "\n":
                state.pos[0] += 2
                continue
            else:
                _fail(state, "Bare CR in root")
                break
        if state.data[p] == "[":
            _parse_table(state)
        else:
            _parse_key_value(state, state.current_table[0])
        if _has_error(state):
            break
        _skip_ws(state)
        p2 = state.pos[0]
        if p2 < state.len:
            curr_c = state.data[p2]
            if curr_c == "\n":
                pass
            elif curr_c == "\r":
                if p2 + 1 < state.len and state.data[p2 + 1] == "\n":
                    pass
                else:
                    _fail(state, "Bare CR after pair")
                    break
            else:
                _fail(state, "Newline required after pair")
                break
    if _has_error(state):
        return default
    return _expand_to_toml_test(state.root, len(data)) if expand_values else state.root

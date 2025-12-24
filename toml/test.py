# Bazel compatability
from types import SimpleNamespace
struct = SimpleNamespace

def fail(msg):
    raise Exception(msg)







WS = " \t"
WS_AND_NEWLINE = WS + "\n"

ASCII_CTRL = "".join([chr(i) for i in range(32)] + [chr(127)])
ASCII_LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
DIGITS = "0123456789"
HEXDIGITS = "0123456789abcdefABCDEF"

# Neither of these sets include quotation mark or backslash. They are
# currently handled as separate cases in the parser functions.
ILLEGAL_BASIC_STR_CHARS = ASCII_CTRL.replace("\t", "")
ILLEGAL_MULTILINE_BASIC_STR_CHARS = ILLEGAL_BASIC_STR_CHARS.replace("\n", "")

ILLEGAL_LITERAL_STR_CHARS = ILLEGAL_BASIC_STR_CHARS
ILLEGAL_MULTILINE_LITERAL_STR_CHARS = ILLEGAL_MULTILINE_BASIC_STR_CHARS

ILLEGAL_COMMENT_CHARS = ILLEGAL_BASIC_STR_CHARS

BARE_KEY_CHARS = ASCII_LETTERS + DIGITS + "-_"

def _errors():
    errors = []

    def add(pos, fmt, *a, **kw):
        errors.append(struct(
            pos = pos,
            msg = fmt.format(*a, **kw),
        ))

    def get():
        return errors

def _buffer(data):
    """Returns an object that can peek and take characters from data."""
    pos_holder = [0]  # An array so we can update it.

    def length():
        return len(data)

    def pos():
        return pos_holder[0]

    def remaining():
        return length() - pos()

    def eof():
        return remaining() == 0

    def peek(count = 1):
        p = pos()
        return data[p:p + count]

    def skip(count = 1):
        pos_holder[0] = min(pos_holder[0] + count, length())

    def skip_chars(chars):
        # Returns number of characters skipped
        if type(chars) != "string":
            chars = "".join(chars)
        stripped = data[pos():].lstrip(chars)
        removed_count = length() - len(stripped)
        skip(removed_count)
        return removed_count

    def skip_until(sub):
        # Returns number of characters skipped
        start = pos()
        index = data.find(sub, pos())
        if index == -1:
            index = length()
        pos_holder[0] = index
        return index - start

    def slice():
        return data[pos():]

    def take(count = 1):
        val = peek(count)
        skip(count)
        return val

    def take_until(sub):
        start = pos()
        skip_until(sub)
        return data[start:pos()]

    return struct(
        eof = eof,
        length = length,
        peek = peek,
        pos = pos,
        remaining = remaining,
        skip = skip,
        skip_chars = skip_chars,
        skip_until = skip_until,
        take = take,
        take_until = take_until,
    )

def _skip_ws(buf, _errors):
    return bool(buf.skip_chars(WS))

def _skip_comment(buf, errors):
    if buf.peek() == "#":
        start = buf.pos()
        comment = buf.take_until("\n")
        for i, comment_char in enumerate(comment.elems()):
            if comment_char in ILLEGAL_COMMENT_CHARS:
                errors.add(start + i, "Illegal character in comment")
        return True
    return False

def _skip_ws_and_comments(buf, errors):
    for _ in range(buf.length()):
        skipped_ws = _skip_ws(buf, errors)
        skipped_comment = _skip_comment(buf, errors)
        if not skipped_ws and not skipped_comment:
            break

def _parse_basic_string(buf, errors):
    start = buf.peek(3)
    if not (start[0] == '"' and start != '"""'):
        return
    buf.skip()

# buildifier: disable=unused-variable
def decode_internal(data, default = None, expand_values = False):
    """Decode toml data.

    Args:
        data: the TOML data
        default: if not None, this value is returned if the data fails to parse.
        expand_values: if True, return values as a dict with "type" and "value" keys. Used
          for executing the toml test suite.
    Returns:
        the parsed data as a dict.
    """

    # The TOML spec allows normalizing newlines, even in multiline strings. So we always use unix-style.
    data = data.replace("\r\n", "\n")
    errors = _errors()
    buf = _buffer(data)

    # Skip any preliminary whitespace and comments
    _skip_ws_and_comments(buf, errors)


    td = "  abc 123"
    tdbuf = _buffer(td)
    print("len", tdbuf.length(), "pos", tdbuf.pos())
    tdbuf.skip(2)
    print("len", tdbuf.length(), "pos", tdbuf.pos())
    tdbuf.skip_chars(" ")
    print(tdbuf.peek(3))

    if data == None:
        fail("data is required")
    if default == None:
        fail("Not implemented!")
    return default

def decode(data, default = None):
    return decode_internal(data, default = default)


decode("foo")

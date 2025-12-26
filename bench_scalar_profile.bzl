load("@re.bzl", "re")

# Regex for integer (simplified from decode.bzl for fairness)
# ^[+-]?(?:0|[1-9](?:[0-9]|_[0-9])*)
_RE_INT = re.compile(r"^[+-]?(?:0|[1-9](?:[0-9]|_[0-9])*)")

def _manual_scan_int(s):
    # s is the string slice starting at current position
    n = len(s)
    if n == 0:
        return 0

    i = 0
    c = s[0]

    # Sign
    if c == "+" or c == "-":
        i = 1

    # Digits using lstrip
    # We take the substring from i.
    # "123".lstrip(...) -> "" -> len 0. consumed = len - 0 = 3.
    # "123a".lstrip(...) -> "a" -> len 1. consumed = len - 1 = 3.

    # Optimization: If the string is potentially long, slicing s[i:] might be copy heavy?
    # But usually tokens are short.

    remain = s[i:].lstrip("0123456789_")
    consumed = (n - i) - len(remain)

    if consumed == 0:
        return 0  # No digits

    length = i + consumed

    # Validation: lstrip allows underscores anywhere "___".
    # TOML requires digits between underscores.
    # For a "fast scanner", we might accept loose and let int() fail later?
    # Or strict check?
    # User's suggestion was lstrip.

    return length

def bench():
    data = [
        "12345",
        "+99",
        "-100200",
        "0",
        "1_000_000",
        "not_a_number",
        "123.456",
    ] * 100  # 700 items

    # 1. Regex
    # Run 100 times -> 70,000 checks
    for _ in range(100):
        for d in data:
            _RE_INT.match(d)

    # 2. Manual
    # Run 1000 times -> 700,000 checks (Manual should be much faster, so loop more to show up)
    for _ in range(1000):
        for d in data:
            _manual_scan_int(d)

bench()

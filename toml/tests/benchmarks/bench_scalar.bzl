load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//toml/private:decode.bzl", "decode")

# Existing regex from decode.bzl (copy-pasted for isolation if needed, or imported)
# We will simulate the scalar parsing logic.

def _manual_scan_int(s):
    # Simulate: ^[+-]?(?:0|[1-9](?:[0-9]|_[0-9])*)

    # Simple "is it an integer" check using lstrip
    # Note: real toml has underscores, signs, etc.
    # This benchmark compares the *mechanism* speed.

    # lstrip returns the REMAINING string.
    # consumed length = len(s) - len(rest)

    if not s:
        return None

    # 1. Sign
    start = 0
    if s[0] == "+" or s[0] == "-":
        start = 1

    # 2. Digits
    # We strip from the substring
    rest = s[start:].lstrip("0123456789_")

    consumed = len(s) - len(rest)
    if consumed == start:
        return None  # No digits found

    return s[:consumed]

def _regex_scan(s, regex):
    m = regex.match(s)
    if m:
        return m.group()
    return None

def bench_scalar_parsing(ctx):
    env = unittest.begin(ctx)

    # Setup data
    ints = ["123456", "99", "+100200300", "-0", "1_2_3"]
    floats = ["123.456", "0.0", "-1.5e10"]
    # We focus on INT parsing first as it's the most common

    load("@re.bzl", "re")

    _RE_INT = re.compile(r"^[+-]?(?:0|[1-9](?:[0-9]|_[0-9])*)")

    # Benchmark Registry
    # 1. Regex
    # 2. Manual (lstrip)
    # 3. Native int() try/except pattern (Simulated by checking digit)

    iterations = 5000

    # --- REGEX ---
    start = timestamp()  # fake timestamp, we rely on bazel profiler or simple loop count
    # Actually we can't get time in Starlark easily for measurement inside the test.
    # We usually rely on bazel --starlark_cpu_profile.

    # But we can just run a tight loop and see if it times out or just use the profile.

    for _ in range(iterations):
        for i in ints:
            _regex_scan(i, _RE_INT)

    # --- MANUAL ---
    for _ in range(iterations):
        for i in ints:
            _manual_scan_int(i)

    unittest.end(env)
    return []

# To truly measure this, we need a script that runs many times or uses the profile.
# I'll create a bench file similar to `bench_tuple_vm.bzl` in re.bzl

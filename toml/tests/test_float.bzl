"""Tests for float values (inf, nan) in toml.decode."""

load("@rules_testing//lib:unit_test.bzl", "unit_test")
load("//toml:toml.bzl", "decode", "encode")

def _test_float_special(env):
    toml_str = """
n = nan
i = inf
m_i = -inf
"""
    data = decode(toml_str)

    # inf / nan are ALWAYS native floats
    env.expect.that_str(type(data["n"])).equals("float")
    env.expect.that_str(str(data["n"])).equals("nan")

    env.expect.that_str(type(data["i"])).equals("float")
    env.expect.that_str(str(data["i"])).equals("+inf")

    env.expect.that_str(type(data["m_i"])).equals("float")
    env.expect.that_str(str(data["m_i"])).equals("-inf")

    # Round-trip verification
    encoded = encode(data)
    env.expect.that_str(encoded).contains("n = nan")
    env.expect.that_str(encoded).contains("i = inf")
    env.expect.that_str(encoded).contains("m_i = -inf")

    data_rt = decode(encoded)
    env.expect.that_str(str(data_rt["n"])).equals("nan")
    env.expect.that_str(str(data_rt["i"])).equals("+inf")
    env.expect.that_str(str(data_rt["m_i"])).equals("-inf")

def float_test_suite(name):
    unit_test(
        name = name,
        impl = _test_float_special,
    )

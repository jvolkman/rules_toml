"""Tests for the return_complex_types_as_string option in toml.decode."""

load("@rules_testing//lib:unit_test.bzl", "unit_test")
load("//toml:toml.bzl", "decode", "encode")

def _test_complex_string(env):
    toml_str = """
dt = 1979-05-27T07:32:00Z
dt_local = 1979-05-27T07:32:00
d = 1979-05-27
t = 07:32:00
n = nan
i = inf
m_i = -inf
"""

    # Test with flag enabled
    data = decode(toml_str, temporal_as_string = True)
    env.expect.that_str(data["dt"]).equals("1979-05-27T07:32:00Z")
    env.expect.that_str(data["dt_local"]).equals("1979-05-27T07:32:00")
    env.expect.that_str(data["d"]).equals("1979-05-27")
    env.expect.that_str(data["t"]).equals("07:32:00")

    # inf / nan are ALWAYS native floats now, ignoring temporal_as_string
    env.expect.that_str(type(data["n"])).equals("float")
    env.expect.that_str(type(data["i"])).equals("float")
    env.expect.that_str(type(data["m_i"])).equals("float")

    # Test with flag disabled (default)
    data_default = decode(toml_str)
    env.expect.that_str(data_default["dt"].toml_type).equals("datetime")

    # inf / nan are now native floats
    env.expect.that_str(type(data_default["n"])).equals("float")
    env.expect.that_str(str(data_default["n"])).equals("nan")

    env.expect.that_str(type(data_default["i"])).equals("float")
    env.expect.that_str(str(data_default["i"])).equals("+inf")

    env.expect.that_str(type(data_default["m_i"])).equals("float")
    env.expect.that_str(str(data_default["m_i"])).equals("-inf")

    # Round-trip verification
    encoded = encode(data_default)
    env.expect.that_str(encoded).contains("n = nan")
    env.expect.that_str(encoded).contains("i = inf")
    env.expect.that_str(encoded).contains("m_i = -inf")

    data_rt = decode(encoded)
    env.expect.that_str(str(data_rt["n"])).equals("nan")
    env.expect.that_str(str(data_rt["i"])).equals("+inf")
    env.expect.that_str(str(data_rt["m_i"])).equals("-inf")

def complex_string_test_suite(name):
    unit_test(
        name = name,
        impl = _test_complex_string,
    )

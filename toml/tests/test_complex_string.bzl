"""Tests for the return_complex_types_as_string option in toml.decode."""

load("@rules_testing//lib:unit_test.bzl", "unit_test")
load("//toml:toml.bzl", "decode")

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
    data = decode(toml_str, return_complex_types_as_string = True)
    env.expect.that_str(data["dt"]).equals("1979-05-27T07:32:00Z")
    env.expect.that_str(data["dt_local"]).equals("1979-05-27T07:32:00")
    env.expect.that_str(data["d"]).equals("1979-05-27")
    env.expect.that_str(data["t"]).equals("07:32:00")
    env.expect.that_str(data["n"]).equals("nan")
    env.expect.that_str(data["i"]).equals("inf")
    env.expect.that_str(data["m_i"]).equals("-inf")

    # Test with flag disabled (default)
    data_default = decode(toml_str)
    env.expect.that_str(data_default["dt"].toml_type).equals("datetime")
    env.expect.that_str(data_default["n"].toml_type).equals("float")

def complex_string_test_suite(name):
    unit_test(
        name = name,
        impl = _test_complex_string,
    )

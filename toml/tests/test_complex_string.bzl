"""Tests for the return_complex_types_as_string option in toml.decode."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//toml:toml.bzl", "decode")

def _test_complex_string_impl(ctx):
    env = unittest.begin(ctx)

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
    asserts.equals(env, "1979-05-27T07:32:00Z", data["dt"])
    asserts.equals(env, "1979-05-27T07:32:00", data["dt_local"])
    asserts.equals(env, "1979-05-27", data["d"])
    asserts.equals(env, "07:32:00", data["t"])
    asserts.equals(env, "nan", data["n"])
    asserts.equals(env, "inf", data["i"])
    asserts.equals(env, "-inf", data["m_i"])

    # Test with flag disabled (default)
    data_default = decode(toml_str)
    asserts.equals(env, "datetime", data_default["dt"].toml_type)
    asserts.equals(env, "float", data_default["n"].toml_type)

    return unittest.end(env)

complex_string_test = unittest.make(_test_complex_string_impl)

def complex_string_test_suite(name):
    unittest.suite(name, complex_string_test)

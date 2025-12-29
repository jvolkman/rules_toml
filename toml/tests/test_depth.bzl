"""Tests for max_depth and loop iteration bounds in toml.decode."""

load("@rules_testing//lib:unit_test.bzl", "unit_test")
load("//toml:toml.bzl", "decode", "encode")

def _test_max_depth(env):
    # Test valid nesting at default limit
    deep_toml = "a = " + "[" * 100 + "]" * 100

    # Should not fail
    decode(deep_toml)

    # Test failure at low limit
    low_depth_toml = "a = [[[1]]]"  # Depth 3

    # This should fail because we check len(stack) BEFORE pushing.
    # [ (len 0) -> [[ (len 1) -> [[[ (len 2)
    # If max_depth is 2, it should fail on the 3rd bracket.
    env.expect.that_str(decode(low_depth_toml, default = "fail", max_depth = 2)).equals("fail")

    # Verify success just inside limit
    env.expect.that_str(str(decode(low_depth_toml, max_depth = 3))).equals('{"a": [[[1]]]}')

    # Verify None disables limit
    env.expect.that_str(str(decode(low_depth_toml, max_depth = None))).equals('{"a": [[[1]]]}')

def _test_loop_bounds(env):
    # The current multiplier is 2.
    # Total iterations are bounded by 1.5 * L.
    # A single-line array with many elements should be fine.
    long_toml = "a = [" + ",".join(["1"] * 1000) + "]"

    # Length is approx 2007. Limit is 4014.
    # Should pass.
    data = decode(long_toml)
    env.expect.that_int(len(data["a"])).equals(1000)

def depth_test_suite(name):
    unit_test(
        name = name + "_max_depth",
        impl = _test_max_depth,
    )
    unit_test(
        name = name + "_loop_bounds",
        impl = _test_loop_bounds,
    )
    unit_test(
        name = name + "_encoder_max_depth",
        impl = _test_encoder_max_depth,
    )

def _test_encoder_max_depth(_env):
    # Test valid nesting
    deep_data = {"a": {"b": {"c": 1}}}
    decode(encode(deep_data))

    # Verify success with reasonable limit
    nested_tables = {"a": {"b": {"c": {"d": 1}}}}
    encode(nested_tables, max_tables = 100)

    # Verify success for inline arrays
    inline_array = {"a": [1, 2, 3]}
    encode(inline_array, max_tables = 100)

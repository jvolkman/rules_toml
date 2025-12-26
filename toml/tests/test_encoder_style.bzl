"""Unit tests for the TOML encoder style and basic functionality."""

load("@rules_testing//lib:unit_test.bzl", "unit_test")
load("//toml:toml.bzl", "decode", "encode")

def _test_encode_basic(env):
    data = {"key": "value", "int": 42, "bool": True, "float": 3.14}
    encoded = encode(data)

    # Keys are sorted
    expected = """
bool = true
float = 3.14
int = 42
key = "value"
""".strip()

    env.expect.that_str(encoded).equals(expected)

    decoded = decode(encoded)
    env.expect.that_dict(decoded).contains_exactly(data)

def _test_encode_nested_table(env):
    data = {
        "section": {
            "key": "value",
            "subset": {"a": 1},
        },
        "top": "val",
    }
    encoded = encode(data)

    # Simple keys first, then tables sorted by key
    # [section] comes before [section.subset]
    expected = """
top = "val"

[section]
key = "value"

[section.subset]
a = 1
""".strip()

    env.expect.that_str(encoded).equals(expected)

    decoded = decode(encoded)
    env.expect.that_dict(decoded).contains_exactly(data)

def _test_encode_array(env):
    data = {
        "arr": [1, 2, 3],
        "mixed": [1, "two", False],
    }
    encoded = encode(data)

    expected = """
arr = [1, 2, 3]
mixed = [1, "two", false]
""".strip()

    env.expect.that_str(encoded).equals(expected)

    decoded = decode(encoded)
    env.expect.that_dict(decoded).contains_exactly(data)

def _test_encode_inline_table(env):
    data = {"aot": [{"a": 1}, {"a": 2}]}
    encoded = encode(data)

    # Array of Tables
    # Encoder adds a leading newline for top-level tables/AOTs if no simple keys precede them.
    expected = "\n" + """
[[aot]]
a = 1

[[aot]]
a = 2
""".strip()

    env.expect.that_str(encoded).equals(expected)

    decoded = decode(encoded)
    env.expect.that_dict(decoded).contains_exactly(data)

def _test_encode_nested_aot(env):
    data = {"x": [{"y": [{"z": 1}]}]}
    encoded = encode(data)

    # Nested AOT
    expected = "\n" + """
[[x]]

[[x.y]]
z = 1
""".strip()

    env.expect.that_str(encoded).equals(expected)

    decoded = decode(encoded)
    env.expect.that_dict(decoded).contains_exactly(data)

def test_encoder_style_suite(name):
    """Instantiates the TOML encoder style tests.

    Args:
        name: Name of the test suite target.
    """
    tests = []

    unit_test(name = name + "_basic", impl = _test_encode_basic)
    tests.append(name + "_basic")

    unit_test(name = name + "_nested_table", impl = _test_encode_nested_table)
    tests.append(name + "_nested_table")

    unit_test(name = name + "_array", impl = _test_encode_array)
    tests.append(name + "_array")

    unit_test(name = name + "_inline_table", impl = _test_encode_inline_table)
    tests.append(name + "_inline_table")

    unit_test(name = name + "_nested_aot", impl = _test_encode_nested_aot)
    tests.append(name + "_nested_aot")

    native.test_suite(
        name = name,
        tests = tests,
    )

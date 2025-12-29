"""Compliance tests for the TOML encoder."""

load("@bazel_lib//lib:base64.bzl", "base64")
load("@rules_testing//lib:unit_test.bzl", "unit_test")
load("@toml_test_suite//:tests.bzl", "valid_cases")
load("//toml:toml.bzl", "decode", "encode")

def _compare_native(a, b, limit):
    """Deeply compares two Starlark values for equality.

    This custom comparison function is necessary for three reasons:
    1. **Starlark Recursion Limits**: Starlark does not support recursion. Deeply nested
       structures (like those found in strict compliance tests) must be traversed iteratively
       using a stack.
    2. **NaN Equality**: Standard equality `NaN == NaN` is False in Starlark (and IEEE 754).
       For verification purposes, we treat `NaN` as equal to itself to ensure round-trip correctness.
    3. **Strict Typing**: Ensures precise type matching (e.g., preventing implicit conversions).

    Args:
        a: First value
        b: Second value
        limit: Max number of iterations for safety
    """

    # Specialized iterative comparison to handle nan and other types
    stack = [(a, b)]

    # Bounded loop
    for _ in range(limit):
        if not stack:
            return True

        curr_a, curr_b = stack.pop()
        ta = type(curr_a)
        tb = type(curr_b)

        if ta != tb:
            return False

        if ta == "float":
            if curr_a != curr_a:  # nan
                if curr_b == curr_b:
                    return False
            elif curr_a != curr_b:
                return False

        elif ta == "dict":
            if len(curr_a) != len(curr_b):
                return False
            for k in curr_a:
                if k not in curr_b:
                    return False
                stack.append((curr_a[k], curr_b[k]))

        elif ta == "list":
            if len(curr_a) != len(curr_b):
                return False
            for i in range(len(curr_a)):
                stack.append((curr_a[i], curr_b[i]))

            # Structs (datetime)
        elif ta == "struct":
            # Compare by value equality
            if curr_a != curr_b:
                return False

        elif curr_a != curr_b:
            return False

    return True

def _test_encoder_compliance_impl(env, case):
    input_data = base64.decode(case.input_b64)
    native_data = decode(input_data)

    encoded = encode(native_data)

    # Round-trip verification: decode(encode(data)) == data
    decoded_again = decode(encoded)

    # Bounded loop limit
    limit = 1000000
    if not _compare_native(native_data, decoded_again, limit):
        env.fail("Encoder Round-Trip Mismatch for {}.\nOriginal: {}\nEncoded: {}\nDecoded: {}".format(
            case.name,
            native_data,
            encoded,
            decoded_again,
        ))

def _sanitize_name(name):
    res = ""
    for i in range(len(name)):
        c = name[i]
        if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_":
            res += c
        else:
            res += "_"
    return res

def test_compliance_encoder_suite(name):
    """Instantiates the TOML encoder compliance tests.

    Args:
        name: Name of the test suite target.
    """
    tests = []

    for case in valid_cases:
        t_name = name + "_" + _sanitize_name(case.name)
        _create_test(t_name, case, tests)

    native.test_suite(
        name = name,
        tests = tests,
    )

def _create_test(name, case, tests_list):
    def test_fn(env):
        _test_encoder_compliance_impl(env, case)

    unit_test(name = name, impl = test_fn)
    tests_list.append(name)

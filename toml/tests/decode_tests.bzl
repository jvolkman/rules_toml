"""Test rules to run the TOML test suite using rules_testing."""

load("@bazel_lib//lib:base64.bzl", "base64")
load("@rules_testing//lib:unit_test.bzl", "unit_test")
load("@toml_test_suite//:tests.bzl", "invalid_cases", "valid_cases")
load("//toml/private:decode.bzl", "decode_internal")

FAIL_DEFAULT = {"rules_toml_fail": True}

def _normalize_datetime(s):
    if "." not in s:
        return s
    dot_idx = s.find(".")
    end_idx = s.find("Z", dot_idx)
    if end_idx == -1:
        end_idx = s.find("+", dot_idx)
    if end_idx == -1:
        end_idx = s.find("-", dot_idx)
    if end_idx == -1:
        end_idx = len(s)
    prefix = s[:dot_idx + 1]
    frac = s[dot_idx + 1:end_idx].rstrip("0")
    suffix = s[end_idx:]
    if not frac:
        return s[:dot_idx] + suffix
    return prefix + frac + suffix

def _compare(a, b):
    stack = [(a, b)]
    for _ in range(100000):
        if not stack:
            return True
        curr_a, curr_b = stack.pop()
        if type(curr_a) != type(curr_b):
            return False
        if type(curr_a) == "dict":
            if "type" in curr_a and "value" in curr_a and len(curr_a) == 2:
                if curr_a["type"] != curr_b["type"]:
                    return False
                if curr_a["type"] == "float":
                    va, vb = curr_a["value"], curr_b["value"]
                    if va == vb:
                        continue
                    if va in ["inf", "+inf", "-inf", "nan"] or vb in ["inf", "+inf", "-inf", "nan"]:
                        return False
                    if float(va) != float(vb):
                        return False
                elif curr_a["type"] in ["datetime", "datetime-local", "time-local"]:
                    if _normalize_datetime(curr_a["value"]) != _normalize_datetime(curr_b["value"]):
                        return False
                elif curr_a["value"] != curr_b["value"]:
                    return False
            else:
                if len(curr_a) != len(curr_b):
                    return False
                for k in curr_a:
                    if k not in curr_b:
                        return False
                    stack.append((curr_a[k], curr_b[k]))
        elif type(curr_a) == "list":
            if len(curr_a) != len(curr_b):
                return False
            for i in range(len(curr_a)):
                stack.append((curr_a[i], curr_b[i]))
        elif curr_a != curr_b:
            return False
    return True

def _toml_test_node_impl(env, case, is_valid):
    input_data = base64.decode(case.input_b64)
    actual = decode_internal(input_data, default = FAIL_DEFAULT, expand_values = True)

    if is_valid:
        expected = json.decode(base64.decode(case.expected_b64))
        if not _compare(actual, expected):
            env.fail("Decode mismatch.\nExpected: {}\nActual: {}".format(expected, actual))
    elif actual != FAIL_DEFAULT:
        env.fail("Expected failure sentinel, but got: {}".format(actual))

def _sanitize_name(name):
    res = ""
    for i in range(len(name)):
        c = name[i]
        if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_":
            res += c
        else:
            res += "_"
    return res

def create_tests(name = "tests"):
    """Instantiates the TOML compliance test suite.

    Args:
      name: The name of the test suite.
    """
    test_targets = []

    for case in valid_cases:
        test_targets.append(_add_unit_test(case, is_valid = True))

    for case in invalid_cases:
        test_targets.append(_add_unit_test(case, is_valid = False))

    native.test_suite(
        name = name,
        tests = test_targets,
    )

def _add_unit_test(case, is_valid):
    name = "t_" + _sanitize_name(case.name)

    def test_fn(env):
        _toml_test_node_impl(env, case, is_valid)

    unit_test(name = name, impl = test_fn)
    return name

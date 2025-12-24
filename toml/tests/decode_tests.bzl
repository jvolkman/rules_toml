"""Test rules to run the TOML test suite."""

load("@bazel_lib//lib:base64.bzl", "base64")
load("@toml_test_suite//:tests.bzl", "invalid_cases", "valid_cases")
load("//toml/private:decode.bzl", "decode_internal")

FAIL_DEFAULT = {"rules_toml_fail": True}

VALID_TEST_TMPL = """\
#!/bin/sh
echo INPUT
echo =====
cat <<TOMLEOF
{input}
TOMLEOF
echo
echo EXPECTED
echo ========
cat <<TOMLEOF
{expected}
TOMLEOF
echo
echo ACTUAL
echo ======
cat <<TOMLEOF
{actual}
TOMLEOF
exit {exit}
"""

INVALID_TEST_TMPL = """\
#!/bin/sh
echo INPUT
echo =====
cat <<TOMLEOF
{input}
TOMLEOF
echo ACTUAL
echo ======
cat <<TOMLEOF
{actual}
TOMLEOF
exit {exit}
"""

def _is_dict(v):
    return type(v) == "dict"

def _is_list(v):
    return type(v) == "list"

def _normalize_datetime(s):
    # Normalize datetime string for comparison by ensuring 3 fractional digits if any,
    # or just removing trailing zeros from fractional part.
    # RFC 3339: ...HH:MM:SS[.frac][Z|offset]
    if "." not in s:
        return s

    # Simple normalization: trim trailing zeros in fractional part
    # Find . and then any digits before Z or + or -
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
    # Iterative comparison to handle large TOML files and avoid recursion
    stack = [(a, b)]
    for _ in range(100000):
        if not stack:
            return True
        curr_a, curr_b = stack.pop()

        if type(curr_a) != type(curr_b):
            return False

        if _is_dict(curr_a):
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
        elif _is_list(curr_a):
            if len(curr_a) != len(curr_b):
                return False
            for i in range(len(curr_a)):
                stack.append((curr_a[i], curr_b[i]))
        elif curr_a != curr_b:
            return False
    return True

def _success_test_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    input = base64.decode(ctx.attr.input_b64)
    expected_str = base64.decode(ctx.attr.expected_b64)
    expected = json.decode(expected_str)
    actual = decode_internal(input, default = FAIL_DEFAULT, expand_values = True)

    exit = "0" if _compare(actual, expected) else "1"
    ctx.actions.write(output = executable, content = VALID_TEST_TMPL.format(
        input = input,
        expected = expected_str,
        actual = actual,
        exit = exit,
    ))

    return [DefaultInfo(executable = executable)]

success_test = rule(
    implementation = _success_test_impl,
    attrs = {
        "input_b64": attr.string(mandatory = True),
        "expected_b64": attr.string(mandatory = True),
    },
    test = True,
)

def _failure_test_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    input = base64.decode(ctx.attr.input_b64)
    actual = decode_internal(input, default = FAIL_DEFAULT, expand_values = True)

    exit = "0" if actual == FAIL_DEFAULT else "1"
    ctx.actions.write(output = executable, content = INVALID_TEST_TMPL.format(
        input = input,
        actual = actual,
        exit = exit,
    ))

    return [DefaultInfo(executable = executable)]

failure_test = rule(
    implementation = _failure_test_impl,
    attrs = {
        "input_b64": attr.string(mandatory = True),
    },
    test = True,
)

def create_tests(name = "tests"):
    """Creates tests for all cases in the toml-test suite.

    Args:
      name: dummy name for macro compliance.
    """

    # buildifier: disable=unused-variable
    unused = name
    for case in valid_cases:
        success_test(
            name = "{}_test".format(case.name),
            input_b64 = case.input_b64,
            expected_b64 = case.expected_b64,
        )

    for case in invalid_cases:
        failure_test(
            name = "{}_test".format(case.name),
            input_b64 = case.input_b64,
        )

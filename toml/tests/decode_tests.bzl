"""Test rules to run the TOML test suite."""

load("//toml/private:decode.bzl", "decode_internal")
load("@aspect_bazel_lib//lib:base64.bzl", "base64")
load("@toml_test_suite//:tests.bzl", "invalid_cases", "valid_cases")

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

def _success_test_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    input = base64.decode(ctx.attr.input_b64)
    expected_str = base64.decode(ctx.attr.expected_b64)
    expected = json.decode(expected_str)
    actual = decode_internal(input, default = FAIL_DEFAULT, expand_values = True)

    exit = "0" if actual == expected else "1"
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

# buildifier: disable=unnamed-macro
def create_tests():
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

"""Smoke test for toml.bzl."""

load("@toml.bzl//:toml.bzl", "toml")

def _smoke_test_impl(ctx):
    data = toml.decode('key = "value"')
    if data["key"] != "value":
        fail("toml.decode failed")

    out = ctx.actions.declare_file(ctx.label.name + ".passed")
    ctx.actions.write(out, "passed")

    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows[platform_common.ConstraintValueInfo])
    if is_windows:
        script = ctx.actions.declare_file(ctx.label.name + ".bat")
        ctx.actions.write(script, "@echo off\r\necho passed", is_executable = True)
    else:
        script = ctx.actions.declare_file(ctx.label.name + ".sh")
        ctx.actions.write(script, "echo passed", is_executable = True)

    return [DefaultInfo(files = depset([out]), executable = script)]

smoke_test = rule(
    implementation = _smoke_test_impl,
    test = True,
    attrs = {
        "_windows": attr.label(default = "@platforms//os:windows"),
    },
)

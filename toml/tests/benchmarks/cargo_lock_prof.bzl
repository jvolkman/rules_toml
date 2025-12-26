"""Cargo.lock benchmarking"""
load("//toml:toml.bzl", "decode")
load(":cargo_lock_data.bzl", "CARGO_LOCK")

def _impl(ctx):
    for _ in range(5):
        decode(CARGO_LOCK)
    out = ctx.actions.declare_file(ctx.label.name + ".out")
    ctx.actions.write(out, "done")
    return [DefaultInfo(files = depset([out]))]

benchmark_runner = rule(
    implementation = _impl,
)

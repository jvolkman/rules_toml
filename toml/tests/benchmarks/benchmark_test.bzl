"""Benchmark test for the Starlark TOML decoder."""

load("@rules_testing//lib:unit_test.bzl", "unit_test")
load("//toml/tests/benchmarks:benchmarks.bzl", "run_benchmarks")

# buildifier: disable=unused-variable
def _benchmark_test_impl(env):
    # Run benchmarks with a large number of iterations
    # The time will be measured by Bazel
    run_benchmarks(n = 1000)

def benchmark_test(name):
    unit_test(
        name = name,
        impl = _benchmark_test_impl,
    )

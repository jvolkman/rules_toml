"""Benchmark test for the Starlark TOML decoder."""

load("@bazel_skylib//lib:unittest.bzl", "unittest")
load("//toml/tests/benchmarks:benchmarks.bzl", "run_benchmarks")

def _benchmark_test_impl(ctx):
    env = unittest.begin(ctx)

    # Run benchmarks with a large number of iterations
    # The time will be measured by Bazel
    run_benchmarks(n = 100000)

    return unittest.end(env)

benchmark_test = unittest.make(_benchmark_test_impl)

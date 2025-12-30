"""Benchmarking the range function."""

def run_range_benchmark(n):
    for _ in range(n):
        pass

def benchmark_range_creation(n):
    for _ in range(1000000):
        range(n)

def benchmark_list_iteration(items):
    for _ in items:
        pass

def _impl(ctx):
    # Iteration benchmark (Lazy Range)
    for _ in range(5):
        run_range_benchmark(1000000)

    # Materialized List iteration
    l_strict = list(range(1000000))
    for _ in range(5):
        benchmark_list_iteration(l_strict)

    out = ctx.actions.declare_file(ctx.label.name + ".out")
    ctx.actions.write(out, "done")
    return [DefaultInfo(files = depset([out]))]

range_benchmark = rule(
    implementation = _impl,
)

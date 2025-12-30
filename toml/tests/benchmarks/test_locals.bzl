"""Benchmarks for local variable vs dictionary access performance."""

def benchmark_dict_repeated_access(d, n):
    """Repeatedly access a dictionary key.

    Args:
        d: The dictionary to access.
        n: The number of iterations.
    """
    for _ in range(n):
        _ = d["a"]
        _ = d["a"]
        _ = d["a"]
        _ = d["a"]
        _ = d["a"]
        _ = d["a"]
        _ = d["a"]
        _ = d["a"]
        _ = d["a"]
        _ = d["a"]

def benchmark_local_repeated_access(d, n):
    """Access a dictionary key once and then use a local variable.

    Args:
        d: The dictionary to access.
        n: The number of iterations.
    """
    for _ in range(n):
        a = d["a"]
        _ = a
        _ = a
        _ = a
        _ = a
        _ = a
        _ = a
        _ = a
        _ = a
        _ = a
        _ = a

def _impl(ctx):
    d = {"a": 1}
    n = 100000

    # Warm up / Resolution
    for _ in range(20):
        benchmark_dict_repeated_access(d, n)
    for _ in range(20):
        benchmark_local_repeated_access(d, n)

    out = ctx.actions.declare_file(ctx.label.name + ".out")
    ctx.actions.write(out, "done")
    return [DefaultInfo(files = depset([out]))]

locals_benchmark = rule(
    implementation = _impl,
)

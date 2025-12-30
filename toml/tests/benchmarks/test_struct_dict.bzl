"""Benchmarking struct member vs dict key access."""

def benchmark_struct_list_mutation(s, n):
    """Benchmarks s.pos[0] += 1 where pos is a list in a struct."""
    for _ in range(n):
        s.pos[0] += 1

def benchmark_dict_int_mutation(d, n):
    """Benchmarks d['pos'] += 1 where pos is an int in a dict."""
    for _ in range(n):
        d["pos"] += 1

def benchmark_list_index_mutation(lst, n):
    """Benchmarks lst[0] += 1 where lst is a list."""
    for _ in range(n):
        lst[0] += 1

def _impl(ctx):
    s = struct(pos = [0])
    d = {"pos": 0}
    lst = [0]
    n = 1000000

    # Warm up / Resolution
    for _ in range(20):
        benchmark_struct_list_mutation(s, n)

    for _ in range(20):
        benchmark_dict_int_mutation(d, n)

    for _ in range(20):
        benchmark_list_index_mutation(lst, n)

    out = ctx.actions.declare_file(ctx.label.name + ".out")
    ctx.actions.write(out, "done")
    return [DefaultInfo(files = depset([out]))]

struct_dict_benchmark = rule(
    implementation = _impl,
)

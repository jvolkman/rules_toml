"""Benchmarks for the Starlark TOML decoder."""

load("//toml:toml.bzl", "decode")

def benchmark_simple_decode(n):
    content = 'key = "value"'
    for _ in range(n):
        decode(content)

def benchmark_complex_decode(n):
    content = """
    # This is a TOML document

    title = "TOML Example"

    [owner]
    name = "Tom Preston-Werner"
    dob = 1979-05-27T07:32:00-08:00

    [database]
    enabled = true
    ports = [ 8000, 8001, 8002 ]
    data = [ ["delta", "phi"], [3.14] ]
    temp_targets = { cpu = 79.5, case = 72.0 }

    [servers]

    [servers.alpha]
    ip = "10.0.0.1"
    role = "frontend"

    [servers.beta]
    ip = "10.0.0.2"
    role = "backend"
    """
    for _ in range(n):
        decode(content)

# buildifier: disable=print
def run_benchmarks(n = 0):
    """Runs all benchmarks.

    Args:
      n: Number of iterations.
    """
    print("Running simple_decode...")
    benchmark_simple_decode(n)
    print("Running complex_decode...")
    benchmark_complex_decode(n)

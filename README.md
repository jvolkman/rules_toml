# toml.bzl

A performance-optimized TOML 1.0.0 parser for Starlark.

## Usage

### In a `MODULE.bazel`

```starlark
bazel_dep(name = "toml.bzl", version = "0.1.0")
```

### In a `.bzl` file

```starlark
load("@toml.bzl", "toml")

content = """
[database]
server = "192.168.1.1"
ports = [ 8000, 8001, 8002 ]
"""

config = toml.decode(content)
print(config["database"]["server"])
```

Alternatively, you can load the `decode` function directly:

```starlark
load("@toml.bzl//toml", "decode")

config = decode("key = 'value'")
```

## Features

- **Spec Compliant**: Supports 100% of TOML 1.0.0.
- **Optimized**: Uses native Starlark string methods to minimize interpreter overhead.
- **Iterative**: Uses an iterative state machine to avoid Starlark's recursion limits.
- **Safe**: Bounded execution to prevent infinite loops in malformed files.

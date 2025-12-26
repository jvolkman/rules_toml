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

config = toml.decode("key = 'value'")

# Encoding
data = {
    "database": {
        "server": "192.168.1.1",
        "ports": [8000, 8001, 8002],
    }
}

content = toml.encode(data)
```

Alternatively, you can load the functions directly:

```starlark
load("@toml.bzl//toml", "decode", "encode")

config = decode("key = 'value'")
content = encode({"a": 1})
```

## Features

- **Spec Compliant**: Supports 100% of TOML 1.0.0 for both decoding and encoding.
- **Optimized**: Uses native Starlark string methods and operators to minimize interpreter overhead.
- **Recursion-Safe**: Uses iterative stack-based approaches to avoid Starlark's recursion limits.
- **Robust**: Built-in cycle detection and bounded execution.

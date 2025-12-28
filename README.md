# toml.bzl

A pure Starlark TOML 1.1.0 encoder and decoder.

## Usage

For full API documentation, see [the API Reference](docs/toml.md).

For installation instructions, see [Releases](https://github.com/jvolkman/toml.bzl/releases).

### In a `.bzl` file

```starlark
load("@toml.bzl", "toml")

content = """
[database]
server = "192.168.1.1"
ports = [ 8000, 8001, 8002 ]
"""

# Decode
config = toml.decode(content)
print(config["database"]["server"])

# Encode
encoded = toml.encode(config)
print(encoded)
```

## Performance

`toml.bzl` is highly optimized for the Starlark interpreter, leveraging native string operations to achieve high throughput while maintaining 100% compliance with TOML 1.1.0.

### Benchmarks

Tested on an **Apple M3 MacBook Pro**:

| Document Type      | Size   | Time       | Performance     |
| :----------------- | :----- | :--------- | :-------------- |
| **Cargo.lock**     | 1.5 MB | **180 ms** | ~8 MB/s         |
| **Scalar Parsing** | -      | -          | ~35,000 items/s |

### Compliance

The implementation is verified against the [toml-test](https://github.com/toml-lang/toml-test) suite, passing all compliance tests (decoding and encoding).

"Public API re-exports"

load("//toml:toml.bzl", _decode = "decode")

toml = struct(
    decode = _decode,
)

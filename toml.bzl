"Public API re-exports"

load("//toml:toml.bzl", _decode = "decode", _encode = "encode")

toml = struct(
    decode = _decode,
    encode = _encode,
)

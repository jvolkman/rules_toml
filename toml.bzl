"""Core TOML parsing and serialization library."""

load("//toml/private:decode.bzl", _decode = "decode")
load("//toml/private:encode.bzl", _encode = "encode")

toml = struct(
    decode = _decode,
    encode = _encode,
)

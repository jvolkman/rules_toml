"Public API re-exports"

load("//toml/private:decode.bzl", _decode = "decode")

toml = struct(
    decode = _decode,
)

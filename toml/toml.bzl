"Public API re-exports"

load("//toml/private:decode.bzl", _decode = "decode")
load("//toml/private:encode.bzl", _encode = "encode")

decode = _decode
encode = _encode

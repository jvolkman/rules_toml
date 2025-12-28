"""toml.bzl runtime dependencies."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", _http_archive = "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")

def http_archive(name, **kwargs):
    maybe(_http_archive, name = name, **kwargs)

def toml_bzl_dependencies():
    http_archive(
        name = "re.bzl",
        sha256 = "6aef17362025d1ec927776f7225c75401d5b3b9faa107ca314cbed0d452547a0",
        strip_prefix = "re.bzl-0.1.0",
        url = "https://github.com/jvolkman/re.bzl/releases/download/v0.1.0/re.bzl-v0.1.0.tar.gz",
    )

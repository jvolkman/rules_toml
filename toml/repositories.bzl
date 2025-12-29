"""toml.bzl runtime dependencies."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", _http_archive = "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")

def http_archive(name, **kwargs):
    maybe(_http_archive, name = name, **kwargs)

def toml_bzl_dependencies():
    http_archive(
        name = "re.bzl",
        sha256 = "f4f2aeb997101541885e5fdf7ce72ed60e543316a6153ed5457797eb48a01f15",
        strip_prefix = "re.bzl-0.2.0",
        url = "https://github.com/jvolkman/re.bzl/releases/download/v0.2.0/re.bzl-v0.2.0.tar.gz",
    )

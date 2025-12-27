"""Rule to download the TOML test suite and export its test cases."""

load("@bazel_lib//lib:base64.bzl", "base64")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "update_attrs")

TOML_VERSION = "1.1.0"

def _test_suite_impl(rctx):
    download_info = rctx.download_and_extract(
        rctx.attr.url,
        integrity = rctx.attr.integrity,
    )

    archive_dir = None
    test_dir = None
    for child in rctx.path("").readdir():
        if child.basename.startswith("toml-test"):
            archive_dir = child
            test_dir = archive_dir.get_child("tests")
            break

    if test_dir == None or not test_dir.exists:
        fail("Couldn't find extracted test suite directory")

    test_index = test_dir.get_child("files-toml-{}".format(TOML_VERSION))
    if not test_index.exists:
        fail("Test index file not found: {}".format(test_index))

    all_file_names = rctx.read(test_index).splitlines()

    # Strip out the json files; we assume they exist when creating the valid cases.
    test_file_names = [f for f in all_file_names if f.endswith(".toml")]
    valid_files = [test_dir.get_child(f) for f in test_file_names if f.startswith("valid/")]
    invalid_files = [test_dir.get_child(f) for f in test_file_names if f.startswith("invalid/")]

    def _relativize(path, start):
        path_str = str(path)
        start_str = str(start)
        if not path_str.startswith(start_str):
            fail("Path {} is not under {}".format(path_str, start_str))
        rel = path_str[len(start_str):]
        if rel.startswith("/"):
            rel = rel[1:]
        return rel

    def test_name(path):
        rel = _relativize(path, test_dir)
        rel = rel.replace(".toml", "")
        rel = rel.replace("/", "_")
        return rel

    bzl_lines = ["valid_cases = ["]
    for f in valid_files:
        name = test_name(f)
        expected = f.dirname.get_child(f.basename.replace(".toml", ".json"))
        if not expected.exists:
            fail("Expected file does not exist: {}".format(expected))
        bzl_lines.extend([
            "    struct(",
            '        name = "{}",'.format(name),
            '        input_b64 = "{}",'.format(base64.encode(rctx.read(f))),
            '        expected_b64 = "{}",'.format(base64.encode(rctx.read(expected))),
            "    ),",
        ])
    bzl_lines.append("]")
    bzl_lines.append("")
    bzl_lines.append("invalid_cases = [")
    for f in invalid_files:
        name = test_name(f)
        bzl_lines.extend([
            "    struct(",
            '        name = "{}",'.format(name),
            '        input_b64 = "{}",'.format(base64.encode(rctx.read(f))),
            "    ),",
        ])
    bzl_lines.append("]")
    rctx.file("tests.bzl", "\n".join(bzl_lines) + "\n")

    build_lines = [
        'exports_files(["tests.bzl"])',
    ]
    rctx.file(
        "BUILD.bazel",
        "\n".join(build_lines) + "\n",
    )

    integrity_override = {"integrity": download_info.integrity}
    return update_attrs(rctx.attr, _test_suite_attrs.keys(), integrity_override)

_test_suite_attrs = {
    "integrity": attr.string(
        doc = "The expected integrity string of the file downloaded.",
        mandatory = True,
    ),
    "url": attr.string(
        doc = "The archive URL.",
        mandatory = True,
    ),
}

test_suite = repository_rule(
    implementation = _test_suite_impl,
    attrs = _test_suite_attrs,
)

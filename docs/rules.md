<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API re-exports

<a id="toml.decode"></a>

## toml.decode

<pre>
load("@toml.bzl", "toml")

toml.decode(<a href="#toml.decode-data">data</a>, <a href="#toml.decode-default">default</a>, <a href="#toml.decode-expand_values">expand_values</a>)
</pre>

Decodes a TOML string into a Starlark structure.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="toml.decode-data"></a>data |  The TOML string to decode.   |  none |
| <a id="toml.decode-default"></a>default |  Optional value to return if parsing fails. If None, the parser will fail.   |  `None` |
| <a id="toml.decode-expand_values"></a>expand_values |  If True, returns values in the toml-test JSON-compatible format (e.g., {"type": "integer", "value": "123"}).   |  `False` |

**RETURNS**

The decoded Starlark structure (dict/list) or the default value on error.



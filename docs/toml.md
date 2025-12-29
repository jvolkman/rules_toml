<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Core TOML parsing and serialization library.

<a id="toml.decode"></a>

## toml.decode

<pre>
load("@toml.bzl", "toml")

toml.decode(<a href="#toml.decode-data">data</a>, *, <a href="#toml.decode-default">default</a>, <a href="#toml.decode-expand_values">expand_values</a>, <a href="#toml.decode-temporal_as_string">temporal_as_string</a>, <a href="#toml.decode-max_depth">max_depth</a>)
</pre>

Decodes a TOML string into a Starlark structure.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="toml.decode-data"></a>data |  The TOML string to decode.   |  none |
| <a id="toml.decode-default"></a>default |  Optional value to return if parsing fails. If None, the parser will fail.   |  `None` |
| <a id="toml.decode-expand_values"></a>expand_values |  If True, returns values in the toml-test JSON-compatible format (e.g., {"type": "integer", "value": "123"}).   |  `False` |
| <a id="toml.decode-temporal_as_string"></a>temporal_as_string |  If True, returns datetime, date, and time types as raw strings instead of structs.   |  `False` |
| <a id="toml.decode-max_depth"></a>max_depth |  Maximum nesting depth for arrays and inline tables. Pass None to disable.   |  `1024` |

**RETURNS**

The decoded Starlark structure (dict/list) or the default value on error.


<a id="toml.encode"></a>

## toml.encode

<pre>
load("@toml.bzl", "toml")

toml.encode(<a href="#toml.encode-data">data</a>, *, <a href="#toml.encode-max_tables">max_tables</a>)
</pre>

Encodes a Starlark dictionary into a TOML string.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="toml.encode-data"></a>data |  The dictionary to encode. Must be a top-level dictionary.   |  none |
| <a id="toml.encode-max_tables"></a>max_tables |  Maximum number of tables/iterations to process.   |  `1000000` |

**RETURNS**

A string containing the TOML representation of the data.



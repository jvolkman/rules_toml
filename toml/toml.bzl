"Public API re-exports"

load("//toml/private:decode.bzl", _decode = "decode")
load("//toml/private:encode.bzl", _encode = "encode")

def decode(data, default = None, expand_values = False, return_complex_types_as_string = False):
    """Decodes a TOML string into a Starlark structure.

    Args:
      data: The TOML string to decode.
      default: Optional value to return if parsing fails. If None, the parser will fail.
      expand_values: If True, returns values in the toml-test JSON-compatible format
        (e.g., {"type": "integer", "value": "123"}).
      return_complex_types_as_string: If True, returns datetime, date, time, nan,
        and inf as raw strings instead of structs.

    Returns:
      The decoded Starlark structure (dict/list) or the default value on error.
    """
    return _decode(data, default = default, expand_values = expand_values, return_complex_types_as_string = return_complex_types_as_string)

encode = _encode

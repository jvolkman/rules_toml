"""TOML decoder."""

# buildifier: disable=unused-variable
def decode_internal(data, default = None, expand_values = False):
    """Decode toml data.

    Args:
        data: the TOML data
        default: if not None, this value is returned if the data fails to parse.
        expand_values: if True, return values as a dict with "type" and "value" keys. Used
          for executing the toml test suite.
    Returns:
        the parsed data as a dict.
    """
    if data == None:
        fail("data is required")
    if default == None:
        fail("Not implemented!")
    return default

def decode(data, default = None):
    return decode_internal(data, default = default)

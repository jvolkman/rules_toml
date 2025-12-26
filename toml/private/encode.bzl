"""TOML Encoder implementation."""

# TOML Encoder
# Starlark implementation of a TOML encoder.
# Note: Recursion is not supported in Starlark, so we use iterative stack-based approaches.

def _escape_string(s):
    res = json.encode(s)

    # JSON allows raw DEL (0x7F), TOML forbids it.
    if "\177" in res:
        res = res.replace("\177", "\\u007F")
    return res

def _escape_key(k):
    # Simple keys don't need quotes if they match [A-Za-z0-9_-]+
    # Otherwise quote.
    if not k:
        return '""'
    for i in range(len(k)):
        c = k[i]
        if not (c.isalnum() or c == "-" or c == "_"):
            return _escape_string(k)
    return k

def _encode_scalar(v):
    t = type(v)
    if t == "string":
        return _escape_string(v)
    elif t == "int":
        return str(v)
    elif t == "bool":
        return "true" if v else "false"
    elif t == "float":
        if v == float("inf"):
            return "inf"
        if v == float("-inf"):
            return "-inf"
        if v != v:  # nan
            return "nan"
        return str(v)
    elif t == "struct":
        # Check for TOML special types (datetime, etc.)
        if hasattr(v, "toml_type") and hasattr(v, "value"):
            return str(v.value)
    fail("Unsupported scalar type: %s" % t)

def _encode_inline_array(arr, limit):
    # Iterative encoding for arrays/inline values.
    # Uses a stack to flatten the structure into tokens.

    tokens = []

    # Work stack: [item]
    # We maintain a list of items to process.
    # To output "[a, b]", we push "[", "a", ", ", "b", "]".
    # But since we pop from end, we push in reverse: "]", "b", ", ", "a", "[".

    work = [arr]

    # Bounded loop for safety. The limit is derived from the input size.
    for _ in range(limit):
        if not work:
            break

        item = work.pop()
        t = type(item)

        if t == "tuple" and item[0] == "OUT":
            tokens.append(item[1])
            continue

        if t == "list":
            # Array -> [ val, val ]
            work.append(("OUT", "]"))
            for i in range(len(item) - 1, -1, -1):
                work.append(item[i])
                if i > 0:
                    work.append(("OUT", ", "))
            work.append(("OUT", "["))

        elif t == "dict":
            # Inline Table -> { key = val, ... }
            work.append(("OUT", "}"))
            keys = sorted(item.keys())
            for i in range(len(keys) - 1, -1, -1):
                k = keys[i]
                work.append(item[k])
                work.append(("OUT", " = "))

                # We assume keys in inline tables should also be escaped if needed
                work.append(("OUT", _escape_key(k)))
                if i > 0:
                    work.append(("OUT", ", "))
            work.append(("OUT", "{"))

        elif t == "string" or t == "int" or t == "bool" or t == "float" or t == "struct":
            tokens.append(_encode_scalar(item))
        else:
            fail("Unable to encode type in inline structure: %s" % t)

    return "".join(tokens)

def _is_aot(v):
    if not v:
        return False
    for x in v:
        if type(x) != "dict":
            return False
    return True

def encode(data):
    """Encodes a Starlark dictionary into a TOML string.

    Args:
        data: The dictionary to encode. Must be a top-level dictionary.

    Returns:
        A string containing the TOML representation of the data.
    """
    if type(data) != "dict":
        fail("Root must be a dictionary")

    output = []

    # Detection of cycles and bound calculation
    # json.encode will fail if a cycle is detected.
    # The length of the JSON representation is a safe upper bound for
    # the number of nodes/iterations in the structure.
    json_repr = json.encode(data)
    limit = len(json_repr) + 100

    # Stack stores: (path_list, dict_node, is_aot)
    stack = [([], data, False)]

    # Max iterations safety
    for _ in range(limit):
        if not stack:
            break

        path, current, is_aot = stack.pop()

        keys = sorted(current.keys())

        simple_fields = []
        tables = []
        arrays_of_tables = []

        for k in keys:
            v = current[k]
            t = type(v)

            if t == "dict":
                tables.append((k, v))
            elif t == "list":
                if _is_aot(v):
                    arrays_of_tables.append((k, v))
                else:
                    simple_fields.append((k, v))
            else:
                simple_fields.append((k, v))

        # 1. Write Header
        if path:
            header = ".".join([_escape_key(p) for p in path])
            if is_aot:
                output.append("\n[[%s]]" % header)
            else:
                output.append("\n[%s]" % header)

        # 2. Write Simple Keys
        for k, v in simple_fields:
            if type(v) == "list":
                val_str = _encode_inline_array(v, limit)
            else:
                val_str = _encode_scalar(v)
            output.append("%s = %s" % (_escape_key(k), val_str))

        # 3. Queue Tables
        for i in range(len(tables) - 1, -1, -1):
            k, v = tables[i]
            new_path = path + [k]
            stack.append((new_path, v, False))

        # 4. Handle Array of Tables
        for i in range(len(arrays_of_tables) - 1, -1, -1):
            k, v_list = arrays_of_tables[i]
            for j in range(len(v_list) - 1, -1, -1):
                item = v_list[j]
                new_path = path + [k]
                stack.append((new_path, item, True))

    return "\n".join(output)

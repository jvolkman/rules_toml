# GEMINI.md - Starlark Performance & Parsing Notes

## Core Starlark Constraints

1.  **No `while` Loops**: Bazel's Starlark dialect does not support `while` loops or recursion.
    *   *Workaround*: Use `for _ in range(MAX_ITERATIONS):` with `break` for "bounded while" loops.
    *   *Strategy*: Design the parser to be linear single-pass or structured in hierarchical passes.

2.  **String Immutability & Concatenation**:
    *   Strings are immutable.
    *   Avoid repeated `s += part` in loops (O(N^2)).
    *   *Best Practice*: Collect parts in a list and use `"".join(parts)` at the end.

3.  **Function Call Overhead**:
    *   Starlark function calls have measurable overhead.
    *   *Optimization*: Inline simple logic where performance is critical (e.g., inside the inner character loop of a parser).

## Parsing Performance

1.  **Native String Methods**:
    *   Use `s.find()`, `s.rfind()`, `s.startswith()`, `s.endswith()`, `s.isdigit()` whenever possible.
    *   These run in Java/C++ native code and are significantly faster than iterating characters in Starlark.

2.  **Character Iteration**:
    *   Iterating a string (`for char in string:`) is slow in Starlark.
    *   *Alternative*: Tokenize with `split()` or regular expressions (if efficient native regex available, or `bazel-regex` if imported).
    *   *Alternative*: Use `partition()` to jump to delimiters.

3.  **List Comprehensions**:
    *   Generally faster than explicit `for` loops with `list.append()`.
    *   `[x for x in data if condition]` > `for loop + append`.

4.  **Structs vs Providers**:
    *   `struct()` is lightweight.
    *   Providers (`provider()`) are typed and better for rule interfaces but strictly immutable once created.

## Regex Considerations (bazel-regex)

*   **Thompson NFA**: Our `bazel-regex` library guarantees linear-time matching O(N), avoiding ReDoS.
*   **Cost**: Being pure Starlark, it has overhead per character step.
*   **Strategy**: Use regex for complex token patterns (dates, float literals) but use native string ops for structural boundaries (newlines, brackets, commas).

## TOML Specifics

*   TOML is line-oriented roughly, but nested structures (inline tables, arrays) cross lines.
*   **Tokenization**: Split by simple delimiters first, then refine.
*   **Lookahead**: Since we can't easily peek/backtrack efficiently, prefer a predictive parser or a robust tokenizer.

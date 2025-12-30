"""Core TOML parsing and serialization library."""

load(
    "//toml/private:decode.bzl",
    _LocalDate = "LocalDate",
    _LocalDateTime = "LocalDateTime",
    _LocalTime = "LocalTime",
    _OffsetDateTime = "OffsetDateTime",
    _datetime_to_string = "datetime_to_string",
    _decode = "decode",
)
load("//toml/private:encode.bzl", _encode = "encode")

toml = struct(
    decode = _decode,
    encode = _encode,
    OffsetDateTime = _OffsetDateTime,
    LocalDateTime = _LocalDateTime,
    LocalDate = _LocalDate,
    LocalTime = _LocalTime,
    datetime_to_string = _datetime_to_string,
)

"""Datetime constructors for TOML temporal types."""

def OffsetDateTime(year, month, day, hour, minute, second, microsecond = 0, offset_minutes = 0):
    return struct(
        _toml_type = "OffsetDateTime",
        year = year,
        month = month,
        day = day,
        hour = hour,
        minute = minute,
        second = second,
        microsecond = microsecond,
        offset_minutes = offset_minutes,
    )

def LocalDateTime(year, month, day, hour, minute, second, microsecond = 0):
    return struct(
        _toml_type = "LocalDateTime",
        year = year,
        month = month,
        day = day,
        hour = hour,
        minute = minute,
        second = second,
        microsecond = microsecond,
    )

def LocalDate(year, month, day):
    return struct(
        _toml_type = "LocalDate",
        year = year,
        month = month,
        day = day,
    )

def LocalTime(hour, minute, second, microsecond = 0):
    return struct(
        _toml_type = "LocalTime",
        hour = hour,
        minute = minute,
        second = second,
        microsecond = microsecond,
    )

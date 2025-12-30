"""Tests for temporal value (datetime) handling in toml.decode."""

load("@rules_testing//lib:unit_test.bzl", "unit_test")
load("//:toml.bzl", "toml")

def _test_datetime_default(env):
    # Default behavior: return structs
    data = toml.decode("d = 1979-05-27\nt = 07:32:00\ndt = 1979-05-27T07:32:00Z")

    d = data["d"]
    env.expect.that_str(d._toml_type).equals("LocalDate")
    env.expect.that_int(d.year).equals(1979)
    env.expect.that_int(d.month).equals(5)
    env.expect.that_int(d.day).equals(27)

    t = data["t"]
    env.expect.that_str(t._toml_type).equals("LocalTime")
    env.expect.that_int(t.hour).equals(7)
    env.expect.that_int(t.minute).equals(32)
    env.expect.that_int(t.second).equals(0)
    env.expect.that_int(t.microsecond).equals(0)

    dt = data["dt"]
    env.expect.that_str(dt._toml_type).equals("OffsetDateTime")
    env.expect.that_int(dt.year).equals(1979)
    env.expect.that_int(dt.offset_minutes).equals(0)

def _test_datetime_formatter(env):
    # Use datetime_to_string as formatter
    data = toml.decode(
        "dt = 1979-05-27T07:32:00.123-08:00",
        datetime_formatter = toml.datetime_to_string,
    )
    env.expect.that_str(data["dt"]).equals("1979-05-27T07:32:00.123-08:00")

    # Custom formatter
    def my_formatter(dt):
        if dt._toml_type == "LocalDate":
            return "DATE:%d" % dt.year
        return "OTHER"

    data = toml.decode("d = 1979-05-27", datetime_formatter = my_formatter)
    env.expect.that_str(data["d"]).equals("DATE:1979")

def _test_datetime_constructors(env):
    dt = toml.OffsetDateTime(2023, 12, 29, 15, 53, 0, 0, -480)
    env.expect.that_str(dt._toml_type).equals("OffsetDateTime")
    env.expect.that_int(dt.offset_minutes).equals(-480)
    env.expect.that_str(toml.datetime_to_string(dt)).equals("2023-12-29T15:53:00-08:00")

def _test_datetime_round_trip(env):
    # Ensure decode -> encode round-trips for all types
    toml_str = """
od = 1979-05-27T07:32:00.123-08:00
ld = 1979-05-27T07:32:00.456
d = 1979-05-27
t = 07:32:00.789
"""
    data = toml.decode(toml_str)
    encoded = toml.encode(data)

    # Standardized output might have some normalization (e.g. microseconds)
    # but should be semantically equivalent.
    data_again = toml.decode(encoded)
    env.expect.that_int(data_again["od"].microsecond).equals(123000)
    env.expect.that_int(data_again["ld"].microsecond).equals(456000)
    env.expect.that_int(data_again["t"].microsecond).equals(789000)
    env.expect.that_int(data_again["od"].offset_minutes).equals(-480)

def _test_datetime_to_string(env):
    # OffsetDateTime
    odt_z = toml.OffsetDateTime(1979, 5, 27, 7, 32, 0, 0, 0)
    env.expect.that_str(toml.datetime_to_string(odt_z)).equals("1979-05-27T07:32:00Z")

    odt_micros = toml.OffsetDateTime(1979, 5, 27, 7, 32, 0, 123000, 0)
    env.expect.that_str(toml.datetime_to_string(odt_micros)).equals("1979-05-27T07:32:00.123Z")

    odt_offset = toml.OffsetDateTime(1979, 5, 27, 7, 32, 0, 0, -480)
    env.expect.that_str(toml.datetime_to_string(odt_offset)).equals("1979-05-27T07:32:00-08:00")

    odt_offset_plus = toml.OffsetDateTime(1979, 5, 27, 7, 32, 0, 0, 120)
    env.expect.that_str(toml.datetime_to_string(odt_offset_plus)).equals("1979-05-27T07:32:00+02:00")

    # LocalDateTime
    ldt = toml.LocalDateTime(1979, 5, 27, 7, 32, 0, 0)
    env.expect.that_str(toml.datetime_to_string(ldt)).equals("1979-05-27T07:32:00")

    ldt_micros = toml.LocalDateTime(1979, 5, 27, 7, 32, 0, 456789)
    env.expect.that_str(toml.datetime_to_string(ldt_micros)).equals("1979-05-27T07:32:00.456789")

    # LocalDate
    ld = toml.LocalDate(1979, 5, 27)
    env.expect.that_str(toml.datetime_to_string(ld)).equals("1979-05-27")

    # LocalTime
    lt = toml.LocalTime(7, 32, 0, 0)
    env.expect.that_str(toml.datetime_to_string(lt)).equals("07:32:00")

    lt_micros = toml.LocalTime(7, 32, 0, 100)
    env.expect.that_str(toml.datetime_to_string(lt_micros)).equals("07:32:00.0001")

def datetime_test_suite(name):
    """Register the temporal (datetime) test suite.

    Args:
        name: Name of the test suite.
    """
    unit_test(
        name = name + "_default",
        impl = _test_datetime_default,
    )
    unit_test(
        name = name + "_formatter",
        impl = _test_datetime_formatter,
    )
    unit_test(
        name = name + "_constructors",
        impl = _test_datetime_constructors,
    )
    unit_test(
        name = name + "_round_trip",
        impl = _test_datetime_round_trip,
    )
    unit_test(
        name = name + "_to_string",
        impl = _test_datetime_to_string,
    )

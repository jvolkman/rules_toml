<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Core TOML parsing and serialization library.

<a id="toml.LocalDate"></a>

## toml.LocalDate

<pre>
load("@toml.bzl", "toml")

toml.LocalDate(<a href="#toml.LocalDate-year">year</a>, <a href="#toml.LocalDate-month">month</a>, <a href="#toml.LocalDate-day">day</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="toml.LocalDate-year"></a>year |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalDate-month"></a>month |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalDate-day"></a>day |  <p align="center"> - </p>   |  none |


<a id="toml.LocalDateTime"></a>

## toml.LocalDateTime

<pre>
load("@toml.bzl", "toml")

toml.LocalDateTime(<a href="#toml.LocalDateTime-year">year</a>, <a href="#toml.LocalDateTime-month">month</a>, <a href="#toml.LocalDateTime-day">day</a>, <a href="#toml.LocalDateTime-hour">hour</a>, <a href="#toml.LocalDateTime-minute">minute</a>, <a href="#toml.LocalDateTime-second">second</a>, <a href="#toml.LocalDateTime-microsecond">microsecond</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="toml.LocalDateTime-year"></a>year |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalDateTime-month"></a>month |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalDateTime-day"></a>day |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalDateTime-hour"></a>hour |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalDateTime-minute"></a>minute |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalDateTime-second"></a>second |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalDateTime-microsecond"></a>microsecond |  <p align="center"> - </p>   |  `0` |


<a id="toml.LocalTime"></a>

## toml.LocalTime

<pre>
load("@toml.bzl", "toml")

toml.LocalTime(<a href="#toml.LocalTime-hour">hour</a>, <a href="#toml.LocalTime-minute">minute</a>, <a href="#toml.LocalTime-second">second</a>, <a href="#toml.LocalTime-microsecond">microsecond</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="toml.LocalTime-hour"></a>hour |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalTime-minute"></a>minute |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalTime-second"></a>second |  <p align="center"> - </p>   |  none |
| <a id="toml.LocalTime-microsecond"></a>microsecond |  <p align="center"> - </p>   |  `0` |


<a id="toml.OffsetDateTime"></a>

## toml.OffsetDateTime

<pre>
load("@toml.bzl", "toml")

toml.OffsetDateTime(<a href="#toml.OffsetDateTime-year">year</a>, <a href="#toml.OffsetDateTime-month">month</a>, <a href="#toml.OffsetDateTime-day">day</a>, <a href="#toml.OffsetDateTime-hour">hour</a>, <a href="#toml.OffsetDateTime-minute">minute</a>, <a href="#toml.OffsetDateTime-second">second</a>, <a href="#toml.OffsetDateTime-microsecond">microsecond</a>, <a href="#toml.OffsetDateTime-offset_minutes">offset_minutes</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="toml.OffsetDateTime-year"></a>year |  <p align="center"> - </p>   |  none |
| <a id="toml.OffsetDateTime-month"></a>month |  <p align="center"> - </p>   |  none |
| <a id="toml.OffsetDateTime-day"></a>day |  <p align="center"> - </p>   |  none |
| <a id="toml.OffsetDateTime-hour"></a>hour |  <p align="center"> - </p>   |  none |
| <a id="toml.OffsetDateTime-minute"></a>minute |  <p align="center"> - </p>   |  none |
| <a id="toml.OffsetDateTime-second"></a>second |  <p align="center"> - </p>   |  none |
| <a id="toml.OffsetDateTime-microsecond"></a>microsecond |  <p align="center"> - </p>   |  `0` |
| <a id="toml.OffsetDateTime-offset_minutes"></a>offset_minutes |  <p align="center"> - </p>   |  `0` |


<a id="toml.datetime_to_string"></a>

## toml.datetime_to_string

<pre>
load("@toml.bzl", "toml")

toml.datetime_to_string(<a href="#toml.datetime_to_string-dt">dt</a>)
</pre>

Converts a datetime/date/time struct to an ISO 8601 string.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="toml.datetime_to_string-dt"></a>dt |  The struct to convert.   |  none |

**RETURNS**

String representation of the datetime.


<a id="toml.decode"></a>

## toml.decode

<pre>
load("@toml.bzl", "toml")

toml.decode(<a href="#toml.decode-data">data</a>, <a href="#toml.decode-default">default</a>, <a href="#toml.decode-datetime_formatter">datetime_formatter</a>, <a href="#toml.decode-max_depth">max_depth</a>, <a href="#toml.decode-expand_values">expand_values</a>)
</pre>

Decodes a TOML string into a Starlark structure.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="toml.decode-data"></a>data |  The TOML string to decode.   |  none |
| <a id="toml.decode-default"></a>default |  Optional default value to return on failure.   |  `None` |
| <a id="toml.decode-datetime_formatter"></a>datetime_formatter |  Optional function to format temporal values.   |  `None` |
| <a id="toml.decode-max_depth"></a>max_depth |  Maximum nesting depth for tables and arrays.   |  `128` |
| <a id="toml.decode-expand_values"></a>expand_values |  Whether to return a "toml-test" compatible format.   |  `False` |

**RETURNS**

The decoded Starlark structure, or the default value on failure.


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



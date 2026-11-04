# CEL support

OpenFGA conditions use a CEL subset implemented in PL/pgSQL. Expressions are compiled when a model is written. Unsupported syntax is rejected at that point.

## CEL subset

A parameter has one of these types: `bool`, `string`, `int`, `uint`, `double`, `duration`, `timestamp`, `ipaddress`, `any`, `list<T>` and `map<T>`. A `bytes` parameter is not valid.

An expression must give a `bool`. An expression can use these parts of CEL:

| Part | Supported |
| --- | --- |
| Literals | `int`, `uint`, `double`, `string`, `bool` and `null`, hexadecimal and exponent forms, raw strings, triple-quoted strings, list literals and map literals |
| Operators | `&&`, `\|\|`, `!`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `+`, `-`, `*`, `/`, `%`, `? :`, `in` and `[ ]` |
| Access | `map.key`, `has(map.key)` and `list[0]` |
| String functions | `size`, `contains`, `startsWith`, `endsWith` and `matches` |
| Conversions | `int`, `uint`, `double`, `string`, `bool`, `timestamp` and `duration` |
| Time | Timestamp and duration arithmetic, comparisons, and the getters, for example `getHours` and `getDayOfWeek`. A timestamp getter takes an optional time zone. |
| Macros | `all`, `exists`, `exists_one`, `map` and `filter` |
| Network | `ipaddress(string)` and `in_cidr(string)` |

The extension refuses these parts of CEL when you write the model, with error `openfga:2056`: `bytes`, `type()`, `dyn()`, protobuf messages and the optional syntax. The extension also refuses inline conditions (`$expression`), with error `openfga:2000`, as the default OpenFGA server does.

Some details are different from OpenFGA:

- `matches` supports a subset of [RE2 patterns](https://github.com/google/re2/wiki/Syntax). A dot excludes a newline; a leading `(?s)` makes it match newlines. Anchors, ordinary character classes and ranges, capturing and noncapturing groups, alternation, and common quantifiers work. Word boundaries (`\b`, `\B`) and shorthand classes such as `\w` use ASCII rules.
- Patterns are limited to 4,096 bytes and bounded repetitions to 255. Lookaround, backreferences, POSIX bracket classes, Unicode property escapes and inline flags other than a leading `(?s)` are unsupported. An invalid or unsupported pattern produces a condition evaluation error (`openfga:2000` if it determines the result).
- A timestamp has microsecond precision. Numeric offsets through ±23:59 are accepted. The resulting UTC instant must fall in years 0001–9999, including for typed context parameters; outside that range the condition reports an error.
- An integer overflow or a division by zero is an error. A `double` overflow or a division by zero is also an error. CEL gives infinity there.
- In a value of type `any`, and in a list or map literal of mixed types, a number is a `double`.
- An IPv6 address with a zone, such as `fe80::1%eth0`, is not valid.

These limits apply:

| Limit | Value |
| --- | --- |
| Length of an expression | 512 bytes |
| Parameters of one condition | 25 |
| Name of a condition or a parameter | 1 to 50 characters, without `:`, `#`, `@` or white space |
| Cost of one evaluation | 100 steps. The extension counts parameters, calls and loop steps. A more costly evaluation fails with error `openfga:2000`. |

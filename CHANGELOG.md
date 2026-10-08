# Changelog

## Unreleased

- Initial release.
- Codec constructors: `atom/1`, `enum/2`, `existing_atom/0`, `boolean/0`,
  `null/0`, `integer/1`, `float/0`, `binary/1`, `list/2`, `charlist/1`,
  `tuple/1`, `map/1`, `map_of/3`, `struct/2`, `one_of/1`, `tagged/2`,
  `iso/3`, `refine/3`, `from/2`, `field/1`, `lazy/1`, `bind/2`, `pure/1` and
  `tuple_seq/2`, with FIRST-set and value-shape checks when built.
- `decode/3`, `encode/2`, `project/2` and `conforms?/2`, with call-site
  limits (`Heddle.Limits`) and exact `Heddle.DecodeError` locations.
- `Heddle.Interpreter`, the reference semantics.
- `Heddle.Gen`, `Heddle.Laws` and `Heddle.Check` for property and
  differential testing; `Heddle.Lint` for unbounded positions.
- Compiled codecs: `Heddle.Schema` (`defcodec`, `defschema`, `defunion`),
  `@derive Heddle.Codec`, and `Heddle.Syntax` blocks compile to binary
  pattern matches at build time, with binding-time analysis of `bind`
  (finite, parameter and opaque binds) and pentiment diagnostics for every
  static check.
- SWAR scans for UTF-8 validation and STRING_EXT byte ranges.

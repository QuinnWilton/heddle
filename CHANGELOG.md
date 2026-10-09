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
  `@derive Heddle.Codec`, and `tuple_seq` blocks compile to binary
  pattern matches at build time, with binding-time analysis of `bind`
  (finite, parameter and opaque binds) and pentiment diagnostics for every
  static check.
- SWAR scans for UTF-8 validation and STRING_EXT byte ranges.
- Faster compiled codecs: decoding within 1.1-1.5x of `binary_to_term/2` and
  encoding at or below `term_to_binary/1` for struct, union and list
  payloads (`bench/ratios.exs`).
- Unions of structs laid out as maps: `one_of/1` dispatches on the
  `:__struct__` key wherever it sits in the map, reading what
  `term_to_binary/1` writes for structs.
- `Heddle.DSL`, the constructors ready to import, with the `tuple_seq`
  block form and infix `<~`. It replaces `Heddle.Syntax`. `use
  Heddle.Schema` imports it, so codecs read `list(integer(), max: 16)`.
- Struct codecs decode a missing field to the struct's own default when the
  struct does not enforce it (`@enforce_keys`) and the field's codec
  encodes that default, so terms written before a field was added still
  read. `nil` defaults need a codec that accepts `nil`.
- Struct defaults, explicit or from `defstruct`, are checked against their
  codec when it is built (H004), so a decoded struct always encodes again.
- A field `default: :__none__` is a default, not the absence of one.
- `Heddle.struct/2` raises H004 when its module is not a struct.
- The formatter exports `locals_without_parens` for `field`, `variant`,
  `defcodec`, `defschema`, `defunion`, `tuple_seq` and `pure`; add
  `import_deps: [:heddle]` to keep them paren-free.

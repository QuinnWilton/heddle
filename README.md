# Heddle

[![CI](https://github.com/QuinnWilton/heddle/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/heddle/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/heddle.svg)](https://hex.pm/packages/heddle)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/heddle)

Safe, bidirectional codecs for the Erlang external term format (ETF).
Heddle replaces `binary_to_term/2` and `term_to_binary/2` wherever the bytes
come from someone you don't trust.

## Why

Calling `binary_to_term` on untrusted input keeps causing vulnerabilities in
BEAM software:

- [CVE-2020-15150](https://nvd.nist.gov/vuln/detail/CVE-2020-15150):
  remote code execution in Paginator. It decoded pagination cursors with
  `binary_to_term/2` and the `:safe` option, which doesn't stop funs.
- [CVE-2026-48853](https://cna.erlef.org/cves/CVE-2026-48853.html):
  atom exhaustion and code execution in elixir-grpc's Erlpack codec, which
  decoded received messages with `binary_to_term/1`.

The `:safe` option only stops the creation of new atoms and new external
function references. As the
[EEF security guide](https://security.erlef.org/secure_coding_and_deployment_hardening/serialisation)
notes, it still decodes:

- Funs that refer to modules already loaded. They run attacker-chosen code
  when the application calls them.
- Struct injections. `%{__struct__: SomeLoadedModule}` uses only existing
  atoms, but it changes which protocol implementation runs.
- Forged pids, ports and references.
- Compressed terms that declare a huge inflated size.
- Huge bignums, and terms that are arbitrarily deep or wide.

## What Heddle does

You describe the data you expect, and Heddle builds a decoder and an encoder
from that one description. The decoder:

- Accepts only the terms the codec names.
- Never creates atoms, funs, pids, ports or references.
- Checks every length against the codec's bound and the input left, before
  allocating anything.
- Enforces limits on nesting depth and total terms, set per call.
- Reports the exact path and byte offset of the first problem.

The encoder fails on any value the decoder would reject, so what you send is
always something you can read back.

## Compatible with existing ETF

Heddle reads and writes ordinary ETF. Adopting it changes no bytes on the
wire, so you can switch one side of a connection at a time, and keep
reading data you stored before.

- **It reads what `term_to_binary` writes.** Every encoding OTP produces for
  the supported types is accepted: small and large atom tags, Latin-1 and
  UTF-8 atoms, `STRING_EXT` and `LIST_EXT` lists, every integer width, and
  map keys in any order.
- **It reads older producers.** The test suite decodes fixtures written by
  `term_to_binary/2` on OTP 24 through 29, including the
  `minor_version: 1` and `:deterministic` options.
- **It writes what `binary_to_term` reads.** Heddle's output is standard
  ETF, and the test suite checks that the VM decodes it to the same value.
- **It reads existing structs.** A struct codec that names every field
  reads the map `term_to_binary` writes for that struct. A choice between
  structs dispatches on the `:__struct__` key wherever it sits in the map.
- **It reads terms from before a field existed.** A missing field decodes
  to the struct's default, unless the struct enforces it. See
  [Missing fields](#missing-fields).

The supported types are atoms, booleans, `nil`, integers, floats, binaries,
lists, charlists, tuples, maps and structs. Heddle rejects the rest on
purpose:

- funs and external function references
- pids, ports and references
- compressed terms
- improper lists and bitstrings
- old-style floats (`FLOAT_EXT`), written only with `minor_version: 0`
- native records

## Installation

```elixir
def deps do
  [
    {:heddle, "~> 0.1.0"}
  ]
end
```

To format `field`, `variant` and the other macros without parentheses, add
Heddle to your `.formatter.exs`:

```elixir
[import_deps: [:heddle]]
```

## Usage

```elixir
defmodule MyApp.Session do
  use Heddle.Schema

  defschema do
    field :user_id, integer(min: 1)
    field :roles, list(enum([:admin, :editor, :viewer]), max: 16)
    field :expires_at, integer(min: 0)
    field :meta, map_of(binary(max_size: 64), binary(max_size: 256), max: 32), default: %{}
  end
end

{:ok, iodata} = Heddle.encode(MyApp.Session.codec(), session)

{:ok, %MyApp.Session{}} =
  Heddle.decode(MyApp.Session.codec(), bin, max_depth: 8, max_nodes: 1_000)
```

`use Heddle.Schema` imports the constructors from `Heddle.DSL`. Anywhere
else, `import Heddle.DSL` does the same. `Heddle.struct/2` is the one
constructor you always write qualified, since `Kernel.struct/2` has its
name.

There are two ways to get a codec:

- **Compiled.** `defschema`, `defunion`, `defcodec` and
  `@derive Heddle.Codec` compile codecs to binary pattern matches when your
  project builds.
- **Built at runtime.** Calling the constructors in a function, such as
  `list(integer())`, gives a codec that runs in an interpreter with the
  same behaviour.

### Tagged unions

```elixir
defmodule MyApp.Shape do
  use Heddle.Schema

  defunion do
    variant :empty
    variant :circle, radius: integer(min: 1)
    variant :rect, width: integer(min: 1), height: integer(min: 1)
  end
end

{:ok, _} = Heddle.encode(MyApp.Shape.codec(), {:rect, 3, 4})
```

- Each variant is a tag followed by its fields, written `name: codec`.
- A variant with no fields is the bare atom, such as `:empty`.
- A variant with fields is a tuple of the tag and the field values in
  order, such as `{:circle, radius}` or `{:rect, width, height}`.
- The field names document each position. The values themselves carry no
  names.

### Unions built from other codecs

A module name in a field stands for that module's codec. That module can be
a schema, a union or a derived struct, so a union can carry structs, lists
of structs, and itself:

```elixir
defmodule MyApp.Point do
  use Heddle.Schema

  defschema as: :tuple, tag: :point do
    field :x, integer(min: -10_000, max: 10_000)
    field :y, integer(min: -10_000, max: 10_000)
  end
end

defmodule MyApp.Drawing do
  use Heddle.Schema

  defunion do
    variant :empty
    variant :circle, center: MyApp.Point, radius: integer(min: 1)
    variant :polygon, points: list(MyApp.Point, max: 64)
    variant :group, shapes: list(MyApp.Drawing, max: 16)
  end
end

drawing = {:group, [{:circle, %MyApp.Point{x: 0, y: 0}, 5}, :empty]}
{:ok, iodata} = Heddle.encode(MyApp.Drawing.codec(), drawing)
```

- Each module's codec is compiled once, and the others call it.
- `:group` nests drawings as deep as the call's `max_depth` allows.
- Every list is bounded by its `max:`.
- `MyApp.Point` uses the tuple layout, so a point is `{:point, x, y}` on the
  wire.

### Unions of structs

Structs laid out as maps need no tag. A choice between them finds the
`:__struct__` key wherever it sits in the map, so it decodes what
`term_to_binary` already writes for structs:

```elixir
defcodec account do
  one_of([MyApp.User, MyApp.Org])
end
```

### Structs you own, and structs you don't

For your own structs, derive the codec where the struct is defined:

```elixir
defmodule MyApp.User do
  import Heddle.DSL

  @derive {Heddle.Codec, fields: [id: integer(min: 1), name: binary(max_size: 100, utf8: true)]}
  defstruct [:id, :name, :cache]
end
```

For a struct from another library, define a codec and name it where you use
it:

```elixir
defmodule MyApp.Codecs do
  use Heddle.Schema

  defcodec uri do
    Heddle.struct(URI, fields: [scheme: binary(max_size: 16), host: binary(max_size: 253)])
  end
end
```

Deriving for a struct you don't own would be global, so two libraries
deriving different bounds for `URI` would conflict.

A struct field you leave out of `fields:`, like `:cache` above, is not
serialized:

- Encoding never writes it.
- Decoding rejects input that contains it, and fills it from the struct's
  default.
- To read structs that `term_to_binary` already wrote, name every field.

### Missing fields

A struct laid out as a map may be missing a field. That happens with terms
written before the field was added. Heddle fills a missing field when
either:

- the field gives its own default, as `name: {codec, default: value}`; or
- the struct doesn't list the field in `@enforce_keys`, and the field's
  codec can encode the struct's default for it.

```elixir
defmodule MyApp.Account do
  import Heddle.DSL

  @enforce_keys [:id]
  @derive {Heddle.Codec,
           fields: [
             id: integer(min: 1),
             plan: enum([:free, :pro]),
             email: one_of([null(), binary(max_size: 254)]),
             name: binary(max_size: 100)
           ]}
  defstruct [:id, :email, :name, plan: :free]
end
```

- `id` is required, because the struct enforces it.
- `plan` may be missing, and decodes to `:free`.
- `email` may be missing, and decodes to `nil`, since its codec accepts
  `nil`.
- `name` is required. Its default is `nil`, which `binary()` can't encode,
  and a decoded struct must always encode again.

A struct laid out as a tuple requires every field.

### Fields that depend on other fields

```elixir
defmodule MyApp.Envelope do
  use Heddle.Schema

  defcodec codec do
    tuple_seq tag: :envelope do
      version <- integer(min: 1, max: 2) <~ field(:version)
      body <- (case version do
                 1 -> binary(max_size: 1024)
                 2 -> MyApp.Shape.codec()
               end) <~ field(:body)
      pure %{version: version, body: body}
    end
  end
end
```

- Each `var <- codec` step decodes one tuple element and names its value.
- `codec <~ field(:key)` says which part of the value the step encodes.
- `pure` ends the block with the decoded result.

The compiler looks at how each step uses earlier values:

- A step that depends on a value with few possibilities, like `version`
  here, compiles once per value.
- A step that uses an earlier value only as a bound, such as a list's
  `max:`, compiles once and receives the bound at runtime.
- Anything else runs in the interpreter, and the compiler warns about it.

### Errors

```elixir
{:error,
 %Heddle.DecodeError{
   path: [:roles, 3],
   offset: 41,
   reason: :unexpected,
   expected: [{:atom, :admin}, {:atom, :editor}, {:atom, :viewer}],
   found: {:small_atom_utf8, "root"}
 }}
```

- Choice is deterministic, so the first failure is the only one, and its
  location is exact.
- `found` quotes at most 64 bytes of input, so logging an error never copies
  attacker-sized data.
- An invalid codec is a compile error rendered by
  [pentiment](https://hex.pm/packages/pentiment), with every codec involved
  labelled in your source.

### Testing

- `Heddle.Gen.from/1` derives StreamData generators from a codec.
- `Heddle.Laws` checks that values round-trip through a codec.
- `Heddle.Check` compares Heddle with `binary_to_term(bin, [:safe])`, and
  compiled codecs with the interpreter.
- `Heddle.lint/1` reports positions the codec leaves unbounded.

## Performance

`mix run bench/ratios.exs` reports each compiled codec's time as a multiple
of the BIF it replaces. Lower is better, and below 1.00x is faster than the
BIF. These are medians on an Apple M1 Max, with Elixir 1.20.4 on OTP 29.1:

| Payload | decode vs `binary_to_term(b, [:safe])` | encode vs `term_to_binary` |
| --- | ---: | ---: |
| Session struct (177 B) | 1.4x | 1.1x |
| 1,000 integers | 1.4x | 1.1x |
| 16 × 1 KiB binaries | 2.9x | 1.9x |
| 16 × 1 KiB UTF-8 text | 4.6x | 5.4x |
| 4,000 integers in 0..100 | 1.2x | 0.7x |
| 100 union commands | 1.5x | 0.7x |
| 100 derived structs | 1.1x | 0.8x |

The BIFs build or write terms without checking them. Heddle checks every
byte against the codec, enforces the limits and builds the structs, and most
of the remaining gap is that work:

- Binary-heavy payloads pay for copying each kept binary, so results never
  hold on to the input. That's the default, `binaries: :copy`.
- UTF-8 text pays for validation, which checks seven bytes at a time while
  the text is ASCII.
- Compiled encoders append to a single binary instead of building iodata.
  That's why several shapes encode faster than `term_to_binary`.

`mix run bench/codecs.exs` prints full Benchee reports. They include the
interpreter, which is 3 to 130 times slower than compiled codecs.

## Design

The specification is [docs/design.md](docs/design.md). It covers the
rationale and the features deferred from this version.

## License

MIT

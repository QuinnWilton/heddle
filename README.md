# Heddle

[![CI](https://github.com/QuinnWilton/heddle/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/heddle/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/heddle.svg)](https://hex.pm/packages/heddle)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/heddle)

Safe, bidirectional ETF codecs for the BEAM: schema-directed decoders and
encoders that replace `binary_to_term/2` and `term_to_binary/2` at trust
boundaries.

`binary_to_term(bin, [:safe])` still decodes local funs, forged pids, struct
injections (`%{__struct__: SomeLoadedModule}`), compressed-term bombs, huge
bignums and arbitrarily deep terms. A Heddle codec accepts only the ETF
subset it names, never creates atoms, funs, pids, ports or references,
checks every length before allocating, and bounds depth and total terms at
the call site. The same codec encodes, and encoding fails on values the
decoder would reject.

## Installation

```elixir
def deps do
  [
    {:heddle, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
defmodule MyApp.Session do
  use Heddle.Schema

  defschema do
    field :user_id, Heddle.integer(min: 1)
    field :roles, Heddle.list(Heddle.enum([:admin, :editor, :viewer]), max: 16)
    field :expires_at, Heddle.integer(min: 0)
    field :meta, Heddle.map_of(Heddle.binary(max_size: 64), Heddle.binary(max_size: 256), max: 32),
      default: %{}
  end
end

{:ok, iodata} = Heddle.encode(MyApp.Session.codec(), session)

{:ok, %MyApp.Session{}} =
  Heddle.decode(MyApp.Session.codec(), bin, max_depth: 8, max_nodes: 1_000)
```

`defschema`, `defunion`, `defcodec` and `@derive Heddle.Codec` compile
codecs to binary pattern matches at build time. Codecs built at runtime
from the same constructors run in an interpreter with the same semantics.

### Tagged unions

```elixir
defmodule MyApp.Command do
  use Heddle.Schema

  defunion do
    variant :ping
    variant :put, key: Heddle.binary(max_size: 128), value: Heddle.binary(max_size: 4096)
    variant :delete, key: Heddle.binary(max_size: 128)
  end
end
```

### Structs you own, and structs you don't

```elixir
defmodule MyApp.User do
  @derive {Heddle.Codec, fields: [id: Heddle.integer(min: 1), name: Heddle.binary(max_size: 100, utf8: true)]}
  defstruct [:id, :name, :cache]
end

defmodule MyApp.Codecs do
  use Heddle.Schema

  defcodec uri do
    Heddle.struct(URI, fields: [scheme: Heddle.enum([:http, :https], unknown: :keep), host: Heddle.binary(max_size: 253)])
  end
end
```

### Fields that depend on other fields

```elixir
defmodule MyApp.Envelope do
  use Heddle.Schema
  import Heddle.Syntax

  defcodec codec do
    tuple_seq tag: :envelope do
      version <- Heddle.integer(min: 1, max: 2) <~ field(:version)
      body <- (case version do
                 1 -> Heddle.binary(max_size: 1024)
                 2 -> MyApp.Command.codec()
               end) <~ field(:body)
      pure %{version: version, body: body}
    end
  end
end
```

The compiler classifies each step: a dependency on a finite value expands
into a case per value, a dependency used only as a bound compiles once with
the bound passed at runtime, and anything else runs in the interpreter with
a compile-time warning.

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

Choice is deterministic, so the first failure is the only one and its
location is exact. Invalid codecs are compile errors rendered by
[pentiment](https://hex.pm/packages/pentiment), with every codec involved
labelled in the source.

### Testing

`Heddle.Gen.from/1` derives StreamData generators from codecs,
`Heddle.Laws` checks the round-trip laws over samples, `Heddle.Check`
compares Heddle with `binary_to_term(bin, [:safe])` and compiled codecs with
the interpreter, and `Heddle.lint/1` reports unbounded positions.

## Performance

`mix run bench/ratios.exs` reports each compiled codec as a multiple of the
BIF it replaces (lower is better; below 1.00x is faster than the BIF).
Medians on an Apple M1 Max, Elixir 1.20.4 on OTP 29.1:

| Payload | decode vs `binary_to_term(b, [:safe])` | encode vs `term_to_binary` |
| --- | ---: | ---: |
| Session struct (177 B) | 1.4x | 1.1x |
| 1,000 integers | 1.4x | 1.1x |
| 16 × 1 KiB binaries | 2.9x | 1.9x |
| 16 × 1 KiB UTF-8 text | 4.6x | 5.4x |
| 4,000 integers in 0..100 | 1.2x | 0.7x |
| 100 union commands | 1.5x | 0.7x |
| 100 derived structs | 1.1x | 0.8x |

The BIFs build or write untyped terms without checking them; Heddle checks
every byte against the codec, enforces the limits and builds the structs.
The remaining gaps are mostly that work: binary-heavy payloads pay for
copying kept binaries (the default `binaries: :copy`), and UTF-8 text pays
for validation, which runs seven bytes per word with an ASCII fast path.
Compiled encoders append to one binary rather than building iodata, which is
why several shapes encode faster than `term_to_binary`.

`mix run bench/codecs.exs` gives full Benchee reports, including the
interpreter, which is 3 to 130 times slower than compiled codecs.

## Design

The specification, with its rationale and the deferred features, is
[docs/design.md](docs/design.md).

## License

MIT

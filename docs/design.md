# Heddle: Safe, Bidirectional ETF Codecs for the BEAM

Oct 8, 2026 · @quinn

## Summary

Heddle replaces `binary_to_term/1,2` and `term_to_binary/1,2` at trust boundaries with schema-directed codecs: one value that is both the recognizer (bytes → value) and the printer (value → bytes). Codecs compile to binary pattern matches, accept only the ETF subset the schema names, and take resource limits as call-site parameters. This document specifies v1; features left out on purpose are listed under Deferred, each with a re-entry plan.

**Why.** `binary_to_term` on untrusted input causes a recurring class of BEAM vulnerabilities. The `[safe]` option blocks new atoms and new external fun references, but several attacks remain:

- Local funs that reference loaded modules still decode. `Plug.Crypto.non_executable_binary_to_term/2` exists to walk the result and reject them.
- Struct injection: `%{__struct__: SomeLoadedModule}` uses only existing atoms but steers protocol dispatch.
- Forged pids, refs and ports.
- Compressed-term bombs (tag 80 declares the inflated size up front).
- Huge bignums and deep or wide terms.
- Sub-binary retention pinning large refc binaries.

Decoding to an untyped term and validating afterwards is the shotgun-parsing pattern. Heddle parses straight from bytes. It still walks every byte of the input, but it materializes only values the schema names, and decoding never creates atoms, funs or identifiers.

## Goals and non-goals

**Goals (v1)**

- Decode untrusted ETF without creating atoms, funs or identifiers, and without allocating beyond explicit bounds.
- One description per type yields decoder, encoder, in-memory validator and test generator.
- Resource limits controllable at the call site.
- Drop-in adoption: `@derive` on existing structs, plus schema macros for new types.
- Compiled decoders as fast as hand-written binary pattern matching.
- Round-trip properties that can be checked compositionally.

**Non-goals**

- Decoding arbitrary terms. A `term()` codec does not exist.
- Replacing the distribution protocol. Distribution headers and `ATOM_CACHE_REF` are rejected.
- Ever accepting funs (`NEW_FUN_EXT`, `EXPORT_EXT`) or `LOCAL_EXT`, under any option.
- Ever creating atoms from input. Names outside a schema's atom set decode to {:unknown, binary}, or to existing atoms by explicit opt-in.
- A canonical byte format, or signature guarantees over ETF bytes (see Deferred).
- Deriving codecs from typespecs.

## Background

Four sources fix the design: LangSec says what to accept, the two bidirectional-programming papers say how to build codecs and their laws, and the ETF spec says where the hazards are.

**LangSec (Momot, Bratus, Hallberg & Patterson, *The Seven Turrets of Babel*, SecDev 2016).** Acceptable input should be defined by a grammar, kept as simple as possible, and fully validated before use by a parser of no more power than needed. Three of their anti-patterns describe `binary_to_term` misuse:

- **Shotgun parsing:** checks scattered through processing code.
- **Non-minimalist input handling:** computing power exposed at a validator is power given to the attacker.
- **Permissive processing of invalid input:** be definite, not liberal, and whitelist from a grammar.

They recommend staying at or below deterministic context-free, where grammar equivalence is decidable and parser differentials are detectable. Schema-restricted ETF is length-prefixed and tag-dispatched, so it stays within that bound if every choice is decided by the next tag byte.

**Rendel & Ostermann, *Invertible Syntax Descriptions* (Haskell Symposium 2010).** A partial isomorphism pairs `a → Maybe b` with `b → Maybe a`, inverse wherever defined. Every data constructor yields one, mechanically. Their uncurried product returns tuples because the curried applicative form cannot be implemented for printers, which suits ETF tuples.

**Xia, Orchard & Wang, *Composing Bidirectional Programs Monadically* (ESOP 2019).** This supplies the codec type and its laws:

- A codec has two parameters: the printer's input `u` and the parser's output `v`. `comap` takes a *partial* getter, restricting the domain explicitly.
- Backward round-tripping is not compositional, but its weak form (compare printer output with parser output) is. Strong backward round-tripping follows when `purify` (discard the printed bytes) is the identity.
- Forward round-tripping is only quasicompositional: bind preserves it when the continuation is an injective arrow. For ETF, that is the non-canonical-encoding problem.
- The same construction yields bigenerators: a random generator one way, a checker the other.

**ETF spec (OTP 29.1).** The hazards and edge cases that shape the design:

- Compressed terms are tag 80, a 4-byte big-endian uncompressed size, then zlib data. The declared size allows rejection before inflating.
- Atoms are at most 255 characters (up to 4 bytes each in UTF-8). Latin-1 `ATOM_EXT` and `SMALL_ATOM_EXT` are deprecated.
- `MAP_EXT` disallows duplicate keys.
- `LOCAL_EXT` (OTP 26) carries a hash that is explicitly not meant to stop forged input.
- `RECORD_EXT` (native records) is new in OTP 29.0.
- Several values have more than one valid encoding: small integers, byte lists (`STRING_EXT` vs `LIST_EXT`), atoms (small vs large tags), and map key order.

## Design principles

1. **Codecs are values chosen by the caller.** Dispatch never happens on the input: no protocol keyed on a decoded `__struct__`.
2. **Decoding has no global side effects.** No atom is interned, no process is addressed, no code is loaded. A rejected input leaves the VM exactly as it was.
3. **The language is the subset the schema names.** Funs, export refs, identifiers, `LOCAL_EXT`, compressed terms and distribution headers have no v1 codec, so they cannot be accepted.
4. **Choice is deterministic.** `one_of` alternatives must be distinguishable by tag byte or literal at compile time, keeping the grammar LL(1) over ETF tags. Their value shapes must be disjoint too, so encoding is deterministic as well.
5. **Limits form a meet-semilattice.** The effective limit is the minimum of the codec's bound and the call site's. A call site can tighten, never silently loosen.
6. **Decoding is linear-time.** With deterministic choice and no backtracking, work is proportional to input size. Interpreted `bind` paths are charged against the node budget.

## Core abstraction

A codec `Heddle.t(i, o)` encodes an `i` and decodes to an `o`. An aligned codec is `Heddle.t(a, a)`. Internally it is a first-order IR, so the same value can be interpreted, compiled to bit-syntax clauses, turned into a generator, or linted.

```elixir
@type t(i, o)   # treat as opaque: the fields are internal
```

### Primitives

Each primitive recognizes one production.

```elixir
Heddle.atom(:ok)                         # literal, matched as bytes, never interned
Heddle.enum([:admin, :editor, :viewer])  # finite atom set, compiled to byte-literal clauses
Heddle.enum([:http, :https], unknown: :keep)
                                       # other names decode as {:unknown, "gopher"};
                                       # re-encoded as atom bytes, never interned
Heddle.existing_atom()                   # opt-in: any atom that already exists in the VM;
                                       # names with no existing atom are rejected
Heddle.boolean()
Heddle.integer(min: 0, max: 65_535)      # range checked; bignum size bounded by the range
Heddle.float()                           # NEW_FLOAT_EXT only; FLOAT_EXT, NaN and infinities rejected
Heddle.binary(max_size: 4096, utf8: true)
Heddle.list(elem, max: 100)              # proper lists only; also STRING_EXT (see Lists)
Heddle.charlist(max: 255)                # accepts STRING_EXT and LIST_EXT
Heddle.tuple([c1, c2, c3])               # uncurried product, arity-checked
Heddle.map(required: [k: c], optional: [k2: c2])
Heddle.map_of(key_codec, val_codec, max: 64)
Heddle.null()                            # the atom nil, distinct from []
```

### Combinators

```elixir
Heddle.one_of([c1, c2])           # deterministic choice: alternatives differ by ETF tag byte
                                # or literal bytes; overlapping FIRST sets are a compile error
Heddle.tagged(:put, payload)      # encodes {:put, payload}
Heddle.iso(codec, decode_fun, encode_fun)
                                # partial iso; both return {:ok, x} | :error
Heddle.refine(codec, &valid?/1, :reason)
                                # subset iso: restricts the accepted language
Heddle.from(codec, getter)        # which part of the value this codec encodes;
                                # getter returns {:ok, part} | :error
Heddle.field(:user_id)            # getter helper for a struct or map field
Heddle.lazy(fn -> tree() end)     # recursion
Heddle.tuple_seq(seq, tag: :t)    # a tuple read as a sequence of steps
Heddle.bind(codec, fn v -> seq end)
                                # a sequence step: the rest depends on a decoded value
Heddle.pure(value)                # ends a sequence with its result
```

`bind` and `pure` build sequences, which only `tuple_seq` runs: in ETF a run of terms exists only inside a container, and a tuple's arity says how many steps the sequence must take. Using a sequence where a codec is expected, or the reverse, raises `Heddle.CodecError` (H009).

`from/2` is the profunctor `lmap` (Xia et al.'s `comap`) with a partial function: `Heddle.integer(min: 1) |> Heddle.from(Heddle.field(:user_id))`. A getter returning `:error` makes encoding fail cleanly outside the codec's domain.

| Paper concept | Heddle construct |
| --- | --- |
| Partial isomorphism (Rendel & Ostermann) | `Heddle.iso/3`, `Heddle.refine/3`, derived constructor isos |
| Uncurried product `<*>` | `Heddle.tuple/1` |
| Alternative `<\|>` | `Heddle.one_of/1`, restricted to deterministic choice |
| `comap` / `upon` (Xia et al.), `lmap` | `Heddle.from/2` |
| Monadic bind | `Heddle.bind/2` and the `Heddle.Syntax` block form |
| `purify` | `Heddle.project/2` (and `Heddle.conforms?/2`) |
| Bigenerator | `Heddle.Gen.from/1` |

## Decoding

Decoding takes a codec, the bytes, and a small set of limits. Everything else about what is accepted is fixed by the schema, not by options.

```elixir
{:ok, session} =
  Heddle.decode(Session.codec(), bin,
    max_depth: 32,
    max_bytes: 65_536,
    max_nodes: 10_000)
```

| Option | Default | Meaning |
| --- | --- | --- |
| `max_bytes` | 1 MiB | Input size, checked before parsing begins |
| `max_depth` | 32 | Nesting depth; the root term is depth 1 |
| `max_nodes` | 10,000 | Total decoded terms, including map keys and each `bind` evaluation |
| `binaries` | `:copy` | `:copy` avoids pinning the input's refc binary; `:ref` returns sub-binaries |

### Limit semantics

Codec-declared bounds (for example `max: 100` on a list) and call-site bounds combine by minimum. `Heddle.Limits.meet/2` is exposed so frameworks can layer policies. A call site cannot raise a bound the codec declared.

`Heddle.lint/1` sees only the codec, so it reports every position with no bound from the codec. Such a position is still bounded at runtime by the call-site limits (at least `max_bytes`, which always has a value), so lint findings are warnings about relying on call-site policy, not decode-time failures.

### Resource accounting

- **Lengths before allocation.** Every declared length (binary size, list length, tuple arity, map arity, atom length, bignum byte count) is checked against the codec's bound and the remaining input bytes before anything is allocated.
- **Depth.** The root is depth 1; each tuple, list or map increments the depth of its children.
- **Nodes.** Every decoded term counts once: each list element, each map key and each map value. Each `bind` evaluation also counts once.
- **Time.** Compiled decoding is linear in input size, because choice is LL(1) and nothing backtracks. Interpreted paths are bounded by the node budget. A `bind` continuation is trusted application code and runs at most once per node charged.

### Atoms

- Schema literals and enums are compared as bytes and never interned. Because nothing is interned, all four atom tags are accepted for literals: `ATOM_UTF8_EXT`, `SMALL_ATOM_UTF8_EXT`, and the deprecated Latin-1 `ATOM_EXT` and `SMALL_ATOM_EXT` (matched against the literal's Latin-1 spelling). This keeps producers on older OTP versions, or using `minor_version: 1`, compatible.
- Names read from the Latin-1 tags are transcoded to UTF-8 before any comparison or lookup, so `{:unknown, name}` is the same value whichever tag carried the atom.
- `enum(..., unknown: :keep)` decodes names outside the set as `{:unknown, binary}`, and encodes them back as atom bytes without creating the atom, so they round-trip. The encoder rejects `{:unknown, name}` when `name` is in the set, since those bytes would decode as the atom rather than as `{:unknown, name}`. ETF caps atoms at 255 characters, so an unknown name is at most about 1 KiB. `enum([], unknown: :keep)` accepts any name as data.
- `existing_atom` is the only primitive that returns atoms not named in the schema. It looks names up with `binary_to_existing_atom/2` and never creates one; a name with no existing atom is rejected. The result can be any atom in the VM, including module names, so it must never be used as a module, a struct name or an `apply/3` target. Its results also depend on what code is loaded, so the same bytes can decode differently on two nodes.
- `existing_atom` has no `unknown: :keep`. Returning an atom when one happens to exist and a binary otherwise would make round-tripping depend on when atoms get created. Callers who want unexpected names as data use `enum([], unknown: :keep)`, whose result depends only on the bytes.

### Lists

`term_to_binary` writes a list of integers in 0–255 with fewer than 65,536 elements as `STRING_EXT`. `Heddle.list/2` accepts `STRING_EXT` wherever its element codec accepts the integers it holds: each byte is checked against the element codec and charged one node, exactly as if it had arrived as `LIST_EXT`. So `Heddle.list(Heddle.integer(min: 0, max: 1000))` decodes OTP's own output for `[1, 2, 3]`. The encoder writes such lists as `STRING_EXT`, as `term_to_binary` does.

### Optional and defaulted fields

- **Plain maps.** In `Heddle.map/1`, an absent `optional:` key is absent from the decoded map, and the encoder omits optional keys the value doesn't have.
- **Struct layouts.** A struct field is required unless it declares `default:`. A defaulted field may be absent from the input and decodes to its default. The encoder always writes every serialized field, as `term_to_binary` does for a struct, so backward round-tripping holds, and when the codec serializes every field the VM decodes Heddle's output to a well-formed struct. Fields the codec does not serialize are neither written nor accepted; decoding fills them from the struct's own defaults.

### Struct keys

A decoded map has a `:__struct__` key only when its codec is a struct layout, which matches the key's value as a literal naming the struct's own module. Everywhere else the key is refused:

- `map_of` rejects a `:__struct__` key on decode whatever its key codec is, so `map_of(existing_atom(), existing_atom())` cannot decode `%{__struct__: SomeLoadedModule}`. Its encoder rejects maps with the key (that is, structs), so the encoder's domain matches what the decoder accepts.
- Naming `:__struct__` in `Heddle.map/1`, or using an `enum` that contains it as a `map_of` key codec, is a compile error that points at `Heddle.struct/2`.

### Integers

An integer's declared bignum size is checked against the codec's range before its magnitude is read. An unbounded range is still capped at the VM's own limit, 524,280 magnitude bytes on 64-bit builds (high zero bytes included), which `binary_to_term` enforces too.

### Always rejected

`NEW_FUN_EXT`, `EXPORT_EXT`, `LOCAL_EXT`, compressed terms (tag 80), pids, ports and refs, `RECORD_EXT`, distribution headers, `ATOM_CACHE_REF`, `FLOAT_EXT`, NaN and infinite floats, improper lists, duplicate map keys, map keys the schema doesn't name, a `:__struct__` key outside a struct layout, and trailing bytes after the term.

### Errors

Errors carry the path, byte offset, a machine-readable reason, the expected set and what was found. Because choice is deterministic, the first failure is the only failure, so the reported location is exact. `found` quotes at most 64 bytes of the input: a longer value is reported as `{:truncated, prefix, byte_size}`, so logging an error never copies attacker-sized data.

```elixir
{:error, %Heddle.DecodeError{
  path: [:roles, 3],
  offset: 41,
  reason: :unexpected,
  expected: [{:atom, :admin}, {:atom, :editor}, {:atom, :viewer}],
  found: {:small_atom_utf8, "root"}
}}
```

## Encoding

Encoding is partial: a value outside the codec's domain fails instead of producing bytes the decoder would later reject. This is the backward round-trip guarantee seen from the writer's side.

```elixir
{:ok, iodata} = Heddle.encode(codec, value)

{:error, %Heddle.EncodeError{path: [:user_id], reason: {:out_of_range, 0}}} =
  Heddle.encode(codec, %{session | user_id: 0})

Heddle.conforms?(codec, value)   # pure projection: validates without serializing
```

- Output is deterministic for a given Heddle version: minimal integer tags, UTF-8 atom tags, map keys sorted by their encoded bytes. It does not depend on the OTP version, because Heddle writes ETF itself rather than calling term\_to\_binary. It is not a canonical format; output changes between Heddle versions are deliberate and listed in the changelog.
- The encoder accepts exactly the values the decoder can return. `{:unknown, name}` is rejected when `name` is in the enum's set (`{:known_name, name}`) or is not a valid atom name (invalid UTF-8, or longer than 255 characters), and a `map_of` encoder rejects maps with a `:__struct__` key. `Heddle.Gen.from/1` never generates these values.
- Output is never compressed.
- Encoders return iodata, so large binaries are never copied.

## Derivation

There are two routes: `@derive` on an existing struct, for dropping Heddle into existing libraries, and schema macros for new types. Both produce the same IR as hand-written combinators.

### Existing structs

```elixir
defmodule MyApp.User do
  @derive {Heddle.Codec,
           as: :map,
           fields: [id: Heddle.integer(min: 1), name: Heddle.binary(max_size: 100, utf8: true)]}
  defstruct [:id, :name, :cache]
end

Heddle.codec_for(MyApp.User)
```

- Every serialized field needs an explicit codec; a field left out of `fields:` (here `:cache`) is neither encoded nor accepted. There is no type-driven default, because a struct field carries no bounds.
- Layouts: `as: :map` (a map whose `__struct__` must equal this module, matched as a byte literal) or `as: :tuple` with optional `tag:`.
- `@derive` is sugar for `Heddle.struct/2` plus a `Heddle.Codec` implementation. The protocol is resolved on the module named at the call site, never on decoded data.
- Elixir evaluates `@derive` options as a module attribute before Heddle sees them, so they may call Heddle's constructors and other modules but not functions of the struct's own module. For local helper codecs, use `defschema` instead.

### Structs you don't own

Protocol implementations are global: a struct can have only one `Heddle.Codec` implementation in the VM. If two libraries both derived one for `URI` with different bounds, which bounds apply would depend on compile order. So `@derive` is only for structs you own, and Heddle's docs say never to `Protocol.derive/3` Heddle codecs for anyone else's struct.

For a struct you don't own, define a codec with `Heddle.struct/2` and name it where it's used:

```elixir
use Heddle.Schema

defcodec uri_codec do
  Heddle.struct(URI,
    as: :map,
    fields: [
      scheme: Heddle.enum([:http, :https], unknown: :keep),
      host: Heddle.binary(max_size: 253)
    ])
end

defschema as: :map do
  field :homepage, uri_codec()
end
```

Two libraries can each define their own `URI` codec without affecting each other.

### Nested structs

When a field holds a struct that has its own derived `Heddle.Codec` implementation or schema, a derived or schema codec may name the struct's module in place of a codec (`field :owner, MyApp.User`) to use its owner's codec. Because only a struct's owner can derive one, the lookup is unambiguous. An explicitly named codec always takes precedence, and naming a module that has no Heddle codec is a compile error. A module reference compiles to a call to that module's decoder, so it needs nothing from the module at compile time (see Compilation model).

### New records

```elixir
defmodule MyApp.Session do
  use Heddle.Schema

  defschema as: :map do
    field :user_id,    Heddle.integer(min: 1)
    field :roles,      Heddle.list(Heddle.enum([:admin, :editor, :viewer]), max: 16)
    field :expires_at, Heddle.integer(min: 0)
    field :meta,       Heddle.map_of(Heddle.binary(max_size: 64), Heddle.binary(max_size: 256), max: 32),
                       default: %{}
  end
end
```

This generates `defstruct`, `@type t`, a compiled `codec/0` and the constructor isos.

### Tagged unions

```elixir
defmodule MyApp.Command do
  use Heddle.Schema

  defunion do
    variant :ping                                          # :ping
    variant :put,    [key: Heddle.binary(max_size: 128),
                      value: Heddle.binary(max_size: 4096)]  # {:put, key, value}
    variant :delete, [key: Heddle.binary(max_size: 128)]    # {:delete, key}
  end
end
```

v1 supports one union encoding: tagged tuples, with nullary variants as bare atoms. It is idiomatic Erlang and dispatches on the leading atom, so FIRST sets are trivially disjoint. Map-based and untagged encodings are deferred.

## Dependent codecs with `bind`

`bind` lets a later codec depend on a value decoded earlier. ETF already carries its own lengths and type tags, so the case left is schema-level dependency: a field whose codec is chosen by another field. `Heddle.Syntax` gives the block form from Xia et al.; `<~` is infix `from`.

```elixir
use Heddle.Schema
import Heddle.Syntax

defcodec envelope do
  tuple_seq tag: :envelope do
    version <- Heddle.integer(min: 1, max: 2) <~ field(:version)
    body    <- (case version do
                  1 -> Heddle.binary(max_size: 1024)
                  2 -> MyApp.Command.codec()
                end) <~ field(:body)
    pure %Envelope{version: version, body: body}
  end
end
```

`version` comes from a two-value range, so this bind is finite: the continuation is evaluated for 1 and 2 at compile time and the bind expands into a `one_of`.

- **Binding-time analysis classifies each continuation.** Inside a `Heddle.Syntax` block the continuation is AST at compile time, and it follows the same rules as any compiled codec expression (see Compilation model): it cannot call the module's own `def` or `defp` functions. Each use of the bound value is classified:
  - **Finite:** the value comes from a codec with at most 64 values (`enum`, `boolean`, an integer range of at most 64 values). The continuation is evaluated for every value and the bind expands into a `one_of`. Nested finite binds may expand to at most 256 alternatives in total; past that, the bind is classified as parameter or opaque instead.
  - **Parameter:** the value appears only in parameter positions of codec constructors, such as a bound (`Heddle.binary(max_size: n)`, `Heddle.list(elem, max: n)`) or a branch selector in a `case` whose arms are codecs. The shape is static, so it compiles once into a decoder that takes the value as a runtime argument.
  - **Opaque:** anything else. The returned codec runs in the interpreter, and `Heddle.lint/1` flags it.
- **Bounds flow through binds.** A parameter's static range comes from the codec that decoded it, so `n` from `Heddle.integer(min: 0, max: 1000)` gives the dependent list a static bound of 1000 for linting. At runtime the parameter is still combined with call-site limits by minimum.
- **No runtime compilation, ever.** Code is generated only at macro expansion time. Compiling per returned codec would load attacker-influenced numbers of modules, a global side effect.
- Each `bind` evaluation is charged one node. Prefer `one_of` over tagged tuples when the dependency is just a discriminator.

## Implementation

Every front end lowers to one codec IR; static checks run on the IR before any backend is generated, so a codec that fails them never compiles.

&#91;embedded content: Heddle pipeline · 3 front ends, 1 IR, 5 backends\]

The interpreter is the reference semantics. The compiled decoder must agree with it on every input, and both must agree with `binary_to_term(b, [:safe])` on inputs they accept (see Correctness).

### Compilation model

Heddle compiles a codec where one of its macros sees it: `defschema`, `defunion`, `@derive {Heddle.Codec, ...}` and `defcodec`. The macro evaluates the codec expression during expansion, runs the static checks on its IR, and generates the decoder and encoder as functions in the calling module. Any other codec value, built at runtime by plain combinator calls (including a `Heddle.Syntax` block outside these macros), runs in the interpreter. Nothing is ever compiled at runtime.

```elixir
use Heddle.Schema

defcodec hostname do
  Heddle.binary(max_size: 253, utf8: true)
end
```

`defcodec name do ... end` defines `name/0`, which returns a codec value linked to the generated functions. A codec value (`t:Heddle.t/2`) carries its IR and, when compiled, a reference to its generated decoder and encoder; `Heddle.decode/3` and `Heddle.encode/2` dispatch on that reference.

A codec expression inside these macros may contain only:

- literals and module attributes;
- Heddle's constructors and combinators, and `Heddle.Syntax` blocks;
- local calls to codecs defined earlier in the same module with `defcodec`;
- a module name standing for that module's struct codec (see Nested structs);
- remote calls to other modules.

Anything else, such as a call to the module's own `def` or `defp` functions, cannot run while its module is still being compiled. It is a compile error that points at the call and suggests `defcodec` or moving the helper to another module.

Dependencies follow from these rules:

- **Remote calls are compile-time dependencies.** Heddle records each module a codec expression calls as a compile-time dependency (as `require` does), so Mix recompiles a schema when a helper it calls changes and a stale decoder cannot survive a rebuild.
- **Compiled codecs are linked, not inlined.** A reference to a codec that is itself compiled (a schema, a derived struct, or a `defcodec` here or elsewhere) becomes a call to its generated decoder. A module-name reference needs nothing from that module at compile time, so mutually recursive structs in different modules compile.
- **`one_of` reads summaries.** When a compiled codec appears as a `one_of` alternative, its summary (FIRST set and value shape) is read at compile time, which requires its module to be compiled first. A cycle of such references across modules deadlocks Elixir's parallel compiler; the fix is to move the cycle into one module and close it with `Heddle.lazy/1`.

Codecs built at runtime get the same static checks when each combinator is called. A violation raises `Heddle.CodecError` before any input is decoded.

### Compilation

Each IR node becomes a private function. Decoders follow one calling convention, `decode(rest, depth, nodes, lim)`, shared with the interpreter so the two backends can call each other (compiled references from interpreted codecs, opaque binds from compiled ones). Compiled encoders take an accumulator, `encode(value, acc)`, and append to it: the BEAM appends to a binary in place, so one growing binary beats nested iodata flattened at the end, and several payload shapes encode faster than `term_to_binary`. Where they call the interpreter's iodata encoders (slow paths, opaque binds), the result is appended.

- **Literals are byte patterns.** An atom literal becomes clauses such as `<<119, 2, "ok", rest::binary>>`, one per atom tag its name can be written with. A `one_of` becomes a `case` over its alternatives' FIRST sets as byte patterns: atom spellings, tag bytes, and tuple headers followed by a tag's spellings.
- **Leaves have inline fast paths.** Integers, floats and binaries match their common encodings inline; anything else, and every failure, falls back to the same shared reader the interpreter calls, so both backends report the same error at the same offset.
- **Loops keep the match context.** List loops match leaf elements in their head, and every loop clause starts with a binary match, so the BEAM reuses one match context across iterations instead of creating a sub-binary per element.
- **Structs decode into their template.** A struct laid out as a map starts from its defaults and records the keys it has seen in a bitmask, for the duplicate and missing-key checks. Its encoder writes keys in an order fixed at compile time.
- **Fused clauses.** A map key followed by a leaf value, a tuple of leaves, and a union alternative that is a literal or a tuple of leaves each match in one clause, with every limit check as a guard; encoders write such shapes in one append. Where output order and error order differ (struct fields are written in key-byte order but reported in declared order), a failure reruns the shared encoder, which reports the canonical error.
- **SWAR scans.** UTF-8 validation skips ASCII 56 bytes at a time before handing the rest to `String.valid?/1`, and a `STRING_EXT` whose element codec is an integer range is checked seven bytes per word. Words are 56 bits so they stay small integers.
- **Binding-time analysis of `bind`** compiles sequences from their continuations' source, as described under Dependent codecs.

### Static checks

- **Decoding determinism:** every `one_of` must have pairwise disjoint FIRST sets over (ETF tag, literal bytes). Overlap is a compile error naming the overlapping pair.
- **Encoding determinism:** every `one_of` must also have pairwise disjoint value shapes, so the encoder dispatches on the value without trial and error. Each alternative is summarized coarsely (atom literal, tuple with a given tag and arity, binary, integer range, map with given required keys) and overlap is a compile error. For example, `one_of([Heddle.enum([:a], unknown: :keep), Heddle.tagged(:unknown, Heddle.binary())])` is rejected because both produce `{:unknown, binary}`.
- **Boundedness:** `Heddle.lint/1` reports every list, binary, map or integer position with no bound from the codec (L001). Call-site limits discharge these at runtime.
- **Opacity:** a `bind` classified as opaque is flagged and runs interpreted.
- **Struct keys:** naming `:__struct__` in `Heddle.map/1`, or using an `enum` containing it as a `map_of` key codec, is a compile error (see Struct keys).

### Diagnostics

Heddle reports compile-time problems with pentiment, the workspace's diagnostics library. Every IR node a Heddle macro builds carries the file and span of the expression that produced it, taken from AST metadata with `Pentiment.Elixir.span_from_ast/1`. A failed static check raises `CompileError` with a rendered `Pentiment.Report` as its description.

- **Every location involved is labelled.** Overlapping `one_of` alternatives get a primary label on the later alternative and a secondary label on the earlier one, even when the earlier one comes from a `defcodec` in another file.
- **Stable codes and a fix.** Each check has a stable error code and a help line naming the fix, such as `defcodec` for a local helper call or `Heddle.struct/2` for a `:__struct__` key. The codes are H001 (overlapping FIRST sets), H002 (overlapping value shapes), H003 (`:__struct__` key), H004 (invalid constructor arguments), H005 (a call that cannot run at compile time), H006 (a module with no codec), H007 (left recursion), H008 (a value that cannot be embedded in code), H009 (a sequence where a codec is expected, or the reverse), H010 (a compile-time function called outside its compiler), W001 (opaque bind) and L001 (unbounded position).
- **Warnings use the same format.** Opaque binds warn at compile time. `Heddle.lint/1` returns `Pentiment.Report` values, so tools render lint findings the same way.
- **Coarser locations where no AST exists.** Elixir evaluates `@derive` options before Heddle sees them, so their findings point at the `@derive` line. Codecs built at runtime carry no spans, so `Heddle.CodecError` renders its report without source excerpts.

### Where deferred features attach

Each deferred feature has one place to go, so none requires redesigning the IR:

- A canonical mode narrows the tag sets in the shared readers and the byte patterns the compiler emits for literals and FIRST sets.
- Unknown-key skipping belongs in the keyed-map readers, which today reject any key the codec does not name.
- Decompression is a step in the shared top-level decode, before the term is read, where the version byte and compressed tag are already examined.

## Correctness: laws and testing

Backward round-tripping is proven per primitive and composed, following Xia et al.; agreement between implementations is checked by differential testing.

| Property | Statement | How it is established |
| --- | --- | --- |
| Weak backward round-trip | If encode yields `(y, bytes)`, decode of `bytes` yields `y` | Compositional: proven once per primitive, preserved by `bind` |
| Identity projection | `purify(codec)(x) == {:ok, x}` | `Heddle.Laws.identity_projection/2` over generated values |
| Backward round-trip | `decode(encode(x)) == {:ok, x}` | Follows from the two rows above |
| Compiled = interpreted | Same result, or same error at the same offset, on every input | Property tests on generated and mutated bytes |
| Agreement with the VM | If Heddle accepts `b` as `v`, then `binary_to_term(b, [:safe])` accepts `b` and returns `v`'s plain-term form | `Heddle.Check.differential/2` on OTP 29 |

The last row is an implication, not an equivalence. `[:safe]` deliberately accepts a larger language, so inputs Heddle rejects are not compared. In the plain-term form, structs compare as maps, and an `{:unknown, name}` value compares equal to an atom whose `atom_to_binary/1` is `name`. Struct fields the input omitted, which Heddle filled from `default:`, are compared after applying the same defaults to the VM's term. If `[:safe]` rejects an input Heddle accepted, the run fails: either Heddle accepted too much, or the harness didn't load the schema's atoms. Inputs containing an unknown enum name that doesn't exist as an atom are expected `[:safe]` rejections and are excluded.

```elixir
property "session codec round-trips" do
  check all s <- Heddle.Gen.from(Session.codec()) do
    {:ok, bin} = Heddle.encode(Session.codec(), s)
    assert {:ok, ^s} = Heddle.decode(Session.codec(), IO.iodata_to_binary(bin))
  end
end

Heddle.Laws.identity_projection(codec, samples)
Heddle.Check.differential(codec, corpus)
```

Forward round-tripping (`encode(decode(b)) == b`) is not claimed in v1. ETF admits several encodings of one value, and v1 accepts all of them.

### Encoder output

- **Golden snapshots per Heddle version.** The exact bytes for a fixed corpus of values are checked in. Any change in encoder output fails CI until the snapshots are updated deliberately.
- **The VM reads what Heddle writes.** On OTP 29, `binary_to_term(IO.iodata_to_binary(Heddle.encode!(codec, v)))` must equal `v`'s plain-term form. The round-trip property tests already generate the values, so this runs alongside them.

No cross-OTP matrix of encoder output is needed: the encoder's bytes depend only on the Heddle version and the codec.

## Deferred, with re-entry plan

Each of these was cut from v1 to keep every claim in this document specified and testable. None requires redesigning the IR.

| Feature | Why deferred | Re-entry plan |
| --- | --- | --- |
| Canonical mode | Needs a complete, versioned grammar (integer widths, bignums, bitstrings, map order); OTP's deterministic output is not a cross-version standard | `canonical: {:heddle, 1}` narrows each primitive's accepted tag set and adds ordering checks |
| Compressed terms | Bomb handling and separate input and inflated-byte budgets | Pre-parse stage: declared-size check, streaming inflate, inflated-bytes budget |
| Unions over maps | The discriminator key can appear anywhere in a map | Bounded pre-scan of one map's keys, then parse; untagged map unions stay a compile error |
| Unknown-key skipping | Needs a second, generic parser with its own budgets | `unknown_keys: :skip` via a bounded walker sharing the main budgets |
| Prefix and streaming decode | Resumable cursors complicate budget accounting | `decode_prefix/3` first, streaming later |
| Pid, port and ref codecs | These are capabilities, not data | Opt-in module, documented as conferring no authority over the process |
| Native records (`RECORD_EXT`) | New in OTP 29.0; semantics still settling | `as: :native_record` layout |
| Typespec derivation | Typespecs carry no bounds | Possibly never |

Removed rather than deferred: creating atoms from input, in any form. Atoms are permanent and VM-wide, so no per-decode limit bounds them.

## Open questions

- [x] **Minimum OTP version.** Decided: Heddle requires Elixir ~> 1.20 and OTP 29, and CI runs Elixir 1.20 on OTP 29. Running on OTP 29 doesn't limit which producers Heddle can read: producers back to OTP 24 are covered by golden fixtures (a fixed corpus encoded on OTP 24–29, with and without minor\_version: 1 and :deterministic) decoded on every CI run. The differential test uses the running VM only.
- [x] **Non-finite `bind` in the compiled backend.** Decided: binding-time analysis in v1 (see Dependent codecs). Finite binds expand, parameter binds compile once with the value as a runtime argument, opaque binds are interpreted. Runtime compilation is ruled out as a global side effect.
- [x] **Open atoms.** Decided: `open_atom` is removed. `enum(..., unknown: :keep)` decodes unexpected names as `{:unknown, binary}`, and its encoder rejects `{:unknown, name}` for names in the set. `existing_atom` is the explicit opt-in for real atoms via lookup, and is reject-only so its round trip doesn't depend on when atoms get created. `one_of` gains a value-shape disjointness check so encoding stays deterministic.
- [x] **Compilation model.** Decided: codecs are compiled where a Heddle macro (`defschema`, `defunion`, `@derive`, `defcodec`) evaluates them at expansion time. Their expressions may call Heddle, module attributes, earlier `defcodec`s and other modules, but not the module's own functions. Compiled codecs reference each other by call, and everything built at runtime is interpreted. Rejected: an `@after_compile` companion module (Mix doesn't track its inputs, so decoders could go stale) and splicing runtime sub-codecs into compiled ones (checks move to runtime; this can return later as a generalization of parameter binds).
- [x] **Struct keys.** Decided: a decoded map has a `:__struct__` key only when its codec is a struct layout. `map_of` rejects the key on decode and encode, and naming it elsewhere is a compile error.
- [x] **Diagnostics.** Decided: compile-time errors and lint findings are `Pentiment.Report`s with source spans from the codec's AST.
- [x] **Map key order in encoder output.** Decided: keys are sorted by their encoded bytes. Term order of decoded values is not the order of their bytes (an `{:unknown, name}` key encodes as an atom), and byte order needs no comparison beyond the bytes Heddle already writes.
- [x] **`@derive` for structs you don't own.** Decided: `@derive` only for structs you own; `Heddle.struct/2` codec values for everyone else's, named explicitly where used. Nested structs may use their owner's derived implementation implicitly, and an explicit codec always wins (see Derivation).
- [x] **Encoder stability.** Decided: no cross-OTP matrix, since Heddle writes ETF itself and its output doesn't vary by OTP. Instead, golden snapshots per Heddle version and a check that OTP 29 decodes Heddle's output (see Correctness).

## References

- Momot, Bratus, Hallberg & Patterson. [The Seven Turrets of Babel: A Taxonomy of LangSec Errors and How to Expunge Them](https://ws.engr.illinois.edu/sitemanager/getfile.asp?id=2324). IEEE SecDev 2016.
- Rendel & Ostermann. [Invertible Syntax Descriptions: Unifying Parsing and Pretty Printing](https://www.informatik.uni-marburg.de/~rendel/unparse/rendel10invertible.pdf). Haskell Symposium 2010.
- Xia, Orchard & Wang. [Composing Bidirectional Programs Monadically](https://arxiv.org/pdf/1902.06950v1). ESOP 2019.
- Erlang/OTP. [External Term Format, OTP 29.1.1](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html).

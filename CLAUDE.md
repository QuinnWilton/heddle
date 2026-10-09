# heddle

Safe, bidirectional ETF codecs for the BEAM: schema-directed decoders and encoders that replace
`binary_to_term/2` and `term_to_binary/2` at trust boundaries.

The design lives in `docs/design.md`; it is the specification, so read it before changing behaviour.

## Architecture

- `Heddle` - the constructors (the codec IR) and `decode/3`, `encode/2`, `project/2`.
- `Heddle.IR` - node shapes and the summaries behind the determinism checks: FIRST sets, value shapes, expected sets.
- `Heddle.Interpreter` - the reference semantics. Compiled codecs must agree with it on every input.
- `Heddle.Runtime` - everything both backends share: the decoder/encoder calling convention, limit checks, leaf readers, container encoders. Any decision that shapes an error lives here.
- `Heddle.Compiler` (+ `Compiler.Seq`, `Compiler.Expr`) - IR to bit-syntax functions; `Seq` is binding-time analysis of `bind`; `Expr` prepares codec expressions for compile-time evaluation (closures become `FunRef`s carrying their source).
- `Heddle.Schema`, `Heddle.Codec`, `Heddle.DSL` - the front ends (`defcodec`/`defschema`/`defunion`, `@derive`, importable constructors and `tuple_seq` blocks). `Compiler.Expr` rewrites `Heddle.DSL` calls to `Heddle` ones, so the compiler only matches `Heddle.f` calls.
- `Heddle.Diagnostics` - pentiment rendering of `CodecError`s; `Heddle.Lint` - L001/W001 findings.
- `Heddle.SWAR` - word-at-a-time scans (56-bit words stay small integers).
- `Heddle.Gen`, `Heddle.Laws`, `Heddle.Check` - generators, round-trip laws, differential checks.

## Invariants worth knowing

- A change to decoding semantics goes in `Heddle.Runtime` (or the interpreter) first; compiled fast paths must be special cases of it. `test/heddle/compiler_test.exs` compiles random codecs and checks both backends agree on valid and mutated bytes.
- `test/fixtures/producers` holds `term_to_binary` output from OTP 24-29 (regenerate with `test/fixtures/generate.escript`, OTP 24/25 via the `erlang:24`/`erlang:25` Docker images). `test/fixtures/encoder_snapshots.etf` pins encoder output; regenerate with `HEDDLE_UPDATE_SNAPSHOTS=1 mix test test/heddle/snapshots_test.exs` and log the change.
- Benchmarks: `mix run bench/codecs.exs`.

## Development commands

```bash
mix test                      # run all tests
mix format                    # format code
mix format --check-formatted  # check formatting
mix credo --strict            # lint
mix dialyzer                  # static analysis
mix presubmit                 # commit policy (installed as a commit-msg hook)
```

## Commit message style

```
[component] brief description

Optional longer explanation, wrapped at 72 columns.
```

## Testing conventions

- Unit tests mirror `lib/` structure in `test/`.
- Test support modules go in `test/support/`.
- Use `stream_data` for property-based testing.

## Changelog

Every user-visible change must have an entry in `CHANGELOG.md` under an `## Unreleased` section at the top.

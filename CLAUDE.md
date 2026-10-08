# heddle

Safe, bidirectional ETF codecs for the BEAM: schema-directed decoders and encoders that replace
`binary_to_term/2` and `term_to_binary/2` at trust boundaries.

The design lives in `docs/design.md`; it is the specification, so read it before changing behaviour.

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

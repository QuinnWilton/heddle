# Heddle

[![CI](https://github.com/QuinnWilton/heddle/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/heddle/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/heddle.svg)](https://hex.pm/packages/heddle)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/heddle)

Safe, bidirectional ETF codecs for the BEAM: schema-directed decoders and
encoders that replace `binary_to_term/2` and `term_to_binary/2` at trust
boundaries.

## Installation

```elixir
def deps do
  [
    {:heddle, "~> 0.1.0"}
  ]
end
```

## License

MIT

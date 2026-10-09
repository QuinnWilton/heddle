locals_without_parens = [
  defcodec: 2,
  defschema: 1,
  defschema: 2,
  defunion: 1,
  field: 2,
  field: 3,
  variant: 1,
  variant: 2,
  tuple_seq: 1,
  tuple_seq: 2,
  pure: 1
]

[
  import_deps: [:presubmit, :stream_data],
  inputs: ["{mix,.formatter,.presubmit}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]

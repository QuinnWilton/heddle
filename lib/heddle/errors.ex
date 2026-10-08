defmodule Heddle.DecodeError do
  @moduledoc """
  Why some bytes were not accepted.

  Choice in a codec is deterministic, so the first failure is the only one
  and the location is exact:

    * `path` - the keys and indices from the root to the failing term.
    * `offset` - the byte offset of the failing term (or of the byte inside
      a `STRING_EXT` that failed).
    * `reason` - a machine-readable cause, listed below.
    * `expected` - what the codec accepts at that position.
    * `found` - a short description of the bytes there; it quotes at most 64
      bytes of input, so logging an error never copies attacker-sized data.

  Reasons:

    * `:max_bytes`, `:max_depth`, `:max_nodes` - a limit was reached.
    * `:version` - the input does not start with the version byte 131.
    * `:compressed`, `:distribution_header` - forms Heddle never accepts.
    * `:trailing_bytes` - bytes follow the term.
    * `:unexpected` - a tag, literal or arity the codec does not accept.
    * `:unexpected_eof` - the input ends inside the term.
    * `:too_large` - a declared length exceeds the codec's bound or the VM's.
    * `:out_of_range` - an integer outside the codec's range.
    * `:invalid_utf8`, `:invalid_atom`, `:invalid_float` - malformed values.
    * `:improper_list` - a list whose tail is not `[]`.
    * `:duplicate_key`, `:unknown_key`, `:missing_key`, `:struct_key` - map
      keys the codec rejects.
    * `:unknown_atom` - `existing_atom/0` read a name with no existing atom.
    * `:iso` - an `iso/3` decode function returned `:error`.
    * `{:refine, reason}` - a `refine/3` predicate failed.
  """

  @type reason ::
          :max_bytes
          | :max_depth
          | :max_nodes
          | :version
          | :compressed
          | :distribution_header
          | :trailing_bytes
          | :unexpected
          | :unexpected_eof
          | :too_large
          | :out_of_range
          | :invalid_utf8
          | :invalid_atom
          | :invalid_float
          | :improper_list
          | :duplicate_key
          | :unknown_key
          | :missing_key
          | :struct_key
          | :unknown_atom
          | :iso
          | {:refine, term()}

  @type t :: %__MODULE__{
          path: [term()],
          offset: non_neg_integer(),
          reason: reason(),
          expected: [term()],
          found: Heddle.ETF.found()
        }

  defexception [:path, :offset, :reason, :expected, :found]

  @impl true
  def message(%__MODULE__{} = e) do
    "cannot decode at offset #{e.offset}, path #{inspect(e.path)}: #{describe(e.reason)}; " <>
      "expected #{inspect(e.expected, limit: 10)}, found #{inspect(e.found, limit: 10)}"
  end

  defp describe({:refine, reason}), do: "refinement #{inspect(reason)} failed"
  defp describe(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")
end

defmodule Heddle.EncodeError do
  @moduledoc """
  Why a value could not be encoded.

  Encoding is partial: a value outside the codec's domain fails here instead
  of producing bytes the decoder would later reject.

    * `path` - the keys and indices from the root to the failing value.
    * `reason` - one of the tuples below; values are kept as given, and the
      exception message prints them with a size limit.

  Reasons:

    * `{:type, expected, value}` - the value has the wrong type or literal.
    * `{:out_of_range, integer}` - outside the codec's integer range.
    * `{:too_large, size, max}` - longer than the codec's bound.
    * `{:invalid_utf8, binary}` - the codec requires UTF-8.
    * `{:known_name, name}` - `{:unknown, name}` names a member of the enum.
    * `{:invalid_atom_name, name}` - not valid UTF-8, or longer than 255
      characters.
    * `{:missing_key, key}`, `{:unknown_key, key}` - map keys the codec
      does not accept.
    * `:struct_key` - a `:__struct__` key outside a struct layout.
    * `{:duplicate_key, key}` - two keys encode to the same decoded key.
    * `{:no_alternative, value}` - no `one_of/1` alternative takes the value.
    * `{:iso, value}` - an `iso/3` function returned `:error`.
    * `{:refine, reason, value}` - a `refine/3` predicate failed.
    * `{:getter, value}` - a `from/2` getter returned `:error`.
    * `{:arity, expected, actual}` - a sequence produced the wrong number of
      elements.
  """

  @type t :: %__MODULE__{path: [term()], reason: term()}

  defexception [:path, :reason]

  @impl true
  def message(%__MODULE__{path: path, reason: reason}) do
    "cannot encode at path #{inspect(path)}: #{inspect(reason, limit: 10, printable_limit: 64)}"
  end
end

defmodule Heddle.CodecError do
  @moduledoc """
  An invalid codec, raised when the codec is built.

  Compiled codecs report the same problems as `CompileError`s rendered by
  pentiment, with source excerpts; codecs built at runtime raise this
  exception, whose message has no excerpts.

    * `code` - a stable identifier, such as `"H001"`.
    * `summary` - one line naming the problem.
    * `labels` - `{codec_or_nil, text}` pairs naming the codecs involved,
      primary first.
    * `help` - how to fix it, or `nil`.
  """

  @type t :: %__MODULE__{
          code: String.t(),
          summary: String.t(),
          labels: [{Heddle.t() | nil, String.t()}],
          help: String.t() | nil
        }

  defexception [:code, :summary, labels: [], help: nil]

  @impl true
  def message(%__MODULE__{} = e) do
    labels = Enum.map_join(e.labels, "", fn {_codec, text} -> "\n  - #{text}" end)
    help = if e.help, do: "\n  help: #{e.help}", else: ""
    "[#{e.code}] #{e.summary}#{labels}#{help}"
  end
end

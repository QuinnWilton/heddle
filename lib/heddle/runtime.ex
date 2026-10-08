defmodule Heddle.Runtime do
  @moduledoc false
  # Pieces shared by the interpreter and compiled codecs. Every decision that
  # shapes a decode error lives here, so the two backends report the same
  # reason, offset, expected set and found description for the same bytes.
  #
  # The decoder calling convention, used by both backends and across modules:
  #
  #     decode(rest, depth, nodes, lim) ::
  #       {:ok, value, rest, nodes} | {:error, failure}
  #
  # where `rest` starts at the term's tag byte, `depth` is the term's depth,
  # `nodes` is the remaining node budget, and `lim` is a `t:lim/0`.
  #
  # The encoder convention:
  #
  #     encode(value) :: {:ok, decoded, iodata} | {:error, {path, reason}}
  #
  # where `decoded` is what decoding the produced bytes returns.

  alias Heddle.{DecodeError, EncodeError, ETF}

  @type mode :: :compiled | :interpret
  @type lim ::
          {max_depth :: pos_integer(), max_nodes :: pos_integer(), copy? :: boolean(), mode()}

  @typedoc "A decode failure before its offset is known: `remaining` is the input left at the failing position."
  @type failure ::
          {reason :: DecodeError.reason(), expected :: [term()], found :: ETF.found(),
           remaining :: non_neg_integer(), path :: [term()]}

  @type dec_result :: {:ok, term(), binary(), integer()} | {:error, failure()}
  @type enc_result :: {:ok, term(), iodata()} | {:error, {[term()], term()}}

  @doc false
  @spec lim(Heddle.Limits.t(), mode()) :: lim()
  def lim(limits, mode), do: {limits.max_depth, limits.max_nodes, limits.binaries == :copy, mode}

  @doc false
  @spec fail(DecodeError.reason(), [term()], binary()) :: {:error, failure()}
  def fail(reason, expected, rest),
    do: {:error, {reason, expected, ETF.describe(rest), byte_size(rest), []}}

  @doc false
  @spec prefix(dec_result(), term()) :: dec_result()
  def prefix({:error, {r, e, f, rem, path}}, segment),
    do: {:error, {r, e, f, rem, [segment | path]}}

  def prefix(ok, _segment), do: ok

  @doc false
  @spec enc_prefix(enc_result(), term()) :: enc_result()
  def enc_prefix({:error, {path, reason}}, segment), do: {:error, {[segment | path], reason}}
  def enc_prefix(ok, _segment), do: ok

  # Checked when a codec starts consuming a term, before its tag: depth first,
  # then the node budget. Returns the budget after charging the term.
  @doc false
  @spec enter(binary(), pos_integer(), integer(), lim()) :: {:ok, integer()} | {:error, failure()}
  def enter(rest, depth, nodes, {max_depth, max_nodes, _, _}) do
    cond do
      depth > max_depth -> fail(:max_depth, [{:max_depth, max_depth}], rest)
      nodes <= 0 -> fail(:max_nodes, [{:max_nodes, max_nodes}], rest)
      true -> {:ok, nodes - 1}
    end
  end

  # The failure for an atom codec whose literal clauses did not match.
  @doc false
  @spec atom_failure(binary(), [term()]) :: {:error, failure()}
  def atom_failure(rest, expected) do
    reason =
      case ETF.read_atom_name(rest) do
        {:ok, _, _} -> :unexpected
        {:error, reason} -> reason
      end

    fail(reason, expected, rest)
  end

  # The failure for a reader error from `Heddle.ETF`.
  @doc false
  @spec read_failure(ETF.read_error(), [term()], binary()) :: {:error, failure()}
  def read_failure(reason, expected, rest), do: fail(reason, expected, rest)

  # Length checks before allocation, in this order: the codec's bound, the
  # input left (each element takes at least `min_bytes`), then the node
  # budget (each element takes `per_node` nodes).
  @doc false
  @spec check_count(
          non_neg_integer(),
          non_neg_integer() | nil,
          non_neg_integer(),
          integer(),
          pos_integer(),
          integer(),
          [term()],
          binary(),
          lim()
        ) ::
          :ok | {:error, failure()}
  def check_count(
        count,
        max,
        min_bytes,
        available,
        per_node,
        nodes,
        expected,
        at,
        {_, max_nodes, _, _}
      ) do
    cond do
      max != nil and count > max -> fail(:too_large, expected, at)
      count * min_bytes > available -> fail(:unexpected_eof, expected, at)
      count * per_node > nodes -> fail(:max_nodes, [{:max_nodes, max_nodes}], at)
      true -> :ok
    end
  end

  @doc false
  @spec keep(binary(), lim()) :: binary()
  def keep(bin, {_, _, true, _}), do: :binary.copy(bin)
  def keep(bin, {_, _, false, _}), do: bin

  # Runs an element decoder over one byte of a STRING_EXT as though it were a
  # SMALL_INTEGER_EXT, reporting failures at that byte's offset.
  @doc false
  @spec string_byte(
          byte(),
          non_neg_integer(),
          (binary(), pos_integer(), integer(), lim() -> dec_result()),
          pos_integer(),
          integer(),
          lim()
        ) ::
          dec_result()
  def string_byte(byte, remaining, decode, depth, nodes, lim) do
    case decode.(<<97, byte>>, depth, nodes, lim) do
      {:ok, value, <<>>, nodes} -> {:ok, value, <<>>, nodes}
      {:error, {r, e, f, _, path}} -> {:error, {r, e, f, remaining, path}}
    end
  end

  @doc false
  @spec codepoint?(term()) :: boolean()
  def codepoint?(c), do: is_integer(c) and c >= 0 and c <= 0x10FFFF and (c < 0xD800 or c > 0xDFFF)

  ## Top level

  @doc false
  @spec run_decode(binary(), Heddle.Limits.t(), mode(), (binary(),
                                                         pos_integer(),
                                                         integer(),
                                                         lim() ->
                                                           dec_result())) ::
          {:ok, term()} | {:error, DecodeError.t()}
  def run_decode(binary, limits, mode, decode) do
    total = byte_size(binary)

    cond do
      total > limits.max_bytes ->
        {:error,
         %DecodeError{
           path: [],
           offset: 0,
           reason: :max_bytes,
           expected: [{:max_bytes, limits.max_bytes}],
           found: {:bytes, total}
         }}

      true ->
        top(binary, total, limits, mode, decode)
    end
  end

  defp top(<<131, 80, _::binary>> = bin, total, _, _, _),
    do: top_error(:compressed, bin, 1, total)

  defp top(<<131, 68, _::binary>> = bin, total, _, _, _),
    do: top_error(:distribution_header, bin, 1, total)

  defp top(<<131, rest::binary>>, total, limits, mode, decode) do
    lim = lim(limits, mode)

    case decode.(rest, 1, limits.max_nodes, lim) do
      {:ok, value, <<>>, _} ->
        {:ok, value}

      {:ok, _, trailing, _} ->
        {:error,
         %DecodeError{
           path: [],
           offset: total - byte_size(trailing),
           reason: :trailing_bytes,
           expected: [:end_of_input],
           found: ETF.describe(trailing)
         }}

      {:error, {reason, expected, found, remaining, path}} ->
        {:error,
         %DecodeError{
           path: path,
           offset: total - remaining,
           reason: reason,
           expected: expected,
           found: found
         }}
    end
  end

  defp top(bin, _total, _, _, _) do
    found =
      case bin do
        <<byte, _::binary>> -> {:byte, byte}
        <<>> -> :eof
      end

    {:error,
     %DecodeError{
       path: [],
       offset: 0,
       reason: :version,
       expected: [{:version, 131}],
       found: found
     }}
  end

  defp top_error(reason, <<131, rest::binary>>, offset, _total) do
    {:error,
     %DecodeError{
       path: [],
       offset: offset,
       reason: reason,
       expected: [:term],
       found: ETF.describe(rest)
     }}
  end

  @doc false
  @spec finish_encode(enc_result()) :: {:ok, term(), iodata()} | {:error, EncodeError.t()}
  def finish_encode({:ok, y, iodata}), do: {:ok, y, iodata}

  def finish_encode({:error, {path, reason}}),
    do: {:error, %EncodeError{path: path, reason: reason}}

  ## Encoding pieces

  # Proper-list length, or :improper.
  @doc false
  @spec proper_length(list()) :: non_neg_integer() | :improper
  def proper_length(list), do: proper_length(list, 0)
  defp proper_length([], n), do: n
  defp proper_length([_ | tail], n), do: proper_length(tail, n + 1)
  defp proper_length(_, _), do: :improper

  # A list whose elements all encoded as SMALL_INTEGER_EXT, written as
  # STRING_EXT, as term_to_binary does; otherwise LIST_EXT.
  @doc false
  @spec list_bytes([iodata()], non_neg_integer()) :: iodata()
  def list_bytes([], 0), do: ETF.nil_ext()

  def list_bytes(elems, n) do
    case n < 65_536 and string_bytes(elems, []) do
      bytes when is_binary(bytes) -> ETF.string_ext(bytes)
      _ -> [ETF.list_header(n), elems, ETF.nil_ext()]
    end
  end

  defp string_bytes([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp string_bytes([<<97, b>> | rest], acc), do: string_bytes(rest, [b | acc])

  defp string_bytes([io | rest], acc) when is_list(io) do
    case IO.iodata_to_binary(io) do
      <<97, b>> -> string_bytes(rest, [b | acc])
      _ -> false
    end
  end

  defp string_bytes(_, _), do: false

  # A map's pairs, keys sorted by their encoded bytes.
  @doc false
  @spec map_bytes([{binary(), iodata()}]) :: iodata()
  def map_bytes(pairs) do
    sorted = Enum.sort_by(pairs, &elem(&1, 0))
    [ETF.map_header(length(pairs)) | Enum.map(sorted, fn {k, v} -> [k, v] end)]
  end

  @doc false
  @spec get(Heddle.getter(), term()) :: {:ok, term()} | :error
  def get(%Heddle.IR.Field{key: key}, value) when is_map(value) do
    case value do
      %{^key => part} -> {:ok, part}
      _ -> :error
    end
  end

  def get(%Heddle.IR.Field{}, _value), do: :error

  def get(getter, value) when is_function(getter, 1) do
    case getter.(value) do
      {:ok, part} ->
        {:ok, part}

      :error ->
        :error

      other ->
        raise ArgumentError,
              "a Heddle.from/2 getter must return {:ok, part} or :error, got: #{inspect(other)}"
    end
  end

  @doc false
  @spec call_iso((term() -> term()), term()) :: {:ok, term()} | :error
  def call_iso(fun, value) do
    case fun.(value) do
      {:ok, result} ->
        {:ok, result}

      :error ->
        :error

      other ->
        raise ArgumentError,
              "a Heddle.iso/3 function must return {:ok, value} or :error, got: #{inspect(other)}"
    end
  end
end

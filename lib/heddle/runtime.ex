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
          {non_neg_integer(), integer()},
          pos_integer(),
          integer(),
          [term()],
          binary(),
          lim()
        ) :: :ok | {:error, failure()}
  def check_count(
        count,
        max,
        {min_bytes, available},
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

    if total > limits.max_bytes do
      {:error,
       %DecodeError{
         path: [],
         offset: 0,
         reason: :max_bytes,
         expected: [{:max_bytes, limits.max_bytes}],
         found: {:bytes, total}
       }}
    else
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

  ## Shared readers
  #
  # Each reads one term whose limits were already checked (see enter/4) and
  # implements the codec's full semantics. Compiled codecs try inline fast
  # paths first and fall back to these for everything else, errors included.

  @doc false
  @spec read_integer(binary(), integer(), integer() | nil, integer() | nil, [term()]) ::
          dec_result()
  def read_integer(rest, nodes, min, max, expected) do
    case ETF.read_integer(rest, ETF.big_bytes_for(min, max)) do
      {:ok, i, after_term} ->
        if (min == nil or i >= min) and (max == nil or i <= max),
          do: {:ok, i, after_term, nodes},
          else: fail(:out_of_range, expected, rest)

      {:error, reason} ->
        fail(reason, expected, rest)
    end
  end

  @doc false
  @spec read_char(binary(), integer(), [term()]) :: dec_result()
  def read_char(rest, nodes, expected) do
    case ETF.read_integer(rest, 3) do
      {:ok, c, after_term} ->
        if codepoint?(c),
          do: {:ok, c, after_term, nodes},
          else: fail(:out_of_range, expected, rest)

      {:error, reason} ->
        fail(reason, expected, rest)
    end
  end

  @doc false
  @spec read_float(binary(), integer(), [term()]) :: dec_result()
  def read_float(rest, nodes, expected) do
    case rest do
      <<70, f::float-64, after_term::binary>> -> {:ok, f, after_term, nodes}
      <<70, _::64, _::binary>> -> fail(:invalid_float, expected, rest)
      <<70, _::binary>> -> fail(:unexpected_eof, expected, rest)
      _ -> fail(:unexpected, expected, rest)
    end
  end

  @doc false
  @spec read_binary(binary(), integer(), non_neg_integer() | nil, boolean(), [term()], lim()) ::
          dec_result()
  def read_binary(rest, nodes, max, utf8, expected, lim) do
    case rest do
      <<109, len::32, body::binary>> ->
        cond do
          max != nil and len > max ->
            fail(:too_large, expected, rest)

          byte_size(body) < len ->
            fail(:unexpected_eof, expected, rest)

          true ->
            <<bin::binary-size(^len), after_term::binary>> = body

            if utf8 and not Heddle.SWAR.utf8?(bin),
              do: fail(:invalid_utf8, expected, rest),
              else: {:ok, keep(bin, lim), after_term, nodes}
        end

      <<109, _::binary>> ->
        fail(:unexpected_eof, expected, rest)

      _ ->
        fail(:unexpected, expected, rest)
    end
  end

  @doc false
  @spec read_existing_atom(binary(), integer(), [term()]) :: dec_result()
  def read_existing_atom(rest, nodes, expected) do
    case ETF.read_atom_name(rest) do
      {:ok, name, after_term} ->
        try do
          {:ok, :erlang.binary_to_existing_atom(name, :utf8), after_term, nodes}
        rescue
          ArgumentError -> fail(:unknown_atom, expected, rest)
        end

      {:error, reason} ->
        fail(reason, expected, rest)
    end
  end

  # `names` maps each member's name to the atom.
  @doc false
  @spec read_enum(binary(), integer(), %{String.t() => atom()}, :reject | :keep, [term()]) ::
          dec_result()
  def read_enum(rest, nodes, names, unknown, expected) do
    case ETF.read_atom_name(rest) do
      {:ok, name, after_term} ->
        case names do
          %{^name => atom} -> {:ok, atom, after_term, nodes}
          _ when unknown == :keep -> {:ok, {:unknown, :binary.copy(name)}, after_term, nodes}
          _ -> fail(:unexpected, expected, rest)
        end

      {:error, reason} ->
        fail(reason, expected, rest)
    end
  end

  @doc false
  @spec tuple_header(binary()) ::
          {:ok, non_neg_integer(), binary()} | {:error, :unexpected | :unexpected_eof}
  def tuple_header(<<104, n, body::binary>>), do: {:ok, n, body}
  def tuple_header(<<105, n::32, body::binary>>), do: {:ok, n, body}
  def tuple_header(<<tag, _::binary>>) when tag in [104, 105], do: {:error, :unexpected_eof}
  def tuple_header(_), do: {:error, :unexpected}

  # The failure for a tuple whose header did not match the codec's arity.
  @doc false
  @spec tuple_failure(binary(), [term()]) :: {:error, failure()}
  def tuple_failure(rest, expected) do
    case tuple_header(rest) do
      {:ok, _, _} -> fail(:unexpected, expected, rest)
      {:error, reason} -> fail(reason, expected, rest)
    end
  end

  @doc false
  @spec list_tail(binary(), list(), integer()) :: dec_result()
  def list_tail(<<106, after_term::binary>>, acc, nodes),
    do: {:ok, :lists.reverse(acc), after_term, nodes}

  def list_tail(rest, _acc, _nodes), do: fail(:improper_list, [:nil_ext], rest)

  # The failure for a map key that is not one of the codec's atom keys.
  @doc false
  @spec key_failure(binary(), [term()]) :: {:error, failure()}
  def key_failure(rest, key_expected) do
    case ETF.read_atom_name(rest) do
      {:ok, _, _} -> fail(:unknown_key, key_expected, rest)
      {:error, :unexpected} -> fail(:unknown_key, key_expected, rest)
      {:error, reason} -> fail(reason, key_expected, rest)
    end
  end

  @doc false
  @spec check_map_key(term(), map(), [term()], binary()) :: :ok | {:error, failure()}
  def check_map_key(:__struct__, _acc, expected, rest), do: fail(:struct_key, expected, rest)

  def check_map_key(key, acc, expected, rest) do
    if is_map_key(acc, key), do: fail(:duplicate_key, expected, rest), else: :ok
  end

  @doc false
  @spec missing([atom()], map(), binary()) :: :ok | {:error, failure()}
  def missing(required, acc, map_start) do
    case Enum.find(required, &(not is_map_key(acc, &1))) do
      nil -> :ok
      key -> fail(:missing_key, [{:key, key}], map_start)
    end
  end

  @doc false
  @spec missing_mask(non_neg_integer(), [{atom(), pos_integer()}], binary()) ::
          {:error, failure()}
  def missing_mask(seen, required_bits, map_start) do
    {key, _} = Enum.find(required_bits, fn {_, bit} -> Bitwise.band(seen, bit) == 0 end)
    fail(:missing_key, [{:key, key}], map_start)
  end

  # Fills defaulted fields the input omitted and the fields the codec does
  # not serialize, from the struct's own defaults.
  @doc false
  @spec build_struct(module(), [{atom(), {:ok, term()} | :none}], map()) :: struct()
  def build_struct(module, defaults, acc) do
    values =
      Enum.reduce(defaults, Map.delete(acc, :__struct__), fn
        {name, {:ok, default}}, acc -> Map.put_new(acc, name, default)
        {_, :none}, acc -> acc
      end)

    module |> Kernel.struct() |> Map.merge(values)
  end

  @doc false
  @spec check_param!(term(), String.t()) :: non_neg_integer()
  def check_param!(value, _context) when is_integer(value) and value >= 0, do: value

  def check_param!(value, context) do
    raise Heddle.CodecError,
      code: "H004",
      summary: "#{context} must be a non-negative integer, got #{inspect(value)}",
      labels: []
  end

  @doc false
  @spec check_int_param!(term(), String.t()) :: integer() | nil
  def check_int_param!(value, _context) when is_integer(value) or is_nil(value), do: value

  def check_int_param!(value, context) do
    raise Heddle.CodecError,
      code: "H004",
      summary: "#{context} must be an integer, got #{inspect(value)}",
      labels: []
  end

  # The constructor's min <= max check, for integer codecs whose bounds are
  # parameters; each bound is a literal or {:param, index}.
  @doc false
  @spec check_ranges!(tuple(), [{term(), term()}]) :: :ok
  def check_ranges!(ps, pairs) do
    Enum.each(pairs, fn {min, max} ->
      {min, max} = {param_value(min, ps), param_value(max, ps)}

      if is_integer(min) and is_integer(max) and min > max do
        raise Heddle.CodecError,
          code: "H004",
          summary: "Heddle.integer/1 has min #{min} above max #{max}",
          labels: []
      end
    end)
  end

  defp param_value({:param, i}, ps), do: elem(ps, i)
  defp param_value(value, _ps), do: value

  ## Shared encoders

  @doc false
  @spec enc_integer(term(), integer() | nil, integer() | nil) :: enc_result()
  def enc_integer(v, min, max) when is_integer(v) do
    if (min == nil or v >= min) and (max == nil or v <= max),
      do: {:ok, v, ETF.encode_integer(v)},
      else: {:error, {[], {:out_of_range, v}}}
  end

  def enc_integer(v, _, _), do: {:error, {[], {:type, :integer, v}}}

  @doc false
  @spec enc_char(term()) :: enc_result()
  def enc_char(v) when is_integer(v) do
    if codepoint?(v),
      do: {:ok, v, ETF.encode_integer(v)},
      else: {:error, {[], {:out_of_range, v}}}
  end

  def enc_char(v), do: {:error, {[], {:type, :char, v}}}

  @doc false
  @spec enc_float(term()) :: enc_result()
  def enc_float(v) when is_float(v), do: {:ok, v, ETF.encode_float(v)}
  def enc_float(v), do: {:error, {[], {:type, :float, v}}}

  @doc false
  @spec enc_binary(term(), non_neg_integer() | nil, boolean()) :: enc_result()
  def enc_binary(v, max, utf8) do
    cond do
      not is_binary(v) -> {:error, {[], {:type, :binary, v}}}
      max != nil and byte_size(v) > max -> {:error, {[], {:too_large, byte_size(v), max}}}
      utf8 and not Heddle.SWAR.utf8?(v) -> {:error, {[], {:invalid_utf8, v}}}
      true -> {:ok, v, [ETF.binary_header(byte_size(v)), v]}
    end
  end

  @doc false
  @spec enc_existing_atom(term()) :: enc_result()
  def enc_existing_atom(v) when is_atom(v), do: {:ok, v, ETF.encode_atom(v)}
  def enc_existing_atom(v), do: {:error, {[], {:type, :atom, v}}}

  @doc false
  @spec enc_enum(term(), [atom()], :reject | :keep) :: enc_result()
  def enc_enum(v, atoms, unknown) do
    cond do
      is_atom(v) and v in atoms ->
        {:ok, v, ETF.encode_atom(v)}

      unknown == :keep and match?({:unknown, _}, v) ->
        {:unknown, name} = v

        cond do
          not ETF.valid_atom_name?(name) -> {:error, {[], {:invalid_atom_name, name}}}
          Enum.any?(atoms, &(Atom.to_string(&1) == name)) -> {:error, {[], {:known_name, name}}}
          true -> {:ok, v, ETF.encode_atom_name(name)}
        end

      true ->
        {:error, {[], {:type, {:enum, atoms}, v}}}
    end
  end

  @doc false
  @spec enc_list(term(), non_neg_integer() | nil, (term() -> enc_result())) :: enc_result()
  def enc_list(value, max, enc_elem) when is_list(value) do
    case proper_length(value) do
      :improper -> {:error, {[], {:type, :proper_list, value}}}
      n when max != nil and n > max -> {:error, {[], {:too_large, n, max}}}
      n -> enc_elems(value, enc_elem, 0, :same, [], n, value)
    end
  end

  def enc_list(value, _max, _enc_elem), do: {:error, {[], {:type, :list, value}}}

  # `ys` stays :same while every decoded element is the input element, so a
  # list that round-trips unchanged is returned as is instead of rebuilt.
  defp enc_elems([], _enc, _i, :same, ios, n, original),
    do: {:ok, original, list_bytes(:lists.reverse(ios), n)}

  defp enc_elems([], _enc, _i, ys, ios, n, _original),
    do: {:ok, :lists.reverse(ys), list_bytes(:lists.reverse(ios), n)}

  defp enc_elems([v | rest], enc, i, ys, ios, n, original) do
    case enc.(v) do
      {:ok, y, io} when ys == :same and y === v ->
        enc_elems(rest, enc, i + 1, :same, [io | ios], n, original)

      {:ok, y, io} when ys == :same ->
        prefix = original |> Enum.take(i) |> :lists.reverse()
        enc_elems(rest, enc, i + 1, [y | prefix], [io | ios], n, original)

      {:ok, y, io} ->
        enc_elems(rest, enc, i + 1, [y | ys], [io | ios], n, original)

      error ->
        enc_prefix(error, i)
    end
  end

  # The bytes of a non-empty proper list of integers in lo..hi with at most
  # `limit` elements, or :error; lo..hi lies within 0..255.
  @doc false
  @spec byte_list(term(), byte(), byte(), non_neg_integer()) :: {:ok, binary()} | :error
  def byte_list([_ | _] = list, lo, hi, limit) do
    if bytes_ok?(list, lo, hi, limit, 0), do: {:ok, :erlang.list_to_binary(list)}, else: :error
  end

  def byte_list(_value, _lo, _hi, _limit), do: :error

  defp bytes_ok?([b | rest], lo, hi, limit, n)
       when is_integer(b) and b >= lo and b <= hi and n < limit,
       do: bytes_ok?(rest, lo, hi, limit, n + 1)

  defp bytes_ok?([], _lo, _hi, _limit, _n), do: true
  defp bytes_ok?(_, _lo, _hi, _limit, _n), do: false

  # `required` and `optional` list {key, encoder}.
  @doc false
  @spec enc_map(term(), [{atom(), (term() -> enc_result())}], [{atom(), (term() -> enc_result())}]) ::
          enc_result()
  def enc_map(value, required, optional) do
    cond do
      not is_map(value) ->
        {:error, {[], {:type, :map, value}}}

      is_map_key(value, :__struct__) ->
        {:error, {[], :struct_key}}

      true ->
        named = required ++ optional

        with :ok <- unknown_keys(value, named),
             :ok <- missing_keys(value, required),
             present = Enum.filter(named, fn {key, _} -> is_map_key(value, key) end),
             {:ok, ys, same, pairs} <- enc_fields(present, value) do
          {:ok, if(same, do: value, else: ys), map_bytes(pairs)}
        end
    end
  end

  defp unknown_keys(value, named) do
    names = Map.new(named)

    case value |> Map.keys() |> Enum.sort() |> Enum.find(&(not is_map_key(names, &1))) do
      nil -> :ok
      key -> {:error, {[], {:unknown_key, key}}}
    end
  end

  defp missing_keys(value, required) do
    case Enum.find(required, fn {key, _} -> not is_map_key(value, key) end) do
      nil -> :ok
      {key, _} -> {:error, {[], {:missing_key, key}}}
    end
  end

  # Also reports whether every decoded field is the input field.
  defp enc_fields(fields, value) do
    Enum.reduce_while(fields, {:ok, %{}, true, []}, fn {key, enc}, {:ok, ys, same, pairs} ->
      v = Map.fetch!(value, key)

      case enc.(v) |> enc_prefix(key) do
        {:ok, y, io} ->
          {:cont,
           {:ok, Map.put(ys, key, y), same and y === v, [{ETF.encode_atom(key), io} | pairs]}}

        error ->
          {:halt, error}
      end
    end)
  end

  @doc false
  @spec enc_struct(term(), module(), :map | {:tuple, atom() | nil}, [
          {atom(), (term() -> enc_result())}
        ]) :: enc_result()
  def enc_struct(value, module, layout, fields) do
    if is_struct(value, module) and Enum.all?(fields, fn {key, _} -> is_map_key(value, key) end) do
      with {:ok, ys, _same, pairs} <- enc_fields(fields, value) do
        y = module |> Kernel.struct() |> Map.merge(ys)

        case layout do
          :map ->
            struct_pair = {ETF.encode_atom(:__struct__), ETF.encode_atom(module)}
            {:ok, y, map_bytes([struct_pair | pairs])}

          {:tuple, tag} ->
            ios = pairs |> :lists.reverse() |> Enum.map(&elem(&1, 1))
            ios = if tag, do: [ETF.encode_atom(tag) | ios], else: ios
            {:ok, y, [ETF.tuple_header(length(ios)) | ios]}
        end
      end
    else
      {:error, {[], {:type, {:struct, module}, value}}}
    end
  end

  @doc false
  @spec enc_map_of(term(), non_neg_integer() | nil, (term() -> enc_result()), (term() ->
                                                                                 enc_result())) ::
          enc_result()
  def enc_map_of(value, max, enc_key, enc_value) do
    cond do
      not is_map(value) ->
        {:error, {[], {:type, :map, value}}}

      is_map_key(value, :__struct__) ->
        {:error, {[], :struct_key}}

      max != nil and map_size(value) > max ->
        {:error, {[], {:too_large, map_size(value), max}}}

      true ->
        value
        |> Enum.sort()
        |> Enum.reduce_while({:ok, %{}, []}, fn {k, v}, {:ok, ys, pairs} ->
          with {:ok, yk, kio} <- enc_key.(k) |> enc_prefix({:key, k}),
               :ok <- encoded_key(yk, ys, k),
               {:ok, yv, vio} <- enc_value.(v) |> enc_prefix(k) do
            {:cont, {:ok, Map.put(ys, yk, yv), [{IO.iodata_to_binary(kio), vio} | pairs]}}
          else
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, ys, pairs} -> {:ok, ys, map_bytes(pairs)}
          error -> error
        end
    end
  end

  defp encoded_key(:__struct__, _ys, k), do: {:error, {[k], :struct_key}}

  defp encoded_key(yk, ys, k) do
    if is_map_key(ys, yk), do: {:error, {[k], {:duplicate_key, yk}}}, else: :ok
  end
end

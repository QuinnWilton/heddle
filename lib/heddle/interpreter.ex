defmodule Heddle.Interpreter do
  @moduledoc """
  The reference semantics of Heddle codecs.

  `Heddle.decode/3` and `Heddle.encode/2` run codecs built at runtime here.
  Compiled codecs must agree with this module on every input: the same value,
  or the same error at the same offset. `decode/3` and `encode/2` here
  interpret compiled codecs too, following references into their IR, which is
  what the differential tests compare against.
  """

  alias Heddle.{ETF, IR, Limits, Runtime}

  @doc "Decodes with the interpreter, including inside compiled codecs."
  @spec decode(Heddle.t(), binary(), Limits.t() | [Limits.option()]) ::
          {:ok, term()} | {:error, Heddle.DecodeError.t()}
  def decode(codec, binary, opts), do: decode(codec, binary, opts, :interpret)

  @doc false
  @spec decode(Heddle.t(), binary(), Limits.t() | [Limits.option()], Runtime.mode()) ::
          {:ok, term()} | {:error, Heddle.DecodeError.t()}
  def decode(codec, binary, opts, mode) do
    limits = Limits.new(opts)
    with_cache(fn -> Runtime.run_decode(binary, limits, mode, &dec(codec, &1, &2, &3, &4)) end)
  end

  @doc "Encodes with the interpreter, including inside compiled codecs; returns the decoded value too."
  @spec encode(Heddle.t(), term()) :: {:ok, term(), iodata()} | {:error, Heddle.EncodeError.t()}
  def encode(codec, value), do: encode(codec, value, :interpret)

  @doc false
  @spec encode(Heddle.t(), term(), Runtime.mode()) ::
          {:ok, term(), iodata()} | {:error, Heddle.EncodeError.t()}
  def encode(codec, value, mode) do
    with_cache(fn -> Runtime.finish_encode(enc(codec, value, mode)) end)
  end

  # Forced lazies and resolved references are cached for one top-level call.
  defp with_cache(fun) do
    if Process.get(:heddle_cache) do
      fun.()
    else
      Process.put(:heddle_cache, %{})

      try do
        fun.()
      after
        Process.delete(:heddle_cache)
      end
    end
  end

  defp cached(key, build) do
    cache = Process.get(:heddle_cache, %{})

    case cache do
      %{^key => value} ->
        value

      _ ->
        value = build.()
        Process.put(:heddle_cache, Map.put(Process.get(:heddle_cache, %{}), key, value))
        value
    end
  end

  defp forced(%Heddle{node: {:lazy, thunk}} = codec),
    do: cached({:lazy, thunk}, fn -> IR.force(codec) end)

  defp resolved(module, name),
    do: cached({:ref, module, name}, fn -> IR.ir_of_ref(module, name) end)

  ## Decoding

  @doc false
  @spec dec(Heddle.t(), binary(), pos_integer(), integer(), Runtime.lim()) :: Runtime.dec_result()
  def dec(%Heddle{node: node} = codec, rest, depth, nodes, lim) do
    case node do
      {:one_of, alts, firsts, _} -> dec_one_of(codec, alts, firsts, rest, depth, nodes, lim)
      {:iso, inner, decode, _} -> dec_iso(inner, decode, rest, depth, nodes, lim)
      {:refine, inner, pred, reason} -> dec_refine(inner, pred, reason, rest, depth, nodes, lim)
      {:from, inner, _} -> dec(inner, rest, depth, nodes, lim)
      {:lazy, _} -> dec(forced(codec), rest, depth, nodes, lim)
      {:ref, module, name} -> dec_ref(module, name, rest, depth, nodes, lim)
      _ -> consume(codec, rest, depth, nodes, lim)
    end
  end

  defp dec_ref(module, name, rest, depth, nodes, {_, _, _, :compiled} = lim),
    do: module.__heddle_decode__(name, rest, depth, nodes, lim)

  defp dec_ref(module, name, rest, depth, nodes, lim),
    do: dec(resolved(module, name), rest, depth, nodes, lim)

  defp dec_one_of(codec, alts, firsts, rest, depth, nodes, lim) do
    class = ETF.classify(rest)

    case IR.choose(firsts, &IR.first_matches?(&1, class)) do
      nil -> Runtime.fail(:unexpected, IR.expected(codec), rest)
      index -> dec(Enum.at(alts, index), rest, depth, nodes, lim)
    end
  end

  defp dec_iso(inner, decode, rest, depth, nodes, lim) do
    with {:ok, value, after_term, nodes} <- dec(inner, rest, depth, nodes, lim) do
      case Runtime.call_iso(decode, value) do
        {:ok, result} -> {:ok, result, after_term, nodes}
        :error -> Runtime.fail(:iso, IR.expected(inner), rest)
      end
    end
  end

  defp dec_refine(inner, pred, reason, rest, depth, nodes, lim) do
    with {:ok, value, after_term, nodes} <- dec(inner, rest, depth, nodes, lim) do
      if pred.(value),
        do: {:ok, value, after_term, nodes},
        else: Runtime.fail({:refine, reason}, IR.expected(inner), rest)
    end
  end

  # Codecs that consume a term: limits first, then the bytes.
  defp consume(codec, rest, depth, nodes, lim) do
    with {:ok, nodes} <- Runtime.enter(rest, depth, nodes, lim) do
      read(codec, rest, depth, nodes, lim)
    end
  end

  defp read(%Heddle{node: {:literal, atom}} = codec, rest, _depth, nodes, _lim) do
    name = Atom.to_string(atom)

    case ETF.read_atom_name(rest) do
      {:ok, ^name, after_term} -> {:ok, atom, after_term, nodes}
      _ -> Runtime.atom_failure(rest, IR.expected(codec))
    end
  end

  defp read(%Heddle{node: {:enum, atoms, unknown}} = codec, rest, _depth, nodes, _lim) do
    case ETF.read_atom_name(rest) do
      {:ok, name, after_term} ->
        case Enum.find(atoms, &(Atom.to_string(&1) == name)) do
          nil when unknown == :keep -> {:ok, {:unknown, :binary.copy(name)}, after_term, nodes}
          nil -> Runtime.fail(:unexpected, IR.expected(codec), rest)
          atom -> {:ok, atom, after_term, nodes}
        end

      {:error, reason} ->
        Runtime.read_failure(reason, IR.expected(codec), rest)
    end
  end

  defp read(%Heddle{node: :existing_atom} = codec, rest, _depth, nodes, _lim) do
    case ETF.read_atom_name(rest) do
      {:ok, name, after_term} ->
        try do
          {:ok, String.to_existing_atom(name), after_term, nodes}
        rescue
          ArgumentError -> Runtime.fail(:unknown_atom, IR.expected(codec), rest)
        end

      {:error, reason} ->
        Runtime.read_failure(reason, IR.expected(codec), rest)
    end
  end

  defp read(%Heddle{node: {:integer, min, max}} = codec, rest, _depth, nodes, _lim) do
    case ETF.read_integer(rest, ETF.big_bytes_for(min, max)) do
      {:ok, i, after_term} ->
        if (min == nil or i >= min) and (max == nil or i <= max),
          do: {:ok, i, after_term, nodes},
          else: Runtime.fail(:out_of_range, IR.expected(codec), rest)

      {:error, reason} ->
        Runtime.read_failure(reason, IR.expected(codec), rest)
    end
  end

  defp read(%Heddle{node: :char} = codec, rest, _depth, nodes, _lim) do
    case ETF.read_integer(rest, 3) do
      {:ok, c, after_term} ->
        if Runtime.codepoint?(c),
          do: {:ok, c, after_term, nodes},
          else: Runtime.fail(:out_of_range, IR.expected(codec), rest)

      {:error, reason} ->
        Runtime.read_failure(reason, IR.expected(codec), rest)
    end
  end

  defp read(%Heddle{node: :float} = codec, rest, _depth, nodes, _lim) do
    case rest do
      <<70, f::float-64, after_term::binary>> -> {:ok, f, after_term, nodes}
      <<70, _::64, _::binary>> -> Runtime.fail(:invalid_float, IR.expected(codec), rest)
      <<70, _::binary>> -> Runtime.fail(:unexpected_eof, IR.expected(codec), rest)
      _ -> Runtime.fail(:unexpected, IR.expected(codec), rest)
    end
  end

  defp read(%Heddle{node: {:binary, max, utf8}} = codec, rest, _depth, nodes, lim) do
    expected = IR.expected(codec)

    case rest do
      <<109, len::32, body::binary>> ->
        cond do
          max != nil and len > max ->
            Runtime.fail(:too_large, expected, rest)

          byte_size(body) < len ->
            Runtime.fail(:unexpected_eof, expected, rest)

          true ->
            <<bin::binary-size(^len), after_term::binary>> = body

            if utf8 and not String.valid?(bin),
              do: Runtime.fail(:invalid_utf8, expected, rest),
              else: {:ok, Runtime.keep(bin, lim), after_term, nodes}
        end

      <<109, _::binary>> ->
        Runtime.fail(:unexpected_eof, expected, rest)

      _ ->
        Runtime.fail(:unexpected, expected, rest)
    end
  end

  defp read(%Heddle{node: {:list, elem, max}} = codec, rest, depth, nodes, lim) do
    expected = IR.expected(codec)

    case rest do
      <<106, after_term::binary>> ->
        {:ok, [], after_term, nodes}

      <<107, len::16, body::binary>> ->
        with :ok <-
               Runtime.check_count(len, max, 1, byte_size(body), 1, nodes, expected, rest, lim) do
          string_elems(elem, body, len, 0, byte_size(body), depth + 1, nodes, lim, [])
        end

      <<108, n::32, body::binary>> ->
        with :ok <-
               Runtime.check_count(n, max, 1, byte_size(body) - 1, 1, nodes, expected, rest, lim) do
          list_elems(elem, body, n, 0, depth + 1, nodes, lim, [])
        end

      <<tag, _::binary>> when tag in [107, 108] ->
        Runtime.fail(:unexpected_eof, expected, rest)

      _ ->
        Runtime.fail(:unexpected, expected, rest)
    end
  end

  defp read(%Heddle{node: {:tuple, elems}} = codec, rest, depth, nodes, lim) do
    arity = length(elems)

    case tuple_header(rest) do
      {:ok, ^arity, body} -> tuple_elems(elems, body, 0, depth + 1, nodes, lim, [])
      {:ok, _, _} -> Runtime.fail(:unexpected, IR.expected(codec), rest)
      {:error, reason} -> Runtime.fail(reason, IR.expected(codec), rest)
    end
  end

  defp read(%Heddle{node: {:map, required, optional}} = codec, rest, depth, nodes, lim) do
    table = Map.new(required ++ optional, fn {key, c} -> {Atom.to_string(key), {key, c}} end)
    keys = Enum.map(required ++ optional, &elem(&1, 0))

    with {:ok, acc, after_term, nodes} <-
           read_keyed_map(codec, table, keys, rest, depth, nodes, lim),
         :ok <- missing(Enum.map(required, &elem(&1, 0)), acc, rest) do
      {:ok, acc, after_term, nodes}
    end
  end

  defp read(%Heddle{node: {:struct, module, :map, fields}} = codec, rest, depth, nodes, lim) do
    struct_key = {:__struct__, %Heddle{node: {:literal, module}}}
    entries = [struct_key | Enum.map(fields, fn {name, c, _} -> {name, c} end)]
    table = Map.new(entries, fn {key, c} -> {Atom.to_string(key), {key, c}} end)
    keys = Enum.map(entries, &elem(&1, 0))
    required = [:__struct__ | for({name, _, :none} <- fields, do: name)]

    with {:ok, acc, after_term, nodes} <-
           read_keyed_map(codec, table, keys, rest, depth, nodes, lim),
         :ok <- missing(required, acc, rest) do
      {:ok, build_struct(module, fields, acc), after_term, nodes}
    end
  end

  defp read(
         %Heddle{node: {:struct, module, {:tuple, tag}, fields}} = codec,
         rest,
         depth,
         nodes,
         lim
       ) do
    codecs = Enum.map(fields, &elem(&1, 1))
    elems = if tag, do: [%Heddle{node: {:literal, tag}} | codecs], else: codecs
    arity = length(elems)

    case tuple_header(rest) do
      {:ok, ^arity, body} ->
        with {:ok, tuple, after_term, nodes} <-
               tuple_elems(elems, body, 0, depth + 1, nodes, lim, []) do
          values = tuple |> Tuple.to_list() |> Enum.drop(if(tag, do: 1, else: 0))
          acc = fields |> Enum.map(&elem(&1, 0)) |> Enum.zip(values) |> Map.new()
          {:ok, build_struct(module, fields, acc), after_term, nodes}
        end

      {:ok, _, _} ->
        Runtime.fail(:unexpected, IR.expected(codec), rest)

      {:error, reason} ->
        Runtime.fail(reason, IR.expected(codec), rest)
    end
  end

  defp read(%Heddle{node: {:map_of, key, value, max}} = codec, rest, depth, nodes, lim) do
    expected = IR.expected(codec)

    case rest do
      <<116, n::32, body::binary>> ->
        with :ok <- Runtime.check_count(n, max, 2, byte_size(body), 2, nodes, expected, rest, lim) do
          map_of_pairs(key, value, body, n, 0, depth + 1, nodes, lim, %{})
        end

      <<116, _::binary>> ->
        Runtime.fail(:unexpected_eof, expected, rest)

      _ ->
        Runtime.fail(:unexpected, expected, rest)
    end
  end

  defp read(%Heddle{node: {:tuple_seq, tag, seq}} = codec, rest, depth, nodes, lim) do
    case tuple_header(rest) do
      {:ok, arity, body} ->
        state = %{start: rest, codec: codec, left: arity, index: 0, depth: depth + 1, lim: lim}

        with {:ok, state, body, nodes} <- seq_tag(state, tag, body, nodes) do
          run_seq(seq, state, body, nodes)
        end

      {:error, reason} ->
        Runtime.fail(reason, IR.expected(codec), rest)
    end
  end

  defp tuple_header(<<104, n, body::binary>>), do: {:ok, n, body}
  defp tuple_header(<<105, n::32, body::binary>>), do: {:ok, n, body}
  defp tuple_header(<<tag, _::binary>>) when tag in [104, 105], do: {:error, :unexpected_eof}
  defp tuple_header(_), do: {:error, :unexpected}

  defp tuple_elems([], rest, _i, _depth, nodes, _lim, acc),
    do: {:ok, acc |> Enum.reverse() |> List.to_tuple(), rest, nodes}

  defp tuple_elems([c | cs], rest, i, depth, nodes, lim, acc) do
    case dec(c, rest, depth, nodes, lim) |> Runtime.prefix(i) do
      {:ok, v, rest, nodes} -> tuple_elems(cs, rest, i + 1, depth, nodes, lim, [v | acc])
      error -> error
    end
  end

  defp list_elems(_elem, rest, n, n, _depth, nodes, _lim, acc) do
    case rest do
      <<106, after_term::binary>> -> {:ok, Enum.reverse(acc), after_term, nodes}
      _ -> Runtime.fail(:improper_list, [:nil_ext], rest)
    end
  end

  defp list_elems(elem, rest, n, i, depth, nodes, lim, acc) do
    case dec(elem, rest, depth, nodes, lim) |> Runtime.prefix(i) do
      {:ok, v, rest, nodes} -> list_elems(elem, rest, n, i + 1, depth, nodes, lim, [v | acc])
      error -> error
    end
  end

  defp string_elems(_elem, rest, len, len, _size, _depth, nodes, _lim, acc),
    do: {:ok, Enum.reverse(acc), rest, nodes}

  defp string_elems(elem, <<byte, rest::binary>>, len, i, size, depth, nodes, lim, acc) do
    remaining = size - i
    decode = &dec(elem, &1, &2, &3, &4)

    case Runtime.string_byte(byte, remaining, decode, depth, nodes, lim) |> Runtime.prefix(i) do
      {:ok, v, _, nodes} ->
        string_elems(elem, rest, len, i + 1, size, depth, nodes, lim, [v | acc])

      error ->
        error
    end
  end

  # Reads a map whose keys are atoms named in `table` (name => {key, codec}).
  defp read_keyed_map(codec, table, keys, rest, depth, nodes, lim) do
    expected = IR.expected(codec)

    case rest do
      <<116, n::32, body::binary>> ->
        with :ok <-
               Runtime.check_count(
                 n,
                 map_size(table),
                 2,
                 byte_size(body),
                 2,
                 nodes,
                 expected,
                 rest,
                 lim
               ) do
          keyed_pairs(table, keys, body, n, depth + 1, nodes, lim, %{})
        end

      <<116, _::binary>> ->
        Runtime.fail(:unexpected_eof, expected, rest)

      _ ->
        Runtime.fail(:unexpected, expected, rest)
    end
  end

  defp keyed_pairs(_table, _keys, rest, 0, _depth, nodes, _lim, acc), do: {:ok, acc, rest, nodes}

  defp keyed_pairs(table, keys, rest, n, depth, nodes, lim, acc) do
    key_expected = Enum.map(keys, &{:key, &1})

    with {:ok, nodes} <- Runtime.enter(rest, depth, nodes, lim),
         {:ok, key, codec, after_key} <- keyed_key(table, key_expected, rest),
         :ok <-
           if(is_map_key(acc, key),
             do: Runtime.fail(:duplicate_key, key_expected, rest),
             else: :ok
           ),
         {:ok, value, after_value, nodes} <-
           dec(codec, after_key, depth, nodes, lim) |> Runtime.prefix(key) do
      keyed_pairs(table, keys, after_value, n - 1, depth, nodes, lim, Map.put(acc, key, value))
    end
  end

  defp keyed_key(table, key_expected, rest) do
    case ETF.read_atom_name(rest) do
      {:ok, name, after_key} ->
        case table do
          %{^name => {key, codec}} -> {:ok, key, codec, after_key}
          _ -> Runtime.fail(:unknown_key, key_expected, rest)
        end

      {:error, :unexpected} ->
        Runtime.fail(:unknown_key, key_expected, rest)

      {:error, reason} ->
        Runtime.fail(reason, key_expected, rest)
    end
  end

  defp missing(required, acc, map_start) do
    case Enum.find(required, &(not is_map_key(acc, &1))) do
      nil -> :ok
      key -> Runtime.fail(:missing_key, [{:key, key}], map_start)
    end
  end

  defp build_struct(module, fields, acc) do
    values =
      Enum.reduce(fields, acc, fn
        {name, _, {:ok, default}}, acc -> Map.put_new(acc, name, default)
        {_, _, :none}, acc -> acc
      end)

    module |> Kernel.struct() |> Map.merge(Map.delete(values, :__struct__))
  end

  defp map_of_pairs(_key, _value, rest, 0, _i, _depth, nodes, _lim, acc),
    do: {:ok, acc, rest, nodes}

  defp map_of_pairs(key_codec, value_codec, rest, n, i, depth, nodes, lim, acc) do
    with {:ok, key, after_key, nodes} <-
           dec(key_codec, rest, depth, nodes, lim) |> Runtime.prefix({:key, i}),
         :ok <- check_key(key, acc, key_codec, rest),
         {:ok, value, after_value, nodes} <-
           dec(value_codec, after_key, depth, nodes, lim) |> Runtime.prefix(key) do
      map_of_pairs(
        key_codec,
        value_codec,
        after_value,
        n - 1,
        i + 1,
        depth,
        nodes,
        lim,
        Map.put(acc, key, value)
      )
    end
  end

  defp check_key(:__struct__, _acc, key_codec, rest),
    do: Runtime.fail(:struct_key, IR.expected(key_codec), rest)

  defp check_key(key, acc, key_codec, rest) do
    if is_map_key(acc, key),
      do: Runtime.fail(:duplicate_key, IR.expected(key_codec), rest),
      else: :ok
  end

  ## Sequences

  defp seq_tag(state, nil, rest, nodes), do: {:ok, state, rest, nodes}

  defp seq_tag(%{left: 0} = state, _tag, _rest, _nodes),
    do: Runtime.fail(:unexpected, IR.expected(state.codec), state.start)

  defp seq_tag(state, tag, rest, nodes) do
    case dec(%Heddle{node: {:literal, tag}}, rest, state.depth, nodes, state.lim)
         |> Runtime.prefix(0) do
      {:ok, _tag, rest, nodes} -> {:ok, %{state | left: state.left - 1, index: 1}, rest, nodes}
      error -> error
    end
  end

  defp run_seq(%Heddle{node: {:pure, value}}, %{left: 0}, rest, nodes),
    do: {:ok, value, rest, nodes}

  defp run_seq(%Heddle{node: {:pure, _}}, state, _rest, _nodes),
    do: Runtime.fail(:unexpected, IR.expected(state.codec), state.start)

  defp run_seq(%Heddle{node: {:bind, _, _}}, %{left: 0} = state, _rest, _nodes),
    do: Runtime.fail(:unexpected, IR.expected(state.codec), state.start)

  defp run_seq(%Heddle{node: {:bind, codec, continuation}}, state, rest, nodes) do
    case dec(codec, rest, state.depth, nodes, state.lim) |> Runtime.prefix(state.index) do
      {:ok, value, rest, nodes} ->
        state = %{state | left: state.left - 1, index: state.index + 1}

        with {:ok, nodes} <- charge_bind(rest, nodes, state.lim) do
          next = IR.seq!(continuation.(value), "a Heddle.bind/2 continuation")
          run_seq(next, state, rest, nodes)
        end

      error ->
        error
    end
  end

  @doc false
  @spec charge_bind(binary(), integer(), Runtime.lim()) ::
          {:ok, integer()} | {:error, Runtime.failure()}
  def charge_bind(rest, nodes, {_, max_nodes, _, _}) do
    if nodes <= 0,
      do: Runtime.fail(:max_nodes, [{:max_nodes, max_nodes}], rest),
      else: {:ok, nodes - 1}
  end

  ## Encoding

  @doc false
  @spec enc(Heddle.t(), term(), Runtime.mode()) :: Runtime.enc_result()
  def enc(%Heddle{node: node} = codec, value, mode) do
    case node do
      {:literal, atom} ->
        if value === atom,
          do: {:ok, atom, ETF.encode_atom(atom)},
          else: type_error({:atom, atom}, value)

      {:enum, atoms, unknown} ->
        enc_enum(atoms, unknown, value)

      :existing_atom ->
        if is_atom(value),
          do: {:ok, value, ETF.encode_atom(value)},
          else: type_error(:atom, value)

      {:integer, min, max} ->
        cond do
          not is_integer(value) ->
            type_error(:integer, value)

          (min == nil or value >= min) and (max == nil or value <= max) ->
            {:ok, value, ETF.encode_integer(value)}

          true ->
            {:error, {[], {:out_of_range, value}}}
        end

      :char ->
        cond do
          not is_integer(value) -> type_error(:char, value)
          Runtime.codepoint?(value) -> {:ok, value, ETF.encode_integer(value)}
          true -> {:error, {[], {:out_of_range, value}}}
        end

      :float ->
        if is_float(value),
          do: {:ok, value, ETF.encode_float(value)},
          else: type_error(:float, value)

      {:binary, max, utf8} ->
        enc_binary(max, utf8, value)

      {:list, elem, max} ->
        enc_list(elem, max, value, mode)

      {:tuple, elems} ->
        enc_tuple(elems, value, mode)

      {:map, required, optional} ->
        enc_map(required, optional, value, mode)

      {:struct, module, layout, fields} ->
        enc_struct(module, layout, fields, value, mode)

      {:map_of, key, val, max} ->
        enc_map_of(key, val, max, value, mode)

      {:one_of, alts, _, shapes} ->
        case IR.choose(shapes, &IR.shape_matches?(&1, value)) do
          nil -> {:error, {[], {:no_alternative, value}}}
          index -> enc(Enum.at(alts, index), value, mode)
        end

      {:iso, inner, decode, encode} ->
        with {:ok, inner_value} <- iso_step(encode, value),
             {:ok, inner_y, iodata} <- enc(inner, inner_value, mode),
             {:ok, y} <- iso_step(decode, inner_y, value) do
          {:ok, y, iodata}
        end

      {:refine, inner, pred, reason} ->
        with {:ok, y, iodata} <- enc(inner, value, mode) do
          if pred.(y), do: {:ok, y, iodata}, else: {:error, {[], {:refine, reason, value}}}
        end

      {:from, inner, getter} ->
        case Runtime.get(getter, value) do
          {:ok, part} -> enc(inner, part, mode)
          :error -> {:error, {[], {:getter, value}}}
        end

      {:lazy, _} ->
        enc(forced(codec), value, mode)

      {:ref, module, name} ->
        if mode == :compiled,
          do: module.__heddle_encode__(name, value),
          else: enc(resolved(module, name), value, mode)

      {:tuple_seq, tag, seq} ->
        prefix = if tag, do: [ETF.encode_atom(tag)], else: []

        with {:ok, y, elems} <- enc_seq(seq, value, mode, length(prefix), Enum.reverse(prefix)) do
          {:ok, y, [ETF.tuple_header(length(elems)) | elems]}
        end
    end
  end

  defp iso_step(fun, value, original \\ nil) do
    case Runtime.call_iso(fun, value) do
      {:ok, result} -> {:ok, result}
      :error -> {:error, {[], {:iso, original || value}}}
    end
  end

  defp type_error(expected, value), do: {:error, {[], {:type, expected, value}}}

  defp enc_enum(atoms, unknown, value) do
    cond do
      is_atom(value) and value in atoms ->
        {:ok, value, ETF.encode_atom(value)}

      unknown == :keep and match?({:unknown, _}, value) ->
        {:unknown, name} = value

        cond do
          not ETF.valid_atom_name?(name) -> {:error, {[], {:invalid_atom_name, name}}}
          Enum.any?(atoms, &(Atom.to_string(&1) == name)) -> {:error, {[], {:known_name, name}}}
          true -> {:ok, value, ETF.encode_atom_name(name)}
        end

      true ->
        type_error({:enum, atoms}, value)
    end
  end

  defp enc_binary(max, utf8, value) do
    cond do
      not is_binary(value) -> type_error(:binary, value)
      max != nil and byte_size(value) > max -> {:error, {[], {:too_large, byte_size(value), max}}}
      utf8 and not String.valid?(value) -> {:error, {[], {:invalid_utf8, value}}}
      true -> {:ok, value, [ETF.binary_header(byte_size(value)), value]}
    end
  end

  defp enc_list(elem, max, value, mode) do
    case is_list(value) and Runtime.proper_length(value) do
      false ->
        type_error(:list, value)

      :improper ->
        type_error(:proper_list, value)

      n when max != nil and n > max ->
        {:error, {[], {:too_large, n, max}}}

      n ->
        value
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, [], []}, fn {v, i}, {:ok, ys, ios} ->
          case enc(elem, v, mode) |> Runtime.enc_prefix(i) do
            {:ok, y, io} -> {:cont, {:ok, [y | ys], [io | ios]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, ys, ios} -> {:ok, Enum.reverse(ys), Runtime.list_bytes(Enum.reverse(ios), n)}
          error -> error
        end
    end
  end

  defp enc_tuple(elems, value, mode) do
    if is_tuple(value) and tuple_size(value) == length(elems) do
      with {:ok, ys, ios} <- enc_elems(elems, Tuple.to_list(value), mode, 0, [], []) do
        {:ok, List.to_tuple(ys), [ETF.tuple_header(length(elems)) | ios]}
      end
    else
      type_error({:tuple, length(elems)}, value)
    end
  end

  defp enc_elems([], [], _mode, _i, ys, ios), do: {:ok, Enum.reverse(ys), Enum.reverse(ios)}

  defp enc_elems([c | cs], [v | vs], mode, i, ys, ios) do
    case enc(c, v, mode) |> Runtime.enc_prefix(i) do
      {:ok, y, io} -> enc_elems(cs, vs, mode, i + 1, [y | ys], [io | ios])
      error -> error
    end
  end

  defp enc_map(required, optional, value, mode) do
    cond do
      not is_map(value) ->
        type_error(:map, value)

      is_map_key(value, :__struct__) ->
        {:error, {[], :struct_key}}

      true ->
        named = required ++ optional

        with :ok <- unknown_keys(value, named),
             :ok <- missing_keys(value, required) do
          present = Enum.filter(named, fn {key, _} -> is_map_key(value, key) end)

          with {:ok, ys, pairs} <- enc_fields(present, value, mode) do
            {:ok, ys, Runtime.map_bytes(pairs)}
          end
        end
    end
  end

  defp unknown_keys(value, named) do
    names = MapSet.new(named, &elem(&1, 0))

    case value |> Map.keys() |> Enum.sort() |> Enum.find(&(not MapSet.member?(names, &1))) do
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

  defp enc_fields(fields, value, mode) do
    Enum.reduce_while(fields, {:ok, %{}, []}, fn {key, codec}, {:ok, ys, pairs} ->
      case enc(codec, Map.fetch!(value, key), mode) |> Runtime.enc_prefix(key) do
        {:ok, y, io} -> {:cont, {:ok, Map.put(ys, key, y), [{ETF.encode_atom(key), io} | pairs]}}
        error -> {:halt, error}
      end
    end)
  end

  defp enc_struct(module, layout, fields, value, mode) do
    if is_struct(value, module) do
      named = Enum.map(fields, fn {name, codec, _} -> {name, codec} end)

      with {:ok, ys, pairs} <- enc_fields(named, value, mode) do
        y = module |> Kernel.struct() |> Map.merge(ys)

        case layout do
          :map ->
            struct_pair = {ETF.encode_atom(:__struct__), ETF.encode_atom(module)}
            {:ok, y, Runtime.map_bytes([struct_pair | pairs])}

          {:tuple, tag} ->
            by_key = Map.new(pairs)

            ios =
              Enum.map(fields, fn {name, _, _} -> Map.fetch!(by_key, ETF.encode_atom(name)) end)

            ios = if tag, do: [ETF.encode_atom(tag) | ios], else: ios
            {:ok, y, [ETF.tuple_header(length(ios)) | ios]}
        end
      end
    else
      type_error({:struct, module}, value)
    end
  end

  defp enc_map_of(key_codec, value_codec, max, value, mode) do
    cond do
      not is_map(value) ->
        type_error(:map, value)

      is_map_key(value, :__struct__) ->
        {:error, {[], :struct_key}}

      max != nil and map_size(value) > max ->
        {:error, {[], {:too_large, map_size(value), max}}}

      true ->
        value
        |> Enum.sort()
        |> Enum.reduce_while({:ok, %{}, []}, fn {k, v}, {:ok, ys, pairs} ->
          with {:ok, yk, kio} <- enc(key_codec, k, mode) |> Runtime.enc_prefix({:key, k}),
               :ok <- encoded_key(yk, ys, k),
               {:ok, yv, vio} <- enc(value_codec, v, mode) |> Runtime.enc_prefix(k) do
            {:cont, {:ok, Map.put(ys, yk, yv), [{IO.iodata_to_binary(kio), vio} | pairs]}}
          else
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, ys, pairs} -> {:ok, ys, Runtime.map_bytes(pairs)}
          error -> error
        end
    end
  end

  defp encoded_key(:__struct__, _ys, k), do: {:error, {[k], :struct_key}}

  defp encoded_key(yk, ys, k) do
    if is_map_key(ys, yk), do: {:error, {[k], {:duplicate_key, yk}}}, else: :ok
  end

  defp enc_seq(%Heddle{node: {:pure, value}}, _input, _mode, _i, elems),
    do: {:ok, value, Enum.reverse(elems)}

  defp enc_seq(%Heddle{node: {:bind, codec, continuation}}, input, mode, i, elems) do
    with {:ok, y, io} <- enc(codec, input, mode) |> Runtime.enc_prefix(i) do
      next = IR.seq!(continuation.(y), "a Heddle.bind/2 continuation")
      enc_seq(next, input, mode, i + 1, [io | elems])
    end
  end
end

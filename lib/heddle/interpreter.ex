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
  def decode(%Heddle{node: {:ref, module, name}}, binary, opts, :compiled) do
    limits = Limits.new(opts)
    Runtime.run_decode(binary, limits, :compiled, &module.__heddle_decode__(name, &1, &2, &3, &4))
  end

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
  def encode(%Heddle{node: {:ref, module, name}}, value, :compiled),
    do: Runtime.finish_encode(module.__heddle_encode__(name, value))

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
    case Process.get(:heddle_cache, %{}) do
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
      {:lazy, _} -> with_cache(fn -> dec(forced(codec), rest, depth, nodes, lim) end)
      {:ref, module, name} -> dec_ref(module, name, rest, depth, nodes, lim)
      _ -> consume(codec, rest, depth, nodes, lim)
    end
  end

  defp dec_ref(module, name, rest, depth, nodes, {_, _, _, :compiled} = lim),
    do: module.__heddle_decode__(name, rest, depth, nodes, lim)

  defp dec_ref(module, name, rest, depth, nodes, lim),
    do: with_cache(fn -> dec(resolved(module, name), rest, depth, nodes, lim) end)

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

  defp read(%Heddle{node: node} = codec, rest, depth, nodes, lim) do
    case node do
      {:literal, atom} ->
        name = Atom.to_string(atom)

        case ETF.read_atom_name(rest) do
          {:ok, ^name, after_term} -> {:ok, atom, after_term, nodes}
          _ -> Runtime.atom_failure(rest, IR.expected(codec))
        end

      {:enum, atoms, unknown} ->
        names = Map.new(atoms, &{Atom.to_string(&1), &1})
        Runtime.read_enum(rest, nodes, names, unknown, IR.expected(codec))

      :existing_atom ->
        Runtime.read_existing_atom(rest, nodes, IR.expected(codec))

      {:integer, min, max} ->
        Runtime.read_integer(rest, nodes, min, max, IR.expected(codec))

      :char ->
        Runtime.read_char(rest, nodes, IR.expected(codec))

      :float ->
        Runtime.read_float(rest, nodes, IR.expected(codec))

      {:binary, max, utf8} ->
        Runtime.read_binary(rest, nodes, max, utf8, IR.expected(codec), lim)

      {:list, elem, max} ->
        read_list(elem, max, IR.expected(codec), rest, depth, nodes, lim)

      {:tuple, elems} ->
        read_tuple(elems, IR.expected(codec), rest, depth, nodes, lim)

      {:map, required, optional} ->
        named = required ++ optional
        required_keys = Enum.map(required, &elem(&1, 0))

        with {:ok, acc, after_term, nodes} <-
               read_keyed_map(named, IR.expected(codec), rest, depth, nodes, lim),
             :ok <- Runtime.missing(required_keys, acc, rest) do
          {:ok, acc, after_term, nodes}
        end

      {:struct, module, :map, fields} ->
        named = [
          {:__struct__, %Heddle{node: {:literal, module}}}
          | Enum.map(fields, fn {n, c, _} -> {n, c} end)
        ]

        required = [:__struct__ | for({name, _, :none} <- fields, do: name)]

        with {:ok, acc, after_term, nodes} <-
               read_keyed_map(named, IR.expected(codec), rest, depth, nodes, lim),
             :ok <- Runtime.missing(required, acc, rest) do
          {:ok, Runtime.build_struct(module, defaults(fields), acc), after_term, nodes}
        end

      {:struct, module, {:tuple, tag}, fields} ->
        codecs = Enum.map(fields, &elem(&1, 1))
        elems = if tag, do: [%Heddle{node: {:literal, tag}} | codecs], else: codecs

        with {:ok, tuple, after_term, nodes} <-
               read_tuple(elems, IR.expected(codec), rest, depth, nodes, lim) do
          values = tuple |> Tuple.to_list() |> Enum.drop(if(tag, do: 1, else: 0))
          acc = fields |> Enum.map(&elem(&1, 0)) |> Enum.zip(values) |> Map.new()
          {:ok, Runtime.build_struct(module, defaults(fields), acc), after_term, nodes}
        end

      {:map_of, key, value, max} ->
        expected = IR.expected(codec)

        case rest do
          <<116, n::32, body::binary>> ->
            with :ok <-
                   Runtime.check_count(n, max, 2, byte_size(body), 2, nodes, expected, rest, lim) do
              map_of_pairs(key, value, body, n, 0, depth + 1, nodes, lim, %{})
            end

          <<116, _::binary>> ->
            Runtime.fail(:unexpected_eof, expected, rest)

          _ ->
            Runtime.fail(:unexpected, expected, rest)
        end

      {:tuple_seq, tag, seq} ->
        expected = IR.expected(codec)

        case Runtime.tuple_header(rest) do
          {:ok, arity, body} ->
            state = {rest, expected, arity, depth + 1, lim}

            with {:ok, index, body, nodes} <- seq_tag(tag, state, body, nodes) do
              run_seq(seq, state, index, body, nodes)
            end

          {:error, reason} ->
            Runtime.fail(reason, expected, rest)
        end
    end
  end

  defp defaults(fields), do: Enum.map(fields, fn {name, _, default} -> {name, default} end)

  defp read_list(elem, max, expected, rest, depth, nodes, lim) do
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

  defp read_tuple(elems, expected, rest, depth, nodes, lim) do
    arity = length(elems)

    case rest do
      <<104, ^arity, body::binary>> -> tuple_elems(elems, body, 0, depth + 1, nodes, lim, [])
      <<105, ^arity::32, body::binary>> -> tuple_elems(elems, body, 0, depth + 1, nodes, lim, [])
      _ -> Runtime.tuple_failure(rest, expected)
    end
  end

  defp tuple_elems([], rest, _i, _depth, nodes, _lim, acc),
    do: {:ok, acc |> Enum.reverse() |> List.to_tuple(), rest, nodes}

  defp tuple_elems([c | cs], rest, i, depth, nodes, lim, acc) do
    case dec(c, rest, depth, nodes, lim) do
      {:ok, v, rest, nodes} -> tuple_elems(cs, rest, i + 1, depth, nodes, lim, [v | acc])
      error -> Runtime.prefix(error, i)
    end
  end

  defp list_elems(_elem, rest, n, n, _depth, nodes, _lim, acc),
    do: Runtime.list_tail(rest, acc, nodes)

  defp list_elems(elem, rest, n, i, depth, nodes, lim, acc) do
    case dec(elem, rest, depth, nodes, lim) do
      {:ok, v, rest, nodes} -> list_elems(elem, rest, n, i + 1, depth, nodes, lim, [v | acc])
      error -> Runtime.prefix(error, i)
    end
  end

  defp string_elems(_elem, rest, len, len, _size, _depth, nodes, _lim, acc),
    do: {:ok, Enum.reverse(acc), rest, nodes}

  defp string_elems(elem, <<byte, rest::binary>>, len, i, size, depth, nodes, lim, acc) do
    decode = &dec(elem, &1, &2, &3, &4)

    case Runtime.string_byte(byte, size - i, decode, depth, nodes, lim) do
      {:ok, v, _, nodes} ->
        string_elems(elem, rest, len, i + 1, size, depth, nodes, lim, [v | acc])

      error ->
        Runtime.prefix(error, i)
    end
  end

  # Reads a map whose keys are the atoms in `named` ([{key, codec}]).
  defp read_keyed_map(named, expected, rest, depth, nodes, lim) do
    case rest do
      <<116, n::32, body::binary>> ->
        with :ok <-
               Runtime.check_count(
                 n,
                 length(named),
                 2,
                 byte_size(body),
                 2,
                 nodes,
                 expected,
                 rest,
                 lim
               ) do
          table = Map.new(named, fn {key, c} -> {Atom.to_string(key), {key, c}} end)
          key_expected = Enum.map(named, &{:key, elem(&1, 0)})
          keyed_pairs(table, key_expected, body, n, depth + 1, nodes, lim, %{})
        end

      <<116, _::binary>> ->
        Runtime.fail(:unexpected_eof, expected, rest)

      _ ->
        Runtime.fail(:unexpected, expected, rest)
    end
  end

  defp keyed_pairs(_table, _key_expected, rest, 0, _depth, nodes, _lim, acc),
    do: {:ok, acc, rest, nodes}

  defp keyed_pairs(table, key_expected, rest, n, depth, nodes, lim, acc) do
    with {:ok, nodes} <- Runtime.enter(rest, depth, nodes, lim),
         {:ok, key, codec, after_key} <- keyed_key(table, key_expected, rest),
         :ok <-
           if(is_map_key(acc, key),
             do: Runtime.fail(:duplicate_key, key_expected, rest),
             else: :ok
           ),
         {:ok, value, after_value, nodes} <-
           dec(codec, after_key, depth, nodes, lim) |> Runtime.prefix(key) do
      keyed_pairs(
        table,
        key_expected,
        after_value,
        n - 1,
        depth,
        nodes,
        lim,
        Map.put(acc, key, value)
      )
    end
  end

  defp keyed_key(table, key_expected, rest) do
    with {:ok, name, after_key} <- ETF.read_atom_name(rest),
         %{^name => {key, codec}} <- table do
      {:ok, key, codec, after_key}
    else
      _ -> Runtime.key_failure(rest, key_expected)
    end
  end

  defp map_of_pairs(_key, _value, rest, 0, _i, _depth, nodes, _lim, acc),
    do: {:ok, acc, rest, nodes}

  defp map_of_pairs(key_codec, value_codec, rest, n, i, depth, nodes, lim, acc) do
    with {:ok, key, after_key, nodes} <-
           dec(key_codec, rest, depth, nodes, lim) |> Runtime.prefix({:key, i}),
         :ok <- Runtime.check_map_key(key, acc, IR.expected(key_codec), rest),
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

  ## Sequences
  #
  # `state` is {tuple_start, expected, arity, element_depth, lim}; `index` is
  # the next element's position, so the tuple has `arity - index` left.

  defp seq_tag(nil, _state, rest, nodes), do: {:ok, 0, rest, nodes}

  defp seq_tag(tag, {start, expected, arity, depth, lim}, rest, nodes) do
    if arity == 0 do
      Runtime.fail(:unexpected, expected, start)
    else
      case dec(%Heddle{node: {:literal, tag}}, rest, depth, nodes, lim) do
        {:ok, _tag, rest, nodes} -> {:ok, 1, rest, nodes}
        error -> Runtime.prefix(error, 0)
      end
    end
  end

  @doc false
  @spec continue_seq(
          term(),
          {binary(), [term()], non_neg_integer(), pos_integer(), Runtime.lim()},
          non_neg_integer(),
          binary(),
          integer()
        ) ::
          Runtime.dec_result()
  def continue_seq(next, state, index, rest, nodes) do
    with_cache(fn ->
      run_seq(IR.seq!(next, "a Heddle.bind/2 continuation"), state, index, rest, nodes)
    end)
  end

  defp run_seq(%Heddle{node: {:pure, value}}, {start, expected, arity, _, _}, index, rest, nodes) do
    if index == arity,
      do: {:ok, value, rest, nodes},
      else: Runtime.fail(:unexpected, expected, start)
  end

  defp run_seq(
         %Heddle{node: {:bind, codec, continuation}},
         {start, expected, arity, depth, lim} = state,
         index,
         rest,
         nodes
       ) do
    if index == arity do
      Runtime.fail(:unexpected, expected, start)
    else
      case dec(codec, rest, depth, nodes, lim) do
        {:ok, value, rest, nodes} ->
          with {:ok, nodes} <- charge_bind(rest, nodes, lim) do
            next = IR.seq!(continuation.(value), "a Heddle.bind/2 continuation")
            run_seq(next, state, index + 1, rest, nodes)
          end

        error ->
          Runtime.prefix(error, index)
      end
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
          else: {:error, {[], {:type, {:atom, atom}, value}}}

      {:enum, atoms, unknown} ->
        Runtime.enc_enum(value, atoms, unknown)

      :existing_atom ->
        Runtime.enc_existing_atom(value)

      {:integer, min, max} ->
        Runtime.enc_integer(value, min, max)

      :char ->
        Runtime.enc_char(value)

      :float ->
        Runtime.enc_float(value)

      {:binary, max, utf8} ->
        Runtime.enc_binary(value, max, utf8)

      {:list, elem, max} ->
        Runtime.enc_list(value, max, &enc(elem, &1, mode))

      {:tuple, elems} ->
        enc_tuple(elems, value, mode)

      {:map, required, optional} ->
        Runtime.enc_map(value, encoders(required, mode), encoders(optional, mode))

      {:struct, module, layout, fields} ->
        Runtime.enc_struct(
          value,
          module,
          layout,
          encoders(Enum.map(fields, fn {n, c, _} -> {n, c} end), mode)
        )

      {:map_of, key, val, max} ->
        Runtime.enc_map_of(value, max, &enc(key, &1, mode), &enc(val, &1, mode))

      {:one_of, alts, _, shapes} ->
        case IR.choose(shapes, &IR.shape_matches?(&1, value)) do
          nil -> {:error, {[], {:no_alternative, value}}}
          index -> enc(Enum.at(alts, index), value, mode)
        end

      {:iso, inner, decode, encode} ->
        with {:ok, inner_value} <- iso_step(encode, value, value),
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
        with_cache(fn -> enc(forced(codec), value, mode) end)

      {:ref, module, name} ->
        if mode == :compiled,
          do: module.__heddle_encode__(name, value),
          else: with_cache(fn -> enc(resolved(module, name), value, mode) end)

      {:tuple_seq, tag, seq} ->
        prefix = if tag, do: [ETF.encode_atom(tag)], else: []

        with {:ok, y, elems} <- enc_seq(seq, value, mode, length(prefix), Enum.reverse(prefix)) do
          {:ok, y, [ETF.tuple_header(length(elems)) | elems]}
        end
    end
  end

  defp encoders(pairs, mode),
    do: Enum.map(pairs, fn {key, codec} -> {key, &enc(codec, &1, mode)} end)

  defp iso_step(fun, value, original) do
    case Runtime.call_iso(fun, value) do
      {:ok, result} -> {:ok, result}
      :error -> {:error, {[], {:iso, original}}}
    end
  end

  defp enc_tuple(elems, value, mode) do
    if is_tuple(value) and tuple_size(value) == length(elems) do
      with {:ok, ys, ios} <- enc_elems(elems, Tuple.to_list(value), mode, 0, [], []) do
        {:ok, List.to_tuple(ys), [ETF.tuple_header(length(elems)) | ios]}
      end
    else
      {:error, {[], {:type, {:tuple, length(elems)}, value}}}
    end
  end

  defp enc_elems([], [], _mode, _i, ys, ios), do: {:ok, Enum.reverse(ys), Enum.reverse(ios)}

  defp enc_elems([c | cs], [v | vs], mode, i, ys, ios) do
    case enc(c, v, mode) do
      {:ok, y, io} -> enc_elems(cs, vs, mode, i + 1, [y | ys], [io | ios])
      error -> Runtime.enc_prefix(error, i)
    end
  end

  # Encodes a sequence from step `i`, with `elems` the reversed iodata so far.
  @doc false
  @spec enc_seq(term(), term(), Runtime.mode(), non_neg_integer(), [iodata()]) ::
          {:ok, term(), [iodata()]} | {:error, {[term()], term()}}
  def enc_seq(seq, input, mode, i, elems) do
    case IR.seq!(seq, "a Heddle.bind/2 continuation") do
      %Heddle{node: {:pure, value}} ->
        {:ok, value, Enum.reverse(elems)}

      %Heddle{node: {:bind, codec, continuation}} ->
        case enc(codec, input, mode) do
          {:ok, y, io} -> enc_seq(continuation.(y), input, mode, i + 1, [io | elems])
          error -> Runtime.enc_prefix(error, i)
        end
    end
  end
end

if Code.ensure_loaded?(StreamData) do
  defmodule Heddle.Gen do
    @moduledoc """
    Test generators derived from codecs (requires `stream_data`).

    `from/1` generates values the codec's decoder can return, by running each
    codec "forwards" over random choices: the bigenerator construction from
    Xia et al. For an aligned codec whose functions are lawful, these are
    exactly the values the encoder accepts, so

        check all v <- Heddle.Gen.from(codec) do
          assert {:ok, ^v} = Heddle.decode(codec, IO.iodata_to_binary(Heddle.encode!(codec, v)))
        end

    exercises the backward round trip. Recursion through `Heddle.lazy/1` and
    compiled references is cut off past a depth of 4 by preferring
    alternatives that do not recurse.
    """

    alias Heddle.IR

    @recursion_cutoff 4
    @existing_atoms [:ok, :error, true, false, nil, :heddle, :__struct__]

    @doc "A generator of values `codec` decodes to."
    @spec from(Heddle.t()) :: StreamData.t(term())
    def from(codec), do: gen(IR.codec!(codec, "Heddle.Gen.from/1"), 0)

    defp gen(%Heddle{node: node} = codec, depth) do
      case node do
        {:literal, atom} ->
          StreamData.constant(atom)

        {:enum, atoms, :reject} ->
          StreamData.member_of(atoms)

        {:enum, atoms, :keep} ->
          unknown = unknown_name(atoms) |> StreamData.map(&{:unknown, &1})

          if atoms == [],
            do: unknown,
            else: StreamData.one_of([StreamData.member_of(atoms), unknown])

        :existing_atom ->
          StreamData.member_of(@existing_atoms)

        {:integer, min, max} ->
          integer(min, max)

        :char ->
          StreamData.one_of([StreamData.integer(0..0xD7FF), StreamData.integer(0xE000..0x10FFFF)])

        :float ->
          StreamData.float()

        {:binary, max, true} ->
          StreamData.string(:utf8, max_length: min(max || 32, 32))
          |> StreamData.filter(&(max == nil or byte_size(&1) <= max))

        {:binary, max, false} ->
          StreamData.binary(max_length: min(max || 32, 32))

        {:list, elem, max} ->
          StreamData.list_of(gen(elem, depth + 1), max_length: list_max(max, depth))

        {:tuple, elems} ->
          elems |> Enum.map(&gen(&1, depth + 1)) |> List.to_tuple() |> StreamData.tuple()

        {:map, required, optional} ->
          required_map =
            StreamData.fixed_map(Enum.map(required, fn {k, c} -> {k, gen(c, depth + 1)} end))

          optional_map =
            StreamData.optional_map(Enum.map(optional, fn {k, c} -> {k, gen(c, depth + 1)} end))

          StreamData.bind(required_map, fn req ->
            StreamData.map(optional_map, &Map.merge(req, &1))
          end)

        {:struct, module, _, fields} ->
          fields
          |> Enum.map(fn {name, c, _} -> {name, gen(c, depth + 1)} end)
          |> StreamData.fixed_map()
          |> StreamData.map(&Map.merge(Kernel.struct(module), &1))

        {:map_of, key, value, max} ->
          # Pairs collapse on duplicate keys, so small key spaces never stall.
          {gen(key, depth + 1), gen(value, depth + 1)}
          |> StreamData.tuple()
          |> StreamData.list_of(max_length: list_max(max, depth))
          |> StreamData.map(&(&1 |> Map.new() |> Map.delete(:__struct__)))

        {:one_of, alts, _, _} ->
          alts |> pick(depth) |> Enum.map(&gen(&1, depth)) |> StreamData.one_of()

        {:iso, inner, decode, _} ->
          inner
          |> gen(depth)
          |> StreamData.map(&decode.(&1))
          |> StreamData.filter(&match?({:ok, _}, &1))
          |> StreamData.map(fn {:ok, v} -> v end)

        {:refine, inner, pred, _} ->
          gen(inner, depth) |> StreamData.filter(&pred.(&1))

        {:from, inner, _} ->
          gen(inner, depth)

        {:lazy, _} ->
          gen(IR.force(codec), depth + 1)

        {:ref, module, name} ->
          gen(IR.ir_of_ref(module, name), depth + 1)

        {:tuple_seq, _tag, seq} ->
          gen_seq(seq, depth + 1)
      end
    end

    defp gen_seq(%Heddle{node: {:pure, value}}, _depth), do: StreamData.constant(value)

    defp gen_seq(%Heddle{node: {:bind, codec, continuation}}, depth) do
      StreamData.bind(gen(codec, depth), fn value ->
        gen_seq(IR.seq!(continuation.(value), "a Heddle.bind/2 continuation"), depth)
      end)
    end

    defp list_max(max, depth) do
      cap = if depth >= @recursion_cutoff, do: 2, else: 8
      if max, do: min(max, cap), else: cap
    end

    # Past the cutoff, prefer alternatives that cannot recurse.
    defp pick(alts, depth) when depth < @recursion_cutoff, do: alts

    defp pick(alts, _depth) do
      case Enum.reject(alts, &recursive?/1) do
        [] -> alts
        shallow -> shallow
      end
    end

    defp recursive?(%Heddle{node: node}) do
      case node do
        {:lazy, _} -> true
        {:ref, _, _} -> true
        {:tuple_seq, _, _} -> false
        {:list, _, _} -> false
        {:map_of, _, _, _} -> false
        _ -> node |> children() |> Enum.any?(&recursive?/1)
      end
    end

    defp children(node) do
      case node do
        {:tuple, elems} -> elems
        {:map, required, optional} -> Keyword.values(required ++ optional)
        {:struct, _, _, fields} -> Enum.map(fields, &elem(&1, 1))
        {:one_of, alts, _, _} -> alts
        {:iso, inner, _, _} -> [inner]
        {:refine, inner, _, _} -> [inner]
        {:from, inner, _} -> [inner]
        _ -> []
      end
    end

    defp integer(nil, nil) do
      StreamData.frequency([
        {8, StreamData.integer()},
        {1, StreamData.integer(-2_147_483_648..2_147_483_647)},
        {1, StreamData.map(StreamData.integer(64..200), &(Integer.pow(2, &1) - 1))}
      ])
    end

    defp integer(min, nil), do: StreamData.map(integer(nil, nil), &(min + abs(&1)))
    defp integer(nil, max), do: StreamData.map(integer(nil, nil), &(max - abs(&1)))
    defp integer(min, max), do: StreamData.integer(min..max)

    defp unknown_name(atoms) do
      names = MapSet.new(atoms, &Atom.to_string/1)

      StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
      |> StreamData.map(&("heddle_unknown_" <> &1))
      |> StreamData.filter(&(not MapSet.member?(names, &1)))
    end
  end
end

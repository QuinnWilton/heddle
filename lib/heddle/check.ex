defmodule Heddle.Check do
  @moduledoc """
  Differential checks: Heddle against the VM, and compiled codecs against
  the interpreter.

  ## Agreement with the VM

  `differential/3` checks an implication, not an equivalence: whenever
  Heddle accepts bytes `b` as `v`, `:erlang.binary_to_term(b, [:safe])` must
  accept `b` and return `v`'s plain-term form. `[:safe]` accepts a larger
  language, so inputs Heddle rejects are not compared.

  The plain-term form of `v` is what the VM reads from Heddle's own
  encoding of `v`. So structs compare as maps of their serialized fields,
  and `{:unknown, name}` compares equal to the atom named `name`. Struct
  fields the input omitted, which Heddle filled from `default:`, are added to
  the VM's term before comparing.

  An input containing an unknown enum name that does not exist as an atom is
  an expected `[:safe]` rejection and is skipped. Any other `[:safe]`
  rejection is a failure: either Heddle accepted too much, or the schema's
  atoms were not loaded.
  """

  alias Heddle.{ETF, Interpreter, IR}

  @type failure :: {binary() | term(), term()}

  @doc "Checks agreement with `:erlang.binary_to_term/2` over a corpus of binaries."
  @spec differential(Heddle.t(), Enumerable.t(), keyword()) :: :ok | {:error, [failure()]}
  def differential(codec, corpus, opts \\ []) do
    collect(corpus, fn bin ->
      case Heddle.decode(codec, bin, opts) do
        {:ok, value} -> agree(codec, bin, value)
        {:error, _} -> :ok
      end
    end)
  end

  defp agree(codec, bin, value) do
    case safe_binary_to_term(bin) do
      {:ok, term} ->
        with {:ok, iodata} <- Heddle.encode(codec, value),
             plain = :erlang.binary_to_term(IO.iodata_to_binary(iodata)),
             ^plain <- with_defaults(codec, term) do
          :ok
        else
          {:error, %Heddle.EncodeError{} = e} -> {:error, {:not_reencodable, value, e}}
          other -> {:error, {:mismatch, value, other}}
        end

      :error ->
        if missing_unknown_atom?(value), do: :ok, else: {:error, {:vm_rejected, value}}
    end
  end

  @doc """
  Checks that a compiled codec's decoder agrees with the interpreter on every
  binary: the same value, or the same error at the same offset.
  """
  @spec backends(Heddle.t(), Enumerable.t(), keyword()) :: :ok | {:error, [failure()]}
  def backends(codec, binaries, opts \\ []) do
    collect(binaries, fn bin ->
      compiled = Heddle.decode(codec, bin, opts)
      interpreted = Interpreter.decode(codec, bin, opts)
      if compiled == interpreted, do: :ok, else: {:error, {compiled, interpreted}}
    end)
  end

  @doc """
  Checks that a compiled codec's encoder agrees with the interpreter on every
  value: the same bytes and decoded value, or the same error.
  """
  @spec encoders(Heddle.t(), Enumerable.t()) :: :ok | {:error, [failure()]}
  def encoders(codec, values) do
    collect(values, fn value ->
      compiled = normalize(Interpreter.encode(codec, value, :compiled))
      interpreted = normalize(Interpreter.encode(codec, value))
      if compiled == interpreted, do: :ok, else: {:error, {compiled, interpreted}}
    end)
  end

  defp normalize({:ok, y, iodata}), do: {:ok, y, IO.iodata_to_binary(iodata)}
  defp normalize(error), do: error

  defp safe_binary_to_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp missing_unknown_atom?({:unknown, name}) when is_binary(name) do
    _ = String.to_existing_atom(name)
    false
  rescue
    ArgumentError -> true
  end

  defp missing_unknown_atom?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&missing_unknown_atom?/1)

  defp missing_unknown_atom?(value) when is_list(value),
    do: Enum.any?(value, &missing_unknown_atom?/1)

  defp missing_unknown_atom?(value) when is_map(value),
    do:
      value
      |> Map.to_list()
      |> Enum.any?(fn {k, v} -> missing_unknown_atom?(k) or missing_unknown_atom?(v) end)

  defp missing_unknown_atom?(_), do: false

  # Adds the plain form of defaulted struct fields the VM's term lacks,
  # walking the codec alongside the term.
  defp with_defaults(%Heddle{node: {:list, elem, _}}, term) when is_list(term),
    do: Enum.map(term, &with_defaults(elem, &1))

  defp with_defaults(%Heddle{node: {:tuple, elems}}, term) when is_tuple(term) do
    elems
    |> Enum.zip(Tuple.to_list(term))
    |> Enum.map(fn {c, t} -> with_defaults(c, t) end)
    |> List.to_tuple()
  end

  defp with_defaults(%Heddle{node: {:map, required, optional}}, term) when is_map(term) do
    Map.new(term, fn {k, v} ->
      {k, with_defaults(Keyword.fetch!(required ++ optional, k), v)}
    end)
  end

  defp with_defaults(%Heddle{node: {:map_of, _key, value, _}}, term) when is_map(term),
    do: Map.new(term, fn {k, v} -> {k, with_defaults(value, v)} end)

  defp with_defaults(%Heddle{node: {:struct, _module, :map, fields}}, term) when is_map(term) do
    Enum.reduce(fields, term, fn {name, c, default}, acc ->
      case {acc, default} do
        {%{^name => v}, _} -> Map.put(acc, name, with_defaults(c, v))
        {_, {:ok, d}} -> Map.put(acc, name, plain(c, d))
        {_, :none} -> acc
      end
    end)
  end

  defp with_defaults(%Heddle{node: {:struct, _module, {:tuple, tag}, fields}}, term)
       when is_tuple(term) do
    codecs = Enum.map(fields, &elem(&1, 1))
    codecs = if tag, do: [Heddle.atom(tag) | codecs], else: codecs
    with_defaults(%Heddle{node: {:tuple, codecs}}, term)
  end

  defp with_defaults(%Heddle{node: {:one_of, alts, firsts, _}}, term) do
    <<131, bytes::binary>> = :erlang.term_to_binary(term)
    class = ETF.classify(bytes)

    case IR.choose(firsts, &IR.first_matches?(&1, class)) do
      nil -> term
      index -> with_defaults(Enum.at(alts, index), term)
    end
  end

  defp with_defaults(%Heddle{node: {:iso, inner, _, _}}, term), do: with_defaults(inner, term)

  defp with_defaults(%Heddle{node: {:refine, inner, _, _}}, term), do: with_defaults(inner, term)

  defp with_defaults(%Heddle{node: {:from, inner, _}}, term), do: with_defaults(inner, term)

  defp with_defaults(%Heddle{node: {:lazy, _}} = codec, term),
    do: with_defaults(IR.force(codec), term)

  defp with_defaults(%Heddle{node: {:ref, module, name}}, term),
    do: with_defaults(IR.ir_of_ref(module, name), term)

  defp with_defaults(%Heddle{node: {:tuple_seq, tag, seq}}, term) when is_tuple(term) do
    elems = Tuple.to_list(term)
    {prefix, elems} = if tag, do: Enum.split(elems, 1), else: {[], elems}
    prefix |> Enum.concat(seq_defaults(seq, elems)) |> List.to_tuple()
  end

  defp with_defaults(%Heddle{node: _}, term), do: term

  defp seq_defaults(%Heddle{node: {:bind, codec, continuation}}, [term | rest]) do
    {:ok, value} =
      Heddle.decode(codec, :erlang.term_to_binary(term), max_nodes: 10_000_000, max_depth: 1_000)

    [
      with_defaults(codec, term)
      | seq_defaults(IR.seq!(continuation.(value), "a continuation"), rest)
    ]
  end

  defp seq_defaults(_seq, rest), do: rest

  defp plain(codec, value) do
    {:ok, iodata} = Heddle.encode(codec, value)
    :erlang.binary_to_term(IO.iodata_to_binary(iodata))
  end

  defp collect(inputs, check) do
    failures =
      Enum.flat_map(inputs, fn input ->
        case check.(input) do
          :ok -> []
          {:error, observed} -> [{input, observed}]
        end
      end)

    if failures == [], do: :ok, else: {:error, failures}
  end
end

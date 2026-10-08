defmodule Heddle.PropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Heddle.Test.CodecGen

  @large [max_bytes: 64 * 1_048_576, max_depth: 1_000, max_nodes: 10_000_000]

  defp codec_and_value do
    gen all {ast, codec} <- CodecGen.codec(),
            value <- Heddle.Gen.from(codec) do
      {ast, codec, value}
    end
  end

  defp encode(codec, value), do: codec |> Heddle.encode!(value) |> IO.iodata_to_binary()

  defp missing_atoms?(value), do: contains_missing_unknown?(value)

  defp contains_missing_unknown?({:unknown, name}) when is_binary(name) do
    _ = String.to_existing_atom(name)
    false
  rescue
    ArgumentError -> true
  end

  defp contains_missing_unknown?(v) when is_tuple(v),
    do: v |> Tuple.to_list() |> contains_missing_unknown?()

  defp contains_missing_unknown?(v) when is_list(v),
    do: Enum.any?(v, &contains_missing_unknown?/1)

  defp contains_missing_unknown?(v) when is_map(v),
    do:
      v
      |> Map.to_list()
      |> Enum.any?(fn {k, x} -> contains_missing_unknown?(k) or contains_missing_unknown?(x) end)

  defp contains_missing_unknown?(_), do: false

  property "decode(encode(v)) == {:ok, v}" do
    check all {ast, codec, value} <- codec_and_value(), max_runs: 300 do
      assert {:ok, ^value} = Heddle.decode(codec, encode(codec, value), @large),
             Macro.to_string(ast)
    end
  end

  property "identity projection and weak backward round trip" do
    check all {_ast, codec, value} <- codec_and_value(), max_runs: 200 do
      assert :ok = Heddle.Laws.identity_projection(codec, [value])
      assert :ok = Heddle.Laws.weak_backward(codec, [value])
    end
  end

  property "the VM reads what Heddle writes, and Heddle reads the VM's re-encoding" do
    check all {ast, codec, value} <- codec_and_value(),
              not missing_atoms?(value),
              minor <- StreamData.member_of([1, 2]),
              max_runs: 300 do
      term = :erlang.binary_to_term(encode(codec, value))
      reencoded = :erlang.term_to_binary(term, minor_version: minor)
      assert {:ok, ^value} = Heddle.decode(codec, reencoded, @large), Macro.to_string(ast)
    end
  end

  property "agreement with binary_to_term(b, [:safe]) on valid and mutated bytes" do
    check all {ast, codec, value} <- codec_and_value(),
              bin = encode(codec, value),
              mutations <-
                StreamData.list_of(mutation(byte_size(bin)), min_length: 1, max_length: 6),
              max_runs: 300 do
      corpus = [bin | Enum.map(mutations, &mutate(bin, &1))]
      assert :ok = Heddle.Check.differential(codec, corpus, @large), Macro.to_string(ast)
    end
  end

  defp mutation(size) do
    StreamData.one_of([
      StreamData.tuple(
        {StreamData.constant(:flip), StreamData.integer(0..max(size - 1, 0)),
         StreamData.integer(0..255)}
      ),
      StreamData.tuple({StreamData.constant(:truncate), StreamData.integer(0..size)}),
      StreamData.tuple(
        {StreamData.constant(:insert), StreamData.integer(0..size), StreamData.integer(0..255)}
      ),
      StreamData.tuple({StreamData.constant(:delete), StreamData.integer(0..max(size - 1, 0))})
    ])
  end

  defp mutate(bin, {:flip, i, b}) when i < byte_size(bin) do
    <<pre::binary-size(^i), _, post::binary>> = bin
    <<pre::binary, b, post::binary>>
  end

  defp mutate(bin, {:truncate, i}), do: binary_part(bin, 0, min(i, byte_size(bin)))

  defp mutate(bin, {:insert, i, b}) do
    i = min(i, byte_size(bin))
    <<pre::binary-size(^i), post::binary>> = bin
    <<pre::binary, b, post::binary>>
  end

  defp mutate(bin, {:delete, i}) when i < byte_size(bin) do
    <<pre::binary-size(^i), _, post::binary>> = bin
    <<pre::binary, post::binary>>
  end

  defp mutate(bin, _), do: bin
end

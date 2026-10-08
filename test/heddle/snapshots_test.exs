defmodule Heddle.SnapshotsTest do
  @moduledoc false
  # Heddle's encoder output for a fixed corpus, pinned per Heddle version.
  # A change fails until the snapshots are regenerated on purpose:
  #
  #     HEDDLE_UPDATE_SNAPSHOTS=1 mix test test/heddle/snapshots_test.exs
  #
  # and the change is listed in the changelog.
  use ExUnit.Case, async: true

  alias Heddle.Test.{Producers, Session}

  @path Path.expand("../fixtures/encoder_snapshots.etf", __DIR__)

  defp corpus do
    [
      {"session", Producers.session(),
       %Session{
         user_id: 42,
         roles: [:admin, :editor],
         expires_at: 1_790_000_000,
         meta: %{"ip" => "203.0.113.7"}
       }},
      {"commands", Producers.commands(), [:ping, {:put, "k", "v"}, {:delete, "k"}]},
      {"integers", Producers.integers(),
       [0, 255, 256, -1, 2_147_483_648, Integer.pow(2, 64), -Integer.pow(2, 100)]},
      {"floats", Producers.floats(), [1.5, -0.0, 1.0e300]},
      {"atoms", Producers.atoms(), [:é, :ok, :日本]},
      {"charlists", Producers.charlists(), [~c"hello", [300, 400], []]},
      {"binaries", Producers.binaries(), ["", "héllo"]},
      {"bigmap", Producers.bigmap(), Map.new(1..40, &{&1, &1 * &1})},
      {"unknown", Producers.unknown(), [:http, {:unknown, "gopher"}]}
    ]
  end

  test "encoder output matches the snapshots" do
    actual =
      Map.new(corpus(), fn {name, codec, value} ->
        {name, IO.iodata_to_binary(Heddle.encode!(codec, value))}
      end)

    if System.get_env("HEDDLE_UPDATE_SNAPSHOTS") do
      File.write!(@path, :erlang.term_to_binary(actual, [:deterministic]))
    end

    expected = @path |> File.read!() |> :erlang.binary_to_term()

    for {name, bytes} <- actual do
      assert Map.fetch!(expected, name) == bytes, "encoder output for #{name} changed"
    end
  end

  test "the VM reads every snapshot as the value" do
    for {name, codec, value} <- corpus() do
      bytes = IO.iodata_to_binary(Heddle.encode!(codec, value))

      assert {:ok, ^value} =
               Heddle.decode(codec, :erlang.term_to_binary(:erlang.binary_to_term(bytes))),
             name
    end
  end
end

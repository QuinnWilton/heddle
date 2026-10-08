defmodule Heddle.FixturesTest do
  @moduledoc false
  # Bytes written by term_to_binary/2 on every OTP release Heddle reads
  # (see test/fixtures/generate.escript), decoded on every run.
  use ExUnit.Case, async: true

  alias Heddle.Test.{Producers, Session}

  @dir Path.expand("../fixtures/producers", __DIR__)

  @expected %{
    "session" =>
      {&Producers.session/0,
       %Session{
         user_id: 42,
         roles: [:admin, :editor],
         expires_at: 1_790_000_000,
         meta: %{"ip" => "203.0.113.7", "agent" => "curl/8"}
       }},
    "commands" => {&Producers.commands/0, [:ping, {:put, "k", "v"}, {:delete, "k"}]},
    "integers" =>
      {&Producers.integers/0,
       [
         0,
         255,
         256,
         -1,
         2_147_483_647,
         -2_147_483_648,
         2_147_483_648,
         Integer.pow(2, 64),
         -Integer.pow(2, 100)
       ]},
    "floats" => {&Producers.floats/0, [1.5, -0.0, 1.0e300, 5.0e-324]},
    "atoms" => {&Producers.atoms/0, [:é, :ok, :ünïcode, :日本]},
    "charlists" => {&Producers.charlists/0, [~c"hello", [1, 2, 3], [300, 400], [], ~c"héllo"]},
    "binaries" => {&Producers.binaries/0, ["", "plain", "héllo", :binary.copy("x", 300)]},
    "nested" => {&Producers.nested/0, {:tag, [{:a, 1}, {:b, "two"}], %{}, {}}},
    "bigmap" => {&Producers.bigmap/0, Map.new(1..40, &{&1, &1 * &1})},
    "unknown" => {&Producers.unknown/0, [:http, :https, {:unknown, "gopher"}]}
  }

  @files @dir |> Path.join("otp*/*.etf") |> Path.wildcard() |> Enum.sort()

  test "fixtures exist for every supported producer" do
    releases = @files |> Enum.map(&(&1 |> Path.dirname() |> Path.basename())) |> Enum.uniq()
    assert releases == ~w(otp24 otp25 otp26 otp27 otp28 otp29)
    assert length(@files) == length(releases) * map_size(@expected) * 3
  end

  for file <- @files do
    [release, name] = [file |> Path.dirname() |> Path.basename(), Path.basename(file, ".etf")]

    @file_path file
    test "#{release} #{name}" do
      [case_name | _] = String.split(Path.basename(@file_path, ".etf"), "-")
      {codec_fun, expected} = Map.fetch!(@expected, case_name)
      codec = codec_fun.()
      bin = File.read!(@file_path)

      assert {:ok, ^expected} = Heddle.decode(codec, bin)
      assert :ok = Heddle.Check.backends(codec, [bin])
      assert :ok = Heddle.Check.differential(codec, [bin])
    end
  end
end

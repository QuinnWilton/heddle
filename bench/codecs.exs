# Compiled codecs against :erlang.binary_to_term/2 and :erlang.term_to_binary/1.
#
#     mix run bench/codecs.exs
#
# binary_to_term/2 builds an untyped term without validating it; Heddle
# validates every byte against the codec, enforces limits and builds the
# structs. The interpreter runs the same codecs without compilation, for
# reference.

defmodule Bench.User do
  @derive {Heddle.Codec,
           fields: [
             id: Heddle.integer(min: 1),
             name: Heddle.binary(max_size: 100, utf8: true),
             email: Heddle.binary(max_size: 254)
           ]}
  defstruct [:id, :name, :email]
end

defmodule Bench.Session do
  use Heddle.Schema

  defschema do
    field :user_id, Heddle.integer(min: 1)
    field :roles, Heddle.list(Heddle.enum([:admin, :editor, :viewer]), max: 16)
    field :expires_at, Heddle.integer(min: 0)
    field :meta, Heddle.map_of(Heddle.binary(max_size: 64), Heddle.binary(max_size: 256), max: 32), default: %{}
  end
end

defmodule Bench.Command do
  use Heddle.Schema

  defunion do
    variant :ping
    variant :put, key: Heddle.binary(max_size: 128), value: Heddle.binary(max_size: 4096)
    variant :delete, key: Heddle.binary(max_size: 128)
    variant :incr, key: Heddle.binary(max_size: 128), by: Heddle.integer(min: -1000, max: 1000)
  end
end

defmodule Bench.Codecs do
  use Heddle.Schema

  defcodec ints do
    Heddle.list(Heddle.integer(), max: 10_000)
  end

  defcodec blobs do
    Heddle.map_of(Heddle.binary(max_size: 32), Heddle.binary(max_size: 4096), max: 64)
  end

  defcodec commands do
    Heddle.list(Bench.Command, max: 1_000)
  end

  defcodec texts do
    Heddle.map_of(Heddle.binary(max_size: 32, utf8: true), Heddle.binary(max_size: 4096, utf8: true), max: 64)
  end

  defcodec percents do
    Heddle.list(Heddle.integer(min: 0, max: 100), max: 65_535)
  end

  defcodec users do
    Heddle.list(Bench.User, max: 1_000)
  end
end

# Struct literals cannot name modules defined in the same script.
session =
  struct!(Bench.Session,
    user_id: 42,
    roles: [:admin, :editor],
    expires_at: 1_790_000_000,
    meta: %{"ip" => "203.0.113.7", "agent" => "Mozilla/5.0", "locale" => "en-GB"}
  )

commands =
  for i <- 1..100 do
    case rem(i, 4) do
      0 -> :ping
      1 -> {:put, "key:#{i}", :binary.copy("v", 64)}
      2 -> {:delete, "key:#{i}"}
      3 -> {:incr, "counter:#{i}", rem(i, 100)}
    end
  end

users = for i <- 1..100, do: struct!(Bench.User, id: i, name: "User #{i}", email: "user#{i}@example.com")

cases = [
  {"session struct", Bench.Session.codec(), session},
  {"1,000 integers", Bench.Codecs.ints(), Enum.map(1..1_000, &(&1 * 7_919))},
  {"16 x 1 KiB binaries", Bench.Codecs.blobs(), Map.new(1..16, &{"k#{&1}", :binary.copy("x", 1024)})},
  {"16 x 1 KiB UTF-8 text", Bench.Codecs.texts(), Map.new(1..16, &{"k#{&1}", :binary.copy("plain ascii text ", 64)})},
  {"4,000 integers in 0..100 (STRING_EXT)", Bench.Codecs.percents(), Enum.map(1..4_000, &rem(&1, 101))},
  {"100 union commands", Bench.Codecs.commands(), commands},
  {"100 derived structs", Bench.Codecs.users(), users}
]

limits = [max_nodes: 1_000_000, max_bytes: 16 * 1_048_576]

for {name, codec, value} <- cases do
  bin = :erlang.term_to_binary(value)
  {:ok, ^value} = Heddle.decode(codec, bin, limits)
  {:ok, ^value} = Heddle.Interpreter.decode(codec, bin, limits)
  ir = Heddle.Interpreter

  IO.puts("\n## #{name} (#{byte_size(bin)} bytes)\n")

  Benchee.run(
    %{
      "decode: Heddle compiled" => fn -> {:ok, _} = Heddle.decode(codec, bin, limits) end,
      "decode: Heddle interpreter" => fn -> {:ok, _} = ir.decode(codec, bin, limits) end,
      "decode: binary_to_term" => fn -> :erlang.binary_to_term(bin) end,
      "decode: binary_to_term [:safe]" => fn -> :erlang.binary_to_term(bin, [:safe]) end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false, benchmarking: false]
  )

  Benchee.run(
    %{
      "encode: Heddle compiled" => fn -> {:ok, io} = Heddle.encode(codec, value); IO.iodata_to_binary(io) end,
      "encode: Heddle interpreter" => fn -> {:ok, _, io} = ir.encode(codec, value); IO.iodata_to_binary(io) end,
      "encode: term_to_binary" => fn -> :erlang.term_to_binary(value) end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false, benchmarking: false]
  )
end

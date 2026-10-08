# Compiled codecs against :erlang.binary_to_term/2 and :erlang.term_to_binary/1,
# with the interpreter for reference, as full Benchee reports.
#
#     mix run bench/codecs.exs
#
# bench/ratios.exs prints the same comparison as one table of multiples.
#
# binary_to_term/2 builds an untyped term without validating it; Heddle
# validates every byte against the codec, enforces limits and builds the
# structs.

Code.require_file("support.exs", __DIR__)
{cases, _} = Code.eval_file(Path.join(__DIR__, "cases.exs"))
limits = [max_nodes: 1_000_000, max_bytes: 16 * 1_048_576]

for {name, codec, value} <- cases do
  bin = :erlang.term_to_binary(value)
  {:ok, ^value} = Heddle.decode(codec, bin, limits)
  {:ok, ^value} = Heddle.Interpreter.decode(codec, bin, limits)
  interpreter = Heddle.Interpreter

  IO.puts("\n## #{name} (#{byte_size(bin)} bytes)\n")

  Benchee.run(
    %{
      "decode: Heddle compiled" => fn -> {:ok, _} = Heddle.decode(codec, bin, limits) end,
      "decode: Heddle interpreter" => fn -> {:ok, _} = interpreter.decode(codec, bin, limits) end,
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
      "encode: Heddle compiled" => fn ->
        {:ok, io} = Heddle.encode(codec, value)
        IO.iodata_to_binary(io)
      end,
      "encode: Heddle interpreter" => fn ->
        {:ok, _, io} = interpreter.encode(codec, value)
        IO.iodata_to_binary(io)
      end,
      "encode: term_to_binary" => fn -> :erlang.term_to_binary(value) end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false, benchmarking: false]
  )
end

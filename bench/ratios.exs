# Heddle's compiled codecs as a multiple of the BIFs they replace.
#
#     mix run bench/ratios.exs
#
# Each figure is the median of 15 batches, with each batch timing enough calls to
# take about 20 ms. Lower is better; 1.00x means as fast as the BIF.

Code.require_file("support.exs", __DIR__)

defmodule Bench.Timing do
  def ns_per_op(fun) do
    n = calibrate(fun, 1)

    for(_ <- 1..15, do: batch(fun, n))
    |> Enum.sort()
    |> Enum.at(7)
  end

  defp calibrate(fun, n) do
    if batch(fun, n) * n < 20_000_000 and n < 10_000_000, do: calibrate(fun, n * 2), else: n
  end

  defp batch(fun, n) do
    {us, _} = :timer.tc(fn -> loop(fun, n) end, :nanosecond)
    us / n
  end

  defp loop(_fun, 0), do: :ok

  defp loop(fun, n) do
    fun.()
    loop(fun, n - 1)
  end
end

{cases, _} = Code.eval_file(Path.join(__DIR__, "cases.exs"))
limits = [max_nodes: 1_000_000, max_bytes: 16 * 1_048_576]

IO.puts(String.pad_trailing("payload", 40) <> "  decode   vs b2t[:safe]   encode   vs t2b")

for {name, codec, value} <- cases do
  bin = :erlang.term_to_binary(value)
  {:ok, ^value} = Heddle.decode(codec, bin, limits)

  dec = Bench.Timing.ns_per_op(fn -> Heddle.decode(codec, bin, limits) end)
  b2t = Bench.Timing.ns_per_op(fn -> :erlang.binary_to_term(bin, [:safe]) end)
  enc = Bench.Timing.ns_per_op(fn -> {:ok, io} = Heddle.encode(codec, value); IO.iodata_to_binary(io) end)
  t2b = Bench.Timing.ns_per_op(fn -> :erlang.term_to_binary(value) end)

  fmt = fn ns -> :io_lib.format("~8.2f", [ns / 1000]) |> to_string() end
  ratio = fn a, b -> :io_lib.format("~6.2fx", [a / b]) |> to_string() end

  IO.puts(String.pad_trailing(name, 40) <> fmt.(dec) <> "us " <> ratio.(dec, b2t) <> "    " <> fmt.(enc) <> "us " <> ratio.(enc, t2b))
end

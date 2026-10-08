defmodule Heddle.Laws do
  @moduledoc """
  The round-trip laws, checked over sample values.

  Weak backward round-tripping holds by construction for Heddle's
  primitives and is preserved by every combinator. With lawful `iso/3`
  functions, identity projection holds too, and together they give the
  backward round trip. User functions are where the laws can fail, so check
  them over generated samples:

      check all v <- Heddle.Gen.from(codec), max_runs: 200 do
        assert :ok = Heddle.Laws.backward(codec, [v])
      end

  Each function returns `:ok` or `{:error, failures}`, listing every sample
  that broke the law with what was observed.
  """

  @type failure :: {sample :: term(), observed :: term()}

  @doc """
  Identity projection (`purify` is the identity): `Heddle.project/2` returns
  each sample unchanged.
  """
  @spec identity_projection(Heddle.t(), Enumerable.t()) :: :ok | {:error, [failure()]}
  def identity_projection(codec, samples) do
    collect(samples, fn x ->
      case Heddle.project(codec, x) do
        {:ok, ^x} -> :ok
        other -> {:error, other}
      end
    end)
  end

  @doc """
  Weak backward round trip: when encoding yields bytes and a decoded value
  `y`, decoding those bytes yields `y`.
  """
  @spec weak_backward(Heddle.t(), Enumerable.t()) :: :ok | {:error, [failure()]}
  def weak_backward(codec, samples) do
    collect(samples, fn x ->
      with {:ok, y} <- Heddle.project(codec, x),
           {:ok, iodata} <- Heddle.encode(codec, x),
           {:ok, ^y} <- Heddle.decode(codec, IO.iodata_to_binary(iodata), large()) do
        :ok
      else
        {:error, %Heddle.EncodeError{}} -> :ok
        other -> {:error, other}
      end
    end)
  end

  @doc "Backward round trip: `decode(encode(x)) == {:ok, x}` for each sample."
  @spec backward(Heddle.t(), Enumerable.t()) :: :ok | {:error, [failure()]}
  def backward(codec, samples) do
    collect(samples, fn x ->
      with {:ok, iodata} <- Heddle.encode(codec, x),
           {:ok, ^x} <- Heddle.decode(codec, IO.iodata_to_binary(iodata), large()) do
        :ok
      else
        other -> {:error, other}
      end
    end)
  end

  defp large, do: [max_bytes: 64 * 1_048_576, max_depth: 1_000, max_nodes: 10_000_000]

  defp collect(samples, check) do
    failures =
      Enum.flat_map(samples, fn x ->
        case check.(x) do
          :ok -> []
          {:error, observed} -> [{x, observed}]
        end
      end)

    if failures == [], do: :ok, else: {:error, failures}
  end
end

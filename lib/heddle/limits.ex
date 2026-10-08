defmodule Heddle.Limits do
  @moduledoc """
  Resource limits for one decode.

    * `max_bytes` (default 1 MiB) - input size, checked before parsing.
    * `max_depth` (default 32) - nesting depth; the root term is depth 1, and
      each tuple, list or map puts its children one level deeper.
    * `max_nodes` (default 10,000) - decoded terms, counting every list
      element, tuple element, map key and map value, plus one for each `bind`
      continuation.
    * `binaries` (default `:copy`) - `:copy` copies kept binaries so they do
      not pin the input; `:ref` returns sub-binaries of it.

  Limits form a meet-semilattice: `meet/2` takes the tighter of each, so a
  policy layered on another can tighten it but never loosen it.
  """

  @enforce_keys [:max_bytes, :max_depth, :max_nodes, :binaries]
  defstruct max_bytes: 1_048_576, max_depth: 32, max_nodes: 10_000, binaries: :copy

  @type binaries :: :copy | :ref

  @type t :: %__MODULE__{
          max_bytes: pos_integer(),
          max_depth: pos_integer(),
          max_nodes: pos_integer(),
          binaries: binaries()
        }

  @type option ::
          {:max_bytes, pos_integer()}
          | {:max_depth, pos_integer()}
          | {:max_nodes, pos_integer()}
          | {:binaries, binaries()}

  @doc "The default limits."
  @spec default() :: t()
  def default,
    do: %__MODULE__{max_bytes: 1_048_576, max_depth: 32, max_nodes: 10_000, binaries: :copy}

  @doc """
  Builds limits from options over the defaults.

  Raises `ArgumentError` on an unknown option or an invalid value.
  """
  @spec new(t() | [option()]) :: t()
  def new(%__MODULE__{} = limits), do: limits

  def new(opts) when is_list(opts) do
    Enum.reduce(opts, default(), fn
      {key, n}, acc
      when key in [:max_bytes, :max_depth, :max_nodes] and is_integer(n) and n > 0 ->
        Map.put(acc, key, n)

      {:binaries, mode}, acc when mode in [:copy, :ref] ->
        %{acc | binaries: mode}

      {key, value}, _ when key in [:max_bytes, :max_depth, :max_nodes] ->
        raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"

      {:binaries, value}, _ ->
        raise ArgumentError, "binaries must be :copy or :ref, got: #{inspect(value)}"

      other, _ ->
        raise ArgumentError, "unknown decode option: #{inspect(other)}"
    end)
  end

  @doc """
  The tighter of two limits, field by field.

  `binaries: :copy` is tighter than `:ref`, since it never pins the input.
  """
  @spec meet(t(), t()) :: t()
  def meet(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      max_bytes: min(a.max_bytes, b.max_bytes),
      max_depth: min(a.max_depth, b.max_depth),
      max_nodes: min(a.max_nodes, b.max_nodes),
      binaries: if(a.binaries == :copy or b.binaries == :copy, do: :copy, else: :ref)
    }
  end
end

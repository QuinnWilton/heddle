defmodule Heddle.Test.Fns do
  @moduledoc false
  # Lawful functions for iso/3 and refine/3 in generated codecs.

  def wrap(v), do: {:ok, {:w, v}}
  def unwrap({:w, v}), do: {:ok, v}
  def unwrap(_), do: :error

  def even?(n), do: rem(n, 2) == 0

  def short?(bin), do: byte_size(bin) <= 4
end

defmodule Heddle.Test.Point do
  @moduledoc false
  defstruct x: 0, y: 0, label: nil, cache: :unset
end

defmodule Heddle.Test.Box do
  @moduledoc false
  defstruct [:contents, size: 1]
end

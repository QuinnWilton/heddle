# Codecs for the benchmarks in this directory; bench/cases.exs builds the
# payloads they encode and decode.

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

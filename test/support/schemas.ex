defmodule Heddle.Test.Session do
  @moduledoc false
  use Heddle.Schema

  defschema as: :map do
    field :user_id, integer(min: 1)
    field :roles, list(enum([:admin, :editor, :viewer]), max: 16)
    field :expires_at, integer(min: 0)

    field :meta, map_of(binary(max_size: 64), binary(max_size: 256), max: 32), default: %{}
  end
end

defmodule Heddle.Test.Command do
  @moduledoc false
  use Heddle.Schema

  defunion do
    variant :ping
    variant :put, key: binary(max_size: 128), value: binary(max_size: 4096)
    variant :delete, key: binary(max_size: 128)
  end
end

defmodule Heddle.Test.Env do
  @moduledoc false
  use Heddle.Schema

  defcodec envelope do
    tuple_seq tag: :envelope do
      version <- integer(min: 1, max: 2) <~ field(:version)

      body <-
        case version do
          1 -> binary(max_size: 1024)
          2 -> Heddle.Test.Command.codec()
        end
        <~ field(:body)

      pure %{version: version, body: body}
    end
  end

  defcodec sized do
    tuple_seq do
      n <- integer(min: 0, max: 1000) <~ field(:n)
      items <- list(integer(), max: n) <~ field(:items)
      pure %{n: n, items: items}
    end
  end

  defcodec tree do
    one_of([
      atom(:leaf),
      tuple([atom(:node), tree(), integer(), tree()])
    ])
  end

  defcodec lazy_tree do
    one_of([null(), list(lazy(&lazy_tree/0), max: 3)])
  end

  defcodec refined do
    refine(integer(), &even?/1, :even)
    |> iso(&{:ok, {:n, &1}}, fn
      {:n, x} -> {:ok, x}
      _ -> :error
    end)
  end

  def even?(n), do: rem(n, 2) == 0
end

defmodule Heddle.Test.User do
  @moduledoc false
  import Heddle.DSL

  @derive {Heddle.Codec, fields: [id: integer(min: 1), name: binary(max_size: 100, utf8: true)]}
  defstruct [:id, :name, :cache]
end

defmodule Heddle.Test.Team do
  @moduledoc false
  use Heddle.Schema

  defschema do
    field :name, binary(max_size: 20)
    field :lead, Heddle.Test.User
    field :members, list(Heddle.Test.User, max: 10)
  end
end

defmodule Heddle.Test.UriCodecs do
  @moduledoc false
  use Heddle.Schema

  defcodec uri_codec do
    Heddle.struct(URI,
      as: :map,
      fields: [
        scheme: enum([:http, :https], unknown: :keep),
        host: binary(max_size: 253)
      ]
    )
  end

  defcodec profile do
    map(required: [homepage: uri_codec()])
  end
end

# Mutually recursive structs in different modules: each names the other.
defmodule Heddle.Test.Folder do
  @moduledoc false
  use Heddle.Schema

  defschema do
    field :name, binary(max_size: 32)
    field :files, list(Heddle.Test.File, max: 8)
  end
end

defmodule Heddle.Test.File do
  @moduledoc false
  use Heddle.Schema

  defschema as: :tuple, tag: :file do
    field :name, binary(max_size: 32)
    field :parent, one_of([null(), Heddle.Test.Folder])
  end
end

defmodule Heddle.Test.Producers do
  @moduledoc false
  # Codecs for the producer corpus in test/fixtures/generate.escript.
  use Heddle.Schema

  defcodec session do
    Heddle.Test.Session
  end

  defcodec commands do
    list(Heddle.Test.Command, max: 10)
  end

  defcodec integers do
    list(integer(), max: 10)
  end

  defcodec floats do
    list(float(), max: 10)
  end

  defcodec atoms do
    list(enum([:é, :ok, :ünïcode, :日本]), max: 10)
  end

  defcodec charlists do
    list(charlist(max: 10), max: 10)
  end

  defcodec binaries do
    list(binary(max_size: 1000, utf8: true), max: 10)
  end

  defcodec nested do
    tuple([
      atom(:tag),
      list(
        one_of([tagged(:a, integer()), tagged(:b, binary())]),
        max: 4
      ),
      map([]),
      tuple([])
    ])
  end

  defcodec bigmap do
    map_of(integer(min: 0), integer(min: 0), max: 64)
  end

  defcodec unknown do
    list(enum([:http, :https], unknown: :keep), max: 10)
  end
end

defmodule Heddle.Test.Point2D do
  @moduledoc false
  use Heddle.Schema

  defschema as: :tuple, tag: :point do
    field :x, integer(min: -10_000, max: 10_000)
    field :y, integer(min: -10_000, max: 10_000)
  end
end

defmodule Heddle.Test.Drawing do
  @moduledoc false
  # A union whose variants are built from other codecs: a struct schema, a
  # list of it, and the union itself, for nesting.
  use Heddle.Schema

  defunion do
    variant :empty
    variant :circle, center: Heddle.Test.Point2D, radius: integer(min: 1, max: 10_000)
    variant :polygon, points: list(Heddle.Test.Point2D, max: 64)
    variant :group, shapes: list(Heddle.Test.Drawing, max: 16)
  end
end

defmodule Heddle.Test.Accounts do
  @moduledoc false
  # A union of structs laid out as maps, dispatched on :__struct__.
  use Heddle.Schema

  defcodec account do
    one_of([atom(:anonymous), Heddle.Test.Session, Heddle.Test.Team])
  end
end

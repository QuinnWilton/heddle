defmodule Heddle.Test.Session do
  use Heddle.Schema

  defschema as: :map do
    field(:user_id, Heddle.integer(min: 1))
    field(:roles, Heddle.list(Heddle.enum([:admin, :editor, :viewer]), max: 16))
    field(:expires_at, Heddle.integer(min: 0))

    field(
      :meta,
      Heddle.map_of(Heddle.binary(max_size: 64), Heddle.binary(max_size: 256), max: 32),
      default: %{}
    )
  end
end

defmodule Heddle.Test.Command do
  use Heddle.Schema

  defunion do
    variant(:ping)
    variant(:put, key: Heddle.binary(max_size: 128), value: Heddle.binary(max_size: 4096))
    variant(:delete, key: Heddle.binary(max_size: 128))
  end
end

defmodule Heddle.Test.Env do
  use Heddle.Schema
  import Heddle.Syntax

  defcodec envelope do
    tuple_seq tag: :envelope do
      version <- Heddle.integer(min: 1, max: 2) <~ field(:version)

      body <-
        case version do
          1 -> Heddle.binary(max_size: 1024)
          2 -> Heddle.Test.Command.codec()
        end
        <~ field(:body)

      pure(%{version: version, body: body})
    end
  end

  defcodec sized do
    tuple_seq do
      n <- Heddle.integer(min: 0, max: 1000) <~ field(:n)
      items <- Heddle.list(Heddle.integer(), max: n) <~ field(:items)
      pure(%{n: n, items: items})
    end
  end

  defcodec tree do
    Heddle.one_of([
      Heddle.atom(:leaf),
      Heddle.tuple([Heddle.atom(:node), tree(), Heddle.integer(), tree()])
    ])
  end

  defcodec lazy_tree do
    Heddle.one_of([Heddle.null(), Heddle.list(Heddle.lazy(&lazy_tree/0), max: 3)])
  end

  defcodec refined do
    Heddle.refine(Heddle.integer(), &even?/1, :even)
    |> Heddle.iso(&{:ok, {:n, &1}}, fn
      {:n, x} -> {:ok, x}
      _ -> :error
    end)
  end

  def even?(n), do: rem(n, 2) == 0
end

defmodule Heddle.Test.User do
  @derive {Heddle.Codec,
           fields: [id: Heddle.integer(min: 1), name: Heddle.binary(max_size: 100, utf8: true)]}
  defstruct [:id, :name, :cache]
end

defmodule Heddle.Test.Team do
  use Heddle.Schema

  defschema do
    field(:name, Heddle.binary(max_size: 20))
    field(:lead, Heddle.Test.User)
    field(:members, Heddle.list(Heddle.Test.User, max: 10))
  end
end

defmodule Heddle.Test.UriCodecs do
  use Heddle.Schema

  defcodec uri_codec do
    Heddle.struct(URI,
      as: :map,
      fields: [
        scheme: Heddle.enum([:http, :https], unknown: :keep),
        host: Heddle.binary(max_size: 253)
      ]
    )
  end

  defcodec profile do
    Heddle.map(required: [homepage: uri_codec()])
  end
end

# Mutually recursive structs in different modules: each names the other.
defmodule Heddle.Test.Folder do
  use Heddle.Schema

  defschema do
    field(:name, Heddle.binary(max_size: 32))
    field(:files, Heddle.list(Heddle.Test.File, max: 8))
  end
end

defmodule Heddle.Test.File do
  use Heddle.Schema

  defschema as: :tuple, tag: :file do
    field(:name, Heddle.binary(max_size: 32))
    field(:parent, Heddle.one_of([Heddle.null(), Heddle.Test.Folder]))
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
    Heddle.list(Heddle.Test.Command, max: 10)
  end

  defcodec integers do
    Heddle.list(Heddle.integer(), max: 10)
  end

  defcodec floats do
    Heddle.list(Heddle.float(), max: 10)
  end

  defcodec atoms do
    Heddle.list(Heddle.enum([:é, :ok, :ünïcode, :日本]), max: 10)
  end

  defcodec charlists do
    Heddle.list(Heddle.charlist(max: 10), max: 10)
  end

  defcodec binaries do
    Heddle.list(Heddle.binary(max_size: 1000, utf8: true), max: 10)
  end

  defcodec nested do
    Heddle.tuple([
      Heddle.atom(:tag),
      Heddle.list(
        Heddle.one_of([Heddle.tagged(:a, Heddle.integer()), Heddle.tagged(:b, Heddle.binary())]),
        max: 4
      ),
      Heddle.map([]),
      Heddle.tuple([])
    ])
  end

  defcodec bigmap do
    Heddle.map_of(Heddle.integer(min: 0), Heddle.integer(min: 0), max: 64)
  end

  defcodec unknown do
    Heddle.list(Heddle.enum([:http, :https], unknown: :keep), max: 10)
  end
end

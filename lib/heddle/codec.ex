defprotocol Heddle.Codec do
  @moduledoc """
  The compiled codec of a struct, derived where the struct is defined.

      defmodule MyApp.User do
        @derive {Heddle.Codec,
                 as: :map,
                 fields: [id: Heddle.integer(min: 1), name: Heddle.binary(max_size: 100, utf8: true)]}
        defstruct [:id, :name, :cache]
      end

      Heddle.codec_for(MyApp.User)

  Options are those of `Heddle.struct/2`. Every serialized field needs an
  explicit codec; a field left out of `fields:` is neither encoded nor
  accepted. The protocol is resolved on the module named at the call site,
  never on decoded data.

  Derive codecs only for structs you own: a struct can have one
  implementation in the VM, so two libraries deriving different bounds for
  the same struct would depend on compile order. For a struct you do not
  own, define a codec with `Heddle.struct/2` and `defcodec`, and name it
  where it is used.

  Elixir evaluates `@derive` options as a module attribute, so they may call
  Heddle's constructors and other modules, and functions in them must be
  external captures (`&Mod.fun/1`). For codecs with local helpers or
  anonymous functions, use `Heddle.Schema.defschema/2`.
  """

  @doc "The codec of `struct`'s module."
  @spec codec(t()) :: Heddle.t()
  def codec(struct)

  @impl true
  defmacro __deriving__(module, opts) do
    Heddle.Schema.derive(module, opts, __CALLER__)
  end
end

defmodule Heddle do
  @moduledoc """
  Safe, bidirectional ETF codecs for the BEAM.

  A codec `Heddle.t(i, o)` is one value that both encodes an `i` to external
  term format and decodes bytes to an `o`. Codecs replace
  `:erlang.binary_to_term/2` and `:erlang.term_to_binary/2` at trust
  boundaries:

    * decoding accepts only the ETF subset the codec names, and never creates
      atoms, funs, pids, ports or references;
    * every length is checked against the codec's bound and the remaining
      input before anything is allocated, and limits passed at the call site
      bound depth, total terms and input size;
    * encoding is partial: a value outside the codec's domain fails instead of
      producing bytes the decoder would reject.

  ```elixir
  session =
    Heddle.map(
      required: [
        user_id: Heddle.integer(min: 1),
        roles: Heddle.list(Heddle.enum([:admin, :editor, :viewer]), max: 16)
      ]
    )

  {:ok, iodata} = Heddle.encode(session, %{user_id: 7, roles: [:admin]})
  {:ok, %{user_id: 7, roles: [:admin]}} =
    Heddle.decode(session, IO.iodata_to_binary(iodata), max_depth: 8)
  ```

  Codecs built with these functions at runtime run in an interpreter. Codecs
  defined with `Heddle.Schema` (`defcodec`, `defschema`, `defunion`) or
  derived with `@derive Heddle.Codec` compile to binary pattern matches at
  build time. See the design document for the full specification.

  `Heddle.DSL` exports the constructors for import, so a codec can read
  `list(integer(), max: 16)`. `use Heddle.Schema` imports it.
  """

  alias Heddle.{CodecError, DecodeError, EncodeError, Interpreter, IR, Limits}
  alias Heddle.IR.{Field, FunRef, Param}

  @enforce_keys [:node]
  defstruct [:node, span: nil]

  @typedoc """
  A codec that encodes an `i` and decodes to an `o`.

  Treat it as opaque: its fields are Heddle's internal representation,
  which Heddle's own modules share, and they change between versions.
  """
  @type t(_i, _o) :: %__MODULE__{node: term(), span: term()}

  @typedoc "An aligned codec: it encodes and decodes the same type."
  @type t(a) :: t(a, a)

  @type t :: t(term(), term())

  @typedoc "Selects the part of a value a codec encodes; see `from/2`."
  @type getter :: (term() -> {:ok, term()} | :error) | Field.t()

  @typedoc "A bound: a non-negative integer, or `nil` for none."
  @type bound :: non_neg_integer() | nil

  ## Primitives

  @doc """
  An atom literal, matched as bytes and never interned.

  All four atom tags are accepted, including the deprecated Latin-1 tags for
  names that have a Latin-1 spelling.
  """
  @spec atom(atom()) :: t(atom())
  def atom(atom) when is_atom(atom), do: %__MODULE__{node: {:literal, atom}}
  def atom(other), do: invalid!("Heddle.atom/1 expects an atom, got #{inspect(other)}")

  @doc """
  A finite set of atoms.

  With `unknown: :keep`, a name outside the set decodes as
  `{:unknown, name}` (a UTF-8 binary) and encodes back as atom bytes, so it
  round-trips without ever creating the atom. The encoder rejects
  `{:unknown, name}` when `name` is in the set. `enum([], unknown: :keep)`
  accepts any name as data.
  """
  @spec enum([atom()], unknown: :reject | :keep) :: t(atom() | {:unknown, String.t()})
  def enum(atoms, opts \\ []) do
    opts = opts!(opts, [unknown: :reject], "Heddle.enum/2")
    unknown = opts[:unknown]

    unless is_list(atoms) and Enum.all?(atoms, &is_atom/1),
      do: invalid!("Heddle.enum/2 expects a list of atoms, got #{inspect(atoms)}")

    unless unknown in [:reject, :keep],
      do: invalid!("Heddle.enum/2 option :unknown must be :reject or :keep")

    if atoms == [] and unknown == :reject,
      do: invalid!("Heddle.enum/2 with no atoms accepts nothing; pass unknown: :keep")

    if length(Enum.uniq(atoms)) != length(atoms),
      do: invalid!("Heddle.enum/2 lists an atom twice: #{inspect(atoms)}")

    %__MODULE__{node: {:enum, atoms, unknown}}
  end

  @doc """
  Any atom that already exists in the VM.

  Names are looked up with `:erlang.binary_to_existing_atom/2`; a name with
  no existing atom is rejected. The result can be any atom, including module
  names, so never use it as a module, a struct name or an `apply/3` target.
  Its results depend on what is loaded, so the same bytes can decode
  differently on two nodes.
  """
  @spec existing_atom() :: t(atom())
  def existing_atom, do: %__MODULE__{node: :existing_atom}

  @doc "`true` or `false`."
  @spec boolean() :: t(boolean())
  def boolean, do: %__MODULE__{node: {:enum, [false, true], :reject}}

  @doc "The atom `nil`, distinct from `[]`."
  @spec null() :: t(nil)
  def null, do: atom(nil)

  @doc """
  An integer, optionally bounded by `min:` and `max:`.

  A bignum's declared size is checked against the range before its magnitude
  is read; an unbounded range is capped at the VM's bignum limit.
  """
  @spec integer(min: integer() | nil, max: integer() | nil) :: t(integer())
  def integer(opts \\ []) do
    opts = opts!(opts, [min: nil, max: nil], "Heddle.integer/1")
    {min, max} = {opts[:min], opts[:max]}

    for {key, value} <- [min: min, max: max],
        not (is_nil(value) or is_integer(value) or param?(value)) do
      invalid!(
        "Heddle.integer/1 option #{inspect(key)} must be an integer, got #{inspect(value)}"
      )
    end

    if is_integer(min) and is_integer(max) and min > max,
      do: invalid!("Heddle.integer/1 has min #{min} above max #{max}")

    %__MODULE__{node: {:integer, min, max}}
  end

  @doc """
  A float, written as `NEW_FLOAT_EXT`.

  `FLOAT_EXT`, NaN and infinities are rejected.
  """
  @spec float() :: t(float())
  def float, do: %__MODULE__{node: :float}

  @doc """
  A binary of at most `max_size:` bytes, optionally required to be UTF-8.

  Kept binaries are copied by default; see `Heddle.Limits`.
  """
  @spec binary(max_size: bound(), utf8: boolean()) :: t(binary())
  def binary(opts \\ []) do
    opts = opts!(opts, [max_size: nil, utf8: false], "Heddle.binary/1")
    unless bound?(opts[:max_size]), do: invalid!(bound_text("Heddle.binary/1", :max_size, opts))
    unless is_boolean(opts[:utf8]), do: invalid!("Heddle.binary/1 option :utf8 must be a boolean")
    %__MODULE__{node: {:binary, opts[:max_size], opts[:utf8]}}
  end

  @doc """
  A proper list of at most `max:` elements.

  `STRING_EXT` is accepted wherever the element codec accepts the integers
  it holds, so `list(integer(min: 0, max: 1000))` reads OTP's own encoding
  of `[1, 2, 3]`.
  """
  @spec list(t(i, o), max: bound()) :: t([i], [o]) when i: term(), o: term()
  def list(elem, opts \\ []) do
    elem = IR.codec!(elem, "Heddle.list/2")
    opts = opts!(opts, [max: nil], "Heddle.list/2")
    unless bound?(opts[:max]), do: invalid!(bound_text("Heddle.list/2", :max, opts))
    %__MODULE__{node: {:list, elem, opts[:max]}}
  end

  @doc "A charlist: a list of Unicode code points, from `STRING_EXT` or `LIST_EXT`."
  @spec charlist(max: bound()) :: t(charlist())
  def charlist(opts \\ []) do
    opts = opts!(opts, [max: nil], "Heddle.charlist/1")
    unless bound?(opts[:max]), do: invalid!(bound_text("Heddle.charlist/1", :max, opts))
    %__MODULE__{node: {:list, %__MODULE__{node: :char}, opts[:max]}}
  end

  @doc "A tuple of exactly these elements, in order."
  @spec tuple([t()]) :: t(tuple())
  def tuple(elems) when is_list(elems) do
    %__MODULE__{node: {:tuple, Enum.map(elems, &IR.codec!(&1, "Heddle.tuple/1"))}}
  end

  def tuple(other), do: invalid!("Heddle.tuple/1 expects a list of codecs, got #{inspect(other)}")

  @doc """
  A map with atom keys: `required:` keys must be present, `optional:` keys
  may be.

  An absent optional key is absent from the decoded map, and the encoder
  omits optional keys the value does not have. Keys the codec does not name
  are rejected, and so is a `:__struct__` key: use `struct/2` for structs.
  """
  @spec map(required: keyword(t()), optional: keyword(t())) :: t(map())
  def map(opts) do
    opts = opts!(opts, [required: [], optional: []], "Heddle.map/1")
    required = keyed!(opts[:required], "Heddle.map/1 option :required")
    optional = keyed!(opts[:optional], "Heddle.map/1 option :optional")
    keys = Keyword.keys(required) ++ Keyword.keys(optional)

    if :__struct__ in keys do
      raise CodecError,
        code: "H003",
        summary: "Heddle.map/1 names a :__struct__ key",
        labels: [],
        help: "a decoded map has a :__struct__ key only through Heddle.struct/2"
    end

    if length(Enum.uniq(keys)) != length(keys),
      do: invalid!("Heddle.map/1 names a key twice: #{inspect(keys)}")

    %__MODULE__{node: {:map, required, optional}}
  end

  @doc """
  A map from keys to values, with at most `max:` pairs.

  Duplicate keys are rejected, and so is a `:__struct__` key, whatever the
  key codec: `map_of(existing_atom(), existing_atom())` cannot decode
  `%{__struct__: SomeModule}`.
  """
  @spec map_of(t(k), t(v), max: bound()) :: t(%{optional(k) => v}) when k: term(), v: term()
  def map_of(key, value, opts \\ []) do
    key = IR.codec!(key, "Heddle.map_of/3 key")
    value = IR.codec!(value, "Heddle.map_of/3 value")
    opts = opts!(opts, [max: nil], "Heddle.map_of/3")
    unless bound?(opts[:max]), do: invalid!(bound_text("Heddle.map_of/3", :max, opts))
    IR.check_struct_key_free!(key, "Heddle.map_of/3")
    %__MODULE__{node: {:map_of, key, value, opts[:max]}}
  end

  @doc """
  A struct of `module`, laid out as a map (`as: :map`, the default) or a
  tuple (`as: :tuple`, with an optional leading `tag:` atom).

  `fields:` lists every serialized field, as `name: codec`, or as
  `name: {codec, default: value}` to give the field a default of its own.
  Fields left out of `fields:` are neither encoded nor accepted, and
  decoding fills them from the struct's defaults. The encoder always writes
  every serialized field.

  In the map layout, the input may omit a field when either:

    * the field has `default: value`, and decodes to `value`; or
    * the struct does not enforce the field (`@enforce_keys`), and the
      field's codec encodes the struct's own default for it. The field then
      decodes to that default, which is `nil` for a field `defstruct` gives
      no value.

  Any other field is required. A tuple layout reads every element, so every
  field is required there.

  A default must be a value its codec encodes, so a decoded struct always
  encodes again. Heddle checks this when the codec is built, for codecs
  with no functions or references in them; a struct default is used only
  when the check passes, and a `default:` that fails it raises
  `Heddle.CodecError`.
  """
  @spec struct(module(), as: :map | :tuple, tag: atom(), fields: keyword()) :: t(struct())
  def struct(module, opts) when is_atom(module) do
    opts = opts!(opts, [as: :map, tag: nil, fields: []], "Heddle.struct/2")

    layout =
      case {opts[:as], opts[:tag]} do
        {:map, nil} -> :map
        {:tuple, tag} when is_atom(tag) -> {:tuple, tag}
        {:map, _} -> invalid!("Heddle.struct/2 option :tag applies only to as: :tuple")
        _ -> invalid!("Heddle.struct/2 option :as must be :map or :tuple")
      end

    fields =
      opts[:fields]
      |> keyed!("Heddle.struct/2 option :fields", &struct_field!/2)
      |> Enum.map(fn {name, {codec, default}} -> {name, codec, default} end)

    names = Enum.map(fields, &elem(&1, 0))

    if :__struct__ in names,
      do: invalid!("Heddle.struct/2 cannot serialize :__struct__ as a field")

    if length(Enum.uniq(names)) != length(names),
      do: invalid!("Heddle.struct/2 lists a field twice: #{inspect(names)}")

    info = IR.struct_info!(module)

    case names -- Map.keys(info) do
      [] -> :ok
      missing -> invalid!("#{inspect(module)} has no fields #{inspect(missing)}")
    end

    Enum.each(fields, &check_default!(module, &1))
    fields = if layout == :map, do: Enum.map(fields, &struct_default(info, &1)), else: fields
    %__MODULE__{node: {:struct, module, layout, fields}}
  end

  def struct(other, _), do: invalid!("Heddle.struct/2 expects a module, got #{inspect(other)}")

  defp struct_field!(name, {codec, field_opts}) when is_list(field_opts) do
    context = "Heddle.struct/2 field #{inspect(name)}"
    opts!(field_opts, [default: nil], context)

    default =
      case Keyword.fetch(field_opts, :default) do
        {:ok, value} -> {:ok, value}
        :error -> :none
      end

    {IR.codec!(codec, context), default}
  end

  defp struct_field!(name, codec),
    do: {IR.codec!(codec, "Heddle.struct/2 field #{inspect(name)}"), :none}

  # A field the struct does not enforce takes the struct's own default when
  # the input omits it, as an ordinary `{:ok, value}` default every backend
  # already handles. A default the codec cannot encode would decode to a
  # struct that does not encode again, so such a field stays required.
  defp struct_default(info, {name, codec, :none} = field) do
    %{required: required, default: default} = Map.fetch!(info, name)

    if not required and IR.closed?(codec) and conforms?(codec, default),
      do: {name, codec, {:ok, default}},
      else: field
  end

  defp struct_default(_info, field), do: field

  defp check_default!(module, {name, codec, {:ok, default}}) do
    if IR.closed?(codec) and not conforms?(codec, default) do
      raise CodecError,
        code: "H004",
        summary:
          "Heddle.struct/2 field #{inspect(name)} of #{inspect(module)} defaults to " <>
            "#{inspect(default, limit: 10, printable_limit: 64)}, which its codec cannot encode",
        labels: [{codec, "this codec rejects the default"}],
        help:
          "a decoded struct must encode again: use a default the codec accepts, or widen the codec"
    end

    :ok
  end

  defp check_default!(_module, _field), do: :ok

  ## Combinators

  @doc """
  A deterministic choice.

  Alternatives must be distinguishable by their first bytes (ETF tag or
  literal), so decoding never backtracks, and by their values, so encoding
  never tries alternatives in turn. Overlap in either raises
  `Heddle.CodecError` when the codec is built.

  Structs laid out as maps are the exception: they share a first byte, so
  a map is told apart by its `:__struct__` key, found by scanning the map's
  keys without building its values. Such structs mix with tagged tuples and
  atoms, but not with plain `map/1` or `map_of/3` alternatives.
  """
  @spec one_of([t()]) :: t()
  def one_of([_ | _] = alts) do
    alts = Enum.map(alts, &IR.codec!(&1, "Heddle.one_of/1"))
    firsts = Enum.map(alts, &IR.first/1)
    shapes = Enum.map(alts, &IR.shape/1)
    IR.check_one_of!(alts, firsts, shapes)
    %__MODULE__{node: {:one_of, alts, firsts, shapes}}
  end

  def one_of(other),
    do: invalid!("Heddle.one_of/1 expects a non-empty list of codecs, got #{inspect(other)}")

  @doc "A two-element tuple tagged by an atom: `tagged(:put, payload)` encodes `{:put, payload}`."
  @spec tagged(atom(), t()) :: t({atom(), term()})
  def tagged(tag, payload) when is_atom(tag), do: tuple([atom(tag), payload])
  def tagged(other, _), do: invalid!("Heddle.tagged/2 expects an atom tag, got #{inspect(other)}")

  @doc """
  A partial isomorphism: `decode` maps the inner codec's values, `encode`
  maps back. Both return `{:ok, value}` or `:error` and must be inverse
  wherever defined; `Heddle.Laws` checks this.
  """
  @spec iso(t(a, a), (a -> {:ok, b} | :error), (b -> {:ok, a} | :error)) :: t(b)
        when a: term(), b: term()
  def iso(codec, decode, encode) do
    codec = IR.codec!(codec, "Heddle.iso/3")
    unless fun?(decode, 1), do: invalid!("Heddle.iso/3 decode must be a function of arity 1")
    unless fun?(encode, 1), do: invalid!("Heddle.iso/3 encode must be a function of arity 1")
    %__MODULE__{node: {:iso, codec, decode, encode}}
  end

  @doc """
  Restricts a codec to values satisfying `predicate`; decoding fails with
  `{:refine, reason}` otherwise.
  """
  @spec refine(t(i, o), (o -> as_boolean(term())), term()) :: t(i, o) when i: term(), o: term()
  def refine(codec, predicate, reason) do
    codec = IR.codec!(codec, "Heddle.refine/3")

    unless fun?(predicate, 1),
      do: invalid!("Heddle.refine/3 predicate must be a function of arity 1")

    %__MODULE__{node: {:refine, codec, predicate, reason}}
  end

  @doc """
  Selects the part of a value this codec encodes (`lmap` with a partial
  getter). A getter returning `:error` makes encoding fail cleanly outside
  the codec's domain.

      Heddle.integer(min: 1) |> Heddle.from(Heddle.field(:user_id))
  """
  @spec from(t(i, o), getter()) :: t(term(), o) when i: term(), o: term()
  def from(codec, getter) do
    codec = IR.codec!(codec, "Heddle.from/2")

    unless match?(%Field{}, getter) or fun?(getter, 1),
      do: invalid!("Heddle.from/2 expects a getter: Heddle.field/1 or a function of arity 1")

    %__MODULE__{node: {:from, codec, getter}}
  end

  @doc "A getter reading `key` of a map or struct, for `from/2`."
  @spec field(term()) :: Field.t()
  def field(key), do: %Field{key: key}

  @doc "A codec built on first use, for recursion."
  @spec lazy((-> t(i, o))) :: t(i, o) when i: term(), o: term()
  def lazy(thunk) do
    unless fun?(thunk, 0), do: invalid!("Heddle.lazy/1 expects a function of arity 0")
    %__MODULE__{node: {:lazy, thunk}}
  end

  @doc """
  A sequence step whose rest depends on a decoded value.

  `continuation` receives the value `codec` decoded and returns the rest of
  the sequence. Sequences run inside `tuple_seq/2`; each continuation call
  is charged one node. `Heddle.DSL.tuple_seq/2` gives the block form.
  """
  @spec bind(t(), (term() -> t())) :: t()
  def bind(codec, continuation) do
    codec = IR.codec!(codec, "Heddle.bind/2")
    unless fun?(continuation, 1), do: invalid!("Heddle.bind/2 expects a function of arity 1")
    %__MODULE__{node: {:bind, codec, continuation}}
  end

  @doc "Ends a sequence with its result, consuming nothing."
  @spec pure(term()) :: t()
  def pure(value), do: %__MODULE__{node: {:pure, value}}

  @doc """
  A tuple read as a sequence: its elements are the sequence's steps, after a
  leading `tag:` atom if given. The tuple's arity must match the number of
  steps the sequence takes.
  """
  @spec tuple_seq(t(), tag: atom() | nil) :: t()
  def tuple_seq(seq, opts \\ []) do
    seq = IR.seq!(seq, "Heddle.tuple_seq/2")
    opts = opts!(opts, [tag: nil], "Heddle.tuple_seq/2")
    unless is_atom(opts[:tag]), do: invalid!("Heddle.tuple_seq/2 option :tag must be an atom")
    %__MODULE__{node: {:tuple_seq, opts[:tag], seq}}
  end

  ## Using codecs

  @doc """
  Decodes `binary` with `codec`.

  Options are the limits in `Heddle.Limits`. Compiled codecs run their
  generated decoder; others run the interpreter, which is the reference
  semantics.
  """
  @spec decode(t(term(), o), binary(), Limits.t() | [Limits.option()]) ::
          {:ok, o} | {:error, DecodeError.t()}
        when o: term()
  def decode(codec, binary, opts \\ [])

  def decode(%__MODULE__{node: {:ref, module, name}}, binary, opts) when is_binary(binary) do
    {max_bytes, lim} = Heddle.Runtime.compiled_limits(opts)
    Heddle.Runtime.run_compiled(binary, max_bytes, lim, module, name)
  end

  def decode(codec, binary, opts) when is_binary(binary) do
    Interpreter.decode(IR.codec!(codec, "Heddle.decode/3"), binary, opts, :compiled)
  end

  @doc "Like `decode/3`, but raises `Heddle.DecodeError`."
  @spec decode!(t(term(), o), binary(), Limits.t() | [Limits.option()]) :: o when o: term()
  def decode!(codec, binary, opts \\ []) do
    case decode(codec, binary, opts) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @doc """
  Encodes `value` with `codec`, as iodata.

  Output is deterministic for a given Heddle version and does not depend on
  the OTP version: minimal integer tags, UTF-8 atom tags, map keys sorted by
  their encoded bytes, never compressed.
  """
  @spec encode(t(i, term()), i) :: {:ok, iodata()} | {:error, EncodeError.t()} when i: term()
  def encode(%__MODULE__{node: {:ref, module, name}}, value) do
    case module.__heddle_encode__(name, value, <<131>>) do
      {:ok, _y, binary} -> {:ok, binary}
      {:error, {path, reason}} -> {:error, %EncodeError{path: path, reason: reason}}
    end
  end

  def encode(codec, value) do
    case Interpreter.encode(IR.codec!(codec, "Heddle.encode/2"), value, :compiled) do
      {:ok, _y, iodata} -> {:ok, [<<131>> | iodata]}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Like `encode/2`, but raises `Heddle.EncodeError`."
  @spec encode!(t(i, term()), i) :: iodata() when i: term()
  def encode!(codec, value) do
    case encode(codec, value) do
      {:ok, iodata} -> iodata
      {:error, error} -> raise error
    end
  end

  @doc """
  The value decoding `value`'s encoding would return, or why `value` cannot
  be encoded (`purify` in Xia et al.).

  For an aligned codec whose functions are lawful this is `{:ok, value}`.
  """
  @spec project(t(i, o), i) :: {:ok, o} | {:error, EncodeError.t()} when i: term(), o: term()
  def project(codec, value) do
    case Interpreter.encode(IR.codec!(codec, "Heddle.project/2"), value, :compiled) do
      {:ok, y, _iodata} -> {:ok, y}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Whether `value` is in the codec's encoding domain."
  @spec conforms?(t(), term()) :: boolean()
  def conforms?(codec, value), do: match?({:ok, _}, project(codec, value))

  @doc """
  The compiled codec of a module that has one: a struct with a derived
  `Heddle.Codec`, or a module using `Heddle.Schema` with `defschema` or
  `defunion`.
  """
  @spec codec_for(module()) :: t()
  def codec_for(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__heddle_summary__, 1) do
      %__MODULE__{node: {:ref, module, :codec}}
    else
      raise ArgumentError, "#{inspect(module)} has no Heddle codec"
    end
  end

  @doc """
  Reports positions the codec leaves unbounded and binds that run in the
  interpreter, as pentiment reports. See `Heddle.Lint`.
  """
  @spec lint(t()) :: [Pentiment.Report.t()]
  def lint(codec), do: Heddle.Lint.run(IR.codec!(codec, "Heddle.lint/1"))

  ## Helpers

  defp opts!(opts, defaults, context) when is_list(opts) do
    allowed = Keyword.keys(defaults)

    case Keyword.keys(opts) -- allowed do
      [] ->
        Keyword.merge(defaults, opts)

      unknown ->
        invalid!(
          "#{context} got unknown options #{inspect(unknown)}; allowed: #{inspect(allowed)}"
        )
    end
  end

  defp opts!(other, _, context),
    do: invalid!("#{context} expects a keyword list, got #{inspect(other)}")

  defp keyed!(
         pairs,
         context,
         convert \\ fn name, codec -> IR.codec!(codec, "codec for #{inspect(name)}") end
       )

  defp keyed!(pairs, context, convert) when is_list(pairs) do
    Enum.map(pairs, fn
      {name, value} when is_atom(name) -> {name, convert.(name, value)}
      other -> invalid!("#{context} expects atom keys, got #{inspect(other, limit: 5)}")
    end)
  end

  defp keyed!(other, context, _),
    do: invalid!("#{context} expects a keyword list, got #{inspect(other, limit: 5)}")

  defp bound?(nil), do: true
  defp bound?(n) when is_integer(n) and n >= 0, do: true
  defp bound?(value), do: param?(value)

  defp bound_text(context, key, opts),
    do:
      "#{context} option #{inspect(key)} must be a non-negative integer, got #{inspect(opts[key])}"

  defp param?(%Param{}), do: true
  defp param?(_), do: false

  defp fun?(%FunRef{arity: arity}, arity), do: true
  defp fun?(fun, arity), do: is_function(fun, arity)

  defp invalid!(summary) do
    raise CodecError, code: "H004", summary: summary, labels: []
  end
end

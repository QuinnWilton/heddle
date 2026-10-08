defmodule Heddle.IR do
  @moduledoc """
  The codec intermediate representation and its static summaries.

  Every codec is a `%Heddle{}` whose `node` is one of:

    * `{:literal, atom}`
    * `{:enum, [atom], :reject | :keep}`
    * `:existing_atom`
    * `{:integer, min | nil, max | nil}`
    * `:char` - a Unicode code point, for charlists
    * `:float`
    * `{:binary, max | nil, utf8? :: boolean()}`
    * `{:list, elem, max | nil}`
    * `{:tuple, [elem]}`
    * `{:map, required :: [{atom, codec}], optional :: [{atom, codec}]}`
    * `{:struct, module, layout, [field]}` where `layout` is `:map` or
      `{:tuple, tag | nil}` and each field is `{name, codec, default}` with
      `default` either `{:ok, value}` or `:none`
    * `{:map_of, key, value, max | nil}`
    * `{:one_of, [alt], firsts, shapes}` - with each alternative's FIRST set and
      shape cached, in order
    * `{:iso, codec, decode_fun, encode_fun}`
    * `{:refine, codec, predicate, reason}`
    * `{:from, codec, getter}`
    * `{:lazy, thunk}`
    * `{:ref, module, name}` - a compiled codec, linked by call
    * `{:tuple_seq, tag | nil, seq}` - a tuple read as a sequence

  and sequences, which only `{:tuple_seq, ...}` may hold:

    * `{:bind, codec, continuation}`
    * `{:pure, value}`

  Functions in the IR are plain functions at runtime. While a Heddle macro
  evaluates a codec expression at compile time they are
  `Heddle.IR.FunRef` placeholders carrying the function's source.

  ## Summaries

  Three summaries drive dispatch and the determinism checks:

    * `first/1` - what the codec's bytes can start with, over (tag class,
      literal bytes). `one_of/1` alternatives must have disjoint FIRST sets.
    * `shape/1` - which values the encoder accepts, coarsely. `one_of/1`
      alternatives must have disjoint shapes.
    * `expected/1` - what a decode error at this position reports.

  A tuple's FIRST set and shape name its first element's literal only when
  that element is syntactically a literal (through `iso/3`, `refine/3` and
  `from/2` for FIRST; through `refine/3` for shape). Both backends compute the
  same summaries from the same IR, so they dispatch identically.
  """

  alias Heddle.CodecError

  defmodule Field do
    @moduledoc "A getter that reads one key of a map or struct; see `Heddle.field/1`."
    @enforce_keys [:key]
    defstruct [:key]
    @type t :: %__MODULE__{key: term()}
  end

  defmodule FunRef do
    @moduledoc false
    # A function inside a codec expression a macro evaluates at compile time.
    # The compiler keeps the function's source under `id`; `bindings` are the
    # variables in scope where the function was created, so its source can
    # be evaluated or embedded later.
    @enforce_keys [:id, :arity]
    defstruct [:id, :arity, bindings: []]

    @type t :: %__MODULE__{
            id: pos_integer(),
            arity: non_neg_integer(),
            bindings: [{{atom(), atom()}, term()}]
          }

    @doc false
    @spec new(pos_integer(), non_neg_integer(), [{{atom(), atom()}, term()}]) :: t()
    def new(id, arity, bindings), do: %__MODULE__{id: id, arity: arity, bindings: bindings}
  end

  defmodule Param do
    @moduledoc false
    # A value decoded earlier in a sequence, standing in a codec parameter (a
    # size or a range bound) while the compiler compiles a dependent bind.
    # `index` is its position in the parameter tuple compiled code passes.
    @enforce_keys [:index]
    defstruct [:index]
    @type t :: %__MODULE__{index: non_neg_integer()}
  end

  @type first_item ::
          {:atom, atom()}
          | :any_atom
          | :integer
          | :float
          | :binary
          | :list
          | :map
          | {:tuple, non_neg_integer() | :any, atom() | :any}

  @type shape_item ::
          {:atom, atom()}
          | :any_atom
          | {:integer, integer() | nil, integer() | nil}
          | :float
          | :binary
          | :list
          | :map
          | {:struct, module()}
          | {:tuple, non_neg_integer(), atom() | :any}
          | :any

  @type summary :: %{first: [first_item()], shape: [shape_item()], expected: [term()]}

  @max_summary_depth 64

  ## Normalization

  @doc """
  Turns a codec argument into a codec.

  A `%Heddle{}` is returned as is. A module name stands for that module's
  struct codec, linked by call. Anything else raises `Heddle.CodecError`.
  """
  @spec codec!(term(), String.t()) :: Heddle.t()
  def codec!(%Heddle{node: node} = codec, context) do
    if sequence_node?(node) do
      raise CodecError,
        code: "H009",
        summary: "#{context} expects a codec, got a sequence",
        labels: [{codec, "a sequence built with bind/2 or pure/1"}],
        help: "wrap the sequence with Heddle.tuple_seq/2"
    end

    codec
  end

  def codec!(module, context) when is_atom(module) and module not in [nil, true, false] do
    if module_name?(module) do
      %Heddle{node: {:ref, module, :codec}}
    else
      bad_codec!(module, context)
    end
  end

  def codec!(other, context), do: bad_codec!(other, context)

  @doc "Turns a sequence argument into a sequence, raising `Heddle.CodecError` otherwise."
  @spec seq!(term(), String.t()) :: Heddle.t()
  def seq!(%Heddle{node: node} = seq, context) do
    if sequence_node?(node) do
      seq
    else
      raise CodecError,
        code: "H009",
        summary: "#{context} expects a sequence, got a codec",
        labels: [{seq, "a codec, which reads one term"}],
        help: "end a sequence with Heddle.pure/1 and chain its steps with Heddle.bind/2"
    end
  end

  def seq!(other, context) do
    raise CodecError,
      code: "H009",
      summary: "#{context} expects a sequence, got #{inspect(other, limit: 5)}",
      labels: []
  end

  defp bad_codec!(other, context) do
    raise CodecError,
      code: "H004",
      summary: "#{context} expects a codec, got #{inspect(other, limit: 5)}",
      labels: [],
      help: "build codecs with Heddle's constructors, or name a module that has a Heddle codec"
  end

  @doc false
  @spec module_name?(atom()) :: boolean()
  def module_name?(atom), do: String.starts_with?(Atom.to_string(atom), "Elixir.")

  @doc false
  @spec sequence_node?(term()) :: boolean()
  def sequence_node?({:bind, _, _}), do: true
  def sequence_node?({:pure, _}), do: true
  def sequence_node?(_), do: false

  ## Forcing and references

  @doc false
  @spec force(Heddle.t()) :: Heddle.t()
  def force(%Heddle{node: {:lazy, thunk}} = lazy) do
    result =
      case thunk do
        %FunRef{} = ref -> compile_time_eval!(ref)
        fun when is_function(fun, 0) -> fun.()
      end

    codec!(result, "the function given to Heddle.lazy/1 (at #{span_text(lazy)})")
  end

  @doc false
  @spec compile_time_eval!(FunRef.t(), [term()]) :: term()
  def compile_time_eval!(%FunRef{} = ref, args \\ []) do
    case Process.get(:heddle_funref_eval) do
      nil ->
        raise CodecError,
          code: "H010",
          summary: "a function inside a compiled codec was called outside its compiler",
          labels: []

      eval ->
        eval.(ref, args)
    end
  end

  @doc false
  @spec summary_of_ref(module(), atom()) :: summary()
  def summary_of_ref(module, name) do
    case Process.get({:heddle_local_summaries, module}) do
      %{^name => :pending} ->
        raise CodecError,
          code: "H007",
          summary: "#{inspect(module)}.#{name} is used in a choice before it is defined",
          labels: [],
          help:
            "a codec cannot start with itself (left recursion); put a literal tag in front, " <>
              "or define the codec it refers to first"

      %{^name => summary} ->
        summary

      _ ->
        remote_summary(module, name)
    end
  end

  # Waits for a module still compiling: a summary is needed now.
  defp remote_summary(module, name) do
    if match?({:module, _}, Code.ensure_compiled(module)) and
         function_exported?(module, :__heddle_summary__, 1) do
      module.__heddle_summary__(name)
    else
      raise CodecError,
        code: "H006",
        summary: "#{inspect(module)} has no Heddle codec named #{inspect(name)}",
        labels: [],
        help:
          "define it with defcodec, defschema or defunion, or derive Heddle.Codec for the struct"
    end
  end

  @doc false
  @spec ir_of_ref(module(), atom()) :: Heddle.t()
  def ir_of_ref(module, name) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__heddle_ir__, 1) do
      module.__heddle_ir__(name)
    else
      raise CodecError,
        code: "H006",
        summary: "#{inspect(module)} has no Heddle codec named #{inspect(name)}",
        labels: []
    end
  end

  ## Summaries

  @doc "The codec's FIRST set."
  @spec first(Heddle.t()) :: [first_item()]
  def first(%Heddle{} = codec), do: guarded(fn -> do_first(codec) end)

  defp do_first(%Heddle{node: {:literal, a}}), do: [{:atom, a}]

  defp do_first(%Heddle{node: {:enum, atoms, :reject}}), do: Enum.map(atoms, &{:atom, &1})

  defp do_first(%Heddle{node: {:enum, _, :keep}}), do: [:any_atom]

  defp do_first(%Heddle{node: :existing_atom}), do: [:any_atom]

  defp do_first(%Heddle{node: {:integer, _, _}}), do: [:integer]

  defp do_first(%Heddle{node: :char}), do: [:integer]

  defp do_first(%Heddle{node: :float}), do: [:float]

  defp do_first(%Heddle{node: {:binary, _, _}}), do: [:binary]

  defp do_first(%Heddle{node: {:list, _, _}}), do: [:list]

  defp do_first(%Heddle{node: {:tuple, elems}}),
    do: [{:tuple, length(elems), first_literal(List.first(elems))}]

  defp do_first(%Heddle{node: {:map, _, _}}), do: [:map]

  defp do_first(%Heddle{node: {:map_of, _, _, _}}), do: [:map]

  defp do_first(%Heddle{node: {:struct, _, :map, _}}), do: [:map]

  defp do_first(%Heddle{node: {:struct, _, {:tuple, tag}, fields}}),
    do: [struct_tuple_first(tag, fields)]

  defp do_first(%Heddle{node: {:one_of, _, firsts, _}}), do: Enum.concat(firsts)

  defp do_first(%Heddle{node: {:iso, inner, _, _}}), do: do_first(inner)

  defp do_first(%Heddle{node: {:refine, inner, _, _}}), do: do_first(inner)

  defp do_first(%Heddle{node: {:from, inner, _}}), do: do_first(inner)

  defp do_first(%Heddle{node: {:lazy, _}} = codec), do: do_first(force(codec))

  defp do_first(%Heddle{node: {:ref, module, name}}), do: summary_of_ref(module, name).first

  defp do_first(%Heddle{node: {:tuple_seq, tag, seq}}),
    do: [{:tuple, :any, tag || seq_first_literal(seq)}]

  defp struct_tuple_first(nil, [{_, codec, _} | _] = fields),
    do: {:tuple, length(fields), first_literal(codec)}

  defp struct_tuple_first(nil, []), do: {:tuple, 0, :any}
  defp struct_tuple_first(tag, fields), do: {:tuple, length(fields) + 1, tag}

  defp seq_first_literal(%Heddle{node: {:bind, codec, _}}), do: first_literal(codec)
  defp seq_first_literal(_), do: :any

  @doc false
  @spec first_literal(Heddle.t() | nil) :: atom()
  def first_literal(nil), do: :any

  def first_literal(%Heddle{node: node}) do
    case node do
      {:literal, a} -> a
      {:iso, inner, _, _} -> first_literal(inner)
      {:refine, inner, _, _} -> first_literal(inner)
      {:from, inner, _} -> first_literal(inner)
      _ -> :any
    end
  end

  @doc "The codec's value shape."
  @spec shape(Heddle.t()) :: [shape_item()]
  def shape(%Heddle{} = codec), do: guarded(fn -> do_shape(codec) end)

  defp do_shape(%Heddle{node: {:literal, a}}), do: [{:atom, a}]

  defp do_shape(%Heddle{node: {:enum, atoms, :reject}}), do: Enum.map(atoms, &{:atom, &1})

  defp do_shape(%Heddle{node: {:enum, atoms, :keep}}),
    do: Enum.map(atoms, &{:atom, &1}) ++ [{:tuple, 2, :unknown}]

  defp do_shape(%Heddle{node: :existing_atom}), do: [:any_atom]

  defp do_shape(%Heddle{node: {:integer, min, max}}), do: [{:integer, min, max}]

  defp do_shape(%Heddle{node: :char}), do: [{:integer, 0, 0x10FFFF}]

  defp do_shape(%Heddle{node: :float}), do: [:float]

  defp do_shape(%Heddle{node: {:binary, _, _}}), do: [:binary]

  defp do_shape(%Heddle{node: {:list, _, _}}), do: [:list]

  defp do_shape(%Heddle{node: {:tuple, elems}}),
    do: [{:tuple, length(elems), shape_literal(List.first(elems))}]

  defp do_shape(%Heddle{node: {:map, _, _}}), do: [:map]

  defp do_shape(%Heddle{node: {:map_of, _, _, _}}), do: [:map]

  defp do_shape(%Heddle{node: {:struct, module, _, _}}), do: [{:struct, module}]

  defp do_shape(%Heddle{node: {:one_of, _, _, shapes}}), do: Enum.concat(shapes)

  defp do_shape(%Heddle{node: {:refine, inner, _, _}}), do: do_shape(inner)

  defp do_shape(%Heddle{node: {:iso, _, _, _}}), do: [:any]

  defp do_shape(%Heddle{node: {:from, _, _}}), do: [:any]

  defp do_shape(%Heddle{node: {:tuple_seq, _, _}}), do: [:any]

  defp do_shape(%Heddle{node: {:lazy, _}} = codec), do: do_shape(force(codec))

  defp do_shape(%Heddle{node: {:ref, module, name}}), do: summary_of_ref(module, name).shape

  defp shape_literal(nil), do: :any

  defp shape_literal(%Heddle{node: node}) do
    case node do
      {:literal, a} -> a
      {:refine, inner, _, _} -> shape_literal(inner)
      _ -> :any
    end
  end

  @doc "What a decode error at this codec's position reports as expected."
  @spec expected(Heddle.t()) :: [term()]
  def expected(%Heddle{} = codec), do: guarded(fn -> do_expected(codec) end)

  defp do_expected(%Heddle{node: {:literal, a}}), do: [{:atom, a}]

  defp do_expected(%Heddle{node: {:enum, atoms, :reject}}), do: Enum.map(atoms, &{:atom, &1})

  defp do_expected(%Heddle{node: {:enum, atoms, :keep}}),
    do: Enum.map(atoms, &{:atom, &1}) ++ [:atom]

  defp do_expected(%Heddle{node: :existing_atom}), do: [:atom]

  defp do_expected(%Heddle{node: {:integer, min, max}}), do: [{:integer, min, max}]

  defp do_expected(%Heddle{node: :char}), do: [:char]

  defp do_expected(%Heddle{node: :float}), do: [:float]

  defp do_expected(%Heddle{node: {:binary, max, false}}), do: [{:binary, max}]

  defp do_expected(%Heddle{node: {:binary, max, true}}), do: [{:utf8, max}]

  defp do_expected(%Heddle{node: {:list, _, max}}), do: [{:list, max}]

  defp do_expected(%Heddle{node: {:tuple, elems}}),
    do: [tuple_expected(length(elems), first_literal(List.first(elems)))]

  defp do_expected(%Heddle{node: {:map, _, _}}), do: [:map]

  defp do_expected(%Heddle{node: {:map_of, _, _, max}}), do: [{:map, max}]

  defp do_expected(%Heddle{node: {:struct, module, _, _}}), do: [{:struct, module}]

  defp do_expected(%Heddle{node: {:one_of, alts, _, _}}), do: Enum.flat_map(alts, &do_expected/1)

  defp do_expected(%Heddle{node: {:iso, inner, _, _}}), do: do_expected(inner)

  defp do_expected(%Heddle{node: {:refine, inner, _, _}}), do: do_expected(inner)

  defp do_expected(%Heddle{node: {:from, inner, _}}), do: do_expected(inner)

  defp do_expected(%Heddle{node: {:lazy, _}} = codec), do: do_expected(force(codec))

  defp do_expected(%Heddle{node: {:ref, module, name}}), do: summary_of_ref(module, name).expected

  defp do_expected(%Heddle{node: {:tuple_seq, tag, _}}), do: [{:tuple, tag}]

  defp tuple_expected(n, :any), do: {:tuple, n}
  defp tuple_expected(n, tag), do: {:tuple, n, tag}

  @doc "All three summaries."
  @spec summary(Heddle.t()) :: summary()
  def summary(codec), do: %{first: first(codec), shape: shape(codec), expected: expected(codec)}

  defp guarded(fun) do
    depth = Process.get(:heddle_summary_depth, 0)

    if depth >= @max_summary_depth do
      raise CodecError,
        code: "H007",
        summary: "a codec's first term is itself (left recursion)",
        labels: [],
        help: "put a literal tag in front of the recursive alternative"
    end

    Process.put(:heddle_summary_depth, depth + 1)

    try do
      fun.()
    after
      if depth == 0,
        do: Process.delete(:heddle_summary_depth),
        else: Process.put(:heddle_summary_depth, depth)
    end
  end

  ## Overlap and matching

  @doc false
  @spec first_overlap?(first_item(), first_item()) :: boolean()
  def first_overlap?({:atom, a}, {:atom, b}), do: a == b
  def first_overlap?(:any_atom, {:atom, _}), do: true
  def first_overlap?({:atom, _}, :any_atom), do: true
  def first_overlap?(:any_atom, :any_atom), do: true

  def first_overlap?({:tuple, n1, t1}, {:tuple, n2, t2}),
    do: wild_eq?(n1, n2) and wild_eq?(t1, t2)

  def first_overlap?(a, b), do: a == b

  @doc false
  @spec shape_overlap?(shape_item(), shape_item()) :: boolean()
  def shape_overlap?(:any, _), do: true
  def shape_overlap?(_, :any), do: true

  def shape_overlap?({:integer, lo1, hi1}, {:integer, lo2, hi2}),
    do: not (below?(hi1, lo2) or below?(hi2, lo1))

  def shape_overlap?({:struct, a}, {:struct, b}), do: a == b

  def shape_overlap?({:tuple, n1, t1}, {:tuple, n2, t2}),
    do: n1 == n2 and wild_eq?(t1, t2)

  def shape_overlap?(a, b) when a in [:any_atom] or b in [:any_atom],
    do: match?({:atom, _}, a) or match?({:atom, _}, b) or a == b

  def shape_overlap?(a, b), do: a == b

  defp below?(nil, _), do: false
  defp below?(_, nil), do: false
  defp below?(hi, lo), do: hi < lo

  defp wild_eq?(:any, _), do: true
  defp wild_eq?(_, :any), do: true
  defp wild_eq?(a, b), do: a == b

  @doc false
  @spec first_matches?(first_item(), Heddle.ETF.class()) :: boolean()
  def first_matches?({:atom, a}, {:atom, name}), do: is_binary(name) and Atom.to_string(a) == name
  def first_matches?(:any_atom, {:atom, _}), do: true

  def first_matches?({:tuple, n, t}, {:tuple, arity, name}) do
    (n == :any or n == arity) and
      (t == :any or (is_binary(name) and Atom.to_string(t) == name))
  end

  def first_matches?(class, class) when is_atom(class), do: true
  def first_matches?(_, _), do: false

  @doc false
  @spec shape_matches?(shape_item(), term()) :: boolean()
  def shape_matches?(:any, _), do: true
  def shape_matches?({:atom, a}, v), do: v === a
  def shape_matches?(:any_atom, v), do: is_atom(v)

  def shape_matches?({:integer, lo, hi}, v),
    do: is_integer(v) and (lo == nil or v >= lo) and (hi == nil or v <= hi)

  def shape_matches?(:float, v), do: is_float(v)
  def shape_matches?(:binary, v), do: is_binary(v)
  def shape_matches?(:list, v), do: is_list(v)
  def shape_matches?(:map, v), do: is_map(v) and not is_map_key(v, :__struct__)
  def shape_matches?({:struct, module}, v), do: is_struct(v, module)

  def shape_matches?({:tuple, n, t}, v),
    do: is_tuple(v) and tuple_size(v) == n and (t == :any or (n > 0 and elem(v, 0) === t))

  @doc false
  @spec choose([[item]], (item -> boolean())) :: non_neg_integer() | nil when item: term()
  def choose(item_lists, matches?) do
    Enum.find_index(item_lists, fn items -> Enum.any?(items, matches?) end)
  end

  ## Static checks

  @doc false
  @spec check_one_of!([Heddle.t()], [[first_item()]], [[shape_item()]]) :: :ok
  def check_one_of!(alts, firsts, shapes) do
    indexed = Enum.with_index(Enum.zip([alts, firsts, shapes]))

    for {{a, fa, sa}, i} <- indexed, {{b, fb, sb}, j} <- indexed, i < j do
      check_pair!(a, b, fa, fb, &first_overlap?/2, "H001", "decode")
      check_pair!(a, b, sa, sb, &shape_overlap?/2, "H002", "encode")
    end

    :ok
  end

  defp check_pair!(a, b, items_a, items_b, overlap?, code, direction) do
    pairs = for x <- items_a, y <- items_b, overlap?.(x, y), do: {x, y}

    case pairs do
      [] ->
        :ok

      [{_x, y} | _] ->
        {what, help} = overlap_text(direction)

        raise CodecError,
          code: code,
          summary: "one_of alternatives overlap: #{what}",
          labels: [
            {b, "this alternative #{describe_item(direction, y)}"},
            {a,
             if(direction == "decode",
               do: "so can this earlier one",
               else: "so does this earlier one"
             )}
          ],
          help: help
    end
  end

  defp overlap_text("decode") do
    {"the decoder cannot tell them apart by their first bytes",
     "give each alternative a distinct tag (an atom literal or a tagged tuple), " <>
       "or a different term type"}
  end

  defp overlap_text("encode") do
    {"the encoder cannot tell their values apart",
     "make the alternatives' values distinguishable: different literals, tuple tags, " <>
       "types or integer ranges"}
  end

  defp describe_item("decode", item), do: "can start with #{inspect_item(item)}"
  defp describe_item("encode", item), do: "accepts #{inspect_item(item)}"

  defp inspect_item({:atom, a}), do: "the atom #{inspect(a)}"
  defp inspect_item(:any_atom), do: "any atom"
  defp inspect_item(:any), do: "any value"
  defp inspect_item({:integer, nil, nil}), do: "any integer"
  defp inspect_item({:integer, lo, hi}), do: "integers in #{bound(lo)}..#{bound(hi)}"
  defp inspect_item({:struct, m}), do: "%#{inspect(m)}{}"
  defp inspect_item({:tuple, n, :any}), do: "tuples of arity #{arity(n)}"
  defp inspect_item({:tuple, n, t}), do: "tuples of arity #{arity(n)} tagged #{inspect(t)}"
  defp inspect_item(:integer), do: "an integer"
  defp inspect_item(class), do: "a #{class}"

  defp bound(nil), do: "∞"
  defp bound(n), do: Integer.to_string(n)
  defp arity(:any), do: "any"
  defp arity(n), do: Integer.to_string(n)

  @doc false
  @spec check_struct_key_free!(Heddle.t(), String.t()) :: :ok
  def check_struct_key_free!(key_codec, context) do
    if {:atom, :__struct__} in shape(key_codec) do
      raise CodecError,
        code: "H003",
        summary: "#{context} cannot decode a :__struct__ key",
        labels: [{key_codec, "this key codec accepts :__struct__"}],
        help: "a decoded map has a :__struct__ key only through Heddle.struct/2"
    end

    :ok
  end

  @doc false
  @spec __at__(term(), term()) :: term()
  def __at__(%Heddle{span: nil} = codec, span), do: %{codec | span: span}
  def __at__(other, _span), do: other

  @doc false
  @spec span_text(Heddle.t()) :: String.t()
  def span_text(%Heddle{span: {file, %{start_line: line}}}),
    do: "#{Path.relative_to_cwd(file)}:#{line}"

  def span_text(_), do: "runtime"
end

defmodule Heddle.DSL do
  @moduledoc """
  Heddle's constructors and combinators, ready to import.

      import Heddle.DSL

      list(enum([:admin, :editor, :viewer]), max: 16)

  `use Heddle.Schema` imports this module, so codecs in `defcodec`,
  `defschema` and `defunion` need no `Heddle.` prefix. Elsewhere, such as
  in `@derive` options or codecs built at runtime, import it yourself.

  Each function delegates to the `Heddle` function of the same name, and
  the compiler treats both spellings the same way. One constructor is left
  out: `Heddle.struct/2` shares its name and arity with `Kernel.struct/2`,
  so it stays qualified.

  ## Sequences

  The module also gives the block form of sequences, after Xia et al.:

      tuple_seq tag: :envelope do
        version <- integer(min: 1, max: 2) <~ field(:version)
        body <- (case version do
                   1 -> binary(max_size: 1024)
                   2 -> MyApp.Shape.codec()
                 end) <~ field(:body)
        pure %{version: version, body: body}
      end

  - Each `var <- codec` step decodes one tuple element. It binds the value
    for the steps after it.
  - `pure expr` ends the block with the sequence's result.
  - `codec <~ getter` is infix `from/2`. It names the part of the encoded
    value the step writes.

  The block desugars to `Heddle.tuple_seq/2` over `bind/2` and `pure/1`.
  Inside `defcodec`, the compiler classifies each step by how it uses
  earlier values. Elsewhere, the block builds a codec the interpreter runs.
  """

  alias Heddle.IR.Field

  @typep t :: Heddle.t()
  @typep t(i, o) :: Heddle.t(i, o)
  @typep t(a) :: Heddle.t(a)

  @spec atom(atom()) :: t(atom())
  defdelegate atom(atom), to: Heddle

  @spec enum([atom()], unknown: :reject | :keep) :: t(atom() | {:unknown, String.t()})
  defdelegate enum(atoms, opts \\ []), to: Heddle

  @spec existing_atom() :: t(atom())
  defdelegate existing_atom, to: Heddle

  @spec boolean() :: t(boolean())
  defdelegate boolean, to: Heddle

  @spec null() :: t(nil)
  defdelegate null, to: Heddle

  @spec integer(min: integer() | nil, max: integer() | nil) :: t(integer())
  defdelegate integer(opts \\ []), to: Heddle

  @spec float() :: t(float())
  defdelegate float, to: Heddle

  @spec binary(max_size: Heddle.bound(), utf8: boolean()) :: t(binary())
  defdelegate binary(opts \\ []), to: Heddle

  @spec list(t(i, o), max: Heddle.bound()) :: t([i], [o]) when i: term(), o: term()
  defdelegate list(elem, opts \\ []), to: Heddle

  @spec charlist(max: Heddle.bound()) :: t(charlist())
  defdelegate charlist(opts \\ []), to: Heddle

  @spec tuple([t()]) :: t(tuple())
  defdelegate tuple(elems), to: Heddle

  @spec map(required: keyword(t()), optional: keyword(t())) :: t(map())
  defdelegate map(opts), to: Heddle

  @spec map_of(t(k, k), t(v, v), max: Heddle.bound()) :: t(%{optional(k) => v})
        when k: term(), v: term()
  defdelegate map_of(key, value, opts \\ []), to: Heddle

  @spec one_of([t()]) :: t()
  defdelegate one_of(alts), to: Heddle

  @spec tagged(atom(), t()) :: t({atom(), term()})
  defdelegate tagged(tag, payload), to: Heddle

  @spec iso(t(a, a), (a -> {:ok, b} | :error), (b -> {:ok, a} | :error)) :: t(b, b)
        when a: term(), b: term()
  defdelegate iso(codec, decode, encode), to: Heddle

  @spec refine(t(i, o), (o -> as_boolean(term())), term()) :: t(i, o) when i: term(), o: term()
  defdelegate refine(codec, predicate, reason), to: Heddle

  @spec from(t(i, o), Heddle.getter()) :: t(term(), o) when i: term(), o: term()
  defdelegate from(codec, getter), to: Heddle

  @spec field(term()) :: Field.t()
  defdelegate field(key), to: Heddle

  @spec lazy((-> t(i, o))) :: t(i, o) when i: term(), o: term()
  defdelegate lazy(thunk), to: Heddle

  @spec bind(t(), (term() -> t())) :: t()
  defdelegate bind(codec, continuation), to: Heddle

  @spec pure(term()) :: t()
  defdelegate pure(value), to: Heddle

  @doc "A tuple read as a sequence of steps; see the module documentation."
  defmacro tuple_seq(opts \\ [], do: block) do
    seq = desugar(block_lines(block), __CALLER__)
    quote(do: Heddle.tuple_seq(unquote(seq), unquote(opts)))
  end

  @doc "Infix `from/2`."
  defmacro codec <~ getter do
    quote(do: Heddle.from(unquote(codec), unquote(getter)))
  end

  defp block_lines({:__block__, _, lines}), do: lines
  defp block_lines(line), do: [line]

  defp desugar([{:pure, _, [expr]}], _env), do: quote(do: Heddle.pure(unquote(expr)))

  defp desugar([{:<-, meta, [pattern, codec]} | rest], env) when rest != [] do
    continuation = {:fn, meta, [{:->, meta, [[pattern], desugar(rest, env)]}]}
    {{:., meta, [Heddle, :bind]}, meta, [codec, continuation]}
  end

  defp desugar([line | _], env) do
    {_, meta, _} = if is_tuple(line) and tuple_size(line) == 3, do: line, else: {nil, [], nil}

    raise CompileError,
      file: env.file,
      line: Keyword.get(meta, :line, env.line),
      description:
        "a tuple_seq block is a list of `var <- codec` steps ending in `pure expr`; got: " <>
          Macro.to_string(line)
  end

  defp desugar([], env) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description: "a tuple_seq block must end in `pure expr`"
  end
end

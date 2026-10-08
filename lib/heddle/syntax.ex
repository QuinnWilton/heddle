defmodule Heddle.Syntax do
  @moduledoc """
  The block form of sequences, after Xia et al.

      import Heddle.Syntax

      tuple_seq tag: :envelope do
        version <- Heddle.integer(min: 1, max: 2) <~ field(:version)
        body <- (case version do
                   1 -> Heddle.binary(max_size: 1024)
                   2 -> MyApp.Shape.codec()
                 end) <~ field(:body)
        pure %{version: version, body: body}
      end

  Each `var <- codec` step decodes one tuple element and binds its value for
  the steps after it; `pure expr` ends the block with the sequence's result.
  `codec <~ getter` is infix `Heddle.from/2`: it names the part of the
  encoded value this step writes.

  The block desugars to `Heddle.tuple_seq/2` over `Heddle.bind/2` and
  `Heddle.pure/1`. Inside `defcodec` (see `Heddle.Schema`), the compiler
  classifies each step by how it uses earlier values; elsewhere the block
  builds a codec the interpreter runs.
  """

  @doc "A tuple read as a sequence of steps; see the module documentation."
  defmacro tuple_seq(opts \\ [], do: block) do
    seq = desugar(block_lines(block), __CALLER__)
    quote(do: Heddle.tuple_seq(unquote(seq), unquote(opts)))
  end

  @doc "Infix `Heddle.from/2`."
  defmacro codec <~ getter do
    quote(do: Heddle.from(unquote(codec), unquote(getter)))
  end

  @doc "A getter for `key`; see `Heddle.field/1`."
  @spec field(term()) :: Heddle.IR.Field.t()
  def field(key), do: Heddle.field(key)

  @doc "Ends a sequence with `value`; see `Heddle.pure/1`."
  @spec pure(term()) :: Heddle.t()
  def pure(value), do: Heddle.pure(value)

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

defmodule Heddle.Test.CodecGen do
  @moduledoc false
  # Random codec expressions, as AST. Evaluating one gives a runtime codec;
  # wrapping one in `defcodec` gives the compiled codec for the same
  # expression. Choices are built so alternatives never overlap: each
  # `one_of` takes at most one alternative per kind, with distinct literals.

  use ExUnitProperties

  alias Heddle.Test.Fns

  @atoms [:a, :b, :c, :ok, :error, :nil_like, :"with space", :é, :日本]

  def codec_ast, do: codec_ast(3)

  def codec_ast(0), do: g_leaf()

  def codec_ast(depth) do
    StreamData.frequency([
      {4, g_leaf()},
      {2, g_list(depth)},
      {2, g_tuple(depth)},
      {2, g_map(depth)},
      {1, g_map_of(depth)},
      {2, g_one_of(depth)},
      {1, g_struct(depth)},
      {1, g_iso(depth)},
      {1, g_refine()},
      {1, g_seq()}
    ])
  end

  defp g_leaf do
    StreamData.one_of([
      StreamData.member_of(@atoms) |> StreamData.map(&quote(do: Heddle.atom(unquote(&1)))),
      g_enum(),
      StreamData.constant(quote(do: Heddle.existing_atom())),
      StreamData.constant(quote(do: Heddle.boolean())),
      StreamData.constant(quote(do: Heddle.null())),
      g_integer(),
      StreamData.constant(quote(do: Heddle.float())),
      g_binary(),
      StreamData.member_of([nil, 0, 3, 40])
      |> StreamData.map(&quote(do: Heddle.charlist(max: unquote(&1))))
    ])
  end

  defp g_enum do
    gen all atoms <-
              uniq(StreamData.member_of(@atoms), 4),
            unknown <- StreamData.member_of([:reject, :keep]) do
      quote(do: Heddle.enum(unquote(atoms), unknown: unquote(unknown)))
    end
  end

  defp g_integer do
    StreamData.member_of([
      quote(do: Heddle.integer()),
      quote(do: Heddle.integer(min: 0, max: 255)),
      quote(do: Heddle.integer(min: -5, max: 5)),
      quote(do: Heddle.integer(min: 0)),
      quote(do: Heddle.integer(max: 1_000_000_000_000)),
      quote(do: Heddle.integer(min: -(2 ** 70), max: 2 ** 70))
    ])
  end

  defp g_binary do
    gen all max <- StreamData.member_of([nil, 0, 4, 64]),
            utf8 <- StreamData.boolean() do
      quote(do: Heddle.binary(max_size: unquote(max), utf8: unquote(utf8)))
    end
  end

  defp g_list(depth) do
    gen all elem <- codec_ast(depth - 1),
            max <- StreamData.member_of([nil, 0, 2, 50]) do
      quote(do: Heddle.list(unquote(elem), max: unquote(max)))
    end
  end

  defp g_tuple(depth) do
    gen all elems <- StreamData.list_of(codec_ast(depth - 1), max_length: 3) do
      quote(do: Heddle.tuple(unquote(elems)))
    end
  end

  defp g_map(depth) do
    gen all keys <-
              uniq(StreamData.member_of([:k1, :k2, :k3, :"k é"]), 3, 0),
            codecs <- StreamData.list_of(codec_ast(depth - 1), length: length(keys)),
            kinds <- StreamData.list_of(StreamData.boolean(), length: length(keys)) do
      pairs = Enum.zip([keys, codecs, kinds])
      required = for {k, c, true} <- pairs, do: {k, c}
      optional = for {k, c, false} <- pairs, do: {k, c}
      quote(do: Heddle.map(required: unquote(required), optional: unquote(optional)))
    end
  end

  defp g_map_of(depth) do
    gen all key <-
              StreamData.member_of([
                quote(do: Heddle.integer(min: 0, max: 100)),
                quote(do: Heddle.binary(max_size: 8)),
                quote(do: Heddle.enum([:a, :b], unknown: :keep)),
                quote(do: Heddle.existing_atom())
              ]),
            value <- codec_ast(depth - 1),
            max <- StreamData.member_of([nil, 0, 4]) do
      quote(do: Heddle.map_of(unquote(key), unquote(value), max: unquote(max)))
    end
  end

  # One alternative per kind, so FIRST sets and shapes stay disjoint.
  defp g_one_of(depth) do
    sub = codec_ast(depth - 1)

    kinds = [
      atom_a: StreamData.constant(quote(do: Heddle.atom(:alt_a))),
      atom_b: StreamData.constant(quote(do: Heddle.null())),
      integer: g_integer(),
      float: StreamData.constant(quote(do: Heddle.float())),
      binary: g_binary(),
      list: StreamData.map(sub, &quote(do: Heddle.list(unquote(&1), max: 4))),
      put: StreamData.map(sub, &quote(do: Heddle.tagged(:put, unquote(&1)))),
      del:
        StreamData.map(
          sub,
          &quote(do: Heddle.tuple([Heddle.atom(:del), unquote(&1), Heddle.integer()]))
        ),
      map: StreamData.map(sub, &quote(do: Heddle.map(required: [v: unquote(&1)])))
    ]

    gen all picked <-
              uniq(StreamData.member_of(Keyword.keys(kinds)), 4),
            alts <- picked |> Enum.map(&Keyword.fetch!(kinds, &1)) |> StreamData.fixed_list() do
      quote(do: Heddle.one_of(unquote(alts)))
    end
  end

  defp g_struct(depth) do
    gen all layout <- StreamData.member_of([:map, :tuple, :tagged]),
            x <- codec_ast(depth - 1),
            default <- StreamData.boolean() do
      label =
        if default,
          do: quote(do: {Heddle.binary(max_size: 8), default: "none"}),
          else: quote(do: Heddle.binary(max_size: 8))

      fields = [x: x, label: label]

      case layout do
        :map ->
          quote(do: Heddle.struct(Heddle.Test.Point, fields: unquote(fields)))

        :tuple ->
          quote(do: Heddle.struct(Heddle.Test.Point, as: :tuple, fields: unquote(fields)))

        :tagged ->
          quote(
            do: Heddle.struct(Heddle.Test.Point, as: :tuple, tag: :point, fields: unquote(fields))
          )
      end
    end
  end

  defp g_iso(depth) do
    StreamData.map(codec_ast(depth - 1), fn inner ->
      quote(do: Heddle.iso(unquote(inner), &Fns.wrap/1, &Fns.unwrap/1))
    end)
  end

  defp g_refine do
    StreamData.member_of([
      quote(do: Heddle.refine(Heddle.integer(min: -100, max: 100), &Fns.even?/1, :even)),
      quote(do: Heddle.refine(Heddle.binary(max_size: 8), &Fns.short?/1, :short))
    ])
  end

  defp g_seq do
    StreamData.member_of([
      quote do
        Heddle.tuple_seq(
          Heddle.bind(Heddle.from(Heddle.integer(min: 0, max: 3), Heddle.field(:n)), fn n ->
            Heddle.bind(
              Heddle.from(Heddle.list(Heddle.integer(), max: n), Heddle.field(:items)),
              fn items ->
                Heddle.pure(%{n: n, items: items})
              end
            )
          end),
          tag: :seq
        )
      end,
      quote do
        Heddle.tuple_seq(
          Heddle.bind(Heddle.from(Heddle.enum([:int, :bin]), Heddle.field(:kind)), fn
            :int ->
              Heddle.bind(
                Heddle.from(Heddle.integer(), Heddle.field(:v)),
                &Heddle.pure(%{kind: :int, v: &1})
              )

            :bin ->
              Heddle.bind(
                Heddle.from(Heddle.binary(max_size: 9), Heddle.field(:v)),
                &Heddle.pure(%{kind: :bin, v: &1})
              )
          end)
        )
      end
    ])
  end

  # Distinct elements without uniq_list_of, which gives up on small spaces.
  defp uniq(gen, max, min \\ 1) do
    gen
    |> StreamData.list_of(min_length: min, max_length: max)
    |> StreamData.map(&Enum.uniq/1)
  end

  @doc "A generator of `{ast, codec}` pairs."
  def codec(depth \\ 3) do
    StreamData.map(codec_ast(depth), fn ast -> {ast, eval(ast)} end)
  end

  def eval(ast) do
    {codec, _} = Code.eval_quoted(ast)
    codec
  end
end

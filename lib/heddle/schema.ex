defmodule Heddle.Schema do
  @moduledoc """
  Compiled codecs: `defcodec`, `defschema` and `defunion`.

      defmodule MyApp.Session do
        use Heddle.Schema

        defschema as: :map do
          field :user_id, integer(min: 1)
          field :roles, list(enum([:admin, :editor, :viewer]), max: 16)
          field :meta, map_of(binary(max_size: 64), binary(max_size: 256), max: 32), default: %{}
        end
      end

  `use Heddle.Schema` imports `Heddle.DSL`, so the constructors need no
  `Heddle.` prefix.

  Heddle compiles a codec where one of these macros sees it. The macro
  evaluates the codec expression during expansion, runs the static checks on
  its IR, and generates the decoder and encoder as functions in the calling
  module. Nothing is ever compiled at runtime.

  ## What a codec expression may contain

    * literals and module attributes;
    * Heddle's constructors and combinators, imported from `Heddle.DSL` or
      qualified, and `tuple_seq` blocks;
    * local calls to codecs defined earlier in the same module with
      `defcodec` (and the codec being defined, for recursion);
    * a module name standing for that module's struct codec;
    * remote calls to other modules;
    * functions (`fn` or `&`) wherever Heddle expects one; they may call the
      module's own functions, since they run later.

  Anything else, such as a call to the module's own `def` or `defp`
  functions, cannot run while its module is still being compiled, and is a
  compile error (H005) that points at the call.

  ## Linking

  A reference to a compiled codec (a `defcodec` here or elsewhere, a schema,
  or a derived struct) becomes a call to its generated decoder, so codecs
  are linked, not inlined, and structs in different modules may refer to
  each other. When a compiled codec is a `one_of/1` alternative its summary
  is read at compile time, so its module must be compiled first.

  Remote calls in codec expressions are compile-time dependencies: changing
  a helper recompiles the codecs that call it.
  """

  alias Heddle.{CodecError, Compiler, Diagnostics, IR}
  alias Heddle.Compiler.Expr

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Heddle.Schema, only: [defcodec: 2, defschema: 1, defschema: 2, defunion: 1]
      import Heddle.DSL, warn: false
      unquote(setup())
    end
  end

  @doc false
  @spec setup() :: Macro.t()
  def setup do
    quote do
      unless Module.has_attribute?(__MODULE__, :heddle_codecs) do
        Module.register_attribute(__MODULE__, :heddle_codecs, accumulate: true)
        @before_compile Heddle.Schema
      end
    end
  end

  @doc """
  Defines a compiled codec `name/0`.

      defcodec hostname do
        binary(max_size: 253, utf8: true)
      end
  """
  defmacro defcodec(name, do: expr) when is_atom(name) do
    define(name, expr, __CALLER__)
  end

  defmacro defcodec({name, _, ctx}, do: expr) when is_atom(name) and is_atom(ctx) do
    define(name, expr, __CALLER__)
  end

  @doc """
  Defines a struct, its `t/0` type and its compiled codec `codec/0`.

      defschema as: :map do
        field :id, integer(min: 1)
        field :name, binary(max_size: 100), default: ""
      end

  Options are `as: :map` (the default) or `as: :tuple`, and `tag:` for the
  tuple layout. Each `field name, codec` is serialized; `default:` sets the
  struct's default and lets the input omit the field. In the map layout, a
  field without `default:` defaults to `nil`, so the input may omit it when
  its codec encodes `nil`.
  """
  defmacro defschema(opts \\ [], do: block) do
    fields = fields!(block, __CALLER__)

    struct_fields =
      Enum.map(fields, fn {name, _codec, default} -> {name, default_value(default)} end)

    type_fields = Enum.map(fields, fn {name, _, _} -> {name, quote(do: term())} end)

    codec_fields =
      Enum.map(fields, fn
        {name, codec, :none} ->
          {name, codec}

        {name, codec, {:ok, default}} ->
          {name, quote(do: {unquote(codec), default: unquote(default)})}
      end)

    struct_opts = Keyword.take(opts, [:as, :tag])
    record_struct_info(__CALLER__, struct_fields)

    quote do
      defstruct unquote(struct_fields)
      @type t :: %__MODULE__{unquote_splicing(type_fields)}

      Heddle.Schema.defcodec codec do
        Heddle.struct(__MODULE__, unquote(struct_opts ++ [fields: codec_fields]))
      end

      defimpl Heddle.Codec do
        def codec(_struct),
          do: unquote(Macro.escape(%Heddle{node: {:ref, __CALLER__.module, :codec}}))
      end
    end
  end

  # The codec in the block defschema returns is compiled before the block's
  # defstruct runs, so the compiler is told the struct's fields and defaults
  # here; defaults are evaluated as defstruct would evaluate them.
  defp record_struct_info(env, struct_fields) do
    info =
      Enum.map(struct_fields, fn {field, default} ->
        {value, _} = Code.eval_quoted(default, [], env)
        %{field: field, default: value, required: false}
      end)

    Process.put({:heddle_struct_info, env.module}, info)
  end

  defp default_value(:none), do: nil
  defp default_value({:ok, value}), do: value

  defp fields!(block, env) do
    block
    |> block_lines()
    |> Enum.map(fn
      {:field, _, [name, codec]} when is_atom(name) ->
        {name, codec, :none}

      {:field, _, [name, codec, [default: default]]} when is_atom(name) ->
        {name, codec, {:ok, default}}

      other ->
        Diagnostics.compile_error!(
          %CodecError{
            code: "H004",
            summary:
              "defschema expects `field name, codec` or `field name, codec, default: value`",
            labels: [{%Heddle{node: nil, span: Expr.span(meta(other), env)}, "this line"}]
          },
          env
        )
    end)
  end

  @doc """
  Defines a tagged union as `codec/0` and its `t/0` type.

      defunion do
        variant :empty
        variant :circle, radius: integer(min: 1)
        variant :rect, width: integer(min: 1), height: integer(min: 1)
      end

  Each variant is a tag and its fields, written `name: codec`. A variant with
  no fields is the bare atom (`:empty`); the others are tuples of the tag and
  the field values in order (`{:circle, radius}`, `{:rect, width, height}`).
  The field names document each position; the values carry no names.

  Fields can be other codecs. A module name stands for that module's codec
  (a schema, a union or a derived struct), so variants can carry structs and
  lists of them, and a union can name itself to nest:

      defunion do
        variant :circle, center: MyApp.Point, radius: integer(min: 1)
        variant :group, shapes: list(MyApp.Drawing, max: 16)
      end
  """
  defmacro defunion(do: block) do
    variants =
      block
      |> block_lines()
      |> Enum.map(fn
        {:variant, _, [tag]} when is_atom(tag) ->
          {tag, []}

        {:variant, _, [tag, fields]} when is_atom(tag) and is_list(fields) ->
          {tag, fields}

        other ->
          Diagnostics.compile_error!(
            %CodecError{
              code: "H004",
              summary: "defunion expects `variant :tag` or `variant :tag, field: codec, ...`",
              labels: [
                {%Heddle{node: nil, span: Expr.span(meta(other), __CALLER__)}, "this line"}
              ]
            },
            __CALLER__
          )
      end)

    alts =
      Enum.map(variants, fn
        {tag, []} ->
          quote(do: Heddle.atom(unquote(tag)))

        {tag, fields} ->
          quote(do: Heddle.tuple([Heddle.atom(unquote(tag)) | unquote(Keyword.values(fields))]))
      end)

    types =
      variants
      |> Enum.map(fn
        {tag, []} -> tag
        {tag, fields} -> {:{}, [], [tag | Enum.map(fields, fn _ -> quote(do: term()) end)]}
      end)
      |> Enum.reduce(fn t, acc -> quote(do: unquote(acc) | unquote(t)) end)

    quote do
      @type t :: unquote(types)

      Heddle.Schema.defcodec codec do
        Heddle.one_of(unquote(alts))
      end
    end
  end

  @doc false
  @spec ir_fun(atom()) :: atom()
  def ir_fun(name), do: :"__heddle_ir_#{name}__"

  defp block_lines({:__block__, _, lines}), do: lines
  defp block_lines(line), do: [line]

  defp meta({_, meta, _}) when is_list(meta), do: meta
  defp meta(_), do: []

  ## Deriving

  @doc false
  @spec derive(module(), keyword(), Macro.Env.t()) :: Macro.t()
  def derive(module, opts, env) do
    {defs, summary, ir_ast, findings, deps} =
      Expr.with_state(env, [:codec], fn ->
        codec =
          compile_time(env, :codec, fn ->
            check_derive_fields!(module, opts, env)
            Heddle.struct(module, opts) |> IR.__at__(Expr.span([line: env.line], env))
          end)

        compile_ir(codec, :codec, env)
      end)

    register(module, :codec, summary)

    quote do
      unquote(setup())
      unquote_splicing(Enum.map(deps, fn dep -> quote(do: require(unquote(dep))) end))
      @heddle_codecs {:codec, unquote(Macro.escape(summary)), unquote(Macro.escape(findings))}
      unquote_splicing(defs)

      @doc false
      def unquote(ir_fun(:codec))(), do: unquote(ir_ast)

      defimpl Heddle.Codec, for: unquote(module) do
        def codec(_struct), do: unquote(Macro.escape(%Heddle{node: {:ref, module, :codec}}))
      end
    end
  end

  defp check_derive_fields!(module, opts, env) do
    known = module |> Macro.struct_info!(env) |> Enum.map(& &1.field)
    fields = if Keyword.keyword?(opts), do: Keyword.get(opts, :fields, []), else: []
    names = if Keyword.keyword?(fields), do: Keyword.keys(fields), else: []

    case names -- known do
      [] ->
        :ok

      missing ->
        raise CodecError,
          code: "H004",
          summary: "#{inspect(module)} has no fields #{inspect(missing)}",
          labels: []
    end
  end

  ## Compilation

  defp define(name, expr, env) do
    locals = registered(env.module) ++ [name]

    {defs, summary, ir_ast, findings, deps} =
      Expr.with_state(env, locals, fn ->
        codec =
          compile_time(env, name, fn ->
            prepared = Expr.prepare(expr, env)
            value = Expr.eval(prepared, [], env)
            IR.codec!(value, "defcodec #{name}")
          end)

        compile_ir(codec, name, env)
      end)

    register(env.module, name, summary)

    quote do
      unquote(setup())
      unquote_splicing(Enum.map(deps, fn module -> quote(do: require(unquote(module))) end))

      @heddle_codecs {unquote(name), unquote(Macro.escape(summary)),
                      unquote(Macro.escape(findings))}
      unquote_splicing(defs)

      @doc false
      def unquote(ir_fun(name))(), do: unquote(ir_ast)

      @spec unquote(name)() :: Heddle.t()
      def unquote(name)(), do: unquote(Macro.escape(%Heddle{node: {:ref, env.module, name}}))
    end
  end

  # Compiles an evaluated codec (from defcodec or @derive) and returns the
  # pieces define/3 and Heddle.Codec emit.
  @doc false
  @spec compile_ir(Heddle.t(), atom(), Macro.Env.t()) ::
          {[Macro.t()], Heddle.IR.summary(), Macro.t(), [Pentiment.Report.t()], [module()]}
  def compile_ir(codec, name, env) do
    compile_time(env, name, fn ->
      summary = IR.summary(codec)
      put_local_summary(env.module, name, summary)
      {defs, findings} = Compiler.compile(codec, name, env)
      {defs, summary, escape_ir(codec), findings, Expr.state() |> deps()}
    end)
  end

  defp deps(nil), do: []
  defp deps(state), do: state.deps |> MapSet.delete(state.module) |> Enum.sort()

  # Runs a compile step with the compile-time evaluator and the module's
  # earlier summaries in scope, turning codec errors into pentiment reports.
  defp compile_time(env, name, fun) do
    summaries = Map.put(local_summaries(env.module), name, :pending)
    previous_eval = Process.put(:heddle_funref_eval, &eval_funref(&1, &2, env))
    previous_summaries = Process.put({:heddle_local_summaries, env.module}, summaries)

    try do
      fun.()
    rescue
      e in CodecError -> Diagnostics.compile_error!(e, env)
    after
      restore(:heddle_funref_eval, previous_eval)
      restore({:heddle_local_summaries, env.module}, previous_summaries)
    end
  end

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, value), do: Process.put(key, value)

  defp eval_funref(%IR.FunRef{id: id, bindings: bindings}, args, env) do
    {source, _meta} = Expr.fun_source(id)
    scope = MapSet.new(bindings, &elem(&1, 0))

    callable =
      case source do
        {:fn, meta, clauses} ->
          {:fn, meta,
           Enum.map(clauses, fn {:->, m, [params, body]} ->
             {:->, m,
              [params, Expr.prepare(body, env, MapSet.union(scope, Expr.var_keys(params)))]}
           end)}

        capture ->
          capture
      end

    call = quote(do: apply(unquote(callable), unquote(Enum.map(args, &Macro.escape/1))))
    Expr.eval(call, bindings, env)
  end

  defp registered(module) do
    if Module.open?(module), do: Map.keys(local_summaries(module)), else: []
  end

  defp local_summaries(module) do
    if Module.open?(module),
      do: Module.get_attribute(module, :heddle_local_summaries) || %{},
      else: %{}
  end

  defp put_local_summary(module, name, summary) do
    Process.put(
      {:heddle_local_summaries, module},
      Map.put(Process.get({:heddle_local_summaries, module}, %{}), name, summary)
    )
  end

  defp register(module, name, summary) do
    unless Module.has_attribute?(module, :heddle_local_summaries),
      do: Module.register_attribute(module, :heddle_local_summaries, [])

    Module.put_attribute(
      module,
      :heddle_local_summaries,
      Map.put(local_summaries(module), name, summary)
    )
  end

  # The IR as code that rebuilds it at runtime, with each function's source
  # in place of its placeholder.
  @doc false
  @spec escape_ir(Heddle.t()) :: Macro.t()
  def escape_ir(%Heddle{} = codec), do: escape_term(codec)

  defp escape_term(%IR.FunRef{} = ref), do: Compiler.funref_ast(ref)
  defp escape_term(fun) when is_function(fun), do: Compiler.fun_ast(fun)

  defp escape_term(%module{} = struct) do
    fields = struct |> Map.from_struct() |> Enum.map(fn {k, v} -> {k, escape_term(v)} end)
    {:%, [], [module, {:%{}, [], fields}]}
  end

  defp escape_term(tuple) when is_tuple(tuple),
    do: {:{}, [], tuple |> Tuple.to_list() |> Enum.map(&escape_term/1)}

  defp escape_term(list) when is_list(list), do: Enum.map(list, &escape_term/1)

  defp escape_term(map) when is_map(map),
    do: {:%{}, [], Enum.map(map, fn {k, v} -> {escape_term(k), escape_term(v)} end)}

  defp escape_term(other), do: Macro.escape(other)

  @doc false
  defmacro __before_compile__(env) do
    codecs = env.module |> Module.get_attribute(:heddle_codecs) |> Enum.reverse()
    names = Enum.map(codecs, &elem(&1, 0))

    quote do
      @doc false
      unquote_splicing(decode_clauses(names))
      @doc false
      unquote_splicing(encode_clauses(names))
      @doc false
      unquote_splicing(summary_clauses(codecs))
      @doc false
      unquote_splicing(lint_clauses(codecs))
      @doc false
      unquote_splicing(ir_clauses(names))
      @doc false
      def __heddle_codecs__, do: unquote(names)
    end
  end

  defp missing(function, args) do
    quote do
      def unquote(function)(name, unquote_splicing(args)),
        do:
          raise(
            ArgumentError,
            "#{inspect(__MODULE__)} has no Heddle codec named #{inspect(name)}"
          )
    end
  end

  defp decode_clauses(names) do
    for(name <- names) do
      quote do
        def __heddle_decode__(unquote(name), rest, depth, nodes, lim),
          do: unquote(Compiler.root_dec(name))(rest, depth, nodes, lim)
      end
    end ++
      [
        missing(
          :__heddle_decode__,
          Enum.map(~w(rest depth nodes lim)a, &Macro.var(:"_#{&1}", __MODULE__))
        )
      ]
  end

  defp encode_clauses(names) do
    two =
      for name <- names do
        quote(
          do:
            def(__heddle_encode__(unquote(name), value),
              do: unquote(Compiler.root_enc(name))(value, "")
            )
        )
      end

    three =
      for name <- names do
        quote(
          do:
            def(__heddle_encode__(unquote(name), value, acc),
              do: unquote(Compiler.root_enc(name))(value, acc)
            )
        )
      end

    two ++
      [missing(:__heddle_encode__, [Macro.var(:_value, __MODULE__)])] ++
      three ++
      [
        missing(:__heddle_encode__, [Macro.var(:_value, __MODULE__), Macro.var(:_acc, __MODULE__)])
      ]
  end

  defp summary_clauses(codecs) do
    for(
      {name, summary, _} <- codecs,
      do: quote(do: def(__heddle_summary__(unquote(name)), do: unquote(Macro.escape(summary))))
    ) ++
      [missing(:__heddle_summary__, [])]
  end

  defp lint_clauses(codecs) do
    for(
      {name, _, findings} <- codecs,
      do: quote(do: def(__heddle_lint__(unquote(name)), do: unquote(Macro.escape(findings))))
    ) ++
      [quote(do: def(__heddle_lint__(_name), do: []))]
  end

  # The IR is rebuilt once per node and kept in :persistent_term.
  defp ir_clauses(names) do
    clauses =
      for name <- names do
        quote do
          def __heddle_ir__(unquote(name)) do
            key = {Heddle, __MODULE__, unquote(name)}

            case :persistent_term.get(key, nil) do
              nil ->
                ir = unquote(ir_fun(name))()
                :persistent_term.put(key, ir)
                ir

              ir ->
                ir
            end
          end
        end
      end

    clauses ++ [missing(:__heddle_ir__, [])]
  end
end

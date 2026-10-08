defmodule Heddle.Compiler.Expr do
  @moduledoc false
  # Prepares a codec expression so a Heddle macro can evaluate it at compile
  # time, within the rules of the compilation model:
  #
  #   * macros are expanded first, so pipes, `Heddle.Syntax` blocks and
  #     `if` become plain calls;
  #   * every function (`fn` or `&`) becomes a FunRef placeholder; the
  #     compiler keeps its source and the variables in scope where it was
  #     created, so compiled code can embed it and the compiler can evaluate
  #     it later (lazy thunks, finite binds);
  #   * a call to a codec defined earlier with `defcodec` becomes a reference;
  #   * a call to any other function of the module being compiled is an
  #     error, since that module cannot run yet;
  #   * remote calls are recorded as compile-time dependencies;
  #   * calls to Heddle's constructors record their source span.

  alias Heddle.CodecError

  defmodule State do
    @moduledoc false
    # One compilation's shared state: function sources by id, the modules
    # codec expressions called, and the next id. It lives in the process
    # dictionary under :heddle_compile for the length of one macro expansion.
    defstruct funs: %{}, deps: MapSet.new(), next: 1, module: nil, env: nil, locals: MapSet.new()

    @type t :: %__MODULE__{
            funs: %{pos_integer() => {Macro.t(), keyword()}},
            deps: MapSet.t(module()),
            next: pos_integer(),
            module: module() | nil,
            env: Macro.Env.t() | nil,
            locals: MapSet.t(atom())
          }
  end

  @doc false
  @spec with_state(Macro.Env.t(), [atom()], (-> result)) :: result when result: term()
  def with_state(env, locals, fun) do
    previous = Process.get(:heddle_compile)
    Process.put(:heddle_compile, %State{module: env.module, env: env, locals: MapSet.new(locals)})

    try do
      fun.()
    after
      if previous,
        do: Process.put(:heddle_compile, previous),
        else: Process.delete(:heddle_compile)
    end
  end

  @doc false
  @spec state() :: State.t() | nil
  def state, do: Process.get(:heddle_compile)

  defp update(fun), do: Process.put(:heddle_compile, fun.(state()))

  @doc false
  @spec fun_source(pos_integer()) :: {Macro.t(), keyword()}
  def fun_source(id), do: Map.fetch!(state().funs, id)

  @doc false
  @spec deps() :: MapSet.t(module())
  def deps, do: state().deps

  @doc """
  Expands and prepares `ast`. Raises `Heddle.CodecError` (H005) on a call
  that cannot run at compile time.
  """
  @spec prepare(Macro.t(), Macro.Env.t(), Enumerable.t()) :: Macro.t()
  def prepare(ast, env, scope \\ MapSet.new()) do
    ast
    |> expand_all(env)
    |> walk(env, MapSet.new(scope))
  end

  @doc false
  @spec expand_all(Macro.t(), Macro.Env.t()) :: Macro.t()
  def expand_all(ast, env) do
    Macro.prewalk(ast, fn
      {:fn, _, _} = fun -> fun
      {:&, _, _} = capture -> capture
      node -> Macro.expand(node, env)
    end)
    |> expand_inside_functions(env)
  end

  # Function bodies are expanded too, so their sources are plain calls when
  # the compiler analyzes them; they are not walked, since they run later.
  defp expand_inside_functions(ast, env) do
    Macro.prewalk(ast, fn
      {:fn, meta, clauses} ->
        {:fn, meta,
         Enum.map(clauses, fn {:->, m, [args, body]} ->
           {:->, m, [args, expand_all(body, env)]}
         end)}

      node ->
        node
    end)
  end

  @doc """
  Evaluates a prepared expression at compile time with `bindings`, a list of
  `{{name, context}, value}`.
  """
  @spec eval(Macro.t(), [{{atom(), atom()}, term()}], Macro.Env.t()) :: term()
  def eval(prepared, bindings, env) do
    {value, _} = Code.eval_quoted(prepared, Enum.map(bindings, &eval_binding/1), env)
    value
  end

  defp eval_binding({{name, nil}, value}), do: {name, value}
  defp eval_binding({{name, ctx}, value}), do: {{name, ctx}, value}

  @doc false
  @spec var_keys(Macro.t()) :: MapSet.t({atom(), atom()})
  def var_keys(ast) do
    {_, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:^, _, _} = pin, acc ->
          {pin, acc}

        {var, _, ctx} = node, acc when is_atom(var) and is_atom(ctx) and var != :_ ->
          {node, MapSet.put(acc, {var, ctx})}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp walk(ast, env, scope) do
    case ast do
      {:fn, meta, [{:->, _, [args, _]} | _]} = fun ->
        funref(fun, length(strip_when(args)), meta, scope)

      {:&, meta, [{:/, _, [_call, arity]}]} = capture when is_integer(arity) ->
        local_codec_capture(capture, env) || funref(capture, arity, meta, scope)

      {:&, meta, [_body]} = capture ->
        funref(capture, capture_arity(capture), meta, scope)

      {:__block__, meta, exprs} ->
        {exprs, _scope} =
          Enum.map_reduce(exprs, scope, fn expr, scope ->
            walked = walk(expr, env, scope)

            case expr do
              {:=, _, [pattern, _]} -> {walked, MapSet.union(scope, var_keys(pattern))}
              _ -> {walked, scope}
            end
          end)

        {:__block__, meta, exprs}

      {:case, meta, [subject, [do: clauses]]} ->
        clauses =
          Enum.map(clauses, fn {:->, m, [[head], body]} ->
            {:->, m, [[head], walk(body, env, MapSet.union(scope, var_keys(head)))]}
          end)

        {:case, meta, [walk(subject, env, scope), [do: clauses]]}

      {{:., _, [Heddle, fun]}, meta, args} when is_atom(fun) and is_list(args) ->
        call = {{:., [], [Heddle, fun]}, meta, Enum.map(args, &walk(&1, env, scope))}
        quote do: Heddle.IR.__at__(unquote(call), unquote(Macro.escape(span(meta, env))))

      {{:., meta, [module, fun]}, call_meta, args} when is_atom(module) and is_list(args) ->
        unless module in [Kernel, Module, Heddle.IR, :erlang],
          do: update(&%{&1 | deps: MapSet.put(&1.deps, module)})

        {{:., meta, [module, fun]}, call_meta, Enum.map(args, &walk(&1, env, scope))}

      {name, meta, args} when is_atom(name) and is_list(args) ->
        local_call(name, meta, args, env, scope)

      {left, right} ->
        {walk(left, env, scope), walk(right, env, scope)}

      list when is_list(list) ->
        Enum.map(list, &walk(&1, env, scope))

      {form, meta, args} when is_list(args) ->
        {walk(form, env, scope), meta, Enum.map(args, &walk(&1, env, scope))}

      other ->
        other
    end
  end

  defp strip_when([{:when, _, args}]), do: Enum.drop(args, -1)
  defp strip_when(args), do: args

  defp local_call(name, meta, args, env, scope) do
    arity = length(args)
    st = state()

    cond do
      args == [] and MapSet.member?(st.locals, name) ->
        Macro.escape(%Heddle{node: {:ref, env.module, name}, span: span(meta, env)})

      special?(name, arity) ->
        {name, meta, Enum.map(args, &walk(&1, env, scope))}

      Macro.Env.lookup_import(env, {name, arity}) != [] ->
        {name, meta, Enum.map(args, &walk(&1, env, scope))}

      true ->
        raise CodecError,
          code: "H005",
          summary: "#{name}/#{arity} cannot be called in a compiled codec expression",
          labels: [
            {%Heddle{node: nil, span: span(meta, env)},
             "this call runs at compile time, before #{inspect(env.module)} exists"}
          ],
          help:
            "define the codec with defcodec earlier in this module, move the helper to another module, " <>
              "or capture it (&#{name}/#{arity}) where Heddle expects a function"
    end
  end

  @special [
    :__block__,
    :__aliases__,
    :__MODULE__,
    :__ENV__,
    :__DIR__,
    :__CALLER__,
    :__STACKTRACE__,
    :case,
    :cond,
    :receive,
    :try,
    :for,
    :with,
    :quote,
    :unquote,
    :unquote_splicing,
    :fn,
    :=,
    :^,
    :%,
    :%{},
    :{},
    :<<>>,
    :"::",
    :|,
    :<-,
    :->,
    :__cursor__,
    :super,
    :import,
    :require,
    :alias
  ]

  defp special?(name, _arity), do: name in @special

  # `&name/0` naming a defcodec stands for that codec, so `lazy(&tree/0)`
  # works without evaluating anything in the module.
  defp local_codec_capture({:&, meta, [{:/, _, [{name, _, ctx}, 0]}]}, env)
       when is_atom(name) and is_atom(ctx) do
    if MapSet.member?(state().locals, name) do
      ref = Macro.escape(%Heddle{node: {:ref, env.module, name}, span: span(meta, env)})
      fun = quote do: fn -> unquote(ref) end
      funref(fun, 0, meta, MapSet.new())
    end
  end

  defp local_codec_capture(_, _), do: nil

  # The function's free variables that are in scope here are captured by
  # name, so its source can be evaluated or embedded later.
  defp funref(source, arity, meta, scope) do
    st = state()
    id = st.next
    update(&%{&1 | next: id + 1, funs: Map.put(&1.funs, id, {source, meta})})

    captured =
      for {name, ctx} = key <- Enum.sort(var_keys(source)), MapSet.member?(scope, key) do
        {Macro.escape(key), Macro.var(name, ctx)}
      end

    quote do: Heddle.IR.FunRef.new(unquote(id), unquote(arity), unquote(captured))
  end

  @doc false
  @spec capture_arity(Macro.t()) :: non_neg_integer()
  def capture_arity(capture) do
    {_, max} =
      Macro.prewalk(capture, 0, fn
        {:&, _, [n]} = node, acc when is_integer(n) -> {node, max(acc, n)}
        node, acc -> {node, acc}
      end)

    max
  end

  @doc """
  Turns a capture with `&1`..`&n` into an equivalent `fn`.
  """
  @spec capture_to_fn(Macro.t()) :: Macro.t()
  def capture_to_fn({:&, meta, [{:/, _, _}]} = capture), do: {:capture, capture, meta}

  def capture_to_fn({:&, meta, [body]} = capture) do
    arity = capture_arity(capture)
    vars = for i <- 1..arity//1, do: Macro.var(:"heddle_arg#{i}", __MODULE__)

    body =
      Macro.prewalk(body, fn
        {:&, _, [n]} when is_integer(n) -> Enum.at(vars, n - 1)
        node -> node
      end)

    {:fn, meta, [{:->, meta, [vars, body]}]}
  end

  @doc false
  @spec span(keyword(), Macro.Env.t()) :: {String.t(), Pentiment.Span.Position.t()}
  def span(meta, env) do
    line = Keyword.get(meta, :line, env.line)
    column = Keyword.get(meta, :column, 1)
    {env.file, Pentiment.Span.position(max(line, 1), max(column, 1))}
  end
end

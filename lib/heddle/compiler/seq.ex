defmodule Heddle.Compiler.Seq do
  @moduledoc false
  # Compiles `tuple_seq` codecs: binding-time analysis of `bind`.
  #
  # A sequence compiles from its IR while its steps are static, and from the
  # source of its continuations once they depend on decoded values. For each
  # step's codec expression:
  #
  #   * static - it reads no runtime value: evaluated now, compiled once;
  #   * finite - the value bound before it comes from a codec with at most 64
  #     values and is used in later codecs: the continuation is compiled once
  #     per value, as a case (at most 256 branches along a path);
  #   * parameter - runtime values appear only as bounds (min:, max:,
  #     max_size:): compiled once, with the bounds passed at runtime;
  #   * case - a case on runtime values whose arms are codecs: each arm is
  #     classified in turn;
  #   * opaque - anything else: evaluated at runtime and run by the
  #     interpreter, and reported (W001).
  #
  # Every path charges one node per continuation and checks the tuple's
  # arity exactly as Heddle.Interpreter.run_seq does.

  alias Heddle.{CodecError, Compiler, Diagnostics, IR}
  alias Heddle.Compiler.Expr
  alias Heddle.IR.{FunRef, Param}

  @param_options %{
    integer: [
      min: {:int, "Heddle.integer/1 option :min"},
      max: {:int, "Heddle.integer/1 option :max"}
    ],
    binary: [max_size: {:bound, "Heddle.binary/1 option :max_size"}],
    list: [max: {:bound, "Heddle.list/2 option :max"}],
    charlist: [max: {:bound, "Heddle.charlist/1 option :max"}],
    map_of: [max: {:bound, "Heddle.map_of/3 option :max"}]
  }

  ## Decoding

  @doc false
  @spec dec(Heddle.t(), atom() | nil, Heddle.t(), term()) :: Heddle.Compiler.caller()
  def dec(codec, tag, seq, pctx) do
    expected = Compiler.expected_of(codec, nil)
    env = %{vars: %{}, budget: 1, expected: expected}

    steps =
      if tag do
        tag_caller = Compiler.dec_caller(%Heddle{node: {:literal, tag}}, nil)

        quote context: Compiler do
          if arity == 0 do
            Heddle.Runtime.fail(:unexpected, unquote(expected), start)
          else
            case unquote(
                   Compiler.call_dec_at(
                     tag_caller,
                     quote(context: Compiler, do: body),
                     quote(context: Compiler, do: edepth)
                   )
                 ) do
              {:ok, _, body, nodes} -> unquote(dec_ir(seq, 1, env))
              error -> Heddle.Runtime.prefix(error, 0)
            end
          end
        end
      else
        dec_ir(seq, 0, env)
      end

    Compiler.new_consuming(
      pctx,
      quote context: Compiler do
        case Heddle.Runtime.tuple_header(rest) do
          {:ok, arity, body} ->
            start = rest
            edepth = depth + 1
            unquote(steps)

          {:error, reason} ->
            Heddle.Runtime.fail(reason, unquote(expected), rest)
        end
      end
    )
  end

  defp dec_ir(%Heddle{node: {:pure, value}}, i, env),
    do: dec_pure(Compiler.escape!(value), i, env)

  defp dec_ir(%Heddle{node: {:bind, codec, k}}, i, env) do
    caller = Compiler.dec_caller(codec, nil)

    call =
      Compiler.call_dec_at(
        caller,
        quote(context: Compiler, do: body),
        quote(context: Compiler, do: edepth)
      )

    dec_step(call, finite_values(codec), k, i, env)
  end

  defp dec_pure(expr, i, env) do
    quote context: Compiler do
      if arity == unquote(i),
        do: {:ok, unquote(expr), body, nodes},
        else: Heddle.Runtime.fail(:unexpected, unquote(env.expected), start)
    end
  end

  defp dec_step(call, finite, k, i, env) do
    y = Macro.var(:"heddle_y#{i}", Compiler)

    quote context: Compiler do
      if arity == unquote(i) do
        Heddle.Runtime.fail(:unexpected, unquote(env.expected), start)
      else
        case unquote(call) do
          {:ok, unquote(y), body, nodes} ->
            case Heddle.Interpreter.charge_bind(body, nodes, lim) do
              {:ok, nodes} -> unquote(continuation(:dec, k, y, finite, i + 1, env))
              error -> error
            end

          error ->
            Heddle.Runtime.prefix(error, unquote(i))
        end
      end
    end
  end

  defp dec_state(env),
    do: quote(context: Compiler, do: {start, unquote(env.expected), arity, edepth, lim})

  ## Encoding

  @doc false
  @spec enc(Heddle.t(), atom() | nil, Heddle.t(), term()) :: Heddle.Compiler.caller()
  def enc(codec, tag, seq, pctx) do
    env = %{vars: %{}, budget: 1, expected: Compiler.expected_of(codec, nil)}
    # Elements append to `elems`; the step index is the element count, known
    # along each path, so the tuple header is written once they are done.
    start = if tag, do: Heddle.ETF.encode_atom(tag), else: ""
    i = if tag, do: 1, else: 0

    body =
      quote context: Compiler do
        elems = unquote(start)

        case unquote(enc_ir(seq, i, env)) do
          {:ok, y, elems, count} ->
            {:ok, y, <<acc::binary, Heddle.ETF.tuple_header(count)::binary, elems::binary>>}

          error ->
            error
        end
      end

    Compiler.new_encoder(pctx, [{quote(context: Compiler, do: value), nil, body}])
  end

  defp enc_ir(%Heddle{node: {:pure, value}}, i, _env),
    do: quote(context: Compiler, do: {:ok, unquote(Compiler.escape!(value)), elems, unquote(i)})

  defp enc_ir(%Heddle{node: {:bind, codec, k}}, i, env) do
    call =
      Compiler.call_enc(
        Compiler.enc_caller(codec, nil),
        quote(context: Compiler, do: value),
        quote(context: Compiler, do: elems)
      )

    enc_step(call, finite_values(codec), k, i, env)
  end

  defp enc_step(call, finite, k, i, env) do
    y = Macro.var(:"heddle_y#{i}", Compiler)

    quote context: Compiler do
      case unquote(call) do
        {:ok, unquote(y), elems} ->
          unquote(continuation(:enc, k, y, finite, i + 1, env))

        error ->
          Heddle.Runtime.enc_prefix(error, unquote(i))
      end
    end
  end

  ## Continuations

  defp continuation(dir, %FunRef{id: id, bindings: bindings}, y, finite, i, env) do
    {source, meta} = Expr.fun_source(id)
    used = Compiler.vars_of(source)
    bound = for {key, value} <- bindings, MapSet.member?(used, key), do: {key, value}

    assignments =
      for {{name, ctx}, value} <- bound do
        quote(do: unquote(Macro.var(name, ctx)) = unquote(Compiler.escape!(value)))
      end

    vars =
      Enum.reduce(bound, env.vars, fn {key, value}, vars ->
        Map.put(vars, key, {:const, value})
      end)

    code = fn_continuation(dir, source, meta, y, finite, i, %{env | vars: vars})
    {:__block__, [], assignments ++ [code]}
  end

  defp continuation(dir, fun, y, _finite, i, env) when is_function(fun, 1) do
    opaque_continuation(dir, Compiler.fun_ast(fun), y, i, env)
  end

  defp continuation(dir, k_ast, y, finite, i, env),
    do: fn_continuation(dir, k_ast, meta_of(k_ast), y, finite, i, env)

  defp fn_continuation(dir, source, meta, y, finite, i, env) do
    case normalize_fn(source) do
      {:simple, var, body} ->
        key = var_key(var)
        {n_values, budget} = {finite && length(finite), env.budget}

        if finite && used_in_codecs?(body, key) &&
             budget * n_values <= elem(Compiler.finite_limits(), 1) do
          branches =
            for value <- finite do
              vars = Map.put(env.vars, key, {:const, value})
              code = body_code(dir, body, i, %{env | vars: vars, budget: budget * n_values})

              {:->, [],
               [
                 [Compiler.escape!(value)],
                 {:__block__, [], [quote(do: unquote(var) = unquote(y)), code]}
               ]}
            end

          fallback = {:->, [], [[quote(do: _)], opaque_continuation(dir, source, y, i, env)]}
          {:case, [], [y, [do: branches ++ [fallback]]]}
        else
          vars = Map.put(env.vars, key, :runtime)
          code = body_code(dir, body, i, %{env | vars: vars})

          if MapSet.member?(Compiler.vars_of(body), key),
            do: {:__block__, [], [quote(do: unquote(var) = unquote(y)), code]},
            else: code
        end

      :clauses when finite != nil ->
        n_values = length(finite)

        if env.budget * n_values <= elem(Compiler.finite_limits(), 1) and
             runtime_free?(source, env) do
          branches =
            for value <- finite do
              code =
                case eval_apply(source, value, env) do
                  {:ok, seq} -> ir_code(dir, seq, i, %{env | budget: env.budget * n_values})
                  :error -> opaque_continuation(dir, source, y, i, env)
                end

              {:->, [], [[Compiler.escape!(value)], code]}
            end

          fallback = {:->, [], [[quote(do: _)], opaque_continuation(dir, source, y, i, env)]}
          {:case, [], [y, [do: branches ++ [fallback]]]}
        else
          opaque(
            meta,
            "this continuation's clauses depend on a value with too many possibilities"
          )

          opaque_continuation(dir, source, y, i, env)
        end

      _ ->
        opaque(meta, "this continuation runs in the interpreter")
        opaque_continuation(dir, source, y, i, env)
    end
  end

  defp ir_code(:dec, seq, i, env), do: dec_ir(seq, i, env)
  defp ir_code(:enc, seq, i, env), do: enc_ir(seq, i, env)

  defp opaque_continuation(:dec, fun_ast, y, i, env) do
    quote context: Compiler do
      Heddle.Interpreter.continue_seq(
        unquote(fun_ast).(unquote(y)),
        unquote(dec_state(env)),
        unquote(i),
        body,
        nodes
      )
    end
  end

  defp opaque_continuation(:enc, fun_ast, y, i, _env) do
    quote context: Compiler do
      Heddle.Runtime.continue_enc(
        Heddle.Interpreter.enc_seq(
          unquote(fun_ast).(unquote(y)),
          value,
          :compiled,
          unquote(i),
          []
        ),
        elems,
        unquote(i)
      )
    end
  end

  # The body of a continuation, compiled from its source.
  defp body_code(dir, body, i, env) do
    case body do
      {{:., _, [Heddle, :pure]}, _, [expr]} ->
        if dir == :dec,
          do: dec_pure(expr, i, env),
          else: quote(context: Compiler, do: {:ok, unquote(expr), elems, unquote(i)})

      {{:., meta, [Heddle, :bind]}, _, [codec_ast, k_ast]} ->
        {call, finite} = step_call(dir, codec_ast, meta, env)

        if dir == :dec,
          do: dec_step(call, finite, k_ast, i, env),
          else: enc_step(call, finite, k_ast, i, env)

      other ->
        opaque(
          meta_of(other),
          "this sequence step is not a Heddle.bind/2 or Heddle.pure/1 call, so it runs in the interpreter"
        )

        if dir == :dec,
          do:
            quote(
              context: Compiler,
              do:
                Heddle.Interpreter.continue_seq(
                  unquote(other),
                  unquote(dec_state(env)),
                  unquote(i),
                  body,
                  nodes
                )
            ),
          else:
            quote(
              context: Compiler,
              do:
                Heddle.Runtime.continue_enc(
                  Heddle.Interpreter.enc_seq(unquote(other), value, :compiled, unquote(i), []),
                  elems,
                  unquote(i)
                )
            )
    end
  end

  # The code that decodes or encodes one step, and the step's finite values.
  defp step_call(dir, codec_ast, meta, env) do
    case classify(codec_ast, env) do
      {:static, codec} ->
        {static_call(dir, codec), finite_values(codec)}

      {:param, codec, params} ->
        {param_call(dir, codec, params), nil}

      {:case, scrutinee, arms} ->
        clauses =
          for {head, arm_ast, arm_env} <- arms do
            {call, _} = step_call(dir, arm_ast, meta, arm_env)
            {:->, [], [[head], call]}
          end

        {{:case, [], [scrutinee, [do: clauses]]}, nil}

      :opaque ->
        opaque(
          meta,
          "this step's codec depends on decoded values beyond its bounds, so it runs in the interpreter"
        )

        codec = quote(do: Heddle.IR.codec!(unquote(codec_ast), "Heddle.bind/2"))

        call =
          if dir == :dec,
            do:
              quote(
                context: Compiler,
                do: Heddle.Interpreter.dec(unquote(codec), body, edepth, nodes, lim)
              ),
            else:
              quote(
                context: Compiler,
                do:
                  Heddle.Runtime.lift(
                    Heddle.Interpreter.enc(unquote(codec), value, :compiled),
                    elems
                  )
              )

        {call, nil}
    end
  end

  defp static_call(:dec, codec),
    do:
      Compiler.call_dec_at(
        Compiler.dec_caller(codec, nil),
        quote(context: Compiler, do: body),
        quote(context: Compiler, do: edepth)
      )

  defp static_call(:enc, codec),
    do:
      Compiler.call_enc(
        Compiler.enc_caller(codec, nil),
        quote(context: Compiler, do: value),
        quote(context: Compiler, do: elems)
      )

  defp param_call(dir, codec, params) do
    checks =
      params
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn
        {_i, expr, :bound, context} ->
          quote(do: Heddle.Runtime.check_param!(unquote(expr), unquote(context)))

        {_i, expr, :int, context} ->
          quote(do: Heddle.Runtime.check_int_param!(unquote(expr), unquote(context)))
      end)

    tuple = {:{}, [], checks}

    call =
      case dir do
        :dec ->
          Compiler.call_dec_at(
            Compiler.dec_caller(codec, :param),
            quote(context: Compiler, do: body),
            quote(context: Compiler, do: edepth)
          )

        :enc ->
          Compiler.call_enc(
            Compiler.enc_caller(codec, :param),
            quote(context: Compiler, do: value),
            quote(context: Compiler, do: elems)
          )
      end

    ps = Macro.var(:ps, Compiler)

    quote do
      case unquote(tuple) do
        unquote(ps) ->
          Heddle.Runtime.check_ranges!(unquote(ps), unquote(Macro.escape(range_pairs(codec))))
          unquote(call)
      end
    end
  end

  # Integer codecs whose bounds are parameters, as {min, max} pairs of
  # literals or parameter indices, so the constructor's min <= max check runs.
  defp range_pairs(%Heddle{node: node}) do
    own =
      case node do
        {:integer, min, max} when is_struct(min, Param) or is_struct(max, Param) ->
          [{param_ref(min), param_ref(max)}]

        _ ->
          []
      end

    own ++ (node |> children() |> Enum.flat_map(&range_pairs/1))
  end

  defp param_ref(%Param{index: i}), do: {:param, i}
  defp param_ref(value), do: value

  defp children(node) when is_tuple(node) do
    node
    |> Tuple.to_list()
    |> Enum.flat_map(fn
      %Heddle{node: {:lazy, _}} -> []
      %Heddle{} = c -> [c]
      list when is_list(list) -> Enum.flat_map(list, &list_children/1)
      _ -> []
    end)
  end

  defp children(_), do: []

  defp list_children(%Heddle{} = c), do: [c]
  defp list_children({_k, %Heddle{} = c}), do: [c]
  defp list_children({_k, %Heddle{} = c, _d}), do: [c]
  defp list_children(_), do: []

  ## Classification

  defp classify(codec_ast, env) do
    runtime = runtime_vars(codec_ast, env)

    cond do
      runtime == [] ->
        case eval(codec_ast, env) do
          {:ok, %Heddle{} = codec} -> {:static, IR.codec!(codec, "Heddle.bind/2")}
          _ -> :opaque
        end

      match?({:case, _, [_, [do: _]]}, codec_ast) ->
        classify_case(codec_ast, env)

      true ->
        classify_param(codec_ast, runtime, env)
    end
  end

  defp classify_case({:case, _, [scrutinee, [do: clauses]]}, env) do
    arms =
      Enum.map(clauses, fn {:->, _, [[head], arm]} ->
        pattern_vars =
          head
          |> Compiler.vars_of()
          |> Enum.reject(fn {name, _} -> String.starts_with?(Atom.to_string(name), "_") end)

        vars = Enum.reduce(pattern_vars, env.vars, &Map.put(&2, &1, :runtime))
        {head, arm, %{env | vars: vars}}
      end)

    {:case, scrutinee, arms}
  end

  defp classify_param(codec_ast, runtime, env) do
    {replaced, params} = replace_params(codec_ast, runtime)

    if params != [] and runtime_vars(replaced, env) == [] do
      case eval(replaced, env) do
        {:ok, %Heddle{} = codec} -> {:param, IR.codec!(codec, "Heddle.bind/2"), params}
        _ -> :opaque
      end
    else
      :opaque
    end
  end

  # Replaces bound expressions that read runtime values with Param
  # placeholders, recording each with its check.
  defp replace_params(ast, runtime) do
    runtime = MapSet.new(runtime)

    Macro.prewalk(ast, [], fn
      {{:., m, [Heddle, fun]}, cm, args} = call, acc
      when is_map_key(@param_options, fun) and is_list(args) ->
        options = Map.fetch!(@param_options, fun)

        case List.last(args) do
          opts when is_list(opts) and opts != [] ->
            {opts, acc} =
              Enum.map_reduce(opts, acc, fn
                {key, value}, acc when is_atom(key) ->
                  with {kind, context} <- Keyword.get(options, key),
                       true <- reads?(value, runtime) do
                    index = length(acc)

                    {{key, Macro.escape(%Param{index: index})},
                     [{index, value, kind, context} | acc]}
                  else
                    _ -> {{key, value}, acc}
                  end

                other, acc ->
                  {other, acc}
              end)

            {{{:., m, [Heddle, fun]}, cm, List.replace_at(args, -1, opts)}, acc}

          _ ->
            {call, acc}
        end

      node, acc ->
        {node, acc}
    end)
  end

  defp reads?(ast, runtime),
    do: ast |> Compiler.vars_of() |> Enum.any?(&MapSet.member?(runtime, &1))

  defp runtime_vars(ast, env) do
    ast
    |> Compiler.vars_of()
    |> Enum.filter(&(Map.get(env.vars, &1) == :runtime))
  end

  defp runtime_free?(ast, env), do: runtime_vars(ast, env) == []

  defp const_bindings(ast, env) do
    used = Compiler.vars_of(ast)
    for {key, {:const, value}} <- env.vars, MapSet.member?(used, key), do: {key, value}
  end

  defp eval(ast, env) do
    compile_env = Compiler.env()
    bindings = const_bindings(ast, env)
    prepared = Expr.prepare(ast, compile_env, Enum.map(bindings, &elem(&1, 0)))
    {:ok, Expr.eval(prepared, bindings, compile_env)}
  rescue
    _ -> :error
  end

  defp eval_apply({:fn, meta, clauses} = source, value, env) do
    compile_env = Compiler.env()
    bindings = const_bindings(source, env)
    scope = MapSet.new(bindings, &elem(&1, 0))

    prepared_clauses =
      Enum.map(clauses, fn {:->, m, [args, body]} ->
        {:->, m,
         [args, Expr.prepare(body, compile_env, MapSet.union(scope, Expr.var_keys(args)))]}
      end)

    call = quote(do: unquote({:fn, meta, prepared_clauses}).(unquote(Compiler.escape!(value))))
    result = Expr.eval(call, bindings, compile_env)
    {:ok, IR.seq!(result, "a Heddle.bind/2 continuation")}
  rescue
    _ -> :error
  end

  defp eval_apply(_source, _value, _env), do: :error

  ## Helpers

  # A continuation's source as a single-variable fn, or :clauses.
  defp normalize_fn({:&, _, _} = capture), do: capture |> Expr.capture_to_fn() |> normalize_fn()

  defp normalize_fn({:fn, _, [{:->, _, [[{name, _, ctx} = var], body]}]})
       when is_atom(name) and is_atom(ctx), do: {:simple, var, body}

  defp normalize_fn({:fn, _, _}), do: :clauses
  defp normalize_fn(_), do: :other

  defp var_key({name, _, ctx}), do: {name, ctx}

  # Whether `var` appears in the body outside the values of Heddle.pure/1.
  defp used_in_codecs?(body, key) do
    body
    |> Macro.prewalk(fn
      {{:., m, [Heddle, :pure]}, cm, [_]} -> {{:., m, [Heddle, :pure]}, cm, [nil]}
      node -> node
    end)
    |> Compiler.vars_of()
    |> MapSet.member?(key)
  end

  defp finite_values(%Heddle{node: node}) do
    {max_values, _} = Compiler.finite_limits()

    values =
      case node do
        {:literal, a} ->
          [a]

        {:enum, atoms, :reject} ->
          atoms

        {:integer, lo, hi} when is_integer(lo) and is_integer(hi) and hi - lo < max_values ->
          Enum.to_list(lo..hi)

        {:refine, inner, _, _} ->
          finite_values(inner)

        {:from, inner, _} ->
          finite_values(inner)

        {:one_of, alts, _, _} ->
          alts |> Enum.map(&finite_values/1) |> combine()

        _ ->
          nil
      end

    if values && length(values) <= max_values, do: values, else: nil
  end

  defp combine(lists), do: if(Enum.all?(lists, &is_list/1), do: Enum.concat(lists), else: nil)

  defp meta_of({_, meta, _}) when is_list(meta), do: meta
  defp meta_of(_), do: []

  defp opaque(meta, text) do
    env = Compiler.env()
    span = Expr.span(meta, env)
    key = {:opaque, span}

    Compiler.warn_once(key, fn ->
      error = %CodecError{
        code: "W001",
        summary: "a bind runs in the interpreter",
        labels: [{%Heddle{node: nil, span: span}, text}],
        help: "make the dependency finite (an enum or a small range), or use it only as a bound"
      }

      Compiler.finding(Diagnostics.warn(error, env))
    end)
  end
end

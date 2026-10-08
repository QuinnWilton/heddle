defmodule Heddle.Compiler do
  @moduledoc false
  # Compiles codec IR to specialized function clauses.
  #
  # Each IR node becomes a private function following the decoder or encoder
  # convention in Heddle.Runtime. Literals compile to byte patterns; integers,
  # floats and binaries get inline fast paths; everything else, and every
  # failure, goes through the same Heddle.Runtime functions the interpreter
  # calls, so the two backends agree by construction.
  #
  # Sequences compile from the source of their continuations (binding-time
  # analysis): a step whose codec depends on no runtime value compiles once;
  # one that depends on a finite value expands into a case over its values;
  # one that uses runtime values only as bounds compiles once with those
  # values passed in a parameter tuple; anything else runs in the
  # interpreter and is reported as opaque.

  alias Heddle.{CodecError, ETF, IR}
  alias Heddle.Compiler.{Expr, Seq}
  alias Heddle.IR.{Field, FunRef, Param}

  @finite_values 64
  @finite_expansion 256

  defstruct [
    :module,
    :name,
    :env,
    defs: [],
    next: 0,
    lazies: %{},
    findings: [],
    warned: MapSet.new()
  ]

  @typedoc "How generated code calls a compiled codec."
  @type caller :: {:local, atom(), boolean()} | {:remote, module(), atom()}

  ## Entry point

  @doc """
  Compiles `codec` as the module's codec `name`.

  Returns the function definitions, plus the opaque-bind findings as
  pentiment reports.
  """
  @spec compile(Heddle.t(), atom(), Macro.Env.t()) :: {[Macro.t()], [Pentiment.Report.t()]}
  def compile(%Heddle{} = codec, name, env) do
    Process.put(:heddle_codegen, %__MODULE__{module: env.module, name: name, env: env})

    try do
      dec = dec(codec, nil)
      enc = enc(codec, nil)
      root_dec = root_dec(name)
      root_enc = root_enc(name)

      roots =
        quote do
          @doc false
          def unquote(root_dec)(rest, depth, nodes, lim), do: unquote(invoke_dec(dec, nil))

          @doc false
          def unquote(root_enc)(value, acc),
            do: unquote(invoke_enc(enc, quote(do: value), quote(do: acc)))
        end

      st = st()
      {Enum.reverse(st.defs) ++ [generated(roots)], Enum.reverse(st.findings)}
    after
      Process.delete(:heddle_codegen)
    end
  end

  @doc false
  @spec root_dec(atom()) :: atom()
  def root_dec(name), do: :"__heddle_dec_#{name}__"
  @doc false
  @spec root_enc(atom()) :: atom()
  def root_enc(name), do: :"__heddle_enc_#{name}__"

  defp st, do: Process.get(:heddle_codegen)
  defp put_st(fun), do: Process.put(:heddle_codegen, fun.(st()))

  defp fresh(kind) do
    s = st()
    put_st(&%{&1 | next: &1.next + 1})
    :"__heddle_#{s.name}_#{kind}#{s.next}__"
  end

  defp add_def(def_ast), do: put_st(&%{&1 | defs: [generated(def_ast) | &1.defs]})

  # Marks generated code, so the type checker does not warn about defensive
  # clauses a particular call site cannot reach.
  @doc false
  @spec generated(Macro.t()) :: Macro.t()
  def generated(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) -> {form, Keyword.put(meta, :generated, true), args}
      node -> node
    end)
  end

  ## Callers
  #
  # A caller names how to call a compiled codec: a local function (with or
  # without the parameter tuple) or another module's codec.

  defp invoke_dec({:local, name, false}, _pctx),
    do: quote(do: unquote(name)(rest, depth, nodes, lim))

  defp invoke_dec({:local, name, true}, _pctx),
    do: quote(do: unquote(name)(rest, depth, nodes, lim, ps))

  # Another module's codec is called through its root function directly,
  # skipping the __heddle_decode__/5 dispatch.
  defp invoke_dec({:remote, module, name}, _pctx),
    do: quote(do: unquote(module).unquote(root_dec(name))(rest, depth, nodes, lim))

  # Calls a decoder with explicit `rest` and `depth` arguments.
  defp call_at({:local, name, false}, rest_ast, depth_ast),
    do: quote(do: unquote(name)(unquote(rest_ast), unquote(depth_ast), nodes, lim))

  defp call_at({:local, name, true}, rest_ast, depth_ast),
    do: quote(do: unquote(name)(unquote(rest_ast), unquote(depth_ast), nodes, lim, ps))

  defp call_at({:remote, module, name}, rest_ast, depth_ast),
    do:
      quote(
        do:
          unquote(module).unquote(root_dec(name))(
            unquote(rest_ast),
            unquote(depth_ast),
            nodes,
            lim
          )
      )

  # Encoders append to an accumulator binary: encode(value, acc) returns
  # {:ok, decoded, acc} with the value's bytes appended. The BEAM appends to
  # a binary in place, so one growing binary beats nested iodata flattened
  # at the end.
  defp invoke_enc({:local, name, false}, value, acc),
    do: quote(do: unquote(name)(unquote(value), unquote(acc)))

  defp invoke_enc({:local, name, true}, value, acc),
    do: quote(do: unquote(name)(unquote(value), unquote(acc), ps))

  defp invoke_enc({:remote, module, name}, value, acc),
    do: quote(do: unquote(module).unquote(root_enc(name))(unquote(value), unquote(acc)))

  # An iodata-convention encoder over a compiled one, for the shared
  # Heddle.Runtime encoders the slow paths call.
  defp enc_capture(caller),
    do: quote(do: fn heddle_v -> unquote(invoke_enc(caller, quote(do: heddle_v), "")) end)

  # An accumulator-convention encoder as a two-argument function.
  defp enc_fun(caller),
    do:
      quote(
        do: fn heddle_v, heddle_acc ->
          unquote(invoke_enc(caller, quote(do: heddle_v), quote(do: heddle_acc)))
        end
      )

  defp dec_capture({:local, name, false}), do: local_capture(name, 4)
  defp dec_capture({:local, name, true}), do: quote(do: &unquote(name)(&1, &2, &3, &4, ps))

  defp dec_capture({:remote, module, name}),
    do: quote(do: &(unquote(module).unquote(root_dec(name)) / 4))

  defp local_capture(name, arity), do: {:&, [], [{:/, [], [{name, [], nil}, arity]}]}

  ## Function builders

  # A function over `args`, with unused arguments renamed to start with `_`.
  defp defp_ast(name, args, guard, body) do
    used = MapSet.union(vars_in([guard, body]), repeated_vars(args))
    args = Enum.map(args, &underscore_unused(&1, used))

    head = {name, [], args}
    head = if guard, do: {:when, [], [head, guard]}, else: head
    quote do: defp(unquote(head), do: unquote(body))
  end

  defp underscore_unused({:=, m, [pattern, {var, vm, ctx}]}, used) when is_atom(var) do
    if MapSet.member?(used, {var, ctx}), do: {:=, m, [pattern, {var, vm, ctx}]}, else: pattern
  end

  defp underscore_unused({var, m, ctx} = ast, used) when is_atom(var) and is_atom(ctx) do
    if MapSet.member?(used, {var, ctx}) or String.starts_with?(Atom.to_string(var), "_"),
      do: ast,
      else: {:"_#{var}", m, ctx}
  end

  defp underscore_unused(other, _used), do: other

  # Variables appearing more than once in a head match by equality, so they
  # count as used.
  defp repeated_vars(args) do
    args
    |> Enum.flat_map(fn
      {var, _, ctx} when is_atom(var) and is_atom(ctx) -> [{var, ctx}]
      _ -> []
    end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_, n} -> n > 1 end)
    |> MapSet.new(fn {key, _} -> key end)
  end

  defp vars_in(ast) do
    {_, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {var, _, ctx} = node, acc when is_atom(var) and is_atom(ctx) ->
          {node, MapSet.put(acc, {var, ctx})}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp args(pctx) do
    base = [quote(do: rest), quote(do: depth), quote(do: nodes), quote(do: lim)]
    if pctx, do: base ++ [quote(do: ps)], else: base
  end

  # A decoder that consumes a term: it checks depth and the node budget, in
  # the order Heddle.Runtime.enter/4 does, then runs `body` with `nodes`
  # already charged.
  defp consuming(pctx, body, fast \\ []) do
    name = fresh(:d)

    # Fast clauses come first: each is a complete special case of `body`,
    # with its limit checks as guards.
    Enum.each(fast, fn {args, guard, fast_body} ->
      add_def(defp_ast(name, args, guard, fast_body))
    end)

    guarded_args = [
      quote(do: <<rest::binary>>),
      quote(do: depth),
      quote(do: nodes),
      quote(do: {max_depth, _, _, _} = lim)
    ]

    guarded_args = if pctx, do: guarded_args ++ [quote(do: ps)], else: guarded_args
    guard = quote(do: depth <= max_depth and nodes > 0)

    full_body =
      quote do
        nodes = nodes - 1
        unquote(body)
      end

    add_def(defp_ast(name, guarded_args, guard, full_body))

    add_def(
      defp_ast(name, args(pctx), nil, quote(do: Heddle.Runtime.enter(rest, depth, nodes, lim)))
    )

    {:local, name, pctx != nil}
  end

  # A decoder that does not consume a term itself (a choice or a wrapper).
  defp wrapper(pctx, body) do
    name = fresh(:d)
    add_def(defp_ast(name, args(pctx), nil, body))
    {:local, name, pctx != nil}
  end

  defp encoder(pctx, clauses) do
    name = fresh(:e)

    Enum.each(clauses, fn {pattern, guard, body} ->
      args =
        if pctx, do: [pattern, quote(do: acc), quote(do: ps)], else: [pattern, quote(do: acc)]

      add_def(defp_ast(name, args, guard, body))
    end)

    {:local, name, pctx != nil}
  end

  ## Decoders

  defp dec(%Heddle{node: node} = codec, pctx) do
    pctx = if pctx && params?(codec), do: pctx, else: nil

    case node do
      {:from, inner, _} -> dec(inner, pctx)
      {:ref, module, name} -> ref_caller(module, name, :dec)
      {:lazy, _} -> lazy_caller(codec, :dec)
      _ -> dec_node(codec, node, pctx)
    end
  end

  defp ref_caller(module, name, kind) do
    s = st()

    if module == s.module do
      {:local, if(kind == :dec, do: root_dec(name), else: root_enc(name)), false}
    else
      check_remote!(module)
      {:remote, module, name}
    end
  end

  # A module named in a codec position must have a Heddle codec. Only a
  # module that is already available is checked: waiting for one still
  # compiling could deadlock structs that name each other, and a missing
  # codec there still surfaces as an undefined-function warning.
  defp check_remote!(module) do
    if Code.ensure_loaded?(module) and not function_exported?(module, :__heddle_summary__, 1) do
      raise CodecError,
        code: "H006",
        summary: "#{inspect(module)} has no Heddle codec",
        labels: [],
        help: "derive Heddle.Codec for the struct, or define its codec with Heddle.Schema"
    end

    :ok
  end

  defp lazy_caller(%Heddle{node: {:lazy, thunk}} = codec, kind) do
    key = {kind, lazy_key(thunk)}

    case st().lazies do
      %{^key => caller} ->
        caller

      _ ->
        forced = IR.force(codec)
        name = fresh(if kind == :dec, do: :l, else: :m)
        caller = {:local, name, false}
        put_st(&%{&1 | lazies: Map.put(&1.lazies, key, caller)})
        inner = if kind == :dec, do: dec(forced, nil), else: enc(forced, nil)

        if kind == :dec,
          do: add_def(defp_ast(name, args(nil), nil, invoke_dec(inner, nil))),
          else:
            add_def(
              defp_ast(
                name,
                [quote(do: value), quote(do: acc)],
                nil,
                invoke_enc(inner, quote(do: value), quote(do: acc))
              )
            )

        caller
    end
  end

  defp lazy_key(%FunRef{id: id, bindings: bindings}), do: {:funref, id, bindings}
  defp lazy_key(fun), do: {:fun, fun}

  defp dec_node(codec, {:literal, atom}, pctx) do
    expected = expected_ast(codec, pctx)

    consuming(
      pctx,
      atom_dispatch([atom], quote(do: Heddle.Runtime.atom_failure(rest, unquote(expected))))
    )
  end

  defp dec_node(codec, {:enum, atoms, :reject}, pctx) do
    expected = expected_ast(codec, pctx)

    consuming(
      pctx,
      atom_dispatch(atoms, quote(do: Heddle.Runtime.atom_failure(rest, unquote(expected))))
    )
  end

  defp dec_node(codec, {:enum, atoms, :keep}, pctx) do
    expected = expected_ast(codec, pctx)

    names = Macro.escape(Map.new(atoms, &{Atom.to_string(&1), &1}))

    fallback =
      quote(do: Heddle.Runtime.read_enum(rest, nodes, unquote(names), :keep, unquote(expected)))

    consuming(pctx, atom_dispatch(atoms, fallback))
  end

  defp dec_node(codec, :existing_atom, pctx) do
    expected = expected_ast(codec, pctx)

    consuming(
      pctx,
      quote(do: Heddle.Runtime.read_existing_atom(rest, nodes, unquote(expected)))
    )
  end

  defp dec_node(codec, {:integer, min, max}, pctx) do
    expected = expected_ast(codec, pctx)

    consuming(pctx, dec_integer(min, max, expected, pctx))
  end

  defp dec_node(codec, :char, pctx) do
    expected = expected_ast(codec, pctx)

    consuming(pctx, quote(do: Heddle.Runtime.read_char(rest, nodes, unquote(expected))))
  end

  defp dec_node(codec, :float, pctx) do
    expected = expected_ast(codec, pctx)

    consuming(
      pctx,
      quote do
        case rest do
          <<70, f::float-64, after_term::binary>> -> {:ok, f, after_term, nodes}
          _ -> Heddle.Runtime.read_float(rest, nodes, unquote(expected))
        end
      end
    )
  end

  defp dec_node(codec, {:binary, max, utf8}, pctx) do
    expected = expected_ast(codec, pctx)

    consuming(pctx, dec_binary(max, utf8, expected, pctx))
  end

  defp dec_node(codec, {:list, elem, max}, pctx) do
    expected = expected_ast(codec, pctx)

    dec_list(elem, max, expected, pctx)
  end

  defp dec_node(codec, {:tuple, elems}, pctx) do
    expected = expected_ast(codec, pctx)

    consuming(
      pctx,
      dec_tuple_body(elems, expected, pctx, fn tuple ->
        quote(do: {:ok, unquote(tuple), body, nodes})
      end),
      fused_tuple(elems, pctx, fn values -> {:{}, [], values} end)
    )
  end

  defp dec_node(codec, {:map, required, optional}, pctx) do
    expected = expected_ast(codec, pctx)

    named = required ++ optional
    required_keys = Enum.map(required, &elem(&1, 0))
    consuming(pctx, dec_keyed_map(named, required_keys, expected, pctx, quote(do: acc)))
  end

  defp dec_node(codec, {:struct, module, :map, fields}, pctx) do
    expected = expected_ast(codec, pctx)

    consuming(pctx, dec_struct_map(module, fields, expected, pctx))
  end

  defp dec_node(codec, {:struct, module, {:tuple, tag}, fields}, pctx) do
    expected = expected_ast(codec, pctx)

    codecs = Enum.map(fields, &elem(&1, 1))
    elems = if tag, do: [%Heddle{node: {:literal, tag}} | codecs], else: codecs
    names = Enum.map(fields, &elem(&1, 0))
    drop = if tag, do: 1, else: 0

    consuming(
      pctx,
      dec_tuple_body(elems, expected, pctx, fn tuple ->
        quote do
          unquote(tuple_vars_to_struct(module, names, tuple, drop))
          {:ok, struct, body, nodes}
        end
      end),
      fused_tuple(elems, pctx, fn values ->
        struct_literal(module, Enum.zip(names, Enum.drop(values, drop)))
      end)
    )
  end

  defp dec_node(codec, {:map_of, key, value, max}, pctx) do
    expected = expected_ast(codec, pctx)

    dec_map_of(key, value, max, expected, pctx)
  end

  defp dec_node(codec, {:one_of, alts, firsts, _}, pctx) do
    expected = expected_ast(codec, pctx)

    dec_one_of(alts, firsts, expected, pctx)
  end

  defp dec_node(_codec, {:iso, inner, decode, _}, pctx) do
    inner_caller = dec(inner, pctx)
    inner_expected = expected_ast(inner, pctx)

    wrapper(
      pctx,
      quote do
        case unquote(invoke_dec(inner_caller, pctx)) do
          {:ok, value, after_term, nodes} ->
            case Heddle.Runtime.call_iso(unquote(fun_ast(decode)), value) do
              {:ok, result} -> {:ok, result, after_term, nodes}
              :error -> Heddle.Runtime.fail(:iso, unquote(inner_expected), rest)
            end

          error ->
            error
        end
      end
    )
  end

  defp dec_node(_codec, {:refine, inner, pred, reason}, pctx) do
    inner_caller = dec(inner, pctx)
    inner_expected = expected_ast(inner, pctx)

    wrapper(
      pctx,
      quote do
        case unquote(invoke_dec(inner_caller, pctx)) do
          {:ok, value, after_term, nodes} ->
            if unquote(fun_ast(pred)).(value),
              do: {:ok, value, after_term, nodes},
              else:
                Heddle.Runtime.fail(
                  {:refine, unquote(escape!(reason))},
                  unquote(inner_expected),
                  rest
                )

          error ->
            error
        end
      end
    )
  end

  defp dec_node(codec, {:tuple_seq, tag, seq}, pctx) do
    Seq.dec(codec, tag, seq, pctx)
  end

  # A tuple whose elements are all leaves matches in one clause: header,
  # then each element's fast path, with the tuple's and every element's
  # limit checks as guards. Atoms use their usual spelling only and the
  # number of clauses is capped; anything else takes the general clause.
  defp fused_tuple(elems, nil, build) when elems != [] and length(elems) <= 255 do
    per_elem =
      elems
      |> Enum.with_index()
      |> Enum.map(fn {elem, i} ->
        alternatives =
          case elem do
            %Heddle{node: {:literal, atom}} -> [hd(inline_leaf_for_atom(atom))]
            %Heddle{node: {:enum, atoms, _}} -> Enum.map(atoms, &hd(inline_leaf_for_atom(&1)))
            _ -> inline_leaf(elem)
          end

        Enum.map(alternatives, fn {{:<<>>, _, segments}, guard, value} ->
          renames = %{x: :"heddle_x#{i}", len: :"heddle_len#{i}", rest: :rest}
          segments = rename_vars(segments, renames)
          {segments, rename_vars(guard, renames), rename_vars(copy_from_lim(value), renames)}
        end)
      end)

    count = Enum.reduce(per_elem, 1, &(length(&1) * &2))

    per_elem = if count > 32, do: Enum.map(per_elem, &Enum.take(&1, 1)), else: per_elem

    if Enum.any?(per_elem, &(&1 == [])) do
      []
    else
      arity = length(elems)

      for combo <- combinations(per_elem) do
        last = length(combo) - 1

        segments =
          combo
          |> Enum.with_index()
          |> Enum.flat_map(fn {{segs, _, _}, i} ->
            if i == last, do: segs, else: Enum.drop(segs, -1)
          end)

        guard =
          combo
          |> Enum.map(&elem(&1, 1))
          |> Enum.reduce(
            quote(do: depth + 1 <= elem(lim, 0) and nodes > unquote(arity)),
            &quote(do: unquote(&2) and unquote(&1))
          )

        values = Enum.map(combo, &elem(&1, 2))

        {[
           {:<<>>, [], [104, arity | segments]},
           quote(do: depth),
           quote(do: nodes),
           quote(do: lim)
         ], guard, quote(do: {:ok, unquote(build.(values)), rest, nodes - unquote(arity + 1)})}
      end
    end
  end

  defp fused_tuple(_elems, _pctx, _build), do: []

  defp inline_leaf_for_atom(atom), do: inline_leaf(%Heddle{node: {:literal, atom}})

  defp copy_from_lim(value) do
    Macro.prewalk(value, fn
      {:copy, _, ctx} when is_atom(ctx) -> quote(do: elem(lim, 2))
      node -> node
    end)
  end

  defp combinations([]), do: [[]]

  defp combinations([choices | rest]),
    do: for(c <- choices, tail <- combinations(rest), do: [c | tail])

  # The struct's fields and defaults. defschema expands its codec before
  # its defstruct runs, so it records them for the compiler first.
  defp struct_info!(module) do
    case Process.get({:heddle_struct_info, module}) do
      nil -> Macro.struct_info!(module, st().env)
      info -> info
    end
  end

  # Binds `struct` to the struct built from a decoded tuple's elements.
  defp tuple_vars_to_struct(module, names, {:{}, _, vars}, drop) do
    pairs = Enum.zip(names, Enum.drop(vars, drop))
    quote(do: struct = unquote(struct_literal(module, pairs)))
  end

  # The struct with `pairs` set and the struct's own defaults elsewhere, as
  # Heddle.Runtime.build_struct/3 fills them. It is a map literal rather than
  # %Module{}, which cannot expand while @derive runs inside defstruct.
  defp struct_literal(module, pairs) do
    defaults = module |> struct_info!() |> Enum.map(&{&1.field, escape!(&1.default)})

    given = Map.new(pairs)

    fields =
      Enum.map(defaults, fn {field, default} -> {field, Map.get(given, field, default)} end)

    {:%{}, [], [{:__struct__, module} | fields]}
  rescue
    _ -> quote(do: Map.merge(Kernel.struct(unquote(module)), unquote({:%{}, [], pairs})))
  end

  # A struct laid out as a map: the template holds the struct's defaults and
  # the codec's `default:` values, decoded fields replace them, and a bitmask
  # records which keys were seen for the duplicate and missing-key checks.
  defp dec_struct_map(module, fields, expected, pctx) do
    loop = fresh(:sm)

    entries = [
      {:__struct__, %Heddle{node: {:literal, module}}}
      | Enum.map(fields, fn {n, c, _} -> {n, c} end)
    ]

    bits =
      entries |> Enum.with_index() |> Map.new(fn {{key, _}, i} -> {key, Bitwise.bsl(1, i)} end)

    key_expected = Macro.escape(Enum.map(entries, &{:key, elem(&1, 0)}))
    required = [:__struct__ | for({n, _, :none} <- fields, do: n)]
    required_bits = Enum.map(required, &{&1, Map.fetch!(bits, &1)})
    required_mask = required_bits |> Enum.map(&elem(&1, 1)) |> Enum.reduce(0, &Bitwise.bor/2)
    template = struct_literal(module, for({n, _, {:ok, d}} <- fields, do: {n, escape!(d)}))
    loop_extra = if pctx, do: [quote(do: ps)], else: []

    # Each key's handler: the duplicate check, then the value's decoder.
    handlers =
      Map.new(entries, fn {key, codec} ->
        handler = fresh(:sk)
        bit = Map.fetch!(bits, key)
        caller = dec(codec, pctx)

        update =
          if key == :__struct__, do: quote(do: acc), else: quote(do: %{acc | unquote(key) => v})

        add_def(
          defp_ast(
            handler,
            [
              quote(do: rest),
              quote(do: after_key),
              quote(do: n),
              quote(do: depth),
              quote(do: nodes),
              quote(do: lim),
              quote(do: seen),
              quote(do: acc)
            ] ++ loop_extra,
            nil,
            quote do
              if Bitwise.band(seen, unquote(bit)) != 0 do
                Heddle.Runtime.fail(:duplicate_key, unquote(key_expected), rest)
              else
                case unquote(call_at(caller, quote(do: after_key), quote(do: depth))) do
                  {:ok, v, after_value, nodes} ->
                    unquote(loop)(
                      after_value,
                      n - 1,
                      depth,
                      nodes,
                      lim,
                      Bitwise.bor(seen, unquote(bit)),
                      unquote(update),
                      unquote_splicing(loop_extra)
                    )

                  error ->
                    Heddle.Runtime.prefix(error, unquote(key))
                end
              end
            end
          )
        )

        {key, handler}
      end)

    key_clauses =
      for {key, _codec} <- entries, spelling <- ETF.atom_spellings(key) do
        call =
          quote do
            unquote(Map.fetch!(handlers, key))(
              rest,
              after_key,
              n,
              depth,
              nodes,
              lim,
              seen,
              acc,
              unquote_splicing(loop_extra)
            )
          end

        {:->, [], [[pattern(spelling, quote(do: after_key))], call]}
      end

    dispatch =
      {:case, [],
       [
         quote(do: rest),
         [
           do:
             key_clauses ++
               [
                 {:->, [],
                  [
                    [quote(do: _)],
                    quote(do: Heddle.Runtime.key_failure(rest, unquote(key_expected)))
                  ]}
               ]
         ]
       ]}

    # A key followed by a leaf value matches in one pattern: the key's and
    # the value's limit checks, the duplicate check and the value's fast
    # path are all guards, so the binary stays a match context. Anything
    # else falls to the general clause below.
    if pctx == nil do
      for {key, codec} <- entries,
          spelling <- ETF.atom_spellings(key),
          {segments, guard, value, check} <- fused_leaf(codec) do
        bit = Map.fetch!(bits, key)

        update =
          if key == :__struct__,
            do: quote(do: acc),
            else: quote(do: %{acc | unquote(key) => unquote(value)})

        head = {:<<>>, [], :binary.bin_to_list(spelling) ++ segments}

        continue =
          quote do
            unquote(loop)(
              rest,
              n - 1,
              depth,
              nodes - 2,
              lim,
              Bitwise.bor(seen, unquote(bit)),
              unquote(update)
            )
          end

        # A value whose fast path needs a check guards cannot express (UTF-8)
        # falls back to the key's handler when the check fails.
        body =
          case check do
            nil ->
              continue

            check ->
              quote do
                if unquote(check) do
                  unquote(continue)
                else
                  <<_::binary-size(unquote(byte_size(spelling))), after_key::binary>> = whole

                  unquote(Map.fetch!(handlers, key))(
                    whole,
                    after_key,
                    n,
                    depth,
                    nodes - 1,
                    lim,
                    seen,
                    acc
                  )
                end
              end
          end

        add_def(
          defp_ast(
            loop,
            [
              if(check, do: quote(do: unquote(head) = whole), else: head),
              quote(do: n),
              quote(do: depth),
              quote(do: nodes),
              quote(do: lim),
              quote(do: seen),
              quote(do: acc)
            ],
            quote do
              n > 0 and nodes >= 2 and depth <= elem(lim, 0) and
                Bitwise.band(seen, unquote(bit)) == 0 and
                unquote(guard)
            end,
            body
          )
        )
      end
    end

    # The finishing clause comes after the fused ones, so they keep the
    # binary a match context.
    add_def(
      defp_ast(
        loop,
        [
          quote(do: <<rest::binary>>),
          0,
          quote(do: depth),
          quote(do: nodes),
          quote(do: lim),
          quote(do: seen),
          quote(do: acc)
        ] ++ loop_extra,
        nil,
        quote(do: {:ok, acc, seen, rest, nodes})
      )
    )

    add_def(
      defp_ast(
        loop,
        [
          quote(do: <<rest::binary>>),
          quote(do: n),
          quote(do: depth),
          quote(do: nodes),
          quote(do: lim),
          quote(do: seen),
          quote(do: acc)
        ] ++ loop_extra,
        quote(do: depth <= elem(lim, 0) and nodes > 0),
        quote do
          nodes = nodes - 1
          unquote(dispatch)
        end
      )
    )

    add_def(
      defp_ast(
        loop,
        [
          quote(do: <<rest::binary>>),
          quote(do: _n),
          quote(do: depth),
          quote(do: nodes),
          quote(do: lim),
          quote(do: _seen),
          quote(do: _acc)
        ] ++ loop_extra,
        nil,
        quote(do: Heddle.Runtime.enter(rest, depth, nodes, lim))
      )
    )

    count = length(entries)

    quote do
      case rest do
        <<116, n::32, body::binary>> ->
          with :ok <-
                 Heddle.Runtime.check_count(
                   n,
                   unquote(count),
                   {2, byte_size(body)},
                   2,
                   nodes,
                   unquote(expected),
                   rest,
                   lim
                 ),
               {:ok, acc, seen, after_term, nodes} <-
                 unquote(loop)(
                   body,
                   n,
                   depth + 1,
                   nodes,
                   lim,
                   0,
                   unquote(template),
                   unquote_splicing(loop_extra)
                 ) do
            if Bitwise.band(seen, unquote(required_mask)) == unquote(required_mask),
              do: {:ok, acc, after_term, nodes},
              else: Heddle.Runtime.missing_mask(seen, unquote(required_bits), rest)
          end

        <<116, _::binary>> ->
          Heddle.Runtime.fail(:unexpected_eof, unquote(expected), rest)

        _ ->
          Heddle.Runtime.fail(:unexpected, unquote(expected), rest)
      end
    end
  end

  # Clauses matching each atom's spellings, then `fallback`.
  defp atom_dispatch(atoms, fallback) do
    clauses =
      for atom <- atoms, spelling <- ETF.atom_spellings(atom) do
        {:->, [],
         [
           [pattern(spelling, quote(do: after_term))],
           quote(do: {:ok, unquote(atom), after_term, nodes})
         ]}
      end

    {:case, [], [quote(do: rest), [do: clauses ++ [{:->, [], [[quote(do: _)], fallback]}]]]}
  end

  # A binary pattern matching `bytes` followed by the rest as `tail`.
  defp pattern(bytes, tail) do
    {:<<>>, [], :binary.bin_to_list(bytes) ++ [quote(do: unquote(tail) :: binary)]}
  end

  defp prefix_pattern(bytes), do: pattern(bytes, quote(do: _))

  defp dec_integer(min, max, expected, pctx) do
    min_ast = bound_ast(min, pctx)
    max_ast = bound_ast(max, pctx)
    guard = fn var -> range_guard(var, min, max, min_ast, max_ast) end

    quote do
      case rest do
        <<97, i, after_term::binary>> when unquote(guard.(quote(do: i))) ->
          {:ok, i, after_term, nodes}

        <<98, i::signed-32, after_term::binary>> when unquote(guard.(quote(do: i))) ->
          {:ok, i, after_term, nodes}

        _ ->
          Heddle.Runtime.read_integer(
            rest,
            nodes,
            unquote(min_ast),
            unquote(max_ast),
            unquote(expected)
          )
      end
    end
  end

  defp range_guard(var, min, max, min_ast, max_ast) do
    lower = if min == nil, do: true, else: quote(do: unquote(var) >= unquote(min_ast))
    upper = if max == nil, do: true, else: quote(do: unquote(var) <= unquote(max_ast))
    quote(do: unquote(lower) and unquote(upper))
  end

  defp dec_binary(max, utf8, expected, pctx) do
    max_ast = bound_ast(max, pctx)
    size_guard = if max == nil, do: true, else: quote(do: len <= unquote(max_ast))

    slow =
      quote(
        do:
          Heddle.Runtime.read_binary(
            rest,
            nodes,
            unquote(max_ast),
            unquote(utf8),
            unquote(expected),
            lim
          )
      )

    ok =
      quote do
        {:ok, if(elem(lim, 2), do: :binary.copy(bin), else: bin), after_term, nodes}
      end

    ok =
      if utf8,
        do: quote(do: if(Heddle.SWAR.utf8?(bin), do: unquote(ok), else: unquote(slow))),
        else: ok

    quote do
      case rest do
        <<109, len::32, bin::binary-size(len), after_term::binary>> when unquote(size_guard) ->
          unquote(ok)

        _ ->
          unquote(slow)
      end
    end
  end

  defp dec_list(elem, max, expected, pctx) do
    elem_caller = dec(elem, pctx)
    max_ast = bound_ast(max, pctx)
    list_loop = fresh(:ll)
    string_loop = fresh(:sl)
    loop_extra = if pctx, do: [quote(do: ps)], else: []

    define_list_loop(list_loop, elem_caller, pctx, loop_extra)

    slow_entry =
      quote(
        do:
          unquote(list_loop)(body, n, 0, depth + 1, nodes, lim, [], unquote_splicing(loop_extra))
      )

    list_entry =
      if pctx == nil and inline_leaf(elem) != [] do
        fast_loop = fresh(:lf)
        define_fast_list_loop(fast_loop, elem, elem_caller)

        quote do
          if depth + 1 <= elem(lim, 0),
            do: unquote(fast_loop)(body, n, nodes, {n, depth + 1, lim}, []),
            else: unquote(slow_entry)
        end
      else
        slow_entry
      end

    define_string_loop(string_loop, elem_caller, loop_extra)
    string_body = string_body(elem, string_loop, loop_extra)

    consuming(
      pctx,
      quote do
        case rest do
          <<106, after_term::binary>> ->
            {:ok, [], after_term, nodes}

          <<107, len::16, body::binary>> ->
            case Heddle.Runtime.check_count(
                   len,
                   unquote(max_ast),
                   {1, byte_size(body)},
                   1,
                   nodes,
                   unquote(expected),
                   rest,
                   lim
                 ) do
              :ok -> unquote(string_body)
              error -> error
            end

          <<108, n::32, body::binary>> ->
            case Heddle.Runtime.check_count(
                   n,
                   unquote(max_ast),
                   {1, byte_size(body) - 1},
                   1,
                   nodes,
                   unquote(expected),
                   rest,
                   lim
                 ) do
              :ok ->
                unquote(list_entry)

              error ->
                error
            end

          <<tag, _::binary>> when tag in [107, 108] ->
            Heddle.Runtime.fail(:unexpected_eof, unquote(expected), rest)

          _ ->
            Heddle.Runtime.fail(:unexpected, unquote(expected), rest)
        end
      end
    )
  end

  defp define_list_loop(list_loop, elem_caller, pctx, loop_extra) do
    # LIST_EXT: n elements, then the tail.
    add_def(
      defp_ast(
        list_loop,
        [
          quote(do: <<rest::binary>>),
          quote(do: n),
          quote(do: n),
          quote(do: depth),
          quote(do: nodes),
          quote(do: lim),
          quote(do: acc)
        ] ++ loop_extra,
        nil,
        quote(do: Heddle.Runtime.list_tail(rest, acc, nodes))
      )
    )

    add_def(
      defp_ast(
        list_loop,
        [
          quote(do: <<rest::binary>>),
          quote(do: n),
          quote(do: i),
          quote(do: depth),
          quote(do: nodes),
          quote(do: lim),
          quote(do: acc)
        ] ++ loop_extra,
        nil,
        quote do
          case unquote(invoke_dec(elem_caller, pctx)) do
            {:ok, v, rest, nodes} ->
              unquote(list_loop)(
                rest,
                n,
                i + 1,
                depth,
                nodes,
                lim,
                [v | acc],
                unquote_splicing(loop_extra)
              )

            error ->
              Heddle.Runtime.prefix(error, i)
          end
        end
      )
    )
  end

  # The loop for leaf elements once the elements' depth is known to fit:
  # every element then takes exactly one node, and the up-front count check
  # guarantees there are enough, so leaf clauses need no limit guards. They
  # match in the loop's head, keeping the binary a match context; anything
  # else goes through the element decoder, which checks for itself.
  defp define_fast_list_loop(fast_loop, elem, elem_caller) do
    # Arguments: the binary, the elements left, the node budget, a context
    # {n, depth, lim} the leaf clauses never unpack, and the accumulator.
    # The finishing clause comes after the leaf clauses: a first clause that
    # hands the binary to another module would cost a sub-binary per element.
    for {pattern, guard, value} <- inline_leaf(elem) do
      value =
        Macro.prewalk(value, fn
          {:copy, _, ctx} when is_atom(ctx) -> quote(do: elem(elem(context, 2), 2))
          node -> node
        end)

      add_def(
        defp_ast(
          fast_loop,
          [pattern, quote(do: left), quote(do: nodes), quote(do: context), quote(do: acc)],
          quote(do: left > 0 and unquote(guard)),
          quote(
            do: unquote(fast_loop)(rest, left - 1, nodes - 1, context, [unquote(value) | acc])
          )
        )
      )
    end

    add_def(
      defp_ast(
        fast_loop,
        [quote(do: <<rest::binary>>), 0, quote(do: nodes), quote(do: _context), quote(do: acc)],
        nil,
        quote(do: Heddle.Runtime.list_tail(rest, acc, nodes))
      )
    )

    add_def(
      defp_ast(
        fast_loop,
        [
          quote(do: <<rest::binary>>),
          quote(do: left),
          quote(do: nodes),
          quote(do: {n, depth, lim} = context),
          quote(do: acc)
        ],
        nil,
        quote do
          case unquote(invoke_dec(elem_caller, nil)) do
            {:ok, v, rest, nodes} -> unquote(fast_loop)(rest, left - 1, nodes, context, [v | acc])
            error -> Heddle.Runtime.prefix(error, n - left)
          end
        end
      )
    )
  end

  defp define_string_loop(string_loop, elem_caller, loop_extra) do
    # STRING_EXT: each byte as a SMALL_INTEGER_EXT.
    add_def(
      defp_ast(
        string_loop,
        [
          quote(do: <<rest::binary>>),
          quote(do: len),
          quote(do: len),
          quote(do: _size),
          quote(do: _depth),
          quote(do: nodes),
          quote(do: _lim),
          quote(do: acc)
        ] ++ loop_extra,
        nil,
        quote(do: {:ok, :lists.reverse(acc), rest, nodes})
      )
    )

    add_def(
      defp_ast(
        string_loop,
        [
          quote(do: <<byte, rest::binary>>),
          quote(do: len),
          quote(do: i),
          quote(do: size),
          quote(do: depth),
          quote(do: nodes),
          quote(do: lim),
          quote(do: acc)
        ] ++
          loop_extra,
        nil,
        quote do
          case Heddle.Runtime.string_byte(
                 byte,
                 size - i,
                 unquote(dec_capture(elem_caller)),
                 depth,
                 nodes,
                 lim
               ) do
            {:ok, v, _, nodes} ->
              unquote(string_loop)(
                rest,
                len,
                i + 1,
                size,
                depth,
                nodes,
                lim,
                [v | acc],
                unquote_splicing(loop_extra)
              )

            error ->
              Heddle.Runtime.prefix(error, i)
          end
        end
      )
    )
  end

  defp string_body(elem, string_loop, loop_extra) do
    generic =
      quote(
        do:
          unquote(string_loop)(
            body,
            len,
            0,
            byte_size(body),
            depth + 1,
            nodes,
            lim,
            [],
            unquote_splicing(loop_extra)
          )
      )

    # When every byte the string can hold is a valid element (or a SWAR scan
    # shows these bytes are), the list is the bytes themselves; only the
    # depth check can still fail, at the first element, which the loop
    # reports.
    fast =
      quote(
        do:
          {:ok, :binary.bin_to_list(binary_part(body, 0, len)),
           binary_part(body, len, byte_size(body) - len), nodes - len}
      )

    case string_elements(elem) do
      :all ->
        quote(
          do: if(len == 0 or depth + 1 <= elem(lim, 0), do: unquote(fast), else: unquote(generic))
        )

      {:range, lo, hi} ->
        quote do
          if (len == 0 or depth + 1 <= elem(lim, 0)) and
               Heddle.SWAR.bytes_in?(binary_part(body, 0, len), unquote(lo), unquote(hi)),
             do: unquote(fast),
             else: unquote(generic)
        end

      nil ->
        generic
    end
  end

  # Head patterns for leaf elements, each {pattern, guard, value}: special
  # cases of the element decoder's success path, with `rest` the remainder.
  defp inline_leaf(%Heddle{node: node}) do
    tail = quote(do: rest)

    case node do
      {:integer, min, max} ->
        [
          {quote(do: <<97, x, rest::binary>>), range_guard(quote(do: x), min, max, min, max),
           quote(do: x)},
          {quote(do: <<98, x::signed-32, rest::binary>>),
           range_guard(quote(do: x), min, max, min, max), quote(do: x)}
        ]

      {:literal, atom} ->
        for spelling <- ETF.atom_spellings(atom), do: {pattern(spelling, tail), true, atom}

      {:enum, atoms, _} ->
        for atom <- atoms,
            spelling <- ETF.atom_spellings(atom),
            do: {pattern(spelling, tail), true, atom}

      :float ->
        [{quote(do: <<70, x::float-64, rest::binary>>), true, quote(do: x)}]

      {:binary, max, false} ->
        guard = if max == nil, do: true, else: quote(do: len <= unquote(max))

        [
          {quote(do: <<109, len::32, x::binary-size(len), rest::binary>>), guard,
           quote(do: if(copy, do: :binary.copy(x), else: x))}
        ]

      _ ->
        []
    end
  end

  # A leaf's fast path as binary segments ending in `rest::binary`, with its
  # guard, its value and an optional check guards cannot express, for
  # fusing into a map key's clause. `lim` is in scope; nothing else is.
  defp fused_leaf(%Heddle{node: {:binary, max, true}}) do
    guard = if max == nil, do: true, else: quote(do: len <= unquote(max))

    [
      {[109, quote(do: len :: 32), quote(do: x :: binary - size(len)), quote(do: rest :: binary)],
       guard, quote(do: if(elem(lim, 2), do: :binary.copy(x), else: x)),
       quote(do: Heddle.SWAR.utf8?(x))}
    ]
  end

  defp fused_leaf(codec) do
    for {{:<<>>, _, segments}, guard, value} <- inline_leaf(codec) do
      value =
        Macro.prewalk(value, fn
          {:copy, _, ctx} when is_atom(ctx) -> quote(do: elem(lim, 2))
          node -> node
        end)

      {segments, guard, value, nil}
    end
  end

  # Which STRING_EXT bytes are elements as they are: all of them, a range
  # (checked with a SWAR scan), or nil when the element codec is not a plain
  # integer range.
  defp string_elements(%Heddle{node: :char}), do: :all

  defp string_elements(%Heddle{node: {:integer, min, max}})
       when (is_integer(min) or is_nil(min)) and (is_integer(max) or is_nil(max)) do
    lo = max(min || 0, 0)
    hi = min(max || 255, 255)

    cond do
      lo == 0 and hi == 255 -> :all
      lo <= hi -> {:range, lo, hi}
      true -> nil
    end
  end

  defp string_elements(_), do: nil

  # The body of a tuple decoder: header, then each element at depth + 1.
  defp dec_tuple_body(elems, expected, pctx, finish) do
    arity = length(elems)
    callers = Enum.map(elems, &dec(&1, pctx))
    vars = for i <- 0..(arity - 1)//1, do: Macro.var(:"v#{i}", __MODULE__)
    tuple = {:{}, [], vars}

    chain =
      callers
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.reduce(finish.(tuple), fn {caller, i}, acc ->
        var = Enum.at(vars, i)

        quote do
          case unquote(call_at(caller, quote(do: body), quote(do: depth + 1))) do
            {:ok, unquote(var), body, nodes} -> unquote(acc)
            error -> Heddle.Runtime.prefix(error, unquote(i))
          end
        end
      end)

    small =
      if arity <= 255,
        do: [{:->, [], [[quote(do: <<104, unquote(arity), body::binary>>)], chain]}],
        else: []

    clauses =
      small ++
        [
          {:->, [], [[quote(do: <<105, unquote(arity)::32, body::binary>>)], chain]},
          {:->, [],
           [[quote(do: _)], quote(do: Heddle.Runtime.tuple_failure(rest, unquote(expected)))]}
        ]

    {:case, [], [quote(do: rest), [do: clauses]]}
  end

  defp dec_keyed_map(named, required, expected, pctx, build) do
    loop = fresh(:ml)
    key_expected = Macro.escape(Enum.map(named, &{:key, elem(&1, 0)}))
    loop_extra = if pctx, do: [quote(do: ps)], else: []

    key_clauses =
      for {key, codec} <- named, caller = dec(codec, pctx), spelling <- ETF.atom_spellings(key) do
        body =
          quote do
            if is_map_key(acc, unquote(key)) do
              Heddle.Runtime.fail(:duplicate_key, unquote(key_expected), rest)
            else
              case unquote(call_at(caller, quote(do: after_key), quote(do: depth))) do
                {:ok, v, after_value, nodes} ->
                  unquote(loop)(
                    after_value,
                    n - 1,
                    depth,
                    nodes,
                    lim,
                    Map.put(acc, unquote(key), v),
                    unquote_splicing(loop_extra)
                  )

                error ->
                  Heddle.Runtime.prefix(error, unquote(key))
              end
            end
          end

        {:->, [], [[pattern(spelling, quote(do: after_key))], body]}
      end

    dispatch =
      {:case, [],
       [
         quote(do: rest),
         [
           do:
             key_clauses ++
               [
                 {:->, [],
                  [
                    [quote(do: _)],
                    quote(do: Heddle.Runtime.key_failure(rest, unquote(key_expected)))
                  ]}
               ]
         ]
       ]}

    add_def(
      defp_ast(
        loop,
        [
          quote(do: <<rest::binary>>),
          0,
          quote(do: depth),
          quote(do: nodes),
          quote(do: lim),
          quote(do: acc)
        ] ++
          loop_extra,
        nil,
        quote(do: {:ok, acc, rest, nodes})
      )
    )

    add_def(
      defp_ast(
        loop,
        [
          quote(do: <<rest::binary>>),
          quote(do: n),
          quote(do: depth),
          quote(do: nodes),
          quote(do: lim),
          quote(do: acc)
        ] ++ loop_extra,
        nil,
        quote do
          case Heddle.Runtime.enter(rest, depth, nodes, lim) do
            {:ok, nodes} -> unquote(dispatch)
            error -> error
          end
        end
      )
    )

    count = length(named)

    quote do
      case rest do
        <<116, n::32, body::binary>> ->
          with :ok <-
                 Heddle.Runtime.check_count(
                   n,
                   unquote(count),
                   {2, byte_size(body)},
                   2,
                   nodes,
                   unquote(expected),
                   rest,
                   lim
                 ),
               {:ok, acc, after_term, nodes} <-
                 unquote(loop)(body, n, depth + 1, nodes, lim, %{}, unquote_splicing(loop_extra)),
               :ok <- Heddle.Runtime.missing(unquote(required), acc, rest) do
            {:ok, unquote(build), after_term, nodes}
          end

        <<116, _::binary>> ->
          Heddle.Runtime.fail(:unexpected_eof, unquote(expected), rest)

        _ ->
          Heddle.Runtime.fail(:unexpected, unquote(expected), rest)
      end
    end
  end

  defp dec_map_of(key, value, max, expected, pctx) do
    key_caller = dec(key, pctx)
    value_caller = dec(value, pctx)
    key_expected = expected_ast(key, pctx)
    max_ast = bound_ast(max, pctx)
    loop = fresh(:mo)
    pair = fresh(:mp)
    loop_extra = if pctx, do: [quote(do: ps)], else: []

    args = [
      quote(do: <<rest::binary>>),
      quote(do: n),
      quote(do: i),
      quote(do: depth),
      quote(do: nodes),
      quote(do: lim),
      quote(do: acc)
    ]

    # One pair through the key's and the value's decoders, with the
    # :__struct__ and duplicate checks between them.
    add_def(
      defp_ast(
        pair,
        args ++ loop_extra,
        nil,
        quote do
          case unquote(invoke_dec(key_caller, pctx)) do
            {:ok, key, after_key, nodes} ->
              case Heddle.Runtime.check_map_key(key, acc, unquote(key_expected), rest) do
                :ok ->
                  case unquote(call_at(value_caller, quote(do: after_key), quote(do: depth))) do
                    {:ok, v, after_value, nodes} ->
                      unquote(loop)(
                        after_value,
                        n - 1,
                        i + 1,
                        depth,
                        nodes,
                        lim,
                        Map.put(acc, key, v),
                        unquote_splicing(loop_extra)
                      )

                    error ->
                      Heddle.Runtime.prefix(error, key)
                  end

                error ->
                  error
              end

            error ->
              Heddle.Runtime.prefix(error, {:key, i})
          end
        end
      )
    )

    # A leaf key followed by a leaf value matches in one pattern, with every
    # check as a guard; anything else goes through the pair function.
    if pctx == nil do
      for {kseg, kguard, kvalue, nil} <- fused_leaf(key),
          {vseg, vguard, vvalue, nil} <- fused_leaf(value) do
        kseg = kseg |> Enum.drop(-1) |> rename_vars(%{x: :k, len: :klen})
        vseg = rename_vars(vseg, %{x: :v, len: :vlen})

        {kguard, kvalue} =
          {rename_vars(kguard, %{x: :k, len: :klen}), rename_vars(kvalue, %{x: :k, len: :klen})}

        {vguard, vvalue} =
          {rename_vars(vguard, %{x: :v, len: :vlen}), rename_vars(vvalue, %{x: :v, len: :vlen})}

        key_value = Macro.var(:key, __MODULE__)

        # The checks compare the key's bytes, before any copy.
        guard_key =
          Macro.prewalk(kvalue, fn
            {:if, _, [_, [do: _, else: raw]]} -> raw
            node -> node
          end)

        add_def(
          defp_ast(
            loop,
            [
              {:<<>>, [], kseg ++ vseg},
              quote(do: n),
              quote(do: i),
              quote(do: depth),
              quote(do: nodes),
              quote(do: lim),
              quote(do: acc)
            ],
            quote do
              n > 0 and nodes >= 2 and depth <= elem(lim, 0) and unquote(kguard) and
                unquote(vguard) and
                unquote(guard_key) != :__struct__ and not is_map_key(acc, unquote(guard_key))
            end,
            quote do
              unquote(key_value) = unquote(kvalue)

              unquote(loop)(
                rest,
                n - 1,
                i + 1,
                depth,
                nodes - 2,
                lim,
                Map.put(acc, unquote(key_value), unquote(vvalue))
              )
            end
          )
        )
      end
    end

    add_def(
      defp_ast(
        loop,
        [
          quote(do: <<rest::binary>>),
          0,
          quote(do: _i),
          quote(do: _depth),
          quote(do: nodes),
          quote(do: _lim),
          quote(do: acc)
        ] ++
          loop_extra,
        nil,
        quote(do: {:ok, acc, rest, nodes})
      )
    )

    add_def(
      defp_ast(
        loop,
        args ++ loop_extra,
        nil,
        quote(do: unquote(pair)(rest, n, i, depth, nodes, lim, acc, unquote_splicing(loop_extra)))
      )
    )

    consuming(
      pctx,
      quote do
        case rest do
          <<116, n::32, body::binary>> ->
            case Heddle.Runtime.check_count(
                   n,
                   unquote(max_ast),
                   {2, byte_size(body)},
                   2,
                   nodes,
                   unquote(expected),
                   rest,
                   lim
                 ) do
              :ok ->
                unquote(loop)(
                  body,
                  n,
                  0,
                  depth + 1,
                  nodes,
                  lim,
                  %{},
                  unquote_splicing(loop_extra)
                )

              error ->
                error
            end

          <<116, _::binary>> ->
            Heddle.Runtime.fail(:unexpected_eof, unquote(expected), rest)

          _ ->
            Heddle.Runtime.fail(:unexpected, unquote(expected), rest)
        end
      end
    )
  end

  defp rename_vars(ast, renames) do
    Macro.prewalk(ast, fn
      {name, meta, ctx} = var when is_atom(name) and is_atom(ctx) ->
        case renames do
          %{^name => new} -> {new, meta, ctx}
          _ -> var
        end

      node ->
        node
    end)
  end

  defp dec_one_of(alts, firsts, expected, pctx) do
    clauses =
      alts
      |> Enum.zip(firsts)
      |> Enum.flat_map(fn {alt, items} ->
        caller = dec(alt, pctx)
        call = invoke_dec(caller, pctx)
        for pattern <- Enum.flat_map(items, &first_patterns/1), do: {:->, [], [[pattern], call]}
      end)

    fallback =
      {:->, [],
       [[quote(do: _)], quote(do: Heddle.Runtime.fail(:unexpected, unquote(expected), rest))]}

    wrapper(pctx, {:case, [], [quote(do: rest), [do: clauses ++ [fallback]]]})
  end

  # Byte patterns equivalent to IR.first_matches?/2 over ETF.classify/1.
  defp first_patterns({:atom, atom}), do: Enum.map(ETF.atom_spellings(atom), &prefix_pattern/1)
  defp first_patterns(:any_atom), do: tag_patterns(ETF.atom_tags())
  defp first_patterns(:integer), do: tag_patterns(ETF.integer_tags())
  defp first_patterns(:float), do: tag_patterns([70])
  defp first_patterns(:binary), do: tag_patterns([109])
  defp first_patterns(:list), do: tag_patterns(ETF.list_tags())
  defp first_patterns(:map), do: tag_patterns([116])

  defp first_patterns({:tuple, arity, tag}) do
    heads =
      case arity do
        :any -> [<<104>>, {:large, nil}]
        n when n <= 255 -> [<<104, n>>, {:large, n}]
        n -> [{:large, n}]
      end

    spellings = if tag == :any, do: [<<>>], else: ETF.atom_spellings(tag)

    for head <- heads, spelling <- spellings do
      case head do
        <<104>> ->
          {:<<>>, [],
           [104, quote(do: _)] ++ :binary.bin_to_list(spelling) ++ [quote(do: _ :: binary)]}

        {:large, nil} ->
          {:<<>>, [],
           [105, quote(do: _ :: 32)] ++ :binary.bin_to_list(spelling) ++ [quote(do: _ :: binary)]}

        {:large, n} ->
          {:<<>>, [],
           [105, quote(do: unquote(n) :: 32)] ++
             :binary.bin_to_list(spelling) ++ [quote(do: _ :: binary)]}

        bytes ->
          prefix_pattern(bytes <> spelling)
      end
    end
  end

  defp tag_patterns(tags), do: Enum.map(tags, &prefix_pattern(<<&1>>))

  ## Encoders

  defp enc(%Heddle{node: node} = codec, pctx) do
    pctx = if pctx && params?(codec), do: pctx, else: nil

    case node do
      {:ref, module, name} -> ref_caller(module, name, :enc)
      {:lazy, _} -> lazy_caller(codec, :enc)
      _ -> enc_node(node, codec, pctx)
    end
  end

  # The result of a Heddle.Runtime encoder (iodata), appended to `acc`.
  defp lift(call), do: quote(do: Heddle.Runtime.lift(unquote(call), acc))

  defp enc_node({:literal, atom}, _codec, pctx) do
    encoder(pctx, [
      {quote(do: value), quote(do: value === unquote(atom)),
       quote(do: {:ok, unquote(atom), <<acc::binary, unquote(ETF.encode_atom(atom))::binary>>})},
      {quote(do: value), nil, quote(do: {:error, {[], {:type, {:atom, unquote(atom)}, value}}})}
    ])
  end

  defp enc_node({:enum, atoms, unknown}, _codec, pctx) do
    members =
      for atom <- atoms do
        {quote(do: value), quote(do: value === unquote(atom)),
         quote(do: {:ok, unquote(atom), <<acc::binary, unquote(ETF.encode_atom(atom))::binary>>})}
      end

    encoder(
      pctx,
      members ++
        [
          {quote(do: value), nil,
           lift(quote(do: Heddle.Runtime.enc_enum(value, unquote(atoms), unquote(unknown))))}
        ]
    )
  end

  defp enc_node(:existing_atom, _codec, pctx) do
    encoder(pctx, [
      {quote(do: value), nil, lift(quote(do: Heddle.Runtime.enc_existing_atom(value)))}
    ])
  end

  defp enc_node({:integer, min, max}, _codec, pctx) do
    min_ast = bound_ast(min, pctx)
    max_ast = bound_ast(max, pctx)
    range = range_guard(quote(do: value), min, max, min_ast, max_ast)

    encoder(pctx, [
      {quote(do: value),
       quote(do: is_integer(value) and value >= 0 and value <= 255 and unquote(range)),
       quote(do: {:ok, value, <<acc::binary, 97, value>>})},
      {quote(do: value),
       quote(
         do:
           is_integer(value) and value >= -2_147_483_648 and value <= 2_147_483_647 and
             unquote(range)
       ), quote(do: {:ok, value, <<acc::binary, 98, value::signed-32>>})},
      {quote(do: value), nil,
       lift(quote(do: Heddle.Runtime.enc_integer(value, unquote(min_ast), unquote(max_ast))))}
    ])
  end

  defp enc_node(:char, _codec, pctx) do
    encoder(pctx, [
      {quote(do: value), quote(do: is_integer(value) and value >= 0 and value <= 255),
       quote(do: {:ok, value, <<acc::binary, 97, value>>})},
      {quote(do: value), nil, lift(quote(do: Heddle.Runtime.enc_char(value)))}
    ])
  end

  defp enc_node(:float, _codec, pctx) do
    encoder(pctx, [
      {quote(do: value), quote(do: is_float(value)),
       quote(do: {:ok, value, <<acc::binary, 70, value::float-64>>})},
      {quote(do: value), nil, lift(quote(do: Heddle.Runtime.enc_float(value)))}
    ])
  end

  defp enc_node({:binary, max, utf8}, _codec, pctx) do
    max_ast = bound_ast(max, pctx)
    size_guard = if max == nil, do: true, else: quote(do: byte_size(value) <= unquote(max_ast))
    slow = lift(quote(do: Heddle.Runtime.enc_binary(value, unquote(max_ast), unquote(utf8))))
    ok = quote(do: {:ok, value, <<acc::binary, 109, byte_size(value)::32, value::binary>>})

    ok =
      if utf8,
        do: quote(do: if(Heddle.SWAR.utf8?(value), do: unquote(ok), else: unquote(slow))),
        else: ok

    encoder(pctx, [
      {quote(do: value), quote(do: is_binary(value) and unquote(size_guard)), ok},
      {quote(do: value), nil, slow}
    ])
  end

  defp enc_node({:list, elem, max}, _codec, pctx) do
    elem_caller = enc(elem, pctx)
    max_ast = bound_ast(max, pctx)
    loop = fresh(:el)
    extra = if pctx, do: [quote(do: ps)], else: []
    # Elements that can encode as SMALL_INTEGER_EXT go to a scratch binary,
    # since the list is a STRING_EXT exactly when all of them do.
    small? = small_capable?(elem)
    define_list_encoder(loop, elem, elem_caller, small?, extra)

    body =
      if small? do
        quote do
          case unquote(loop)(value, 0, <<>>, :same, value, true, unquote_splicing(extra)) do
            {:ok, y, out, true} when n < 65_536 ->
              {:ok, y, <<acc::binary, 107, n::16, Heddle.Runtime.untag_small(out)::binary>>}

            {:ok, y, out, _small} ->
              {:ok, y, <<acc::binary, 108, n::32, out::binary, 106>>}

            error ->
              error
          end
        end
      else
        quote do
          case unquote(loop)(
                 value,
                 0,
                 <<acc::binary, 108, n::32>>,
                 :same,
                 value,
                 false,
                 unquote_splicing(extra)
               ) do
            {:ok, y, out, _small} -> {:ok, y, <<out::binary, 106>>}
            error -> error
          end
        end
      end

    max_check =
      if max == nil,
        do: false,
        else: quote(do: n > unquote(max_ast))

    fast =
      case {pctx, string_elements(elem)} do
        {nil, :all} ->
          [{quote(do: value), nil, string_encode(0, 255, max, quote(do: unquote(loop)))}]

        {nil, {:range, lo, hi}} ->
          [{quote(do: value), nil, string_encode(lo, hi, max, quote(do: unquote(loop)))}]

        _ ->
          []
      end

    general =
      quote do
        case Heddle.Runtime.proper_length(value) do
          :improper -> {:error, {[], {:type, :proper_list, value}}}
          n when unquote(max_check) -> {:error, {[], {:too_large, n, unquote(max_ast)}}}
          0 -> {:ok, value, <<acc::binary, 106>>}
          n -> unquote(body)
        end
      end

    general = if fast == [], do: general, else: quote(do: unquote(general))

    clauses =
      case fast do
        [] ->
          [
            {quote(do: value), quote(do: is_list(value)), general},
            {quote(do: value), nil, quote(do: {:error, {[], {:type, :list, value}}})}
          ]

        [{pattern, nil, string_body}] ->
          [
            {pattern, quote(do: is_list(value)),
             quote do
               case unquote(string_body) do
                 :general -> unquote(general)
                 result -> result
               end
             end},
            {quote(do: value), nil, quote(do: {:error, {[], {:type, :list, value}}})}
          ]
      end

    encoder(pctx, clauses)
  end

  defp enc_node({:tuple, elems}, _codec, pctx), do: enc_tuple(elems, pctx)

  defp enc_node({:map, required, optional}, _codec, pctx) do
    named = required ++ optional

    entries =
      named
      |> Enum.map(fn {key, codec} -> {ETF.encode_atom(key), key, enc(codec, pctx)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {bytes, key, caller} -> {:{}, [], [key, bytes, enc_fun(caller)]} end)

    required_keys = Enum.map(required, &elem(&1, 0))

    slow =
      quote do
        Heddle.Runtime.enc_map(
          value,
          unquote(Enum.map(required, fn {k, c} -> {k, enc_capture(enc(c, pctx))} end)),
          unquote(Enum.map(optional, fn {k, c} -> {k, enc_capture(enc(c, pctx))} end))
        )
      end

    encoder(pctx, [
      {quote(do: value), nil,
       quote do
         Heddle.Runtime.append_map(value, acc, unquote(entries), unquote(required_keys), fn ->
           unquote(slow)
         end)
       end}
    ])
  end

  defp enc_node({:struct, module, layout, fields}, _codec, pctx),
    do: enc_struct(module, layout, fields, pctx)

  defp enc_node({:map_of, key, val, max}, _codec, pctx) do
    key_caller = enc(key, pctx)
    val_caller = enc(val, pctx)
    max_ast = bound_ast(max, pctx)
    keys = fresh(:mk)
    values = fresh(:mv)
    extra = if pctx, do: [quote(do: ps)], else: []

    slow =
      quote do
        Heddle.Runtime.enc_map_of(
          value,
          unquote(max_ast),
          unquote(enc_capture(key_caller)),
          unquote(enc_capture(val_caller))
        )
      end

    # Keys are encoded on their own and sorted by their bytes; each value is
    # then encoded straight into the output after its key, so it is copied
    # once. Any failure, or a decoded key or value that differs from the
    # input, reruns the shared encoder for the canonical result.
    add_def(defp_ast(keys, [[], quote(do: keyed)] ++ extra, nil, quote(do: {:ok, keyed})))

    if pctx == nil do
      for {guard, segments} <- inline_enc(key, quote(do: k)) do
        add_def(
          defp_ast(
            keys,
            [quote(do: [{k, v} | rest]), quote(do: keyed)],
            guard,
            quote(do: unquote(keys)(rest, [{unquote({:<<>>, [], segments}), v} | keyed]))
          )
        )
      end
    end

    add_def(
      defp_ast(
        keys,
        [quote(do: [{k, v} | rest]), quote(do: keyed)] ++ extra,
        nil,
        quote do
          case unquote(invoke_enc(key_caller, quote(do: k), "")) do
            {:ok, yk, key_bytes} when yk === k ->
              unquote(keys)(rest, [{key_bytes, v} | keyed], unquote_splicing(extra))

            _ ->
              :slow
          end
        end
      )
    )

    add_def(defp_ast(values, [[], quote(do: out)] ++ extra, nil, quote(do: {:ok, out})))

    if pctx == nil do
      for {guard, segments} <- inline_enc(val, quote(do: v)) do
        add_def(
          defp_ast(
            values,
            [quote(do: [{key_bytes, v} | rest]), quote(do: out)],
            guard,
            quote(
              do:
                unquote(values)(
                  rest,
                  unquote(append_ast(quote(do: out), [quote(do: key_bytes :: binary) | segments]))
                )
            )
          )
        )
      end
    end

    add_def(
      defp_ast(
        values,
        [quote(do: [{key_bytes, v} | rest]), quote(do: out)] ++ extra,
        nil,
        quote do
          case unquote(
                 invoke_enc(
                   val_caller,
                   quote(do: v),
                   quote(do: <<out::binary, key_bytes::binary>>)
                 )
               ) do
            {:ok, yv, out} when yv === v -> unquote(values)(rest, out, unquote_splicing(extra))
            _ -> :slow
          end
        end
      )
    )

    size_guard = if max == nil, do: true, else: quote(do: map_size(value) <= unquote(max_ast))

    encoder(pctx, [
      {quote(do: value),
       quote(do: is_map(value) and not is_map_key(value, :__struct__) and unquote(size_guard)),
       quote do
         with {:ok, keyed} <- unquote(keys)(:maps.to_list(value), [], unquote_splicing(extra)),
              {:ok, out} <-
                unquote(values)(
                  :lists.keysort(1, keyed),
                  <<acc::binary, 116, map_size(value)::32>>,
                  unquote_splicing(extra)
                ) do
           {:ok, value, out}
         else
           _ -> Heddle.Runtime.lift(unquote(slow), acc)
         end
       end},
      {quote(do: value), nil, lift(slow)}
    ])
  end

  defp enc_node({:one_of, alts, _, shapes}, _codec, pctx) do
    branches =
      alts
      |> Enum.zip(shapes)
      |> Enum.map(fn {alt, items} ->
        test =
          items
          |> Enum.map(&shape_test/1)
          |> Enum.reduce(fn t, acc -> quote(do: unquote(acc) or unquote(t)) end)

        {:->, [], [[test], invoke_enc(enc(alt, pctx), quote(do: value), quote(do: acc))]}
      end)

    fallback = {:->, [], [[true], quote(do: {:error, {[], {:no_alternative, value}}})]}
    encoder(pctx, [{quote(do: value), nil, {:cond, [], [[do: branches ++ [fallback]]]}}])
  end

  defp enc_node({:iso, inner, decode, encode}, _codec, pctx) do
    inner_caller = enc(inner, pctx)

    encoder(pctx, [
      {quote(do: value), nil,
       quote do
         case Heddle.Runtime.call_iso(unquote(fun_ast(encode)), value) do
           {:ok, inner_value} ->
             case unquote(invoke_enc(inner_caller, quote(do: inner_value), quote(do: acc))) do
               {:ok, inner_y, acc} ->
                 case Heddle.Runtime.call_iso(unquote(fun_ast(decode)), inner_y) do
                   {:ok, y} -> {:ok, y, acc}
                   :error -> {:error, {[], {:iso, value}}}
                 end

               error ->
                 error
             end

           :error ->
             {:error, {[], {:iso, value}}}
         end
       end}
    ])
  end

  defp enc_node({:refine, inner, pred, reason}, _codec, pctx) do
    inner_caller = enc(inner, pctx)

    encoder(pctx, [
      {quote(do: value), nil,
       quote do
         case unquote(invoke_enc(inner_caller, quote(do: value), quote(do: acc))) do
           {:ok, y, acc} ->
             if unquote(fun_ast(pred)).(y),
               do: {:ok, y, acc},
               else: {:error, {[], {:refine, unquote(escape!(reason)), value}}}

           error ->
             error
         end
       end}
    ])
  end

  defp enc_node({:from, inner, getter}, _codec, pctx) do
    inner_caller = enc(inner, pctx)

    encoder(pctx, [
      {quote(do: value), nil,
       quote do
         case Heddle.Runtime.get(unquote(getter_ast(getter)), value) do
           {:ok, part} -> unquote(invoke_enc(inner_caller, quote(do: part), quote(do: acc)))
           :error -> {:error, {[], {:getter, value}}}
         end
       end}
    ])
  end

  defp enc_node({:tuple_seq, tag, seq}, codec, pctx) do
    Seq.enc(codec, tag, seq, pctx)
  end

  # A leaf encoder's fast paths as {guard, segments} over `var`, where the
  # segments are what the leaf appends and the decoded value is `var`
  # itself. Callers inline these before calling the encoder, which handles
  # everything else.
  defp inline_enc(%Heddle{node: node}, var) do
    case node do
      {:integer, min, max}
      when (is_integer(min) or is_nil(min)) and (is_integer(max) or is_nil(max)) ->
        range = range_guard(var, min, max, min, max)

        [
          {quote(
             do:
               is_integer(unquote(var)) and unquote(var) >= 0 and unquote(var) <= 255 and
                 unquote(range)
           ), [97, var]},
          {quote(
             do:
               is_integer(unquote(var)) and unquote(var) >= -2_147_483_648 and
                 unquote(var) <= 2_147_483_647 and unquote(range)
           ), [98, quote(do: unquote(var) :: signed - 32)]}
        ]

      :float ->
        [{quote(do: is_float(unquote(var))), [70, quote(do: unquote(var) :: float - 64)]}]

      {:binary, max, false} when is_integer(max) or is_nil(max) ->
        size = if max == nil, do: true, else: quote(do: byte_size(unquote(var)) <= unquote(max))

        [
          {quote(do: is_binary(unquote(var)) and unquote(size)),
           [109, quote(do: byte_size(unquote(var)) :: 32), quote(do: unquote(var) :: binary)]}
        ]

      {:literal, atom} ->
        [{quote(do: unquote(var) === unquote(atom)), :binary.bin_to_list(ETF.encode_atom(atom))}]

      {:enum, atoms, _} ->
        for atom <- atoms,
            do:
              {quote(do: unquote(var) === unquote(atom)),
               :binary.bin_to_list(ETF.encode_atom(atom))}

      _ ->
        []
    end
  end

  # `acc` with the segments appended.
  defp append_ast(acc, segments), do: {:<<>>, [], [quote(do: unquote(acc) :: binary) | segments]}

  # Whether a codec can write a SMALL_INTEGER_EXT. Only an optimization
  # hint (the encoder checks the bytes), so references and lazy codecs are
  # assumed to, rather than waiting on another module's summary.
  defp small_capable?(%Heddle{node: node}) do
    case node do
      {:integer, _, _} -> true
      :char -> true
      {:one_of, alts, _, _} -> Enum.any?(alts, &small_capable?/1)
      {:iso, inner, _, _} -> small_capable?(inner)
      {:refine, inner, _, _} -> small_capable?(inner)
      {:from, inner, _} -> small_capable?(inner)
      {:ref, _, _} -> true
      {:lazy, _} -> true
      _ -> false
    end
  end

  # The list loop: (list, index, out, ys, original, small, [ps]) returns
  # {:ok, decoded, out, small}. `ys` stays :same while every decoded element
  # is the input element, so an unchanged list is returned as is. `small`
  # stays true while every element encodes as SMALL_INTEGER_EXT.
  defp define_list_encoder(loop, elem, elem_caller, small?, extra) do
    args = fn list ->
      [list, quote(do: i), quote(do: out), quote(do: ys), quote(do: original), quote(do: small)] ++
        extra
    end

    add_def(
      defp_ast(
        loop,
        args.([]),
        nil,
        quote(do: {:ok, if(ys == :same, do: original, else: :lists.reverse(ys)), out, small})
      )
    )

    # Leaf elements append inline: the same bytes and value the element
    # encoder produces.
    if extra == [] do
      for {guard, segments} <- inline_enc(elem, quote(do: x)) do
        # An element stays small exactly when it is a SMALL_INTEGER_EXT.
        small = if match?([97 | _], segments), do: quote(do: small), else: false

        add_def(
          defp_ast(
            loop,
            args.(quote(do: [x | rest])),
            guard,
            quote do
              unquote(loop)(
                rest,
                i + 1,
                unquote(append_ast(quote(do: out), segments)),
                Heddle.Runtime.track_y(ys, x, x, original, i),
                original,
                unquote(small)
              )
            end
          )
        )
      end
    end

    small_after =
      if small?,
        do:
          quote(
            do:
              small and byte_size(next) == byte_size(out) + 2 and
                :binary.at(next, byte_size(out)) == 97
          ),
        else: false

    add_def(
      defp_ast(
        loop,
        args.(quote(do: [x | rest])),
        nil,
        quote do
          case unquote(invoke_enc(elem_caller, quote(do: x), quote(do: out))) do
            {:ok, y, next} ->
              unquote(loop)(
                rest,
                i + 1,
                next,
                Heddle.Runtime.track_y(ys, y, x, original, i),
                original,
                unquote(small_after),
                unquote_splicing(extra)
              )

            error ->
              Heddle.Runtime.enc_prefix(error, i)
          end
        end
      )
    )
  end

  # A list of integers that each encode as SMALL_INTEGER_EXT is the
  # STRING_EXT the general path would build, written in one step; anything
  # else returns :general.
  defp string_encode(lo, hi, max, _loop) do
    limit = if max == nil, do: 65_535, else: min(max, 65_535)

    quote do
      case Heddle.Runtime.byte_list(value, unquote(lo), unquote(hi), unquote(limit)) do
        {:ok, bytes} -> {:ok, value, <<acc::binary, 107, byte_size(bytes)::16, bytes::binary>>}
        :error -> :general
      end
    end
  end

  defp enc_tuple(elems, pctx) do
    arity = length(elems)
    callers = Enum.map(elems, &enc(&1, pctx))
    xs = for i <- 0..(arity - 1)//1, do: Macro.var(:"x#{i}", __MODULE__)
    ys = for i <- 0..(arity - 1)//1, do: Macro.var(:"y#{i}", __MODULE__)
    same = Enum.zip(xs, ys) |> Enum.map(fn {x, y} -> quote(do: unquote(y) === unquote(x)) end)

    y =
      case same do
        [] ->
          quote(do: value)

        _ ->
          quote(
            do:
              if(unquote(Enum.reduce(same, &quote(do: unquote(&2) and unquote(&1)))),
                do: value,
                else: unquote({:{}, [], ys})
              )
          )
      end

    chain =
      callers
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.reduce(quote(do: {:ok, unquote(y), acc}), fn {caller, i}, acc ->
        quote do
          case unquote(invoke_enc(caller, Enum.at(xs, i), quote(do: acc))) do
            {:ok, unquote(Enum.at(ys, i)), acc} -> unquote(acc)
            error -> Heddle.Runtime.enc_prefix(error, unquote(i))
          end
        end
      end)

    encoder(pctx, [
      {quote(do: unquote({:{}, [], xs}) = value), nil,
       quote do
         acc = <<acc::binary, unquote(ETF.tuple_header(arity))::binary>>
         unquote(chain)
       end},
      {quote(do: value), nil, quote(do: {:error, {[], {:type, {:tuple, unquote(arity)}, value}}})}
    ])
  end

  # Fields encode in key-byte order for the map layout, which is the order
  # of the output; a failure reruns the shared encoder, which reports the
  # first failure in declared order as the interpreter does. The tuple
  # layout writes fields in declared order, so its errors are direct.
  defp enc_struct(module, layout, fields, pctx) do
    names = Enum.map(fields, &elem(&1, 0))
    xs = Map.new(names, &{&1, Macro.var(:"x_#{&1}", __MODULE__)})
    ys = Map.new(names, &{&1, Macro.var(:"y_#{&1}", __MODULE__)})
    callers = Map.new(fields, fn {name, codec, _} -> {name, enc(codec, pctx)} end)
    same = Enum.map(names, fn n -> quote(do: unquote(ys[n]) === unquote(xs[n])) end)
    rebuilt = struct_literal(module, Enum.map(names, &{&1, ys[&1]}))

    # Decoding resets fields the codec does not serialize to their defaults,
    # so the input is the decoded value only when the codec covers them all.
    y =
      if covers_struct?(module, names) and same != [],
        do:
          quote(
            do:
              if(unquote(Enum.reduce(same, &quote(do: unquote(&2) and unquote(&1)))),
                do: value,
                else: unquote(rebuilt)
              )
          ),
        else: rebuilt

    {steps, prefix} =
      case layout do
        :map ->
          ordered =
            [{:__struct__, nil} | Enum.map(names, &{&1, &1})]
            |> Enum.sort_by(fn {key, _} -> ETF.encode_atom(key) end)

          steps =
            Enum.map(ordered, fn
              {:__struct__, nil} ->
                {:constant, ETF.encode_atom(:__struct__) <> ETF.encode_atom(module)}

              {key, name} ->
                {:field, name, ETF.encode_atom(key)}
            end)

          {steps, ETF.map_header(length(names) + 1)}

        {:tuple, tag} ->
          steps = Enum.map(names, &{:field, &1, <<>>})
          prefix = ETF.tuple_header(length(names) + if(tag, do: 1, else: 0))
          {steps, if(tag, do: prefix <> ETF.encode_atom(tag), else: prefix)}
      end

    on_error =
      case layout do
        :map ->
          fn _name ->
            entries = Enum.map(names, &{&1, enc_capture(callers[&1])})

            quote do
              _ = error

              Heddle.Runtime.lift(
                Heddle.Runtime.enc_struct(value, unquote(module), :map, unquote(entries)),
                start
              )
            end
          end

        {:tuple, _} ->
          fn name -> quote(do: Heddle.Runtime.enc_prefix(error, unquote(name))) end
      end

    chain =
      steps
      |> Enum.reverse()
      |> Enum.reduce(quote(do: {:ok, unquote(y), acc}), fn
        {:constant, bytes}, next ->
          quote do
            acc = <<acc::binary, unquote(bytes)::binary>>
            unquote(next)
          end

        {:field, name, key_bytes}, next ->
          call =
            invoke_enc(
              callers[name],
              xs[name],
              quote(do: <<acc::binary, unquote(key_bytes)::binary>>)
            )

          codec = Enum.find_value(fields, fn {n, c, _} -> if n == name, do: c end)

          # A leaf field appends inline when its fast path applies.
          encoded =
            case if(pctx == nil, do: inline_enc(codec, xs[name]), else: []) do
              [] ->
                call

              fast ->
                clauses =
                  Enum.map(fast, fn {guard, segments} ->
                    bytes = append_ast(quote(do: acc), :binary.bin_to_list(key_bytes) ++ segments)

                    {:->, [],
                     [
                       [{:when, [], [quote(do: _), guard]}],
                       quote(do: {:ok, unquote(xs[name]), unquote(bytes)})
                     ]}
                  end)

                {:case, [], [xs[name], [do: clauses ++ [{:->, [], [[quote(do: _)], call]}]]]}
            end

          quote do
            case unquote(encoded) do
              {:ok, unquote(ys[name]), acc} -> unquote(next)
              error -> unquote(on_error.(name))
            end
          end
      end)

    match = {:%{}, [], [{:__struct__, module} | Enum.map(names, &{&1, xs[&1]})]}

    encoder(pctx, [
      {quote(do: unquote(match) = value), nil,
       quote do
         start = acc
         acc = <<acc::binary, unquote(prefix)::binary>>
         unquote(chain)
       end},
      {quote(do: value), nil,
       quote(do: {:error, {[], {:type, {:struct, unquote(module)}, value}}})}
    ])
  end

  defp covers_struct?(module, names) do
    known = module |> struct_info!() |> Enum.map(& &1.field)
    Enum.sort(known) == Enum.sort(names)
  rescue
    _ -> false
  end

  # Code equivalent to IR.shape_matches?/2.
  defp shape_test(:any), do: true

  defp shape_test({:atom, a}), do: quote(do: value === unquote(a))

  defp shape_test(:any_atom), do: quote(do: is_atom(value))

  defp shape_test({:integer, lo, hi}),
    do: quote(do: is_integer(value) and unquote(range_guard(quote(do: value), lo, hi, lo, hi)))

  defp shape_test(:float), do: quote(do: is_float(value))

  defp shape_test(:binary), do: quote(do: is_binary(value))

  defp shape_test(:list), do: quote(do: is_list(value))

  defp shape_test(:map), do: quote(do: is_map(value) and not is_map_key(value, :__struct__))

  defp shape_test({:struct, module}), do: quote(do: is_struct(value, unquote(module)))

  defp shape_test({:tuple, n, :any}),
    do: quote(do: is_tuple(value) and tuple_size(value) == unquote(n))

  defp shape_test({:tuple, n, t}) do
    quote(
      do: is_tuple(value) and tuple_size(value) == unquote(n) and elem(value, 0) === unquote(t)
    )
  end

  ## Embedding values and functions

  @doc false
  @spec escape!(term()) :: Macro.t()
  def escape!(term) do
    Macro.escape(term)
  rescue
    ArgumentError ->
      reraise CodecError,
              [
                code: "H008",
                summary:
                  "a compiled codec holds a value that cannot be embedded in code: #{inspect(term, limit: 5)}",
                labels: [],
                help:
                  "functions in compiled codecs must be written in the codec expression, or be external captures (&Mod.fun/1)"
              ],
              __STACKTRACE__
  end

  @doc false
  @spec fun_ast(FunRef.t() | function()) :: Macro.t()
  def fun_ast(%FunRef{} = ref), do: funref_ast(ref)

  def fun_ast(fun) when is_function(fun) do
    case Function.info(fun, :type) do
      {:type, :external} ->
        Macro.escape(fun)

      _ ->
        raise CodecError,
          code: "H008",
          summary: "a compiled codec holds an anonymous function created outside its expression",
          labels: [],
          help:
            "write the function in the codec expression (or in @derive options as an external capture, &Mod.fun/1), " <>
              "or compile the codec that holds it with defcodec in its own module"
    end
  end

  # A FunRef's source, with the variables it captured bound first.
  @doc false
  @spec funref_ast(FunRef.t()) :: Macro.t()
  def funref_ast(%FunRef{id: id, bindings: bindings}) do
    {source, _meta} = Expr.fun_source(id)
    used = vars_in(source)

    assignments =
      for {{name, ctx} = key, value} <- bindings, MapSet.member?(used, key) do
        quote(do: unquote(Macro.var(name, ctx)) = unquote(escape!(value)))
      end

    case assignments do
      [] -> source
      _ -> {:__block__, [], assignments ++ [source]}
    end
  end

  defp getter_ast(%Field{} = field), do: Macro.escape(field)
  defp getter_ast(fun), do: fun_ast(fun)

  defp expected_ast(codec, pctx), do: quote_term(IR.expected(codec), pctx)

  defp bound_ast(%Param{index: i}, pctx) when pctx != nil, do: quote(do: elem(ps, unquote(i)))
  defp bound_ast(value, _pctx), do: value

  # Escapes a term, with parameters read from the parameter tuple.
  defp quote_term(%Param{} = param, pctx), do: bound_ast(param, pctx)
  defp quote_term(list, pctx) when is_list(list), do: Enum.map(list, &quote_term(&1, pctx))

  defp quote_term(tuple, pctx) when is_tuple(tuple),
    do: {:{}, [], tuple |> Tuple.to_list() |> Enum.map(&quote_term(&1, pctx))}

  defp quote_term(other, _pctx), do: escape!(other)

  @doc false
  @spec params?(Heddle.t()) :: boolean()
  def params?(%Heddle{} = codec), do: contains_param?(codec)

  defp contains_param?(%Param{}), do: true
  defp contains_param?(%Heddle{node: {:lazy, _}}), do: false
  defp contains_param?(%Heddle{node: {:ref, _, _}}), do: false
  defp contains_param?(%Heddle{node: node}), do: contains_param?(node)
  defp contains_param?(%_{}), do: false

  defp contains_param?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&contains_param?/1)

  defp contains_param?(list) when is_list(list), do: Enum.any?(list, &contains_param?/1)
  defp contains_param?(_), do: false

  ## Shared with Heddle.Compiler.Seq

  @doc false
  @spec dec_caller(Heddle.t(), term()) :: caller()
  def dec_caller(codec, pctx), do: dec(codec, pctx)
  @doc false
  @spec enc_caller(Heddle.t(), term()) :: caller()
  def enc_caller(codec, pctx), do: enc(codec, pctx)
  @doc false
  @spec call_dec_at(caller(), Macro.t(), Macro.t()) :: Macro.t()
  def call_dec_at(caller, rest_ast, depth_ast), do: call_at(caller, rest_ast, depth_ast)
  @doc false
  @spec call_enc(caller(), Macro.t(), Macro.t()) :: Macro.t()
  def call_enc(caller, value_ast, acc_ast), do: invoke_enc(caller, value_ast, acc_ast)
  @doc false
  @spec new_consuming(term(), Macro.t()) :: caller()
  def new_consuming(pctx, body), do: consuming(pctx, body)
  @doc false
  @spec new_encoder(term(), [{Macro.t(), Macro.t() | nil, Macro.t()}]) :: caller()
  def new_encoder(pctx, clauses), do: encoder(pctx, clauses)
  @doc false
  @spec expected_of(Heddle.t(), term()) :: Macro.t()
  def expected_of(codec, pctx), do: expected_ast(codec, pctx)
  @doc false
  @spec vars_of(Macro.t()) :: MapSet.t({atom(), atom()})
  def vars_of(ast), do: vars_in(ast)

  @doc false
  @spec finding(Pentiment.Report.t()) :: term()
  def finding(report), do: put_st(&%{&1 | findings: [report | &1.findings]})

  @doc false
  @spec warn_once(term(), (-> term())) :: term()
  def warn_once(key, fun) do
    unless MapSet.member?(st().warned, key) do
      put_st(&%{&1 | warned: MapSet.put(&1.warned, key)})
      fun.()
    end
  end

  @doc false
  @spec env() :: Macro.Env.t()
  def env, do: st().env

  @doc false
  @spec finite_limits() :: {pos_integer(), pos_integer()}
  def finite_limits, do: {@finite_values, @finite_expansion}
end

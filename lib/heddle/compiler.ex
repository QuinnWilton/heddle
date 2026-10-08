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
  alias Heddle.Compiler.Expr
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
          def unquote(root_enc)(value), do: unquote(invoke_enc(enc, quote(do: value), nil))
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

  defp invoke_dec({:remote, module, name}, _pctx),
    do: quote(do: unquote(module).__heddle_decode__(unquote(name), rest, depth, nodes, lim))

  # Calls a decoder with explicit `rest` and `depth` arguments.
  defp call_at({:local, name, false}, rest_ast, depth_ast),
    do: quote(do: unquote(name)(unquote(rest_ast), unquote(depth_ast), nodes, lim))

  defp call_at({:local, name, true}, rest_ast, depth_ast),
    do: quote(do: unquote(name)(unquote(rest_ast), unquote(depth_ast), nodes, lim, ps))

  defp call_at({:remote, module, name}, rest_ast, depth_ast),
    do:
      quote(
        do:
          unquote(module).__heddle_decode__(
            unquote(name),
            unquote(rest_ast),
            unquote(depth_ast),
            nodes,
            lim
          )
      )

  defp invoke_enc({:local, name, false}, value, _pctx),
    do: quote(do: unquote(name)(unquote(value)))

  defp invoke_enc({:local, name, true}, value, _pctx),
    do: quote(do: unquote(name)(unquote(value), ps))

  defp invoke_enc({:remote, module, name}, value, _pctx),
    do: quote(do: unquote(module).__heddle_encode__(unquote(name), unquote(value)))

  defp enc_capture({:local, name, false}), do: local_capture(name, 1)
  defp enc_capture({:local, name, true}), do: quote(do: &unquote(name)(&1, ps))

  defp enc_capture({:remote, module, name}),
    do: quote(do: &unquote(module).__heddle_encode__(unquote(name), &1))

  defp dec_capture({:local, name, false}), do: local_capture(name, 4)
  defp dec_capture({:local, name, true}), do: quote(do: &unquote(name)(&1, &2, &3, &4, ps))

  defp dec_capture({:remote, module, name}),
    do: quote(do: &unquote(module).__heddle_decode__(unquote(name), &1, &2, &3, &4))

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
  defp consuming(pctx, body) do
    name = fresh(:d)

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
      args = if pctx, do: [pattern, quote(do: ps)], else: [pattern]
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
              defp_ast(name, [quote(do: value)], nil, invoke_enc(inner, quote(do: value), nil))
            )

        caller
    end
  end

  defp lazy_key(%FunRef{id: id, bindings: bindings}), do: {:funref, id, bindings}
  defp lazy_key(fun), do: {:fun, fun}

  defp dec_node(codec, node, pctx) do
    expected = expected_ast(codec, pctx)

    case node do
      {:literal, atom} ->
        consuming(
          pctx,
          atom_dispatch([atom], quote(do: Heddle.Runtime.atom_failure(rest, unquote(expected))))
        )

      {:enum, atoms, :reject} ->
        consuming(
          pctx,
          atom_dispatch(atoms, quote(do: Heddle.Runtime.atom_failure(rest, unquote(expected))))
        )

      {:enum, atoms, :keep} ->
        names = Macro.escape(Map.new(atoms, &{Atom.to_string(&1), &1}))

        fallback =
          quote(
            do: Heddle.Runtime.read_enum(rest, nodes, unquote(names), :keep, unquote(expected))
          )

        consuming(pctx, atom_dispatch(atoms, fallback))

      :existing_atom ->
        consuming(
          pctx,
          quote(do: Heddle.Runtime.read_existing_atom(rest, nodes, unquote(expected)))
        )

      {:integer, min, max} ->
        consuming(pctx, dec_integer(min, max, expected, pctx))

      :char ->
        consuming(pctx, quote(do: Heddle.Runtime.read_char(rest, nodes, unquote(expected))))

      :float ->
        consuming(
          pctx,
          quote do
            case rest do
              <<70, f::float-64, after_term::binary>> -> {:ok, f, after_term, nodes}
              _ -> Heddle.Runtime.read_float(rest, nodes, unquote(expected))
            end
          end
        )

      {:binary, max, utf8} ->
        consuming(pctx, dec_binary(max, utf8, expected, pctx))

      {:list, elem, max} ->
        dec_list(elem, max, expected, pctx)

      {:tuple, elems} ->
        consuming(
          pctx,
          dec_tuple_body(elems, expected, pctx, fn tuple ->
            quote(do: {:ok, unquote(tuple), body, nodes})
          end)
        )

      {:map, required, optional} ->
        named = required ++ optional
        required_keys = Enum.map(required, &elem(&1, 0))
        consuming(pctx, dec_keyed_map(named, required_keys, expected, pctx, quote(do: acc)))

      {:struct, module, :map, fields} ->
        consuming(pctx, dec_struct_map(module, fields, expected, pctx))

      {:struct, module, {:tuple, tag}, fields} ->
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
          end)
        )

      {:map_of, key, value, max} ->
        dec_map_of(key, value, max, expected, pctx)

      {:one_of, alts, firsts, _} ->
        dec_one_of(alts, firsts, expected, pctx)

      {:iso, inner, decode, _} ->
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

      {:refine, inner, pred, reason} ->
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

      {:tuple_seq, tag, seq} ->
        Heddle.Compiler.Seq.dec(codec, tag, seq, pctx)
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
    defaults =
      module |> Macro.struct_info!(st().env) |> Enum.map(&{&1.field, escape!(&1.default)})

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

    key_clauses =
      for {key, codec} <- entries,
          caller = dec(codec, pctx),
          spelling <- ETF.atom_spellings(key) do
        bit = Map.fetch!(bits, key)

        update =
          if key == :__struct__, do: quote(do: acc), else: quote(do: %{acc | unquote(key) => v})

        body =
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
        nil,
        quote do
          case Heddle.Runtime.enter(rest, depth, nodes, lim) do
            {:ok, nodes} -> unquote(dispatch)
            error -> error
          end
        end
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
                   2,
                   byte_size(body),
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

    # Leaf elements match in the loop's head, so the binary stays a match
    # context across iterations; anything else falls to the general clause.
    for {pattern, guard, value} <- inline_leaf(elem, pctx) do
      add_def(
        defp_ast(
          list_loop,
          [
            pattern,
            quote(do: n),
            quote(do: i),
            quote(do: depth),
            quote(do: nodes),
            quote(do: {max_depth, _, copy, _} = lim),
            quote(do: acc)
          ],
          quote(do: depth <= max_depth and nodes > 0 and unquote(guard)),
          quote(
            do: unquote(list_loop)(rest, n, i + 1, depth, nodes - 1, lim, [unquote(value) | acc])
          )
        )
      )
    end

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

    string_body =
      case string_elements(elem) do
        :all ->
          quote(
            do:
              if(len == 0 or depth + 1 <= elem(lim, 0), do: unquote(fast), else: unquote(generic))
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
                   1,
                   byte_size(body),
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
                   1,
                   byte_size(body) - 1,
                   1,
                   nodes,
                   unquote(expected),
                   rest,
                   lim
                 ) do
              :ok ->
                unquote(list_loop)(
                  body,
                  n,
                  0,
                  depth + 1,
                  nodes,
                  lim,
                  [],
                  unquote_splicing(loop_extra)
                )

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

  # Head patterns for leaf elements, each {pattern, guard, value}: special
  # cases of the element decoder's success path, with `rest` the remainder.
  defp inline_leaf(_codec, pctx) when pctx != nil, do: []

  defp inline_leaf(%Heddle{node: node}, nil) do
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
                   2,
                   byte_size(body),
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
    loop_extra = if pctx, do: [quote(do: ps)], else: []

    add_def(
      defp_ast(
        loop,
        [
          quote(do: <<rest::binary>>),
          0,
          quote(do: i),
          quote(do: depth),
          quote(do: nodes),
          quote(do: lim),
          quote(do: acc)
        ] ++ loop_extra,
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
          quote(do: i),
          quote(do: depth),
          quote(do: nodes),
          quote(do: lim),
          quote(do: acc)
        ] ++ loop_extra,
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

    consuming(
      pctx,
      quote do
        case rest do
          <<116, n::32, body::binary>> ->
            case Heddle.Runtime.check_count(
                   n,
                   unquote(max_ast),
                   2,
                   byte_size(body),
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

  defp enc_node(node, codec, pctx) do
    v = quote(do: value)

    case node do
      {:literal, atom} ->
        encoder(pctx, [
          {v, quote(do: value === unquote(atom)),
           quote(do: {:ok, unquote(atom), unquote(ETF.encode_atom(atom))})},
          {v, nil, quote(do: {:error, {[], {:type, {:atom, unquote(atom)}, value}}})}
        ])

      {:enum, atoms, unknown} ->
        members =
          for atom <- atoms do
            {v, quote(do: value === unquote(atom)),
             quote(do: {:ok, unquote(atom), unquote(ETF.encode_atom(atom))})}
          end

        encoder(
          pctx,
          members ++
            [
              {v, nil,
               quote(do: Heddle.Runtime.enc_enum(value, unquote(atoms), unquote(unknown)))}
            ]
        )

      :existing_atom ->
        encoder(pctx, [{v, nil, quote(do: Heddle.Runtime.enc_existing_atom(value))}])

      {:integer, min, max} ->
        min_ast = bound_ast(min, pctx)
        max_ast = bound_ast(max, pctx)

        guard =
          quote(
            do:
              is_integer(value) and value >= 0 and value <= 255 and
                unquote(range_guard(v, min, max, min_ast, max_ast))
          )

        encoder(pctx, [
          {v, guard, quote(do: {:ok, value, <<97, value>>})},
          {v, nil,
           quote(do: Heddle.Runtime.enc_integer(value, unquote(min_ast), unquote(max_ast)))}
        ])

      :char ->
        encoder(pctx, [{v, nil, quote(do: Heddle.Runtime.enc_char(value))}])

      :float ->
        encoder(pctx, [
          {v, quote(do: is_float(value)), quote(do: {:ok, value, <<70, value::float-64>>})},
          {v, nil, quote(do: Heddle.Runtime.enc_float(value))}
        ])

      {:binary, max, utf8} ->
        max_ast = bound_ast(max, pctx)

        size_guard =
          if max == nil, do: true, else: quote(do: byte_size(value) <= unquote(max_ast))

        fast =
          if utf8,
            do: [],
            else: [
              {v, quote(do: is_binary(value) and unquote(size_guard)),
               quote(do: {:ok, value, [<<109, byte_size(value)::32>>, value]})}
            ]

        encoder(
          pctx,
          fast ++
            [
              {v, nil,
               quote(do: Heddle.Runtime.enc_binary(value, unquote(max_ast), unquote(utf8)))}
            ]
        )

      {:list, elem, max} ->
        elem_caller = enc(elem, pctx)

        generic =
          quote(
            do:
              Heddle.Runtime.enc_list(
                value,
                unquote(bound_ast(max, pctx)),
                unquote(enc_capture(elem_caller))
              )
          )

        # A list of integers that each encode as SMALL_INTEGER_EXT is the
        # STRING_EXT the generic path would build, written in one step.
        fast =
          case {pctx, string_elements(elem)} do
            {nil, :all} -> [{v, nil, string_encode(0, 255, max, generic)}]
            {nil, {:range, lo, hi}} -> [{v, nil, string_encode(lo, hi, max, generic)}]
            _ -> []
          end

        encoder(pctx, if(fast == [], do: [{v, nil, generic}], else: fast))

      {:tuple, elems} ->
        enc_tuple(elems, pctx)

      {:map, required, optional} ->
        encoder(pctx, [
          {v, nil,
           quote(
             do:
               Heddle.Runtime.enc_map(
                 value,
                 unquote(field_encoders(required, pctx)),
                 unquote(field_encoders(optional, pctx))
               )
           )}
        ])

      {:struct, module, layout, fields} ->
        enc_struct(module, layout, fields, pctx)

      {:map_of, key, val, max} ->
        key_caller = enc(key, pctx)
        val_caller = enc(val, pctx)

        encoder(pctx, [
          {v, nil,
           quote(
             do:
               Heddle.Runtime.enc_map_of(
                 value,
                 unquote(bound_ast(max, pctx)),
                 unquote(enc_capture(key_caller)),
                 unquote(enc_capture(val_caller))
               )
           )}
        ])

      {:one_of, alts, _, shapes} ->
        branches =
          alts
          |> Enum.zip(shapes)
          |> Enum.map(fn {alt, items} ->
            test =
              items
              |> Enum.map(&shape_test/1)
              |> Enum.reduce(fn t, acc -> quote(do: unquote(acc) or unquote(t)) end)

            {:->, [], [[test], invoke_enc(enc(alt, pctx), v, pctx)]}
          end)

        fallback = {:->, [], [[true], quote(do: {:error, {[], {:no_alternative, value}}})]}
        encoder(pctx, [{v, nil, {:cond, [], [[do: branches ++ [fallback]]]}}])

      {:iso, inner, decode, encode} ->
        inner_caller = enc(inner, pctx)

        encoder(pctx, [
          {v, nil,
           quote do
             case Heddle.Runtime.call_iso(unquote(fun_ast(encode)), value) do
               {:ok, inner_value} ->
                 case unquote(invoke_enc(inner_caller, quote(do: inner_value), pctx)) do
                   {:ok, inner_y, iodata} ->
                     case Heddle.Runtime.call_iso(unquote(fun_ast(decode)), inner_y) do
                       {:ok, y} -> {:ok, y, iodata}
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

      {:refine, inner, pred, reason} ->
        inner_caller = enc(inner, pctx)

        encoder(pctx, [
          {v, nil,
           quote do
             case unquote(invoke_enc(inner_caller, v, pctx)) do
               {:ok, y, iodata} ->
                 if unquote(fun_ast(pred)).(y),
                   do: {:ok, y, iodata},
                   else: {:error, {[], {:refine, unquote(escape!(reason)), value}}}

               error ->
                 error
             end
           end}
        ])

      {:from, inner, getter} ->
        inner_caller = enc(inner, pctx)

        encoder(pctx, [
          {v, nil,
           quote do
             case Heddle.Runtime.get(unquote(getter_ast(getter)), value) do
               {:ok, part} -> unquote(invoke_enc(inner_caller, quote(do: part), pctx))
               :error -> {:error, {[], {:getter, value}}}
             end
           end}
        ])

      {:tuple_seq, tag, seq} ->
        Heddle.Compiler.Seq.enc(codec, tag, seq, pctx)
    end
  end

  defp string_encode(lo, hi, max, generic) do
    limit = if max == nil, do: 65_535, else: min(max, 65_535)

    quote do
      case Heddle.Runtime.byte_list(value, unquote(lo), unquote(hi), unquote(limit)) do
        {:ok, bytes} -> {:ok, value, [<<107, byte_size(bytes)::16>>, bytes]}
        :error -> unquote(generic)
      end
    end
  end

  defp enc_tuple(elems, pctx) do
    arity = length(elems)
    callers = Enum.map(elems, &enc(&1, pctx))
    xs = for i <- 0..(arity - 1)//1, do: Macro.var(:"x#{i}", __MODULE__)
    ys = for i <- 0..(arity - 1)//1, do: Macro.var(:"y#{i}", __MODULE__)
    ios = for i <- 0..(arity - 1)//1, do: Macro.var(:"io#{i}", __MODULE__)

    finish =
      quote(do: {:ok, unquote({:{}, [], ys}), [unquote(ETF.tuple_header(arity)) | unquote(ios)]})

    chain =
      callers
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.reduce(finish, fn {caller, i}, acc ->
        quote do
          case unquote(invoke_enc(caller, Enum.at(xs, i), pctx)) do
            {:ok, unquote(Enum.at(ys, i)), unquote(Enum.at(ios, i))} -> unquote(acc)
            error -> Heddle.Runtime.enc_prefix(error, unquote(i))
          end
        end
      end)

    encoder(pctx, [
      {quote(do: unquote({:{}, [], xs}) = value), nil, chain},
      {quote(do: value), nil, quote(do: {:error, {[], {:type, {:tuple, unquote(arity)}, value}}})}
    ])
  end

  # Fields encode in declared order, so the first failure is the one the
  # interpreter reports; the map layout writes keys in their sorted order,
  # fixed at compile time.
  defp enc_struct(module, layout, fields, pctx) do
    names = Enum.map(fields, &elem(&1, 0))
    xs = Enum.map(names, &Macro.var(:"x_#{&1}", __MODULE__))
    ys = Enum.map(names, &Macro.var(:"y_#{&1}", __MODULE__))
    ios = Enum.map(names, &Macro.var(:"io_#{&1}", __MODULE__))
    callers = Enum.map(fields, fn {_, codec, _} -> enc(codec, pctx) end)

    bytes =
      case layout do
        :map ->
          pairs =
            [
              {ETF.encode_atom(:__struct__), ETF.encode_atom(module)}
              | Enum.zip(Enum.map(names, &ETF.encode_atom/1), ios)
            ]
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map(fn {k, io} -> [k, io] end)

          [ETF.map_header(length(pairs)) | pairs]

        {:tuple, tag} ->
          elems = if tag, do: [ETF.encode_atom(tag) | ios], else: ios
          [ETF.tuple_header(length(elems)) | elems]
      end

    same = Enum.zip(xs, ys) |> Enum.map(fn {x, y} -> quote(do: unquote(y) === unquote(x)) end)
    rebuilt = struct_literal(module, Enum.zip(names, ys))

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

    chain =
      [callers, xs, ys, ios, names]
      |> Enum.zip()
      |> Enum.reverse()
      |> Enum.reduce(quote(do: {:ok, unquote(y), unquote(bytes)}), fn {caller, x, y, io, name},
                                                                      acc ->
        quote do
          case unquote(invoke_enc(caller, x, pctx)) do
            {:ok, unquote(y), unquote(io)} -> unquote(acc)
            error -> Heddle.Runtime.enc_prefix(error, unquote(name))
          end
        end
      end)

    match = {:%{}, [], [{:__struct__, module} | Enum.zip(names, xs)]}

    encoder(pctx, [
      {quote(do: unquote(match) = value), nil, chain},
      {quote(do: value), nil,
       quote(do: {:error, {[], {:type, {:struct, unquote(module)}, value}}})}
    ])
  end

  defp covers_struct?(module, names) do
    known = module |> Macro.struct_info!(st().env) |> Enum.map(& &1.field)
    Enum.sort(known) == Enum.sort(names)
  rescue
    _ -> false
  end

  defp field_encoders(pairs, pctx) do
    entries = Enum.map(pairs, fn {key, codec} -> {key, enc_capture(enc(codec, pctx))} end)
    quote(do: unquote(entries))
  end

  # Code equivalent to IR.shape_matches?/2.
  defp shape_test(item) do
    case item do
      :any ->
        true

      {:atom, a} ->
        quote(do: value === unquote(a))

      :any_atom ->
        quote(do: is_atom(value))

      {:integer, lo, hi} ->
        quote(do: is_integer(value) and unquote(range_guard(quote(do: value), lo, hi, lo, hi)))

      :float ->
        quote(do: is_float(value))

      :binary ->
        quote(do: is_binary(value))

      :list ->
        quote(do: is_list(value))

      :map ->
        quote(do: is_map(value) and not is_map_key(value, :__struct__))

      {:struct, module} ->
        quote(do: is_struct(value, unquote(module)))

      {:tuple, n, :any} ->
        quote(do: is_tuple(value) and tuple_size(value) == unquote(n))

      {:tuple, n, t} ->
        quote(
          do:
            is_tuple(value) and tuple_size(value) == unquote(n) and elem(value, 0) === unquote(t)
        )
    end
  end

  ## Embedding values and functions

  @doc false
  @spec escape!(term()) :: Macro.t()
  def escape!(term) do
    Macro.escape(term)
  rescue
    ArgumentError ->
      raise CodecError,
        code: "H008",
        summary:
          "a compiled codec holds a value that cannot be embedded in code: #{inspect(term, limit: 5)}",
        labels: [],
        help:
          "functions in compiled codecs must be written in the codec expression, or be external captures (&Mod.fun/1)"
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
  @spec call_enc(caller(), Macro.t(), term()) :: Macro.t()
  def call_enc(caller, value_ast, pctx), do: invoke_enc(caller, value_ast, pctx)
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

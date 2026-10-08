defmodule Heddle.Lint do
  @moduledoc """
  Static findings about a codec, as `Pentiment.Report` warnings.

    * `L001` - a list, binary, map or integer position has no bound from the
      codec. It is still bounded at runtime by the call-site limits (at least
      `max_bytes`, which always has a value), so this is a warning about
      relying on call-site policy, not a decode-time failure.
    * `W001` - a compiled codec's `bind` was classified as opaque and runs in
      the interpreter.

  Findings carry source locations for codecs a Heddle macro compiled; codecs
  built at runtime report the path to the position instead.
  """

  alias Pentiment.{Label, Report}

  @doc "Lints a codec."
  @spec run(Heddle.t()) :: [Report.t()]
  def run(codec) do
    {findings, _seen} = walk(codec, [], {[], MapSet.new()})
    Enum.reverse(findings)
  end

  defp walk(%Heddle{node: {:binary, nil, _}} = codec, path, acc),
    do: add(acc, codec, path, "binary has no max_size", "pass max_size: to Heddle.binary/1")

  defp walk(%Heddle{node: {:list, elem, max}} = codec, path, acc) do
    acc =
      if max == nil,
        do: add(acc, codec, path, "list has no max", "pass max: to the list codec"),
        else: acc

    walk(elem, path ++ [:elements], acc)
  end

  defp walk(%Heddle{node: {:map_of, key, value, max}} = codec, path, acc) do
    acc =
      if max == nil,
        do: add(acc, codec, path, "map_of has no max", "pass max: to Heddle.map_of/3"),
        else: acc

    acc = walk(key, path ++ [:keys], acc)
    walk(value, path ++ [:values], acc)
  end

  defp walk(%Heddle{node: {:integer, min, max}} = codec, path, acc)
       when min == nil or max == nil do
    add(
      acc,
      codec,
      path,
      "integer has no #{if min == nil, do: "min", else: "max"}, so bignums up to the VM's limit decode",
      "pass min: and max: to Heddle.integer/1"
    )
  end

  defp walk(%Heddle{node: {:tuple, elems}}, path, acc) do
    elems
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {c, i}, acc -> walk(c, path ++ [i], acc) end)
  end

  defp walk(%Heddle{node: {:map, required, optional}}, path, acc),
    do: Enum.reduce(required ++ optional, acc, fn {k, c}, acc -> walk(c, path ++ [k], acc) end)

  defp walk(%Heddle{node: {:struct, _, _, fields}}, path, acc),
    do: Enum.reduce(fields, acc, fn {k, c, _}, acc -> walk(c, path ++ [k], acc) end)

  defp walk(%Heddle{node: {:one_of, alts, _, _}}, path, acc),
    do: Enum.reduce(alts, acc, &walk(&1, path, &2))

  defp walk(%Heddle{node: {:iso, inner, _, _}}, path, acc), do: walk(inner, path, acc)

  defp walk(%Heddle{node: {:refine, inner, _, _}}, path, acc), do: walk(inner, path, acc)

  defp walk(%Heddle{node: {:from, inner, _}}, path, acc), do: walk(inner, path, acc)

  defp walk(%Heddle{node: {:lazy, thunk}} = codec, path, acc),
    do: visit(acc, {:lazy, thunk}, fn acc -> walk(Heddle.IR.force(codec), path, acc) end)

  defp walk(%Heddle{node: {:ref, module, name}}, path, acc) do
    visit(acc, {:ref, module, name}, fn acc ->
      acc =
        Enum.reduce(compiled_findings(module, name), acc, fn r, {f, s} -> {[r | f], s} end)

      walk(Heddle.IR.ir_of_ref(module, name), path, acc)
    end)
  end

  defp walk(%Heddle{node: {:tuple_seq, _, seq}}, path, acc), do: walk_seq(seq, path, acc)

  defp walk(%Heddle{node: _}, _path, acc), do: acc

  # Only the first step of a sequence is static; the rest depends on values.
  defp walk_seq(%Heddle{node: {:bind, codec, _}}, path, acc), do: walk(codec, path ++ [0], acc)
  defp walk_seq(_, _path, acc), do: acc

  defp visit({findings, seen} = acc, key, fun) do
    if MapSet.member?(seen, key), do: acc, else: fun.({findings, MapSet.put(seen, key)})
  end

  defp compiled_findings(module, name) do
    if function_exported?(module, :__heddle_lint__, 1), do: module.__heddle_lint__(name), else: []
  end

  defp add({findings, seen}, codec, path, message, help) do
    report =
      Report.warning(message)
      |> Report.with_code("L001")
      |> Report.with_help(help)
      |> located(codec, path)

    {[report | findings], seen}
  end

  @doc false
  @spec located(Report.t(), Heddle.t(), [term()]) :: Report.t()
  def located(report, %Heddle{span: {file, span}}, _path) do
    report |> Report.with_source(file) |> Report.with_label(Label.primary(span, "here"))
  end

  def located(report, _codec, path), do: Report.with_note(report, "at path #{inspect(path)}")
end

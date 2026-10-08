defmodule Heddle.Diagnostics do
  @moduledoc false
  # Renders compile-time problems with pentiment. Codecs built by a Heddle
  # macro carry `{file, span}` from the expression that produced them, so a
  # report can label every codec involved, across files.

  alias Pentiment.{Label, Report, Source}

  @doc false
  @spec report(Heddle.CodecError.t(), Macro.Env.t(), keyword()) :: Report.t()
  def report(%Heddle.CodecError{} = error, env, opts \\ []) do
    severity = Keyword.get(opts, :severity, :error)

    fallback =
      Keyword.get(opts, :fallback) || {env.file, Pentiment.Span.position(max(env.line, 1), 1)}

    labels =
      error.labels
      |> Enum.with_index()
      |> Enum.flat_map(fn {{codec, text}, i} ->
        case codec_span(codec) do
          nil ->
            []

          {file, span} ->
            label = if i == 0, do: &Label.primary/3, else: &Label.secondary/3
            [{file, label.(span, text, source: file)}]
        end
      end)

    {primary_file, labels} =
      case labels do
        [] ->
          {file, span} = fallback
          {file, [{file, Label.primary(span, first_text(error), source: file)}]}

        [{file, _} | _] ->
          {file, labels}
      end

    report =
      Report.build(severity, error.summary)
      |> Report.with_code(error.code)
      |> Report.with_source(primary_file)
      |> Report.with_labels(Enum.map(labels, &elem(&1, 1)))

    if error.help, do: Report.with_help(report, error.help), else: report
  end

  defp first_text(%{labels: [{_, text} | _]}), do: text
  defp first_text(%{summary: summary}), do: summary

  defp codec_span(%Heddle{span: {file, span}}) when is_binary(file), do: {file, span}
  defp codec_span(_), do: nil

  @doc false
  @spec format(Report.t()) :: String.t()
  def format(%Report{} = report) do
    files =
      Enum.uniq([report.source | Enum.map(report.labels, & &1.source)]) |> Enum.reject(&is_nil/1)

    sources = Map.new(files, &{&1, source(&1)})

    # Labels in code with no file on disk (compiled from a string) cannot be
    # excerpted, so their text becomes notes.
    report =
      report.labels
      |> Enum.reject(&(&1.source && File.exists?(&1.source)))
      |> Enum.reduce(report, fn label, report ->
        Report.with_note(report, "#{label.source}:#{label.span.start_line}: #{label.message}")
      end)

    Pentiment.format(report, sources, colors: false)
  end

  defp source(file) do
    if File.exists?(file), do: Source.from_file(file), else: Source.named(file)
  end

  @doc false
  @spec compile_error!(Heddle.CodecError.t(), Macro.Env.t()) :: no_return()
  @spec compile_error!(Heddle.CodecError.t(), Macro.Env.t(), keyword()) :: no_return()
  def compile_error!(error, env, opts \\ []) do
    report = report(error, env, opts)
    line = primary_line(report) || env.line
    raise CompileError, file: report.source || env.file, line: line, description: format(report)
  end

  @doc false
  @spec warn(Heddle.CodecError.t(), Macro.Env.t(), keyword()) :: Report.t()
  def warn(error, env, opts \\ []) do
    report = report(error, env, Keyword.put(opts, :severity, :warning))
    IO.warn(format(report), Macro.Env.stacktrace(env))
    report
  end

  defp primary_line(%Report{labels: labels}) do
    Enum.find_value(labels, fn
      %Label{priority: :primary, span: %{start_line: line}} -> line
      _ -> nil
    end)
  end
end

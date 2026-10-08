defmodule Heddle.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/QuinnWilton/heddle"

  def project do
    [
      app: :heddle,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix, :stream_data],
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ],

      # Hex
      description:
        "Safe, bidirectional ETF codecs for the BEAM: schema-directed decoders and encoders " <>
          "that replace binary_to_term/term_to_binary at trust boundaries.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:pentiment, "~> 0.2"},
      {:stream_data, "~> 1.0", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:presubmit, "~> 0.2.2", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "Heddle",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["docs/design.md"]
    ]
  end
end

defmodule Hume.MixProject do
  use Mix.Project

  @version "0.0.1"

  def project do
    [
      app: :hume,
      version: @version,
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Event-sourced state machines for Elixir",
      package: package(),
      source_url: "https://github.com/zen-en-tonal/hume",
      homepage_url: "https://github.com/zen-en-tonal/hume",
      docs: [
        main: "Hume",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Hume.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.21", only: [:dev, :test], runtime: false},
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 0.6", only: :test}
    ]
  end

  defp package do
    [
      maintainers: ["Takeru KODAMA"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/zen-en-tonal/hume",
        "Docs" => "https://hexdocs.pm/hume"
      },
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end

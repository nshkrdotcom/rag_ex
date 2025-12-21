defmodule Rag.MixProject do
  use Mix.Project

  @source_url "https://github.com/bitcrowd/rag"
  @version "0.3.0"

  def project do
    [
      app: :rag,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: [lint: :test],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :jason],
        plt_core_path: "_plts"
      ],
      package: package(),
      docs: docs(),
      description: "A library to make building performant RAG systems in Elixir easy",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5.10"},
      {:nx, "~> 0.9.0"},
      {:telemetry, "~> 1.0"},

      # LLM providers - all optional
      {:gemini_ex, "~> 0.8.6"},
      {:codex_sdk, "~> 0.4.2", optional: true},
      {:claude_agent_sdk, "~> 0.6.8", optional: true},

      # Vector store and search
      # TODO: Re-enable Torus once inflex dependency is fixed for Elixir 1.18
      # {:torus, "~> 0.5.3"},
      {:pgvector, "~> 0.3.0"},
      {:ecto_sql, "~> 3.0"},
      {:postgrex, "~> 0.17"},

      # Dev/test
      # Temporarily disabled due to inflex Elixir 1.18 compatibility issue
      # {:igniter, "~> 0.5.7", runtime: false},
      {:mimic, "~> 2.2", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["@bitcrowd", "Joel Koch"],
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE assets),
      links: %{
        GitHub: @source_url
      }
    ]
  end

  defp docs do
    [
      main: "Rag",
      source_ref: "v#{@version}",
      source_url: @source_url,
      assets: %{"assets" => "assets"},
      logo: "assets/rag.svg",
      extras: [
        {"README.md", title: "README"},
        "CHANGELOG.md",
        "notebooks/getting_started.livemd"
      ]
    ]
  end

  defp aliases do
    [
      lint: [
        "format --check-formatted",
        "credo --strict",
        "dialyzer --format dialyxir"
      ]
    ]
  end
end

defmodule TripleStoreDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :triple_store_demo,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [{:rag, path: "../.."}]
  end
end

defmodule PoliteClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :polite_client,
      version: "0.1.0",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Docs
      name: "PoliteClient",
      source_url: "https://github.com/davidsulc/polite_client",
      # homepage_url: "http://YOUR_PROJECT_HOMEPAGE",
      docs: [
        main: "PoliteClient",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {PoliteClient.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dialyxir, "~> 0.5.1", only: :dev},
      # TODO remove
      {:mojito, "~> 0.3.0", only: :dev},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false}
    ]
  end
end

defmodule Rexsilient.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/fabiobarkoski/rexsilient"

  def project do
    [
      app: :rexsilient,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Rexsilient",
      source_url: @source_url,
      homepage_url: @source_url,
      description: description(),
      package: package(),
      docs: docs(),
    ]
  end

  defp description do
    "Resilience toolkit for Elixir."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "Github" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:benchee, "~> 1.5", only: :bench},
      {:fuse, "~> 2.5", only: :bench}
    ]
  end

  defp aliases do
    [
      bench_stress: "run benchmarks/stress.exs",
      bench_fuse_stress: "run benchmarks/fuse_stress.exs"
    ]
  end
end

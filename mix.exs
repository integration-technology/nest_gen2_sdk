defmodule NestGen2.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/integration-technology/nest_gen2_sdk"

  def project do
    [
      app: :nest_gen2,
      version: @version,
      # The Nest runs Elixir 1.17 on OTP 26: build with that toolchain.
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [test: "test --no-start"],
      description:
        "Elixir SDK for a rooted Nest Learning Thermostat (2nd gen): round display, " <>
          "dial, click, motion and climate sensors.",
      package: package(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {NestGen2.Application, []}
    ]
  end

  defp deps do
    []
  end

  defp package do
    [
      licenses: ["GPL-3.0-only"],
      links: %{
        "GitHub" => @source_url,
        "Issues" => "#{@source_url}/issues",
        "Changelog" => "#{@source_url}/blob/v#{@version}/CHANGELOG.md",
        "Example app (foxbus)" => "https://github.com/integration-technology/foxbus"
      },
      files:
        ~w(lib priv c_src/*.c c_src/Makefile c_src/vendor platform docs/api.md mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end

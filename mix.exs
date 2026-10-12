defmodule NestGen2.MixProject do
  use Mix.Project

  @version "0.2.4"
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
        "Run your own Elixir app on a Wi-Fi-connected Nest Learning Thermostat (2nd gen) " <>
          "rooted with No Longer Evil: round display, dial and press, piezo, motion, light " <>
          "and climate sensors, Wi-Fi setup, and scripts to install it and deploy apps.",
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
        "Install guide" => "#{@source_url}/blob/main/docs/install.md",
        "Rooting (No Longer Evil)" => "https://docs.nolongerevil.com/hosted/installation",
        "Example app (foxbus)" => "https://github.com/integration-technology/foxbus"
      },
      files:
        ~w(lib priv c_src/*.c c_src/Makefile c_src/vendor platform docs/api.md docs/install.md
           examples/hello_nest/lib examples/hello_nest/mix.exs examples/hello_nest/README.md
           mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end

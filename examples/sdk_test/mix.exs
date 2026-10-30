defmodule SdkTest.MixProject do
  use Mix.Project

  def project do
    [
      app: :sdk_test,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      # The SDK in this repository, so a build can be tried on a Nest before release.
      deps: [{:nest_gen2, path: "../.."}],
      aliases: [test: "test --no-start"]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {SdkTest.Application, []}]
  end
end

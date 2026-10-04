defmodule HelloNest.MixProject do
  use Mix.Project

  def project do
    [
      app: :hello_nest,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: [{:nest_gen2, "~> 0.2.1"}]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {HelloNest.Application, []}]
  end
end

defmodule NestGen2.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    NestGen2.Network.configure_dns()

    children = [
      {Registry, keys: :duplicate, name: NestGen2.Registry},
      NestGen2.Clock,
      NestGen2.Wifi,
      NestGen2.Piezo,
      NestGen2.Backlight,
      NestGen2.Text,
      NestGen2.Display,
      NestGen2.Backplate,
      NestGen2.Dial,
      NestGen2.Power
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: NestGen2.Supervisor)
  end
end

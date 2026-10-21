defmodule NestGen2.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    unless NestGen2.Config.host?(), do: NestGen2.Network.configure_dns()

    children =
      [
        {Registry, keys: :duplicate, name: NestGen2.Registry},
        NestGen2.Clock,
        NestGen2.Wifi,
        NestGen2.Piezo,
        NestGen2.Backlight,
        NestGen2.Text,
        NestGen2.Display,
        NestGen2.Backplate,
        NestGen2.Dial,
        NestGen2.Gesture,
        NestGen2.Power
      ] ++ host_viewer()

    Supervisor.start_link(children, strategy: :one_for_one, name: NestGen2.Supervisor)
  end

  # On a computer, the screen in a browser (see docs/host.md).
  defp host_viewer do
    if NestGen2.Config.host?() and NestGen2.Config.get(:host_viewer),
      do: [NestGen2.Host.Viewer],
      else: []
  end
end

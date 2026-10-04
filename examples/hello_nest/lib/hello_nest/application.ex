defmodule HelloNest.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([HelloNest], strategy: :one_for_one, name: HelloNest.Supervisor)
  end
end

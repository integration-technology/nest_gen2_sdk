defmodule HelloNest do
  @moduledoc """
  The smallest useful nest_gen2 app: a number you change with the ring, reset
  with a press, and the room temperature underneath.
  """
  use GenServer
  alias NestGen2.Display

  @background "#1C1C1E"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    NestGen2.subscribe([:dial_step, :button, :climate])
    state = %{count: 0, temperature: nil}
    draw(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:nest_gen2, :dial_step, %{direction: direction}}, state) do
    NestGen2.Piezo.click()
    state = %{state | count: state.count + if(direction == :cw, do: 1, else: -1)}
    draw(state)
    {:noreply, state}
  end

  def handle_info({:nest_gen2, :button, :down}, state) do
    state = %{state | count: 0}
    draw(state)
    {:noreply, state}
  end

  def handle_info({:nest_gen2, :climate, %{temperature_c: t}}, state) do
    state = %{state | temperature: t}
    draw(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp draw(state) do
    text = [align: :center, background: @background]
    Display.set_background(@background)
    Display.put_text(160, 70, "Hello, Nest", text ++ [size: 30])
    Display.put_text(160, 120, Integer.to_string(state.count), text ++ [size: 72])

    if state.temperature do
      Display.put_text(
        160,
        220,
        "#{Float.round(state.temperature, 1)} °C",
        text ++ [size: 24, color: "#A0A0A0"]
      )
    end

    Display.present()
  end
end

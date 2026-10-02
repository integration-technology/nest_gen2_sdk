defmodule NestGen2.Dial do
  @moduledoc """
  The ring and its press.

  The ring is read by an ADBS-A350 optical sensor at a fixed 750 cpi: about
  7800 counts per turn. There is no absolute position, so the angle is relative
  to start-up (or `reset_angle/0`) and can drift a few degrees over many turns.

  Events: `:dial` for every movement, `:dial_step` each time the angle crosses a
  multiple of the step size (default 10°, with Nest's click), `:button` on press.

  Do not ask users to hold the press: a long hold triggers the power chip's
  hardware reset.
  """
  use GenServer
  alias NestGen2.Piezo

  @rotary "/dev/input/event1"
  @button "/dev/input/event2"
  @ev_key 1
  @ev_rel 2
  @rel_x 0

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Degrees turned clockwise since start-up or the last reset."
  @spec angle() :: float
  def angle, do: GenServer.call(__MODULE__, :angle)

  @spec reset_angle() :: :ok
  def reset_angle, do: GenServer.call(__MODULE__, :reset)

  @doc "Degrees between `:dial_step` events, or nil for none."
  @spec set_step(pos_integer | nil) :: :ok
  def set_step(degrees), do: GenServer.call(__MODULE__, {:put, :step, degrees})

  @doc "Calibration: sensor counts per full turn (default 7800)."
  @spec set_counts_per_turn(pos_integer) :: :ok
  def set_counts_per_turn(counts) when is_integer(counts) and counts > 0,
    do: GenServer.call(__MODULE__, {:put, :counts, counts})

  @impl true
  def init(nil) do
    {:ok,
     %{
       rotary: open(@rotary),
       button: open(@button),
       angle: 0.0,
       step: NestGen2.Config.get(:dial_step_degrees),
       counts: NestGen2.Config.get(:dial_counts_per_turn)
     }}
  end

  @impl true
  def handle_call(:angle, _from, s), do: {:reply, s.angle, s}
  def handle_call(:reset, _from, s), do: {:reply, :ok, %{s | angle: 0.0}}
  def handle_call({:put, key, value}, _from, s), do: {:reply, :ok, Map.put(s, key, value)}

  @impl true
  def handle_info({port, {:data, {_, line}}}, s) do
    case String.split(line) do
      ["ev", type, code, value] ->
        {:noreply,
         event(
           port,
           String.to_integer(type),
           String.to_integer(code),
           String.to_integer(value),
           s
         )}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({port, {:exit_status, _}}, %{rotary: port} = s),
    do: {:noreply, %{s | rotary: open(@rotary)}}

  def handle_info({port, {:exit_status, _}}, %{button: port} = s),
    do: {:noreply, %{s | button: open(@button)}}

  def handle_info(_other, s), do: {:noreply, s}

  defp event(port, @ev_rel, @rel_x, counts, %{rotary: port} = s) do
    {angle, delta, step} = rotate(s.angle, counts, s.counts, s.step)
    NestGen2.publish(:dial, %{delta: delta, angle: angle})

    if step do
      NestGen2.publish(:dial_step, %{direction: step, angle: angle})
      Piezo.step_click()
    end

    %{s | angle: angle}
  end

  defp event(port, @ev_key, _code, value, %{button: port} = s) do
    case value do
      1 -> button(:down)
      0 -> button(:up)
      _ -> :ok
    end

    s
  end

  defp event(_port, _type, _code, _value, s), do: s

  @doc false
  # Applies raw sensor counts to the angle. The sensor counts negative for
  # clockwise (Nest's rotarygain is -1024). Returns {angle, delta, step} where
  # step is :cw/:ccw if a multiple of step_degrees was crossed, else nil.
  def rotate(angle, counts, counts_per_turn, step_degrees) do
    delta = -counts * 360 / counts_per_turn
    new_angle = angle + delta

    step =
      if step_degrees && floor(new_angle / step_degrees) != floor(angle / step_degrees),
        do: if(delta > 0, do: :cw, else: :ccw)

    {new_angle, delta, step}
  end

  defp button(state) do
    NestGen2.Trace.write("button #{state}")
    NestGen2.publish(:button, state)
  end

  defp open(device) do
    Port.open({:spawn_executable, NestGen2.Config.native("evwatch")}, [
      {:args, [device]},
      {:line, 256},
      :binary,
      :exit_status
    ])
  end
end

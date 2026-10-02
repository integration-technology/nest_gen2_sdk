defmodule NestGen2.Backlight do
  @moduledoc """
  The LM3530 backlight.

  `set/1` sets the level used while the screen is awake (0..120; the stock UI
  uses 113). `NestGen2.Power` switches it off while asleep. The SDK re-writes the
  current value every second, because the panel goes dark about a minute after
  the last write.
  """
  use GenServer

  @brightness "/sys/class/backlight/3-0036/brightness"
  @chip "/sys/devices/platform/omap/omap_i2c.3/i2c-3/3-0036"
  # ramp_rise_rate / ramp_fall_rate take an index into these times (ms).
  @ramp_ms [1, 130, 260, 520, 1000, 2000, 4000, 8000]
  @max_level 120
  @reassert_ms 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Level used while the screen is awake, 0..120."
  @spec set(0..120) :: :ok
  def set(level) when level in 0..@max_level, do: GenServer.call(__MODULE__, {:set, level})

  @spec level() :: 0..120
  def level, do: GenServer.call(__MODULE__, :level)

  @doc """
  Hardware fade times. Each is rounded to the nearest the chip supports:
  1, 130, 260, 520, 1000, 2000, 4000 or 8000 ms. Stock: 260 up, 2000 down.
  """
  @spec set_fade(pos_integer, pos_integer) :: :ok
  def set_fade(rise_ms, fall_ms) do
    File.write!(Path.join(@chip, "ramp_rise_rate"), Integer.to_string(ramp_index(rise_ms)))
    File.write!(Path.join(@chip, "ramp_fall_rate"), Integer.to_string(ramp_index(fall_ms)))
  end

  @doc false
  def on, do: GenServer.call(__MODULE__, {:output, :on})

  @doc false
  def off, do: GenServer.call(__MODULE__, {:output, :off})

  @impl true
  def init(nil) do
    set_fade(NestGen2.Config.get(:fade_rise_ms), NestGen2.Config.get(:fade_fall_ms))
    state = %{level: NestGen2.Config.get(:backlight_level), on: true}
    write(state)
    Process.send_after(self(), :reassert, @reassert_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:set, level}, _from, state) do
    state = %{state | level: level}
    write(state)
    {:reply, :ok, state}
  end

  def handle_call(:level, _from, state), do: {:reply, state.level, state}

  def handle_call({:output, which}, _from, state) do
    state = %{state | on: which == :on}
    write(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:reassert, state) do
    write(state)
    Process.send_after(self(), :reassert, @reassert_ms)
    {:noreply, state}
  end

  defp write(%{on: true, level: level}), do: File.write(@brightness, "#{level}\n")
  defp write(%{on: false}), do: File.write(@brightness, "0\n")

  @doc false
  def ramp_index(ms) do
    @ramp_ms
    |> Enum.with_index()
    |> Enum.min_by(fn {t, _} -> abs(t - ms) end)
    |> elem(1)
  end
end

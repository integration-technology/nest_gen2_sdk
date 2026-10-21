defmodule NestGen2.Host do
  @moduledoc """
  Running an app on a computer instead of a Nest, for developing and testing
  screens without deploying (see `docs/host.md`).

  With `config :nest_gen2, target: :host` the SDK starts as usual but touches no
  hardware: the screen is drawn in memory (`NestGen2.Display.snapshot/0`), the
  ring and its press come from these functions or the browser viewer
  (`NestGen2.Host.Viewer`), the climate is a steady simulated reading, and
  deep sleep, the clock and Wi-Fi are left alone.

  These functions produce the same events as the real hardware, so the app
  can't tell the difference.
  """
  alias NestGen2.{Dial, Display, Image}

  @doc "Turns the ring by `degrees`, clockwise if positive."
  @spec turn(number) :: :ok
  def turn(degrees), do: Dial.turn(degrees)

  @doc "Turns the ring one step (`NestGen2.Dial.set_step/1`) clockwise or anticlockwise."
  @spec step(:cw | :ccw) :: :ok
  def step(direction) when direction in [:cw, :ccw] do
    degrees = Dial.step() || 10
    turn(if direction == :cw, do: degrees, else: -degrees)
  end

  @doc "A short press of the ring."
  @spec click() :: :ok
  def click do
    Dial.press(:down)
    Process.sleep(60)
    Dial.press(:up)
  end

  @doc "Two quick presses (a `:double_click` gesture)."
  @spec double_click() :: :ok
  def double_click do
    click()
    Process.sleep(80)
    click()
  end

  @doc "A press held long enough for a `:long_press` gesture."
  @spec long_press() :: :ok
  def long_press do
    Dial.press(:down)
    Process.sleep(NestGen2.Config.get(:button_long_press_ms) + 100)
    Dial.press(:up)
  end

  @doc "Someone moving near the Nest (wakes the screen if motion is a wake source)."
  @spec motion(0..10) :: :ok
  def motion(level \\ 5) do
    NestGen2.publish(:motion, %{level: level, near: true, far: false})
    :ok
  end

  @doc "Sets the simulated room reading and sends it as a `:climate` event."
  @spec climate(number, number) :: :ok
  def climate(temperature_c, humidity_pct),
    do: GenServer.call(NestGen2.Backplate, {:host_climate, temperature_c, humidity_pct})

  @doc "The screen as a PNG."
  @spec screenshot() :: binary
  def screenshot, do: Image.to_png(Display.snapshot())
end

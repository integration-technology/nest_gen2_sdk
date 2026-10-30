defmodule SdkTest do
  @moduledoc """
  Shows every event the SDK sends, newest first, to check a Nest and an SDK
  build: press, double press, long press, dial left and right, movement near
  and far, light, battery, screen on and off, Wi-Fi. Each line also goes to the
  app's log, so a run can be read back after a crash or a restart.

  The ring moves through a small menu; a long press runs the item shown.
  """
  use GenServer
  require Logger
  alias NestGen2.{Display, Piezo, Power, Wifi}

  @background "#1C1C1E"
  @menu ["Beep", "Screen off", "Deep sleep on/off", "Wi-Fi status", "Clear log"]
  @lines 7
  @draw_after_ms 150

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    NestGen2.subscribe([:gesture, :dial_step, :motion, :light, :battery, :climate, :power, :wifi])
    # Awake all the time, the Nest drains its battery even on its base.
    Power.set_deep_sleep(true)

    state = %{
      log: [],
      menu: 0,
      deep_sleep: true,
      motion: {false, false},
      climate: nil,
      battery: nil,
      draw: nil
    }

    {:ok, state |> note("started, SDK #{NestGen2.version()}") |> draw_soon()}
  end

  @impl true
  def handle_info({:nest_gen2, :gesture, :click}, s), do: noted(s, "press")
  def handle_info({:nest_gen2, :gesture, :double_click}, s), do: noted(s, "double press")

  def handle_info({:nest_gen2, :gesture, :long_press}, s) do
    item = Enum.at(@menu, s.menu)
    {:noreply, run(item, note(s, "long press: #{item}"))}
  end

  def handle_info({:nest_gen2, :dial_step, %{direction: dir}}, s) do
    s = %{s | menu: step_menu(s.menu, dir)}
    noted(s, if(dir == :cw, do: "dial right", else: "dial left"))
  end

  def handle_info({:nest_gen2, :motion, %{near: near, far: far}}, s) do
    if {near, far} == s.motion,
      do: {:noreply, s},
      else: noted(%{s | motion: {near, far}}, motion_text(near, far))
  end

  def handle_info({:nest_gen2, :light, %{level: level}}, s), do: noted(s, "light #{level}")

  def handle_info({:nest_gen2, :battery, %{millivolts: mv}}, s),
    do: noted(%{s | battery: mv}, "battery #{mv} mV")

  def handle_info({:nest_gen2, :climate, %{temperature_c: t}}, s),
    do: {:noreply, draw_soon(%{s | climate: t})}

  def handle_info({:nest_gen2, :power, power}, s),
    do: noted(s, if(power == :awake, do: "screen on", else: "screen off"))

  def handle_info({:nest_gen2, :wifi, status}, s), do: noted(s, "wifi #{status[:state]}")

  def handle_info(:draw, s) do
    draw(s)
    {:noreply, %{s | draw: nil}}
  end

  def handle_info(_other, s), do: {:noreply, s}

  defp run("Beep", s), do: Piezo.click() && s
  defp run("Screen off", s), do: Power.sleep() && s
  defp run("Clear log", s), do: %{s | log: []} |> draw_soon()

  defp run("Wi-Fi status", s) do
    w = Wifi.status()
    note(s, "wifi #{w.state} #{w.ssid} #{w.signal_dbm} dBm")
  end

  defp run("Deep sleep on/off", s) do
    on? = not s.deep_sleep
    Power.set_deep_sleep(on?)
    note(%{s | deep_sleep: on?}, "deep sleep #{if on?, do: "on", else: "off"}")
  end

  defp noted(s, text), do: {:noreply, note(s, text)}

  defp note(s, text) do
    Logger.info("sdk_test: #{text}")
    draw_soon(%{s | log: add_line(s.log, text, Time.utc_now())})
  end

  @doc false
  # Newest first; a repeat of the newest line counts up instead of filling the log.
  def add_line([{text, n, _} | rest], text, time), do: [{text, n + 1, time} | rest]
  def add_line(log, text, time), do: Enum.take([{text, 1, time} | log], @lines)

  @doc false
  def step_menu(i, :cw), do: rem(i + 1, length(@menu))
  def step_menu(i, :ccw), do: rem(i - 1 + length(@menu), length(@menu))

  defp motion_text(true, _), do: "movement near"
  defp motion_text(false, true), do: "movement far"
  defp motion_text(false, false), do: "no movement"

  # Events can come many a second (the ring): draw once they pause.
  defp draw_soon(%{draw: nil} = s),
    do: %{s | draw: Process.send_after(self(), :draw, @draw_after_ms)}

  defp draw_soon(s), do: s

  defp draw(s) do
    text = [align: :center, background: @background]
    Display.set_background(@background)
    Display.put_text(160, 36, "SDK test #{NestGen2.version()}", text ++ [size: 18])
    Display.put_text(160, 60, status(s), text ++ [size: 16, color: "#9A9AA0"])

    Display.put_text(
      160,
      88,
      "‹ #{Enum.at(@menu, s.menu)} ›",
      text ++ [size: 22, color: "#FF9F0A"]
    )

    s.log
    |> Enum.with_index()
    |> Enum.each(fn {{line, n, time}, i} ->
      count = if n > 1, do: " ×#{n}", else: ""
      color = if i == 0, do: "#FFFFFF", else: "#9A9AA0"
      stamp = time |> Time.truncate(:second) |> Time.to_string()

      Display.put_text(
        160,
        126 + i * 22,
        "#{stamp} #{line}#{count}",
        text ++ [size: 16, color: color]
      )
    end)

    Display.present()
  end

  defp status(s) do
    temp = if s.climate, do: "#{Float.round(s.climate, 1)} °C", else: "-- °C"
    battery = if s.battery, do: "#{Float.round(s.battery / 1000, 2)} V", else: "-- V"
    "#{temp} · #{battery} · deep sleep #{if s.deep_sleep, do: "on", else: "off"}"
  end
end

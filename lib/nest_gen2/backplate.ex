defmodule NestGen2.Backplate do
  @moduledoc """
  The link to the backplate (or desk stand) microcontroller on `/dev/ttyO2`.

  Always runs the keep-alive: every 30 s it repeats the stock client's `0x83`,
  `0xa2`, `0xa3` exchange, without which the backplate power-cycles the head unit
  about 36 minutes after it last heard from it. Each time the link opens it
  wakes the backplate the way Nest's own client does (a serial BREAK, then
  answering its hello), and does so again if the backplate falls silent, which
  it does after a reset or a power loss. Decoded readings are published as
  `:motion`, `:climate` and `:battery` events and are available through
  `NestGen2.Motion`, `NestGen2.Climate` and `NestGen2.Battery`.

  `status/0`, `subscribe_raw/0` and `send_raw/2` are for decoding messages the SDK
  does not cover yet, and may change between minor versions.
  """
  use GenServer
  require Logger
  alias NestGen2.Backplate.{Decode, Frame, Handshake}

  @tty "/dev/ttyO2"
  @cycle_ms 30_000
  @a2_delay_ms 1900
  @a3_delay_ms 150
  @reopen_ms 5000
  # The backplate sends readings every second; this long without one means it
  # has gone silent and needs waking, at most once per @wake_retry_ms.
  @silence_check_ms 5_000
  @silent_ms 15_000
  @wake_retry_ms 60_000
  @raw_key :__backplate_raw__
  # Light samples (one a second) compared when looking for a sudden change.
  @light_window 5

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec status() :: %{
          connected: boolean,
          frames_received: non_neg_integer,
          last_frame_at: DateTime.t() | nil,
          restarts: non_neg_integer
        }
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Subscribes the caller to every frame as `{:nest_gen2_backplate, cmd, payload}`."
  @spec subscribe_raw() :: :ok
  def subscribe_raw do
    {:ok, _} = Registry.register(NestGen2.Registry, @raw_key, nil)
    :ok
  end

  @doc "Sends a command frame to the backplate."
  @spec send_raw(0..0xFFFF, binary) :: :ok
  def send_raw(cmd, payload \\ <<>>), do: GenServer.cast(__MODULE__, {:send, cmd, payload})

  @doc false
  # Tells the base the head is about to suspend for `seconds`, as Nest's
  # client does; the base then stays quiet until then or until it has
  # something to wake the head for. Call resumed/0 straight after the wake-up.
  def sleep_notice(seconds), do: call_if_running({:sleep_notice, seconds})

  @doc false
  # After a suspend: the exchange Nest's client opens with on waking (83, a2,
  # a3), after which the base sends what it kept and resumes its readings.
  def resumed, do: call_if_running(:resumed)

  defp call_if_running(msg) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, msg), else: :ok
  end

  @doc false
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @doc false
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})

  @impl true
  def init(nil) do
    send(self(), :cycle)
    Process.send_after(self(), :silence_check, @silence_check_ms)

    {:ok,
     %{
       port: open(),
       rx: <<>>,
       frames: 0,
       last_frame_at: nil,
       last_rx: nil,
       handshake: 0,
       last_handshake: nil,
       info: %{},
       awake_once: false,
       restarts: 0,
       motion_level: 0,
       near: false,
       far: false,
       raw_temperature_c: nil,
       humidity_pct: nil,
       board_temperatures_c: [],
       battery_mv: nil,
       light: nil,
       light_window: [],
       motion_threshold: NestGen2.Config.get(:motion_threshold),
       temperature_offset_c: NestGen2.Config.get(:temperature_offset_c)
     }}
  end

  @impl true
  def handle_call(:status, _from, s) do
    {:reply,
     %{
       connected: s.port != nil,
       frames_received: s.frames,
       last_frame_at: s.last_frame_at,
       restarts: s.restarts
     }, s}
  end

  def handle_call({:get, key}, _from, s), do: {:reply, Map.fetch!(s, key), s}
  def handle_call({:put, key, value}, _from, s), do: {:reply, :ok, Map.put(s, key, value)}

  def handle_call({:sleep_notice, seconds}, _from, s) do
    # The room temperature as the base last gave it, uncorrected, as Nest's
    # client sends it; 22.71 degC (Nest's value) until a reading has arrived.
    centi = if s.raw_temperature_c, do: round(s.raw_temperature_c * 100), else: 2271
    seconds = seconds |> max(1) |> min(0xFFFF)

    for {cmd, payload} <- Handshake.sleep_burst(centi, seconds), do: tx(s, cmd, payload)
    {:reply, :ok, s}
  end

  def handle_call(:resumed, _from, s) do
    tx(s, 0x83)
    Process.send_after(self(), :a2, 200)
    # Readings from before the sleep mustn't look like a sudden change in
    # light, and the quiet spell mustn't look like a silent base.
    {:reply, :ok, %{s | last_rx: now(), light_window: []}}
  end

  @impl true
  def handle_cast({:send, cmd, payload}, s) do
    tx(s, cmd, payload)
    {:noreply, s}
  end

  @impl true
  def handle_info(:cycle, s) do
    tx(s, 0x83)
    Process.send_after(self(), :a2, @a2_delay_ms)
    Process.send_after(self(), :cycle, @cycle_ms)
    {:noreply, s}
  end

  def handle_info(:a2, s) do
    tx(s, 0xA2)
    Process.send_after(self(), :a3, @a3_delay_ms)
    {:noreply, s}
  end

  def handle_info(:a3, s) do
    tx(s, 0xA3)
    {:noreply, s}
  end

  # Bytes from the serial line, in whatever chunks they arrived: cut them
  # into frames (keeping any partial frame for next time) and handle each.
  def handle_info({port, {:data, <<?r, bytes::binary>>}}, %{port: port} = s) do
    {frames, rx} = Frame.parse(s.rx <> bytes)
    {:noreply, Enum.reduce(frames, %{s | rx: rx}, &handle_rx/2)}
  end

  # bplink has opened the port: wake the backplate.
  def handle_info({port, {:data, <<?o, _path::binary>>}}, %{port: port} = s),
    do: {:noreply, wake(s)}

  def handle_info({port, {:data, <<?e, text::binary>>}}, %{port: port} = s) do
    Logger.warning("bplink: #{text}")
    {:noreply, s}
  end

  # One step of the wake handshake; steps from an earlier handshake are dropped.
  def handle_info({:handshake, n, action, rest}, %{handshake: n} = s) do
    case action do
      {:tx, cmd, payload} -> tx(s, cmd, payload)
      :brk -> brk(s)
      :no_hello -> Logger.warning("backplate did not answer the wake-up BREAK")
      :done -> log_awake(s)
    end

    s = if action == :done, do: %{s | awake_once: true}, else: s
    {:noreply, steps(s, rest)}
  end

  def handle_info({:handshake, _stale, _action, _rest}, s), do: {:noreply, s}

  def handle_info(:silence_check, s) do
    Process.send_after(self(), :silence_check, @silence_check_ms)

    if s.port != nil and
         Handshake.wake?(now(), s.last_rx, s.last_handshake, @silent_ms, @wake_retry_ms) do
      Logger.warning(
        "backplate silent for #{now() - (s.last_rx || s.last_handshake)} ms; waking it"
      )

      {:noreply, wake(s)}
    else
      {:noreply, s}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
    Logger.warning("bplink exited with status #{status}; reopening")
    Process.send_after(self(), :reopen, @reopen_ms)
    {:noreply, %{s | port: nil}}
  end

  def handle_info(:reopen, s), do: {:noreply, %{s | port: open()}}
  def handle_info(_other, s), do: {:noreply, s}

  defp handle_rx({cmd, payload}, s) do
    NestGen2.Trace.write(["rx ", hex4(cmd), " ", Base.encode16(payload, case: :lower)])

    Registry.dispatch(NestGen2.Registry, @raw_key, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:nest_gen2_backplate, cmd, payload})
    end)

    s = %{s | frames: s.frames + 1, last_frame_at: DateTime.utc_now(), last_rx: now()}
    handle_frame(Decode.decode(cmd, payload), s)
  end

  defp hex4(cmd),
    do: cmd |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")

  defp handle_frame({:motion_level, level}, s) do
    if level >= s.motion_threshold, do: publish_motion(s, level)
    %{s | motion_level: level}
  end

  defp handle_frame({:pir, near, far}, s) do
    if near or far, do: publish_motion(%{s | near: near, far: far}, s.motion_level)
    %{s | near: near, far: far}
  end

  defp handle_frame({:climate, raw_c, rh}, s) do
    NestGen2.publish(:climate, %{
      temperature_c: Float.round(raw_c + s.temperature_offset_c, 2),
      humidity_pct: rh
    })

    write_calibration(%{s | raw_temperature_c: raw_c, humidity_pct: rh})
  end

  defp handle_frame({:board_temperatures, temps}, s),
    do: write_calibration(%{s | board_temperatures_c: temps})

  defp handle_frame({:battery, mv}, s) do
    if mv != s.battery_mv, do: NestGen2.publish(:battery, %{millivolts: mv})
    %{s | battery_mv: mv}
  end

  defp handle_frame({:light, level}, s) do
    window = Enum.take([level | s.light_window], @light_window)

    window =
      if NestGen2.Light.changed?(window,
           flicker_pct: NestGen2.Config.get(:light_wake_flicker_pct),
           jump_pct: NestGen2.Config.get(:light_wake_jump_pct),
           min_delta: NestGen2.Config.get(:light_wake_min_delta)
         ) do
        NestGen2.publish(:light, %{level: level})
        # Start afresh so one change is reported once.
        [level]
      else
        window
      end

    %{s | light: level, light_window: window}
  end

  # The backplate restarted (after our BREAK, or by itself): answer its hello.
  # A loose head unit on its base, or a base power blip, restarts it now and
  # then; each restart after the first wake-up is counted rather than logged.
  defp handle_frame({:hello, hello}, s) do
    restarts = if s.awake_once, do: s.restarts + 1, else: s.restarts
    s = %{s | handshake: s.handshake + 1, restarts: restarts}
    steps(s, Handshake.hello_steps(hello) ++ [{0, :done}])
  end

  defp handle_frame({:info, key, value}, s), do: %{s | info: Map.put(s.info, key, value)}

  defp handle_frame({:wake_reason, flags}, s) do
    NestGen2.Trace.write("base wake reason #{Integer.to_string(flags, 16)}")
    s
  end

  # Text the backplate prints around a restart: "BRK", its firmware banner,
  # sensor self-test ("*sense ...") and, with no heating system wired to it,
  # "*HVAC power lost". Anything else is new, so worth seeing.
  defp handle_frame({:message, text}, s) do
    unless restart_chatter?(text), do: Logger.debug("backplate: #{text}")
    s
  end

  defp handle_frame(:unknown, s), do: s

  @doc false
  def restart_chatter?(text) do
    text == "BRK" or String.starts_with?(text, ["*sense", "*HVAC"]) or
      Regex.match?(~r/^\d+\.\d+\.\d+ \d{4}-\d\d-\d\d/, text)
  end

  defp log_awake(%{awake_once: false} = s), do: Logger.info("backplate awake: #{inspect(s.info)}")

  defp log_awake(s),
    do: Logger.debug("backplate restarted and woken again (#{s.restarts} since start)")

  defp wake(s) do
    s = %{s | handshake: s.handshake + 1, last_handshake: now()}
    steps(s, Handshake.start_steps() ++ [{Handshake.hello_timeout_ms(), :no_hello}])
  end

  defp steps(s, []), do: s

  defp steps(s, [{delay, action} | rest]) do
    Process.send_after(self(), {:handshake, s.handshake, action, rest}, delay)
    s
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Optional, for calibrating the temperature correction: when :calibration_file
  # is set (use a tmpfs path such as /tmp, not flash), keep the latest raw
  # readings there as "raw_c humidity board1 board2 board3".
  defp write_calibration(%{raw_temperature_c: raw, board_temperatures_c: [a, b, c]} = s)
       when is_number(raw) do
    # A charlist when set from the erl command line, a binary from config.
    with path when is_binary(path) or is_list(path) <-
           Application.get_env(:nest_gen2, :calibration_file) do
      File.write(path, "#{raw} #{s.humidity_pct} #{a} #{b} #{c}\n")
    end

    s
  end

  defp write_calibration(s), do: s

  defp publish_motion(s, level),
    do: NestGen2.publish(:motion, %{level: level, near: s.near, far: s.far})

  defp tx(state, cmd, payload \\ <<>>)
  defp tx(%{port: nil}, _cmd, _payload), do: :ok

  defp tx(%{port: port}, cmd, payload) do
    NestGen2.Trace.write(
      "tx #{Integer.to_string(cmd, 16)} #{Base.encode16(payload, case: :lower)}"
    )

    Port.command(port, [?w, Frame.encode(cmd, payload)])
  end

  defp brk(%{port: nil}), do: :ok

  defp brk(%{port: port}) do
    NestGen2.Trace.write("brk")
    Port.command(port, <<?b>>)
  end

  defp open do
    Port.open({:spawn_executable, NestGen2.Config.native("bplink")}, [
      {:args, [@tty]},
      {:packet, 2},
      :binary,
      :exit_status,
      :use_stdio
    ])
  end
end

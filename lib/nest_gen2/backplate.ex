defmodule NestGen2.Backplate do
  @moduledoc """
  The link to the backplate (or desk stand) microcontroller on `/dev/ttyO2`.

  Always runs the keep-alive: every 30 s it repeats the stock client's `0x83`,
  `0xa2`, `0xa3` exchange, without which the backplate power-cycles the head unit
  about 36 minutes after it last heard from it. Decoded readings are published as
  `:motion`, `:climate` and `:battery` events and are available through
  `NestGen2.Motion`, `NestGen2.Climate` and `NestGen2.Battery`.

  `status/0`, `subscribe_raw/0` and `send_raw/2` are for decoding messages the SDK
  does not cover yet, and may change between minor versions.
  """
  use GenServer
  require Logger
  alias NestGen2.Backplate.Decode

  @tty "/dev/ttyO2"
  @cycle_ms 30_000
  @a2_delay_ms 1900
  @a3_delay_ms 150
  @reopen_ms 5000
  @raw_key :__backplate_raw__
  # Light samples (one a second) compared when looking for a sudden change.
  @light_window 5

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec status() :: %{
          connected: boolean,
          frames_received: non_neg_integer,
          last_frame_at: DateTime.t() | nil
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
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @doc false
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})

  @impl true
  def init(nil) do
    send(self(), :cycle)

    {:ok,
     %{
       port: open(),
       frames: 0,
       last_frame_at: nil,
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
     %{connected: s.port != nil, frames_received: s.frames, last_frame_at: s.last_frame_at}, s}
  end

  def handle_call({:get, key}, _from, s), do: {:reply, Map.fetch!(s, key), s}
  def handle_call({:put, key, value}, _from, s), do: {:reply, :ok, Map.put(s, key, value)}

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

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = s) do
    NestGen2.Trace.write(line)

    case Decode.parse_line(line) do
      {:ok, cmd, payload} ->
        Registry.dispatch(NestGen2.Registry, @raw_key, fn entries ->
          for {pid, _} <- entries, do: send(pid, {:nest_gen2_backplate, cmd, payload})
        end)

        s = %{s | frames: s.frames + 1, last_frame_at: DateTime.utc_now()}
        {:noreply, handle_frame(Decode.decode(cmd, payload), s)}

      :ignore ->
        if String.starts_with?(line, "err"), do: Logger.warning("bplink: #{line}")
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

  defp handle_frame(:unknown, s), do: s

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
    hex = Base.encode16(payload, case: :lower)
    NestGen2.Trace.write("tx #{Integer.to_string(cmd, 16)} #{hex}")
    Port.command(port, "tx #{Integer.to_string(cmd, 16)} #{hex}\n")
  end

  defp open do
    Port.open({:spawn_executable, NestGen2.Config.native("bplink")}, [
      {:args, [@tty]},
      {:line, 4096},
      :binary,
      :exit_status,
      :use_stdio
    ])
  end
end

defmodule NestGen2.Piezo do
  @moduledoc """
  The piezo buzzer (pwm-beeper on `/dev/input/event0`).

  `click/0` plays Nest's own dial click: 2000 Hz for 3 ms, from the stock
  `product.config`.
  """
  use GenServer

  @device "/dev/input/event0"
  @click_hz 2000
  @click_ms 3
  @min_click_gap_ms 15
  @ev_syn 0x00
  @ev_snd 0x12
  @snd_tone 0x02

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Plays a tone; returns immediately."
  @spec tone(pos_integer, pos_integer) :: :ok
  def tone(hz, duration_ms), do: GenServer.cast(__MODULE__, {:tone, hz, duration_ms})

  @doc "Plays Nest's dial click. Clicks closer than 15 ms together are dropped."
  @spec click() :: :ok
  def click, do: GenServer.cast(__MODULE__, :click)

  @doc "Whether the dial clicks on every step (see `NestGen2.Dial.set_step/1`)."
  @spec set_click_on_step(boolean) :: :ok
  def set_click_on_step(on?) when is_boolean(on?),
    do: GenServer.call(__MODULE__, {:click_on_step, on?})

  @doc false
  def step_click, do: GenServer.cast(__MODULE__, :step_click)

  @impl true
  def init(nil) do
    {:ok, dev} = :file.open(@device, [:write, :raw, :binary])

    {:ok,
     %{dev: dev, last_click: 0, stop_ref: nil, click_on_step: NestGen2.Config.get(:click_on_step)}}
  end

  @impl true
  def handle_cast({:tone, hz, ms}, state), do: {:noreply, play(state, hz, ms)}

  def handle_cast(:click, state), do: {:noreply, click(state)}

  def handle_cast(:step_click, %{click_on_step: true} = state), do: {:noreply, click(state)}
  def handle_cast(:step_click, state), do: {:noreply, state}

  @impl true
  def handle_call({:click_on_step, on?}, _from, state),
    do: {:reply, :ok, %{state | click_on_step: on?}}

  @impl true
  def handle_info({:stop, ref}, %{stop_ref: ref} = state) do
    write_tone(state.dev, 0)
    {:noreply, %{state | stop_ref: nil}}
  end

  def handle_info({:stop, _stale}, state), do: {:noreply, state}

  defp click(state) do
    now = System.monotonic_time(:millisecond)

    if now - state.last_click >= @min_click_gap_ms do
      %{play(state, @click_hz, @click_ms) | last_click: now}
    else
      state
    end
  end

  defp play(state, hz, ms) do
    write_tone(state.dev, hz)
    ref = make_ref()
    Process.send_after(self(), {:stop, ref}, ms)
    %{state | stop_ref: ref}
  end

  # 16-byte input_event for this 32-bit kernel: zero timeval, type, code, value.
  defp write_tone(dev, hz) do
    :ok = :file.write(dev, [event(@ev_snd, @snd_tone, hz), event(@ev_syn, 0, 0)])
  end

  defp event(type, code, value),
    do: <<0::64, type::16-little, code::16-little, value::32-little-signed>>
end

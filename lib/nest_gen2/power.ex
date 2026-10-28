defmodule NestGen2.Power do
  @moduledoc """
  Screen wake and sleep.

  The screen wakes on any configured source (dial, button, motion, light) and
  sleeps after the idle timeout with no activity. Publishes `:power` events
  (`:awake` / `:asleep`).

  To keep the screen on (an alarm, a settings screen), take a hold:

      {:ok, hold} = NestGen2.Power.keep_awake(:alarm)
      # ... the screen is on and won't sleep from idleness ...
      :ok = NestGen2.Power.release(hold)

  Holds stack: idle sleep resumes once every hold is released, starting a fresh
  idle timeout then. A hold is released automatically if the process that took
  it exits, so a crash can't leave the screen on for good. `sleep/0` still turns
  the screen off when asked, holds or not.

  ## Deep sleep

  With `deep_sleep` on (config, or `set_deep_sleep/1`), once the screen has been
  asleep for `deep_sleep_after_ms` (10 s) with no holds, the whole system
  suspends to RAM, as Nest's own software does: the processor, radios and every
  process stop, and carry on exactly where they were when it wakes. That's what
  lets the battery charge on the base, which supplies only about 120 mA; awake
  all the time, the Nest drains its battery even on the base.

  It wakes on the button, on the base (which wakes it for motion), or after
  `deep_sleep_max_s` (270 s) to keep in touch with the base. A wake-up that
  doesn't wake the screen goes back to sleep after `deep_sleep_awake_ms` (8 s).
  While suspended nothing runs: timers pause (they count awake time only), Wi-Fi
  drops and reconnects within a few seconds of waking. Apps that show changing
  data should refresh it on `{:nest_gen2, :power, :awake}`.
  """
  use GenServer
  alias NestGen2.Backlight

  @tick_ms 1000
  @sources [:dial, :button, :motion, :light]
  # The screen's own glow must not count as a change in room light.
  @light_settle_ms 3000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec wake() :: :ok
  def wake, do: GenServer.call(__MODULE__, :wake)

  @spec sleep() :: :ok
  def sleep, do: GenServer.call(__MODULE__, :sleep)

  @spec awake?() :: boolean
  def awake?, do: GenServer.call(__MODULE__, :awake?)

  @doc """
  Wakes the screen and keeps it from sleeping when idle until `release/1`, or
  until the calling process exits. `reason` is any term, shown by `holds/0`.
  """
  @spec keep_awake(term) :: {:ok, reference}
  def keep_awake(reason \\ nil), do: GenServer.call(__MODULE__, {:keep_awake, reason})

  @doc "Releases a hold from `keep_awake/1`. Releasing an unknown hold is a no-op."
  @spec release(reference) :: :ok
  def release(hold) when is_reference(hold), do: GenServer.call(__MODULE__, {:release, hold})

  @doc "Current holds, for debugging."
  @spec holds() :: [%{ref: reference, reason: term, owner: pid}]
  def holds, do: GenServer.call(__MODULE__, :holds)

  @doc "Milliseconds without activity before sleeping, or :infinity (default 30_000)."
  @spec set_idle_timeout(pos_integer | :infinity) :: :ok
  def set_idle_timeout(ms), do: GenServer.call(__MODULE__, {:timeout, ms})

  @doc "Which events wake the screen and count as activity."
  @spec set_wake_sources([:dial | :button | :motion | :light]) :: :ok
  def set_wake_sources(sources), do: GenServer.call(__MODULE__, {:sources, sources})

  @doc "Turns deep sleep (suspend to RAM while the screen is asleep) on or off."
  @spec set_deep_sleep(boolean) :: :ok
  def set_deep_sleep(on?) when is_boolean(on?), do: GenServer.call(__MODULE__, {:deep_sleep, on?})

  @impl true
  def init(nil) do
    sources = NestGen2.Config.get(:wake_sources)
    NestGen2.subscribe(sources)
    Process.send_after(self(), :tick, @tick_ms)

    {:ok,
     %{
       awake: true,
       last_activity: now(),
       timeout: NestGen2.Config.get(:idle_timeout_ms),
       sources: sources,
       changed_at: now(),
       holds: %{},
       deep_sleep: NestGen2.Config.get(:deep_sleep),
       deep_timer: nil
     }}
  end

  @impl true
  def handle_call(:wake, _from, s), do: {:reply, :ok, activity(s)}
  def handle_call(:sleep, _from, s), do: {:reply, :ok, go_to_sleep(s)}
  def handle_call(:awake?, _from, s), do: {:reply, s.awake, s}
  def handle_call({:timeout, ms}, _from, s), do: {:reply, :ok, %{s | timeout: ms}}

  def handle_call({:keep_awake, reason}, {owner, _}, s) do
    monitor = Process.monitor(owner)
    holds = add_hold(s.holds, monitor, reason, owner)
    {:reply, {:ok, monitor}, activity(%{s | holds: holds})}
  end

  def handle_call({:release, ref}, _from, s) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, release_hold(s, ref)}
  end

  def handle_call(:holds, _from, s) do
    {:reply, for({ref, h} <- s.holds, do: Map.put(h, :ref, ref)), s}
  end

  def handle_call({:deep_sleep, on?}, _from, s) do
    s = %{cancel_deep(s) | deep_sleep: on?}
    s = if on? and not s.awake, do: schedule_deep(s, config(:deep_sleep_after_ms)), else: s
    {:reply, :ok, s}
  end

  def handle_call({:sources, sources}, _from, s) do
    true = Enum.all?(sources, &(&1 in @sources))
    NestGen2.unsubscribe(s.sources)
    NestGen2.subscribe(sources)
    {:reply, :ok, %{s | sources: sources}}
  end

  @impl true
  def handle_info({:nest_gen2, :light, _payload}, s) do
    if now() - s.changed_at < @light_settle_ms,
      do: {:noreply, s},
      else: handle_activity(:light, s)
  end

  def handle_info({:nest_gen2, topic, payload}, s), do: handle_activity({topic, payload}, s)

  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) when is_map_key(s.holds, ref),
    do: {:noreply, release_hold(s, ref)}

  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, @tick_ms)

    if map_size(s.holds) == 0 and idle?(s.awake, s.last_activity, s.timeout, now()),
      do: {:noreply, go_to_sleep(s)},
      else: {:noreply, s}
  end

  def handle_info(:deep_sleep, %{deep_sleep: true, awake: false, holds: holds} = s)
      when map_size(holds) == 0 do
    # Read before anything else, so a press from here on cancels the suspend.
    count = NestGen2.Suspend.wakeup_count()

    # A press the kernel counted before that read may already be queued here,
    # behind this message: handle it first, and sleep later.
    if elem(Process.info(self(), :message_queue_len), 1) > 0,
      do: {:noreply, schedule_deep(%{s | deep_timer: nil}, config(:deep_sleep_after_ms))},
      else: deep_sleep(s, count)
  end

  def handle_info(:deep_sleep, s), do: {:noreply, %{s | deep_timer: nil}}

  defp deep_sleep(s, count) do
    seconds = config(:deep_sleep_max_s)
    NestGen2.Trace.write("deep sleep, up to #{seconds} s")
    NestGen2.Backplate.sleep_notice(seconds, s.sources)

    case NestGen2.Suspend.sleep(seconds, count) do
      {:ok, slept} -> NestGen2.Trace.write("woke after #{slept} s")
      {:error, reason} -> NestGen2.Trace.write("suspend refused: #{inspect(reason)}")
    end

    NestGen2.Backplate.resumed()
    # Whatever woke us (button, motion) is in the mailbox and, if it's a wake
    # source, wakes the screen and cancels this; otherwise sleep again soon.
    {:noreply, schedule_deep(%{s | deep_timer: nil}, config(:deep_sleep_awake_ms))}
  end

  defp handle_activity(source, s) do
    unless s.awake, do: NestGen2.Trace.write("wake by #{inspect(source)}")
    {:noreply, activity(s)}
  end

  @doc false
  def add_hold(holds, ref, reason, owner),
    do: Map.put(holds, ref, %{reason: reason, owner: owner})

  # Releasing the last hold starts a fresh idle timeout, so the screen doesn't
  # go dark the moment a long hold ends.
  defp release_hold(s, ref) do
    holds = Map.delete(s.holds, ref)

    if map_size(holds) == 0 and map_size(s.holds) > 0,
      do: %{s | holds: holds, last_activity: now()},
      else: %{s | holds: holds}
  end

  @doc false
  # Whether an awake screen has gone longer than the timeout without activity.
  def idle?(false, _last, _timeout, _now), do: false
  def idle?(true, _last, :infinity, _now), do: false
  def idle?(true, last, timeout, now), do: now - last > timeout

  defp activity(%{awake: true} = s), do: %{s | last_activity: now()}

  defp activity(s) do
    s = cancel_deep(s)
    Backlight.on()
    NestGen2.publish(:power, :awake)
    %{s | awake: true, last_activity: now(), changed_at: now()}
  end

  defp go_to_sleep(%{awake: false} = s), do: s

  defp go_to_sleep(s) do
    NestGen2.Trace.write("sleep")
    Backlight.off()
    NestGen2.publish(:power, :asleep)
    s = %{s | awake: false, changed_at: now()}
    if s.deep_sleep, do: schedule_deep(s, config(:deep_sleep_after_ms)), else: s
  end

  # A computer never suspends for the app: deep sleep is a no-op on the host.
  defp schedule_deep(s, ms) do
    if NestGen2.Config.host?(), do: s, else: start_deep_timer(s, ms)
  end

  defp start_deep_timer(s, ms) do
    s = cancel_deep(s)
    %{s | deep_timer: Process.send_after(self(), :deep_sleep, ms)}
  end

  defp cancel_deep(%{deep_timer: nil} = s), do: s

  defp cancel_deep(s) do
    Process.cancel_timer(s.deep_timer)
    %{s | deep_timer: nil}
  end

  defp config(key), do: NestGen2.Config.get(key)

  defp now, do: System.monotonic_time(:millisecond)
end

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
       holds: %{}
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
    Backlight.on()
    NestGen2.publish(:power, :awake)
    %{s | awake: true, last_activity: now(), changed_at: now()}
  end

  defp go_to_sleep(%{awake: false} = s), do: s

  defp go_to_sleep(s) do
    NestGen2.Trace.write("sleep")
    Backlight.off()
    NestGen2.publish(:power, :asleep)
    %{s | awake: false, changed_at: now()}
  end

  defp now, do: System.monotonic_time(:millisecond)
end

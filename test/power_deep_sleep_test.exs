defmodule NestGen2.PowerDeepSleepTest do
  # Deep sleep against stand-in files for /sys/power/state, the RTC alarm and
  # the backplate line's wakeup setting; writing "mem" to a plain file returns
  # at once, like a suspend that's woken straight away.
  use ExUnit.Case, async: false
  alias NestGen2.Power

  defmodule FakeBacklight do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: NestGen2.Backlight)
    def init(nil), do: {:ok, nil}
    def handle_call({:output, _}, _from, s), do: {:reply, :ok, s}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "nest_gen2_suspend_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    env = [
      idle_timeout_ms: 100,
      wake_sources: [:button],
      deep_sleep: true,
      deep_sleep_after_ms: 50,
      deep_sleep_awake_ms: 10_000,
      deep_sleep_max_s: 270,
      power_state_path: Path.join(dir, "state"),
      wakeup_count_path: Path.join(dir, "wakeup_count"),
      rtc_wakealarm_path: Path.join(dir, "wakealarm"),
      backplate_wakeup_path: Path.join(dir, "wakeup")
    ]

    for {k, v} <- env, do: Application.put_env(:nest_gen2, k, v)

    on_exit(fn ->
      for {k, _} <- env, do: Application.delete_env(:nest_gen2, k)
      File.rm_rf(dir)
    end)

    start_supervised!({Registry, keys: :duplicate, name: NestGen2.Registry})
    start_supervised!(FakeBacklight)
    {:ok, dir: dir}
  end

  defp read(dir, name), do: File.read(Path.join(dir, name))

  defp wait_until(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end

  test "suspends once the screen has slept, waking for the base and an alarm", %{dir: dir} do
    start_supervised!(Power)
    wait_until(fn -> read(dir, "state") == {:ok, "mem"} end)
    assert read(dir, "wakeup") == {:ok, "enabled"}
    # The alarm is cleared after waking.
    assert read(dir, "wakealarm") == {:ok, "0"}
  end

  test "a refused suspend leaves no alarm armed", %{dir: dir} do
    # The kernel can refuse (e.g. a wake-up already pending); here the state
    # path is a directory, so the write fails.
    File.mkdir_p!(Path.join(dir, "state"))
    start_supervised!(Power)
    wait_until(fn -> match?({:ok, "0"}, read(dir, "wakealarm")) end)
    assert Power.awake?() == false
  end

  test "hands the wake-up count back to the kernel before suspending", %{dir: dir} do
    File.write!(Path.join(dir, "wakeup_count"), "41\n")
    start_supervised!(Power)
    wait_until(fn -> read(dir, "state") == {:ok, "mem"} end)
    assert read(dir, "wakeup_count") == {:ok, "41"}
  end

  defmodule ChattyBackplate do
    # The base answers the sleep notice over its serial line, a wake-up event.
    use GenServer
    def start_link(count), do: GenServer.start_link(__MODULE__, count, name: NestGen2.Backplate)
    def init(count), do: {:ok, count}

    def handle_call({:sleep_notice, _, _}, _from, count),
      do: {:reply, File.write!(count, "42\n"), count}

    def handle_call(:resumed, _from, count), do: {:reply, :ok, count}
  end

  test "takes the wake-up count after the base has answered the sleep notice", %{dir: dir} do
    count = Path.join(dir, "wakeup_count")
    File.write!(count, "41\n")
    start_supervised!({ChattyBackplate, count})
    start_supervised!(Power)
    wait_until(fn -> read(dir, "state") == {:ok, "mem"} end)
    assert read(dir, "wakeup_count") == {:ok, "42"}
  end

  test "no suspend if a wake-up event came after the count was read", %{dir: dir} do
    # The kernel refuses the count back when an event has happened since; a
    # directory refuses the write the same way, even for root.
    File.mkdir_p!(Path.join(dir, "wakeup_count"))
    assert NestGen2.Suspend.sleep(270, "41") == {:error, :wakeup_pending}
    assert read(dir, "state") == {:error, :enoent}
    assert read(dir, "wakealarm") == {:ok, "0"}
  end

  test "a press already queued when it is time to sleep is handled first", %{dir: dir} do
    start_supervised!(Power)
    wait_until(fn -> Power.awake?() == false end)
    # Hold Power while its deep sleep timer fires, then queue a press behind it.
    :sys.suspend(Power)
    Process.sleep(100)
    send(Power, {:nest_gen2, :button, :down})
    :sys.resume(Power)
    assert Power.awake?()
    assert read(dir, "state") == {:error, :enoent}
  end

  test "its own idle tick queued at that moment doesn't stop the suspend", %{dir: dir} do
    start_supervised!(Power)
    wait_until(fn -> Power.awake?() == false end)
    # Hold Power while its deep sleep timer fires, then queue a tick behind it.
    :sys.suspend(Power)
    Process.sleep(100)
    send(Power, :tick)
    :sys.resume(Power)
    wait_until(fn -> read(dir, "state") == {:ok, "mem"} end)
  end

  test "no deep sleep while a hold keeps the screen on", %{dir: dir} do
    start_supervised!(Power)
    {:ok, _hold} = Power.keep_awake(:test)
    Process.sleep(1_500)
    assert read(dir, "state") == {:error, :enoent}
  end

  test "off unless turned on", %{dir: dir} do
    Application.put_env(:nest_gen2, :deep_sleep, false)
    start_supervised!(Power)
    Process.sleep(1_500)
    assert read(dir, "state") == {:error, :enoent}
    :ok = Power.set_deep_sleep(true)
    wait_until(fn -> read(dir, "state") == {:ok, "mem"} end)
  end

  test "waking the screen cancels a pending deep sleep", %{dir: dir} do
    Application.put_env(:nest_gen2, :deep_sleep_after_ms, 2_000)
    start_supervised!(Power)
    wait_until(fn -> not Power.awake?() end)
    NestGen2.publish(:button, :down)
    wait_until(fn -> Power.awake?() end)
    Process.sleep(2_200)
    assert read(dir, "state") == {:error, :enoent}
  end
end

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

defmodule NestGen2.PowerHoldTest do
  # Runs the real Power server (named, so not async) against a stand-in
  # backlight that records what it was asked to do.
  use ExUnit.Case, async: false
  alias NestGen2.Power

  defmodule FakeBacklight do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test, name: NestGen2.Backlight)
    def init(test), do: {:ok, test}

    def handle_call({:output, state}, _from, test) do
      send(test, {:backlight, state})
      {:reply, :ok, test}
    end
  end

  # Power checks for idleness once a second.
  @tick 1_100

  setup do
    Application.put_env(:nest_gen2, :idle_timeout_ms, 100)
    Application.put_env(:nest_gen2, :wake_sources, [])

    on_exit(fn ->
      Application.delete_env(:nest_gen2, :idle_timeout_ms)
      Application.delete_env(:nest_gen2, :wake_sources)
    end)

    start_supervised!({Registry, keys: :duplicate, name: NestGen2.Registry})
    start_supervised!({FakeBacklight, self()})
    start_supervised!(Power)
    :ok
  end

  defp wait_for_sleep do
    assert_receive {:backlight, :off}, @tick * 2
    refute Power.awake?()
  end

  test "with no holds the screen sleeps after the idle timeout" do
    wait_for_sleep()
  end

  test "a hold wakes the screen and keeps it awake" do
    wait_for_sleep()
    {:ok, hold} = Power.keep_awake(:alarm)
    assert_receive {:backlight, :on}
    refute_receive {:backlight, :off}, @tick * 2
    assert Power.awake?()
    assert [%{ref: ^hold, reason: :alarm, owner: owner}] = Power.holds()
    assert owner == self()
  end

  test "releasing the last hold lets it sleep again" do
    {:ok, a} = Power.keep_awake(:alarm)
    {:ok, b} = Power.keep_awake(:settings)
    :ok = Power.release(a)
    refute_receive {:backlight, :off}, @tick * 2
    :ok = Power.release(b)
    assert Power.holds() == []
    wait_for_sleep()
  end

  test "a hold is released when the process that took it exits" do
    test = self()

    holder =
      spawn(fn ->
        {:ok, _} = Power.keep_awake(:short_lived)
        send(test, :held)
        receive do: (:stop -> :ok)
      end)

    assert_receive :held
    assert [%{reason: :short_lived}] = Power.holds()
    send(holder, :stop)
    Process.sleep(50)
    assert Power.holds() == []
    wait_for_sleep()
  end

  test "releasing an unknown hold is harmless" do
    assert Power.release(make_ref()) == :ok
  end

  test "sleep/0 still turns the screen off with a hold" do
    {:ok, _} = Power.keep_awake(:alarm)
    :ok = Power.sleep()
    assert_receive {:backlight, :off}
    refute Power.awake?()
  end
end

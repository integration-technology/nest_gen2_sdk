defmodule NestGen2.BatteryGuardTest do
  # Stand-in files for the battery ADC and the USB controller, and a poweroff
  # that only leaves a mark.
  use ExUnit.Case, async: false
  alias NestGen2.BatteryGuard

  setup do
    dir = Path.join(System.tmp_dir!(), "nest_gen2_battery_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    poweroff = Path.join(dir, "poweroff")
    File.write!(poweroff, "#!/bin/sh\ntouch #{dir}/off\n")
    File.chmod!(poweroff, 0o755)

    env = [
      battery_adc_path: Path.join(dir, "adc"),
      usb_vbus_path: Path.join(dir, "vbus"),
      poweroff_cmd: poweroff
    ]

    for {k, v} <- env, do: Application.put_env(:nest_gen2, k, v)
    File.write!(Path.join(dir, "vbus"), "off\n")

    on_exit(fn ->
      for k <- [:battery_shutdown_mv | Keyword.keys(env)],
          do: Application.delete_env(:nest_gen2, k)

      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  # The guard checks once at start; two more checks make the 30 s.
  defp run_checks(dir, adc) do
    File.write!(Path.join(dir, "adc"), adc)
    guard = start_supervised!(BatteryGuard)
    send(guard, :check)
    send(guard, :check)
    :sys.get_state(guard)
    File.exists?(Path.join(dir, "off"))
  end

  test "reads the head unit's battery in mV", %{dir: dir} do
    File.write!(Path.join(dir, "adc"), "1260\n")
    assert BatteryGuard.millivolts() == {:ok, 3780}
  end

  test "shuts down after 30 s below 3.4 V", %{dir: dir} do
    assert run_checks(dir, "1100\n")
  end

  test "not while the battery is above 3.4 V", %{dir: dir} do
    refute run_checks(dir, "1200\n")
  end

  test "not on USB power", %{dir: dir} do
    File.write!(Path.join(dir, "vbus"), "on\n")
    refute run_checks(dir, "1100\n")
  end

  test "not when turned off", %{dir: dir} do
    Application.put_env(:nest_gen2, :battery_shutdown_mv, nil)
    refute run_checks(dir, "1100\n")
  end

  test "nothing on a computer, where there's no battery to read" do
    assert BatteryGuard.millivolts() == :error
    guard = start_supervised!(BatteryGuard)
    assert :sys.get_state(guard) == 0
  end
end

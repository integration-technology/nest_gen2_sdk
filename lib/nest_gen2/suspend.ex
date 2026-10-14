defmodule NestGen2.Suspend do
  @moduledoc false
  # Suspend to RAM: the whole system stops (processor, radios, the BEAM and
  # every process in it) with memory kept alive, and carries on where it left
  # off when something wakes it: the button, the backplate's serial line (it
  # wakes the head on motion), or the RTC alarm set here. Writing "mem" to
  # /sys/power/state only returns after the wake-up.
  #
  # This is how Nest's own software keeps the head unit within the ~120 mA the
  # base can supply; awake all the time, it drains the battery on the base.

  @doc """
  Sleeps for at most `seconds`; returns how long it actually slept (shorter if
  something woke it first), or an error if the kernel refused (for example a
  wake-up event already pending).
  """
  @spec sleep(pos_integer) :: {:ok, non_neg_integer} | {:error, term}
  def sleep(seconds) do
    # The backplate's line must be able to wake us: it's how motion does.
    _ = File.write(path(:backplate_wakeup_path), "enabled")
    alarm = path(:rtc_wakealarm_path)
    _ = File.write(alarm, "0")
    t0 = System.os_time(:second)

    with :ok <- File.write(alarm, Integer.to_string(t0 + seconds)) do
      result = File.write(path(:power_state_path), "mem")
      slept = System.os_time(:second) - t0
      _ = File.write(alarm, "0")

      case result do
        :ok -> {:ok, slept}
        {:error, _} = error -> error
      end
    end
  end

  defp path(key), do: NestGen2.Config.get(key)
end

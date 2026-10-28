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
  The kernel's count of wake-up events so far, or nil where there is none.
  Read it when deciding to sleep and pass it to `sleep/2`: a press or motion
  after that point then cancels the suspend instead of being lost until the
  alarm (the kernel's wakeup_count handshake, as Nest's own nlsleepd does).
  """
  @spec wakeup_count() :: String.t() | nil
  def wakeup_count do
    # Blocks while a wake-up event is still being handled, as it should.
    with false <- NestGen2.Config.host?(),
         {:ok, count} <- File.read(path(:wakeup_count_path)),
         do: String.trim(count),
         else: (_ -> nil)
  end

  @doc """
  Sleeps for at most `seconds`; returns how long it actually slept (shorter if
  something woke it first), or an error if the kernel refused:
  `:wakeup_pending` when a wake-up event happened since `count` was read.
  """
  @spec sleep(pos_integer, String.t() | nil) :: {:ok, non_neg_integer} | {:error, term}
  def sleep(seconds, count \\ nil) do
    if NestGen2.Config.host?(), do: {:error, :host}, else: suspend(seconds, count)
  end

  defp suspend(seconds, count) do
    # The backplate's line must be able to wake us: it's how motion does.
    _ = File.write(path(:backplate_wakeup_path), "enabled")
    alarm = path(:rtc_wakealarm_path)
    _ = File.write(alarm, "0")
    t0 = System.os_time(:second)

    with :ok <- File.write(alarm, Integer.to_string(t0 + seconds)) do
      result = with :ok <- claim(count), do: File.write(path(:power_state_path), "mem")
      slept = System.os_time(:second) - t0
      _ = File.write(alarm, "0")

      case result do
        :ok -> {:ok, slept}
        {:error, _} = error -> error
      end
    end
  end

  # Writing the count back fails if any wake-up event has happened since it
  # was read; once it succeeds, a later event makes the "mem" write fail too.
  defp claim(nil), do: :ok

  defp claim(count) do
    case File.write(path(:wakeup_count_path), count) do
      :ok -> :ok
      {:error, _} -> {:error, :wakeup_pending}
    end
  end

  defp path(key), do: NestGen2.Config.get(key)
end

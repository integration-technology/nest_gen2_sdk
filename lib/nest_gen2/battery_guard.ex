defmodule NestGen2.BatteryGuard do
  @moduledoc """
  Shuts the Nest down before its battery runs flat, as Nest's own firmware
  does: once the head unit's battery has read below `battery_shutdown_mv`
  (3400 mV) for 30 s, unless USB power is connected.

  Without this, a Nest that can't charge (deep sleep off, or a base that
  can't keep up) runs its lithium cell down until it browns out and reboots,
  again and again, well below the voltage that harms the cell. Powered off,
  it draws next to nothing; it comes back on USB power or the button.

  The voltage is the head unit's own reading (the one Nest's firmware uses),
  so it works with or without the base. Set `battery_shutdown_mv: nil` to
  turn the guard off.
  """
  use GenServer
  require Logger

  @check_ms 10_000
  # Three low readings in a row, 30 s: a moment's dip under load (seen at
  # boot) doesn't count.
  @low_checks 3

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The head unit's battery voltage in mV, or :error where it can't be read (a computer)."
  @spec millivolts() :: {:ok, pos_integer} | :error
  def millivolts do
    # The ADC reads a third of the cell's voltage.
    with {:ok, text} <- File.read(NestGen2.Config.get(:battery_adc_path)),
         {raw, _} <- Integer.parse(text),
         do: {:ok, raw * 3},
         else: (_ -> :error)
  end

  @impl true
  def init(nil) do
    send(self(), :check)
    {:ok, 0}
  end

  @impl true
  def handle_info(:check, low) do
    Process.send_after(self(), :check, @check_ms)
    limit = NestGen2.Config.get(:battery_shutdown_mv)

    case millivolts() do
      {:ok, mv} when is_integer(limit) and mv < limit ->
        if usb_power?(), do: {:noreply, 0}, else: {:noreply, low(low + 1, mv)}

      _ ->
        {:noreply, 0}
    end
  end

  # Again at every check after, should the first attempt not take.
  defp low(low, mv) when low >= @low_checks do
    shut_down(mv)
    low
  end

  defp low(low, _mv), do: low

  # The power chip's USB side, which Nest's own firmware watches: "on" while
  # a charger or computer powers it. (Not the USB controller's own "Vbus"
  # file, which says off with a charger plugged in.)
  defp usb_power? do
    match?({:ok, "on" <> _}, File.read(NestGen2.Config.get(:usb_vbus_path)))
  end

  defp shut_down(mv) do
    message = "battery #{mv} mV for 30 s, not on USB: shutting down"
    NestGen2.Trace.event(message)
    Logger.error("nest_gen2: " <> message)
    System.cmd(NestGen2.Config.get(:poweroff_cmd), [], stderr_to_stdout: true)
  end
end

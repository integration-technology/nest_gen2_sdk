defmodule NestGen2.Gesture do
  @moduledoc """
  Clicks, double clicks and long presses, from the button's raw `:down` and
  `:up` events. Subscribe to `:gesture` to receive:

      {:nest_gen2, :gesture, :click}
      {:nest_gen2, :gesture, :double_click}
      {:nest_gen2, :gesture, :long_press}

  Timings (config, in ms):

    * `button_double_click_ms` (default 300): a second press starting within
      this long of the first release makes a double click. A single click is
      only known once this window has passed, so `:click` arrives that much
      after the release. Set it to `nil` for no double clicks and an
      immediate `:click`. Measured on a real Nest, a natural double click
      leaves 98 to 229 ms (mean 142) between the release and the second
      press, so 300 ms catches the slow ones while keeping a single click's
      delay short.
    * `button_long_press_ms` (default 800): held this long, `:long_press` is
      sent while the button is still down, and its release sends nothing more.
      Keep it well under 10 s: holding the display that long restarts the Nest.
      Ordinary presses measured 120 to 291 ms.

  `:button` keeps sending `:down` and `:up` as they happen, for anything that
  must respond at once.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    NestGen2.subscribe(:button)
    {:ok, %{phase: :idle, presses: 0, timer: nil, token: nil}}
  end

  @impl true
  def handle_info({:nest_gen2, :button, :down}, %{phase: :idle} = s),
    do: {:noreply, pressed(s, 1)}

  # A second press inside the double-click window.
  def handle_info({:nest_gen2, :button, :down}, %{phase: :released} = s),
    do: {:noreply, pressed(cancel(s), 2)}

  def handle_info({:nest_gen2, :button, :up}, %{phase: :pressed, presses: 1} = s) do
    s = cancel(s)

    case NestGen2.Config.get(:button_double_click_ms) do
      nil -> {:noreply, emit(s, :click)}
      ms -> {:noreply, schedule(%{s | phase: :released}, ms)}
    end
  end

  def handle_info({:nest_gen2, :button, :up}, %{phase: :pressed, presses: 2} = s),
    do: {:noreply, emit(cancel(s), :double_click)}

  # The release that ends a long press.
  def handle_info({:nest_gen2, :button, :up}, %{phase: :held} = s), do: {:noreply, idle(s)}

  def handle_info({:timeout, token}, %{token: token, phase: :pressed, presses: 1} = s),
    do: {:noreply, %{publish(s, :long_press) | phase: :held, timer: nil}}

  def handle_info({:timeout, token}, %{token: token, phase: :released} = s),
    do: {:noreply, emit(%{s | timer: nil}, :click)}

  # A stale timer, or a down/up that doesn't fit (e.g. a missed event).
  def handle_info(_other, s), do: {:noreply, s}

  defp pressed(s, presses) do
    s = %{s | phase: :pressed, presses: presses}
    # Only the first press of a sequence can become a long press.
    if presses == 1, do: schedule(s, NestGen2.Config.get(:button_long_press_ms)), else: s
  end

  defp schedule(s, ms) do
    token = make_ref()
    %{s | token: token, timer: Process.send_after(self(), {:timeout, token}, ms)}
  end

  defp cancel(%{timer: nil} = s), do: s

  defp cancel(s) do
    Process.cancel_timer(s.timer)
    %{s | timer: nil, token: nil}
  end

  defp emit(s, gesture), do: s |> publish(gesture) |> idle()

  defp publish(s, gesture) do
    NestGen2.Trace.write("gesture #{gesture}")
    NestGen2.publish(:gesture, gesture)
    s
  end

  defp idle(s), do: %{s | phase: :idle, presses: 0, timer: nil, token: nil}
end

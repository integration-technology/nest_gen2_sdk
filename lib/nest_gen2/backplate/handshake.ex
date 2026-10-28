defmodule NestGen2.Backplate.Handshake do
  @moduledoc false
  # The start-up exchange Nest's own client performs every time it opens the
  # backplate link (captured from the stock firmware on 2026-10-03). After a
  # reset or a power loss the backplate stays silent until it gets this, so
  # without it no motion, light or climate readings arrive.
  #
  # Steps are {delay_ms, action}: the delay is waited before the action.
  # Actions are {:tx, cmd, payload} or :brk (flush, then a 100 ms BREAK, after
  # which the backplate restarts and says hello with 0x0004).
  import Bitwise

  @doc "From opening the link up to the BREAK; the backplate answers with 0x0004."
  def start_steps do
    [
      {0, {:tx, 0xC0, <<0::32>>}},
      {10, {:tx, 0x85, <<>>}},
      {60, {:tx, 0x83, <<>>}},
      {150, :brk},
      {0, {:tx, 0xFF, <<>>}}
    ]
  end

  @doc "The reply to the backplate's 0x0004 hello: echo it as 0x8f, then the queries."
  def hello_steps(hello) do
    [
      {140, {:tx, 0x8F, hello}},
      {10, {:tx, 0x83, <<>>}},
      {40, {:tx, 0x90, <<>>}}
    ] ++
      for(cmd <- [0x98, 0x99, 0x9D, 0x9B, 0x9C, 0x9F, 0x9E], do: {150, {:tx, cmd, <<>>}}) ++
      [{300, {:tx, 0xC0, <<0::32>>}}]
  end

  # a4's wake mask bits, as Nest's client names them; the base reports why it
  # woke the head (0014) with the same bits. Timer, buffers full, vergence,
  # battery and errors are the base's own business and always on, as Nest has
  # them; temperature and humidity (thresholds for heating) never are.
  @wake_always 0x0001 ||| 0x0002 ||| 0x0100 ||| 0x0200 ||| 0x0400
  @wake_near_pir 0x0080
  @wake_als 0x0020

  @doc """
  What Nest's client sends just before it suspends (capture of 2026-10-13,
  fields named from its code): the base then stays quiet, keeping its
  readings, for `seconds` (a1) unless one of the app's `sources` makes it wake
  the head early. a4 is the wake mask: someone near (`:motion`) and a change in
  room light (`:light`). b9 is the light thresholds (low, high; 0xFFFF is off):
  a change of `jump_pct` percent, and at least `min_delta` counts, from `light`
  (the last reading) either way. c2 is a low-temperature threshold, sent as
  `low_c_centi` (5 degC) though the temperature wake is off: Nest sent its
  heating thresholds there. b5, b3 and ba are Nest's own values, as sent.
  """
  def sleep_burst(light, seconds, sources, jump_pct, min_delta, low_c_centi \\ 500) do
    mask =
      @wake_always |||
        if(:motion in sources, do: @wake_near_pir, else: 0) |||
        if(:light in sources, do: @wake_als, else: 0)

    [
      {0xC2, <<0x00, 0x00, low_c_centi::16-little, 0x00, 0x80>>},
      {0xB5, <<0x0F, 0x00>>},
      {0xB3, <<0xFF, 0xFF, 0xFF, 0xFF>>},
      {0xB9, light_thresholds(:light in sources and light, jump_pct, min_delta)},
      {0xBA, <<0::48>>},
      {0xA4, <<mask::16-little>>},
      {0xA1, <<seconds::16-little>>}
    ]
  end

  defp light_thresholds(level, jump_pct, min_delta) when is_integer(level) do
    delta = max(div(level * jump_pct, 100), min_delta)
    <<max(level - delta, 0)::16-little, min(level + delta, 0xFFFE)::16-little>>
  end

  defp light_thresholds(_off, _, _), do: <<0::16, 0xFFFF::16-little>>

  @doc "How long to wait for the hello after the BREAK."
  def hello_timeout_ms, do: 3_000

  @doc """
  Whether the backplate has gone quiet: it normally sends light and motion
  readings every second, so `silent_ms` without a frame means it needs waking.
  Not more often than every `retry_ms`, so a missing backplate (say, a head
  unit on a bench supply) isn't sent a BREAK in a tight loop.
  """
  def wake?(now, last_rx, last_handshake, silent_ms, retry_ms) do
    now - (last_rx || last_handshake || now) >= silent_ms and
      (last_handshake == nil or now - last_handshake >= retry_ms)
  end
end

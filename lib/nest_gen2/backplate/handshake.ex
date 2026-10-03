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

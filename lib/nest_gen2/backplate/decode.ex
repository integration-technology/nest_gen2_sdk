defmodule NestGen2.Backplate.Decode do
  @moduledoc false
  # Payload decoding for backplate messages (all little-endian).

  @doc "Decodes a message payload by command number."
  def decode(0x0007, <<level::16-little>>), do: {:motion_level, level}

  # PIR event flags: byte 0 is set by close movement (near sensor), byte 1 by
  # body movement further away (far sensor). All zero when the event clears.
  def decode(0x0005, <<near, far, _::binary>>), do: {:pir, near != 0, far != 0}

  # Temperature in 1/100 degC and relative humidity in 1/10 %, raw (self-heated).
  def decode(0x0002, <<centi_c::16-little-signed, deci_rh::16-little>>),
    do: {:climate, centi_c / 100, deci_rh / 10}

  # Three board temperatures in 1/100 degC.
  def decode(
        0x0023,
        <<a::16-little-signed, b::16-little-signed, c::16-little-signed, _::binary>>
      ),
      do: {:board_temperatures, [a / 100, b / 100, c / 100]}

  # Battery voltage in mV at payload bytes 12-13.
  def decode(0x000B, <<_::binary-size(12), mv::16-little, _::binary>>), do: {:battery, mv}

  # Ambient light, raw sensor counts (bytes 0-1), once a second. Daylight in
  # a room reads in the thousands to tens of thousands.
  def decode(0x000A, <<level::16-little, _::binary>>), do: {:light, level}

  def decode(_cmd, _payload), do: :unknown

  @doc "Parses a bplink `rx` line: \"rx 000b 01ce0f...\"."
  def parse_line("rx " <> rest) do
    case String.split(rest, " ", parts: 2) do
      [cmd, hex] -> {:ok, String.to_integer(cmd, 16), Base.decode16!(hex, case: :lower)}
      [cmd] -> {:ok, String.to_integer(cmd, 16), <<>>}
    end
  end

  def parse_line(_), do: :ignore
end

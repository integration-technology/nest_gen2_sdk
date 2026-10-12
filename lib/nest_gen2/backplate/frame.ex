defmodule NestGen2.Backplate.Frame do
  @moduledoc false
  # Framing for the backplate's serial line. Every message, both ways, is one
  # frame:
  #
  #   d5 aa 96 | cmd u16le | len u16le | payload (len bytes) | crc u16le
  #
  # The crc is CRC-16/XMODEM over cmd, len and payload. The serial line hands
  # us bytes in arbitrary chunks, so parse/1 keeps whatever is left over (half
  # a frame) for the next chunk, and skips bytes that can't start a frame
  # (line noise, a frame cut short by a backplate restart).

  @sync <<0xD5, 0xAA, 0x96>>
  @max_payload 1024

  @doc "Encodes one frame."
  @spec encode(0..0xFFFF, binary) :: binary
  def encode(cmd, payload \\ <<>>) do
    body = <<cmd::16-little, byte_size(payload)::16-little, payload::binary>>
    <<@sync::binary, body::binary, crc16(body)::16-little>>
  end

  @doc """
  Takes the bytes received so far and returns the complete frames in them, in
  order, as `{cmd, payload}`, and the bytes to keep for the next call.
  """
  @spec parse(binary) :: {[{0..0xFFFF, binary}], binary}
  def parse(buffer), do: parse(buffer, [])

  defp parse(
         <<0xD5, 0xAA, 0x96, cmd::16-little, len::16-little, payload::binary-size(len),
           crc::16-little, rest::binary>> = buffer,
         acc
       )
       when len <= @max_payload do
    if crc == crc16(binary_part(buffer, 3, 4 + len)),
      do: parse(rest, [{cmd, payload} | acc]),
      # A corrupt frame: its sync was real or it was noise; either way, look
      # for the next sync one byte on.
      else: skip(buffer, acc)
  end

  # Not enough bytes yet for a whole frame: keep them (as long as they could
  # still become one).
  defp parse(<<0xD5, 0xAA, 0x96, _cmd::16, len::16-little, _::binary>> = partial, acc)
       when len <= @max_payload,
       do: {Enum.reverse(acc), partial}

  defp parse(<<0xD5, 0xAA, 0x96, _::binary>> = partial, acc) when byte_size(partial) < 7,
    do: {Enum.reverse(acc), partial}

  defp parse(<<0xD5, 0xAA>> = partial, acc), do: {Enum.reverse(acc), partial}
  defp parse(<<0xD5>> = partial, acc), do: {Enum.reverse(acc), partial}
  defp parse(<<>>, acc), do: {Enum.reverse(acc), <<>>}
  defp parse(buffer, acc), do: skip(buffer, acc)

  # Drop one byte and look for the next sync.
  defp skip(<<_, rest::binary>>, acc) do
    case :binary.match(rest, @sync) do
      {pos, _} -> parse(binary_part(rest, pos, byte_size(rest) - pos), acc)
      :nomatch -> parse(tail_that_could_start_sync(rest), acc)
    end
  end

  defp tail_that_could_start_sync(bin) do
    cond do
      String.ends_with?(bin, <<0xD5, 0xAA>>) -> <<0xD5, 0xAA>>
      String.ends_with?(bin, <<0xD5>>) -> <<0xD5>>
      true -> <<>>
    end
  end

  @doc "CRC-16/XMODEM (polynomial 0x1021, initial value 0)."
  @spec crc16(binary) :: 0..0xFFFF
  def crc16(data), do: crc16(data, 0)

  defp crc16(<<>>, crc), do: crc

  defp crc16(<<byte, rest::binary>>, crc) do
    crc = Bitwise.bxor(crc, Bitwise.bsl(byte, 8))
    crc16(rest, crc_bits(crc, 8))
  end

  defp crc_bits(crc, 0), do: crc

  defp crc_bits(crc, n) do
    shifted = Bitwise.band(Bitwise.bsl(crc, 1), 0xFFFF)

    if Bitwise.band(crc, 0x8000) != 0,
      do: crc_bits(Bitwise.bxor(shifted, 0x1021), n - 1),
      else: crc_bits(shifted, n - 1)
  end
end

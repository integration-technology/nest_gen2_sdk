defmodule NestGen2.Backplate.FrameTest do
  use ExUnit.Case, async: true
  alias NestGen2.Backplate.Frame

  # A climate frame as the backplate sent it (27.12 degC, 42.7 %RH), with the
  # CRC bplink accepted.
  @climate Frame.encode(0x0002, <<0x98, 0x0A, 0xAB, 0x01>>)

  test "CRC-16/XMODEM check value" do
    assert Frame.crc16("123456789") == 0x31C3
  end

  test "encodes the frame layout" do
    assert <<0xD5, 0xAA, 0x96, 0x02, 0x00, 0x04, 0x00, 0x98, 0x0A, 0xAB, 0x01, _crc::16>> =
             @climate

    assert Frame.encode(0x83) |> byte_size() == 9
  end

  test "round trip, several frames in one chunk" do
    bytes = Frame.encode(0x83) <> @climate <> Frame.encode(0x0004, <<0::104>>)

    assert {[{0x83, ""}, {0x0002, <<0x98, 0x0A, 0xAB, 0x01>>}, {0x0004, <<0::104>>}], ""} =
             Frame.parse(bytes)
  end

  test "a frame split across chunks is kept until it's complete" do
    <<a::binary-size(5), b::binary>> = @climate
    assert {[], ^a} = Frame.parse(a)
    assert {[{0x0002, _}], ""} = Frame.parse(a <> b)

    for n <- 1..(byte_size(@climate) - 1) do
      <<head::binary-size(n), _::binary>> = @climate
      assert {[], ^head} = Frame.parse(head)
    end
  end

  test "noise before, between and after frames is skipped" do
    bytes = <<1, 2, 0xD5, 3>> <> @climate <> <<0xFF, 0xAA>> <> Frame.encode(0x83) <> <<7, 0xD5>>
    assert {[{0x0002, _}, {0x83, ""}], <<0xD5>>} = Frame.parse(bytes)
  end

  test "a corrupt frame is dropped and the next one still found" do
    <<head::binary-size(8), byte, tail::binary>> = @climate
    corrupt = head <> <<Bitwise.bxor(byte, 1)>> <> tail
    assert {[{0x83, ""}], ""} = Frame.parse(corrupt <> Frame.encode(0x83))
  end

  test "an impossible length is treated as noise, not waited for" do
    bytes = <<0xD5, 0xAA, 0x96, 0x02, 0x00, 0xFF, 0xFF>> <> Frame.encode(0x83)
    assert {[{0x83, ""}], ""} = Frame.parse(bytes)
  end
end

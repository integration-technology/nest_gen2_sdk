defmodule NestGen2.Backplate.DecodeTest do
  use ExUnit.Case, async: true
  alias NestGen2.Backplate.Decode

  # Payloads captured from a real backplate on 2026-09-30.

  test "motion level" do
    assert Decode.decode(0x0007, <<10, 0>>) == {:motion_level, 10}
  end

  test "PIR flags split near and far" do
    assert Decode.decode(0x0005, <<0xC0, 0, 0, 0>>) == {:pir, true, false}
    assert Decode.decode(0x0005, <<0xFF, 0x7F, 0, 0x78>>) == {:pir, true, true}
    assert Decode.decode(0x0005, <<0, 0x40, 0, 0>>) == {:pir, false, true}
    assert Decode.decode(0x0005, <<0, 0, 0, 0>>) == {:pir, false, false}
  end

  test "climate: 98 0a ab 01 is 27.12 degC and 42.7 %RH" do
    assert Decode.decode(0x0002, <<0x98, 0x0A, 0xAB, 0x01>>) == {:climate, 27.12, 42.7}
  end

  test "board temperatures" do
    assert Decode.decode(0x0023, <<0xF0, 0x0C, 0xBE, 0x0B, 0x24, 0x0B>>) ==
             {:board_temperatures, [33.12, 30.06, 28.52]}
  end

  test "battery millivolts" do
    payload =
      Base.decode16!("018e0f00000013130000040038 0f1414" |> String.replace(" ", ""), case: :lower)

    assert Decode.decode(0x000B, payload) == {:battery, 3896}
  end

  test "parses bplink lines" do
    assert Decode.parse_line("rx 0002 980aab01") == {:ok, 2, <<0x98, 0x0A, 0xAB, 0x01>>}
    assert Decode.parse_line("rx 0083") == {:ok, 0x83, <<>>}
    assert Decode.parse_line("ready /dev/ttyO2") == :ignore
  end
end

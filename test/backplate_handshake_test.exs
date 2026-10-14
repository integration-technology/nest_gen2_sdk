defmodule NestGen2.Backplate.HandshakeTest do
  use ExUnit.Case, async: true
  alias NestGen2.Backplate.{Decode, Handshake}

  # Frames captured from the stock firmware waking a backplate on 2026-10-03.
  @hello Base.decode16!("00000000000000000100010000", case: :lower)

  test "the BREAK comes after c0, 85 and 83, then ff" do
    actions = Enum.map(Handshake.start_steps(), &elem(&1, 1))

    assert actions == [
             {:tx, 0xC0, <<0::32>>},
             {:tx, 0x85, <<>>},
             {:tx, 0x83, <<>>},
             :brk,
             {:tx, 0xFF, <<>>}
           ]
  end

  test "the hello is echoed as 0x8f, then the queries, ending with c0" do
    [{_, first} | _] = steps = Handshake.hello_steps(@hello)
    assert first == {:tx, 0x8F, @hello}
    cmds = for {_, {:tx, cmd, _}} <- steps, do: cmd
    assert cmds == [0x8F, 0x83, 0x90, 0x98, 0x99, 0x9D, 0x9B, 0x9C, 0x9F, 0x9E, 0xC0]
  end

  test "decodes the hello and the handshake answers" do
    assert Decode.decode(0x0004, @hello) == {:hello, @hello}
    assert Decode.decode(0x0001, "BRK") == {:message, "BRK"}
    assert Decode.decode(0x0018, "1.0.26") == {:info, :firmware, "1.0.26"}
    assert Decode.decode(0x001E, "Backplate-3.2") == {:info, :model, "Backplate-3.2"}
    assert Decode.decode(0x001C, "BSL\0") == {:info, :bootloader, "BSL"}
  end

  test "restart chatter is recognised, anything else isn't" do
    alias NestGen2.Backplate

    for text <- [
          "BRK",
          "1.0.26 2019-04-05 19:24:34 K",
          "*sense 0000 0000; detect 0000 1318",
          "*HVAC power lost"
        ],
        do: assert(Backplate.restart_chatter?(text), text)

    refute Backplate.restart_chatter?("*something new")
  end

  test "the sleep notice carries the temperature and the seconds, as Nest's does" do
    burst = Handshake.sleep_burst(2271, 0x0121)
    assert Enum.map(burst, &elem(&1, 0)) == [0xC2, 0xB5, 0xB3, 0xB9, 0xBA, 0xA4, 0xA1]
    # Byte for byte what Nest's client sent before its 277 s sleep.
    assert {0xB9, <<0x00, 0x00, 0xDF, 0x08>>} in burst
    assert {0xA1, <<0x21, 0x01>>} in burst
  end

  test "decodes the base's wake reason" do
    assert Decode.decode(0x0014, <<0x80, 0x00>>) == {:wake_reason, 0x80}
  end

  describe "wake?/5" do
    test "not while readings arrive" do
      refute Handshake.wake?(100_000, 99_000, 0, 15_000, 60_000)
    end

    test "after 15 s of silence" do
      assert Handshake.wake?(100_000, 80_000, 0, 15_000, 60_000)
    end

    test "not again within a minute of the last attempt" do
      refute Handshake.wake?(100_000, 50_000, 70_000, 15_000, 60_000)
      assert Handshake.wake?(140_000, 50_000, 70_000, 15_000, 60_000)
    end

    test "counts from the last attempt when nothing was ever received" do
      refute Handshake.wake?(10_000, nil, 0, 15_000, 60_000)
      assert Handshake.wake?(60_000, nil, 0, 15_000, 60_000)
    end
  end
end

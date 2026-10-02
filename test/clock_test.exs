defmodule NestGen2.ClockTest do
  use ExUnit.Case, async: true
  alias NestGen2.Clock

  # 2026-10-25 01:00:00.250 UTC, when BST ends.
  @t ~U[2026-10-25 01:00:00.250Z] |> DateTime.to_unix(:millisecond)

  test "NTP timestamps round-trip to the millisecond" do
    assert Clock.from_ntp(Clock.ntp_timestamp(@t)) == @t
    assert <<seconds::32, _::32>> = Clock.ntp_timestamp(@t)
    assert seconds == div(@t, 1000) + 2_208_988_800
  end

  test "timestamps after the 2036 wrap" do
    after_wrap = ~U[2040-01-01 00:00:00Z] |> DateTime.to_unix(:millisecond)
    assert Clock.from_ntp(Clock.ntp_timestamp(after_wrap)) == after_wrap
  end

  test "the request is a 48-byte v4 client packet carrying our send time" do
    packet = Clock.request(@t)
    assert byte_size(packet) == 48
    assert <<0::2, 4::3, 3::3, _::binary-size(39), xmit::binary-size(8)>> = packet
    assert xmit == Clock.ntp_timestamp(@t)
  end

  defp reply(t1, t2, t3, opts \\ []) do
    stratum = Keyword.get(opts, :stratum, 2)
    orig = Keyword.get(opts, :orig, Clock.ntp_timestamp(t1))

    <<0::2, 4::3, 4::3, stratum, 0::size(22)-unit(8), orig::binary,
      Clock.ntp_timestamp(t2)::binary, Clock.ntp_timestamp(t3)::binary>>
  end

  test "offset when our clock is 90 s slow, with 40 ms each way" do
    # Real time at our send is @t + 90_000; the server holds it 2 ms.
    t1 = @t
    t2 = t1 + 90_000 + 40
    t3 = t2 + 2
    t4 = t1 + 82
    assert Clock.offset_ms(reply(t1, t2, t3), t1, t4) == {:ok, 90_000}
  end

  test "offset when our clock is fast" do
    t1 = @t

    assert Clock.offset_ms(reply(t1, t1 - 5_000 + 10, t1 - 5_000 + 10), t1, t1 + 20) ==
             {:ok, -5_000}
  end

  test "rejects kiss-of-death, someone else's reply and junk" do
    t1 = @t
    assert Clock.offset_ms(reply(t1, t1, t1, stratum: 0), t1, t1) == {:error, {:stratum, 0}}

    assert Clock.offset_ms(reply(t1, t1, t1, orig: Clock.ntp_timestamp(1)), t1, t1) ==
             {:error, :originate_mismatch}

    assert Clock.offset_ms(<<1, 2, 3>>, t1, t1) == {:error, :bad_packet}
  end

  describe "best_sample/2" do
    test "trusts the sample with the shortest round trip" do
      samples = [
        %{offset_ms: -1304, delay_ms: 2650},
        %{offset_ms: -12, delay_ms: 40},
        %{offset_ms: 30, delay_ms: 120}
      ]

      assert Clock.best_sample(samples, 500) == {:ok, %{offset_ms: -12, delay_ms: 40}}
    end

    test "rejects all of them when even the best round trip is too slow" do
      assert Clock.best_sample([%{offset_ms: -1304, delay_ms: 2650}], 500) ==
               {:error, {:slow_replies, 2650}}
    end

    test "no replies at all" do
      assert Clock.best_sample([], 500) == {:error, :no_replies}
    end
  end

  test "measure/3 reports the round trip, excluding the server's own time" do
    t1 = @t
    t2 = t1 + 90_000 + 40
    t3 = t2 + 2
    t4 = t1 + 82
    assert {:ok, %{offset_ms: 90_000, delay_ms: 80}} = Clock.measure(reply(t1, t2, t3), t1, t4)
  end
end

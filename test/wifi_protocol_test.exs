defmodule NestGen2.Wifi.ProtocolTest do
  use ExUnit.Case, async: true
  alias NestGen2.Wifi.Protocol

  test "STATUS key=value lines" do
    text =
      "bssid=02:00:00:00:00:01\nssid=HomeNet\nid=0\nwpa_state=COMPLETED\nip_address=192.0.2.7\n"

    kv = Protocol.parse_kv(text)
    assert kv["wpa_state"] == "COMPLETED"
    assert kv["ssid"] == "HomeNet"
    assert kv["id"] == "0"
  end

  describe "parse_scan/2" do
    @scan """
    bssid / frequency / signal level / flags / ssid
    02:00:00:00:00:01\t2437\t-58\t[WPA2-PSK-CCMP][ESS]\tHomeNet
    02:00:00:00:00:02\t5180\t-71\t[WPA2-PSK-CCMP][ESS]\tHomeNet
    02:00:00:00:00:03\t2412\t-80\t[ESS]\tCafe Free
    02:00:00:00:00:04\t2462\t-65\t[WPA2-PSK-CCMP][ESS]\t
    02:00:00:00:00:05\t2462\t-90\t[WEP][ESS]\tOld \\"Router\\"
    """

    test "one entry per SSID, strongest first, hidden networks dropped" do
      assert [
               %{ssid: "HomeNet", signal_dbm: -58, secured: true, saved: true},
               %{ssid: "Cafe Free", signal_dbm: -80, secured: false, saved: false},
               %{ssid: ~s(Old "Router"), signal_dbm: -90, secured: true, saved: false}
             ] = Protocol.parse_scan(@scan, ["HomeNet"])
    end
  end

  test "LIST_NETWORKS" do
    text = """
    network id / ssid / bssid / flags
    0\tHomeNet\tany\t[CURRENT]
    1\tPhone\tany\t[DISABLED]
    """

    assert [%{id: "0", ssid: "HomeNet", flags: "[CURRENT]"}, %{id: "1", ssid: "Phone"}] =
             Protocol.parse_networks(text)
  end

  test "SSIDs are unescaped and written as hex" do
    assert Protocol.unescape("caf\\xc3\\xa9") == "café"
    assert Protocol.unescape("a\\\\b") == "a\\b"
    assert Protocol.ssid_hex("Home Net") == "486f6d65204e6574"
  end

  test "psk matches wpa_passphrase (IEEE 802.11i test vector)" do
    # Passphrase "password", SSID "IEEE" from the 802.11i-2004 annex H.4 vectors.
    assert Protocol.psk("password", "IEEE") ==
             {:ok, "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"}

    assert Protocol.psk("short", "IEEE") == {:error, :bad_password_length}
    assert Protocol.psk(String.duplicate("x", 64), "IEEE") == {:error, :bad_password_length}
  end

  test "events" do
    assert Protocol.event("<3>CTRL-EVENT-CONNECTED - Connection to 02:00:00:00:00:01 completed") ==
             :connected

    assert Protocol.event("<3>CTRL-EVENT-DISCONNECTED bssid=02:00:00:00:00:01 reason=3") ==
             :disconnected

    assert Protocol.event(
             "<3>CTRL-EVENT-SSID-TEMP-DISABLED id=1 ssid=\"Phone\" auth_failures=1 duration=10 reason=WRONG_KEY"
           ) == :wrong_key

    assert Protocol.event("<3>WPA: 4-Way Handshake failed - pre-shared key may be incorrect") ==
             :wrong_key

    assert Protocol.event("<3>CTRL-EVENT-SCAN-RESULTS ") == :scan_results
    assert Protocol.event("OK") == nil
  end

  test "signal bars and usable addresses" do
    assert Enum.map([-50, -60, -70, -80, -95, nil], &Protocol.bars/1) == [4, 3, 2, 1, 0, 0]
    assert Protocol.usable_ip?("192.0.2.7")
    refute Protocol.usable_ip?("169.254.1.2")
    refute Protocol.usable_ip?("127.0.0.1")
    refute Protocol.usable_ip?(nil)
  end
end

defmodule NestGen2.Wifi.Protocol do
  @moduledoc false
  # Pure helpers for wpa_supplicant's control interface: parsing its replies
  # and events, and building values for SET_NETWORK.

  @doc "Parses `key=value` lines (STATUS, SIGNAL_POLL) into a map with string keys."
  def parse_kv(text) do
    for line <- String.split(text, "\n", trim: true),
        [k, v] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {k, v}
  end

  @doc """
  Parses SCAN_RESULTS into one entry per SSID (the strongest), strongest
  first, without hidden networks.
  """
  def parse_scan(text, saved_ssids \\ []) do
    text
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t") do
        [_bssid, _freq, signal, flags, ssid] ->
          ssid = unescape(ssid)

          if ssid == "" or String.starts_with?(ssid, "\\x00"),
            do: [],
            else: [%{ssid: ssid, signal_dbm: String.to_integer(signal), secured: secured?(flags)}]

        _ ->
          []
      end
    end)
    |> Enum.group_by(& &1.ssid)
    |> Enum.map(fn {_ssid, aps} -> Enum.max_by(aps, & &1.signal_dbm) end)
    |> Enum.map(&Map.put(&1, :saved, &1.ssid in saved_ssids))
    |> Enum.sort_by(& &1.signal_dbm, :desc)
  end

  defp secured?(flags), do: String.contains?(flags, ["WPA", "RSN", "WEP"])

  @doc "Parses LIST_NETWORKS into `[%{id, ssid, flags}]`."
  def parse_networks(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t") do
        [id, ssid, _bssid, flags] -> [%{id: id, ssid: unescape(ssid), flags: flags}]
        [id, ssid, _bssid] -> [%{id: id, ssid: unescape(ssid), flags: ""}]
        _ -> []
      end
    end)
  end

  @doc "Undoes wpa_supplicant's escaping of SSIDs (\\xNN, \\\\, \\\")."
  def unescape(s), do: s |> do_unescape([]) |> IO.iodata_to_binary()

  defp do_unescape(<<"\\x", a, b, rest::binary>>, acc) do
    case Integer.parse(<<a, b>>, 16) do
      {n, ""} -> do_unescape(rest, [acc, n])
      _ -> do_unescape(rest, [acc, "\\x", a, b])
    end
  end

  defp do_unescape(<<"\\", c, rest::binary>>, acc) when c in [?\\, ?"],
    do: do_unescape(rest, [acc, c])

  defp do_unescape(<<c, rest::binary>>, acc), do: do_unescape(rest, [acc, c])
  defp do_unescape(<<>>, acc), do: acc

  @doc "An SSID as wpa_supplicant's unquoted hex form, safe for any characters."
  def ssid_hex(ssid), do: Base.encode16(ssid, case: :lower)

  @doc """
  The WPA pre-shared key for a passphrase: PBKDF2-HMAC-SHA1, 4096 rounds,
  salted with the SSID (as `wpa_passphrase` computes it). Storing this rather
  than the passphrase keeps the passphrase itself off the device.
  """
  def psk(passphrase, ssid) when byte_size(passphrase) in 8..63 do
    {:ok, :crypto.pbkdf2_hmac(:sha, passphrase, ssid, 4096, 32) |> Base.encode16(case: :lower)}
  end

  def psk(_passphrase, _ssid), do: {:error, :bad_password_length}

  @doc """
  Classifies an unsolicited event line (with or without its `<N>` priority
  prefix) into a tuple, or nil if it doesn't matter to us.
  """
  def event(line) do
    line = Regex.replace(~r/^<\d>/, line, "")

    cond do
      String.starts_with?(line, "CTRL-EVENT-CONNECTED") ->
        :connected

      String.starts_with?(line, "CTRL-EVENT-DISCONNECTED") ->
        :disconnected

      String.starts_with?(line, "CTRL-EVENT-SSID-TEMP-DISABLED") and line =~ "WRONG_KEY" ->
        :wrong_key

      String.contains?(line, "4-Way Handshake failed") or
          String.contains?(line, "pre-shared key may be incorrect") ->
        :wrong_key

      String.starts_with?(line, "CTRL-EVENT-SCAN-RESULTS") ->
        :scan_results

      true ->
        nil
    end
  end

  @doc "Signal level 0-4 for a dBm reading, for drawing bars."
  def bars(nil), do: 0
  def bars(dbm) when dbm >= -55, do: 4
  def bars(dbm) when dbm >= -67, do: 3
  def bars(dbm) when dbm >= -75, do: 2
  def bars(dbm) when dbm >= -85, do: 1
  def bars(_dbm), do: 0

  @doc "Whether an IPv4 address string is usable (not link-local or empty)."
  def usable_ip?(nil), do: false

  def usable_ip?(ip) do
    case :inet.parse_ipv4strict_address(String.to_charlist(ip)) do
      {:ok, {169, 254, _, _}} -> false
      {:ok, {0, 0, 0, 0}} -> false
      {:ok, {127, _, _, _}} -> false
      {:ok, _} -> true
      _ -> false
    end
  end
end

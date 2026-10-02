defmodule NestGen2.WifiTest do
  # Runs the real NestGen2.Wifi against a fake wpa_supplicant on a Unix
  # datagram socket, which plays out each scenario.
  use ExUnit.Case, async: false
  alias NestGen2.Wifi

  defmodule FakeWpa do
    @moduledoc false
    use GenServer

    # in_range: %{ssid => {secured?, correct_psk_hex | nil}}; dhcp: write a lease?
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def calls, do: GenServer.call(__MODULE__, :calls)
    def networks, do: GenServer.call(__MODULE__, :networks)

    @impl true
    def init(opts) do
      File.rm(opts[:path])

      {:ok, sock} =
        :gen_udp.open(0, [:local, :binary, {:active, true}, {:ifaddr, {:local, opts[:path]}}])

      {:ok,
       %{
         sock: sock,
         log: opts[:log],
         dhcp: Keyword.get(opts, :dhcp, true),
         in_range: opts[:in_range],
         networks: %{"0" => %{ssid: "HomeNet", psk: "saved", key_mgmt: "WPA-PSK"}},
         next_id: 1,
         current: "0",
         wpa_state: "COMPLETED",
         attached: [],
         calls: []
       }}
    end

    @impl true
    def handle_call(:calls, _from, s), do: {:reply, Enum.reverse(s.calls), s}
    def handle_call(:networks, _from, s), do: {:reply, s.networks, s}

    @impl true
    def handle_info({:udp, sock, addr, port, cmd}, s) do
      s = %{s | calls: [cmd | s.calls]}
      {reply, s} = command(cmd, addr, port, s)
      :gen_udp.send(sock, addr, port, reply)
      {:noreply, s}
    end

    def handle_info({:associate, id}, s) do
      net = s.networks[id]

      case net && s.in_range[net.ssid] do
        {false, _} ->
          associated(s, id)

        {true, psk} when psk == net.psk or net.psk == "saved" ->
          associated(s, id)

        {true, _wrong} ->
          event(
            s,
            "<3>CTRL-EVENT-SSID-TEMP-DISABLED id=#{id} ssid=\"#{net.ssid}\" auth_failures=1 duration=10 reason=WRONG_KEY"
          )

          {:noreply, %{s | wpa_state: "DISCONNECTED", current: nil}}

        nil ->
          {:noreply, %{s | wpa_state: "SCANNING", current: nil}}
      end
    end

    def handle_info(:lease, s) do
      {{y, mo, d}, {h, mi, se}} = :calendar.local_time()

      stamp =
        :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [y, mo, d, h, mi, se])

      File.write!(s.log, "#{stamp} bound 192.0.2.77/24 via 192.0.2.1 dns 192.0.2.53\n", [:append])
      {:noreply, s}
    end

    def handle_info(:scan_done, s) do
      event(s, "<3>CTRL-EVENT-SCAN-RESULTS ")
      {:noreply, s}
    end

    defp associated(s, id) do
      event(s, "<3>CTRL-EVENT-CONNECTED - Connection to 02:00:00:00:00:01 completed")
      if s.dhcp, do: Process.send_after(self(), :lease, 1_200)
      {:noreply, %{s | wpa_state: "COMPLETED", current: id}}
    end

    defp event(s, text),
      do: Enum.each(s.attached, fn {a, p} -> :gen_udp.send(s.sock, a, p, text) end)

    defp command("PING", _a, _p, s), do: {"PONG\n", s}
    defp command("ATTACH", a, p, s), do: {"OK\n", %{s | attached: [{a, p} | s.attached]}}

    defp command("STATUS", _a, _p, s) do
      case s.current && s.networks[s.current] do
        nil -> {"wpa_state=#{s.wpa_state}\n", s}
        net -> {"ssid=#{net.ssid}\nid=#{s.current}\nwpa_state=#{s.wpa_state}\n", s}
      end
    end

    defp command("SIGNAL_POLL", _a, _p, s), do: {"RSSI=-55\nLINKSPEED=65\n", s}

    defp command("LIST_NETWORKS", _a, _p, s) do
      rows = for {id, n} <- Enum.sort(s.networks), do: "#{id}\t#{n.ssid}\tany\t\n"
      {["network id / ssid / bssid / flags\n" | rows] |> IO.iodata_to_binary(), s}
    end

    defp command("SCAN", _a, _p, s) do
      Process.send_after(self(), :scan_done, 50)
      {"OK\n", s}
    end

    defp command("SCAN_RESULTS", _a, _p, s) do
      rows =
        for {{ssid, {secured, _}}, i} <- Enum.with_index(s.in_range) do
          flags = if secured, do: "[WPA2-PSK-CCMP][ESS]", else: "[ESS]"
          "02:00:00:00:00:0#{i}\t2437\t-#{50 + i * 10}\t#{flags}\t#{ssid}\n"
        end

      {["bssid / frequency / signal level / flags / ssid\n" | rows] |> IO.iodata_to_binary(), s}
    end

    defp command("ADD_NETWORK", _a, _p, s) do
      id = Integer.to_string(s.next_id)

      {"#{id}\n",
       %{
         s
         | next_id: s.next_id + 1,
           networks: Map.put(s.networks, id, %{ssid: nil, psk: nil, key_mgmt: nil})
       }}
    end

    defp command("SET_NETWORK " <> rest, _a, _p, s) do
      [id, key, value] = String.split(rest, " ", parts: 3)
      value = if key == "ssid", do: Base.decode16!(value, case: :lower), else: value
      {"OK\n", update_in(s.networks[id], &Map.put(&1, String.to_atom(key), value))}
    end

    defp command("SELECT_NETWORK " <> id, _a, _p, s) do
      Process.send_after(self(), {:associate, id}, 100)
      {"OK\n", %{s | wpa_state: "SCANNING"}}
    end

    defp command("REMOVE_NETWORK " <> id, _a, _p, s),
      do: {"OK\n", %{s | networks: Map.delete(s.networks, id)}}

    defp command("ENABLE_NETWORK all", _a, _p, s), do: {"OK\n", s}
    defp command("SAVE_CONFIG", _a, _p, s), do: {"OK\n", s}
    defp command(_other, _a, _p, s), do: {"UNKNOWN COMMAND\n", s}
  end

  @phone_psk elem(NestGen2.Wifi.Protocol.psk("correct horse", "Phone"), 1)

  setup do
    dir = Path.join(System.tmp_dir!(), "nest_gen2_wifi_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = Path.join(dir, "dhcp.log")
    File.write!(log, "")

    env = [
      wifi_ctrl_dir: dir,
      wifi_interface: "wlan_test",
      wifi_dhcp_log: log,
      wifi_dhcp_pidfile: Path.join(dir, "no_udhcpc.pid"),
      wifi_associate_ms: 2_000,
      wifi_dhcp_ms: 4_000
    ]

    for {k, v} <- env, do: Application.put_env(:nest_gen2, k, v)

    on_exit(fn ->
      for {k, _} <- env, do: Application.delete_env(:nest_gen2, k)
      File.rm_rf(dir)
    end)

    start_supervised!({Registry, keys: :duplicate, name: NestGen2.Registry})
    {:ok, dir: dir}
  end

  defp start(dir, opts \\ []) do
    in_range =
      Keyword.get(opts, :in_range, %{
        "HomeNet" => {true, "saved"},
        "Phone" => {true, @phone_psk},
        "Cafe Free" => {false, nil}
      })

    start_supervised!(
      {FakeWpa,
       path: Path.join(dir, "wlan_test"),
       log: Path.join(dir, "dhcp.log"),
       in_range: in_range,
       dhcp: Keyword.get(opts, :dhcp, true)}
    )

    start_supervised!(Wifi)
    wait_until(fn -> Wifi.status().state != :unavailable end)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "unavailable without wpa_supplicant" do
    start_supervised!(Wifi)
    assert Wifi.status().state == :unavailable
    assert Wifi.scan() == {:error, :unavailable}
    assert Wifi.connect("Phone", "correct horse") == {:error, :unavailable}
  end

  test "status, saved networks and scan", %{dir: dir} do
    start(dir)
    assert %{state: :connected, ssid: "HomeNet", signal_dbm: -55} = Wifi.status()
    assert Wifi.saved_networks() == ["HomeNet"]
    {:ok, networks} = Wifi.scan()
    assert Enum.map(networks, & &1.ssid) == ["Cafe Free", "HomeNet", "Phone"]
    assert Enum.find(networks, &(&1.ssid == "HomeNet")).saved
  end

  test "joins a new network, gets an address and saves it", %{dir: dir} do
    start(dir)
    NestGen2.subscribe(:wifi)
    assert Wifi.connect("Phone", "correct horse") == {:ok, %{ssid: "Phone", ip: "192.0.2.77"}}
    calls = FakeWpa.calls()
    assert "SAVE_CONFIG" in calls
    assert Enum.any?(calls, &String.starts_with?(&1, "SET_NETWORK 1 psk " <> @phone_psk))
    # The password itself is never sent, only the derived key.
    refute Enum.any?(calls, &String.contains?(&1, "correct horse"))
    assert_receive {:nest_gen2, :wifi, %{ssid: "Phone"}}
  end

  test "a wrong password goes back to the previous network without saving", %{dir: dir} do
    start(dir)
    assert Wifi.connect("Phone", "wrong password") == {:error, :wrong_password}
    calls = FakeWpa.calls()
    assert "REMOVE_NETWORK 1" in calls
    assert "SELECT_NETWORK 0" in calls
    refute "SAVE_CONFIG" in calls
    assert Map.keys(FakeWpa.networks()) == ["0"]
    wait_until(fn -> Wifi.status().ssid == "HomeNet" end)
  end

  test "a network that isn't there", %{dir: dir} do
    start(dir)
    assert Wifi.connect("Nowhere", "whatever123") == {:error, :not_found}
    assert "SELECT_NETWORK 0" in FakeWpa.calls()
  end

  test "joined but no address", %{dir: dir} do
    start(dir, dhcp: false)
    assert Wifi.connect("Phone", "correct horse") == {:error, :no_ip}
    refute "SAVE_CONFIG" in FakeWpa.calls()
  end

  test "open network needs no password", %{dir: dir} do
    start(dir)
    assert {:ok, %{ssid: "Cafe Free"}} = Wifi.connect("Cafe Free")
    assert Enum.any?(FakeWpa.calls(), &(&1 =~ "key_mgmt NONE"))
  end

  test "a secured network needs a password unless saved", %{dir: dir} do
    start(dir)
    assert Wifi.connect("Phone") == {:error, :password_required}
    assert Wifi.connect("Phone", "short") == {:error, :bad_password_length}
  end

  test "forget", %{dir: dir} do
    start(dir)
    assert Wifi.forget("HomeNet") == {:error, :connected}
    assert Wifi.forget("Elsewhere") == {:error, :not_found}
  end

  test "one connect at a time", %{dir: dir} do
    start(dir)
    task = Task.async(fn -> Wifi.connect("Phone", "correct horse") end)
    Process.sleep(100)
    assert Wifi.connect("Cafe Free") == {:error, :busy}
    assert {:ok, _} = Task.await(task, 10_000)
  end
end

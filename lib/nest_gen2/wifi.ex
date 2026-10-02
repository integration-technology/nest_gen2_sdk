defmodule NestGen2.Wifi do
  @moduledoc """
  Wi-Fi: status, scanning, joining a network, and saved networks.

  The platform runs `wpa_supplicant` and `udhcpc` (see `platform/wifi`) in
  place of Nest's connection manager; this module talks to `wpa_supplicant`
  through its control socket. If they aren't running, `status/0` reports
  `:unavailable` and the other calls return `{:error, :unavailable}`.

      NestGen2.Wifi.status()
      #=> %{state: :connected, ssid: "HomeNet", ip: "192.0.2.7", signal_dbm: -58}

      {:ok, networks} = NestGen2.Wifi.scan()
      {:ok, %{ip: ip}} = NestGen2.Wifi.connect("Phone hotspot", "correct horse")

  `connect/2` is safe to try: the new network is only saved once it has an
  address. On any failure the previous network is selected again, and the
  saved configuration is left unchanged. Passwords are stored as the derived
  WPA key, never as entered.

  Publishes `{:nest_gen2, :wifi, %{state, ssid, ip}}` whenever those change.
  """
  use GenServer
  require Logger
  alias NestGen2.Wifi.Protocol

  @retry_ms 10_000
  @refresh_ms 15_000
  @scan_timeout_ms 8_000
  @tick_ms 500
  @connect_call_ms 90_000

  @type status :: %{
          state: :connected | :connecting | :disconnected | :unavailable,
          ssid: String.t() | nil,
          ip: String.t() | nil,
          signal_dbm: integer | nil
        }
  @type network :: %{ssid: String.t(), signal_dbm: integer, secured: boolean, saved: boolean}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Current connection."
  @spec status() :: status
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Scans for networks (takes a few seconds). Strongest first, one entry per SSID."
  @spec scan() :: {:ok, [network]} | {:error, term}
  def scan, do: GenServer.call(__MODULE__, :scan, @scan_timeout_ms + 5_000)

  @doc """
  Joins a network. `password` is nil for an open network, or to use the
  saved key of a network joined before. Takes up to about a minute; call it
  from a separate process, not from a GenServer that must stay responsive.
  """
  @spec connect(String.t(), String.t() | nil) ::
          {:ok, %{ssid: String.t(), ip: String.t()}}
          | {:error,
             :wrong_password
             | :not_found
             | :no_ip
             | :timeout
             | :password_required
             | :bad_password_length
             | :busy
             | :unavailable
             | term}
  def connect(ssid, password \\ nil) when is_binary(ssid),
    do: GenServer.call(__MODULE__, {:connect, ssid, password}, @connect_call_ms)

  @doc "SSIDs of the saved networks."
  @spec saved_networks() :: [String.t()]
  def saved_networks, do: GenServer.call(__MODULE__, :saved_networks)

  @doc "Removes a saved network (not the one in use)."
  @spec forget(String.t()) :: :ok | {:error, :not_found | :connected | :unavailable}
  def forget(ssid), do: GenServer.call(__MODULE__, {:forget, ssid})

  # --- server

  @impl true
  def init(nil) do
    send(self(), :open)

    {:ok,
     %{
       ctrl: nil,
       events: nil,
       paths: [],
       status: unavailable(),
       scan_waiters: [],
       scan_timer: nil,
       connect: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, s), do: {:reply, s.status, s}

  def handle_call(_request, _from, %{ctrl: nil} = s), do: {:reply, {:error, :unavailable}, s}

  def handle_call(:scan, from, s) do
    s =
      if s.scan_waiters == [] do
        _ = request(s, "SCAN")
        %{s | scan_timer: Process.send_after(self(), :scan_timeout, @scan_timeout_ms)}
      else
        s
      end

    {:noreply, %{s | scan_waiters: [from | s.scan_waiters]}}
  end

  def handle_call(:saved_networks, _from, s) do
    {:reply, networks(s) |> Enum.map(& &1.ssid) |> Enum.uniq(), s}
  end

  def handle_call({:forget, ssid}, _from, s) do
    ids = for %{id: id, ssid: ^ssid} <- networks(s), do: id

    cond do
      ids == [] ->
        {:reply, {:error, :not_found}, s}

      s.status.ssid == ssid ->
        {:reply, {:error, :connected}, s}

      true ->
        Enum.each(ids, &request(s, "REMOVE_NETWORK #{&1}"))
        _ = request(s, "SAVE_CONFIG")
        {:reply, :ok, s}
    end
  end

  def handle_call({:connect, _ssid, _password}, _from, %{connect: c} = s) when c != nil,
    do: {:reply, {:error, :busy}, s}

  def handle_call({:connect, ssid, password}, from, s) do
    case start_connect(s, ssid, password) do
      {:ok, c} ->
        Logger.info("nest_gen2: joining Wi-Fi #{inspect(ssid)}")
        Process.send_after(self(), :connect_tick, @tick_ms)
        {:noreply, %{s | connect: Map.put(c, :from, from)}}

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_info(:open, s) do
    s = close(s)

    case open() do
      {:ok, ctrl, events, paths} ->
        s = refresh(%{s | ctrl: ctrl, events: events, paths: paths})
        Logger.info("nest_gen2: Wi-Fi control connected (#{inspect(s.status.ssid)})")
        Process.send_after(self(), :refresh, @refresh_ms)
        {:noreply, s}

      {:error, _reason} ->
        Process.send_after(self(), :open, @retry_ms)
        {:noreply, %{s | status: unavailable()}}
    end
  end

  def handle_info(:refresh, %{ctrl: nil} = s), do: {:noreply, s}

  def handle_info(:refresh, s) do
    Process.send_after(self(), :refresh, @refresh_ms)

    case request(s, "PING") do
      {:ok, "PONG" <> _} ->
        {:noreply, refresh(s)}

      _ ->
        # wpa_supplicant went away (e.g. restarted); reconnect to it.
        send(self(), :open)
        {:noreply, s}
    end
  end

  def handle_info({:udp, sock, _from, _port, data}, %{events: sock} = s) do
    case Protocol.event(data) do
      :scan_results -> {:noreply, reply_scan(s)}
      :wrong_key -> {:noreply, flag_wrong_key(s)}
      ev when ev in [:connected, :disconnected] -> {:noreply, refresh(s)}
      _ -> {:noreply, s}
    end
  end

  def handle_info(:scan_timeout, s), do: {:noreply, reply_scan(s)}

  def handle_info(:connect_tick, %{connect: nil} = s), do: {:noreply, s}
  def handle_info(:connect_tick, s), do: {:noreply, connect_step(s)}

  def handle_info(_other, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s), do: close(s)

  # --- connecting

  defp start_connect(s, ssid, password) do
    saved = Enum.find(networks(s), &(&1.ssid == ssid))
    prev_id = Map.get(status_kv(s), "id")

    with {:ok, setup} <- network_setup(s, ssid, password, saved),
         {:ok, id, temp?} <- create_network(s, ssid, saved, setup),
         {:ok, "OK" <> _} <- request(s, "SELECT_NETWORK #{id}") do
      {:ok,
       %{
         ssid: ssid,
         id: id,
         temp?: temp?,
         prev_id: prev_id,
         phase: :associating,
         deadline: now() + config(:wifi_associate_ms),
         wrong_key: false,
         since: nil
       }}
    else
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  # What SET_NETWORK needs: a key for a new password, nothing to set for a
  # saved network, or open (no key) when the network isn't secured.
  defp network_setup(_s, ssid, password, _saved) when is_binary(password) do
    with {:ok, key} <- Protocol.psk(password, ssid), do: {:ok, {:psk, key}}
  end

  defp network_setup(_s, _ssid, nil, saved) when saved != nil, do: {:ok, :saved}

  defp network_setup(s, ssid, nil, nil) do
    case Enum.find(last_scan(s), &(&1.ssid == ssid)) do
      %{secured: true} -> {:error, :password_required}
      _ -> {:ok, :open}
    end
  end

  defp create_network(_s, _ssid, saved, :saved), do: {:ok, saved.id, false}

  # A new entry even when the SSID is saved, so a wrong password can't
  # replace a working one: the old entry is removed only on success.
  defp create_network(s, ssid, _saved, setup) do
    with {:ok, id} <- add_network(s),
         :ok <- set(s, id, "ssid", Protocol.ssid_hex(ssid)),
         :ok <- set_key(s, id, setup) do
      {:ok, id, true}
    end
  end

  defp set_key(s, id, {:psk, key}) do
    with :ok <- set(s, id, "psk", key), do: set(s, id, "key_mgmt", "WPA-PSK")
  end

  defp set_key(s, id, :open), do: set(s, id, "key_mgmt", "NONE")

  defp add_network(s) do
    case request(s, "ADD_NETWORK") do
      {:ok, reply} ->
        case Integer.parse(String.trim(reply)) do
          {_n, ""} -> {:ok, String.trim(reply)}
          _ -> {:error, {:add_network, reply}}
        end

      error ->
        error
    end
  end

  defp set(s, id, key, value) do
    case request(s, "SET_NETWORK #{id} #{key} #{value}") do
      {:ok, "OK" <> _} -> :ok
      other -> {:error, {:set_network, key, other}}
    end
  end

  defp connect_step(%{connect: c} = s) do
    kv = status_kv(s)

    cond do
      c.wrong_key ->
        fail(s, :wrong_password)

      c.phase == :associating and kv["wpa_state"] == "COMPLETED" and kv["ssid"] == c.ssid ->
        since = local_stamp()
        renew_lease(s)

        tick(%{
          s
          | connect: %{c | phase: :dhcp, deadline: now() + config(:wifi_dhcp_ms), since: since}
        })

      c.phase == :dhcp ->
        case bound_since(c.since) do
          {:ok, ip} -> succeed(s, ip)
          :none -> if now() > c.deadline, do: fail(s, :no_ip), else: tick(s)
        end

      now() > c.deadline ->
        reason = if Enum.any?(last_scan(s), &(&1.ssid == c.ssid)), do: :timeout, else: :not_found
        fail(s, reason)

      true ->
        tick(s)
    end
  end

  defp tick(s) do
    Process.send_after(self(), :connect_tick, @tick_ms)
    s
  end

  defp succeed(%{connect: c} = s, ip) do
    if c.temp? do
      for %{id: id, ssid: ssid} <- networks(s),
          ssid == c.ssid,
          id != c.id,
          do: request(s, "REMOVE_NETWORK #{id}")
    end

    _ = request(s, "ENABLE_NETWORK all")
    _ = request(s, "SAVE_CONFIG")
    NestGen2.Network.configure_dns()
    Logger.info("nest_gen2: joined Wi-Fi #{inspect(c.ssid)} as #{ip}")
    GenServer.reply(c.from, {:ok, %{ssid: c.ssid, ip: ip}})
    refresh(%{s | connect: nil})
  end

  defp fail(%{connect: c} = s, reason) do
    if c.temp?, do: request(s, "REMOVE_NETWORK #{c.id}")
    if c.prev_id, do: request(s, "SELECT_NETWORK #{c.prev_id}")
    _ = request(s, "ENABLE_NETWORK all")
    renew_lease(s)

    Logger.warning(
      "nest_gen2: couldn't join Wi-Fi #{inspect(c.ssid)}: #{inspect(reason)}; back on the previous network"
    )

    GenServer.reply(c.from, {:error, reason})
    refresh(%{s | connect: nil})
  end

  defp flag_wrong_key(%{connect: nil} = s), do: s
  defp flag_wrong_key(%{connect: c} = s), do: %{s | connect: %{c | wrong_key: true}}

  # udhcpc: release the old lease, then ask for a new one on the network we're on.
  defp renew_lease(_s) do
    with {:ok, pid} <- File.read(config(:wifi_dhcp_pidfile)),
         pid = String.trim(pid),
         true <- pid != "" do
      System.cmd("/bin/kill", ["-USR2", pid], stderr_to_stdout: true)
      # Signals sent together can be handled in either order, leaving udhcpc
      # released with no lease; let it finish the release first.
      Process.sleep(1_000)
      System.cmd("/bin/kill", ["-USR1", pid], stderr_to_stdout: true)
    end

    :ok
  end

  # The udhcpc script logs "YYYY-MM-DD HH:MM:SS bound IP/MASK via ...".
  defp bound_since(since) do
    case File.read(config(:wifi_dhcp_log)) do
      {:ok, log} ->
        log
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(:none, fn line ->
          case String.split(line, " ") do
            [d, t, event, cidr | _] when event in ["bound", "renew"] ->
              if "#{d} #{t}" >= since, do: {:ok, cidr |> String.split("/") |> hd()}

            _ ->
              nil
          end
        end)

      _ ->
        :none
    end
  end

  # --- scanning

  defp reply_scan(%{scan_waiters: []} = s), do: s

  defp reply_scan(s) do
    if s.scan_timer, do: Process.cancel_timer(s.scan_timer)
    result = {:ok, last_scan(s)}
    Enum.each(s.scan_waiters, &GenServer.reply(&1, result))
    %{s | scan_waiters: [], scan_timer: nil}
  end

  defp last_scan(s) do
    saved = networks(s) |> Enum.map(& &1.ssid)

    case request(s, "SCAN_RESULTS") do
      {:ok, text} -> Protocol.parse_scan(text, saved)
      _ -> []
    end
  end

  # --- status

  defp refresh(%{ctrl: nil} = s), do: s

  defp refresh(s) do
    kv = status_kv(s)
    signal = request(s, "SIGNAL_POLL") |> signal()

    status = %{
      state: state(kv["wpa_state"]),
      ssid: kv["ssid"] && Protocol.unescape(kv["ssid"]),
      ip: interface_ip(),
      signal_dbm: signal
    }

    if Map.take(status, [:state, :ssid, :ip]) != Map.take(s.status, [:state, :ssid, :ip]),
      do: NestGen2.publish(:wifi, Map.take(status, [:state, :ssid, :ip]))

    %{s | status: status}
  end

  defp status_kv(s) do
    case request(s, "STATUS") do
      {:ok, text} -> Protocol.parse_kv(text)
      _ -> %{}
    end
  end

  defp signal({:ok, text}) do
    case Integer.parse(Map.get(Protocol.parse_kv(text), "RSSI", "")) do
      {dbm, _} -> dbm
      :error -> nil
    end
  end

  defp signal(_), do: nil

  defp state("COMPLETED"), do: :connected

  defp state(s)
       when s in ~w(SCANNING AUTHENTICATING ASSOCIATING ASSOCIATED 4WAY_HANDSHAKE GROUP_HANDSHAKE),
       do: :connecting

  defp state(_), do: :disconnected

  defp interface_ip do
    iface = config(:wifi_interface) |> String.to_charlist()

    with {:ok, ifaddrs} <- :inet.getifaddrs(),
         {_, opts} <- List.keyfind(ifaddrs, iface, 0),
         {a, b, c, d} <- Enum.find(Keyword.get_values(opts, :addr), &(tuple_size(&1) == 4)) do
      ip = "#{a}.#{b}.#{c}.#{d}"
      if Protocol.usable_ip?(ip), do: ip
    else
      _ -> nil
    end
  end

  defp networks(s) do
    case request(s, "LIST_NETWORKS") do
      {:ok, text} -> Protocol.parse_networks(text)
      _ -> []
    end
  end

  defp unavailable, do: %{state: :unavailable, ssid: nil, ip: nil, signal_dbm: nil}

  # --- control socket

  # Two client sockets: one for request/reply, one attached for events.
  defp open do
    server = server_path()

    if File.exists?(server) do
      with {:ok, ctrl, p1} <- client_socket("ctrl", false),
           {:ok, events, p2} <- client_socket("ev", true),
           :ok <- :gen_udp.send(events, {:local, server}, 0, "ATTACH") do
        {:ok, ctrl, events, [p1, p2]}
      end
    else
      {:error, :no_wpa_supplicant}
    end
  end

  defp client_socket(tag, active) do
    path = "/tmp/nest_gen2_wpa_#{tag}_#{System.unique_integer([:positive])}"
    File.rm(path)

    case :gen_udp.open(0, [:local, :binary, {:active, active}, {:ifaddr, {:local, path}}]) do
      {:ok, sock} -> {:ok, sock, path}
      error -> error
    end
  end

  defp close(s) do
    for sock <- [s.ctrl, s.events], sock != nil, do: :gen_udp.close(sock)
    Enum.each(s.paths, &File.rm/1)
    %{s | ctrl: nil, events: nil, paths: []}
  end

  defp request(%{ctrl: nil}, _cmd), do: {:error, :unavailable}

  defp request(%{ctrl: sock}, cmd) do
    drain(sock)

    with :ok <- :gen_udp.send(sock, {:local, server_path()}, 0, cmd),
         {:ok, {_addr, _port, reply}} <- :gen_udp.recv(sock, 0, 3_000) do
      {:ok, reply}
    end
  end

  # Discard a late reply to an earlier request that timed out.
  defp drain(sock) do
    case :gen_udp.recv(sock, 0, 0) do
      {:ok, _} -> drain(sock)
      _ -> :ok
    end
  end

  defp server_path, do: Path.join(config(:wifi_ctrl_dir), config(:wifi_interface))
  defp config(key), do: NestGen2.Config.get(key)
  defp now, do: System.monotonic_time(:millisecond)

  defp local_stamp do
    {{y, mo, d}, {h, mi, se}} = :calendar.local_time()

    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [y, mo, d, h, mi, se])
    |> IO.iodata_to_binary()
  end
end

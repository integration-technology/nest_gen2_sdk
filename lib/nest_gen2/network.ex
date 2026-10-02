defmodule NestGen2.Network do
  @moduledoc """
  Name resolution that doesn't depend on Nest's connection manager.

  Nest's `/etc/resolv.conf` points at `127.0.0.1`, a DNS proxy inside `connmand`.
  If that process stops, nothing resolves (and a statically linked VM can't use
  the device's own resolver anyway). The SDK instead points Erlang's own DNS
  client (`inet_res`) at real servers when it starts, and stops it re-reading
  resolv.conf:

    * the `:nameservers` setting, if given (a list of IPv4 tuples), else
    * non-loopback servers from `/etc/resolv.conf`, else
    * the default gateway.
  """
  require Logger

  @resolv "/etc/resolv.conf"
  @route "/proc/net/route"

  @doc "Configures Erlang's resolver; returns the nameservers used."
  @spec configure_dns() :: [:inet.ip4_address()]
  def configure_dns do
    servers =
      case Application.get_env(:nest_gen2, :nameservers) do
        list when is_list(list) and list != [] -> list
        _ -> auto_nameservers()
      end

    # inet_db re-reads resolv.conf on use and would put the dead 127.0.0.1 proxy
    # back, so stop it watching the file before setting the servers.
    :ok = :inet_db.res_option(:resolv_conf, ~c"")
    :ok = :inet_db.res_option(:nameservers, Enum.map(servers, &{&1, 53}))
    :inet_db.set_lookup([:file, :dns])
    Logger.info("nest_gen2: DNS via #{Enum.map_join(servers, ", ", &:inet.ntoa/1)}")
    servers
  end

  @doc "The default gateway's IPv4 address, or nil."
  @spec gateway() :: :inet.ip4_address() | nil
  def gateway, do: read(@route) |> default_gateway()

  defp auto_nameservers do
    resolv = read(@resolv) |> nameservers()
    if resolv != [], do: resolv, else: List.wrap(gateway())
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  @doc false
  # IPv4 nameservers from resolv.conf text, excluding loopback.
  def nameservers(text) do
    for line <- String.split(text, "\n"),
        ["nameserver", addr | _] <- [String.split(line)],
        {:ok, {a, _, _, _} = ip} <- [:inet.parse_ipv4strict_address(String.to_charlist(addr))],
        a != 127,
        do: ip
  end

  @doc false
  # Default gateway from /proc/net/route text (little-endian hex), or nil.
  def default_gateway(text) do
    Enum.find_value(String.split(text, "\n"), fn line ->
      case String.split(line) do
        [_iface, "00000000", gw | _] when gw != "00000000" ->
          <<d, c, b, a>> = <<String.to_integer(gw, 16)::32>>
          {a, b, c, d}

        _ ->
          nil
      end
    end)
  end
end

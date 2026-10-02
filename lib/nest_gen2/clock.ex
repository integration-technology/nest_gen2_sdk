defmodule NestGen2.Clock do
  @moduledoc """
  Keeps the system clock (UTC) right.

  The Nest restores UTC from its battery-backed RTC at boot, but nothing
  corrects it afterwards: Nest's own NTP client lived in `connmand`, which
  isn't reliable once the stock stack is off. This asks NTP servers (SNTP over
  UDP 123) shortly after start and then every `:clock_sync_interval_ms`,
  steps the system clock when it is out by `:clock_step_ms` or more, and saves
  it to the RTC after every successful check so the next boot starts right.

  Servers are tried in order from `:time_servers` (host names, IPv4 tuples, or
  `:gateway` for the default router).

  Apps that already talk to a trusted HTTPS server can pass its `Date` header
  to `observe/2` as a fallback: it only corrects the clock when NTP hasn't
  succeeded for 12 hours and the difference is over 30 seconds.

  Local time and daylight saving are the app's concern; this only keeps UTC.
  The VM must run with `+C multi_time_warp` (as `app_watchdog.sh` does) so
  Erlang's own time follows a stepped clock.
  """
  use GenServer
  require Logger
  alias NestGen2.Config

  # Seconds from the NTP epoch (1900) to the Unix epoch (1970).
  @ntp_unix 2_208_988_800
  # Not while the VM is still busy starting: a late-read reply skews the offset.
  @first_sync_ms 30_000
  @samples 4
  @sample_gap_ms 250
  # Round trips longer than this can't be trusted to within the step threshold.
  @max_delay_ms 500
  @retry_ms 120_000
  @reply_timeout_ms 5_000
  @observe_threshold_s 30
  @ntp_fresh_ms 12 * 3_600_000
  @date "/bin/date"
  @hwclock "/sbin/hwclock"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Queries NTP now and corrects the clock if needed."
  @spec sync() :: {:ok, %{server: term, offset_ms: integer}} | {:error, term}
  def sync, do: GenServer.call(__MODULE__, :sync, 60_000)

  @doc "When and how the clock was last checked."
  @spec status() :: map
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Reports the UTC time according to another source (e.g. an HTTPS `Date`
  header). Used only as a fallback when NTP has been failing.
  """
  @spec observe(DateTime.t(), term) :: :ok
  def observe(%DateTime{} = utc, source), do: GenServer.cast(__MODULE__, {:observe, utc, source})

  @impl true
  def init(nil) do
    Process.send_after(self(), :sync, @first_sync_ms)
    {:ok, %{synced_at: nil, synced_mono: nil, server: nil, offset_ms: nil, last_error: nil}}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {reply, state} = do_sync(state)
    {:reply, reply, state}
  end

  def handle_call(:status, _from, state),
    do: {:reply, Map.drop(state, [:synced_mono]), state}

  @impl true
  def handle_cast({:observe, utc, source}, state) do
    diff_s = DateTime.diff(utc, DateTime.utc_now(), :second)

    cond do
      abs(diff_s) <= @observe_threshold_s ->
        :ok

      ntp_fresh?(state) ->
        Logger.warning(
          "nest_gen2: #{inspect(source)} says the clock is #{diff_s} s out; trusting NTP"
        )

      true ->
        Logger.warning(
          "nest_gen2: no recent NTP; setting the clock from #{inspect(source)} (#{diff_s} s)"
        )

        set_clock(DateTime.to_unix(utc, :millisecond))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:sync, state) do
    {reply, state} = do_sync(state)
    delay = if match?({:ok, _}, reply), do: Config.get(:clock_sync_interval_ms), else: @retry_ms
    Process.send_after(self(), :sync, delay)
    {:noreply, state}
  end

  defp do_sync(state) do
    case query_servers(Config.get(:time_servers)) do
      {:ok, server, offset_ms} ->
        if state.synced_at == nil,
          do:
            Logger.info(
              "nest_gen2: clock checked against #{inspect(server)}, #{offset_ms} ms out"
            )

        if abs(offset_ms) >= Config.get(:clock_step_ms) do
          Logger.info("nest_gen2: clock #{offset_ms} ms out by #{inspect(server)}; setting it")
          set_clock(System.os_time(:millisecond) + offset_ms)
        else
          # Close enough: still refresh the RTC so its own drift never builds up.
          save_rtc()
        end

        state = %{
          state
          | synced_at: DateTime.utc_now(),
            synced_mono: System.monotonic_time(:millisecond),
            server: server,
            offset_ms: offset_ms,
            last_error: nil
        }

        {{:ok, %{server: server, offset_ms: offset_ms}}, state}

      {:error, reason} ->
        Logger.warning("nest_gen2: NTP failed: #{inspect(reason)}")
        {{:error, reason}, %{state | last_error: reason}}
    end
  end

  defp ntp_fresh?(%{synced_mono: nil}), do: false

  defp ntp_fresh?(%{synced_mono: t}),
    do: System.monotonic_time(:millisecond) - t < @ntp_fresh_ms

  defp query_servers(servers) do
    Enum.reduce_while(servers, {:error, :no_servers}, fn server, _acc ->
      case query(server) do
        {:ok, %{offset_ms: offset}} -> {:halt, {:ok, server, offset}}
        {:error, reason} -> {:cont, {:error, {server, reason}}}
      end
    end)
  end

  defp query(:gateway) do
    case NestGen2.Network.gateway() do
      nil -> {:error, :no_gateway}
      ip -> query(ip)
    end
  end

  # Several samples from one server; the one with the shortest round trip is
  # the least distorted by network or scheduling delays (as NTP does).
  defp query(server) do
    host = if is_binary(server), do: String.to_charlist(server), else: server

    with {:ok, ip} <- :inet.getaddr(host, :inet) do
      samples =
        for i <- 1..@samples do
          if i > 1, do: Process.sleep(@sample_gap_ms)
          sample(ip)
        end

      best_sample(for({:ok, m} <- samples, do: m), @max_delay_ms)
    end
  end

  defp sample(ip) do
    with {:ok, socket} <- :gen_udp.open(0, [:binary, active: false]) do
      try do
        t1 = System.os_time(:millisecond)
        :ok = :gen_udp.send(socket, ip, 123, request(t1))

        case :gen_udp.recv(socket, 0, @reply_timeout_ms) do
          {:ok, {_ip, 123, packet}} -> measure(packet, t1, System.os_time(:millisecond))
          {:ok, _other} -> {:error, :unexpected_reply}
          {:error, reason} -> {:error, reason}
        end
      after
        :gen_udp.close(socket)
      end
    end
  end

  @doc false
  # The sample with the shortest round trip, if that is short enough to trust.
  def best_sample([], _max_delay_ms), do: {:error, :no_replies}

  def best_sample(samples, max_delay_ms) do
    case Enum.min_by(samples, & &1.delay_ms) do
      %{delay_ms: d} = best when d <= max_delay_ms -> {:ok, best}
      %{delay_ms: d} -> {:error, {:slow_replies, d}}
    end
  end

  # Steps the system clock to `target_ms` (Unix ms, UTC) and saves it to the
  # RTC. `date` takes whole seconds, so wait for the next second boundary.
  defp set_clock(target_ms) do
    wait = 1000 - rem(target_ms, 1000)
    Process.sleep(wait)
    {:ok, at} = DateTime.from_unix(div(target_ms + wait, 1000))
    stamp = Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")

    case run(@date, ["-u", "-s", stamp]) do
      {_, 0} -> save_rtc()
      failure -> log_failure("setting the clock", failure)
    end
  end

  # Copies the system clock to the battery-backed RTC, which the boot restores from.
  defp save_rtc do
    case run(@hwclock, ["-u", "-w"]) do
      {_, 0} -> :ok
      failure -> log_failure("saving the RTC", failure)
    end
  end

  # Absolute paths: the VM's PATH (from rcS) doesn't include /sbin.
  defp run(command, args) do
    System.cmd(command, args, stderr_to_stdout: true)
  rescue
    error -> {Exception.message(error), :not_run}
  end

  defp log_failure(what, {output, status}) do
    Logger.error("nest_gen2: #{what} failed (#{status}): #{String.trim(output)}")
    {:error, status}
  end

  @doc false
  # A client request (version 4, mode 3) carrying `t1` as its transmit time,
  # which the server echoes back as the originate time.
  def request(t1_ms), do: <<0::2, 4::3, 3::3, 0::size(39)-unit(8), ntp_timestamp(t1_ms)::binary>>

  @doc false
  # Offset and round-trip delay from a server reply: offset is
  # ((t2 - t1) + (t3 - t4)) / 2 and delay (t4 - t1) - (t3 - t2), where t1/t4
  # are our send/receive times and t2/t3 the server's receive/transmit times.
  def measure(packet, t1, t4) do
    case packet do
      <<_li::2, _vn::3, 4::3, stratum, _::binary-size(22), orig::binary-size(8),
        recv::binary-size(8), xmit::binary-size(8), _::binary>> ->
        cond do
          stratum not in 1..15 ->
            {:error, {:stratum, stratum}}

          orig != ntp_timestamp(t1) ->
            {:error, :originate_mismatch}

          true ->
            t2 = from_ntp(recv)
            t3 = from_ntp(xmit)
            {:ok, %{offset_ms: div(t2 - t1 + (t3 - t4), 2), delay_ms: t4 - t1 - (t3 - t2)}}
        end

      _ ->
        {:error, :bad_packet}
    end
  end

  @doc false
  def offset_ms(packet, t1, t4) do
    with {:ok, %{offset_ms: offset}} <- measure(packet, t1, t4), do: {:ok, offset}
  end

  @doc false
  def ntp_timestamp(unix_ms) do
    seconds = div(unix_ms, 1000) + @ntp_unix
    # Rounded up so from_ntp/1 gives back the same millisecond.
    fraction = div(rem(unix_ms, 1000) * 0x1_0000_0000 + 999, 1000)
    <<seconds::32, fraction::32>>
  end

  @doc false
  # NTP seconds wrap in February 2036; small values are taken to be after it.
  def from_ntp(<<seconds::32, fraction::32>>) do
    seconds = if seconds < 0x8000_0000, do: seconds + 0x1_0000_0000, else: seconds
    (seconds - @ntp_unix) * 1000 + div(fraction * 1000, 0x1_0000_0000)
  end
end

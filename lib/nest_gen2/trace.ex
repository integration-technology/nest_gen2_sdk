defmodule NestGen2.Trace do
  @moduledoc false
  # Optional diagnostic trace: when :trace_file is set (use a tmpfs path such as
  # /tmp, not flash), append timestamped lines for backplate traffic and screen
  # wake/sleep.
  #
  # /tmp is RAM, and the Nest has only a few MB to spare: an unbounded trace
  # grows about 7 MB a day and runs it out of memory overnight (the board then
  # resets). So the file is capped: past :trace_max_bytes it becomes
  # <file>.1, replacing the previous one, and a new file starts.
  #
  # Power events (event/1) also go to :trace_keep_file, on flash, so they
  # outlive a reboot: its last lines say what the Nest was doing when it went.
  # A few lines every few minutes, each synced before the next step (a suspend
  # that never wakes, say).

  @default_max_bytes 256 * 1024
  @keep_max_bytes 64 * 1024

  def write(line) do
    # A charlist when set from the erl command line, a binary from config.
    with path when is_binary(path) or is_list(path) <-
           Application.get_env(:nest_gen2, :trace_file) do
      path = to_string(path)
      rotate(path, Application.get_env(:nest_gen2, :trace_max_bytes, @default_max_bytes))
      stamp = DateTime.utc_now() |> DateTime.to_time() |> Time.to_iso8601()
      File.write(path, [stamp, " ", line, "\n"], [:append])
    end

    :ok
  end

  def event(line) do
    write(line)

    with path when is_binary(path) or is_list(path) <-
           Application.get_env(:nest_gen2, :trace_keep_file) do
      path = to_string(path)
      rotate(path, @keep_max_bytes)
      stamp = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      append_synced(path, [stamp, " ", line, "\n"])
    end

    :ok
  end

  defp append_synced(path, data) do
    with {:ok, fd} <- :file.open(path, [:append, :raw, :binary]) do
      :file.write(fd, data)
      :file.datasync(fd)
      :file.close(fd)
    end
  end

  defp rotate(path, max_bytes) do
    case File.stat(path) do
      {:ok, %{size: size}} when size >= max_bytes -> File.rename(path, path <> ".1")
      _ -> :ok
    end
  end
end

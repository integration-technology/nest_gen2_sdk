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

  @default_max_bytes 256 * 1024

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

  defp rotate(path, max_bytes) do
    case File.stat(path) do
      {:ok, %{size: size}} when size >= max_bytes -> File.rename(path, path <> ".1")
      _ -> :ok
    end
  end
end

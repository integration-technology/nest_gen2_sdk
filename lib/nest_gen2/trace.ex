defmodule NestGen2.Trace do
  @moduledoc false
  # Optional diagnostic trace: when :trace_file is set (use a tmpfs path such as
  # /tmp, not flash), append timestamped lines for backplate traffic and screen
  # wake/sleep.

  def write(line) do
    # A charlist when set from the erl command line, a binary from config.
    with path when is_binary(path) or is_list(path) <-
           Application.get_env(:nest_gen2, :trace_file) do
      stamp = DateTime.utc_now() |> DateTime.to_time() |> Time.to_iso8601()
      File.write(path, [stamp, " ", line, "\n"], [:append])
    end

    :ok
  end
end

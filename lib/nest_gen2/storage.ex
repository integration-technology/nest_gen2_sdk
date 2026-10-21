defmodule NestGen2.Storage do
  @moduledoc """
  Settings that survive restarts and power cuts, for apps.

      NestGen2.Storage.put(:screen, %{idle_timeout_ms: 30_000})
      NestGen2.Storage.get(:screen, %{idle_timeout_ms: :infinity})

  Each app gets its own folder in flash that nothing else touches,
  `<install>/data/<app>`, and each key is one file in it, holding an Erlang
  term as readable text (`cat` shows it) with a checksum. Writes are made safe
  against the power going mid-write: the new value goes to a temporary file
  that is flushed to flash, the previous value is kept as a backup, and the
  temporary file is then renamed into place. A value that doesn't check out
  when read falls back to the backup, then to the default; it never raises.

  Meant for settings and small state that change now and then, not for data
  written every second: the Nest's flash is slow and wears out.

  For anything more (logs, a cache, a database such as CubDB), `dir/1` is the
  app's own folder to use as it likes.

  Keys are atoms or strings of lowercase letters, digits and underscores.
  Values are any term that can be written out and read back as text: maps,
  lists, tuples, strings, numbers, atoms; not pids, references or functions.
  The calling process's application is used unless `app:` is given.
  """

  @header "%% nest_gen2 storage v1 crc32="

  @type key :: atom | String.t()

  @doc "The app's own folder in flash (created if missing)."
  @spec dir(keyword) :: Path.t()
  def dir(opts \\ []) do
    path = Path.join(base_dir(), Atom.to_string(app(opts)))
    File.mkdir_p!(path)
    path
  end

  @doc "Stores `value` under `key`."
  @spec put(key, term, keyword) :: :ok | {:error, :not_storable | File.posix()}
  def put(key, value, opts \\ []) do
    path = path(key, opts)

    with {:ok, text} <- encode(value),
         tmp = path <> ".tmp",
         :ok <- write_synced(tmp, text) do
      if File.exists?(path), do: File.rename(path, path <> ".bak")

      with :ok <- File.rename(tmp, path) do
        sync()
        :ok
      end
    end
  end

  @doc "The value stored under `key`, or `default`."
  @spec get(key, term, keyword) :: term
  def get(key, default \\ nil, opts \\ []) do
    path = path(key, opts)

    with :error <- read(path), :error <- read(path <> ".bak") do
      default
    else
      {:ok, value} -> value
    end
  end

  @doc "Removes `key`."
  @spec delete(key, keyword) :: :ok
  def delete(key, opts \\ []) do
    path = path(key, opts)
    for p <- [path, path <> ".bak", path <> ".tmp"], do: File.rm(p)
    sync()
    :ok
  end

  @doc "The keys stored, as strings."
  @spec keys(keyword) :: [String.t()]
  def keys(opts \\ []) do
    dir(opts)
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      case Path.extname(name) do
        ".term" -> [Path.rootname(name)]
        ".bak" -> [name |> Path.rootname() |> Path.rootname()]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # --- encoding: one term, written as text, with a crc32 of that text

  @doc false
  def encode(value) do
    text = IO.chardata_to_string(:io_lib.format(~c"~tp.~n", [value]))

    case decode_term(text) do
      {:ok, ^value} -> {:ok, [@header, Integer.to_string(:erlang.crc32(text)), "\n", text]}
      _ -> {:error, :not_storable}
    end
  end

  @doc false
  def decode(<<@header, rest::binary>>) do
    with [crc, text] <- String.split(rest, "\n", parts: 2),
         {crc, ""} <- Integer.parse(crc),
         true <- crc == :erlang.crc32(text) do
      decode_term(text)
    else
      _ -> :error
    end
  end

  def decode(_), do: :error

  defp decode_term(text) do
    with {:ok, tokens, _} <- :erl_scan.string(String.to_charlist(text)),
         {:ok, term} <- :erl_parse.parse_term(tokens) do
      {:ok, term}
    else
      _ -> :error
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bin} -> decode(bin)
      _ -> :error
    end
  end

  defp write_synced(path, data) do
    with {:ok, fd} <- :file.open(path, [:write, :raw, :binary]) do
      result =
        with :ok <- :file.write(fd, data),
             do: :file.sync(fd)

      :file.close(fd)
      result
    end
  end

  # The renames are only durable once the file system has written them out.
  defp sync do
    if Application.get_env(:nest_gen2, :storage_sync, true), do: System.cmd("sync", [])
    :ok
  end

  defp path(key, opts), do: Path.join(dir(opts), file_name(key) <> ".term")

  defp file_name(key) when is_atom(key), do: file_name(Atom.to_string(key))

  defp file_name(key) when is_binary(key) do
    if key =~ ~r/\A[a-z0-9_]{1,64}\z/,
      do: key,
      else:
        raise(ArgumentError, "storage keys are lowercase letters, digits and _: #{inspect(key)}")
  end

  defp app(opts) do
    case Keyword.get_lazy(opts, :app, fn -> :application.get_application() end) do
      {:ok, app} -> app
      app when is_atom(app) and app not in [nil, :undefined] -> app
      _ -> raise ArgumentError, "can't tell which app is calling; pass app: :my_app"
    end
  end

  defp base_dir,
    do: Application.get_env(:nest_gen2, :storage_dir) || default_dir()

  defp default_dir do
    if NestGen2.Config.host?(),
      do: NestGen2.Config.host_dir("data"),
      else: "/media/scratch/.nest_gen2_sdk/data"
  end
end

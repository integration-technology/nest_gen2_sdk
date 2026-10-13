defmodule NestGen2.StorageTest do
  use ExUnit.Case, async: false
  alias NestGen2.Storage

  setup do
    dir = Path.join(System.tmp_dir!(), "nest_gen2_storage_#{System.unique_integer([:positive])}")
    Application.put_env(:nest_gen2, :storage_dir, dir)
    Application.put_env(:nest_gen2, :storage_sync, false)

    on_exit(fn ->
      Application.delete_env(:nest_gen2, :storage_dir)
      Application.delete_env(:nest_gen2, :storage_sync)
      File.rm_rf(dir)
    end)

    {:ok, app_dir: Path.join(dir, "demo")}
  end

  @opts [app: :demo]

  test "put, get, keys, delete" do
    assert Storage.get(:screen, :none, @opts) == :none
    value = %{idle_timeout_ms: 30_000, wake: [:motion, :button], name: "Café", t: {1, 2.5}}
    assert Storage.put(:screen, value, @opts) == :ok
    assert Storage.get(:screen, :none, @opts) == value
    assert Storage.put("stops", [{:a, "123", "To A"}], @opts) == :ok
    assert Storage.keys(@opts) == ["screen", "stops"]
    assert Storage.delete(:screen, @opts) == :ok
    assert Storage.get(:screen, :none, @opts) == :none
    assert Storage.keys(@opts) == ["stops"]
  end

  test "the file is readable text", %{app_dir: dir} do
    Storage.put(:screen, %{idle_timeout_ms: :infinity}, @opts)
    text = File.read!(Path.join(dir, "screen.term"))
    assert text =~ "%% nest_gen2 storage v1 crc32="
    assert text =~ "idle_timeout_ms => infinity"
  end

  test "apps don't see each other's keys" do
    Storage.put(:screen, 1, app: :one)
    assert Storage.get(:screen, :none, app: :two) == :none
    assert Storage.dir(app: :one) != Storage.dir(app: :two)
  end

  test "a value cut off mid-write falls back to the previous one", %{app_dir: dir} do
    Storage.put(:screen, :first, @opts)
    Storage.put(:screen, :second, @opts)
    path = Path.join(dir, "screen.term")
    full = File.read!(path)
    File.write!(path, binary_part(full, 0, div(byte_size(full), 2)))
    assert Storage.get(:screen, :none, @opts) == :first
  end

  test "power lost between keeping the backup and the rename", %{app_dir: dir} do
    Storage.put(:screen, :first, @opts)
    path = Path.join(dir, "screen.term")
    File.rename!(path, path <> ".bak")
    File.write!(path <> ".tmp", "%% nest_gen2 storage v1 crc32=1\nhalf")
    assert Storage.get(:screen, :none, @opts) == :first
    assert Storage.keys(@opts) == ["screen"]
  end

  test "a corrupt file with no backup gives the default", %{app_dir: dir} do
    Storage.put(:screen, :first, @opts)
    File.write!(Path.join(dir, "screen.term"), "garbage")
    assert Storage.get(:screen, :default, @opts) == :default
  end

  test "values that can't be written as text are refused" do
    assert Storage.put(:pid, self(), @opts) == {:error, :not_storable}
    assert Storage.put(:fun, fn -> 1 end, @opts) == {:error, :not_storable}
  end

  test "keys are checked" do
    assert_raise ArgumentError, fn -> Storage.put("../escape", 1, @opts) end
    assert_raise ArgumentError, fn -> Storage.put(:"Has Spaces", 1, @opts) end
  end

  test "an app name is required outside an application" do
    assert_raise ArgumentError, fn -> Storage.put(:x, 1) end
  end
end

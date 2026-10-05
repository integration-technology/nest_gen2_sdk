defmodule NestGen2.TraceTest do
  use ExUnit.Case, async: false
  alias NestGen2.Trace

  setup do
    dir = Path.join(System.tmp_dir!(), "nest_gen2_trace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "trace")
    Application.put_env(:nest_gen2, :trace_file, path)
    Application.put_env(:nest_gen2, :trace_max_bytes, 200)

    on_exit(fn ->
      Application.delete_env(:nest_gen2, :trace_file)
      Application.delete_env(:nest_gen2, :trace_max_bytes)
      File.rm_rf(dir)
    end)

    {:ok, path: path}
  end

  test "the trace never holds much more than the cap", %{path: path} do
    for i <- 1..100, do: Trace.write("rx 000a #{i}")
    assert File.stat!(path).size < 200 + 40
    assert File.stat!(path <> ".1").size >= 200
    assert File.read!(path) =~ "rx 000a 100"
  end

  test "off unless a trace file is set", %{path: path} do
    Application.delete_env(:nest_gen2, :trace_file)
    assert Trace.write("rx 000a 1") == :ok
    refute File.exists?(path)
  end
end

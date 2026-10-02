defmodule NestGen2.ConfigTest do
  use ExUnit.Case, async: false
  alias NestGen2.Config

  test "defaults match the stock Nest and our calibration" do
    assert Config.get(:dial_counts_per_turn) == 7800
    assert Config.get(:idle_timeout_ms) == 30_000
    assert Config.get(:temperature_offset_c) == -3.7
    assert Config.get(:fade_rise_ms) == 260
  end

  test "application env overrides a default" do
    Application.put_env(:nest_gen2, :idle_timeout_ms, 5000)
    on_exit(fn -> Application.delete_env(:nest_gen2, :idle_timeout_ms) end)
    assert Config.get(:idle_timeout_ms) == 5000
  end
end

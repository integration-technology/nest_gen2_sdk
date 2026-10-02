defmodule NestGen2.LightTest do
  use ExUnit.Case, async: true
  alias NestGen2.Light
  alias NestGen2.Backplate.Decode

  @opts [flicker_pct: 6, jump_pct: 40, min_delta: 200]

  # Light readings from traces on 2026-10-01, one a second, newest first.
  defp changed?(oldest_first), do: Light.changed?(Enum.reverse(oldest_first), @opts)

  test "decodes the light level from 0x000a" do
    assert Decode.decode(0x000A, <<0x76, 0x4F, 0x2F, 0x00>>) == {:light, 0x4F76}
  end

  test "a hand waved near the thermostat makes the light flicker" do
    assert changed?([9016, 8239, 7315, 8148, 6559])
  end

  test "an empty room in steady daylight is no change" do
    refute changed?([11781, 11788, 11774, 11760, 11767])
  end

  test "clouds change the light steadily, without flicker" do
    refute changed?([9590, 8505, 7287, 6251, 5663])
    refute changed?([6874, 7140, 7413, 7854, 8463])
    refute changed?([10297, 10227, 10129, 9646, 8169])
  end

  test "a light switched on is a single big jump" do
    assert changed?([3374, 3380, 15904, 15900, 15910])
  end

  test "flicker in the dark below the minimum change is ignored" do
    refute changed?([150, 40, 160, 45, 150])
  end

  test "needs at least two samples" do
    refute Light.changed?([5000], @opts)
    refute Light.changed?([], @opts)
  end
end

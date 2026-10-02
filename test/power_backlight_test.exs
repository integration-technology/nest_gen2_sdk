defmodule NestGen2.PowerBacklightTest do
  use ExUnit.Case, async: true
  alias NestGen2.{Backlight, Power}

  describe "Power.idle?/4" do
    test "sleeps once the timeout has passed" do
      assert Power.idle?(true, 0, 30_000, 30_001)
      refute Power.idle?(true, 0, 30_000, 30_000)
    end

    test "never while already asleep, or with no timeout" do
      refute Power.idle?(false, 0, 30_000, 99_999)
      refute Power.idle?(true, 0, :infinity, 99_999_999)
    end
  end

  describe "Backlight.ramp_index/1" do
    test "maps fade times to the chip's nearest ramp rate" do
      # Rates: 1, 130, 260, 520, 1000, 2000, 4000, 8000 ms
      assert Backlight.ramp_index(260) == 2
      assert Backlight.ramp_index(2000) == 5
      assert Backlight.ramp_index(1) == 0
      assert Backlight.ramp_index(300) == 2
      assert Backlight.ramp_index(60_000) == 7
    end
  end
end

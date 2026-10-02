defmodule NestGen2.DialTest do
  use ExUnit.Case, async: true
  alias NestGen2.Dial

  # 7800 counts per turn; the sensor reports clockwise as negative counts.

  test "a full clockwise turn is +360 degrees" do
    {angle, delta, _} = Dial.rotate(0.0, -7800, 7800, nil)
    assert_in_delta angle, 360.0, 1.0e-9
    assert_in_delta delta, 360.0, 1.0e-9
  end

  test "anticlockwise is negative" do
    {angle, _, _} = Dial.rotate(90.0, 1950, 7800, nil)
    assert_in_delta angle, 0.0, 1.0e-9
  end

  test "crossing a step boundary reports its direction" do
    assert {_, _, :cw} = Dial.rotate(8.0, -100, 7800, 10)
    assert {_, _, :ccw} = Dial.rotate(11.0, 100, 7800, 10)
  end

  test "moving within a step reports no step" do
    assert {_, _, nil} = Dial.rotate(1.0, -100, 7800, 10)
  end

  test "crossing zero going anticlockwise is a step" do
    assert {_, _, :ccw} = Dial.rotate(1.0, 100, 7800, 10)
  end

  test "no steps when stepping is off" do
    assert {_, _, nil} = Dial.rotate(8.0, -1000, 7800, nil)
  end
end

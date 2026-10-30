defmodule SdkTestTest do
  use ExUnit.Case, async: true

  test "a repeated event counts up instead of filling the log" do
    t = ~T[10:00:00]
    log = [] |> SdkTest.add_line("dial right", t) |> SdkTest.add_line("dial right", t)
    assert [{"dial right", 2, ^t}] = log
    assert [{"press", 1, _}, {"dial right", 2, _}] = SdkTest.add_line(log, "press", t)
  end

  test "the log keeps the newest seven lines" do
    log = Enum.reduce(1..10, [], &SdkTest.add_line(&2, "e#{&1}", ~T[10:00:00]))
    assert length(log) == 7
    assert {"e10", 1, _} = hd(log)
  end

  test "the menu wraps both ways" do
    assert SdkTest.step_menu(0, :ccw) == 4
    assert SdkTest.step_menu(4, :cw) == 0
  end
end

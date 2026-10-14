defmodule NestGen2.GestureTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:nest_gen2, :button_double_click_ms, 80)
    Application.put_env(:nest_gen2, :button_long_press_ms, 200)

    on_exit(fn ->
      Application.delete_env(:nest_gen2, :button_double_click_ms)
      Application.delete_env(:nest_gen2, :button_long_press_ms)
    end)

    start_supervised!({Registry, keys: :duplicate, name: NestGen2.Registry})
    start_supervised!(NestGen2.Gesture)
    NestGen2.subscribe(:gesture)
    :ok
  end

  defp press(ms \\ 20) do
    NestGen2.publish(:button, :down)
    Process.sleep(ms)
    NestGen2.publish(:button, :up)
  end

  test "a single press is a click, once the double-click window has passed" do
    press()
    refute_receive {:nest_gen2, :gesture, _}, 50
    assert_receive {:nest_gen2, :gesture, :click}, 100
    refute_receive {:nest_gen2, :gesture, _}, 150
  end

  test "two presses inside the window are one double click" do
    press()
    Process.sleep(30)
    press()
    assert_receive {:nest_gen2, :gesture, :double_click}, 50
    refute_receive {:nest_gen2, :gesture, _}, 250
  end

  test "two presses further apart are two clicks" do
    press()
    Process.sleep(150)
    press()
    assert_receive {:nest_gen2, :gesture, :click}, 50
    assert_receive {:nest_gen2, :gesture, :click}, 200
    refute_receive {:nest_gen2, :gesture, :double_click}, 50
  end

  test "holding is a long press, sent before the release, and nothing after it" do
    NestGen2.publish(:button, :down)
    assert_receive {:nest_gen2, :gesture, :long_press}, 300
    NestGen2.publish(:button, :up)
    refute_receive {:nest_gen2, :gesture, _}, 200
  end

  test "a short press then a long hold: the long hold doesn't count" do
    press()
    Process.sleep(30)
    NestGen2.publish(:button, :down)
    Process.sleep(250)
    NestGen2.publish(:button, :up)
    assert_receive {:nest_gen2, :gesture, :double_click}, 50
    refute_receive {:nest_gen2, :gesture, :long_press}, 50
  end

  test "with double clicks off, a click comes straight away" do
    Application.put_env(:nest_gen2, :button_double_click_ms, nil)
    press()
    assert_receive {:nest_gen2, :gesture, :click}, 20
  end

  test "a release without a press is ignored" do
    NestGen2.publish(:button, :up)
    refute_receive {:nest_gen2, :gesture, _}, 150
  end
end

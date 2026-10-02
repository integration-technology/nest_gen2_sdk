defmodule NestGen2.Display.FrameTest do
  use ExUnit.Case, async: true
  alias NestGen2.Image
  alias NestGen2.Display.Frame

  @black {0, 0, 0}
  @red {255, 0, 0}

  test "put draws the image and returns its rectangle" do
    {frame, rect} = Frame.put(Frame.new(@black), 10, 20, Image.new(3, 2, @red))
    assert rect == {10, 20, 3, 2}
    red = Image.pixel(@red)
    assert binary_part(elem(frame, 20), 10 * 4, 12) == red <> red <> red
    assert binary_part(elem(frame, 20), 9 * 4, 4) == Image.pixel(@black)
    assert binary_part(elem(frame, 22), 10 * 4, 4) == Image.pixel(@black)
    assert byte_size(elem(frame, 20)) == 320 * 4
  end

  test "put clips to the screen" do
    {_, rect} = Frame.put(Frame.new(@black), -2, 318, Image.new(5, 5, @red))
    assert rect == {0, 318, 3, 2}
    assert {_, nil} = Frame.put(Frame.new(@black), 400, 0, Image.new(5, 5, @red))
  end

  test "patches cover a rectangle at page-relative offsets" do
    {frame, rect} = Frame.put(Frame.new(@black), 1, 1, Image.new(2, 2, @red))
    base = 320 * 320 * 4
    assert [{off1, px1}, {off2, _}] = Frame.patches(frame, rect, base)
    assert off1 == base + (1 * 320 + 1) * 4
    assert off2 == base + (2 * 320 + 1) * 4
    assert px1 == Image.pixel(@red) <> Image.pixel(@red)
  end

  test "bounding box of rectangles" do
    assert Frame.bounding([{10, 10, 5, 5}, {0, 12, 2, 20}]) == {0, 10, 15, 22}
  end

  test "round-trips a full binary" do
    bin = :crypto.strong_rand_bytes(320 * 320 * 4)
    assert bin |> Frame.from_binary() |> Frame.to_binary() == bin
  end
end

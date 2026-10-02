defmodule NestGen2.ImageTest do
  use ExUnit.Case, async: true
  alias NestGen2.Image

  test "pixels are stored BGRX" do
    assert Image.pixel({0x43, 0x5F, 0xA6}) == <<0xA6, 0x5F, 0x43, 0>>
  end

  test "new fills every pixel with the colour" do
    img = Image.new(3, 2, {255, 0, 0})
    assert {img.width, img.height, byte_size(img.data)} == {3, 2, 24}
    assert img.data == :binary.copy(<<0, 0, 255, 0>>, 6)
  end

  test "row returns one row's bytes" do
    img = Image.from_raw(2, 2, <<1::32, 2::32, 3::32, 4::32>>)
    assert Image.row(img, 1) == <<3::32, 4::32>>
  end

  test "from_raw rejects data of the wrong size" do
    assert_raise FunctionClauseError, fn -> Image.from_raw(2, 2, <<0, 0, 0>>) end
  end

  test "rgb builds a colour tuple" do
    assert Image.rgb(1, 2, 3) == {1, 2, 3}
  end

  describe "color/1" do
    test "accepts hex with or without #, any case" do
      assert Image.color("#1C1C1E") == {28, 28, 30}
      assert Image.color("e87a1e") == {232, 122, 30}
    end

    test "passes tuples through" do
      assert Image.color({1, 2, 3}) == {1, 2, 3}
    end

    test "rejects anything else" do
      assert_raise FunctionClauseError, fn -> Image.color("#12345") end
      assert_raise FunctionClauseError, fn -> Image.color({300, 0, 0}) end
    end
  end

  test "new and pixel take hex colours" do
    assert Image.new(1, 1, "#435FA6").data == <<0xA6, 0x5F, 0x43, 0>>
  end

  test "a hex background fills the whole frame" do
    frame = NestGen2.Display.Frame.new(Image.color("#1C1C1E"))
    rows = Tuple.to_list(frame)
    assert length(rows) == 320
    assert Enum.all?(rows, &(&1 == :binary.copy(<<30, 28, 28, 0>>, 320)))
  end
end

defmodule NestGen2.HostTest do
  # Host mode (target: :host): no hardware, input simulated, screen in memory.
  use ExUnit.Case, async: false
  alias NestGen2.{Dial, Display, Image}
  alias NestGen2.Host.Viewer

  setup do
    Application.put_env(:nest_gen2, :target, :host)
    on_exit(fn -> Application.delete_env(:nest_gen2, :target) end)
    start_supervised!({Registry, keys: :duplicate, name: NestGen2.Registry})
    :ok
  end

  describe "the dial" do
    setup do
      start_supervised!(NestGen2.Piezo)
      start_supervised!(Dial)
      NestGen2.subscribe([:dial_step, :button])
      :ok
    end

    test "a simulated turn gives a step for every boundary it crosses" do
      Dial.turn(25)
      assert_receive {:nest_gen2, :dial_step, %{direction: :cw}}
      assert_receive {:nest_gen2, :dial_step, %{direction: :cw}}
      refute_receive {:nest_gen2, :dial_step, _}, 50
      assert_in_delta Dial.angle(), 25.0, 0.01
    end

    test "turning back steps the other way" do
      Dial.turn(-10)
      assert_receive {:nest_gen2, :dial_step, %{direction: :ccw}}
      assert_in_delta Dial.angle(), -10.0, 0.01
    end

    test "a simulated press gives the button events" do
      NestGen2.Host.click()
      assert_receive {:nest_gen2, :button, :down}
      assert_receive {:nest_gen2, :button, :up}
    end
  end

  test "the display keeps what was last presented, without a framebuffer" do
    start_supervised!(Display)
    Display.set_background("#FF0000")
    before = Display.snapshot()
    Display.present()
    shown = Display.snapshot()

    assert before.data != shown.data
    assert binary_part(shown.data, (160 * 320 + 160) * 4, 4) == Image.pixel({255, 0, 0})
    assert binary_part(shown.data, 0, 4) == Image.pixel({0, 0, 0})
  end

  test "to_png writes a valid PNG with the image's pixels" do
    png = Image.to_png(Image.new(2, 1, {10, 20, 30}))
    assert <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 2::32, 1::32, 8, 2, _::binary>> = png
    # One row: filter byte 0, then RGB for each pixel.
    assert :zlib.uncompress(chunk(png, "IDAT")) == <<0, 10, 20, 30, 10, 20, 30>>
    assert String.ends_with?(png, <<0::32, "IEND", :erlang.crc32("IEND")::32>>)
  end

  test "the viewer refuses bad input and unknown paths" do
    assert {404, _, _} = Viewer.route("GET", "/nope", %{})
    assert_raise ArgumentError, fn -> Viewer.route("POST", "/turn", %{"deg" => "abc"}) end
  end

  defp chunk(png, type) do
    [before, after_type] = :binary.split(png, type)
    <<_::binary-size(byte_size(before) - 4), len::32>> = before
    binary_part(after_type, 0, len)
  end
end

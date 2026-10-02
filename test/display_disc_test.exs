defmodule NestGen2.Display.DiscTest do
  use ExUnit.Case, async: true
  alias NestGen2.Display.Frame

  @grey <<30, 28, 28, 0>>
  @black <<0, 0, 0, 0>>

  defp pixel(frame, x, y), do: binary_part(elem(frame, y), x * 4, 4)

  setup_all do
    {:ok, frame: Frame.disc({28, 28, 30})}
  end

  test "320 rows of 320 pixels", %{frame: frame} do
    assert tuple_size(frame) == 320
    assert Enum.all?(Tuple.to_list(frame), &(byte_size(&1) == 1280))
  end

  test "the colour fills the middle and the corners are black", %{frame: frame} do
    assert pixel(frame, 160, 160) == @grey
    assert pixel(frame, 160, 2) == @grey

    for {x, y} <- [{0, 0}, {319, 0}, {0, 319}, {319, 319}, {30, 30}, {289, 289}],
        do: assert(pixel(frame, x, y) == @black)
  end

  test "the colour reaches the edge of the circle on all four sides", %{frame: frame} do
    for {x, y} <- [{1, 160}, {318, 160}, {160, 1}, {160, 318}],
        do: assert(pixel(frame, x, y) == @grey)
  end

  test "the edge is smoothed, between black and the colour", %{frame: frame} do
    blended =
      for row <- Tuple.to_list(frame),
          <<px::binary-size(4) <- row>>,
          px not in [@grey, @black],
          do: px

    # A ring of part-covered pixels round the circle, nothing else.
    assert length(blended) in 300..1500
  end

  test "left and right halves mirror each other", %{frame: frame} do
    row = elem(frame, 100)
    pixels = for <<px::binary-size(4) <- row>>, do: px
    assert pixels == Enum.reverse(pixels)
  end
end

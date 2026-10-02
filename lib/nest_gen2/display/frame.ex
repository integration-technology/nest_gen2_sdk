defmodule NestGen2.Display.Frame do
  @moduledoc false
  # The screen's current content as a tuple of 320 row binaries (BGRX), so
  # drawing a box only rebuilds the rows it touches.

  alias NestGen2.Image

  @size 320
  @row_bytes @size * 4

  def size, do: @size

  def new(color),
    do: List.to_tuple(List.duplicate(:binary.copy(Image.pixel(color), @size), @size))

  @doc """
  A solid-colour disc filling the visible circle (centre 160,160, radius 160)
  with black outside it, as Nest draws its own screens. The bezel's round
  cut-out doesn't line up exactly with the square panel, so coloured corners
  would show as slivers at the edge; black ones don't. The edge is smoothed.
  """
  def disc(color) do
    {b, g, r, _} = color |> Image.pixel() |> then(fn <<b, g, r, x>> -> {b, g, r, x} end)
    black = <<0, 0, 0, 0>>

    for {outside, edge} <- disc_rows() do
      edge_px = for c <- edge, into: <<>>, do: <<round(b * c), round(g * c), round(r * c), 0>>
      inside = @size - 2 * (outside + length(edge))

      IO.iodata_to_binary([
        :binary.copy(black, outside),
        edge_px,
        :binary.copy(<<b, g, r, 0>>, inside),
        reverse_pixels(edge_px),
        :binary.copy(black, outside)
      ])
    end
    |> List.to_tuple()
  end

  # Per row: pixels fully outside the circle on each side, and the coverage
  # (0..1) of the edge pixels between that and the solid middle, left side
  # only (the right mirrors it). Computed once.
  defp disc_rows do
    case :persistent_term.get({__MODULE__, :disc_rows}, nil) do
      nil ->
        rows = for y <- 0..(@size - 1), do: disc_row(y)
        :persistent_term.put({__MODULE__, :disc_rows}, rows)
        rows

      rows ->
        rows
    end
  end

  @radius @size / 2
  defp disc_row(y) do
    coverage =
      for x <- 0..(div(@size, 2) - 1) do
        dist = :math.sqrt(:math.pow(x + 0.5 - @radius, 2) + :math.pow(y + 0.5 - @radius, 2))
        min(max(@radius - dist + 0.5, 0.0), 1.0)
      end

    outside = Enum.count(coverage, &(&1 == 0.0))
    edge = coverage |> Enum.drop(outside) |> Enum.take_while(&(&1 < 1.0))
    {outside, edge}
  end

  defp reverse_pixels(bin),
    do: for(<<px::binary-size(4) <- bin>>, do: px) |> Enum.reverse() |> IO.iodata_to_binary()

  def from_binary(bin) when byte_size(bin) == @size * @row_bytes,
    do: List.to_tuple(for y <- 0..(@size - 1), do: binary_part(bin, y * @row_bytes, @row_bytes))

  def from_image(%Image{width: @size, height: @size, data: data}), do: from_binary(data)

  @doc "Draws `image` with its top-left at (x, y), clipped to the screen. Returns {frame, rect | nil}."
  def put(frame, x, y, %Image{width: w, height: h} = image) do
    src_x = max(0, -x)
    src_y = max(0, -y)
    dst_x = max(0, x)
    dst_y = max(0, y)
    cw = min(w - src_x, @size - dst_x)
    ch = min(h - src_y, @size - dst_y)

    if cw <= 0 or ch <= 0 do
      {frame, nil}
    else
      frame =
        Enum.reduce(0..(ch - 1), frame, fn r, acc ->
          src = binary_part(Image.row(image, src_y + r), src_x * 4, cw * 4)
          row = elem(acc, dst_y + r)

          new_row =
            binary_part(row, 0, dst_x * 4) <>
              src <> binary_part(row, (dst_x + cw) * 4, @row_bytes - (dst_x + cw) * 4)

          put_elem(acc, dst_y + r, new_row)
        end)

      {frame, {dst_x, dst_y, cw, ch}}
    end
  end

  @doc "Page-relative {byte offset, pixels} patches covering a rectangle."
  def patches(frame, {x, y, w, h}, base) do
    for r <- y..(y + h - 1) do
      {base + (r * @size + x) * 4, binary_part(elem(frame, r), x * 4, w * 4)}
    end
  end

  def to_binary(frame), do: IO.iodata_to_binary(Tuple.to_list(frame))

  @doc "Smallest rectangle containing all the given rectangles."
  def bounding([{x, y, w, h} | rest]) do
    Enum.reduce(rest, {x, y, x + w, y + h}, fn {rx, ry, rw, rh}, {x0, y0, x1, y1} ->
      {min(x0, rx), min(y0, ry), max(x1, rx + rw), max(y1, ry + rh)}
    end)
    |> then(fn {x0, y0, x1, y1} -> {x0, y0, x1 - x0, y1 - y0} end)
  end
end

defmodule NestGen2.Image do
  @moduledoc """
  A block of pixels in the framebuffer's own format: 4 bytes per pixel, BGRX.

  Colours can be given as a hex string (`"#1C1C1E"`, `"1c1c1e"`) or an
  `{red, green, blue}` tuple of 0..255, anywhere the SDK takes a colour.
  """

  @enforce_keys [:width, :height, :data]
  defstruct [:width, :height, :data]

  @type rgb :: {0..255, 0..255, 0..255}
  @type color :: rgb | String.t()
  @type t :: %__MODULE__{width: pos_integer, height: pos_integer, data: binary}

  @doc "Builds a colour tuple."
  @spec rgb(0..255, 0..255, 0..255) :: rgb
  def rgb(r, g, b), do: {r, g, b}

  @doc """
  Normalises a colour to an `{r, g, b}` tuple.

      iex> NestGen2.Image.color("#1C1C1E")
      {28, 28, 30}
  """
  @spec color(color) :: rgb
  def color({r, g, b} = rgb) when r in 0..255 and g in 0..255 and b in 0..255, do: rgb
  def color("#" <> hex), do: color(hex)

  def color(<<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>),
    do: {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}

  @doc "An image filled with one colour."
  @spec new(pos_integer, pos_integer, color) :: t
  def new(width, height, color) do
    %__MODULE__{width: width, height: height, data: :binary.copy(pixel(color), width * height)}
  end

  @doc "Wraps raw BGRX pixel data."
  @spec from_raw(pos_integer, pos_integer, binary) :: t
  def from_raw(width, height, data) when byte_size(data) == width * height * 4 do
    %__MODULE__{width: width, height: height, data: data}
  end

  @doc "Row `y` of the image as a binary."
  @spec row(t, non_neg_integer) :: binary
  def row(%__MODULE__{width: w, data: data}, y), do: binary_part(data, y * w * 4, w * 4)

  @doc false
  def pixel(color) do
    {r, g, b} = color(color)
    <<b, g, r, 0>>
  end
end

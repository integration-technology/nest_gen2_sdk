defmodule NestGen2.Display do
  @moduledoc """
  The 320×320 round screen, double-buffered.

  Drawing calls update a back buffer; `present/0` shows everything drawn since
  the last present in one page flip, so a partly drawn frame is never visible.

  The visible area is the circle inscribed in the square: centre `{160, 160}`,
  radius 160. Backgrounds can bleed to the edge; keep text and icons inside
  `safe_radius/0`, since the bezel covers the outermost few pixels.
  """
  use GenServer
  alias NestGen2.{Image, Text}
  alias NestGen2.Display.Frame

  @fb "/dev/fb0"
  @sysfs "/sys/class/graphics/fb0"
  @size 320
  @page_bytes @size * @size * 4
  @max_rects 16

  def width, do: @size
  def height, do: @size
  def center, do: {160, 160}
  def radius, do: 160
  def safe_radius, do: 145

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Replaces the whole screen with a 320×320 image or a solid colour, given as a
  hex string or `{r, g, b}` tuple:

      NestGen2.Display.set_background("#1C1C1E")

  A colour fills the visible circle (radius 160) and leaves the corners black,
  as Nest's own screens do, so no coloured slivers show where the bezel's
  cut-out meets the square panel. Images are drawn as given; make their
  corners black for the same reason.
  """
  @spec set_background(Image.t() | Image.color()) :: :ok
  def set_background(%Image{width: @size, height: @size} = image),
    do: GenServer.call(__MODULE__, {:background, Frame.from_image(image)})

  def set_background(color),
    do: GenServer.call(__MODULE__, {:background, Frame.disc(Image.color(color))})

  @doc "Draws an image with its top-left corner at (x, y)."
  @spec put_image(integer, integer, Image.t()) :: :ok
  def put_image(x, y, %Image{} = image), do: GenServer.call(__MODULE__, {:put, x, y, image})

  @spec fill_rect(integer, integer, pos_integer, pos_integer, Image.color()) :: :ok
  def fill_rect(x, y, w, h, color), do: put_image(x, y, Image.new(w, h, color))

  @doc """
  Draws text with its top edge at `y`. Takes `NestGen2.Text` options plus
  `:align` — `:left` (x is the left edge, default), `:center` or `:right`.
  """
  @spec put_text(integer, integer, String.t(), keyword) :: :ok | {:error, term}
  def put_text(x, y, text, opts \\ []) do
    with {:ok, %Image{width: w} = image} <- Text.render(text, opts) do
      left =
        case Keyword.get(opts, :align, :left) do
          :left -> x
          :center -> x - div(w, 2)
          :right -> x - w
        end

      put_image(left, y, image)
    end
  end

  @doc "Shows everything drawn since the last present, in one page flip."
  @spec present() :: :ok
  def present, do: GenServer.call(__MODULE__, :present)

  @impl true
  def init(nil) do
    # Our boots leave the virtual screen at 320x320; two pages need 320x640.
    File.write!(Path.join(@sysfs, "virtual_size"), "320,640")
    {:ok, fb} = :file.open(@fb, [:read, :write, :raw, :binary])
    visible = visible_page()
    # Start from what is on screen (e.g. the boot splash) so nothing flashes.
    {:ok, current} = :file.pread(fb, visible * @page_bytes, @page_bytes)
    NestGen2.subscribe(:power)
    schedule_refresh()

    {:ok,
     %{
       fb: fb,
       frame: Frame.from_binary(current),
       visible: visible,
       damage: %{visible => [], (1 - visible) => [:all]},
       awake: true
     }}
  end

  @impl true
  def handle_call({:background, frame}, _from, state),
    do: {:reply, :ok, damage(%{state | frame: frame}, :all)}

  def handle_call({:put, x, y, image}, _from, state) do
    case Frame.put(state.frame, x, y, image) do
      {_, nil} -> {:reply, :ok, state}
      {frame, rect} -> {:reply, :ok, damage(%{state | frame: frame}, rect)}
    end
  end

  def handle_call(:present, _from, state), do: {:reply, :ok, present(state)}

  @impl true
  def handle_info({:nest_gen2, :power, power}, state),
    do: {:noreply, %{state | awake: power == :awake}}

  # Periodic full redraw while awake, as insurance against lost screen content.
  def handle_info(:refresh, state) do
    schedule_refresh()
    {:noreply, if(state.awake, do: present(damage(state, :all)), else: state)}
  end

  defp damage(%{damage: d} = state, region) do
    add = fn
      list when region == :all -> [:all | list]
      list -> [region | list]
    end

    %{state | damage: %{0 => add.(d[0]), 1 => add.(d[1])}}
  end

  defp present(%{fb: fb, visible: visible, damage: d, frame: frame} = state) do
    hidden = 1 - visible
    base = hidden * @page_bytes

    case d[hidden] do
      [] ->
        :ok

      regions ->
        if :all in regions do
          write_chunks(fb, base, Frame.to_binary(frame))
        else
          rects = if length(regions) > @max_rects, do: [Frame.bounding(regions)], else: regions
          :ok = :file.pwrite(fb, Enum.flat_map(rects, &Frame.patches(frame, &1, base)))
        end
    end

    File.write!(Path.join(@sysfs, "pan"), "0,#{hidden * @size}")
    %{state | visible: hidden, damage: %{d | hidden => []}}
  end

  # Full-page writes must be chunked to <=4KB on this omapfb driver.
  defp write_chunks(_fb, _off, <<>>), do: :ok

  defp write_chunks(fb, off, data) do
    n = min(4096, byte_size(data))
    <<chunk::binary-size(n), rest::binary>> = data
    :ok = :file.pwrite(fb, off, chunk)
    write_chunks(fb, off + n, rest)
  end

  defp visible_page do
    [_, y] = File.read!(Path.join(@sysfs, "pan")) |> String.trim() |> String.split(",")
    div(String.to_integer(y), @size)
  end

  defp schedule_refresh,
    do: Process.send_after(self(), :refresh, NestGen2.Config.get(:refresh_interval_ms))
end

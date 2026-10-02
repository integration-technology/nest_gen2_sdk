defmodule NestGen2.Text do
  @moduledoc """
  Text rendering from Nest's own Akkurat fonts, on the device.

  The `textrender` helper (stb_truetype) rasterises text from the device's
  `/nestlabs/share/fonts`, so no font data ships with the SDK (Akkurat is
  commercially licensed).

  Options:
    * `:font` — `:bold` (default), `:regular`, or a path to a TrueType file
    * `:size` — em size in pixels, default 36
    * `:color` — text colour (hex string or `{r, g, b}`), default white
    * `:background` — colour the text is smoothed onto, default black
  """
  use GenServer
  alias NestGen2.Image

  @fonts %{
    bold: "/nestlabs/share/fonts/AkkuratNest-Bold.ttf",
    regular: "/nestlabs/share/fonts/AkkuratNest-Regular.ttf"
  }
  @timeout 5000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Renders text to an image the exact size of the text."
  @spec render(String.t(), keyword) :: {:ok, Image.t()} | {:error, term}
  def render(text, opts \\ []), do: GenServer.call(__MODULE__, {:render, text, opts}, @timeout)

  @doc "Width and height the text would render at."
  @spec measure(String.t(), keyword) :: {:ok, {pos_integer, pos_integer}} | {:error, term}
  def measure(text, opts \\ []) do
    with {:ok, %Image{width: w, height: h}} <- render(text, opts), do: {:ok, {w, h}}
  end

  @impl true
  def init(nil), do: {:ok, open()}

  @impl true
  def handle_call({:render, text, opts}, _from, port) do
    Port.command(port, request(text, opts))

    receive do
      {^port, {:data, <<0, w::16, h::16, pixels::binary>>}} ->
        {:reply, {:ok, Image.from_raw(w, h, pixels)}, port}

      {^port, {:data, <<1, message::binary>>}} ->
        {:reply, {:error, message}, port}

      {^port, {:exit_status, _}} ->
        {:reply, {:error, :renderer_exited}, open()}
    after
      @timeout -> {:reply, {:error, :timeout}, port}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, port), do: {:noreply, open()}
  def handle_info(_, port), do: {:noreply, port}

  defp open do
    Port.open({:spawn_executable, NestGen2.Config.native("textrender")}, [
      {:packet, 4},
      :binary,
      :exit_status
    ])
  end

  defp request(text, opts) do
    font = Map.get(@fonts, Keyword.get(opts, :font, :bold), Keyword.get(opts, :font))
    {fr, fg, fb} = opts |> Keyword.get(:color, {255, 255, 255}) |> Image.color()
    {br, bg, bb} = opts |> Keyword.get(:background, {0, 0, 0}) |> Image.color()
    size = Keyword.get(opts, :size, 36)

    <<size::16, fr, fg, fb, br, bg, bb, byte_size(font)::16, font::binary, text::binary>>
  end
end

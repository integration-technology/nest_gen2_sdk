defmodule NestGen2.TextTest do
  # Runs the host's textrender (built by `mix nest_gen2.host`), with the fonts
  # in ~/.nest_gen2_sdk/fonts.
  use ExUnit.Case, async: false
  @moduletag :host_renderer
  alias NestGen2.{Image, Text}

  setup do
    Application.put_env(:nest_gen2, :target, :host)
    Application.put_env(:nest_gen2, :text_render_ms, 300)

    on_exit(fn ->
      Application.delete_env(:nest_gen2, :target)
      Application.delete_env(:nest_gen2, :text_render_ms)
    end)

    start_supervised!(Text)
    :ok
  end

  test "a render that takes too long closes that renderer and starts a fresh one" do
    # A renderer that never answers, opened by Text so it owns the port.
    stuck =
      :sys.replace_state(Text, fn _ ->
        Port.open({:spawn, "sleep 30"}, [{:packet, 4}, :binary])
      end)

    assert Text.render("slow") == {:error, :timeout}
    # Closed, so its late reply can't be taken for the next text's.
    assert Port.info(stuck) == nil
    assert {:ok, %Image{}} = Text.render("next")
  end
end

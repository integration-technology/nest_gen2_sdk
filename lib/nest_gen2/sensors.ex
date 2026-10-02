defmodule NestGen2.Motion do
  @moduledoc """
  The backplate's passive-infrared motion sensors (near and far).

  `:motion` events fire when the level reaches the threshold or either sensor
  flags a detection. Someone walking in is seen from about 4 m.
  """
  alias NestGen2.Backplate

  @doc "Latest motion level, 0 (nothing moving) to about 10."
  @spec level() :: non_neg_integer
  def level, do: Backplate.get(:motion_level)

  @doc "Level from which movement counts as motion (default 2)."
  @spec set_threshold(pos_integer) :: :ok
  def set_threshold(level) when is_integer(level) and level > 0,
    do: Backplate.put(:motion_threshold, level)
end

defmodule NestGen2.Climate do
  @moduledoc """
  Temperature and humidity from the backplate, every ~30 s.

  The raw temperature reads warm because the sensor sits next to the unit's own
  electronics; `temperature_c` has the offset applied (default -3.7 °C, measured
  on a desk stand against a reference probe). Calibrate with `set_offset/1`.
  """
  alias NestGen2.Backplate

  @spec read() :: %{
          temperature_c: float | nil,
          humidity_pct: float | nil,
          raw_temperature_c: float | nil,
          board_temperatures_c: [float]
        }
  def read do
    raw = Backplate.get(:raw_temperature_c)
    offset = Backplate.get(:temperature_offset_c)

    %{
      temperature_c: raw && Float.round(raw + offset, 2),
      humidity_pct: Backplate.get(:humidity_pct),
      raw_temperature_c: raw,
      board_temperatures_c: Backplate.get(:board_temperatures_c)
    }
  end

  @doc "Self-heating correction added to the raw temperature, in °C."
  @spec set_offset(number) :: :ok
  def set_offset(delta_c) when is_number(delta_c),
    do: Backplate.put(:temperature_offset_c, delta_c * 1.0)
end

defmodule NestGen2.Battery do
  @moduledoc "The head unit's battery voltage, as reported by the backplate."

  @spec millivolts() :: non_neg_integer | nil
  def millivolts, do: NestGen2.Backplate.get(:battery_mv)
end

defmodule NestGen2.Light do
  @moduledoc """
  The backplate's ambient light sensor (raw counts, once a second).

  Someone moving near the thermostat makes the light flicker: within a few
  seconds it both drops and rises as their shadow passes. Clouds change the
  light just as much, but steadily in one direction. A flicker, or a sudden
  jump such as a light being switched on, is published as a `:light` event
  `%{level: counts}`.

  `:light` is one of the default wake sources, because the backplate's motion
  sensors can stop reporting for minutes after a long quiet spell.

  Over the last 5 samples, it counts when:

    * the light both fell and rose by `:light_wake_flicker_pct` percent or more
      from one second to the next (default 6), or
    * it changed by `:light_wake_jump_pct` percent or more in one second
      (default 40).

  Changes smaller than `:light_wake_min_delta` counts (default 200) are
  ignored, so noise in the dark doesn't count.
  """

  @doc "Latest raw light level, or nil before the first reading."
  @spec level() :: non_neg_integer | nil
  def level, do: NestGen2.Backplate.get(:light)

  @doc false
  # Whether recent samples (newest first) look like someone moving nearby or a
  # light switched on, as opposed to steady daylight or passing clouds.
  def changed?(window, opts) do
    steps = steps(Enum.reverse(window), opts[:min_delta])
    flicker = opts[:flicker_pct]

    (Enum.any?(steps, &(&1 <= -flicker)) and Enum.any?(steps, &(&1 >= flicker))) or
      Enum.any?(steps, &(abs(&1) >= opts[:jump_pct]))
  end

  # Percentage change from each sample to the next (oldest first); changes
  # below min_delta counts are treated as no change.
  defp steps(samples, min_delta) do
    samples
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] ->
      if abs(b - a) >= min_delta, do: (b - a) * 100 / max(a, 1), else: 0
    end)
  end
end

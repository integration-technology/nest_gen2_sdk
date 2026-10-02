defmodule NestGen2.Config do
  @moduledoc false

  @defaults [
    idle_timeout_ms: 30_000,
    wake_sources: [:dial, :button, :motion, :light],
    motion_threshold: 2,
    light_wake_flicker_pct: 6,
    light_wake_jump_pct: 40,
    light_wake_min_delta: 200,
    dial_counts_per_turn: 7800,
    dial_step_degrees: 10,
    click_on_step: true,
    temperature_offset_c: -3.7,
    backlight_level: 113,
    fade_rise_ms: 260,
    fade_fall_ms: 2000,
    refresh_interval_ms: 10_000,
    time_servers: ["time.nest.com", "pool.ntp.org", :gateway],
    clock_sync_interval_ms: 3_600_000,
    clock_step_ms: 500
  ]

  def get(key), do: Application.get_env(:nest_gen2, key, Keyword.fetch!(@defaults, key))

  @doc "Absolute path of a native helper shipped in priv/."
  def native(name), do: Application.app_dir(:nest_gen2, ["priv", name])
end

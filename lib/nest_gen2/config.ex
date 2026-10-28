defmodule NestGen2.Config do
  @moduledoc false

  @defaults [
    target: :nest,
    host_viewer: true,
    host_viewer_port: 4000,
    host_viewer_ip: {127, 0, 0, 1},
    host_viewer_controls: true,
    host_climate: {20.0, 45.0},
    idle_timeout_ms: 30_000,
    wake_sources: [:dial, :button, :motion, :light],
    motion_threshold: 2,
    light_wake_flicker_pct: 6,
    light_wake_jump_pct: 40,
    light_wake_min_delta: 200,
    dial_counts_per_turn: 7800,
    dial_step_degrees: 10,
    click_on_step: true,
    button_double_click_ms: 300,
    deep_sleep: false,
    deep_sleep_after_ms: 10_000,
    deep_sleep_max_s: 270,
    deep_sleep_awake_ms: 8_000,
    power_state_path: "/sys/power/state",
    wakeup_count_path: "/sys/power/wakeup_count",
    rtc_wakealarm_path: "/sys/class/rtc/rtc0/wakealarm",
    backplate_wakeup_path: "/sys/devices/platform/omap/omap_uart.2/power/wakeup",
    button_long_press_ms: 800,
    temperature_offset_c: -3.7,
    backlight_level: 113,
    fade_rise_ms: 260,
    fade_fall_ms: 2000,
    refresh_interval_ms: 10_000,
    time_servers: ["time.nest.com", "pool.ntp.org", :gateway],
    clock_sync_interval_ms: 3_600_000,
    clock_step_ms: 500,
    wifi_interface: "wlan0",
    wifi_ctrl_dir: "/var/run/wpa_supplicant",
    wifi_dhcp_log: "/tmp/nest_gen2_dhcp.log",
    wifi_dhcp_pidfile: "/var/run/udhcpc.pid",
    wifi_associate_ms: 30_000,
    wifi_dhcp_ms: 25_000
  ]

  def get(key), do: Application.get_env(:nest_gen2, key, Keyword.fetch!(@defaults, key))

  @doc "Whether the SDK runs on a computer instead of a Nest (`target: :host`)."
  def host?, do: get(:target) == :host

  @doc """
  Absolute path of a native helper: shipped in priv/ for the Nest, or built for
  this computer by `mix nest_gen2.host` when running on the host.
  """
  def native(name) do
    if host?(),
      do: Path.join(host_dir("bin"), name),
      else: Application.app_dir(:nest_gen2, ["priv", name])
  end

  @doc "Where the Nest's fonts are: the device's own, or a copy on the host."
  def font_dir do
    Application.get_env(:nest_gen2, :font_dir) ||
      if host?(), do: host_dir("fonts"), else: "/nestlabs/share/fonts"
  end

  @doc "A directory under ~/.nest_gen2_sdk on the host (bin, fonts, data)."
  def host_dir(name), do: Path.join([System.user_home!(), ".nest_gen2_sdk", name])
end

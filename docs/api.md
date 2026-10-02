# nest_gen2_sdk — public Elixir API (draft)

The SDK turns a rooted Nest Learning Thermostat (2nd gen, "Diamond" board) into a
small Elixir device: a 320×320 round screen, a rotating ring with a press, a
piezo, motion sensors and a climate sensor. Apps depend on the hex package
`nest_gen2_sdk` and use only the functions below. Anything not listed is internal
and may change.

Reference app: **foxbus** (fox logo, dial, temperature; grows into the bus display).

## Layers

| Layer | Contents | Ships as |
|---|---|---|
| Platform | Rooting, cross-compiled OTP/Elixir, install folder `/media/scratch/.nest_gen2_sdk` (leading dot survives Nest's `cleanup_scratch`), `rcS` boot hook, stock stack disabled, watchdog | Separate repo + install script |
| Native helpers | `evwatch` (input events), `bplink` (backplate UART) | Pre-built ARM binaries in `priv/` |
| SDK | The modules below | hex package `nest_gen2_sdk` |
| Apps | foxbus, others | Their own Mix projects |

**Rule:** the SDK provides mechanisms with sensible defaults; apps decide policy.
The one exception is the backplate keep-alive, which always runs: without it the
stand power-cycles the head unit about 36 minutes after it last heard from it.

## Starting and events

The SDK is an OTP application; adding the dependency starts its supervision tree
(backplate link, display, dial, piezo, power, climate).

```elixir
NestGen2.subscribe(topic_or_topics) :: :ok
NestGen2.unsubscribe(topic_or_topics) :: :ok
```

Subscribers receive `{:nest_gen2, topic, payload}`:

| Topic | Payload | From |
|---|---|---|
| `:dial` | `%{delta: degrees, angle: degrees}` | Head unit ring sensor |
| `:dial_step` | `%{direction: :cw \| :ccw, angle: degrees}` (every `step_degrees`) | Head unit |
| `:light` | `%{level: counts}` (light flickering as someone moves nearby, or switched on; a default wake source, since the motion sensors can go quiet for minutes) | Backplate light sensor |
| `:button` | `:down \| :up` | Head unit (power chip button) |
| `:motion` | `%{level: 0..10, near: boolean, far: boolean}` | Backplate PIRs |
| `:climate` | `%{temperature_c: float, humidity_pct: float}` (corrected) | Backplate |
| `:battery` | `%{millivolts: integer}` | Backplate |
| `:power` | `:awake \| :asleep` | SDK power policy |

## Head unit

### NestGen2.Display — double-buffered screen

Drawing is batched: calls update the back buffer; `present/0` shows the batch in
one page flip, so partial frames are never visible.

```elixir
width() :: 320
height() :: 320
center() :: {160, 160}
radius() :: 160                          # visible circle
safe_radius() :: 145                     # keep text and icons inside this

set_background(image) :: :ok             # 320×320 base layer, used by full redraws
set_background("#1C1C1E") :: :ok        # a colour fills the visible disc, corners black
put_image(x, y, image) :: :ok            # draw a rectangle into the back buffer
fill_rect(x, y, w, h, color) :: :ok
put_text(x, y, text, opts) :: :ok        # opts: font, size, color, align
present() :: :ok                         # flip: show everything drawn since the last present
```

### NestGen2.Image and NestGen2.Text — pixels and fonts

```elixir
NestGen2.Image.new(width, height, color) :: image
NestGen2.Image.from_raw(width, height, bgrx_binary) :: image
NestGen2.Image.from_png(path_or_binary) :: {:ok, image} | {:error, term}
NestGen2.Image.rgb(r, g, b) :: color

NestGen2.Text.render(text, opts) :: image     # opts: font (:regular | :bold), size, color, background
NestGen2.Text.measure(text, opts) :: {width, height}
```

Fonts are Nest's own Akkurat, rendered at runtime by the `textrender` helper
(stb_truetype) from the device's `/nestlabs/share/fonts`; the package never ships
font files or anything rendered from them (commercial licence).

### NestGen2.Backlight

```elixir
set(level) :: :ok                        # 0..120; the stock UI uses 113
level() :: integer
set_fade(rise_ms, fall_ms) :: :ok        # LM3530 hardware ramp; stock 260 / 2000
```

The SDK re-writes the level every second (the panel goes dark ~60 s after the last
write), so apps set it once.

### NestGen2.Dial — ring and press

```elixir
angle() :: float                         # degrees since start or last reset
reset_angle() :: :ok
set_step(degrees | nil) :: :ok           # :dial_step events every N degrees (default 10)
set_counts_per_turn(counts) :: :ok       # calibration, default 7800 (ADBS-A350 at 750 cpi)
```

Holding the press for several seconds triggers the power chip's hardware reset;
apps must not ask users for a long press.

### NestGen2.Piezo

```elixir
tone(hz, duration_ms) :: :ok
click() :: :ok                           # Nest's click: 2000 Hz for 3 ms
set_click_on_step(boolean) :: :ok        # click on every :dial_step (default true)
```

### NestGen2.Power — screen wake and sleep

```elixir
wake() :: :ok
sleep() :: :ok                           # off now, even with holds
awake?() :: boolean
keep_awake(reason \\ nil) :: {:ok, hold} # wake, and no idle sleep until released
release(hold) :: :ok                     # also automatic if the holder exits
holds() :: [%{ref, reason, owner}]
set_idle_timeout(ms | :infinity) :: :ok  # default 30_000
set_wake_sources([:dial | :button | :motion | :light]) :: :ok   # default all four
```

Holds stack: idle sleep resumes once the last one is released, with a fresh
idle timeout. Use them for anything that must stay visible, such as an alarm
or a settings screen.

## Backplate

### NestGen2.Motion

```elixir
level() :: 0..10
set_threshold(level) :: :ok              # level counted as motion, default 2
```

### NestGen2.Climate

```elixir
read() :: %{temperature_c: float, humidity_pct: float,
            raw_temperature_c: float, board_temperatures_c: [float]}
set_offset(delta_c) :: :ok               # self-heating correction, default -3.7
```

### NestGen2.Battery

```elixir
millivolts() :: integer | nil
```

### NestGen2.Backplate — advanced, unstable

For decoding messages the SDK does not yet cover. May change between minor versions.

```elixir
status() :: %{connected: boolean, frames_received: integer, last_frame_at: DateTime.t()}
subscribe_raw() :: :ok                   # {:nest_gen2_backplate, cmd, payload}
send_raw(cmd, payload) :: :ok
```

## Wi-Fi

`NestGen2.Wifi` manages the connection through `wpa_supplicant`, which the
platform runs in place of Nest's connection manager (`platform/wifi`). It's
`:unavailable` if that isn't running.

```elixir
NestGen2.Wifi.status() :: %{state: :connected | :connecting | :disconnected | :unavailable,
                            ssid: String.t() | nil, ip: String.t() | nil, signal_dbm: integer | nil}
NestGen2.Wifi.scan() :: {:ok, [%{ssid, signal_dbm, secured, saved}]} | {:error, term}   # ~3-8 s
NestGen2.Wifi.connect(ssid, password | nil) :: {:ok, %{ssid, ip}}
    | {:error, :wrong_password | :not_found | :no_ip | :timeout | :password_required
              | :bad_password_length | :busy | :unavailable | term}                   # up to ~1 min
NestGen2.Wifi.saved_networks() :: [String.t()]
NestGen2.Wifi.forget(ssid) :: :ok | {:error, :not_found | :connected | :unavailable}
# event: {:nest_gen2, :wifi, %{state, ssid, ip}} on any change
```

`connect/2` only saves a network once it has an address; on any failure it
goes back to the previous network and leaves the saved configuration alone.
Passwords are stored as the derived WPA key. Call it from a Task, as it blocks.
The platform's `wifi.sh guard` also restarts `wpa_supplicant` from the saved
configuration if the gateway is unreachable for 3 minutes.

## Version

```elixir
NestGen2.version() :: String.t()   # the SDK's version, e.g. "0.2.0"
```

## Clock

`NestGen2.Clock` keeps UTC right: SNTP shortly after start and then hourly,
stepping the system clock when it is 0.5 s or more out, and saving it to the RTC after every check.
Local time and daylight saving are the app's job.

```elixir
NestGen2.Clock.sync() :: {:ok, %{server: term, offset_ms: integer}} | {:error, term}
NestGen2.Clock.status() :: %{synced_at: DateTime.t() | nil, server: term, offset_ms: integer | nil, last_error: term}
NestGen2.Clock.observe(utc :: DateTime.t(), source) :: :ok   # fallback, e.g. an HTTPS Date header
```

## Configuration

```elixir
config :nest_gen2,
  install_dir: "/media/scratch/.nest_gen2_sdk",
  idle_timeout_ms: 30_000,
  wake_sources: [:dial, :button, :motion, :light],
  motion_threshold: 2,
  light_wake_flicker_pct: 6,    # :light = a fall and a rise of this % within 5 s (not clouds) ...
  light_wake_jump_pct: 40,      # ... or one jump this big (a light switched on)
  light_wake_min_delta: 200,    # smaller changes (raw counts) don't count
  dial_counts_per_turn: 7800,
  dial_step_degrees: 10,
  click_on_step: true,
  temperature_offset_c: -3.7,
  time_servers: ["time.nest.com", "pool.ntp.org", :gateway],
  clock_sync_interval_ms: 3_600_000,
  clock_step_ms: 500
```

## Not in the API

Framebuffer page tracking and damage regions, the pan/virtual-size sysfs writes,
the backplate keep-alive exchange (`0x83`, `0xa2`, `0xa3` every 30 s), frame
CRCs, evdev record parsing and the native helper protocols are internal.

## foxbus against this API (sketch)

```elixir
NestGen2.Dial.set_step(45)
NestGen2.subscribe([:dial_step, :button, :climate])
# splash:  set_background(fox_image); put_text(160, 240, "#{t}°C", align: :center); present()
# stops:   set_background("#1C1C1E"); put_text(...) per bus; present()
# on {:nest_gen2, :dial_step, %{direction: d}}: move to the next/previous screen and redraw
```

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

Fonts are Nest's own Akkurat, loaded at runtime from the device's
`/nestlabs/share/fonts`; the package never ships font files (commercial licence).

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
sleep() :: :ok
awake?() :: boolean
set_idle_timeout(ms | :infinity) :: :ok  # default 30_000
set_wake_sources([:dial | :button | :motion]) :: :ok   # default all three
```

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
set_offset(delta_c) :: :ok               # self-heating correction, default -4.1
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

## Configuration

```elixir
config :nest_gen2_sdk,
  install_dir: "/media/scratch/.nest_gen2_sdk",
  idle_timeout_ms: 30_000,
  wake_sources: [:dial, :button, :motion],
  motion_threshold: 2,
  dial_counts_per_turn: 7800,
  dial_step_degrees: 10,
  click_on_step: true,
  temperature_offset_c: -4.1
```

## Not in the API

Framebuffer page tracking and damage regions, the pan/virtual-size sysfs writes,
the backplate keep-alive exchange (`0x83`, `0xa2`, `0xa3` every 30 s), frame
CRCs, evdev record parsing and the native helper protocols are internal.

## foxbus against this API (sketch)

```elixir
NestGen2.subscribe([:dial, :climate])
NestGen2.Display.set_background(disc)
# on {:nest_gen2, :dial, %{angle: a}}:   put_image(90, 90, fox_frame(a)); present()
# on {:nest_gen2, :climate, %{temperature_c: t}}: put_text(160, 240, "#{t}°C", align: :center); present()
```

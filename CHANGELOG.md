# Changelog

All notable changes to `nest_gen2`. Versions follow [Semantic Versioning](https://semver.org/):
while the version is 0.x, a minor release (0.1 → 0.2) may change the API.

## 0.6.2 (2026-10-28)

- Deep sleep: **fix** a press or motion in the moment the Nest goes to sleep
  being missed, so it slept on for up to 270 s. Before suspending, the SDK now
  uses the kernel's `wakeup_count` handshake (as Nest's own sleep daemon does):
  any wake-up event after it decided to sleep cancels the suspend.
- Deep sleep: **fix** the light thresholds in the sleep notice (`b9`). The SDK
  sent the room temperature there, which the base takes as "wake the display
  when the light goes above this", so in a bright room it could wake straight
  away. They are now set `light_wake_jump_pct` (at least
  `light_wake_min_delta` counts) either side of the room's light, and off
  without `:light` in `wake_sources`.
- Deep sleep: the base's wake mask (`a4`) follows `wake_sources`: someone near
  wakes the display only with `:motion`, a change in light only with `:light`.
  The temperature and humidity wakes are off, so the base no longer wakes the
  display every 30 s on cold mornings at all.
- `docs/backplate.md`: the wake mask and wake reason bits, and the light
  thresholds, named from Nest's own software.

## 0.6.1 (2026-10-26)

- Watch-only viewer: `config :nest_gen2, host_viewer_controls: false` shows the screen
  with no buttons and refuses every press, turn and climate change, for putting an app's
  screen on a public website. Its replies may be cached for a second by a CDN in front.
  See "Showing it publicly" in `docs/host.md`.
- The viewer encodes the screen only when it changes, instead of on every fetch.

## 0.6.0 (2026-10-21)

- **Host mode** (`config :nest_gen2, target: :host`): run an app on a computer instead of
  the Nest, unchanged, to develop and test screens without deploying. The SDK touches no
  hardware: the screen is drawn in memory, the climate is a steady simulated reading, and
  deep sleep, the clock and Wi-Fi are left alone. See `docs/host.md`.
- `NestGen2.Host.Viewer`: on the host, the screen in a browser at http://localhost:4000,
  with the ring turned by mouse wheel, drag or arrow keys, and buttons for a press, double
  click, long press and someone walking past. Uses OTP's own `:inets`; no new
  dependencies.
- `NestGen2.Host`: `turn/1`, `step/1`, `click/0`, `double_click/0`, `long_press/0`,
  `motion/1`, `climate/2` and `screenshot/0`, producing the same events as the hardware.
- `mix nest_gen2.host` builds the text renderer for the computer and checks for the fonts
  (copied from your own Nest; they aren't shipped).
- `NestGen2.Display.snapshot/0` (on the Nest too): what the screen shows.
  `NestGen2.Image.to_png/1`.
- `NestGen2.Dial.turn/1`, `press/1` and `step/0`.
- Text fonts are found in `font_dir` (default the Nest's `/nestlabs/share/fonts`).

## 0.5.1 (2026-10-15)

- Deep sleep: the sleep notice's low-temperature threshold (`c2`) is now 5 °C instead of
  Nest's 16.48 °C. Below the threshold the base woke the display every 30 s (wake reason
  `0x0004`), so on a cold morning the Nest barely slept; with 5 °C it sleeps the full 270 s.
- `docs/power.md`: why the Nest drains its battery on its base unless it deep-sleeps, what
  the SDK does about it, and what an app should do.
- `docs/backplate.md`: the backplate's hardware and serial protocol (frames, start-up,
  keep-alive, the sleep protocol and every known message), from our captures and the
  cuckoo-nest project's research, with each fact's source and credits.

## 0.5.0 (2026-10-14)

- **Deep sleep** (`deep_sleep` config / `NestGen2.Power.set_deep_sleep/1`, off by default):
  10 s after the screen goes dark the whole system suspends to RAM, as Nest's own software
  does, and wakes on the button, on the base (motion), or after at most 270 s. It tells the
  base first (the sleep notice Nest's client sends, with the planned seconds) and repeats
  Nest's wake-up exchange afterwards. Without it the Nest drains its battery even on its
  stand, which supplies only about 120 mA; with it, the battery charges (measured +290 mV/h
  against -70 mV/h).
- The base's wake reason (0x0014) is decoded and traced.

## 0.4.0 (2026-10-14)

- `NestGen2.Gesture` and the `:gesture` topic: `:click`, `:double_click` and `:long_press` from
  the button, with `button_double_click_ms` (default 300, `nil` for none) and
  `button_long_press_ms` (default 800). `:button` `:down`/`:up` are unchanged.

## 0.3.0 (2026-10-13)

- `NestGen2.Storage`: per-app settings in flash (`put/3`, `get/3`, `delete/2`, `keys/1`,
  `dir/1`), written so a power cut mid-write can't corrupt them (temporary file, flush,
  rename, previous value kept as a fallback), stored as readable text with a checksum.
- `platform/storage.sh`: list, read, write and delete an app's stored values from your
  computer.
- `NestGen2.Wifi.save/2`: save a network without switching to it, e.g. a phone hotspot
  before taking the Nest somewhere new.

## 0.2.5 (2026-10-12)

- Backplate framing moves from C to Elixir. `bplink` is now a byte pipe (it sets the serial
  line up and sends the BREAK, nothing else) speaking `{packet, 2}`, and
  `NestGen2.Backplate.Frame` finds, checks and builds frames with binary pattern matching:
  partial frames are kept for the next chunk, noise and bad checksums are skipped. Checked
  against traffic captured from Nest's own firmware: the same frames found, and the head's
  frames re-encoded byte for byte. No API change; the trace keeps its format.

## 0.2.4 (2026-10-12)

- **Fix: the screen went dark after 10 minutes and only a press brought it back,** even
  with an idle timeout of `:infinity`. That was the Linux console, not the SDK: it blanks
  the framebuffer after 10 minutes without keyboard input, and on the Nest only the button
  counts as a keyboard (not the dial or the motion sensor). `NestGen2.Display` now turns
  console blanking off at start, and un-blanks the screen whenever `NestGen2.Power` wakes it.

## 0.2.3 (2026-10-10)

- Backplate restarts are counted (`NestGen2.Backplate.status/0` gains `restarts`) instead of
  logged: after the first wake-up, each restart and its chatter ("BRK", the firmware banner,
  "*sense", and "*HVAC power lost", which a base with no heating system wired to it prints)
  no longer reach the log. A loose head unit on its base restarts it now and then; the SDK
  wakes it again within about 2 seconds.
- The optional backplate trace (`trace_file`) is capped at 256 KB (`trace_max_bytes`), the
  older part kept as `<file>.1`. It lives in `/tmp`, which is RAM: uncapped, it grew about
  7 MB a day and ran the Nest out of memory overnight, which resets the board ("Global Cold
  Reset").

## 0.2.2 (2026-10-04)

- **Install guide and scripts.** [docs/install.md](docs/install.md) goes from a 2nd-gen
  Nest flashed with No Longer Evil to foxbus and then your own app.
  `platform/install.sh <nest-address>` installs the platform (SSH key, a prebuilt runtime
  bundle with a checked sha256, Wi-Fi, boot script with the original kept as `rcS.stock`)
  and `--check` reports what's running; `platform/uninstall.sh` restores the original.
- `examples/hello_nest`: the smallest useful app, as a starting point.
- The Hex description, README and package links say it's for a Wi-Fi-connected Nest rooted
  with No Longer Evil, and link to the install guide and NLE's rooting instructions.
- `deploy_app.sh` installs the SDK with the app on the first deploy to a Nest, and with
  `--sdk` replaces a different version; it removes an updated library's old `.beam` files.
- `app_watchdog.sh` waits quietly until the app has been deployed.
- `host_env.sh` works with OTP 26 / Elixir 1.17 from mise or asdf, and `deploy_app.sh`
  stops early with what to install if the toolchain is wrong.
- Platform: `wifi.sh add SSID` saves another network over SSH (the password is asked for
  without echo, and only the derived key is stored), so a phone hotspot can be set up
  before taking the Nest somewhere new.
- Platform: `app_watchdog.sh` keeps the previous run's log as `<app>.log.1`.
- Platform: at boot, `wifi.sh takeover` no longer hands Wi-Fi back to Nest's connection
  manager when the gateway is slow to answer (which, with Nest's software stopped, left the
  Nest offline until the next reboot); it keeps retrying. The old behaviour is `wifi.sh trial`.
  The Wi-Fi log moves to `<install>/wifi.log` so it survives a reboot.

## 0.2.1 (2026-10-03)

- The backplate is woken the way Nest's own client does it, each time the link opens:
  a serial BREAK, then answering its 0x0004 hello (echoed as 0x8f) and its start-up
  queries. After a reset or a power loss the backplate otherwise stays silent (no motion,
  light or climate readings, and the green LED flashing) until the stock firmware runs.
- If no backplate message arrives for 15 s, the handshake runs again (at most once a minute).
- `bplink` accepts `brk` (flush, then a 100 ms BREAK).

## 0.2.0 (2026-10-03)

- `NestGen2.Wifi`: status, scan, connect (with automatic fall-back to the previous
  network and nothing saved on failure), saved networks, forget; `:wifi` events.
  Passwords are stored as the derived WPA key.
- `NestGen2.version/0`.
- Platform: `entropyd`, started from rcS, keeps the kernel's entropy pool topped up. Without
  it OpenSSL blocks on `/dev/random` at the first TLS connection and stalls the whole VM.
- `evwatch` exits when its port closes instead of lingering until the next input event.
- Platform: Wi-Fi from boot (`wifi.sh takeover` in rcS), and `wifi.sh guard`, which
  restarts `wpa_supplicant` from the saved configuration after 3 minutes without the
  gateway.
- `platform/mix26`: run `mix` with the Nest's toolchain regardless of the shell's version manager.

## 0.1.0 (2026-10-02)

First release.

### Head unit
- `NestGen2.Display`: page-flipped drawing on the round 320×320 screen (`set_background/1`
  with an image or a hex colour drawn as the visible disc, `put_image/3`, `fill_rect/5`,
  `put_text/4`, `present/0`).
- `NestGen2.Text`: text rendered on the device from its own fonts (no font files shipped).
- `NestGen2.Dial`: rotation (7800 counts per turn), steps with Nest's click, and press.
- `NestGen2.Backlight`, `NestGen2.Piezo`, `NestGen2.Power` (sleep after idle; wake on dial,
  button, motion or a flicker in room light; `keep_awake/1` holds that keep the screen on,
  released explicitly or when the holder exits).

### Backplate
- Keep-alive that stops the backplate power-cycling the head unit.
- `NestGen2.Motion`, `NestGen2.Climate`, `NestGen2.Battery`, `NestGen2.Light`, and events
  (`:motion`, `:light`, `:climate`, `:battery`).

### System
- `NestGen2.Network`: DNS without Nest's connection manager.
- `NestGen2.Clock`: SNTP sync of UTC, saved to the RTC. Takes four samples per server and
  trusts the shortest round trip (rejecting any over 500 ms), first sync 30 s after start.
- Platform: `app_watchdog.sh` (one watchdog per app; the VM records its own pid), `deploy_app.sh` (deploy an app without the SDK, checking the
  SDK version on the device), Wi-Fi without connmand (`platform/wifi`).

### Known limitations
- If the backplate is reset (or loses power while the head unit stays up) it stops
  reporting and periodically power-cycles the head unit. Booting the stock firmware once
  brings it back; the SDK cannot yet do this itself.

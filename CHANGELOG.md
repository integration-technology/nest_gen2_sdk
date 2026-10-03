# Changelog

All notable changes to `nest_gen2`. Versions follow [Semantic Versioning](https://semver.org/):
while the version is 0.x, a minor release (0.1 → 0.2) may change the API.

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

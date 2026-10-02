# nest_gen2

Turn a rooted Nest Learning Thermostat (2nd gen) into a small Elixir device: a
320×320 round screen, a rotating ring with a press, a piezo, motion sensors and a
climate sensor, all driven from your own OTP application.

**Status: alpha (0.1).** It runs the example app,
[foxbus](https://github.com/integration-technology/foxbus), on a real Nest every
day. The public API is described in [`docs/api.md`](docs/api.md) and the module
docs. Expect API changes between 0.x minor versions (see Versioning).

## Install

```elixir
def deps do
  [{:nest_gen2, "~> 0.1.0"}]
end
```

Before the Hex release, or to track a tag: `{:nest_gen2, github:
"integration-technology/nest_gen2_sdk", tag: "v0.1.0"}`. The device side
(rooting, runtime, boot hook) is described in [`platform/README.md`](platform/README.md).

## Example app: foxbus

[foxbus](https://github.com/integration-technology/foxbus) is a complete
application built on this SDK, kept as a GitHub repository rather than a Hex
package so it can be read, forked and adapted. It shows live bus departures for
two stops, a splash screen with the room temperature, disruption warnings, and a
countdown with an arrival alarm, using:

- `NestGen2.Display` and `NestGen2.Text` for the screens,
- `NestGen2.Dial` steps and presses to move between them and mute the alarm,
- `NestGen2.Power.keep_awake/1` to keep the screen on while the alarm sounds,
- `NestGen2.Climate` for the temperature, and
- `platform/deploy_app.sh` to build and install it on the Nest (set `NEST_HOST`, or
  put it in `~/.config/nest_gen2/target`).

## Versioning

Both the SDK and foxbus follow [Semantic Versioning](https://semver.org/).

- While the SDK is **0.x**, a **minor** release (0.1 → 0.2) may change the API;
  patch releases (0.1.0 → 0.1.1) only fix things. Depend on it with
  **`~> 0.1.0`** (which allows 0.1.x but not 0.2), not `~> 0.1` (which in Elixir
  allows anything below 1.0).
- From 1.0, breaking changes only come with a major release.
- Every release is a git tag (`v0.1.0`) with an entry in
  [CHANGELOG.md](CHANGELOG.md).
- Apps are deployed separately from the SDK. `platform/deploy_app.sh` refuses to
  install an app built against a different SDK version from the one on the
  device.

| foxbus | nest_gen2 |
|---|---|
| 0.1.x | 0.1.x |

## Layout

| Folder | What |
|---|---|
| `lib/` | The Elixir package: `NestGen2` (events), `Display`, `Image`, `Text`, `Backlight`, `Dial`, `Piezo`, `Power`, `Backplate`, `Motion`, `Climate`, `Battery`, `Light`, `Clock`, `Network` |
| `c_src/` | C helpers run as ports: `evwatch` (input events), `bplink` (backplate UART), `textrender` (text from the device's own fonts), `regread` (register reads for debugging) |
| `priv/` | Pre-built ARM binaries of the helpers (`make -C c_src`) |
| `platform/` | Rooting, runtime install, boot hook, app watchdog, app deploy, Wi-Fi without Nest's connection manager, host build environment, shell setup |
| `tools/` | Backplate frame decoder |
| `docs/` | API description |

## Build and test

The Nest runs OTP 26 / Elixir 1.17, so build with that toolchain:

```sh
. platform/host_env.sh
mix test
```

## Layers

1. **Platform** — the device runs our BEAM instead of Nest's software.
2. **Native helpers** — small static C programs for the device nodes Erlang
   can't read reliably.
3. **SDK** — the hex package `nest_gen2` (`NestGen2.*`).
4. **Apps** — your OTP application, e.g. foxbus.

The SDK provides mechanisms with sensible defaults and apps decide policy. The
backplate keep-alive always runs.

## Contributing

Issues and pull requests are welcome at
[github.com/integration-technology/nest_gen2_sdk](https://github.com/integration-technology/nest_gen2_sdk/issues).
For hardware problems, please include the board (Gen 2 "Diamond"), the
backplate firmware version (the `0x0001` message after a backplate reset) and
what the Nest's own firmware does in the same situation.

## Credits

This work stands on the shoulders of the Nest right-to-repair community:

- **[NoLongerEvil-Thermostat](https://github.com/codykociemba/NoLongerEvil-Thermostat)**
  by codykociemba — the installer we use to root the Nest and flash custom
  firmware. Every device running this SDK starts there. Its own credits, which we
  pass on:
  - **grant-h / ajb142** — [omap_loader](https://github.com/ajb142/omap_loader),
    the USB bootloader tool used to flash OMAP devices.
  - **exploiteers (GTVHacker)** — the original research behind the
    [Nest DFU Attack](https://github.com/exploiteers/NestDFUAttack), which showed
    custom firmware could be flashed to Nest gen 1 and gen 2.
  - **FULU and bounty backers** — for funding the
    [Nest Learning Thermostat Gen 1/2 bounty](https://bounties.fulu.org/bounties/nest-learning-thermostat-gen-1-2)
    and supporting right to repair.
- **[stb_truetype](https://github.com/nothings/stb)** by Sean Barrett (public
  domain / MIT), vendored in `c_src/vendor`, which rasterises text on the device.
- **Nest Labs' published GPL kernel sources** — reading the board file and
  drivers is how the display, dial, backlight and sensors were understood.

## Licence

GPL-3.0-only; see [LICENSE](LICENSE). If you distribute an app built on this
SDK, the app must be released under a GPL-compatible licence too.

Nest's Akkurat fonts (`/nestlabs/share/fonts`) are commercially licensed and are
not covered by this licence. This repository never contains them or anything
rendered from them; the SDK renders text from the device's own copy at runtime.

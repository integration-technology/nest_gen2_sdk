# nest_gen2_sdk

Turn a rooted Nest Learning Thermostat (2nd gen) into a small Elixir device: a
320×320 round screen, a rotating ring with a press, a piezo, motion sensors and a
climate sensor, all driven from your own OTP application.

**Status: pre-alpha.** The hardware is fully working through the Erlang
prototype in `prototype/`; the Elixir package with the API in `docs/api.md` is
being built from it. The reference app is
[foxbus](https://github.com/integration-technology/foxbus).

## Layout

| Folder | What |
|---|---|
| `platform/` | Rooting, runtime install, boot hook, watchdog, shell setup |
| `native/` | C helpers run as ports: `evwatch` (input events), `bplink` (backplate UART), `regread` (register reads for debugging) |
| `prototype/` | Working Erlang modules: backplate link and keep-alive, double-buffered display, dial, click, motion wake, temperature |
| `tools/` | Backplate frame decoder, temperature calibration logger |
| `docs/` | Public API draft (`api.md`), signal-chain diagram |

## Layers

1. **Platform** — the device runs our BEAM instead of Nest's software.
2. **Native helpers** — small static C programs for the device nodes Erlang
   can't read reliably.
3. **SDK** — the hex package `nest_gen2_sdk` (`NestGen2.*`).
4. **Apps** — your OTP application, e.g. foxbus.

The SDK provides mechanisms with sensible defaults and apps decide policy. The
backplate keep-alive always runs.

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
- **Nest Labs' published GPL kernel sources** — reading the board file and
  drivers is how the display, dial, backlight and sensors were understood.

## Licence

GPL-3.0-only; see [LICENSE](LICENSE). If you distribute an app built on this
SDK, the app must be released under a GPL-compatible licence too.

Nest's Akkurat fonts (`/nestlabs/share/fonts`) are commercially licensed and are
not covered by this licence. This repository never contains them or anything
rendered from them; the SDK renders text from the device's own copy at runtime.

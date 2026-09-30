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

## Licensing notes

Nest's Akkurat fonts (`/nestlabs/share/fonts`) are commercially licensed. This
repository never contains them or anything rendered from them; the SDK loads
them from the device at runtime.

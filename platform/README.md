# Platform

Everything needed below the SDK: a rooted Nest Learning Thermostat (2nd gen,
"Diamond" board) running our own Erlang/Elixir instead of Nest's software.

## Install folder

Everything lives in `/media/scratch/.nest_gen2_sdk`. The leading dot is required:
Nest's `/etc/init.d/nestlabs` (`cleanup_scratch`) deletes every non-dot name in
`/media/scratch` whenever the stock stack starts.

## Steps (current, manual)

1. **Root** with No Longer Evil: USB DFU mode (hold the display 10–15 s on USB),
   flash with the NLE installer. First boot has root password `nolongerevil`;
   install an SSH key, then add `-g` to dropbear in `/etc/init.d/rcS` to disable
   root password login.
2. **Disable the stock stack** by commenting out these `rcS` lines: `nlmetrics`,
   `heartbeat`, `nlsleep`, `nlshutdown`, `nestlabs`, `monit`
   (see `rcS.excerpt`). BusyBox `sed` here needs one call per line.
3. **Runtime:** cross-compiled OTP 26 and Elixir 1.17, extracted to
   `<install>/otp` and `<install>/elixir`. The OTP launcher is relocatable.
   Build notes: toolchain `arm-nest-linux-musleabi`, `CFLAGS="-O2 -g -march=armv7-a"`
   (the default armv5te needs 64-bit atomics the 2.6.37 kernel lacks),
   `--without-termcap`; build Elixir against a native OTP 26.
4. **Boot hook:** the last lines of `rcS.excerpt` draw the splash and start
   `dial_watchdog.sh`, which keeps exactly one BEAM running (pidfile-locked).
5. **Shell (optional):** static bash at `/bin/bash`, `shell/` dotfiles and
   `/etc/termcap`; `profile_hook` is appended to `/root/.profile` and only
   switches interactive logins to bash, so `ssh host cmd` always gets plain `sh`.

## Hardware notes that shape the SDK

- The stand's microcontroller power-cycles the head unit ~36 min after it last
  heard from it on `/dev/ttyO2`; the SDK's keep-alive prevents this.
- `/dev/fb0` writes must be chunked to ≤4 KB. Our boots leave the virtual size
  at 320×320; the SDK sets 320×640 for page flipping.
- The panel goes dark ~60 s after the last backlight write; the SDK re-asserts it.
- A long press on the dial triggers the power chip's hardware reset.

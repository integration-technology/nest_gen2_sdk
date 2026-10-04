# From a Nest thermostat to your own Elixir app

This guide takes a Nest Learning Thermostat (2nd generation) from its box to
running an Elixir app you can change and redeploy: first the example app,
[foxbus](https://github.com/integration-technology/foxbus), then your own.

It takes about an hour, most of it waiting for the Nest's flash memory. Each
step says what you should see; if you don't see it, check
[Troubleshooting](#troubleshooting) before going on.

> **Status:** written from the first unit and being checked step by step on a
> second, factory-fresh one. Steps marked *(to confirm)* haven't been through
> that check yet.

## What you need

- **A Nest Learning Thermostat, 2nd generation.** In the Nest's own menu,
  **Settings → Technical Info** shows the display model: it must start with
  **2** (e.g. `2.14`). Gen 1 isn't supported by this SDK, and Gen 3 can't be
  flashed yet (see [No Longer Evil's compatibility list](https://docs.nolongerevil.com/compatibility)).
  A Gen 2 has a yellow/green spirit level in the base; a Gen 3's is blue.
- **Power for it.** The display unit runs from its own battery for a while,
  but needs its base: a wall plate, the Nest desk stand, or a Heat Link base.
  The SDK talks to the base, and without it the Nest can't stay up.
- **A USB cable** (micro-USB to the back of the display) for flashing.
- **A computer running Linux or macOS**, on the same network as the Nest.
- **A 2.4 GHz Wi-Fi network.** The Nest's radio doesn't do 5 GHz. (A phone
  hotspot works; on an iPhone turn on *Maximize Compatibility*.)

Throughout, `<nest-address>` means the Nest's IP address on your network, for
example as listed by your router.

## 1. Flash No Longer Evil

[No Longer Evil](https://nolongerevil.com) (NLE) replaces the Nest's bootloader
and kernel so the thermostat works without Google's servers, and opens SSH.
This SDK runs on top of it.

1. Follow NLE's [installation guide](https://docs.nolongerevil.com/hosted/installation):
   connect the display to your computer by USB, hold the display down for
   10–15 seconds to put it into DFU mode, and run their installer.
2. When the Nest restarts, go through its on-screen setup until it's on your
   Wi-Fi. If it asks to pair with a Heat Link you don't have, hold the display
   down for 10 seconds to restart it; it then goes straight to Wi-Fi setup.
3. Find its address: **Settings → Technical Info → Network** on the Nest, or
   your router's list of devices. It helps to give it a fixed address in your
   router (a "DHCP reservation").
4. Check you can log in. The password is `nolongerevil`:

       ssh root@<nest-address>

   *(to confirm: whether NLE's hosted installer enables SSH by default, or
   whether you need their firmware builder's `--enable-root-access` option.)*

   Type `exit` to leave. If your SSH settings only allow keys, add
   `-o PreferredAuthentications=password` to the command.

## 2. Set up your computer

Apps for the Nest are built on your computer with **Erlang/OTP 26 and Elixir
1.17**, the versions the Nest runs. Newer versions build code the Nest can't
load. With [mise](https://mise.jdx.dev) (or asdf):

    mise use --global erlang@26.2.5 elixir@1.17.3-otp-26

Then get the SDK, which holds the install and deploy scripts:

    git clone https://github.com/integration-technology/nest_gen2_sdk.git
    cd nest_gen2_sdk

Check the toolchain:

    sh -c '. platform/host_env.sh && nest_toolchain_ok && echo OK'

You should see `OK`. Otherwise it says what it found and what to install.

## 3. Install the platform on the Nest

    platform/install.sh <nest-address>

It explains each step as it goes:

1. **SSH key.** It creates `~/.ssh/nest_gen2` and asks once for the password
   (`nolongerevil`) to install it. From then on no password is needed, and the
   Nest stops accepting root password logins.
2. **Checks** it's a 2nd-gen Nest with room in its flash.
3. **Downloads the runtime**, Erlang/OTP 26 and Elixir 1.17 built for the
   Nest (about 45 MB), and checks its checksum.
4. **Copies it to the Nest.** This takes several minutes; the flash is slow.
5. **Wi-Fi.** It asks for your network's name (press Enter to keep the one
   the Nest is on) and then, on the Nest, its password. The SDK runs its own
   Wi-Fi from now on, because Nest's connection manager goes with the rest of
   Nest's software.
6. **Boot script.** It changes `/etc/init.d/rcS` so the Nest starts the SDK
   instead of Nest's thermostat software, keeping the original as
   `/etc/init.d/rcS.stock`.
7. **Restarts the Nest** and reports what's running:

       entropyd                     running
       Wi-Fi (SDK)                  running
       app watchdog (foxbus)        running
       foxbus                       not deployed yet
       Nest's own software          stopped
       runtime                      nest_gen2-runtime-...
       address                      <nest-address>

After the restart the Nest shows its boot logo until an app draws something.
You can run `platform/install.sh <nest-address> --check` at any time for the
same report.

Everything lives in `/media/scratch/.nest_gen2_sdk` on the Nest. To go back to
No Longer Evil's own software, see [Undoing it](#undoing-it).

## 4. Deploy the example app: foxbus

[foxbus](https://github.com/integration-technology/foxbus) shows live bus
departures, the room temperature, disruption warnings and an arrival alarm. Get
it next to the SDK and set it up for your own stops as its README describes:

    cd ..
    git clone https://github.com/integration-technology/foxbus.git
    cd nest_gen2_sdk
    platform/deploy_app.sh ../foxbus

`deploy_app.sh` runs the app's tests, builds it, copies it and its
dependencies to the Nest (the first time, the SDK as well), and restarts it. It
ends with the first lines of the app's log, and within half a minute the Nest
shows foxbus.

`install.sh` saved the Nest's address and key in `~/.config/nest_gen2/target`,
which is where `deploy_app.sh` finds them.

## 5. Your own app

[`examples/hello_nest`](../examples/hello_nest) is the smallest useful app: a
number you change with the ring, reset with a press, and the room temperature.
Copy it, make it yours, and switch the Nest over to it:

    cp -r examples/hello_nest ../my_app        # then rename the app inside
    platform/install.sh <nest-address> --app my_app
    platform/deploy_app.sh ../my_app

`install.sh --app` only changes which app starts at boot; it skips everything
that's already done. One app runs at a time: the Nest has 58 MB of memory, too
little for two Erlang VMs.

An app is an ordinary Mix project with `{:nest_gen2, "~> 0.2.1"}` in its
dependencies. [docs/api.md](api.md) describes what the SDK provides: drawing on
the round screen, text, the ring and its press, the piezo, the screen's sleep
and wake, the motion, light and climate sensors, and Wi-Fi.

## Everyday use

All of these run on your computer, from the SDK folder.

| To | Run |
|---|---|
| See what's running | `platform/install.sh <nest-address> --check` |
| Update the app | `platform/deploy_app.sh ../foxbus` |
| Read the app's log | `ssh -i ~/.ssh/nest_gen2 root@<nest-address> tail -50 /media/scratch/.nest_gen2_sdk/foxbus.log` |
| The log from before the last restart | the same with `foxbus.log.1` |
| Save another Wi-Fi network | `ssh -t -i ~/.ssh/nest_gen2 root@<nest-address> sh /media/scratch/.nest_gen2_sdk/wifi.sh add "Network name"` |
| Move to a newer SDK | update the app's dependency, then `platform/deploy_app.sh ../foxbus --sdk` |
| Restart the Nest | hold the display down for 10 seconds |

The Nest joins whichever saved network is in range, so a phone hotspot saved at
home lets you take it somewhere else.

## Undoing it

    platform/uninstall.sh <nest-address>           # back to No Longer Evil's software
    platform/uninstall.sh <nest-address> --purge   # ... and delete the runtime and apps

This restores the original `/etc/init.d/rcS` and restarts the Nest. Your SSH key
stays installed.

## Troubleshooting

**`install.sh` can't log in with the password.** Check the address and that you
can `ssh root@<nest-address>` by hand (step 1.4).

**The download fails or the checksum doesn't match.** Delete
`~/.cache/nest_gen2/` and run it again.

**After the restart the Nest isn't on the network.** Give it three minutes: if
the router doesn't answer, the SDK restarts Wi-Fi every 3 minutes. If it still
isn't back, the network name or password was probably wrong. Hold the display
down for 10 s to restart; if that doesn't help, connect it by USB, re-flash No
Longer Evil (step 1), and run `install.sh` again.

**The screen stays on the boot logo.** The app isn't deployed or doesn't start.
Run `--check`, then read the app's log.

**The green light above the screen flashes and nothing reacts to motion.** The
base has gone quiet, usually after losing power. The SDK wakes it within about
a minute; if it doesn't, restart the Nest.

**The screen doesn't wake when you walk up to it.** The motion sensor is better
at movement across the room than straight towards it. Pressing the display
always wakes it, and foxbus's settings (press on the home screen, then *Screen*)
can keep it on.

**`deploy_app.sh` says the SDK version doesn't match.** Another app on the Nest
was deployed with a different SDK version. Build against that version, or add
`--sdk` to replace it.

**Anything else.** Open an issue at
<https://github.com/integration-technology/nest_gen2_sdk/issues> with the output
of `--check` and the last lines of the app's log.

## What install.sh changes

So you can check its work, or do it by hand:

- adds `/media/scratch/.nest_gen2_sdk/` with `otp/`, `elixir/`, `udhcpc`,
  `entropyd`, `wifi.sh`, `udhcpc.script`, `app_watchdog.sh`, `RUNTIME`, and
  `wpa_supplicant.conf` (your Wi-Fi network as a WPA key, not the password);
- appends your public key to `/root/.ssh/authorized_keys`;
- copies `/etc/init.d/rcS` to `/etc/init.d/rcS.stock`, then in `rcS`: comments
  out `nlmetrics`, `heartbeat`, `nlsleep`, `nlshutdown`, `nestlabs` and `monit`;
  starts `entropyd` before networking and `wifi.sh takeover` after it; adds `-g`
  to dropbear (no root password logins); and starts `app_watchdog.sh <app>` at
  the end ([`platform/rcs_patch.awk`](../platform/rcs_patch.awk) does this);
- writes `~/.config/nest_gen2/target` on your computer.

[platform/README.md](../platform/README.md) explains why each part is there.

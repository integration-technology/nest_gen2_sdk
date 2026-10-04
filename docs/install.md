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

Throughout, `<nest-address>` means the Nest's IP address on your network
(step 1 shows where to find it).

## 1. Put the Nest on your Wi-Fi and note its address

Do this first, with the Nest's own (stock) software: after rooting you need the
Nest on your network to reach it, and it keeps the network it joined.

1. Power the Nest (on its base or stand) and go through its on-screen setup, or
   later **Settings → Network**. Choose your 2.4 GHz network and type its
   password with the ring.
2. If it insists on pairing with a Heat Link you don't have, hold the display
   down for 10 seconds to restart it; it then goes straight to Wi-Fi setup.
3. Note its address: **Settings → Technical Info → Network** shows the IP
   address (e.g. `192.0.2.50`). That's `<nest-address>` in the rest of this
   guide. Your router's list of devices shows it too.
4. Recommended: give it a fixed address in your router (a "DHCP reservation"
   for the Nest), so the address stays the same through flashing and restarts.

While you're in **Technical Info**, check the display model starts with **2**.

## 2. Root it with No Longer Evil

[No Longer Evil](https://nolongerevil.com) (NLE) replaces the Nest's bootloader
and kernel so it works without Google's servers, and gives you `root` over SSH.
This SDK runs on top of it.

Follow NLE's own instructions: the
[installation guide](https://docs.nolongerevil.com/hosted/installation) (start
with their [compatibility check](https://docs.nolongerevil.com/compatibility)).
In short, you connect the display to your computer by USB, hold the display down
for 10–15 seconds to put it into DFU mode, and run their installer.

When it's done the Nest restarts on its own and rejoins your Wi-Fi, usually at
the same address. Check you can log in as `root`; the password is
`nolongerevil`:

    ssh -o PreferredAuthentications=password root@<nest-address>

The first time, SSH asks you to confirm the Nest's host key: answer `yes`. You
should get a `#` prompt. Type `exit` to leave.

*(to confirm on a fresh unit: whether NLE's hosted installer enables SSH like
this by default, or whether you need their firmware builder's
`--enable-root-access` option.)*

## 3. Set up SSH without a password

The scripts in this guide log in to the Nest with an SSH key, never a password.
The Nest's SSH server is old: it accepts **ECDSA** or RSA keys, not ed25519, so
make an ECDSA key just for it:

    ssh-keygen -t ecdsa -b 521 -f ~/.ssh/nest_gen2 -C nest_gen2

Press Enter when asked for a passphrase (or set one and use `ssh-agent`). Then
copy the public key to the Nest, typing `nolongerevil` once more:

    ssh -o PreferredAuthentications=password root@<nest-address> \
      'mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' \
      < ~/.ssh/nest_gen2.pub

Check it logs in without asking for a password:

    ssh -i ~/.ssh/nest_gen2 root@<nest-address> uname -a

You should see a line starting `Linux` and mentioning `2.6.37`. To shorten
commands, add this to `~/.ssh/config`, after which `ssh nest` is enough:

    Host nest
      HostName <nest-address>
      User root
      IdentityFile ~/.ssh/nest_gen2
      IdentitiesOnly yes

The installer in step 5 turns off root password logins, so from then on only
your key gets in. (If you skip this step, the installer does it for you and
asks for the password once.)

## 4. Set up your computer

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

## 5. Install the platform on the Nest

    platform/install.sh <nest-address>

It explains each step as it goes:

1. **SSH key.** It logs in with `~/.ssh/nest_gen2` from step 3. (If that key
   doesn't exist or isn't on the Nest yet, it creates and installs it, asking
   once for the password `nolongerevil`.)
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

## 6. Deploy the example app: foxbus

[foxbus](https://github.com/integration-technology/foxbus) shows live bus
departures, the room temperature, disruption warnings and an arrival alarm. Get
it next to the SDK and set it up for your own stops as described in its README,
under [Run foxbus on your own Nest](https://github.com/integration-technology/foxbus#run-foxbus-on-your-own-nest)
(it shows Carousel Buses stops only, for now):

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

## 7. Your own app

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
can log in by hand as in steps 2 and 3.

**The download fails or the checksum doesn't match.** Delete
`~/.cache/nest_gen2/` and run it again.

**After the restart the Nest isn't on the network.** Give it three minutes: if
the router doesn't answer, the SDK restarts Wi-Fi every 3 minutes. If it still
isn't back, the network name or password was probably wrong. Hold the display
down for 10 s to restart; if that doesn't help, connect it by USB, re-flash No
Longer Evil (step 2), and run `install.sh` again.

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

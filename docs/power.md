# Power, battery and sleep

A Nest that runs your app all day on its base or stand needs one thing from
the app: to let the SDK put the whole device into deep sleep when nobody is
looking. This page explains why, what the SDK does, and what an app should do.
Everything here was measured on a 2nd-gen Nest on a UK desk stand.

## Why: the base supplies only about 120 mA

The display runs from its own battery. The base (wall plate or stand) charges
that battery and powers the display, but it can supply only about **120 mA**,
the figure it reports in its power status message (`0x002b`); a heating
thermostat is designed to live on the trickle it can draw from the heating
wires. The display awake, with Wi-Fi up and the processor running, uses more
than that, even with the screen dark and the processor nearly idle.

So a display that stays awake drains its battery **while plugged in**:

| | Battery on the stand |
|---|---|
| Awake all the time (our app before deep sleep) | fell about 70 mV/h, ran flat after 12 to 24 hours |
| Deep sleep while the screen is dark | rose about 290 mV/h from nearly flat, then held at about 3.93 V for 17+ hours |

On USB straight into the back of the display it charges either way, because
USB supplies far more than the base.

Nest's own software has the same budget and stays within it the same way: it
suspends the whole system between events.

## What deep sleep does

With deep sleep on, 10 seconds after the screen goes dark (and with nothing
holding it awake) `NestGen2.Power`:

1. tells the base it is going to sleep, for how long, and at what temperature
   to wake it (the sleep notice Nest's own software sends; see
   [backplate.md](backplate.md#sleep));
2. sets the clock chip's alarm and suspends to RAM: the processor, radios and
   every process stop, with memory kept alive. It uses the kernel's
   `wakeup_count` handshake, as Nest's own sleep daemon does, so a press or
   motion in the moment it is going to sleep cancels the suspend instead of
   being missed until the alarm;
3. carries on exactly where it stopped when something wakes it: the button, the
   base (someone moving near it; also its own housekeeping now and then), or
   the alarm after at most 270 seconds;
4. says hello to the base again and, if the wake didn't light the screen, goes
   back to sleep after 8 seconds.

Typically it is asleep 90 to 97% of the time. Your app's processes don't notice
being suspended: their state is in memory, unchanged.

## What an app should do

1. **Turn it on.** `NestGen2.Power.set_deep_sleep(true)` (or config
   `deep_sleep: true`). It is off by default so that nothing changes for an app
   that hasn't thought about it.
2. **Let the screen sleep.** An idle timeout of `:infinity` ("always on") means
   the screen never sleeps, so neither does the device, and the battery drains.
   If you offer "always on", say that it drains the battery on the base; foxbus
   turns deep sleep on for its 30 s / 1 min / 5 min settings and off for
   "always on".
3. **Use holds sparingly.** `keep_awake/1` keeps the device fully awake. Fine for
   an alarm that is ringing or a settings screen; not for something that lasts
   hours.
4. **Refresh on wake.** While suspended nothing runs, and timers count only
   awake time: a "poll every 60 s" timer pauses while the device sleeps. When
   `{:nest_gen2, :power, :awake}` arrives, fetch fresh data for whatever the
   screen shows. Wi-Fi reconnects within a few seconds of waking, so retry a
   failed request once or twice.
5. **Don't count on work while asleep.** Anything that must happen at a set time
   while nobody is looking will happen late. (Waking at a chosen time for an app
   is a planned addition.)

## Things that looked like power problems and weren't

- **The screen went dark after 10 minutes and only a press brought it back.**
  The Linux console blanks the framebuffer after 10 minutes without keyboard
  input, and only the button counts as a keyboard. The SDK turns console
  blanking off (0.2.4).
- **The Nest reset itself overnight ("Global Cold Reset").** It ran out of
  memory: a diagnostic trace in `/tmp`, which is RAM, grew all day. The trace is
  now capped (0.2.3), and off unless you set `trace_file`.
- **The base woke the display every 30 seconds on cold mornings** (wake reason
  `0x0004`). The sleep notice carries a low-temperature threshold, below which
  the base wakes the display to decide about heating; Nest's own value was about
  16.5 °C. The SDK sent 5 °C (0.5.1), and now turns the temperature wake off.
- **In a bright room the base could wake the display straight away.** Before
  0.6.2 the SDK sent the room temperature where the base expects a light
  threshold, so above about 2,300 counts of light it was always past it. The
  thresholds are now set either side of the room's light, and only with
  `:light` in `wake_sources`.
- **The base restarted every few minutes.** A loose display on its stand or a
  power blip; the base logs `*HVAC power lost`. Screw the stand's base down; the
  SDK re-wakes the base within seconds anyway (0.2.1).

## The lights

The light above the screen is the base's:

- **Blinking green:** starting, restarting or updating.
- **Blinking red:** the battery is too low to start; it's charging and starts by
  itself when it can (this can take an hour or more on a stand). Pressing does
  nothing until then.

## Watching it

The battery voltage (mV) is in the base's `0x000b` message (bytes 12-13) and its
power status `0x002b` (per record: battery mV at bytes 2-3, input mV at 6-7).
`NestGen2.Battery` publishes `:battery` events. With `trace_file` set, the trace
shows each `deep sleep`, `woke after N s` and `base wake reason`.

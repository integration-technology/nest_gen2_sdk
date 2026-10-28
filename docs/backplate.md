# The backplate: hardware and protocol

The Nest Learning Thermostat (2nd gen) is two computers. The **display** (head
unit) runs Linux on a TI OMAP3 and drives the screen, the ring, Wi-Fi and the
apps. The **backplate** (the wall plate, or the base inside the desk stand) has
its own microcontroller, which reads most of the sensors, switches the heating,
draws power from the heating wires, and powers the display and charges its
battery. The two talk over a serial line, and `NestGen2.Backplate` is the SDK's
side of that conversation.

This page collects what is known about the backplate: what we found on our own
units (captures of Nest's own software, and the SDK running on real hardware),
and what the [cuckoo-nest](https://github.com/cuckoo-nest) project documented in
its [wiki](https://github.com/cuckoo-nest/wiki/tree/main/backplate). Each fact is
marked with where it comes from:

- **✓ confirmed**: seen on our hardware, and what the SDK relies on;
- **cuckoo**: reported by cuckoo-nest, not yet confirmed by us;
- **both**: found independently by both;
- **code**: named in the log messages and code of Nest's own software on the
  display, studied to interoperate with it.

Please read the cuckoo-nest wiki itself for their photos, the US terminal
details and their investigation notes; see [Credits](#credits).

## Hardware

- **Microcontroller:** an ST STM32L151VB (32 MHz Arm Cortex-M3, 128 kB flash)
  with its own firmware *(cuckoo)*. It reports itself as `Backplate-3.2`,
  firmware `1.0.26` built 2019-04-05, "TFE (AMBER_BP)", bootloader "BSL" *(✓ on
  our UK desk stand)*.
- **US backplate:** 10 spring terminals (Rc, Rh, W1, W2/AUX, Y1, Y2, G, O/B, C,
  Star), switched by FETs, each with a switch that detects whether a wire is
  inserted; without a C wire it "power-sips" from the heating circuit *(cuckoo)*.
- **UK/EU backplate:** takes 12 V DC on T1/T2 from the Heat Link (which sits by
  the boiler and switches it with a relay), or power from a micro-USB socket; the
  Heat Link can also talk to it wirelessly *(cuckoo)*. Our desk stand is the
  USB-powered variant *(✓)*.
- **Sensors:** temperature and humidity, three board temperatures, a near-field
  proximity sensor, the PIR motion sensors and ambient light are all read by the
  backplate, not by Linux *(both)*.
- **Power budget:** the backplate supplies the display only about **120 mA**
  (reported in `0x002b`), less than the display uses awake. The battery charges
  only while the display sleeps most of the time; see [Sleep](#sleep) *(✓)*.

## The serial line

`/dev/ttyO2` on the display, 115200 baud, 8N1, raw *(both)*. Set the port fully
raw (`cfmakeraw`): with the default input processing, a `0x0d` byte is turned into
`0x0a` and corrupts frames, which showed up as `Backplate-` instead of
`Backplate-3.2` *(cuckoo; the SDK's `bplink` is raw)*.

## Frames

Every message, in both directions, is one frame *(both)*:

```
d5 aa 96 | command u16le | length u16le | payload (length bytes) | CRC u16le
```

The CRC is CRC-16/XMODEM (CRC-CCITT, polynomial 0x1021, initial value 0) over the
command, length and payload *(both)*. For example, the keep-alive `0x83` is
`d5 aa 96 83 00 00 00 e4 46`, and the reset `0xff` is `d5 aa 96 ff 00 00 00 a3 4b`.

cuckoo-nest describe frames *from* the backplate as starting `d5 d5 aa 96`. The
SDK simply hunts for `d5 aa 96`, so an extra leading `d5` is skipped like any other
stray byte (`NestGen2.Backplate.Frame`).

## Start-up

What Nest's own software does each time it opens the line (captured 2026-10-03,
and what the SDK does) *(✓)*:

1. `c0 00000000`, `85`, `83`, `8c`.
2. Flush, then a 100 ms serial **BREAK**, then `ff` (reset). The backplate
   restarts and sends `0001 "BRK"`, its firmware banner, a `*sense ...` line, and
   **`0004`** (13 bytes).
3. Echo the `0004` payload back as `8f`, then `83`, `90`.
4. Queries, each answered with text: `98` → `0018` firmware, `99` → `0019` build,
   `9d` → `001d`, `9b` → `001b` hardware, `9c` → `001c` bootloader, `9f` →
   `001f` serial, `9e` → `001e` model.
5. `c0 00000000` ("set power steal mode" *(cuckoo)*). Readings start.

cuckoo-nest found a shorter version works (BREAK, `ff`, wait for "BRK", then
`8f`, `83`, `90`, the queries and `c0`) and that the backplate stops answering if
the sequence doesn't arrive within about a second *(cuckoo)*. Without it, a
backplate that has been reset or lost power stays silent, and the display's
green light blinks *(✓)*.

## Keeping in touch

- **Readings:** after start-up the backplate sends ambient light (`000a`) and the
  proximity level (`0007`) about once a second, and PIR events (`0005`) as they
  happen *(both)*.
- **Buffers:** every 30 s the display sends `83`, then `a2`; the backplate replies
  with what it has collected (`0022` climate, `0023`, `000c`, `0038`, `002b`, ...)
  and ends with `002f`; the display answers `a3` *(both; cuckoo report `83`
  every ~15 s)*.
- **Watchdog:** if the backplate hears nothing for about 36 minutes it
  power-cycles the display *(✓)*.
- **Restarts:** the backplate restarts now and then (a loose display on its base,
  or a power blip), printing `BRK`, the banner and, with no heating system,
  `*HVAC power lost`, then `0004` again; answering that `0004` as at start-up
  brings it back *(✓)*.

## Sleep

How Nest's own software keeps within the backplate's power budget (captured
2026-10-13, and what `NestGen2.Power`'s deep sleep does) *(✓)*:

1. **Going to sleep**, the display sends: `c2 0000` + a low-temperature
   threshold (hundredths of °C, u16le) + `0080`, `b5 0f00`, `b3 ffffffff`,
   **`b9`** = light thresholds, **`ba 000000000000`**, **`a4`** = wake mask, and
   **`a1` = seconds it intends to sleep** (u16le), then suspends to RAM *(✓)*.
   - **`a4`, the wake mask** (u16le): which events may wake the display, with
     the bits in the table below *(code; ✓ for the bits we have seen)*. Nest's
     software always sets timer, buffers full, temperature, light, humidity,
     vergence and errors (`0x0567`), and adds motion, battery and proximity
     according to its settings; ours sent `0x07e7`. The SDK sets the base's
     own five (timer, buffers full, vergence, battery, errors: `0x0703`), plus
     near-PIR for `:motion` and light for `:light` in `wake_sources`.
   - **`b9`, the light thresholds**: u16le low, u16le high, in the same counts
     as `000a`; the base wakes the display when the light goes below the low
     one or above the high one, and `ffff` turns the high one off *(code, ✓)*.
     Nest's software set `0`/`2271` in a dim room (about 300-450 counts) and
     `1444`/`ffff` in daylight (about 15,000). The SDK sets them
     `light_wake_jump_pct` (and at least `light_wake_min_delta` counts) either
     side of the last reading, or off without `:light`.
   - **`c2`**: Nest's software sent 15.51 °C and 16.48 °C; below it, with the
     temperature bit in the mask, the base wakes the display every 30 s
     (reason `0x0004`, seen on a cold morning), presumably so a thermostat can
     decide about heating. The SDK sends 5 °C and leaves that bit off *(✓)*.
2. The backplate goes quiet, keeping its readings, until that time is up or it
   has a reason to wake the display (it does so over the serial line).
3. **Waking**, the display sends `83`; the backplate answers **`0014`**, the wake
   reason, with the same bits as the mask (`0` seen too), then `a2` brings what
   it kept while the display slept, and `a3` resumes the readings.

| Bit | Wake reason | Seen |
|---|---|---|
| `0x0001` | Timer | ✓ |
| `0x0002` | Buffers full | |
| `0x0004` | Temperature below the `c2` threshold | ✓ |
| `0x0008` | PIR | |
| `0x0010` | Proximity | |
| `0x0020` | Light past a `b9` threshold | ✓ |
| `0x0040` | Humidity | |
| `0x0080` | Near PIR: someone moved near it (Nest's software also checks a "TP" reason on this bit) | ✓ |
| `0x0100` | "Vergence" | |
| `0x0200` | Battery | ✓ |
| `0x0400` | Errors | |
| `0x0800` | "HE" | |

On a desk stand, with the display awake all the time the battery fell about
70 mV an hour; sleeping like this, it rose about 290 mV an hour.

## Messages

### From the backplate

| ID | Name | Payload | Source |
|---|---|---|---|
| `0001` | Text | ASCII: `BRK`, banner, `*sense ...`, `*HVAC power lost` | both |
| `0002` | Climate | i16le temperature (1/100 °C), u16le humidity (1/10 %) | both |
| `0004` | Hello / FET presence | 13 bytes; echo it back as `8f` | ✓ (cuckoo: "FET presence") |
| `0005` | PIR event | byte 0 near, byte 1 far (non-zero = movement), all zero = cleared | ✓ |
| `0007` | Proximity level | u16le, 0 when nothing is near | ✓ (cuckoo: "proximity sensor") |
| `0009` | FET presence | 15 bytes | cuckoo |
| `000a` | Ambient light | u16le counts | both |
| `000b` | Backplate state | bytes 6-7 input mV (0 when unpowered), 12-13 battery mV | ✓ (cuckoo: 8-9 Vin/100, 10-11 Vop/1000, 12-13 Vbat/1000) |
| `000c` | Raw sensor ADC | 0-1 PIR raw, 10-11 ambient IR, 12-13 ambient visible | cuckoo |
| `0010` | TFE id | 3 bytes | both |
| `0014` | Wake reason | u16le flags, as the wake mask (see Sleep) | ✓, code |
| `0018` | Firmware version | ASCII | both |
| `0019` | Build info | ASCII | both |
| `001b` | Hardware version | ASCII | ✓ |
| `001c` | Bootloader | ASCII | ✓ |
| `001d` | Model / BSL id | 2 bytes | both |
| `001e` | Model name | ASCII, `Backplate-3.2` | both |
| `001f` | Serial number | ASCII | ✓ |
| `0022` | Buffered climate | repeated `0002` records | both |
| `0023` | Board temperatures | three i16le, 1/100 °C | ✓ (cuckoo: "PIR motion event") |
| `0025` | Proximity event | 2 bytes | cuckoo |
| `0027` | Proximity detail | 8 bytes | cuckoo |
| `002b` | Power status | per record: u16 0, battery mV, supply limit (120), input mV | ✓ |
| `002f` | End of buffers | 2 bytes | both |
| `0038` | Unknown, in buffers | | both |

### To the backplate

| ID | Name | Payload | Source |
|---|---|---|---|
| `0082` | FET control (switch the heating outputs) | | cuckoo |
| `0083` | Keep-alive / status request | | both |
| `0085`, `008c` | Sent at start-up | | ✓ |
| `008f` | Answer to `0004` | the `0004` payload | both |
| `0090` | Get TFE id | | both |
| `0098`–`009f` | Queries (see Start-up) | | both |
| `00a1` | Sleep for (part of the sleep notice) | u16le seconds | ✓ |
| `00a2` / `00a3` | Request buffers / acknowledge their end | | both |
| `00c2` | Sleep notice: low-temperature threshold | `0000`, u16le 1/100 °C, `0080` | ✓ |
| `00a4` | Wake mask | u16le bits (see Sleep) | ✓, code |
| `00b9` | Light thresholds | u16le low, u16le high (`ffff` = off) | ✓, code |
| `00b3`, `00b5`, `00ba` | Sleep notice (see Sleep) | | ✓ |
| `00b1` | Temperature lock | | cuckoo |
| `00c0` | Set power steal mode | `00000000` | both |
| `00ff` | Reset | | both |

Corrections and additions are welcome: open an issue or a pull request, or
contribute to the cuckoo-nest wiki.

## Credits

The cuckoo-nest project's [backplate wiki](https://github.com/cuckoo-nest/wiki/tree/main/backplate),
in particular the [protocol](https://github.com/cuckoo-nest/wiki/blob/main/backplate/Protocol.md)
and [hardware](https://github.com/cuckoo-nest/wiki/blob/main/backplate/Hardware.md) pages by
[z3ugma](https://github.com/z3ugma) and the UK/EU backplate and Heat Link pages by
[wian007](https://github.com/wian007), and [jfarre20](https://github.com/jfarre20)'s
`ttyproxy` used in their investigation. The facts above credited to cuckoo come
from their pages, restated in our own words; their wiki has no licence, so none of
its text or images are copied here. They in turn build on earlier work by
[GTVHacker](https://web.archive.org/web/20141023183423/http://wiki.gtvhacker.com/index.php/Nest_Hacking),
[exploitee.rs](https://wiki.exploitee.rs/index.php/Nest_Hacking) and Luke Dashjr's
[freeabode](https://web.archive.org/web/20141023183423/http://luke.dashjr.org/programs/freeabode/kindling/NestDecode.pl)
tools.

The ✓ findings come from capturing Nest's own software on our units (start-up on
2026-10-03, sleep and charging on 2026-10-13) and from running the SDK on them.

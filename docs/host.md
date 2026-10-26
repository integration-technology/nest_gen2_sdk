# Running your app on a computer

You can run a nest_gen2 app on your own computer instead of the Nest, and see
its screen in a browser. It's for developing and testing screens: change the
code, restart, look, without building for the Nest or deploying.

The app runs unchanged. With `target: :host` the SDK starts as usual but touches
no hardware ([architecture.html](architecture.html) draws both side by side):

| On the Nest | On the host |
|---|---|
| Screen (`/dev/fb0`) | drawn in memory; shown in the browser viewer |
| Ring and press | the viewer (mouse wheel, arrow keys, click) or `NestGen2.Host` |
| Motion sensor | the viewer's "Walk past" button, or `NestGen2.Host.motion/1` |
| Temperature and humidity | a steady 20 °C / 45 %, changed with `NestGen2.Host.climate/2` |
| Backlight, piezo | ignored |
| Deep sleep | never: the computer doesn't suspend |
| Clock (NTP) | left alone: your computer keeps its own time |
| Wi-Fi | unavailable |
| Storage | `~/.nest_gen2_sdk/data` instead of the Nest's flash |

The screen still goes to sleep after the idle timeout, as on the Nest; the
viewer shows it dimmed. Press the ring or "Walk past" to wake it.

Network fetches are real: an app that fetches bus times fetches real bus times.

## One-time setup

1. **A C compiler** (`cc`, e.g. from `build-essential` or Xcode's command-line
   tools). In your app's folder run:

   ```
   mix nest_gen2.host
   ```

   It builds the text renderer for your computer into `~/.nest_gen2_sdk/bin` and
   checks the fonts.

2. **The fonts.** The SDK draws text with Nest's own Akkurat fonts, which are
   commercially licensed, so they don't ship with the SDK. Copy them from your
   own Nest (while it's awake, i.e. with the screen on):

   ```
   mkdir -p ~/.nest_gen2_sdk/fonts
   for f in AkkuratNest-Bold.ttf AkkuratNest-Regular.ttf; do
     ssh root@<nest-address> "cat /nestlabs/share/fonts/$f" > ~/.nest_gen2_sdk/fonts/$f
   done
   ```

   Any TrueType font works too if you give it those names, or set
   `config :nest_gen2, font_dir: "/path/to/fonts"`.

## Running

Run your app with the SDK told it's on a computer, e.g.:

```
elixir --erl "-nest_gen2 target host" -S mix run --no-halt
```

or in your app's `config/dev.exs`:

```elixir
config :nest_gen2, target: :host
```

Then open <http://localhost:4000>. Turn the ring with the mouse wheel over it,
by dragging, or with ← and →; click it, or press Space, to press it. The buttons
give a double click, a long press and someone walking past.

Use the same Erlang/Elixir as for the Nest (`platform/host_env.sh`), or any
newer one: on the host nothing has to load on the Nest.

### From another computer

The viewer listens only on this computer (`127.0.0.1`). To see it from, say, a
laptop that can reach this computer over SSH (Tailscale works), forward the
port and open <http://localhost:4000> on the laptop:

```
ssh -L 4000:localhost:4000 <this-computer>
```

Or listen on another address with
`config :nest_gen2, host_viewer_ip: {0, 0, 0, 0}`. Then anyone who can reach
that port can press your app's buttons, so keep it to a trusted network.

### Showing it publicly

To put the screen on a public website, make the viewer watch-only:

```elixir
config :nest_gen2, host_viewer_controls: false
```

The page then has no buttons and ignores the mouse and keyboard, and the viewer
refuses every press, turn and climate change (`403`), so visitors can't drive
your app or each other's view: everyone sees the same screen. Your app has to
move between its screens by itself. Replies may be kept for a second by a cache
in front, such as a CDN, and the screen is only encoded when it changes, so
many visitors cost about the same as one.

Run it behind a reverse proxy or tunnel that adds HTTPS; the viewer itself
speaks plain HTTP.

## Settings

| Config | Default | |
|---|---|---|
| `target` | `:nest` | `:host` to run on a computer |
| `host_viewer` | `true` | start the browser viewer on the host |
| `host_viewer_port` | `4000` | |
| `host_viewer_ip` | `{127, 0, 0, 1}` | address it listens on |
| `host_viewer_controls` | `true` | `false`: watch-only, for showing publicly |
| `host_climate` | `{20.0, 45.0}` | simulated °C and % humidity |
| `font_dir` | `~/.nest_gen2_sdk/fonts` on the host | where the TrueType fonts are |
| `storage_dir` | `~/.nest_gen2_sdk/data` on the host | `NestGen2.Storage`'s files |

To start from the settings your Nest has, copy its storage across (leave out
anything secret you'd rather not have on the computer):

```
mkdir -p ~/.nest_gen2_sdk/data/<app>
ssh root@<nest-address> "cd /media/scratch/.nest_gen2_sdk/data/<app> && tar cf - *.term" |
  tar xf - -C ~/.nest_gen2_sdk/data/<app>
```

## From code and tests

`NestGen2.Host` drives the simulated hardware: `turn/1`, `step/1`, `click/0`,
`double_click/0`, `long_press/0`, `motion/1`, `climate/2`, and `screenshot/0`
for the screen as a PNG. They produce the same events as the real hardware.
The viewer's endpoints do the same over HTTP, for scripts:

```
curl -o screen.png http://localhost:4000/screen.png
curl -X POST "http://localhost:4000/step?dir=cw"
curl -X POST http://localhost:4000/click
```

`NestGen2.Display.snapshot/0` works on the Nest too: it returns what the
screen shows.

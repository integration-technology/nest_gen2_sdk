# hello_nest

The smallest useful [nest_gen2](../../README.md) app, as a starting point for
your own: turn the ring to change the number (with a click from the piezo),
press to reset it, and the room temperature shows underneath.

Copy this folder anywhere, then deploy it to a Nest set up with
`platform/install.sh <nest-address> --app hello_nest`:

    platform/deploy_app.sh path/to/hello_nest

See [docs/install.md](../../docs/install.md) for the whole route, and
[docs/api.md](../../docs/api.md) for what the SDK offers.

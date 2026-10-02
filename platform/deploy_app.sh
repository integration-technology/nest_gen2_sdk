#!/bin/sh
# Deploys an app built on nest_gen2 to the Nest: the app and its dependencies,
# never the SDK itself (that is installed and versioned separately).
#
# Usage: deploy_app.sh <app_dir> [--no-test]
#   e.g. platform/deploy_app.sh ../foxbus
#
# Which Nest: NEST_HOST (its address or name) and optionally NEST_KEY (an SSH
# private key; otherwise ssh's defaults and agent are used), from the
# environment or from ~/.config/nest_gen2/target (override with NEST_TARGET),
# a shell file outside the repository such as:
#     NEST_HOST=<nest-address>
#     NEST_KEY=$HOME/.ssh/<nest-key>
#
# Steps: mix test, prod build, check the app was built against the SDK version
# installed on the Nest, upload <app> and its other deps to <install>/apps,
# sync the flash, restart the app (app_watchdog.sh relaunches it) and show the
# first lines of its log.
set -e

APP_DIR=${1:?usage: deploy_app.sh <app_dir> [--no-test]}
RUN_TESTS=yes
[ "$2" = "--no-test" ] && RUN_TESTS=no

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/host_env.sh"

TARGET=${NEST_TARGET:-$HOME/.config/nest_gen2/target}
# shellcheck disable=SC1090
[ -z "$NEST_HOST" ] && [ -f "$TARGET" ] && . "$TARGET"
[ -n "$NEST_HOST" ] || { echo "Set NEST_HOST, or put NEST_HOST=<nest-address> in $TARGET"; exit 1; }
BASE=/media/scratch/.nest_gen2_sdk
SDK_APP=nest_gen2

nest() {
  # shellcheck disable=SC2086
  ssh -F /dev/null ${NEST_KEY:+-o IdentityFile="$NEST_KEY" -o IdentitiesOnly=yes} \
    -o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ecdsa-sha2-nistp521 \
    -o ConnectTimeout=15 -o LogLevel=ERROR "root@$NEST_HOST" "$@"
}

cd "$APP_DIR"
APP=$(MIX_ENV=prod mix run --no-start --no-compile -e 'IO.write(Mix.Project.config()[:app])' 2>/dev/null ||
  MIX_ENV=prod mix run --no-start -e 'IO.write(Mix.Project.config()[:app])')
[ -n "$APP" ] || { echo "could not read the app name from $APP_DIR/mix.exs"; exit 1; }
REV=$(git describe --always --dirty 2>/dev/null || echo unknown)
echo "== $APP ($REV)"

if [ "$RUN_TESTS" = yes ]; then
  mix test
fi
MIX_ENV=prod mix compile

vsn() { sed -n 's/.*{vsn,"\([^"]*\)"}.*/\1/p' "$1" | head -1; }
BUILT_SDK=$(vsn "_build/prod/lib/$SDK_APP/ebin/$SDK_APP.app")
DEVICE_SDK=$(nest "sed -n 's/.*{vsn,\"\\([^\"]*\\)\"}.*/\\1/p' $BASE/apps/$SDK_APP/ebin/$SDK_APP.app" | head -1)
echo "== SDK: built against $BUILT_SDK, installed on the Nest $DEVICE_SDK"
if [ "$BUILT_SDK" != "$DEVICE_SDK" ]; then
  echo "!! SDK version mismatch: install nest_gen2 $BUILT_SDK on the Nest first, or build against $DEVICE_SDK."
  exit 1
fi

# The app and every dependency except the SDK, with priv/ files copied
# rather than symlinked.
LIBS=""
for d in _build/prod/lib/*/; do
  name=$(basename "$d")
  [ "$name" = "$SDK_APP" ] && continue
  LIBS="$LIBS $name/ebin"
  [ -e "$d/priv" ] && LIBS="$LIBS $name/priv"
done
echo "== uploading:$LIBS"
STAMP="$REV deployed $(date -u '+%Y-%m-%dT%H:%M:%SZ') by $(id -un)"
# shellcheck disable=SC2086
tar -C _build/prod/lib -chf - $LIBS |
  nest "mkdir -p $BASE/apps && tar -C $BASE/apps -xf - && echo '$STAMP' > $BASE/apps/$APP/DEPLOYED && sync"

echo "== restarting $APP"
# app_watchdog.sh relaunches it within 5 s with a new pid and a fresh log.
# SIGTERM asks the VM to stop cleanly; if it hasn't within 15 s, SIGKILL.
nest "OLD=\$(cat $BASE/$APP.pid 2>/dev/null); [ -n \"\$OLD\" ] && kill \$OLD 2>/dev/null
for i in \$(seq 15); do [ -d /proc/\$OLD ] || break; sleep 1; done
[ -d /proc/\$OLD ] && { echo '   (no clean stop after 15 s: SIGKILL)'; kill -9 \$OLD; }
for i in \$(seq 60); do
  sleep 1; NEW=\$(cat $BASE/$APP.pid 2>/dev/null)
  [ -n \"\$NEW\" ] && [ \"\$NEW\" != \"\$OLD\" ] && [ -d /proc/\$NEW ] && break
done
for i in \$(seq 30); do
  sleep 1; grep -q 'clock checked\\|start failed\\|rror' $BASE/$APP.log 2>/dev/null && break
done
[ -d /proc/\$NEW ] || echo '!! $APP is not running'
tail -n 8 $BASE/$APP.log"
echo "== $APP $REV is on the Nest"

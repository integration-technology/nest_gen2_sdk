#!/bin/sh
# Installs the nest_gen2 platform on a Nest Learning Thermostat (2nd gen) that
# has been flashed with No Longer Evil. Run it on your computer, with the Nest
# on the same network:
#
#   platform/install.sh <nest-address> [--app NAME] [--runtime FILE] [--key FILE] [--no-reboot]
#   platform/install.sh <nest-address> --check     (only report what's running)
#
#   --app NAME      the app the Nest starts at boot (default: foxbus); deploy it
#                   afterwards with platform/deploy_app.sh
#   --runtime FILE  a runtime bundle you have already downloaded
#   --key FILE      SSH key for the Nest (default ~/.ssh/nest_gen2, created if
#                   missing; the Nest's SSH server needs an ECDSA or RSA key)
#   --no-reboot     prepare everything but don't restart the Nest
#   --check         change nothing; show whether the platform is running
#
# What it does, in order (each step says what it's doing; nothing is changed
# before step 4):
#   1. SSH key login (asks for the No Longer Evil root password once)
#   2. checks it's a 2nd-gen Nest with room for the runtime
#   3. downloads the runtime (Erlang/OTP 26 + Elixir 1.17) and checks its sha256
#   4. copies the runtime and the platform scripts to /media/scratch/.nest_gen2_sdk
#   5. saves your Wi-Fi network for the SDK's own Wi-Fi (asks for its password,
#      which is typed into the Nest, not stored on this computer)
#   6. changes /etc/init.d/rcS to start the app instead of Nest's software, keeping
#      the original as /etc/init.d/rcS.stock (platform/uninstall.sh puts it back)
#   7. restarts the Nest and checks everything came up
#
# Safe to run again: it skips what's already done and re-applies the rest.
set -e

RUNTIME_NAME=nest_gen2-runtime-otp26.2.5.13-elixir1.17.3-armv7-1
RUNTIME_URL=https://github.com/integration-technology/nest_gen2_sdk/releases/download/runtime-1/$RUNTIME_NAME.tar.gz
RUNTIME_SHA256=15d4142e6a1e9c244d7c00cedd94516bcf05aa94ad5f57d2cb1e2ef6744a62fa
B=/media/scratch/.nest_gen2_sdk
MIN_FREE_KB=60000

HERE=$(cd "$(dirname "$0")" && pwd)
SDK=$(dirname "$HERE")

HOST=
APP=foxbus
RUNTIME=
KEY=$HOME/.ssh/nest_gen2
REBOOT=yes
CHECK=no
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP=$2; shift ;;
    --runtime) RUNTIME=$2; shift ;;
    --key) KEY=$2; shift ;;
    --no-reboot) REBOOT=no ;;
    --check) CHECK=yes ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    -*) echo "unknown option $1"; exit 1 ;;
    *) HOST=$1 ;;
  esac
  shift
done
[ -n "$HOST" ] || { echo "usage: platform/install.sh <nest-address> [options]   (--help for more)"; exit 1; }

say() { printf '\n== %s\n' "$*"; }
fail() { printf '\n!! %s\n' "$*" >&2; exit 1; }

SSH_OPTS="-F /dev/null -o IdentityFile=$KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR"
# shellcheck disable=SC2086
nest() { ssh $SSH_OPTS -o BatchMode=yes "root@$HOST" "$@"; }
# shellcheck disable=SC2086
nest_tty() { ssh $SSH_OPTS -t "root@$HOST" "$@"; }
# Copies a local file to the Nest (no scp/sftp there): nest_put <file> <dest> [mode]
nest_put() {
  nest "cat > '$2.new' && chmod ${3:-644} '$2.new' && mv '$2.new' '$2'" < "$1"
}

# What's running on the Nest, one line each.
check_nest() {
  nest "sh -s $APP" < "$HERE/nest_check.sh"
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

if [ "$CHECK" = yes ]; then
  check_nest
  exit 0
fi

# --- 1. SSH key -------------------------------------------------------------
say "1/7 SSH key login to root@$HOST"
if [ ! -f "$KEY" ]; then
  echo "Creating an SSH key for the Nest: $KEY"
  mkdir -p "$(dirname "$KEY")"
  ssh-keygen -q -t ecdsa -b 521 -N "" -C "nest_gen2" -f "$KEY"
fi
if nest true 2>/dev/null; then
  echo "Key login works."
else
  echo "Adding the key to the Nest. Type the root password when asked:"
  echo "No Longer Evil's default is  nolongerevil"
  # shellcheck disable=SC2086
  ssh -F /dev/null -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive "root@$HOST" \
    'mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' \
    < "$KEY.pub" || fail "Couldn't log in with the password. Is $HOST the Nest, and is it flashed with No Longer Evil?"
  nest true || fail "The key was added but key login still fails."
  echo "Key login works."
fi

# --- 2. Check the Nest -----------------------------------------------------
say "2/7 Checking the Nest"
MODEL=$(nest "sed -n 's/.*nlmodel=\([^ ]*\).*/\1/p' /proc/cmdline")
KERNEL=$(nest "uname -r")
FREE_KB=$(nest "df -k /media/scratch | awk 'NR==2 {print \$4}'")
HAVE_RUNTIME=$(nest "head -1 $B/RUNTIME 2>/dev/null" || true)
echo "Display model: ${MODEL:-unknown}   kernel: $KERNEL   free in /media/scratch: $((FREE_KB / 1024)) MB"
case "$MODEL" in
  Display-2.*) ;;
  *) fail "This doesn't look like a 2nd-generation Nest (display model '$MODEL', expected Display-2.x)." ;;
esac
[ "$KERNEL" = 2.6.37 ] || echo "Note: expected kernel 2.6.37; carrying on."
if [ "$HAVE_RUNTIME" != "$RUNTIME_NAME" ] && [ "$FREE_KB" -lt "$MIN_FREE_KB" ]; then
  fail "Not enough free space in /media/scratch ($((FREE_KB / 1024)) MB; the runtime needs about $((MIN_FREE_KB / 1024)) MB)."
fi

# --- 3. Runtime -------------------------------------------------------------
say "3/7 Runtime ($RUNTIME_NAME)"
if [ "$HAVE_RUNTIME" = "$RUNTIME_NAME" ]; then
  echo "Already on the Nest."
else
  if [ -z "$RUNTIME" ]; then
    CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/nest_gen2
    RUNTIME=$CACHE/$RUNTIME_NAME.tar.gz
    if [ ! -f "$RUNTIME" ]; then
      mkdir -p "$CACHE"
      echo "Downloading $RUNTIME_URL"
      curl -fL --progress-bar -o "$RUNTIME.part" "$RUNTIME_URL" || fail "Download failed."
      mv "$RUNTIME.part" "$RUNTIME"
    fi
  fi
  [ "$(sha256 "$RUNTIME")" = "$RUNTIME_SHA256" ] ||
    fail "$RUNTIME doesn't match the expected sha256 $RUNTIME_SHA256 (delete it and run again to re-download)."
  echo "sha256 OK."
fi

# --- 4. Copy to the Nest ------------------------------------------------------
say "4/7 Copying to $B"
nest "mkdir -p $B"
if [ "$HAVE_RUNTIME" != "$RUNTIME_NAME" ]; then
  echo "Unpacking the runtime on the Nest (a few minutes: the flash is slow)..."
  nest "cd $B && rm -rf otp elixir && tar -xzf - && sync" < "$RUNTIME"
  nest "$B/otp/bin/erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().'" | grep -q '^26' ||
    fail "The runtime didn't start on the Nest."
  echo "Runtime installed; Erlang/OTP 26 runs."
fi
nest_put "$HERE/app_watchdog.sh" "$B/app_watchdog.sh" 755
nest_put "$HERE/wifi/wifi.sh" "$B/wifi.sh" 755
nest_put "$HERE/wifi/udhcpc.script" "$B/udhcpc.script" 755
nest_put "$SDK/priv/entropyd" "$B/entropyd" 755
nest sync
echo "Platform scripts copied."

# --- 5. Wi-Fi ---------------------------------------------------------------
say "5/7 Wi-Fi"
if nest "grep -q 'ssid=' $B/wpa_supplicant.conf 2>/dev/null"; then
  echo "Already set up:"
  nest "sed -n 's/^[[:space:]]*ssid=/  /p' $B/wpa_supplicant.conf"
  echo "(Add another network later with:  ssh root@$HOST sh $B/wifi.sh add 'Network name')"
else
  CURRENT=$(nest "iwgetid -r 2>/dev/null" || true)
  printf 'Wi-Fi network name for the Nest [%s]: ' "$CURRENT"
  read -r SSID
  SSID=${SSID:-$CURRENT}
  [ -n "$SSID" ] || fail "No network name given."
  nest "printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\n' > $B/wpa_supplicant.conf && chmod 600 $B/wpa_supplicant.conf"
  Q=$(printf '%s' "$SSID" | sed "s/'/'\\\\''/g")
  nest_tty "sh $B/wifi.sh add '$Q'" || fail "Saving the network failed."
fi

# --- 6. Boot script -----------------------------------------------------------
say "6/7 Boot script (/etc/init.d/rcS) to start $APP"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
nest "cat /etc/init.d/rcS" > "$TMP/rcS"
if ! nest "[ -f /etc/init.d/rcS.stock ]"; then
  grep -q nest_gen2_sdk "$TMP/rcS" && fail "rcS is already changed but there's no rcS.stock backup; not touching it."
  nest "cp /etc/init.d/rcS /etc/init.d/rcS.stock && sync"
  echo "Original saved as /etc/init.d/rcS.stock"
fi
awk -v APP="$APP" -f "$HERE/rcs_patch.awk" "$TMP/rcS" > "$TMP/rcS.new"
for want in "#\${INITDIR}/nestlabs start" "$B/entropyd" "$B/wifi.sh takeover" "$B/app_watchdog.sh $APP" "/bin/dropbear -g"; do
  grep -qF "$want" "$TMP/rcS.new" || fail "The new rcS is missing '$want'; not installing it."
done
if cmp -s "$TMP/rcS" "$TMP/rcS.new"; then
  echo "Already up to date."
else
  diff "$TMP/rcS" "$TMP/rcS.new" | sed -n 's/^[<>]/ &/p' || true
  nest_put "$TMP/rcS.new" /etc/init.d/rcS 750
  nest "sh -n /etc/init.d/rcS && sync" || fail "The new rcS has a syntax error; restore it with platform/uninstall.sh"
  echo "rcS updated."
fi

TARGET=${NEST_TARGET:-$HOME/.config/nest_gen2/target}
if [ ! -f "$TARGET" ]; then
  mkdir -p "$(dirname "$TARGET")"
  printf 'NEST_HOST=%s\nNEST_KEY=%s\n' "$HOST" "$KEY" > "$TARGET"
  echo "Saved $TARGET (deploy_app.sh reads it)."
fi

# --- 7. Restart -------------------------------------------------------------
if [ "$REBOOT" = no ]; then
  say "Done. Restart the Nest to switch over (hold the display down for 10 s)."
  exit 0
fi
say "7/7 Restarting the Nest"
nest "sync; (sleep 1; kill -TERM 1) > /dev/null 2>&1 &"
printf 'Waiting for it to go down'
i=0
while nest true 2>/dev/null && [ $i -lt 30 ]; do printf '.'; sleep 2; i=$((i + 1)); done
printf '\nWaiting for it to come back (about a minute)'
i=0
until nest true 2>/dev/null; do
  printf '.'; sleep 5; i=$((i + 1))
  [ $i -lt 48 ] || fail "The Nest hasn't come back after 4 minutes. If it has a new address, check your router; to undo, see platform/uninstall.sh."
done
echo
sleep 15
check_nest
say "Installed. Next: deploy $APP (see docs/install.md), e.g.
   platform/deploy_app.sh ../$APP"

#!/bin/sh
# Puts a Nest back to No Longer Evil's own software: restores the original
# /etc/init.d/rcS saved by install.sh and restarts the Nest.
#
#   platform/uninstall.sh <nest-address> [--purge] [--key FILE]
#
#   --purge     also delete /media/scratch/.nest_gen2_sdk (runtime, apps, saved
#               Wi-Fi networks, logs)
#
# Wi-Fi then goes back to Nest's connection manager and the network it had
# saved before; your SSH key stays installed.
set -e
B=/media/scratch/.nest_gen2_sdk
HOST=
KEY=$HOME/.ssh/nest_gen2
PURGE=no
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=yes ;;
    --key) KEY=$2; shift ;;
    -*) echo "unknown option $1"; exit 1 ;;
    *) HOST=$1 ;;
  esac
  shift
done
[ -n "$HOST" ] || { echo "usage: platform/uninstall.sh <nest-address> [--purge] [--key FILE]"; exit 1; }

# shellcheck disable=SC2086
nest() {
  ssh -F /dev/null -o IdentityFile="$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o ConnectTimeout=10 -o LogLevel=ERROR "root@$HOST" "$@"
}

nest "[ -f /etc/init.d/rcS.stock ]" ||
  { echo "No /etc/init.d/rcS.stock on the Nest: nothing to restore."; exit 1; }
nest "cp /etc/init.d/rcS.stock /etc/init.d/rcS && sync"
echo "Restored the original /etc/init.d/rcS."
if [ "$PURGE" = yes ]; then
  nest "rm -rf $B && sync"
  echo "Deleted $B."
fi
nest "sync; (sleep 1; kill -TERM 1) > /dev/null 2>&1 &"
echo "The Nest is restarting into its own software. Its address may change once"
echo "Nest's connection manager takes over Wi-Fi again."

#!/bin/sh
# Reads and writes an app's NestGen2.Storage values on the Nest from this
# computer, e.g. to give an app its first settings without editing files.
#
#   platform/storage.sh <app> list
#   platform/storage.sh <app> get <key>
#   platform/storage.sh <app> put <key> '<Elixir term>'
#   platform/storage.sh <app> delete <key>
#
#   e.g. platform/storage.sh foxbus put stops '[{:towards_town, "<atco-code>", "To Town"}]'
#
# The app reads values when it asks for them, so restart it (or wait for its
# next read) to pick up a change. Which Nest: as for deploy_app.sh.
set -e
APP=${1:?usage: storage.sh <app> list|get|put|delete [key] [term]}
CMD=${2:?usage: storage.sh <app> list|get|put|delete [key] [term]}
KEY=$3
HERE=$(cd "$(dirname "$0")" && pwd)
TARGET=${NEST_TARGET:-$HOME/.config/nest_gen2/target}
[ -z "$NEST_HOST" ] && [ -f "$TARGET" ] && . "$TARGET"
[ -n "$NEST_HOST" ] || { echo "Set NEST_HOST, or put NEST_HOST=<nest-address> in $TARGET"; exit 1; }
DIR=/media/scratch/.nest_gen2_sdk/data/$APP

nest() {
  # shellcheck disable=SC2086
  ssh -F /dev/null ${NEST_KEY:+-o IdentityFile="$NEST_KEY" -o IdentitiesOnly=yes} \
    -o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ecdsa-sha2-nistp521 \
    -o ConnectTimeout=15 -o LogLevel=ERROR "root@$NEST_HOST" "$@"
}

check_key() {
  echo "$KEY" | grep -Eq '^[a-z0-9_]{1,64}$' || { echo "keys are lowercase letters, digits and _"; exit 1; }
}

case "$CMD" in
  list)
    nest "ls $DIR 2>/dev/null | sed -n 's/\.term\$//p'"
    ;;
  get)
    check_key
    nest "cat $DIR/$KEY.term 2>/dev/null || cat $DIR/$KEY.term.bak 2>/dev/null" | sed 1d
    ;;
  put)
    check_key
    TERM_SRC=${4:?put needs a value, e.g. '%{idle_timeout_ms: 30_000}'}
    # Encoded here, with the same format and checksum as NestGen2.Storage.
    . "$HERE/host_env.sh"
    FILE=$(mktemp)
    trap 'rm -f "$FILE"' EXIT
    elixir -e '
      {value, _} = Code.eval_string(System.argv() |> hd())
      text = IO.chardata_to_string(:io_lib.format(~c"~tp.~n", [value]))
      IO.write(["%% nest_gen2 storage v1 crc32=", Integer.to_string(:erlang.crc32(text)), "\n", text])
    ' "$TERM_SRC" > "$FILE"
    sed 1d "$FILE"
    nest "mkdir -p $DIR && cat > $DIR/$KEY.term.tmp && { [ ! -f $DIR/$KEY.term ] || mv $DIR/$KEY.term $DIR/$KEY.term.bak; } && mv $DIR/$KEY.term.tmp $DIR/$KEY.term && sync" < "$FILE"
    echo "saved $APP/$KEY"
    ;;
  delete)
    check_key
    nest "rm -f $DIR/$KEY.term $DIR/$KEY.term.bak $DIR/$KEY.term.tmp && sync"
    echo "deleted $APP/$KEY"
    ;;
  *)
    echo "unknown command $CMD"; exit 1 ;;
esac

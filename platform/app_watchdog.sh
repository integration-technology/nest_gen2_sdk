#!/bin/sh
# Keeps exactly one BEAM running an app built on nest_gen2.
# Usage: app_watchdog.sh <app>     e.g. app_watchdog.sh foxbus
#
# Code: every $BASE/apps/<name>/ebin goes on the code path (the SDK in
# apps/nest_gen2 with its priv/, the app, and its dependencies).
# Settings: optional $BASE/<app>.args holds extra erl arguments, e.g. app env
# overrides such as:  -nest_gen2 calibration_file "/tmp/nest_climate"
#
# The VM writes its own pid to <app>.pid as it starts, and the app counts as
# running only while that pid is a beam.smp for this app; a pid left over from
# an earlier boot, or reused by another process, doesn't count. Only one
# watchdog runs per app (<app>.watchdog.pid).
APP=${1:?usage: app_watchdog.sh <app>}
BASE=/media/scratch/.nest_gen2_sdk
LOG=$BASE/watchdog.log
PIDFILE=$BASE/$APP.pid
LOCK=$BASE/$APP.watchdog.pid
LAUNCH_WAIT=60

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

is_running() {
  P=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$P" ] && [ "$(cat "/proc/$P/comm" 2>/dev/null)" = beam.smp ] &&
    tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null | grep -q "ensure_all_started($APP,"
}

# One watchdog per app.
W=$(cat "$LOCK" 2>/dev/null)
if [ -n "$W" ] && [ "$W" != "$$" ] && [ -d "/proc/$W" ] &&
  tr '\0' ' ' < "/proc/$W/cmdline" 2>/dev/null | grep -q "app_watchdog.sh $APP"; then
  log "watchdog for $APP already running as pid $W; exiting"
  exit 0
fi
echo $$ > "$LOCK"

log "watchdog starting for $APP"

while true; do
  if ! is_running; then
    CODE_PATHS="-pa $BASE/elixir/lib/elixir/ebin -pa $BASE/elixir/lib/logger/ebin"
    for d in "$BASE"/apps/*/ebin; do CODE_PATHS="$CODE_PATHS -pa $d"; done
    EXTRA=""
    [ -f "$BASE/$APP.args" ] && EXTRA=$(cat "$BASE/$APP.args")
    rm -f "$PIDFILE"
    # Keep the last run's log: after a crash or a reboot it is the evidence.
    [ -s "$BASE/$APP.log" ] && mv -f "$BASE/$APP.log" "$BASE/$APP.log.1"
    log "no running $APP, launching"
    # -noinput: a daemon with no console (-noshell still reads stdin).
    # multi_time_warp: Erlang time follows the system clock when NestGen2.Clock sets it.
    # The VM records its own pid, then starts the app as permanent: if the app
    # dies the VM halts and this loop restarts it.
    # shellcheck disable=SC2086
    eval setsid "\"$BASE/otp/bin/erl\"" +C multi_time_warp $CODE_PATHS -noinput $EXTRA \
      -eval "\"ok = file:write_file(\\\"$PIDFILE\\\", os:getpid()), case application:ensure_all_started($APP, permanent) of {ok, _} -> ok; E -> io:format(\\\"start failed: ~p~n\\\", [E]), halt(1) end\"" \
      "> \"$BASE/$APP.log\" 2>&1 < /dev/null &"
    # Give the VM time to start before judging it, so a slow start isn't
    # mistaken for a failure and launched twice.
    i=0
    while [ $i -lt $LAUNCH_WAIT ] && ! is_running; do
      sleep 1
      i=$((i + 1))
    done
    if is_running; then
      log "launched $APP as pid $(cat "$PIDFILE")"
    else
      log "launch of $APP failed after ${i}s (see $APP.log)"
    fi
  fi
  sleep 5
done

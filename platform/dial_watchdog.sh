#!/bin/sh
# Supervisor for the input-driven sleep/wake controller.
# Uses a pidfile so a slow "is it running" check can never launch a
# second instance racing the first over the same device files.
LOG=/media/scratch/.nest_gen2_sdk/watchdog.log
PIDFILE=/media/scratch/.nest_gen2_sdk/dial_control.pid

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

is_running() {
  [ -f "$PIDFILE" ] && [ -d "/proc/$(cat "$PIDFILE" 2>/dev/null)" ]
}

log "dial watchdog starting"

while true; do
  if ! is_running; then
    log "no running instance (pidfile check), relaunching dial_control"
    setsid /media/scratch/.nest_gen2_sdk/otp/bin/erl -pa /media/scratch/.nest_gen2_sdk -noshell -s dial_control main \
      > /media/scratch/.nest_gen2_sdk/dial_control_stdout.log 2>&1 < /dev/null &
    NEWPID=$!
    echo "$NEWPID" > "$PIDFILE"
    log "launched dial_control as pid $NEWPID"
  fi
  sleep 5
done

#!/bin/sh
# Wi-Fi without Nest's connection manager (connmand).
#
#   wifi.sh start      stop connmand, run wpa_supplicant on our config, run udhcpc
#   wifi.sh stop       stop ours
#   wifi.sh stock      stop ours and give Wi-Fi back to Nest's connmand
#   wifi.sh takeover   start, and go back to stock if the gateway isn't
#                      reachable within a minute (safe to run over SSH)
#
# Networks live in <install>/wpa_supplicant.conf; the SDK (NestGen2.Wifi)
# manages them through wpa_supplicant's control socket in /var/run/wpa_supplicant.
B=/media/scratch/.nest_gen2_sdk
IFACE=wlan0
CONF=$B/wpa_supplicant.conf
WPA_PID=/var/run/wpa_supplicant.pid
DHCP_PID=/var/run/udhcpc.pid
LOG=/tmp/nest_gen2_wifi.log

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

kill_named() { # comm name
  for p in /proc/[0-9]*; do
    [ "$(cat "$p/comm" 2>/dev/null)" = "$1" ] && kill "${p#/proc/}" 2>/dev/null
  done
}

running() { [ -f "$1" ] && [ -d "/proc/$(cat "$1" 2>/dev/null)" ]; }

start() {
  kill_named connmand
  kill_named wpa_supplicant
  kill_named udhcpc
  sleep 1
  rm -f "$WPA_PID" "$DHCP_PID" /var/run/wpa_supplicant/$IFACE
  ip link set "$IFACE" up
  /sbin/wpa_supplicant -B -s -i "$IFACE" -D nl80211 -c "$CONF" -P "$WPA_PID"
  "$B/udhcpc" -i "$IFACE" -b -S -s "$B/udhcpc.script" -p "$DHCP_PID"
  log "started (wpa_supplicant $(cat $WPA_PID 2>/dev/null), udhcpc $(cat $DHCP_PID 2>/dev/null))"
}

stop() {
  running "$DHCP_PID" && kill "$(cat $DHCP_PID)"
  running "$WPA_PID" && kill "$(cat $WPA_PID)"
  kill_named udhcpc
  kill_named wpa_supplicant
  rm -f "$WPA_PID" "$DHCP_PID"
  log "stopped"
}

stock() {
  stop
  sleep 1
  /etc/init.d/wpasupplicant monit_start
  /etc/init.d/connman monit_start
  log "back on stock connmand"
}

gateway_ok() {
  gw=$(ip route | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1)
  [ -n "$gw" ] && ping -c 1 -W 2 "$gw" >/dev/null 2>&1
}

takeover() {
  start
  i=0
  while [ $i -lt 12 ]; do
    sleep 5
    if gateway_ok; then log "takeover ok after $(( (i + 1) * 5 ))s"; return 0; fi
    i=$((i + 1))
  done
  log "takeover failed: gateway unreachable for 60s; reverting"
  stock
  return 1
}

case "$1" in
  start) start ;;
  stop) stop ;;
  stock) stock ;;
  takeover) takeover ;;
  *) echo "usage: $0 start|stop|stock|takeover"; exit 1 ;;
esac

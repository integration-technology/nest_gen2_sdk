#!/bin/sh
# Wi-Fi without Nest's connection manager (connmand).
#
#   wifi.sh start      stop connmand, run wpa_supplicant on our config, run udhcpc
#   wifi.sh stop       stop ours
#   wifi.sh stock      stop ours and give Wi-Fi back to Nest's connmand
#   wifi.sh takeover   start, and go back to stock if the gateway isn't
#                      reachable within a minute (safe to run over SSH)
#   wifi.sh guard      (started by start) every 30 s check the gateway; after
#                      3 minutes unreachable, restart wpa_supplicant from the
#                      saved config, so a failed network switch can't leave the
#                      Nest offline
#   wifi.sh add SSID   save another network (asks for its password, which isn't
#                      echoed or stored, only the derived key); the Nest joins it
#                      by itself whenever it's in range and no higher-priority
#                      saved network is. Run over `ssh -t`.
#
# Networks live in <install>/wpa_supplicant.conf; the SDK (NestGen2.Wifi)
# manages them through wpa_supplicant's control socket in /var/run/wpa_supplicant.
B=/media/scratch/.nest_gen2_sdk
IFACE=wlan0
CONF=$B/wpa_supplicant.conf
WPA_PID=/var/run/wpa_supplicant.pid
DHCP_PID=/var/run/udhcpc.pid
GUARD_PID=/var/run/nest_gen2_wifi_guard.pid
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
  running "$GUARD_PID" || (setsid "$0" guard </dev/null >/dev/null 2>&1 &)
}

restart_wpa() {
  running "$WPA_PID" && kill "$(cat $WPA_PID)"
  kill_named wpa_supplicant
  sleep 1
  rm -f "$WPA_PID" /var/run/wpa_supplicant/$IFACE
  /sbin/wpa_supplicant -B -s -i "$IFACE" -D nl80211 -c "$CONF" -P "$WPA_PID"
  sleep 10
  # Ask for a fresh lease on whatever network it joined.
  running "$DHCP_PID" && kill -USR2 "$(cat $DHCP_PID)" && kill -USR1 "$(cat $DHCP_PID)"
}

guard() {
  echo $$ > "$GUARD_PID"
  down=0
  while running "$WPA_PID" || [ $down -lt 6 ]; do
    sleep 30
    if gateway_ok; then
      down=0
    else
      down=$((down + 1))
      if [ $down -ge 6 ]; then
        log "guard: gateway unreachable for 3 minutes; restarting wpa_supplicant from saved config"
        restart_wpa
        down=0
      fi
    fi
  done
}

stop() {
  running "$GUARD_PID" && kill "$(cat $GUARD_PID)"
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

add() {
  ssid=$1
  [ -n "$ssid" ] || { echo "usage: $0 add SSID"; exit 1; }
  if grep -qF "ssid=\"$ssid\"" "$CONF"; then
    echo "\"$ssid\" is already saved"; exit 1
  fi
  printf 'Password for "%s" (blank for an open network): ' "$ssid"
  stty -echo 2>/dev/null; read -r pass; stty echo 2>/dev/null; echo
  if [ -z "$pass" ]; then
    printf '\nnetwork={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$ssid" >> "$CONF"
  else
    n=${#pass}
    [ "$n" -ge 8 ] && [ "$n" -le 63 ] || { echo "a WPA password is 8 to 63 characters"; exit 1; }
    # wpa_passphrase also writes the password as a comment: leave that out.
    printf '%s\n' "$pass" | wpa_passphrase "$ssid" | grep -v '^[[:space:]]*#' >> "$CONF" ||
      { echo "wpa_passphrase failed"; exit 1; }
  fi
  sync
  # Re-read the config: Wi-Fi drops for a few seconds and rejoins the best saved network.
  running "$WPA_PID" && kill -HUP "$(cat $WPA_PID)"
  log "added network \"$ssid\""
  echo "saved \"$ssid\""
}

case "$1" in
  start) start ;;
  stop) stop ;;
  stock) stock ;;
  takeover) takeover ;;
  guard) guard ;;
  add) add "$2" ;;
  *) echo "usage: $0 start|stop|stock|takeover|guard|add SSID"; exit 1 ;;
esac

#!/bin/sh
# Runs on the Nest (install.sh pipes it over SSH): one line per part of the
# platform, saying whether it's running.   sh nest_check.sh <app>
APP=${1:-foxbus}
B=/media/scratch/.nest_gen2_sdk

ok() { printf '  %-28s %s\n' "$1" "$2"; }

PS=/tmp/nest_check.$$
for p in /proc/[0-9]*; do
  echo "$(cat "$p/comm" 2>/dev/null) $(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)"
done > "$PS"

if grep -q '^entropyd' "$PS"; then ok entropyd running; else ok entropyd MISSING; fi
if grep -q "wpa_supplicant.*$B" "$PS"; then ok "Wi-Fi (SDK)" running
else ok "Wi-Fi (SDK)" "not running (see $B/wifi.log)"; fi
if grep -q "app_watchdog.sh $APP" "$PS"; then ok "app watchdog ($APP)" running
else ok "app watchdog ($APP)" MISSING; fi
if grep -q "ensure_all_started($APP," "$PS"; then ok "$APP" running
elif [ -d "$B/apps/$APP/ebin" ]; then ok "$APP" "NOT running (see $B/$APP.log)"
else ok "$APP" "not deployed yet"; fi
if grep -q '^nlclient' "$PS"; then ok "Nest's own software" "still running!"
else ok "Nest's own software" stopped; fi
ok "runtime" "$(head -1 "$B/RUNTIME" 2>/dev/null || echo missing)"
ok "address" "$(ip -4 addr show wlan0 | sed -n 's/.*inet \([0-9.]*\).*/\1/p')"
rm -f "$PS"

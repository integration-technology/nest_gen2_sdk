# Turns the Nest's own /etc/init.d/rcS into one that runs a nest_gen2 app.
# Used by install.sh (on the host, so it doesn't depend on the Nest's BusyBox).
#
#   awk -v APP=foxbus -f rcs_patch.awk rcS > rcS.new
#
# - comments out Nest's application services (nlmetrics, heartbeat, nlsleep,
#   nlshutdown, nestlabs, monit), leaving the system ones (syslog, watchdog,
#   networking, sshd, ...) alone
# - starts entropyd before networking, our Wi-Fi after it, and the app's
#   watchdog after dropbear
# - makes dropbear refuse root password logins (-g)
#
# Running it again on its own output gives the same result: lines it added
# earlier (anything mentioning the install folder) are dropped and re-added,
# so it can also switch the app.

BEGIN {
  B = "/media/scratch/.nest_gen2_sdk"
  if (APP == "") APP = "foxbus"
  split("nlmetrics heartbeat nlsleep nlshutdown nestlabs monit", names, " ")
  for (i in names) off["${INITDIR}/" names[i] " start"] = 1
}

index($0, B) > 0 { next }

{
  line = $0
  bare = line
  sub(/^#/, "", bare)
  if (bare in off) line = "#" bare
  if (line == "/bin/dropbear") line = "/bin/dropbear -g"
}

line == "${INITDIR}/networking start" {
  print "(setsid " B "/entropyd " B "/random-seed > /dev/null 2>&1 </dev/null &)"
  print line
  print "(setsid " B "/wifi.sh takeover > /dev/null 2>&1 </dev/null &)"
  next
}

line ~ /^\/bin\/dropbear/ {
  print line
  print "(setsid " B "/app_watchdog.sh " APP " > " B "/app_watchdog_stdout.log 2>&1 </dev/null &)"
  next
}

{ print line }

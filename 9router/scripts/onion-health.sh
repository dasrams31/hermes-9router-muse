#!/bin/bash
# onion-health.sh — keep Peka + Aeterra onion services online.
# Runs every 2 min via cron. Checks local apps, tor bootstrap, and
# end-to-end .onion reachability. Restarts what is broken. Logs actions.
# State: /home/hatch/workspace/onion-health/state
set -u
LOG=/home/hatch/workspace/onion-health/health.log
STATEDIR=/home/hatch/workspace/onion-health/state
mkdir -p "$STATEDIR"
PEKA=http://127.0.0.1:18092/
AETERRA=http://127.0.0.1:18093/
PEKA_ONION=http://pekaheqjbfgs3neiuyllbenxw7yimcfjainydksvko3ywvzzdtygh4id.onion/
AETERRA_ONION=http://aeterramwgvpn4cfqyv5hjwxx7dlo4adpwyvfufrhxw5jtwxac3o6zad.onion/
SOCKS=127.0.0.1:9050

log() { echo "$(date '+%F %T') $1" >> "$LOG"; }
failcount() { # $1=name -> increments, echoes count
  f="$STATEDIR/$1.fail"
  n=$(cat "$f" 2>/dev/null || echo 0)
  n=$((n+1)); echo "$n" > "$f"; echo "$n"
}
clearfail() { rm -f "$STATEDIR/$1.fail"; }

# --- 1. local apps ---
for svc in peka-social aeterra-provider; do
  if ! systemctl is-active -q "$svc" 2>/dev/null; then
    log "RESTART $svc (inactive)"
    systemctl restart "$svc" 2>/dev/null || true
  fi
done
if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$PEKA")" != "200" ]; then
  n=$(failcount peka-local)
  [ "$n" -ge 2 ] && { log "RESTART peka-social (local http fail x$n)"; systemctl restart peka-social; clearfail peka-local; }
else clearfail peka-local; fi
if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$AETERRA")" != "200" ]; then
  n=$(failcount aeterra-local)
  [ "$n" -ge 2 ] && { log "RESTART aeterra-provider (local http fail x$n)"; systemctl restart aeterra-provider; clearfail aeterra-local; }
else clearfail aeterra-local; fi

# --- 2. tor daemon ---
# NOTE: tor.service is a dummy master unit (always "active"); the real
# daemon is tor@default. Always check/restart tor@default.
TOR_UNIT="tor@default"
TOR_RESTART_FILE="$STATEDIR/tor-last-restart"
MIN_RESTART_INTERVAL=900  # do not restart tor more often than every 15 min

tor_restart() { # $1=reason
  last=$(cat "$TOR_RESTART_FILE" 2>/dev/null || echo 0)
  now_s=$(date +%s)
  if [ $((now_s - last)) -lt $MIN_RESTART_INTERVAL ]; then
    log "tor restart skipped (last restart $((now_s - last))s ago): $1"
    return 1
  fi
  log "RESTART $TOR_UNIT: $1"
  echo "$now_s" > "$TOR_RESTART_FILE"
  systemctl reset-failed "$TOR_UNIT" 2>/dev/null || true
  systemctl restart "$TOR_UNIT" 2>/dev/null || true
  sleep 10
  return 0
}

if ! systemctl is-active -q "$TOR_UNIT" 2>/dev/null; then
  tor_restart "daemon inactive" || true
fi
# bootstrap progress: restart tor if stuck below 100% for a while
pct=$(journalctl -u "$TOR_UNIT" --no-pager 2>/dev/null | grep -oP 'Bootstrapped \K[0-9]+' | tail -1)
pct=${pct:-0}
if [ "$pct" -lt 100 ]; then
  n=$(failcount tor-boot)
  if [ "$n" -ge 5 ]; then
    tor_restart "bootstrap stuck at ${pct}% x$n" && clearfail tor-boot || true
  fi
else clearfail tor-boot; fi

# --- 3. end-to-end .onion via tor socks (only if bootstrapped) ---
if [ "$pct" -eq 100 ]; then
  for name in "peka:$PEKA_ONION" "aeterra:$AETERRA_ONION"; do
    nname="${name%%:*}"; url="${name#*:}"
    code=$(curl -s --socks5-hostname "$SOCKS" --max-time 45 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    if [ "$code" != "200" ]; then
      n=$(failcount "onion-$nname")
      log "onion $nname unreachable (http $code) x$n"
      if [ "$n" -eq 2 ]; then
        # descriptor publish flakiness (local app ok, .onion times out):
        # a tor reload re-publishes HS descriptors. Cheap, non-disruptive,
        # and the proven manual fix. Try it before a full restart.
        # (2026-10-17: lowered from 3 to 2 after repeated flapping —
        #  guards are degraded, faster recovery matters more than caution)
        log "RELOAD $TOR_UNIT: onion $nname down x$n (re-publish HS descriptors)"
        systemctl reload "$TOR_UNIT" 2>/dev/null || true
      fi
      if [ "$n" -ge 5 ]; then
        # onions down for ~10 min: restart tor, but respect the cooldown
        # (frequent restarts prevent hidden services from ever stabilizing)
        tor_restart "onion $nname down x$n, local apps ok" && clearfail "onion-$nname" || true
      fi
    else
      clearfail "onion-$nname"
    fi
  done
fi

# --- 4. heartbeat (for uptime visibility) ---
echo "$(date +%s) pct=$pct" > "$STATEDIR/heartbeat"
# trim log to last 500 lines
tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true

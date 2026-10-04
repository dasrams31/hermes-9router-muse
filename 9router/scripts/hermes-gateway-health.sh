#!/bin/bash
# hermes-gateway-health.sh — watchdog for the Hermes Telegram gateway.
# Runs via systemd timer. Restarts the service when it is:
#   - not active, or
#   - active but its main process is gone/unresponsive, or
#   - alive but stuck in a Python error loop (tracebacks in last 5 min).
# Never touches anything outside this VM's hermes-gateway.service.
set -u
SVC="hermes-gateway.service"
LOGDIR=/home/hatch/workspace/9router-setup/logs
HLOG="$LOGDIR/hermes-gateway-health.log"
mkdir -p "$LOGDIR"
ts() { date -u +%FT%TZ; }

need_restart=""
reason=""

if [ "$(systemctl is-active "$SVC" 2>/dev/null)" != "active" ]; then
  need_restart=1; reason="service not active"
else
  pid=$(systemctl show "$SVC" -p MainPID --value 2>/dev/null)
  if [ -z "$pid" ] || [ "$pid" = "0" ] || ! kill -0 "$pid" 2>/dev/null; then
    need_restart=1; reason="main process missing/unresponsive (pid=$pid)"
  elif journalctl -u "$SVC" --since "5 minutes ago" --no-pager 2>/dev/null | grep -aqE "Traceback \(most recent call last\)"; then
    # Count distinct tracebacks; restart only on a real error loop (>=3).
    n=$(journalctl -u "$SVC" --since "5 minutes ago" --no-pager 2>/dev/null | grep -ac "Traceback (most recent call last)")
    if [ "$n" -ge 3 ]; then
      need_restart=1; reason="error loop: $n tracebacks in 5 min"
    fi
  fi
fi

if [ -n "$need_restart" ]; then
  echo "$(ts) HEALTH-FAIL: $reason — restarting $SVC" >> "$HLOG"
  systemctl restart "$SVC" 2>/dev/null
  sleep 5
  echo "$(ts) HEALTH: restart done, state=$(systemctl is-active "$SVC" 2>/dev/null)" >> "$HLOG"
else
  # Quiet heartbeat (only log state changes to avoid spam: touch a marker).
  echo "$(ts) ok" > "$LOGDIR/hermes-gateway-health.last"
fi

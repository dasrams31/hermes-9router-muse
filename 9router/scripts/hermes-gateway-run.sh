#!/bin/bash
# hermes-gateway-run.sh — hardened launcher for the Hermes Telegram gateway.
# - flock: prevents duplicate instances (manual or otherwise).
# - logs every (re)start with timestamp + reason.
# - verifies required config exists before launching.
set -u
LOCK=/run/hermes-gateway.lock
LOGDIR=/home/hatch/workspace/9router-setup/logs
RLOG="$LOGDIR/hermes-gateway-restarts.log"
mkdir -p "$LOGDIR"

# Exclusive non-blocking lock: a second instance exits immediately.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "$(date -u +%FT%TZ) REFUSED duplicate instance (lock held)" >> "$RLOG"
  echo "hermes-gateway: another instance is already running, refusing duplicate" >&2
  exit 1
fi

# Config sanity: fail fast with a clear message instead of a cryptic crash.
for f in /home/hatch/.hermes/.env /home/hatch/.hermes/proxy.env /home/hatch/.hermes/config.yaml; do
  if [ ! -f "$f" ]; then
    echo "$(date -u +%FT%TZ) ABORT missing config: $f" >> "$RLOG"
    echo "hermes-gateway: missing required config $f" >&2
    exit 1
  fi
done

echo "$(date -u +%FT%TZ) START pid=$$ (trigger: ${RESTART_REASON:-systemd})" >> "$RLOG"
exec /home/hatch/.local/bin/hermes gateway run --accept-hooks

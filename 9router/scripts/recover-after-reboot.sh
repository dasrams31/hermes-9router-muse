#!/bin/bash
# Recovery script: reinstalls 9Router stack after a VM replacement.
# /etc and /usr/lib are ephemeral; ~/workspace persists.
# Safe to run repeatedly (idempotent).
set -u
LOG=/tmp/9router-recovery.log
exec >>"$LOG" 2>&1
echo "=== recovery run: $(date -u +%FT%TZ)"

WS=/home/hatch/workspace/9router-setup

# 1. Reinstall 9Router if missing
if [ ! -f /usr/lib/node_modules/9router/cli.js ]; then
  echo "reinstalling 9router..."
  npm install -g 9router@0.5.95 2>&1 | tail -1
fi

# 2. Restore systemd units (.service and .timer)
for f in "$WS"/scripts/*.service "$WS"/scripts/*.timer; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  if ! cmp -s "$f" "/etc/systemd/system/$base" 2>/dev/null; then
    echo "restoring $base"
    cp "$f" /etc/systemd/system/
  fi
done
systemctl daemon-reload 2>/dev/null

# 2b. Ensure timers are enabled + started
for t in "$WS"/scripts/*.timer; do
  [ -f "$t" ] || continue
  base=$(basename "$t")
  if ! systemctl is-enabled "$base" >/dev/null 2>&1; then
    systemctl enable "$base" 2>/dev/null
  fi
  if [ "$(systemctl is-active "$base" 2>/dev/null)" != "active" ]; then
    systemctl start "$base" 2>/dev/null
  fi
done

# 3. Enable + start services (tunnel needs SSH approval on first connect)
for s in 9router muse-bridge hermes-gateway 9router-tunnel ramadanadipa-web ramadanadipa-tunnel blog-web blog-tunnel mc-portal mc-portal-tunnel agentarium agentarium-tunnel agentarium-logika7 agentarium-kacaubalau agentarium-dataneng agentarium-populasi; do
  if ! systemctl is-enabled "$s.service" >/dev/null 2>&1; then
    systemctl enable "$s.service" 2>/dev/null
  fi
  if [ "$(systemctl is-active "$s.service" 2>/dev/null)" != "active" ]; then
    echo "starting $s"
    systemctl start "$s.service" 2>/dev/null
  fi
done

# Agentarium story cleaner (Fase 2): timer tiap 15 menit, bukan service.
if ! systemctl is-enabled agentarium-story-cleaner.timer >/dev/null 2>&1; then
  cp ~/workspace/agentarium/systemd/agentarium-story-cleaner.service ~/workspace/agentarium/systemd/agentarium-story-cleaner.timer /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable agentarium-story-cleaner.timer 2>/dev/null
fi

# Agentarium backup PostgreSQL harian (Fase 4): timer tiap hari 03:30.
# (Juga tercakup loop generik *.service/*.timer di atas; blok ini pengaman eksplisit.)
if ! systemctl is-enabled agentarium-backup.timer >/dev/null 2>&1; then
  cp ~/workspace/9router-setup/scripts/agentarium-backup.service ~/workspace/9router-setup/scripts/agentarium-backup.timer /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable agentarium-backup.timer 2>/dev/null
fi

# Local AI stack: llama.cpp + models (2026-10-06)
# Restore model lokal setelah VM replacement
if [ ! -f "$HOME/workspace/llama-models/llama-3.2-1b-q4km.gguf" ]; then
  echo "local AI models missing, running installer..."
  bash "$WS/scripts/install-local-ai.sh" 2>&1 | tail -3
fi
# Pastikan services jalan
for s in llama-server smollm2-server; do
  if ! systemctl is-active "$s.service" >/dev/null 2>&1; then
    echo "starting $s.service"
    systemctl enable --now "$s.service" 2>/dev/null
  fi
done

# Backup timers: GitHub + semua repos (2026-10-06)
for t in agentarium-github-backup all-repos-backup; do
  if ! systemctl is-enabled "$t.timer" >/dev/null 2>&1; then
    echo "enabling $t.timer"
    systemctl enable --now "$t.timer" 2>/dev/null
  fi
done

echo "done: $(systemctl is-active 9router.service muse-bridge.service hermes-gateway.service 9router-tunnel.service 2>/dev/null | tr '\n' ' ')"

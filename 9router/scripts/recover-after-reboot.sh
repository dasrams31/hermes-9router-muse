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

# 2c. Kill stale non-systemd bridge processes (bridge-hook workers sometimes
# start `node bridge.js` manually during a reset gap; the leftover holds
# port 18089 and makes the systemd unit crash-loop with EADDRINUSE).
BRIDGE_MAINPID=$(systemctl show muse-bridge.service -p MainPID --value 2>/dev/null)
for pid in $(pgrep -f "node .*/bridge/bridge.js" 2>/dev/null); do
  if [ "$pid" != "$BRIDGE_MAINPID" ]; then
    echo "killing stale bridge process $pid (not systemd MainPID $BRIDGE_MAINPID)"
    kill "$pid" 2>/dev/null
  fi
done
sleep 2

# 3. Enable + start services (tunnel needs SSH approval on first connect)
for s in 9router muse-bridge hermes-gateway 9router-tunnel ramadanadipa-web ramadanadipa-tunnel blog-web blog-tunnel mc-portal mc-portal-tunnel agentarium agentarium-tunnel agentarium-logika7 agentarium-kacaubalau agentarium-dataneng agentarium-populasi threads-cms threads-cms-tunnel web-terminal web-terminal-tunnel peka-web peka-tunnel tor peka-social aeterra-provider; do
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


# Peka social Tor hidden service (2026-10-16)
# /etc/tor and /var/lib/tor are ephemeral; keys persist in ~/workspace.
if ! dpkg -l tor 2>/dev/null | grep -q "^ii"; then
  echo "reinstalling tor..."
  # Ensure package lists exist; drop dead mirrors first (cogentco hangs this network).
  if ! apt-cache policy tor 2>/dev/null | grep -q "Candidate:"; then
    for src in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources; do
      [ -f "$src" ] || continue
      if grep -q "mirror.cogentco.com" "$src" 2>/dev/null; then
        sed -i 's| http://mirror.cogentco.com/pub/linux/ubuntu||g' "$src"
        echo "removed dead mirror from $src"
      fi
    done
    timeout 180 apt-get update -qq 2>&1 | tail -2
  fi
  timeout 300 apt-get install -y -q tor 2>&1 | tail -1
fi
HSDIR=/var/lib/tor/peka-social
KEYSRC=/home/hatch/workspace/peka-social/tor-keys/pekaheqjbfgs3neiuyllbenxw7yimcfjainydksvko3ywvzzdtygh4id.onion
if [ -d "$KEYSRC" ]; then
  mkdir -p "$HSDIR"
  # only copy if keys differ/missing (avoid clobbering live keys needlessly)
  if ! cmp -s "$KEYSRC/hs_ed25519_secret_key" "$HSDIR/hs_ed25519_secret_key" 2>/dev/null; then
    echo "deploying peka-social onion keys"
    cp "$KEYSRC/hostname" "$KEYSRC/hs_ed25519_secret_key" "$KEYSRC/hs_ed25519_public_key" "$HSDIR/"
    chown -R debian-tor:debian-tor "$HSDIR"
    chmod 700 "$HSDIR"
    chmod 600 "$HSDIR/hs_ed25519_secret_key" "$HSDIR/hs_ed25519_public_key"
    chmod 644 "$HSDIR/hostname"
    systemctl restart tor 2>/dev/null || true
  fi
fi
# Aeterra onion keygen auto-resume (2026-10-16)
# Keeps bruteforcing the aeterra* vanity key until found. One-shot: once a
# *.onion dir exists in tor-keys/, this never fires again.
AKEYDIR=/home/hatch/workspace/aeterra-provider/tor-keys
if [ -z "$(ls -A "$AKEYDIR" 2>/dev/null)" ] && ! pgrep -f "mkp224o -d $AKEYDIR" >/dev/null 2>&1; then
  if [ -x /home/hatch/workspace/mkp224o-build/mkp224o/mkp224o ]; then
    echo "resuming aeterra onion keygen"
    cd /home/hatch/workspace/mkp224o-build/mkp224o
    setsid nohup ./mkp224o -d "$AKEYDIR" -n 1 aeterra >>/tmp/aeterra-keygen.log 2>&1 < /dev/null &
  fi
fi

if ! grep -q "HiddenServiceDir /var/lib/tor/peka-social/" /etc/tor/torrc 2>/dev/null; then
  echo "restoring peka-social torrc hidden service config"
  {
    echo ""
    echo "# Egress via runtime proxy (direct Tor TLS MITMed since 2026-10-16 reset)"
    echo "HTTPSProxy hatch-egress-proxy:3128"
    echo "HTTPSProxyAuthenticator hatch-runtime:4e5be8d77d964524ab561b6ac6f67693"
    echo ""
    echo "# Peka social - Tor hidden service (managed, see ~/workspace/peka-social/)"
    echo "HiddenServiceDir /var/lib/tor/peka-social/"
    echo "HiddenServicePort 80 127.0.0.1:18092"
  } >> /etc/tor/torrc
  systemctl restart tor 2>/dev/null || true
fi

echo "done: $(systemctl is-active 9router.service muse-bridge.service hermes-gateway.service 9router-tunnel.service 2>/dev/null | tr '\n' ' ')"

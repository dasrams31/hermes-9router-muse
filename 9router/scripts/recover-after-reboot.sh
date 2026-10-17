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
for s in 9router muse-bridge hermes-gateway 9router-tunnel ramadanadipa-web ramadanadipa-tunnel blog-web blog-tunnel mc-portal mc-portal-tunnel agentarium agentarium-tunnel agentarium-logika7 agentarium-kacaubalau agentarium-dataneng agentarium-populasi threads-cms threads-cms-tunnel web-terminal web-terminal-tunnel peka-web peka-tunnel tor peka-social aeterra-provider whisper jot snip onionatlas oracle qron senter-web senter-crawler; do
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

# Onion health watchdog: cek Peka + Aeterra tiap 2 menit, restart yang mati.
if ! systemctl is-enabled onion-health.timer >/dev/null 2>&1; then
  cp ~/workspace/9router-setup/scripts/onion-health.service ~/workspace/9router-setup/scripts/onion-health.timer /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now onion-health.timer 2>/dev/null
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
  if ! apt-cache policy tor 2>/dev/null | grep -q "Candidate: [0-9]"; then
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
# always enforce ownership (a root-owned HSDir crash-loops tor)
if [ -d "$HSDIR" ]; then
  chown -R debian-tor:debian-tor "$HSDIR" 2>/dev/null || true
  chmod 700 "$HSDIR" 2>/dev/null || true
  chmod 600 "$HSDIR/hs_ed25519_secret_key" "$HSDIR/hs_ed25519_public_key" 2>/dev/null || true
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
    echo "HiddenServiceNumIntroductionPoints 10"
  } >> /etc/tor/torrc
  systemctl restart tor 2>/dev/null || true
fi

# --- Aeterra .onion Provider hidden service (HS#2 -> 127.0.0.1:18093) ---
AKEYSRC=/home/hatch/workspace/aeterra-provider/tor-keys/aeterramwgvpn4cfqyv5hjwxx7dlo4adpwyvfufrhxw5jtwxac3o6zad.onion
if [ -d "$AKEYSRC" ]; then
  mkdir -p /var/lib/tor/aeterra-provider
  cp "$AKEYSRC/hostname" "$AKEYSRC/hs_ed25519_secret_key" "$AKEYSRC/hs_ed25519_public_key" /var/lib/tor/aeterra-provider/ 2>/dev/null || true
  chown -R debian-tor:debian-tor /var/lib/tor/aeterra-provider 2>/dev/null || true
  chmod 700 /var/lib/tor/aeterra-provider 2>/dev/null || true
  chmod 600 /var/lib/tor/aeterra-provider/hs_ed25519_secret_key /var/lib/tor/aeterra-provider/hs_ed25519_public_key 2>/dev/null || true
fi
# --- Tor guard state persistence ---
# /var/lib/tor is ephemeral; without the guard state, fresh tor picks random
# guards which the egress proxy usually blocks (stuck at bootstrap 4%).
# Restore last known-good guards + cached descriptors so tor bootstraps
# immediately after reset.
if [ -f /home/hatch/workspace/tor-persist/state ]; then
  cp /home/hatch/workspace/tor-persist/state /var/lib/tor/state
  chown debian-tor:debian-tor /var/lib/tor/state
  chmod 600 /var/lib/tor/state
  for cf in cached-microdesc-consensus cached-microdescs cached-microdescs.new cached-certs; do
    if [ -f /home/hatch/workspace/tor-persist/$cf ]; then
      cp /home/hatch/workspace/tor-persist/$cf /var/lib/tor/$cf
      chown debian-tor:debian-tor /var/lib/tor/$cf
      chmod 600 /var/lib/tor/$cf
    fi
  done
  echo "restored tor guard state + cached descriptors from persistent backup"
fi
# onion-health watchdog timer (2-min checks, 15-min restart cooldown)
if ! systemctl is-enabled onion-health.timer >/dev/null 2>&1; then
  cp ~/workspace/9router-setup/scripts/onion-health.service ~/workspace/9router-setup/scripts/onion-health.timer /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now onion-health.timer 2>/dev/null
fi
# qron service unit
if ! systemctl is-enabled qron.service >/dev/null 2>&1; then
  cp ~/workspace/9router-setup/scripts/qron.service /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now qron.service 2>/dev/null
fi
# senter search engine units (web UI + crawler worker)
for u in senter-web senter-crawler; do
  if ! systemctl is-enabled $u.service >/dev/null 2>&1; then
    cp ~/workspace/9router-setup/scripts/$u.service /etc/systemd/system/ 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now $u.service 2>/dev/null
  fi
done
# oracle service unit
if ! systemctl is-enabled oracle.service >/dev/null 2>&1; then
  cp ~/workspace/9router-setup/scripts/oracle.service /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now oracle.service 2>/dev/null
fi
# onionatlas service unit
if ! systemctl is-enabled onionatlas.service >/dev/null 2>&1; then
  cp ~/workspace/9router-setup/scripts/onionatlas.service /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now onionatlas.service 2>/dev/null
fi
# snip service unit
if ! systemctl is-enabled snip.service >/dev/null 2>&1; then
  cp ~/workspace/9router-setup/scripts/snip.service /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now snip.service 2>/dev/null
fi
# jot service unit
if ! systemctl is-enabled jot.service >/dev/null 2>&1; then
  cp ~/workspace/9router-setup/scripts/jot.service /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now jot.service 2>/dev/null
fi
# whisper service unit
if ! systemctl is-enabled whisper.service >/dev/null 2>&1; then
  cp ~/workspace/9router-setup/scripts/whisper.service /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now whisper.service 2>/dev/null
fi
# tor guard state saver (hourly, only when bootstrap 100%)
if ! systemctl is-enabled tor-state-save.timer >/dev/null 2>&1; then
  cp ~/workspace/9router-setup/scripts/tor-state-save.service ~/workspace/9router-setup/scripts/tor-state-save.timer /etc/systemd/system/ 2>/dev/null
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now tor-state-save.timer 2>/dev/null
fi

# --- Qron QR generator hidden service (-> 127.0.0.1:18099) ---
QKEYSRC=$(ls -d /home/hatch/workspace/qron/tor-keys/*.onion 2>/dev/null | head -1)
if [ -n "$QKEYSRC" ]; then
  mkdir -p /var/lib/tor/qron
  cp "$QKEYSRC/hostname" "$QKEYSRC/hs_ed25519_secret_key" "$QKEYSRC/hs_ed25519_public_key" /var/lib/tor/qron/ 2>/dev/null || true
  chown -R debian-tor:debian-tor /var/lib/tor/qron
  chmod 700 /var/lib/tor/qron
  chmod 600 /var/lib/tor/qron/hs_ed25519_secret_key /var/lib/tor/qron/hs_ed25519_public_key
fi
if ! grep -q "HiddenServiceDir /var/lib/tor/qron/" /etc/tor/torrc 2>/dev/null; then
  echo "restoring qron torrc hidden service config"
  {
    echo ""
    echo "# Qron QR generator - Tor hidden service (managed, see ~/workspace/qron/)"
    echo "HiddenServiceDir /var/lib/tor/qron/"
    echo "HiddenServicePort 80 127.0.0.1:18099"
    echo "HiddenServiceNumIntroductionPoints 10"
  } >> /etc/tor/torrc
fi

# --- Senter search engine hidden service (-> 127.0.0.1:18100) ---
SKEYSRC=$(ls -d /home/hatch/workspace/senter/tor-keys/*.onion 2>/dev/null | head -1)
if [ -n "$SKEYSRC" ]; then
  mkdir -p /var/lib/tor/senter
  cp "$SKEYSRC/hostname" "$SKEYSRC/hs_ed25519_secret_key" "$SKEYSRC/hs_ed25519_public_key" /var/lib/tor/senter/ 2>/dev/null || true
  chown -R debian-tor:debian-tor /var/lib/tor/senter
  chmod 700 /var/lib/tor/senter
  chmod 600 /var/lib/tor/senter/hs_ed25519_secret_key /var/lib/tor/senter/hs_ed25519_public_key
fi
if ! grep -q "HiddenServiceDir /var/lib/tor/senter/" /etc/tor/torrc 2>/dev/null; then
  echo "restoring senter torrc hidden service config"
  {
    echo ""
    echo "# Senter search engine - Tor hidden service (managed, see ~/workspace/senter/)"
    echo "HiddenServiceDir /var/lib/tor/senter/"
    echo "HiddenServicePort 80 127.0.0.1:18100"
    echo "HiddenServiceNumIntroductionPoints 10"
  } >> /etc/tor/torrc
fi

# --- Oracle anonymous AI chat hidden service (-> 127.0.0.1:18098) ---
ORKEYSRC=$(ls -d /home/hatch/workspace/oracle/tor-keys/*.onion 2>/dev/null | head -1)
if [ -n "$ORKEYSRC" ]; then
  mkdir -p /var/lib/tor/oracle
  cp "$ORKEYSRC/hostname" "$ORKEYSRC/hs_ed25519_secret_key" "$ORKEYSRC/hs_ed25519_public_key" /var/lib/tor/oracle/ 2>/dev/null || true
  chown -R debian-tor:debian-tor /var/lib/tor/oracle
  chmod 700 /var/lib/tor/oracle
  chmod 600 /var/lib/tor/oracle/hs_ed25519_secret_key /var/lib/tor/oracle/hs_ed25519_public_key
fi
if ! grep -q "HiddenServiceDir /var/lib/tor/oracle/" /etc/tor/torrc 2>/dev/null; then
  echo "restoring oracle torrc hidden service config"
  {
    echo ""
    echo "# Oracle anonymous AI chat - Tor hidden service (managed, see ~/workspace/oracle/)"
    echo "HiddenServiceDir /var/lib/tor/oracle/"
    echo "HiddenServicePort 80 127.0.0.1:18098"
    echo "HiddenServiceNumIntroductionPoints 10"
  } >> /etc/tor/torrc
fi

# --- OnionAtlas landing page hidden service (-> 127.0.0.1:18097) ---
OKEYSRC=$(ls -d /home/hatch/workspace/onionatlas/tor-keys/*.onion 2>/dev/null | head -1)
if [ -n "$OKEYSRC" ]; then
  mkdir -p /var/lib/tor/onionatlas
  cp "$OKEYSRC/hostname" "$OKEYSRC/hs_ed25519_secret_key" "$OKEYSRC/hs_ed25519_public_key" /var/lib/tor/onionatlas/ 2>/dev/null || true
  chown -R debian-tor:debian-tor /var/lib/tor/onionatlas
  chmod 700 /var/lib/tor/onionatlas
  chmod 600 /var/lib/tor/onionatlas/hs_ed25519_secret_key /var/lib/tor/onionatlas/hs_ed25519_public_key
fi
if ! grep -q "HiddenServiceDir /var/lib/tor/onionatlas/" /etc/tor/torrc 2>/dev/null; then
  echo "restoring onionatlas torrc hidden service config"
  {
    echo ""
    echo "# OnionAtlas landing page - Tor hidden service (managed, see ~/workspace/onionatlas/)"
    echo "HiddenServiceDir /var/lib/tor/onionatlas/"
    echo "HiddenServicePort 80 127.0.0.1:18097"
    echo "HiddenServiceNumIntroductionPoints 10"
  } >> /etc/tor/torrc
fi

# --- Snip onion URL shortener hidden service (-> 127.0.0.1:18096) ---
SKEYSRC=$(ls -d /home/hatch/workspace/snip/tor-keys/*.onion 2>/dev/null | head -1)
if [ -n "$SKEYSRC" ]; then
  mkdir -p /var/lib/tor/snip
  cp "$SKEYSRC/hostname" "$SKEYSRC/hs_ed25519_secret_key" "$SKEYSRC/hs_ed25519_public_key" /var/lib/tor/snip/ 2>/dev/null || true
  chown -R debian-tor:debian-tor /var/lib/tor/snip
  chmod 700 /var/lib/tor/snip
  chmod 600 /var/lib/tor/snip/hs_ed25519_secret_key /var/lib/tor/snip/hs_ed25519_public_key
fi
if ! grep -q "HiddenServiceDir /var/lib/tor/snip/" /etc/tor/torrc 2>/dev/null; then
  echo "restoring snip torrc hidden service config"
  {
    echo ""
    echo "# Snip onion URL shortener - Tor hidden service (managed, see ~/workspace/snip/)"
    echo "HiddenServiceDir /var/lib/tor/snip/"
    echo "HiddenServicePort 80 127.0.0.1:18096"
    echo "HiddenServiceNumIntroductionPoints 10"
  } >> /etc/tor/torrc
fi

# --- Jot anonymous pastebin hidden service (-> 127.0.0.1:18095) ---
JKEYSRC=$(ls -d /home/hatch/workspace/jot/tor-keys/*.onion 2>/dev/null | head -1)
if [ -n "$JKEYSRC" ]; then
  mkdir -p /var/lib/tor/jot
  cp "$JKEYSRC/hostname" "$JKEYSRC/hs_ed25519_secret_key" "$JKEYSRC/hs_ed25519_public_key" /var/lib/tor/jot/ 2>/dev/null || true
  chown -R debian-tor:debian-tor /var/lib/tor/jot
  chmod 700 /var/lib/tor/jot
  chmod 600 /var/lib/tor/jot/hs_ed25519_secret_key /var/lib/tor/jot/hs_ed25519_public_key
fi
if ! grep -q "HiddenServiceDir /var/lib/tor/jot/" /etc/tor/torrc 2>/dev/null; then
  echo "restoring jot torrc hidden service config"
  {
    echo ""
    echo "# Jot anonymous pastebin - Tor hidden service (managed, see ~/workspace/jot/)"
    echo "HiddenServiceDir /var/lib/tor/jot/"
    echo "HiddenServicePort 80 127.0.0.1:18095"
    echo "HiddenServiceNumIntroductionPoints 10"
  } >> /etc/tor/torrc
fi

# --- Whisper anonymous chat hidden service (-> 127.0.0.1:18094) ---
WKEYSRC=$(ls -d /home/hatch/workspace/whisper/tor-keys/*.onion 2>/dev/null | head -1)
if [ -n "$WKEYSRC" ]; then
  mkdir -p /var/lib/tor/whisper
  cp "$WKEYSRC/hostname" "$WKEYSRC/hs_ed25519_secret_key" "$WKEYSRC/hs_ed25519_public_key" /var/lib/tor/whisper/ 2>/dev/null || true
  chown -R debian-tor:debian-tor /var/lib/tor/whisper
  chmod 700 /var/lib/tor/whisper
  chmod 600 /var/lib/tor/whisper/hs_ed25519_secret_key /var/lib/tor/whisper/hs_ed25519_public_key
fi
if ! grep -q "HiddenServiceDir /var/lib/tor/whisper/" /etc/tor/torrc 2>/dev/null; then
  echo "restoring whisper torrc hidden service config"
  {
    echo ""
    echo "# Whisper anonymous chat - Tor hidden service (managed, see ~/workspace/whisper/)"
    echo "HiddenServiceDir /var/lib/tor/whisper/"
    echo "HiddenServicePort 80 127.0.0.1:18094"
    echo "HiddenServiceNumIntroductionPoints 10"
  } >> /etc/tor/torrc
fi

if ! grep -q "HiddenServiceDir /var/lib/tor/aeterra-provider/" /etc/tor/torrc 2>/dev/null; then
  echo "restoring aeterra-provider torrc hidden service config"
  {
    echo ""
    echo "# Aeterra .onion Provider - Tor hidden service (managed, see ~/workspace/aeterra-provider/)"
    echo "HiddenServiceDir /var/lib/tor/aeterra-provider/"
    echo "HiddenServicePort 80 127.0.0.1:18093"
    echo "HiddenServiceNumIntroductionPoints 10"
  } >> /etc/tor/torrc
fi


echo "done: $(systemctl is-active 9router.service muse-bridge.service hermes-gateway.service 9router-tunnel.service 2>/dev/null | tr '\n' ' ')"

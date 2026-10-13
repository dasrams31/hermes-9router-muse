#!/usr/bin/env bash
# vm-reset-watchdog: cek ringan tiap 60 dtk apakah service penting masih jalan.
# Hanya bangunkan worker bila ada yang down 2x berturut-turut (anti false alarm).
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

STATE_DIR="$HOME/hooks/state/vm-reset-watchdog"
mkdir -p "$STATE_DIR"
COUNT_FILE="$STATE_DIR/consec_fails"

# Service yang WAJIB jalan (sesuai recover-after-reboot.sh).
# minecraft/muse-bot sengaja TIDAK masuk daftar (dimatikan permanen).
SERVICES="peka-web peka-tunnel 9router muse-bridge hermes-gateway 9router-tunnel ramadanadipa-web ramadanadipa-tunnel blog-web blog-tunnel mc-portal mc-portal-tunnel agentarium agentarium-tunnel threads-cms threads-cms-tunnel web-terminal web-terminal-tunnel llama-server smollm2-server"

out=""
if ! out=$(systemctl is-active $SERVICES 2>/dev/null); then
  # systemctl gagal total (VM unreachable) -> anggap semua down, tanpa parsing
  down="ALL(systemctl-unreachable)"
else
  down=""
  i=0
  for s in $SERVICES; do
    i=$((i + 1))
    st=$(printf '%s\n' "$out" | sed -n "${i}p")
    if [ "$st" != "active" ]; then
      down="$down $s"
    fi
  done
  down=$(printf '%s' "$down" | sed 's/^ //')
fi

count=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)

if [ -n "$down" ]; then
  count=$((count + 1))
  printf '%s' "$count" > "$COUNT_FILE"
  log "services down" "{\"down\":\"$down\",\"consec_fails\":$count}"
  if [ "$count" -ge 2 ]; then
    printf '0' > "$COUNT_FILE"
    wake "service down 2x berturut-turut (kemungkinan VM reset)" "{\"down\":\"$down\"}"
  else
    silent "down terdeteksi 1x, tunggu konfirmasi poll berikutnya" "{\"down\":\"$down\"}"
  fi
else
  printf '0' > "$COUNT_FILE"
  silent "semua service aktif" '{}'
fi

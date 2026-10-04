#!/bin/bash
# Backup harian hermes-9router-muse ke GitHub
set -e
S="$HOME/workspace/releases/hermes-9router-muse"
TOKEN_FILE="$HOME/workspace/mc-portal/config/github_token"

rm -rf "$S/9router" "$S/hermes"
mkdir -p "$S/9router/scripts" "$S/9router/bridge" "$S/hermes"

cp "$HOME/workspace/9router-setup/scripts/"* "$S/9router/scripts/"
cp "$HOME/workspace/9router-setup/bridge/bridge.js" "$S/9router/bridge/"
cp "$HOME/workspace/9router-setup/backup/README.md" "$S/9router/"
cp "$HOME/.hermes/config.yaml" "$HOME/.hermes/SOUL.md" "$S/hermes/"

cd "$S"
git add -A
if git diff --cached --quiet; then
  echo "no changes"
  exit 0
fi
git -c user.name="dasrams31" -c user.email="ramadanadipa176@gmail.com" \
  commit -qm "Daily backup $(date +%F)"

TOKEN="$(cat "$TOKEN_FILE")"
git push "https://dasrams31:${TOKEN}@github.com/dasrams31/hermes-9router-muse.git" main 2>&1 | tail -2
echo "pushed $(date -Is)"

# hermes-9router-muse

AI stack backup: 9Router + Muse Bridge + Hermes gateway config on the Muse VPS.

## Contents
- `9router/scripts/` — systemd unit files for the whole stack (9Router, muse-bridge,
  hermes-gateway, tunnels, web services, minecraft) + `recover-after-reboot.sh`
- `9router/bridge/bridge.js` — OpenAI-compatible bridge ("Muse" provider, combo `muse`);
  every chat request becomes a queue job answered by a worker agent
- `9router/README.md` — recovery/backup notes
- `hermes/config.yaml` — Hermes gateway config (sanitized, no secrets)
- `hermes/SOUL.md` — gateway persona

## Architecture
```
Telegram @dasrams_sparkbot → hermes-gateway → Hermes (model `muse`)
                                                    ↓
                                            9Router :20128 (prefix `spark`)
                                                    ↓
                                          muse-bridge :18089 → this assistant
```
Public: https://spark.dasrams.biz.id (Caddy reverse proxy on the public server).

## Not included (sensitive / too big)
- `.env` files, API tokens, dashboard passwords, Telegram bot tokens
- SSH private keys (`9router-setup/ssh/`)
- Hermes runtime state: `~/.hermes/` (2.4 GB — logs, caches, session DBs, audio/image cache)
- `bin/chisel`

Secrets live only on the VPS (chmod 600). After a restore, re-enter credentials manually.

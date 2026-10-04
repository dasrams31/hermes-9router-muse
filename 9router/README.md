# 9Router + Muse-bridge + Hermes — VPS setup

Dibuat: 2026-09-30. Semua kredensial ada di file `.env` (chmod 600) di direktori ini
dan di `../bridge/.env`. File ini TIDAK berisi secret.

## Arsitektur

```
Hermes  →  9Router (http://localhost:20128/v1, model "muse" = combo)
            → provider node "muse" (prefix muse/)
            → muse-bridge (http://127.0.0.1:18089/v1, systemd)
            → job queue → hook worker (Muse) menjawab → respons kembali
```

Provider "muse" BUKAN API eksternal — yang menjawab adalah Muse (asisten) itu
sendiri lewat worker terjadwal:
- Bridge mengantrekan tiap request chat sebagai job (`bridge/jobs/*.json`)
  dan menunggu jawaban (long-poll, maks 10 menit).
- Hook `muse-bridge-worker` (poll tiap 30 dtk, `~/hooks/scripts/`) membangunkan
  agen worker saat ada job baru.
- Worker mengklaim job, menjawab sebagai Muse, dan mem-post jawaban ke bridge.

## Komponen

| Komponen | Detail |
|---|---|
| 9Router | v0.5.91 (npm), systemd `9router.service`, port 20128, data di `/home/hatch/.9router` |
| muse-bridge | Node tanpa dependensi, systemd `muse-bridge.service`, port 18089 (localhost only) |
| Hook worker | `muse-bridge-worker`, poll 30 dtk |
| Hermes | NousResearch hermes-agent, `~/.hermes/`, model default `muse` via 9Router |
| Combo 9Router | `muse` (fallback) → `muse/muse` |

## File penting

- `backup/9router-secrets.env` — dashboard URL+password, 9Router API key (chmod 600)
- `bridge/.env` — BRIDGE_KEY untuk koneksi 9Router→bridge (chmod 600)
- `bridge/bridge.js` — kode bridge
- `scripts/9router.service`, `scripts/muse-bridge.service` — unit systemd (salinan)
- `scripts/secure-9router.py` — rotasi password + buat API key (idempoten)
- `scripts/register-muse.py` — registrasi node/koneksi/combo via API (idempoten)

## Recovery (setelah VM diganti)

1. `npm install -g 9router`
2. Salin unit: `cp scripts/*.service /etc/systemd/system/ && systemctl daemon-reload`
3. `systemctl enable --now 9router muse-bridge`
4. Data 9Router (`/home/hatch/.9router`) dan `~/hooks` ikut home dir yang persisten;
   jika hilang, jalankan ulang `scripts/secure-9router.py` + `scripts/register-muse.py`,
   lalu buat ulang hook worker.
5. Hermes: jalankan ulang installer resmi bila `~/.hermes` hilang, lalu
   `hermes config set model.provider custom`,
   `hermes config set model.base_url http://localhost:20128/v1`,
   `hermes config set model.default muse`,
   `hermes config set model.api_key <NINEROUTER_API_KEY>`.

## Catatan

- Dashboard 9Router: http://localhost:20128/dashboard (password di secrets.env,
  sudah diganti dari default 123456).
- Latensi respons model "muse": ~30–90 detik (poll hook 30 dtk + waktu worker menjawab).
- Bridge tidak mendukung tool-calling; hanya teks.

## Telegram (2026-09-30)
- Bot @dasrams_sparkbot terhubung via Hermes gateway (systemd `hermes-gateway.service`,
  long polling). Token di `~/.hermes/.env` (TELEGRAM_BOT_TOKEN).
- `TELEGRAM_ALLOWED_USERS` diisi ID pemilik. Gateway butuh proxy egress:
  `~/.hermes/proxy.env` (chmod 600) dimuat via EnvironmentFile di unit systemd.
- Dependensi `python-telegram-bot[webhooks]==22.8` di-install manual via uv ke venv
  Hermes karena downloader internal gateway tidak memakai proxy.

# Local AI Stack — Dokumentasi

Stack AI lokal di VPS Muse: llama.cpp + model GGUF + 9Router.

## Arsitektur

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│   Hermes    │────▶│   9Router    │────▶│ llama-server│
│  (Telegram) │     │  :20128      │     │  :18090/:18091
└─────────────┘     └──────────────┘     └─────────────┘
                          │
                    ┌─────┴─────┐
                    │ Agentarium│
                    │  :8100    │
                    └───────────┘
```

## Model

| Model | File | Ukuran | Port | 9Router Combo |
|-------|------|--------|------|---------------|
| Llama 3.2 1B Instruct Q4_K_M | `llama-3.2-1b-q4km.gguf` | 771 MB | 18090 | `llama` → `llamalocal/llama` |
| SmolLM2 1.7B Instruct Q4_K_M | `smollm2-1.7b-q4km.gguf` | 1007 MB | 18091 | `smollm2` → `smol/smollm2` |

**Catatan prefix:** Setiap provider HARUS punya prefix unik. Jangan pakai `spark` untuk semua (menyebabkan routing collision — 9Router selalu pilih provider pertama).

## Services

| Service | Deskripsi |
|---------|-----------|
| `llama-server.service` | llama.cpp server untuk Llama 3.2 1B |
| `smollm2-server.service` | llama.cpp server untuk SmolLM2 1.7B |

## Instalasi Ulang (setelah VM replacement)

```bash
# 1. Install llama.cpp + download models + setup services
bash ~/workspace/9router-setup/scripts/install-local-ai.sh

# 2. Setup 9Router combos (setelah 9Router jalan)
bash ~/workspace/9router-setup/scripts/install-9router-models.sh

# 3. Verifikasi
curl -s http://127.0.0.1:18090/health  # {"status":"ok"}
curl -s http://127.0.0.1:18091/health  # {"status":"ok"}
```

## Testing via 9Router

```bash
KEY=$(cat ~/workspace/agentarium/agents/.keys/.9router_key)

# Test Llama
curl -s -X POST "http://127.0.0.1:20128/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"llama","messages":[{"role":"user","content":"Hi"}],"max_tokens":20}'

# Test SmolLM2
curl -s -X POST "http://127.0.0.1:20128/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"smollm2","messages":[{"role":"user","content":"Hi"}],"max_tokens":20}'
```

## Testing via Hermes

```bash
hermes chat --model llama
hermes chat --model smollm2
```

## Spesifikasi VPS

- RAM: 7.7 GB
- CPU: 2 cores
- Model lokal pakai ~1.5 GB RAM total
- **JANGAN** jalankan Minecraft bersamaan dengan model lokal

## Troubleshooting

### 9Router selalu routing ke Muse
Penyebab: prefix collision. Pastikan setiap provider punya prefix unik di `providerNodes.data`.

### Response JSON malformed (`data: [DONE]` di akhir)
9Router menambahkan SSE garbage ke response non-streaming dari llama.cpp.
Sudah di-handle di `agentarium/agents/agent_base.py` (`llm_complete` mengekstrak JSON object pertama yang valid).

### Model lambat / timeout
- Kurangi `-c` (context size) di service file
- Kurangi `-t` (threads) jika CPU contention
- Timeout default `llm_complete`: 60 detik

## Riwayat

- **2026-10-06**: Llama 3.2 1B dipasang (gantiin Minecraft untuk hemat RAM)
- **2026-10-06**: Qwen2.5 0.5B dipasang, lalu diganti SmolLM2 1.7B (kualitas lebih baik)
- **2026-10-06**: Fix prefix collision di 9Router
- **2026-10-06**: Fix SSE garbage di parser JSON

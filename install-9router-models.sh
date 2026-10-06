#!/bin/bash
# Setup 9Router combos untuk model lokal (Llama + SmolLM2)
# Dijalankan setelah install-local-ai.sh dan 9Router sudah jalan.
# Usage: bash install-9router-models.sh
set -e

DB="$HOME/.9router/db/data.sqlite"

if [ ! -f "$DB" ]; then
  echo "ERROR: 9Router DB tidak ditemukan di $DB"
  echo "Pastikan 9Router sudah ter-install dan pernah dijalankan."
  exit 1
fi

echo "=== Setup 9Router provider nodes ==="

sqlite3 "$DB" << 'SQLEOF'
-- Hapus yang lama kalau ada (idempotent)
DELETE FROM providerConnections WHERE name IN ('Llama Local Bridge', 'SmolLM2 Local Bridge', 'Qwen Local Bridge');
DELETE FROM providerNodes WHERE name IN ('Llama Local', 'SmolLM2 Local', 'Qwen Local');
DELETE FROM combos WHERE name IN ('llama', 'smollm2', 'qwen');

-- Llama Local
INSERT INTO providerNodes (id, type, name, data, createdAt, updatedAt)
VALUES (
  'openai-compatible-llama-' || hex(randomblob(16)),
  'openai-compatible',
  'Llama Local',
  '{"prefix": "llamalocal", "apiType": "chat", "baseUrl": "http://127.0.0.1:18090/v1"}',
  datetime('now'), datetime('now')
);

-- SmolLM2 Local
INSERT INTO providerNodes (id, type, name, data, createdAt, updatedAt)
VALUES (
  'openai-compatible-smol-' || hex(randomblob(16)),
  'openai-compatible',
  'SmolLM2 Local',
  '{"prefix": "smol", "apiType": "chat", "baseUrl": "http://127.0.0.1:18091/v1"}',
  datetime('now'), datetime('now')
);
SQLEOF

LLAMA_NODE=$(sqlite3 "$DB" "SELECT id FROM providerNodes WHERE name='Llama Local';")
SMOL_NODE=$(sqlite3 "$DB" "SELECT id FROM providerNodes WHERE name='SmolLM2 Local';")

sqlite3 "$DB" << SQLEOF
-- Llama connection
INSERT INTO providerConnections (id, provider, authType, name, priority, isActive, data, createdAt, updatedAt)
VALUES (
  'conn-llama-local-001',
  '$LLAMA_NODE', 'apikey', 'Llama Local Bridge', 10, 1,
  '{"defaultModel": "llama", "apiKey": "not-needed", "testStatus": "active", "providerSpecificData": {"prefix": "llamalocal", "apiType": "chat", "baseUrl": "http://127.0.0.1:18090/v1", "nodeName": "Llama Local", "connectionProxyEnabled": false}, "backoffLevel": 0}',
  datetime('now'), datetime('now')
);

-- SmolLM2 connection
INSERT INTO providerConnections (id, provider, authType, name, priority, isActive, data, createdAt, updatedAt)
VALUES (
  'conn-smol-local-001',
  '$SMOL_NODE', 'apikey', 'SmolLM2 Local Bridge', 10, 1,
  '{"defaultModel": "smollm2", "apiKey": "not-needed", "testStatus": "active", "providerSpecificData": {"prefix": "smol", "apiType": "chat", "baseUrl": "http://127.0.0.1:18091/v1", "nodeName": "SmolLM2 Local", "connectionProxyEnabled": false}, "backoffLevel": 0}',
  datetime('now'), datetime('now')
);

-- Combos
INSERT INTO combos (id, name, kind, models, createdAt, updatedAt)
VALUES ('combo-llama-' || hex(randomblob(8)), 'llama', 'fallback', '["llamalocal/llama"]', datetime('now'), datetime('now'));

INSERT INTO combos (id, name, kind, models, createdAt, updatedAt)
VALUES ('combo-smol-' || hex(randomblob(8)), 'smollm2', 'fallback', '["smol/smollm2"]', datetime('now'), datetime('now'));
SQLEOF

echo "=== Restart 9Router ==="
sudo systemctl restart 9router.service
sleep 5

echo "=== Combos ==="
sqlite3 "$DB" "SELECT name, models FROM combos;"

echo ""
echo "=== Done! ==="
echo "Test: curl dengan model 'llama' atau 'smollm2' via 9Router API"

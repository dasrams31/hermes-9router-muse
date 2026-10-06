#!/bin/bash
# Auto-installer: Local AI Stack (llama.cpp + Llama + SmolLM2 + 9Router)
# Dijalankan setelah VM replacement untuk restore model lokal.
# Usage: bash install-local-ai.sh
set -e

WORKSPACE="$HOME/workspace"
MODELS_DIR="$WORKSPACE/llama-models"
LLAMACPP_DIR="$WORKSPACE/llama.cpp"

echo "=== [1/5] Install dependencies ==="
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential cmake git curl sqlite3 > /dev/null

echo "=== [2/5] Build llama.cpp ==="
if [ ! -d "$LLAMACPP_DIR" ]; then
  git clone --quiet https://github.com/ggerganov/llama.cpp.git "$LLAMACPP_DIR"
fi
cd "$LLAMACPP_DIR"
cmake -B build -DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=OFF > /dev/null 2>&1
cmake --build build --config Release -j2 2>&1 | tail -1
echo "llama.cpp built: $LLAMACPP_DIR/build/bin/llama-server"

echo "=== [3/5] Download models ==="
mkdir -p "$MODELS_DIR"
cd "$MODELS_DIR"

if [ ! -f "llama-3.2-1b-q4km.gguf" ]; then
  echo "Downloading Llama 3.2 1B..."
  wget -q --show-progress "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf" -O llama-3.2-1b-q4km.gguf
fi

if [ ! -f "smollm2-1.7b-q4km.gguf" ]; then
  echo "Downloading SmolLM2 1.7B..."
  wget -q --show-progress "https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF/resolve/main/smollm2-1.7b-instruct-q4_k_m.gguf" -O smollm2-1.7b-q4km.gguf
fi

chmod 600 "$MODELS_DIR"/*.gguf
ls -lh "$MODELS_DIR"/*.gguf

echo "=== [4/5] Install systemd services ==="
# Llama server
sudo tee /etc/systemd/system/llama-server.service > /dev/null << 'SVCEOF'
[Unit]
Description=Llama.cpp server (Llama 3.2 1B)
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/hatch/workspace/llama-models
ExecStart=/home/hatch/workspace/llama.cpp/build/bin/llama-server -m /home/hatch/workspace/llama-models/llama-3.2-1b-q4km.gguf --host 127.0.0.1 --port 18090 -c 2048 -t 2
Restart=always
RestartSec=10
Nice=10
MemoryMax=1200M

[Install]
WantedBy=multi-user.target
SVCEOF

# SmolLM2 server
sudo tee /etc/systemd/system/smollm2-server.service > /dev/null << 'SVCEOF'
[Unit]
Description=Llama.cpp server (SmolLM2 1.7B)
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/hatch/workspace/llama-models
ExecStart=/home/hatch/workspace/llama.cpp/build/bin/llama-server -m /home/hatch/workspace/llama-models/smollm2-1.7b-q4km.gguf --host 127.0.0.1 --port 18091 -c 2048 -t 2
Restart=always
RestartSec=10
Nice=10
MemoryMax=1200M

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable --now llama-server.service smollm2-server.service

echo "=== [5/5] Verify ==="
sleep 10
echo -n "Llama (18090): "
curl -s -m 5 "http://127.0.0.1:18090/health" 2>&1 | head -c 20; echo
echo -n "SmolLM2 (18091): "
curl -s -m 5 "http://127.0.0.1:18091/health" 2>&1 | head -c 20; echo

echo ""
echo "=== Done! ==="
echo "Next: setup 9Router combos via install-9router-models.sh"

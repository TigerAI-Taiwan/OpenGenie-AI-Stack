#!/usr/bin/env bash
# =====================================================================
# TigerAI Lemonade Core Service Deployer (ARM64-NVIDIA Optimized)
# Path: deployments/arm64-compose-stack/06-ai-core-lemonade/deploy.sh
# =====================================================================

set -eo pipefail

# --- 0) Configuration & Variables ---
# Import from local .env first
if [ -f .env ]; then
  export $(grep -v '^#' .env | sed 's/\r//g' | xargs)
fi

# Then import from tiger-tuning.env (hardware optimized)
if [ -f ../tiger-tuning.env ]; then
  export $(grep -v '^#' ../tiger-tuning.env | sed 's/\r//g' | xargs)
fi

# Finally import from parent stack .env (if exists)
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | sed 's/\r//g' | xargs)
fi

# Robust Variable Cleansing (Against Windows CRLF)
for var in $(env | grep -E 'PORT|IMAGE|URL|PATH|USER|PASS|DB|SECRET|TZ' | cut -d= -f1); do
  export "$var"="$(echo "${!var}" | tr -d '\r')"
done

LOG_PREFIX="TigerAI Lemonade"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

# Fallback defaults for service paths and models (align with arm64 .env.example and nvidia deploy.sh)
BASE_DIR="${BASE_DIR:-/home/wrt/TigerAI}"
MODELS_DIR="${MODELS_DIR:-${BASE_DIR}/models}"
LOG_DIR="${LOG_DIR:-${BASE_DIR}/lemonade-logs}"
LLM_MODEL="${LLM_MODEL:-gpt-oss-20b-mxfp4.gguf}"
EMBED_MODEL="${EMBED_MODEL:-Qwen3-Embedding-8B-Q8_0.gguf}"

usage() {
    echo "Usage: sudo $0 {all | install | config | status | restart | purge}"
    exit 1
}

[ $# -eq 0 ] && usage

# --- 1) Native Binary Installation (ARM64 Optimized) ---
install_snap() {
    LOG " Installing Lemonade Core (ARM64 Native via GitHub Release)..."
    
    if command -v lemonade-server &>/dev/null; then
        LOG " lemonade-server already installed, skipping."
    else
        local VERSION="v0.2.14" # 根據當前穩定版
        LOG " Downloading Lemonade ${VERSION} for ARM64..."
        
        # 下載二進位檔 (lemonade-server & lemonade client)
        sudo curl -L "https://github.com/lemonade-sdk/lemonade-server/releases/download/${VERSION}/lemonade-server-linux-arm64" -o /usr/local/bin/lemonade-server
        sudo curl -L "https://github.com/lemonade-sdk/lemonade-server/releases/download/${VERSION}/lemonade-linux-arm64" -o /usr/local/bin/lemonade
        
        sudo chmod +x /usr/local/bin/lemonade-server /usr/local/bin/lemonade
        LOG " Binaries installed successfully to /usr/local/bin."
    fi
}

# --- 2) Configuration & Service Setup ---
configure_services() {
    LOG " Configuring Lemonade Services (EDU, RAG, EMBED)..."
    
    local LLM_PATH="${MODELS_DIR}/${LLM_MODEL}"
    local EMBED_PATH="${MODELS_DIR}/${EMBED_MODEL}"
    # Use TIGER_CPU_THREADS if set, otherwise default to 16
    local AUTO_THREADS=${TIGER_CPU_THREADS:-16}

    sudo mkdir -p "${MODELS_DIR}" "${LOG_DIR}"
    sudo chown -R ${SUDO_USER:-wrt}:${SUDO_USER:-wrt} "${BASE_DIR:-/home/wrt/TigerAI}"

    # A. EDU Service (Port 8800)
    cat <<EOF | sudo tee /etc/systemd/system/lemonade-edu.service > /dev/null
[Unit]
Description=TigerAI Lemonade - EDU
After=network.target

[Service]
Type=simple
User=root
PrivateTmp=true
LimitMEMLOCK=infinity
TasksMax=4096
Environment=LEMONADE_API_KEY=${LEMONADE_API_KEY:-CHANGE_ME}
Environment=CUDA_VISIBLE_DEVICES=${GGML_VULKAN_DEVICE_EDU:-0}
Environment=LEMONADE_EXTRA_MODELS_DIR=${MODELS_DIR}
ExecStart=/usr/local/bin/lemonade-server serve 
  --host 0.0.0.0 --port 8800 --socket-path /tmp/lemonade-edu.sock --pid-file /tmp/lemonade-edu.pid 
  --extra-models-dir ${MODELS_DIR} --ctx-size 81920 --model ${LLM_PATH} --llamacpp cuda 
  --llamacpp-args "--flash-attn on --threads ${AUTO_THREADS} --parallel 28 --tensor-split 1,1 --n-gpu-layers 999 --cache-type-k q8_0 --cache-type-v q8_0"
StandardOutput=append:${LOG_DIR}/edu.log
StandardError=append:${LOG_DIR}/edu.log
Restart=always
RestartSec=15
EOF

    # B. RAG Service (Port 8801)
    cat <<EOF | sudo tee /etc/systemd/system/lemonade-rag.service > /dev/null
[Unit]
Description=TigerAI Lemonade - RAG
After=network.target

[Service]
Type=simple
User=root
PrivateTmp=true
LimitMEMLOCK=infinity
TasksMax=4096
Environment=LEMONADE_API_KEY=${LEMONADE_API_KEY:-CHANGE_ME}
Environment=CUDA_VISIBLE_DEVICES=${GGML_VULKAN_DEVICE_RAG:-0}
Environment=LEMONADE_EXTRA_MODELS_DIR=${MODELS_DIR}
ExecStart=/usr/local/bin/lemonade-server serve 
  --host 0.0.0.0 --port 8801 --socket-path /tmp/lemonade-rag.sock --pid-file /tmp/lemonade-rag.pid 
  --extra-models-dir ${MODELS_DIR} --ctx-size 131072 --model ${LLM_PATH} --llamacpp cuda 
  --llamacpp-args "--flash-attn on --threads ${AUTO_THREADS} --parallel 2 --tensor-split 3,1 --n-gpu-layers 999 --cache-type-k q8_0 --cache-type-v q8_0"
StandardOutput=append:${LOG_DIR}/rag.log
StandardError=append:${LOG_DIR}/rag.log
Restart=always
RestartSec=15
EOF

    # C. EMBED Service (Port 8802)
    cat <<EOF | sudo tee /etc/systemd/system/lemonade-embed.service > /dev/null
[Unit]
Description=TigerAI Lemonade - EMBED Daemon
After=network.target

[Service]
Type=simple
User=root
PrivateTmp=true
LimitMEMLOCK=infinity
Environment=LEMONADE_API_KEY=${LEMONADE_API_KEY:-CHANGE_ME}
Environment=CUDA_VISIBLE_DEVICES=${GGML_VULKAN_DEVICE_EMBED:-0}
Environment=LEMONADE_EXTRA_MODELS_DIR=${MODELS_DIR}
ExecStart=/usr/local/bin/lemonade-server serve 
  --host 0.0.0.0 --port 8802 --socket-path /tmp/lemonade-embed.sock --pid-file /tmp/lemonade-embed.pid 
  --extra-models-dir ${MODELS_DIR} --ctx-size 8192 --model ${EMBED_PATH} --llamacpp cuda 
  --llamacpp-args "--flash-attn on --threads 8 --n-gpu-layers 999 --embedding"
StandardOutput=append:${LOG_DIR}/embed.log
StandardError=append:${LOG_DIR}/embed.log
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    # D. Mode Switching Scripts
    cat <<EOF | sudo tee /usr/local/bin/tiger-mode-edu > /dev/null
#!/usr/bin/env bash
sudo systemctl stop lemonade-rag
sudo systemctl reset-failed
sleep 3
sudo systemctl restart lemonade-embed
sleep 5
sudo systemctl restart lemonade-edu
echo ">> [TigerAI] 教學模式已就緒 (8800 + 8802)"
EOF

    cat <<EOF | sudo tee /usr/local/bin/tiger-mode-rag > /dev/null
#!/usr/bin/env bash
sudo systemctl stop lemonade-edu
sudo systemctl reset-failed
sleep 3
sudo systemctl restart lemonade-embed
sleep 5
sudo systemctl restart lemonade-rag
echo ">> [TigerAI] 研究模式已就緒 (8801 + 8802)"
EOF

    sudo chmod +x /usr/local/bin/tiger-mode-edu /usr/local/bin/tiger-mode-rag

    LOG " Reloading systemd and enabling services..."
    sudo systemctl daemon-reload
    sudo systemctl enable lemonade-embed lemonade-rag
    
    # E. Logrotate Configuration
    LOG " Configuring Logrotate for Lemonade logs..."
    sudo tee /etc/logrotate.d/lemonade > /dev/null <<ROT
${LOG_DIR}/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
ROT
    LOG " Configuration complete. Use 'tiger-mode-rag' to start research mode."
}

# --- 3) Logic Execution ---
[ "$(id -u)" -ne 0 ] && ERROR "Please run with sudo."

# --- AMD-only guard ---------------------------------------------------
# Lemonade is an AMD-exclusive service in TigerAI. On NVIDIA / ARM64 hosts
# there is no AMD ROCm GPU, so skip installation entirely — this mirrors the
# k3s deploy.sh which skips Lemonade when the node has no `amd.com/gpu`.
#   /dev/kfd  = AMD Kernel Fusion Driver node, the ROCm compute interface.
#               Present only on AMD ROCm GPUs, never on NVIDIA (/dev/nvidia*).
#               It is also what the amd-compose docker-compose mounts.
#   lspci     = fallback: match an AMD/ATI VGA/3D/Display controller.
detect_amd_gpu() {
    [ -e /dev/kfd ] && return 0
    if command -v lspci >/dev/null 2>&1; then
        lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qiE 'advanced micro devices|radeon|\b(amd|ati)\b' && return 0
    fi
    return 1
}

if ! detect_amd_gpu; then
    LOG " No AMD ROCm GPU detected (no /dev/kfd, no AMD VGA) — Lemonade is AMD-exclusive; skipping installation/configuration on this host."
    exit 0
fi

case "$1" in
    all)
        install_snap
        configure_services
        ;;
    install)
        install_snap
        ;;
    config)
        configure_services
        ;;
    status)
        systemctl status lemonade-edu lemonade-rag lemonade-embed --no-pager || true
        ;;
    restart)
        sudo systemctl restart lemonade-embed lemonade-edu lemonade-rag
        ;;
    purge)
        LOG " ⚠️ Starting FULL PURGE..."
        sudo systemctl stop lemonade-edu lemonade-rag lemonade-embed || true
        sudo systemctl disable lemonade-edu lemonade-rag lemonade-embed || true
        sudo rm -f /etc/systemd/system/lemonade-*.service
        sudo systemctl daemon-reload
        sudo systemctl reset-failed
        sudo rm -f /usr/local/bin/tiger-mode-edu /usr/local/bin/tiger-mode-rag
        LOG "✅ Purge complete."
        ;;
    *)
        usage
        ;;
esac

LOG " Lemonade command finished."

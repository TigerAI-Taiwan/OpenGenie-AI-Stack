#!/usr/bin/env bash
# =====================================================================
# TigerAI arm64 RAG Stack Deployer (ARM64 Optimized)
# Path: deployments/arm64-compose-stack/05-rag-stack-docling-qdrant-mosquitto/deploy.sh
# =====================================================================

set -eo pipefail

# --- 0) Configuration & Variables ---
# Import from local .env first
if [ -f .env ]; then
  export $(grep -v '^#' .env | sed 's/\r//g' | xargs)
fi

# Then import from parent stack .env (overrides local)
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | sed 's/\r//g' | xargs)
fi

# Finally import from tiger-tuning.env (highest priority - hardware optimized)
if [ -f ../tiger-tuning.env ]; then
  export $(grep -v '^#' ../tiger-tuning.env | sed 's/\r//g' | xargs)
fi

# Robust Variable Cleansing (Against Windows CRLF)
for var in $(env | grep -E 'PORT|IMAGE|URL|PATH|USER|PASS|DB|SECRET|TZ|BASE_DIR' | cut -d= -f1); do
  export "$var"="$(echo "${!var}" | tr -d '\r')"
done

LOG_PREFIX="TigerAI RAG"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

usage() {
    echo "Usage: sudo $0 {all | mosquitto | docling | qdrant | down | restart}"
    exit 1
}

[ $# -eq 0 ] && usage

prep_rag_env() {
    LOG " Configuring RAG environment..."
    local RAG_BASE=${BASE_DIR:-/home/wrt/TigerAI}
    sudo mkdir -p "$RAG_BASE/docling" "$RAG_BASE/qdrant" "$RAG_BASE/mosquitto/config" "$RAG_BASE/mosquitto/data" "$RAG_BASE/mosquitto/log"
    sudo chown -R 1001:1001 "$RAG_BASE/docling"          # docling-serve container runs as UID 1001
    sudo chown -R "${SUDO_USER:-wrt}":"${SUDO_USER:-wrt}" "$RAG_BASE/qdrant"
    sudo chown -R 1883:1883 "$RAG_BASE/mosquitto"
    
    if [ ! -f "$RAG_BASE/mosquitto/config/mosquitto.conf" ]; then
      echo -e "persistence true\npersistence_location /mosquitto/data/\nlog_dest file /mosquitto/log/mosquitto.log\nlistener 1883\nallow_anonymous true" | sudo tee "$RAG_BASE/mosquitto/config/mosquitto.conf" >/dev/null
    fi
}

setup_python_env() {
    LOG " Setting up Python virtual environment for MQTT monitors..."

    # If .venv exists but is broken (missing activate), remove it
    if [ -d ".venv" ] && [ ! -f ".venv/bin/activate" ]; then
        LOG " Removing broken .venv..."
        rm -rf .venv
    fi

    # Create venv if not present; install python3-venv and retry if needed
    if [ ! -f ".venv/bin/activate" ]; then
        if ! python3 -m venv .venv 2>/dev/null; then
            LOG " python3-venv might be missing. Installing..."
            sudo apt-get install -y python3-venv || ERROR "Failed to install python3-venv."
            rm -rf .venv
            python3 -m venv .venv || ERROR "Failed to create python venv after installing python3-venv."
        fi
    fi

    source .venv/bin/activate
    pip install --upgrade pip > /dev/null
    pip install aiomqtt python-dotenv > /dev/null
    LOG " Python environment ready."
}

ensure_network() {
    docker network inspect ai_stack_net >/dev/null 2>&1 || docker network create ai_stack_net
}

ACTION=$1

case "$ACTION" in
    all)
        setup_python_env
        prep_rag_env
        ensure_network
        LOG " Starting RAG Stack (Docling, Qdrant, Mosquitto)..."
        docker compose up -d
        ;;
    docling|qdrant|mosquitto)
        [ "$ACTION" = "mosquitto" ] && prep_rag_env
        ensure_network
        LOG " Starting specific service: $ACTION..."
        docker compose up -d "$ACTION"
        ;;
    down)
        LOG " Stopping RAG services..."
        docker compose down
        ;;
    restart)
        LOG " Restarting RAG Stack..."
        # docker compose down && bash $0 all
        docker compose restart 
        ;;
    *)
        usage
        ;;
esac

LOG " RAG Deployment command finished."

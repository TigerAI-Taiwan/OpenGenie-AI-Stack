#!/usr/bin/env bash
# =====================================================================
# TigerAI RAG Stack Deployer
# Path: deployments/nvidia-compose-stack/05-rag-stack-docling-qdrant-mosquitto/deploy.sh
# =====================================================================

set -eo pipefail

# --- 0) Configuration & Variables ---
# Import from local .env first
if [ -f .env ]; then
  export $(grep -v '^#' .env | sed 's/\r//g' | xargs)
fi

# Then import from tuning if exists
if [ -f ../tiger-tuning.env ]; then
  export $(grep -v '^#' ../tiger-tuning.env | sed 's/\r//g' | xargs)
fi

# Finally import from parent stack .env (if exists)
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | sed 's/\r//g' | xargs)
fi

# And global root .env (highest priority overrides)
if [ -f ../../.env ]; then
  export $(grep -v '^#' ../../.env | sed 's/\r//g' | xargs)
fi

# Robust Variable Cleansing (Against Windows CRLF)
for var in $(env | grep -E 'PORT|IMAGE|URL|PATH|USER|PASS|DB|SECRET|TZ|LANG' | cut -d= -f1); do
  export "$var"="$(echo "${!var}" | tr -d '\r')"
done

LOG_PREFIX="TigerAI RAG"
BASE_DIR="${BASE_DIR:-/home/wrt/TigerAI}"
MQTT_HOST_DIR="${MQTT_HOST_DIR:-$BASE_DIR/mosquitto}"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

usage() {
    echo "Usage: sudo $0 {all | mosquitto | docling | qdrant}"
    exit 1
}

[ $# -eq 0 ] && usage

prep_rag_env() {
    LOG " Configuring RAG environment..."
    local _BASE="${BASE_DIR:-/home/wrt/TigerAI}"
    local _MQTT="${MQTT_HOST_DIR:-$_BASE/mosquitto}"
    sudo mkdir -p "$_BASE/docling" "$_BASE/qdrant" "$_MQTT/config" "$_MQTT/data" "$_MQTT/log"
    sudo chown -R 1001:1001 "$_BASE/docling"          # docling-serve container runs as UID 1001
    sudo chown -R "${SUDO_USER:-wrt}":"${SUDO_USER:-wrt}" "$_BASE/qdrant"
    sudo chown -R 1883:1883 "$_MQTT"
    if [ ! -f "$_MQTT/config/mosquitto.conf" ]; then
      echo -e "persistence true\npersistence_location /mosquitto/data/\nlog_dest file /mosquitto/log/mosquitto.log\nlistener 1883\nallow_anonymous true" | sudo tee "$_MQTT/config/mosquitto.conf" >/dev/null
    fi
}

ensure_network() {
    docker network inspect ai_stack_net >/dev/null 2>&1 || docker network create ai_stack_net
}

setup_python_env() {
    LOG " Setting up Python virtual environment for MQTT monitors..."

    # If .venv exists but is broken (missing activate), remove it
    if [ -d ".venv" ] && [ ! -f ".venv/bin/activate" ]; then
        LOG " Removing broken .venv..."
        rm -rf .venv
    fi

    # Create venv if not present
    if [ ! -f ".venv/bin/activate" ]; then
        # Try to create; if it fails due to missing ensurepip, install and retry
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

ACTION=$1

# Smart Docling Image Check
check_docling_image() {
    if [[ "$ACTION" == "all" || "$ACTION" == "docling" ]]; then
        local _IMG="${DOCLING_IMAGE:-ghcr.io/docling-project/docling-serve-cu128:latest}"
        # Check if image exists locally (using grep on the full image string including SHA)
        if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "docling-serve-cu128"; then
            LOG "📥 Docling NVIDIA CUDA image not found locally. Pulling from registry..."
            docker pull "$_IMG"
            LOG "✅ Docling NVIDIA CUDA image ready."
        else
            LOG "✅ Docling NVIDIA CUDA image already exists, skipping pull."
        fi
    fi
}

prep_rag_env
ensure_network
check_docling_image

case "$ACTION" in
    all)
        setup_python_env
        LOG " Starting Full RAG Stack..."
        docker compose up -d
        ;;
    mosquitto|docling|qdrant)
        LOG " Starting specific service: $ACTION..."
        docker compose up -d "$ACTION"
        ;;
    *)
        usage
        ;;
esac

LOG " RAG Deployment command finished."

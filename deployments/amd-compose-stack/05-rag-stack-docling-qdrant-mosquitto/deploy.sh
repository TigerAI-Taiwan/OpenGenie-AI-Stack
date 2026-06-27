#!/usr/bin/env bash
# =====================================================================
# TigerAI RAG Stack Deployer
# Path: deployments/amd-compose-stack/05-rag-stack-docling-qdrant-mosquitto/deploy.sh
# =====================================================================

set -eo pipefail

# --- 0) Configuration & Variables ---
# Import from local .env first (with CRLF handling)
if [ -f .env ]; then
  export $(grep -v '^#' .env | sed 's/\r//g' | xargs)
fi

# Then import from parent stack .env (overrides local, with CRLF handling)
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | sed 's/\r//g' | xargs)
fi

# Finally import from tiger-tuning.env (highest priority - hardware optimized)
if [ -f ../tiger-tuning.env ]; then
  export $(grep -v '^#' ../tiger-tuning.env | sed 's/\r//g' | xargs)
fi

LOG_PREFIX="TigerAI RAG"
MQTT_HOST_DIR="$BASE_DIR/mosquitto"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

usage() {
    echo "Usage: sudo $0 {all | mosquitto | docling | qdrant}"
    exit 1
}

[ $# -eq 0 ] && usage

# Fallback defaults
BASE_DIR=${BASE_DIR:-/home/wrt/TigerAI}
DOCLING_IMAGE=${DOCLING_IMAGE:-ghcr.io/docling-project/docling-serve-rocm:main}
MQTT_HOST_DIR="$BASE_DIR/mosquitto"

prep_rag_env() {
    LOG " Configuring RAG environment..."
    sudo mkdir -p "$BASE_DIR/docling" "$BASE_DIR/qdrant" "$MQTT_HOST_DIR/config" "$MQTT_HOST_DIR/data" "$MQTT_HOST_DIR/log"
    REAL_USER="${SUDO_USER:-${USER:-wrt}}"
    sudo chown -R 1001:1001 "$BASE_DIR/docling"          # docling-serve container runs as UID 1001
    sudo chown -R "$REAL_USER":"$REAL_USER" "$BASE_DIR/qdrant"
    sudo chown -R 1883:1883 "$MQTT_HOST_DIR"
    if [ ! -f "$MQTT_HOST_DIR/config/mosquitto.conf" ]; then
      echo -e "persistence true\npersistence_location /mosquitto/data/\nlog_dest file /mosquitto/log/mosquitto.log\nlistener 1883\nallow_anonymous true" | sudo tee "$MQTT_HOST_DIR/config/mosquitto.conf" >/dev/null
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

# Smart Docling Image Check
check_docling_image() {
    if [[ "$ACTION" == "all" || "$ACTION" == "docling" ]]; then
        if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -qx "$DOCLING_IMAGE"; then
            LOG "Detected Docling image not present ($DOCLING_IMAGE)..."
            local DOCLING_CLONE_DIR="/tmp/docling-serve-build"
            sudo apt-get update && sudo apt-get install -y git make
            [ -d "$DOCLING_CLONE_DIR" ] || git clone --branch main https://github.com/docling-project/docling-serve.git "$DOCLING_CLONE_DIR"
            pushd "$DOCLING_CLONE_DIR" > /dev/null
            LOG "Building Docling ROCm Image (this will take a while)..."
            sudo make docling-serve-rocm-image
            docker tag ghcr.io/docling-project/docling-serve-rocm:main "$DOCLING_IMAGE"
            popd > /dev/null
            LOG "✅ Docling image built and tagged."
        else
            LOG "✅ Detected Docling image, skipping build."
        fi
    fi
}

ACTION=$1
prep_rag_env
ensure_network
check_docling_image

case "$ACTION" in
    all)
        setup_python_env
        LOG " Starting RAG Stack (Docling, Qdrant, Mosquitto)..."
        docker compose up -d
        ;;
    docling|qdrant|mosquitto)
        LOG " Starting specific service: $ACTION..."
        docker compose up -d "$ACTION"
        ;;
    down)
        LOG " Stopping RAG services..."
        docker compose down
        ;;
    restart)
        LOG " Restarting RAG Stack..."
        docker compose down && $0 all
        ;;
    *)
        usage
        ;;
esac

LOG " RAG Deployment command finished."

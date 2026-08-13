#!/usr/bin/env bash
# =====================================================================
# TigerAI RAG Stack Deployer (Docling, Qdrant, Mosquitto)
# Path: deployments/compose-stack/05-rag-stack-docling-qdrant-mosquitto/deploy.sh
#
# All three platforms carry an overlay — see docker-compose.base.yaml.
#
# Merged from the three former deploy.sh scripts. The env loading, colors,
# logging and ensure_network boilerplate now lives in lib/common.sh. What
# genuinely differed was the Docling image preparation, which is now branched
# on TIGER_PLATFORM:
#   amd    — builds the ROCm image from source if it is not present locally
#   nvidia — pulls the CUDA image if it is not present locally
#   arm64  — had no image preparation at all; still none, it uses the CPU image
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI RAG"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

BASE_DIR="${BASE_DIR:-/home/wrt/TigerAI}"
MQTT_HOST_DIR="${BASE_DIR}/mosquitto"

usage() {
    echo "Usage: sudo $0 {all | mosquitto | docling | qdrant | down | restart}"
    exit 1
}

[ $# -eq 0 ] && usage

prep_rag_env() {
    LOG "Configuring the RAG environment..."
    sudo mkdir -p "$BASE_DIR/docling" "$BASE_DIR/qdrant" \
        "$MQTT_HOST_DIR/config" "$MQTT_HOST_DIR/data" "$MQTT_HOST_DIR/log"
    local REAL_USER="${SUDO_USER:-${USER:-wrt}}"
    sudo chown -R 1001:1001 "$BASE_DIR/docling"   # docling-serve runs as UID 1001
    sudo chown -R "$REAL_USER":"$REAL_USER" "$BASE_DIR/qdrant"
    sudo chown -R 1883:1883 "$MQTT_HOST_DIR"
    # No mosquitto.conf is generated here any more. It used to be written with
    # `allow_anonymous true` and no password file, so the broker accepted
    # anyone who could reach port 1883 while the healthcheck passed credentials
    # that were never checked. The config now ships as
    # resource/_shared/mosquitto.conf and is mounted read-only; the password
    # file is generated inside the container at start-up.
    #
    # An existing host still has the old file at
    # $MQTT_HOST_DIR/config/mosquitto.conf. It is no longer mounted, so it has
    # no effect — see docs/MIGRATION.md before deleting it.
}

setup_python_env() {
    LOG "Setting up the Python virtual environment for the MQTT monitor..."
    # The venv lives at the module level. monitor_device.py itself lives under
    # resource/_shared/, which holds tracked files only.
    cd "$SCRIPT_DIR"

    # A .venv without bin/activate is broken; rebuild it.
    if [ -d ".venv" ] && [ ! -f ".venv/bin/activate" ]; then
        LOG "Removing a broken .venv..."
        rm -rf .venv
    fi

    if [ ! -f ".venv/bin/activate" ]; then
        if ! python3 -m venv .venv 2>/dev/null; then
            LOG "python3-venv may be missing. Installing..."
            sudo apt-get install -y python3-venv || ERROR "Failed to install python3-venv."
            rm -rf .venv
            python3 -m venv .venv || ERROR "Failed to create the venv after installing python3-venv."
        fi
    fi

    # shellcheck disable=SC1091
    source .venv/bin/activate
    pip install --upgrade pip > /dev/null
    pip install aiomqtt python-dotenv > /dev/null
    deactivate
    LOG "Python environment ready."
}

# Docling image preparation. Only runs for the actions that start docling.
check_docling_image() {
    case "$ACTION" in
        all|docling) ;;
        *) return 0 ;;
    esac

    case "$TIGER_PLATFORM" in
        amd)
            # No AMD GPU build is published, so it is built from source once.
            local img="${DOCLING_IMAGE:-ghcr.io/docling-project/docling-serve-rocm:main}"
            if docker images --format "{{.Repository}}:{{.Tag}}" | grep -qx "$img"; then
                LOG "✅ Docling image present, skipping build."
                return 0
            fi
            LOG "Docling image not present ($img). Building..."
            local clone_dir="/tmp/docling-serve-build"
            sudo apt-get update && sudo apt-get install -y git make
            [ -d "$clone_dir" ] || git clone --branch main \
                https://github.com/docling-project/docling-serve.git "$clone_dir"
            pushd "$clone_dir" > /dev/null
            LOG "Building the Docling ROCm image (this takes a while)..."
            sudo make docling-serve-rocm-image
            docker tag ghcr.io/docling-project/docling-serve-rocm:main "$img"
            popd > /dev/null
            LOG "✅ Docling image built and tagged."
            ;;
        nvidia)
            local img="${DOCLING_IMAGE:-ghcr.io/docling-project/docling-serve-cu128:latest}"
            if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "docling-serve-cu128"; then
                LOG "✅ Docling CUDA image already present, skipping pull."
                return 0
            fi
            LOG "📥 Docling CUDA image not found locally. Pulling..."
            docker pull "$img"
            LOG "✅ Docling CUDA image ready."
            ;;
        arm64)
            # The arm64 stack never prepared an image; compose pulls the CPU
            # build on demand.
            ;;
    esac
}

ACTION="$1"
prep_rag_env
ensure_network
check_docling_image

case "$ACTION" in
    all)
        setup_python_env
        LOG "Starting the RAG stack (Docling, Qdrant, Mosquitto)..."
        tiger_compose up -d
        ;;
    docling|qdrant|mosquitto)
        LOG "Starting specific service: $ACTION..."
        tiger_compose up -d "$ACTION"
        ;;
    down)
        LOG "Stopping RAG services..."
        tiger_compose down
        ;;
    restart)
        LOG "Restarting the RAG stack..."
        tiger_compose down
        tiger_compose up -d
        ;;
    *)
        usage
        ;;
esac

LOG "RAG deployment command finished."

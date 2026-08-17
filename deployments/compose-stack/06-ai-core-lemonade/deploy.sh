#!/usr/bin/env bash
# =====================================================================
# TigerAI Lemonade AI Core Deployer
# Path: deployments/compose-stack/06-ai-core-lemonade/deploy.sh
#
# amd ONLY. Lemonade is a Vulkan/ROCm inference engine and is deployed on the
# AMD platform alone. On nvidia and arm64 the LLM inference path is Ollama in
# 03-ai-interface, and this module exits cleanly without doing anything.
#
# Before the stack merge the nvidia and arm64 stacks each shipped their own
# copy of this module, which installed native systemd units (lemonade-edu /
# -rag / -embed). That was never intended: neither platform's .env.example
# defines a single Lemonade variable, so those units ran entirely on hardcoded
# fallbacks. Existing nvidia and arm64 machines need those units removed —
# see docs/MIGRATION.md.
#
# tiger-mode is a mutually exclusive pair: edu is always up, and embed and rag
# take turns. Anything that restarts Lemonade should ask what is running
# rather than assume a fixed set.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Lemonade"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

if [ "$TIGER_PLATFORM" != "amd" ]; then
    LOG "Lemonade is an amd-only module; skipping on ${TIGER_PLATFORM}."
    exit 0
fi

usage() {
    echo "Usage: sudo $0 {all | edu | rag | status | logs | down | restart | purge}"
    exit 1
}

[ $# -eq 0 ] && usage
ACTION="$1"

# Fallback defaults
MODELS_DIR=${MODELS_DIR:-/home/wrt/TigerAI/models}
LEMONADE_API_KEY=${LEMONADE_API_KEY:-}
TIGER_CPU_THREADS=${TIGER_CPU_THREADS:-16}
GGML_VULKAN_DEVICE_EDU=${GGML_VULKAN_DEVICE_EDU:-0}
GGML_VULKAN_DEVICE_RAG=${GGML_VULKAN_DEVICE_RAG:-0}
GGML_VULKAN_DEVICE_EMBED=${GGML_VULKAN_DEVICE_EMBED:-0}
# Looked up on the host: the compose group_add entries fall back to 44/992,
# which is wrong wherever the distro numbers these groups differently — the
# containers then cannot reach /dev/dri.
TIGER_RENDER_GID=${TIGER_RENDER_GID:-$(getent group render 2>/dev/null | cut -d: -f3 || echo "992")}
TIGER_VIDEO_GID=${TIGER_VIDEO_GID:-$(getent group video  2>/dev/null | cut -d: -f3 || echo "44")}
export MODELS_DIR LEMONADE_API_KEY TIGER_CPU_THREADS
export GGML_VULKAN_DEVICE_EDU GGML_VULKAN_DEVICE_RAG GGML_VULKAN_DEVICE_EMBED
export TIGER_RENDER_GID TIGER_VIDEO_GID

prep_dirs() {
    REAL_USER="${SUDO_USER:-${USER:-wrt}}"
    sudo mkdir -p "$MODELS_DIR"
    sudo chown -R "$REAL_USER":"$REAL_USER" "$MODELS_DIR"
}

prep_dirs
ensure_network

case "$ACTION" in
    all)
        LOG "Starting the Lemonade stack (EDU + EMBED)..."
        tiger_compose pull
        tiger_compose up -d
        ;;
    edu)
        LOG "Switching to EDU mode (edu + embed)..."
        tiger_compose stop lemonade-rag
        tiger_compose start lemonade-embed lemonade-edu
        LOG "✅ EDU mode active (8800 + 8802)"
        ;;
    rag)
        LOG "Switching to RAG mode (edu + rag)..."
        tiger_compose stop lemonade-embed
        tiger_compose start lemonade-rag lemonade-edu
        LOG "✅ RAG mode active (8800 + 8801)"
        ;;
    status)
        tiger_compose ps
        ;;
    logs)
        tiger_compose logs -f
        ;;
    down)
        LOG "Stopping Lemonade services..."
        tiger_compose down
        ;;
    restart)
        LOG "Restarting Lemonade..."
        tiger_compose down
        tiger_compose up -d
        ;;
    purge)
        WARN "⚠️ Purging Lemonade containers AND their model caches..."
        tiger_compose down -v
        LOG "✅ Purged. Reinstall with: sudo $0 all"
        ;;
    *)
        usage
        ;;
esac

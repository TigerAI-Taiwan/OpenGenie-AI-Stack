#!/usr/bin/env bash
# =====================================================================
# TigerAI AI Core — Ollama Deployer
# Path: deployments/compose-stack/03-ai-core/ollama/deploy.sh
#
# nvidia / arm64 only; deploys only when INFERENCE_BACKEND=ollama, any other value is skipped (exit 0).
# Skipping must exit 0: master-deploy.sh calls this under set -e, and non-zero would abort the whole `all`.
# The service definition comes from the pre-renumber AI-interface module; platform differences live in overlays.
#
# Usage: sudo -E bash ./deploy.sh {all|up|down|restart|status|logs}
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # read by lib/common.sh's LOG/WARN/ERROR
TIGER_LOG_PREFIX="TigerAI Ollama"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    echo "Usage: sudo -E bash $0 {all | up | down | restart | status | logs}"
    echo "  all / up : start ollama (models in /var/lib/ollama)"
    echo "  down     : stop and remove the container (models are not touched)"
    echo "  restart  : down + up"
    echo "  status   : container status"
    echo "  logs     : follow the logs"
    exit 1
}

[ $# -eq 0 ] && usage
ACTION=$1

# Stop/inspect actions ignore INFERENCE_BACKEND and the platform: switching backends still removes this project's
# containers; containers of the pre-renumber project are handled by migrations/renumber-migrate.sh.
case "$ACTION" in
    down|status|logs) ;;
    *)
        # An unsupported platform (AMD selecting ollama) is rejected by resolve's validation.
        tiger_inference_backend_resolve
        if [ "$TIGER_INFERENCE_BACKEND" != "ollama" ]; then
            SKIP "INFERENCE_BACKEND=${TIGER_INFERENCE_BACKEND}, skipping 03-ai-core/ollama"
            exit 0
        fi
        ;;
esac

ensure_network

case "$ACTION" in
    all|up)
        LOG " Starting Ollama..."
        # Pull first, then remove other backends: a failed pull leaves the old backend serving.
        tiger_compose pull
        tiger_inference_backend_cutover
        tiger_compose up -d
        LOG "✅ Ollama started (11434)"
        ;;
    down)
        tiger_compose down --remove-orphans
        ;;
    restart)
        tiger_compose pull
        tiger_compose down --remove-orphans
        tiger_inference_backend_cutover
        tiger_compose up -d
        LOG "✅ Ollama started (11434)"
        ;;
    status)
        tiger_compose ps
        ;;
    logs)
        tiger_compose logs -f
        ;;
    *)
        usage
        ;;
esac

#!/usr/bin/env bash
# =====================================================================
# TigerAI VRAM Purge & Service Refresh (Zero-Reboot Maintenance) — shared body
# Path: deployments/compose-stack/08-backup-recovery/resource/_shared/vram-purge-common.sh
#
# Sourced by resource/<platform>/vram-purge.sh. Defines
# tiger_vram_purge_main() and does NOT call it — the entry point does, after
# appending its own restart steps to TIGER_PURGE_EXTRA_STEPS.
#
# The -common.sh suffix is deliberate: tiger_res resolves
# resource/<platform>/ before resource/_shared/, so a platform entry point
# named vram-purge.sh that went missing would silently fall back to this file,
# which defines a function and calls nothing — exiting 0 having freed no VRAM
# at all. Different names make that impossible.
#
# WARNING: must stay at the FIRST level of resource/_shared/. The `../..`
# below is a hard-coded depth.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Maintenance"
# shellcheck source=../../../lib/common.sh
source "${TIGER_MODULE_DIR}/../lib/common.sh"

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ERROR "vram-purge-common.sh must be sourced by a platform entry point, not run directly."
fi

# Platform entry points append function names here; each is called at the end
# of the purge.
TIGER_PURGE_EXTRA_STEPS=()

# Run a compose command against another module, the way that module's own
# deploy.sh would — base plus the platform overlay plus the env files.
tiger_purge_compose() {
    local module="$1"; shift
    local saved="$TIGER_MODULE_DIR"
    TIGER_MODULE_DIR="${TIGER_STACK_DIR}/${module}"
    [ -d "$TIGER_MODULE_DIR" ] || { TIGER_MODULE_DIR="$saved"; ERROR "module not found: $module"; }
    tiger_compose "$@"
    local rc=$?
    TIGER_MODULE_DIR="$saved"
    return $rc
}

tiger_vram_purge_main() {
    LOG "Periodical VRAM purge starting..."

    # 1. Restart the AI interface so Ollama releases its resident models.
    LOG "Restarting phase 03 AI interfaces..."
    tiger_purge_compose 03-ai-interface-ollama-openwebui-redis restart ollama

    # 2. Whatever this platform added.
    local step
    for step in "${TIGER_PURGE_EXTRA_STEPS[@]:-}"; do
        [ -n "$step" ] || continue
        "$step"
    done

    LOG "VRAM purge complete. GPU memory held by AI models has been released."
    LOG "System uptime preserved. No reboot was required."
}

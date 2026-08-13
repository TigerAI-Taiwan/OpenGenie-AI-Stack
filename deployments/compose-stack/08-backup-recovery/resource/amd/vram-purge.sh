#!/usr/bin/env bash
# =====================================================================
# TigerAI VRAM Purge — amd entry point
# Path: deployments/compose-stack/08-backup-recovery/resource/amd/vram-purge.sh
#
# The entry point does three things and nothing else — path derivation, the
# compose bridge and the Ollama restart all live in the shared body:
#   1. export TIGER_PLATFORM=amd
#   2. append this platform's extra restart step — amd is the only platform
#      that deploys 06-ai-core-lemonade
#   3. call tiger_vram_purge_main
#
# NOTE: this also fixes two long-standing defects in the pre-merge script,
# which was byte-identical on all three platforms and did
# `systemctl restart lemonade-{edu,rag}.service || true`:
#   * On amd, Lemonade runs as containers, so those systemctl calls always
#     failed and were swallowed — amd's Lemonade VRAM was never freed.
#   * The list was hard-coded to edu and rag. edu is always up while embed and
#     rag take turns, so restarting a fixed pair could start the service the
#     current tiger-mode had deliberately stopped, and embed was never
#     restarted at all.
# Querying what is actually running avoids both: there is no list to get wrong.
#
# WARNING: must stay at the FIRST level of resource/amd/. The `../..` is a
# hard-coded depth.
# =====================================================================

export TIGER_PLATFORM=amd

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
# shellcheck source=../_shared/vram-purge-common.sh
source "${TIGER_MODULE_DIR}/resource/_shared/vram-purge-common.sh"

purge_lemonade() {
    LOG "Refreshing the phase 06 Lemonade engine..."
    local running
    running="$(tiger_purge_compose 06-ai-core-lemonade ps --services --status running 2>/dev/null || true)"
    if [ -z "$running" ]; then
        WARN "No Lemonade services are running; nothing to refresh."
        return 0
    fi
    # shellcheck disable=SC2086  # deliberate word splitting: one arg per service
    tiger_purge_compose 06-ai-core-lemonade restart $running
    LOG "Restarted: $(echo "$running" | tr '\n' ' ')"
}
TIGER_PURGE_EXTRA_STEPS+=(purge_lemonade)

tiger_vram_purge_main

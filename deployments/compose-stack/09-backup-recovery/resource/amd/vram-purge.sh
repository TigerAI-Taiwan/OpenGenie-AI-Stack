#!/usr/bin/env bash
# =====================================================================
# TigerAI VRAM Purge & Service Refresh (Zero-Reboot Maintenance) — AMD ROCm/Vulkan entry
# Path: deployments/compose-stack/09-backup-recovery/resource/amd/vram-purge.sh
#
# 入口只做三件事，其餘全部留在共用主體裡（不要把路徑推導、compose 橋接、
# Ollama 重啟複製過來）：
#   1. 指定自己的平台 + source resource/_shared/vram-purge-common.sh
#   2. 追加本平台專屬的重啟項 —— 只有 amd 會部署 06-ai-core-lemonade
#   3. 呼叫 tiger_vram_purge_main
# =====================================================================

# 這支腳本會被 crontab 直接叫起來（環境裡沒有 master-deploy.sh 的變數），
# 而「選到哪個平台的入口檔」本身就已經決定了平台，所以這裡直接指定。
# Load bearing: the cron entry sets no TIGER_PLATFORM, so this is the only
# place vram-purge-common.sh gets it. Do not remove.
export TIGER_PLATFORM=amd

TIGER_PURGE_ENTRY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
COMMON="$(dirname "$TIGER_PURGE_ENTRY")/../_shared/vram-purge-common.sh"
if [ ! -f "$COMMON" ]; then
    echo "[TigerAI Maintenance ERROR] 找不到共用主體：$COMMON" >&2
    exit 1
fi
# shellcheck source=../_shared/vram-purge-common.sh
source "$COMMON"

# AMD-only: Lemonade AI core (06-ai-core-lemonade).
# NOTE: Lemonade on AMD runs as Docker containers (lemonade-edu / rag / embed),
#       NOT systemd services.
# NOTE: tiger-mode keeps only two of the three running (edu+embed or edu+rag).
#       A bare `docker compose restart` would restart "all stopped and running
#       services" and thus wake the container tiger-mode deliberately stopped,
#       so we restart only the services currently in the `running` state.
purge_lemonade() {
    LOG "Refreshing Phase 06 Lemonade Engine..."
    local running
    running="$(purge_compose 06-ai-core-lemonade ps --services --status running || true)"
    if [ -n "$running" ]; then
        LOG "Restarting running Lemonade services: $(echo "$running" | tr '\n' ' ')"
        # shellcheck disable=SC2086  # intentional word-splitting: one service name per line
        purge_compose 06-ai-core-lemonade restart $running
    else
        LOG "No Lemonade containers running — skipping (tiger-mode may be down)."
    fi
}
TIGER_PURGE_EXTRA_STEPS+=(purge_lemonade)

tiger_vram_purge_main "$@"

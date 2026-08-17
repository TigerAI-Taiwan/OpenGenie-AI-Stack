#!/usr/bin/env bash
# =====================================================================
# TigerAI VRAM Purge & Service Refresh (Zero-Reboot Maintenance) — ARM64 Optimized entry
# Path: deployments/compose-stack/08-backup-recovery/resource/arm64/vram-purge.sh
#
# 入口只做兩件事，其餘全部留在共用主體裡（不要把路徑推導、compose 橋接、
# Ollama 重啟複製過來）：
#   1. 指定自己的平台 + source resource/_shared/vram-purge-common.sh
#   2. 呼叫 tiger_vram_purge_main
# arm64 沒有平台專屬的重啟項 —— Lemonade（06-ai-core-lemonade）只有 amd 有，
# 這個平台的 LLM 推論由 03-ai-interface 的 Ollama 負責，共用主體已經涵蓋。
# =====================================================================

# 這支腳本會被 crontab 直接叫起來（環境裡沒有 master-deploy.sh 的變數），
# 而「選到哪個平台的入口檔」本身就已經決定了平台，所以這裡直接指定。
# Load bearing: the cron entry sets no TIGER_PLATFORM, so this is the only
# place vram-purge-common.sh gets it. Do not remove.
export TIGER_PLATFORM=arm64

TIGER_PURGE_ENTRY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
COMMON="$(dirname "$TIGER_PURGE_ENTRY")/../_shared/vram-purge-common.sh"
if [ ! -f "$COMMON" ]; then
    echo "[TigerAI Maintenance ERROR] 找不到共用主體：$COMMON" >&2
    exit 1
fi
# shellcheck source=../_shared/vram-purge-common.sh
source "$COMMON"

tiger_vram_purge_main "$@"

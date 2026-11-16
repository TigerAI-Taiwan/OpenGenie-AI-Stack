#!/usr/bin/env bash
# =====================================================================
# TigerAI VRAM Purge & Service Refresh — 三平台共用主體
# Path: deployments/compose-stack/08-backup-recovery/resource/_shared/vram-purge-common.sh
#
# 這個檔案「不是」入口，而是由 resource/<platform>/vram-purge.sh source 進來的
# 共用主體：路徑推導、依推論後端重啟（ollama／lemonade）、tiger_vram_purge_main。
#
# ⚠️ 刻意不叫 vram-purge.sh：tiger_res 的查找順序是
#    resource/<platform>/ → resource/_shared/，若這裡也叫 vram-purge.sh，
#    某平台入口檔一旦消失就會靜默退回本檔 —— 而本檔沒有呼叫 tiger_vram_purge_main，
#    結果是「什麼都沒做卻回 0」的假成功。
#    改名之後 `tiger_res vram-purge.sh` 只會命中平台入口，找不到時由
#    tiger_res 自己 ERROR + exit 1。
#
# ⚠️ 這裡「不」呼叫 tiger_vram_purge_main —— 那一步固定由平台入口在最後做，
#    平台專屬的重啟項才排得進去（目前三平台都沒有）。
# =====================================================================

# 被單獨執行時直接報錯：source 進來時 $0 是平台入口，直接跑時兩者相同。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "[TigerAI Maintenance ERROR] $(basename "${BASH_SOURCE[0]}") 必須由 resource/<platform>/vram-purge.sh source，不可單獨執行。" >&2
    exit 1
fi

# 平台入口必須先設好 TIGER_PLATFORM（它自己就代表一個平台），因為本腳本會被
# cron 直接叫起來，環境裡沒有 master-deploy.sh 傳下來的變數。
if [ -z "${TIGER_PLATFORM:-}" ]; then
    echo "[TigerAI Maintenance ERROR] TIGER_PLATFORM 未設定 —— 平台入口 vram-purge.sh 應該在 source 本檔之前指定。" >&2
    exit 1
fi

# --- 路徑推導 ---------------------------------------------------------------
# 一律以本檔位置推導，不依賴 CWD（cron 起來時 CWD 是家目錄）。
# ⚠️ 被 source 時 ${BASH_SOURCE[0]} 仍指向本檔（$0 才是入口檔），所以推導出來的
#    是 resource/_shared/。本檔位於
#    <stack>/08-backup-recovery/resource/_shared/vram-purge-common.sh，
#    因此 ../.. 是模組目錄、../../.. 是 stack 根目錄。
TIGER_PURGE_SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_MODULE_DIR="$(cd "${TIGER_PURGE_SHARED_DIR}/../.." && pwd -P)"
TIGER_PURGE_STACK_DIR="$(cd "${TIGER_MODULE_DIR}/.." && pwd -P)"

# shellcheck disable=SC2034  # 由 lib/common.sh 的 LOG/WARN/ERROR 讀取
TIGER_LOG_PREFIX="TigerAI Maintenance"
# shellcheck source=../../../lib/common.sh
source "${TIGER_PURGE_STACK_DIR}/lib/common.sh"

# 平台入口可在 source 之後追加自己的步驟（函式名陣列），tiger_vram_purge_main 依序執行。
TIGER_PURGE_EXTRA_STEPS=()

# Container names are fixed; no tiger_compose needed to restart them.
purge_ollama() {
    LOG "Restarting Phase 03 Ollama..."
    docker container inspect ollama >/dev/null 2>&1 \
        || ERROR "No ollama container - 03-ai-core/ollama is not deployed, nothing to restart."
    docker restart ollama >/dev/null
}

# tiger-mode deliberately stops one of them, so only the running ones are restarted.
purge_lemonade() {
    LOG "Refreshing Phase 03 Lemonade Engine..."
    local c state running="" found=""
    for c in lemonade-edu lemonade-rag lemonade-embed; do
        state="$(docker container inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" || continue
        found=1
        if [ "$state" = "true" ]; then running="${running:+$running }$c"; fi
    done
    [ -n "$found" ] || ERROR "No lemonade-* container - 03-ai-core/lemonade is not deployed, nothing to restart."
    if [ -z "$running" ]; then
        WARN "No Lemonade containers running — skipping (tiger-mode may be down)."
        return 0
    fi
    LOG "Restarting running Lemonade services: ${running}"
    # shellcheck disable=SC2086  # one argument per container name
    docker restart $running >/dev/null
}

# $1 = inference backend, passed by deploy.sh (purge / cron) as the effective value; fixed in the cron line, never re-resolved.
tiger_vram_purge_main() {
    local backend="${1:-}"
    case "$backend" in
        ollama|lemonade) ;;
        "") ERROR "No inference backend given. Use sudo -E TIGER_PLATFORM=${TIGER_PLATFORM} bash ${TIGER_MODULE_DIR}/deploy.sh purge; for cron re-run deploy.sh cron (old cron lines carry no backend)." ;;
        *)  ERROR "Unknown inference backend '${backend}' (ollama / lemonade)." ;;
    esac

    LOG " Periodical VRAM Purge Starting (INFERENCE_BACKEND=${backend})..."

    "purge_${backend}"

    local step
    for step in ${TIGER_PURGE_EXTRA_STEPS[@]+"${TIGER_PURGE_EXTRA_STEPS[@]}"}; do
        "$step"
    done

    LOG " VRAM Purge Complete. ${backend} restarted; GPU memory was released and re-allocated."
    LOG "System uptime preserved. No reboot was required."
}

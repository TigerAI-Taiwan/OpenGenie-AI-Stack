#!/usr/bin/env bash
# =====================================================================
# TigerAI VRAM Purge & Service Refresh — 三平台共用主體
# Path: deployments/compose-stack/09-backup-recovery/resource/_shared/vram-purge-common.sh
#
# 這個檔案「不是」入口，而是由 resource/<platform>/vram-purge.sh source 進來的
# 共用主體：路徑推導、tiger_compose 橋接、Ollama 重啟、tiger_vram_purge_main。
#
# ⚠️ 刻意不叫 vram-purge.sh：tiger_res 的查找順序是
#    resource/<platform>/ → resource/_shared/，若這裡也叫 vram-purge.sh，
#    某平台入口檔一旦消失就會靜默退回本檔 —— 而本檔沒有呼叫 tiger_vram_purge_main，
#    結果是「什麼都沒做卻回 0」的假成功（amd 還會少掉 Lemonade 重啟）。
#    改名之後 `tiger_res vram-purge.sh` 只會命中平台入口，找不到時由
#    tiger_res 自己 ERROR + exit 1。
#
# ⚠️ 這裡「不」呼叫 tiger_vram_purge_main —— 那一步固定由平台入口在最後做，
#    平台專屬的重啟項（例如 amd 的 Lemonade）才排得進去。
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
#    <stack>/09-backup-recovery/resource/_shared/vram-purge-common.sh，
#    因此 ../.. 是模組目錄、../../.. 是 stack 根目錄。
TIGER_PURGE_SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_MODULE_DIR="$(cd "${TIGER_PURGE_SHARED_DIR}/../.." && pwd -P)"
TIGER_PURGE_STACK_DIR="$(cd "${TIGER_MODULE_DIR}/.." && pwd -P)"

# shellcheck disable=SC2034  # 由 lib/common.sh 的 LOG/WARN/ERROR 讀取
TIGER_LOG_PREFIX="TigerAI Maintenance"
# 這裡刻意 source lib/common.sh（而不是像 07 / 09 的共用主體那樣自己載 env）：
# 本腳本要重啟「別的模組」的服務，而 compose 檔在統一 stack 底下叫
# docker-compose.base.yaml + docker-compose.<platform>.yaml —— 舊版那句
# `cd ../03-ai-interface… && docker compose restart ollama` 現在會直接失敗
# （找不到 docker-compose.yaml），就算改成手動拼 -f 也等於把 tiger_compose
# 的疊加與 --env-file 邏輯複製一份。TIGER_MODULE_DIR 已於上面設好，
# lib/common.sh 會沿用它而不是從 BASH_SOURCE 反推。
# shellcheck source=../../../lib/common.sh
source "${TIGER_PURGE_STACK_DIR}/lib/common.sh"

# --- 對其他模組下 compose 指令 ----------------------------------------------
# 用子 shell 暫時改寫 TIGER_MODULE_DIR（master-deploy.sh 的 fallback 路徑同一招）：
# tiger_compose / tiger_env_files 每次呼叫都重讀該變數，所以 -f 疊加與
# --env-file 串接都會對到目標模組自己的檔案。
purge_compose() {
    local module="$1"; shift
    (
        TIGER_MODULE_DIR="${TIGER_PURGE_STACK_DIR}/${module}"
        tiger_compose "$@"
    )
}

# --- 共用主體：重啟 Ollama --------------------------------------------------
# 平台入口可在 source 之後追加自己的步驟到 TIGER_PURGE_EXTRA_STEPS（函式名陣列），
# tiger_vram_purge_main 會依序執行。
TIGER_PURGE_EXTRA_STEPS=()

purge_ai_interface() {
    LOG "Restarting Phase 03 AI Interfaces..."
    purge_compose 03-ai-interface-ollama-openwebui-redis restart ollama
}

tiger_vram_purge_main() {
    LOG " Periodical VRAM Purge Starting..."

    # 1. Restart AI Interface (Ollama & OpenWebUI)
    purge_ai_interface

    # 2. 平台專屬步驟（目前只有 amd 的 Lemonade）
    local step
    for step in ${TIGER_PURGE_EXTRA_STEPS[@]+"${TIGER_PURGE_EXTRA_STEPS[@]}"}; do
        "$step"
    done

    LOG " VRAM Purge Complete. All GPU memory associated with AI models has been released."
    LOG "System uptime preserved. No reboot was required."
}

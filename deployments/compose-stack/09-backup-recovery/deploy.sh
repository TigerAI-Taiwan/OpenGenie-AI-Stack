#!/usr/bin/env bash
# =====================================================================
# TigerAI Backup/Recovery Module Initializer
# Path: deployments/compose-stack/09-backup-recovery/deploy.sh
#
# 本模組沒有 compose 檔 —— 備份／還原／VRAM purge 都是 host 上的一次性腳本，
# 所以 deploy.sh 只負責「把腳本準備好」，以及提供搬進 resource/ 之後的替代入口。
#
# Actions:
#   (無參數 / all / 其他)  chmod +x 全部腳本（master-deploy.sh 的 action=all 走這條）
#   cron                   安裝每日 5:00 的 VRAM purge crontab
#   backup                 執行全系統備份
#   restore [args...]      執行還原（args 直接透傳給 restore-tigerai.sh）
#   purge                  執行一次 VRAM purge
#
# ⚠️ 搬進 resource/ 之前，使用者／master-deploy.sh 的入口是模組根目錄下的
#    ./backup-tigerai.sh 等四支腳本。搬完後那些路徑不存在了，上面的 action
#    就是替代入口 —— master-deploy.sh 因此不必知道本模組的檔案佈局
#    （用 `[ -f ./09-backup-recovery/backup-tigerai.sh ]` 當 guard 會永遠 false，
#     而 if 沒中就是「安靜跳過」，備份會默默不執行）。
#
# 檔案歸屬（見 lib/common.sh 的 tiger_res）：
#   resource/_shared/backup-tigerai.sh
#   resource/_shared/restore-tigerai.sh
#   resource/_shared/setup-cron.sh
#                       三平台逐字相同（舊三份只差自己的 "# Path:" 檔頭）。
#   resource/<platform>/vram-purge.sh
#                       各平台的入口（tiger_res 解析到這裡）。薄包裝，只做：
#                       source 共用主體 → 追加平台專屬的重啟項 → tiger_vram_purge_main。
#                       amd 的入口多了 Lemonade（06-ai-core-lemonade，AMD 專屬）。
#   resource/_shared/vram-purge-common.sh
#                       共用主體：路徑推導、tiger_compose 橋接、Ollama 重啟、
#                       tiger_vram_purge_main。刻意不叫 vram-purge.sh —— 否則平台
#                       入口檔一旦消失，tiger_res 會退回 _shared/，而本檔沒有呼叫
#                       tiger_vram_purge_main，結果是「什麼都沒做卻回 0」的假成功
#                       （amd 還會少掉 Lemonade 重啟）。
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # 由 lib/common.sh 的 LOG/WARN/ERROR 讀取
TIGER_LOG_PREFIX="TigerAI Backup/Recovery"
# lib 提供：set -Eeo pipefail + ERR trap、LOG/WARN/ERROR、env 三層載入、
#           ensure_network、tiger_compose、tiger_res
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-}"

# 路徑一律走 tiger_res（不自己拼），檔案不存在時由 tiger_res 報錯並 exit 1。
BACKUP_SCRIPT="$(tiger_res backup-tigerai.sh)"
RESTORE_SCRIPT="$(tiger_res restore-tigerai.sh)"
CRON_SCRIPT="$(tiger_res setup-cron.sh)"
PURGE_SCRIPT="$(tiger_res vram-purge.sh)"

# 用 exec：被委派腳本的退出碼要原封不動傳回呼叫端（backup 在 INCOMPLETE 時回 1，
# restore 在參數不足時印 usage 回 1，master-deploy.sh 靠這個判斷成敗）。
run_host_script() {
    local script="$1"; shift
    chmod +x "$script"
    LOG "Running: $script $*"
    exec bash "$script" "$@"
}

case "$ACTION" in
    cron)
        # setup-cron.sh 位於 resource/_shared/，自己解析不出平台入口，
        # 所以把 tiger_res 已解析好的 vram-purge.sh 路徑當參數傳進去。
        chmod +x "$PURGE_SCRIPT"
        run_host_script "$CRON_SCRIPT" "$PURGE_SCRIPT"
        ;;
    backup)
        # backup-tigerai.sh 目前不吃任何參數，但一樣把 "$@" 交下去 —— 與 restore
        # 對稱，也避免 master-deploy.sh 轉發過來的參數在這裡被靜默吃掉。
        shift
        run_host_script "$BACKUP_SCRIPT" "$@"
        ;;
    restore)
        shift
        run_host_script "$RESTORE_SCRIPT" "$@"
        ;;
    purge)
        run_host_script "$PURGE_SCRIPT"
        ;;
    *)
        # 預設行為（含 master-deploy.sh 傳進來的 `all`）：只把腳本設成可執行。
        # 未知參數也走這裡，維持搬移前的行為（舊 deploy.sh 完全不看參數）。
        chmod +x "$BACKUP_SCRIPT" "$RESTORE_SCRIPT" "$CRON_SCRIPT" "$PURGE_SCRIPT"
        LOG "Initializing Backup/Recovery scripts..."
        LOG "✅ Backup/Recovery module ready."
        ;;
esac

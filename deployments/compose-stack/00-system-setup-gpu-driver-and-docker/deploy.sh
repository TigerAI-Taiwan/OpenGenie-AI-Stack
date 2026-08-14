#!/usr/bin/env bash
# =====================================================================
# TigerAI System Foundation Installer (GPU driver + Docker)
# Path: deployments/compose-stack/00-system-setup-gpu-driver-and-docker/deploy.sh
#
# ⚠️ 本模組是整個 stack 唯一會「改變 host 系統狀態」的模組：裝 GPU 驅動、裝
#    Docker、寫 /etc/sysctl.conf、寫 systemd unit、改 gdm3 設定，跑完通常要
#    reboot。它同時在 master-deploy.sh 的 `init`、`system`、**以及 `all`** 路徑上
#    （`all` 迭代整個 DEPLOY_STEPS，含 index 0），不是只有手動 `system` 才會跑。
#
# 檔案佈局（見 lib/common.sh 的 tiger_res）：
#   resource/<platform>/install.sh
#       每個平台一支**完整且獨立**的安裝腳本，沒有共用主體。這與 07 / 09 的
#       「_shared 主體 + 平台薄包裝」刻意不同 —— 三份舊 deploy.sh 排除註解後
#       amd↔nvidia 差 343 行、amd↔arm64 差 342 行，amd 走 amdgpu-install /
#       DKMS 版本決策 / udev / rocm-gpu-performance.service，nvidia 走 PPA
#       driver / container-toolkit / nvidia-persistenced，兩者沒有可共用的主體。
#       硬抽共用只會做出一個滿是 if 的殼。
#
#   ⚠️ 這裡沒有 resource/_shared/ —— 也就沒有 install.sh 可以被靜默 fallback 到。
#      某平台的 install.sh 一旦消失，tiger_res 會直接 ERROR + exit 1，
#      不會出現「什麼都沒裝卻回 0」的假成功。
#
# 這支 deploy.sh 只做三件事：解析平台腳本、確認 root、把控制權交出去。
# 任何「要裝什麼」的知識都不放在這裡。
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # 由 lib/common.sh 的 LOG/WARN/ERROR 讀取
TIGER_LOG_PREFIX="TigerAI Foundation"
# lib 提供：set -Eeo pipefail + ERR trap、LOG/WARN/ERROR、env 三層載入、
#           TIGER_PLATFORM 驗證、tiger_res
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# 路徑一律走 tiger_res（不自己拼字串）：找不到就由 tiger_res 報錯並 exit 1。
INSTALL_SCRIPT="$(tiger_res install.sh)"

# 三份平台腳本內部都用 `sudo` 逐條執行，三者也都各有自己的 root 檢查。
# 這裡先擋一次，錯誤訊息才會指向 master-deploy.sh 的用法而不是半途某條 sudo。
[ "$(id -u)" -ne 0 ] && ERROR "Please run with sudo (or via: sudo bash master-deploy.sh system)."

LOG "Platform=${TIGER_PLATFORM} → $(basename "$(dirname "$INSTALL_SCRIPT")")/$(basename "$INSTALL_SCRIPT")"

# exec：安裝腳本的退出碼要原封傳回 master-deploy.sh 的 run_step。
# 走一般呼叫的話，lib 的 ERR trap 會先印一行 FAILED 把真正的錯誤訊息推出畫面。
#
# ⚠️ 額外參數原樣透傳，但三支 install.sh 目前都不解析任何參數 —— master-deploy.sh
#    的 run_step 會傳 `all` 進來，那個字被忽略是刻意的（搬移前也是如此）。
exec bash "$INSTALL_SCRIPT" "$@"

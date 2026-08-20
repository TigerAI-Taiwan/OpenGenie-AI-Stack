#!/usr/bin/env bash
# =====================================================================
# TigerAI Compose-Stack Master Deployer （amd / nvidia / arm64 共用）
# Path: deployments/compose-stack/master-deploy.sh
# Version: v2.0.0 (unified)
#
# 取代原本三份 deployments/{amd,nvidia,arm64}-compose-stack/master-deploy.sh。
# 平台差異一律走 TIGER_PLATFORM，compose 檔差異走
#   docker-compose.base.yaml + docker-compose.<platform>.yaml。
#
# 用法：
#   sudo TIGER_PLATFORM=amd bash master-deploy.sh all
#   （或由 deployments/tiger-deploy.sh 偵測硬體後 export 再呼叫）
# =====================================================================

# --- 0) 平台判定（必須在 source lib 之前，lib 會驗證這個變數）---------------
# 順序：呼叫端已 export > 自動偵測。判不出來就直接停，不要猜。
detect_platform() {
    local arch; arch=$(uname -m)
    if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        echo arm64
    elif command -v nvidia-smi >/dev/null 2>&1; then
        echo nvidia
    elif command -v rocm-smi >/dev/null 2>&1 || command -v amd-smi >/dev/null 2>&1 || [ -e /dev/kfd ]; then
        echo amd
    fi
}

if [ -z "${TIGER_PLATFORM:-}" ]; then
    TIGER_PLATFORM=$(detect_platform)
fi
if [ -z "${TIGER_PLATFORM:-}" ]; then
    echo "[Master ERROR] 無法判定 TIGER_PLATFORM（uname -m=$(uname -m)，且找不到 nvidia-smi / rocm-smi / /dev/kfd）。" >&2
    # ${*:+ $*}：無參數時整段不展開，避免印出結尾多一個空格的指令
    echo "               請明確指定：sudo TIGER_PLATFORM={amd|nvidia|arm64} bash $0${*:+ $*}" >&2
    exit 1
fi
export TIGER_PLATFORM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # 由 lib/common.sh 的 LOG/WARN/ERROR 讀取
TIGER_LOG_PREFIX="Master"
# lib 會設定 set -Eeo pipefail / ERR trap / LOG / WARN / ERROR / tiger_compose
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

cd "$SCRIPT_DIR" || exit 1

# --- 1) 權限 -----------------------------------------------------------------
[ "$(id -u)" -ne 0 ] && ERROR "Please run this script with sudo"

# --- 2) 部署順序 -------------------------------------------------------------
# 三平台共用同一份清單，這裡刻意不做任何平台篩選。
#
# 「這個模組在這個平台上要不要做事」由**模組自己**判斷 —— 每支 deploy.sh 都
# source lib/common.sh，那裡保證 TIGER_PLATFORM 已設定且合法（未設 / 不合法會
# 直接 ERROR 退出），所以模組拿得到平台資訊。不適用的模組印訊息後 exit 0。
# 例：06-ai-core-lemonade 是 AMD 專屬，在 nvidia / arm64 上會說明並略過。
#
# ⚠️ 不要在這裡加回 `[ "$TIGER_PLATFORM" = "..." ] && DEPLOY_STEPS+=(...)`。
#    那會讓「哪個平台有哪個模組」同時存在於兩個地方，而修改模組的人不會想到
#    要回來改這裡（07 的佈局註解就這樣過期過三次）。
#
# ⚠️ run_step 的呼叫沒有 `|| true`，配上 set -Eeo pipefail：模組回非 0 會中斷
#    整條 all。所以「平台不適用」必須 exit 0，只有「真的失敗」才回非 0。
DEPLOY_STEPS=(
    "00-system-setup-gpu-driver-and-docker"
    "01-infra-webssh-portainer"
    "02-database-postgres-pgadmin"
    "03-ai-interface-ollama-openwebui-redis"
    "04-automation-n8n"
    "05-rag-stack-docling-qdrant-mosquitto"
    "06-ai-core-lemonade"
    "07-validation-stack"
    "08-monitoring-alerting"   # monitoring 先起，讓 09 安裝 cron 後監控即可看到 VRAM purge 狀態
    "09-backup-recovery"
    "10-observability-grafana"
)

# `check` 動作委派給 07-validation-stack/deploy.sh check，不在這裡自己解析路徑。
# 「跑健康檢查」只留這一條實作路徑，避免日後改了一邊忘了另一邊。
#
# ⚠️ 這裡刻意不複述 07 內部的檔案佈局 —— 那是該模組自己的事，寫在這裡只會在對方
#    重組檔案時變成假話（這段先前就因此改過三次）。要知道佈局請看
#    07-validation-stack/deploy.sh 的檔頭。
VALIDATION_MODULE_DIR="$SCRIPT_DIR/07-validation-stack"

usage() {
    echo "Usage: sudo $0 {init | all | restart | system | app | status | check | backup | restore | clean}"
    echo ""
    echo "  init   : [Mandatory] Hardware assessment; if the GPU driver is not ready, installs it"
    echo "           first and asks for a reboot, then re-run init"
    echo "           (exit code 10 means: driver installed, reboot required)"
    echo "  all    : Execute full deployment (Phase 00 → 10)"
    echo "  restart: Re-run every migrated module with its 'restart' action"
    echo "  system : Execute Phase 00 system initialization (GPU driver + Docker)"
    echo "  app    : Execute App layer deployment (Phase 01-10 + 99)"
    echo "  status : Check all container status"
    echo "  check  : Execute system-wide health check (delegates to 07-validation-stack)"
    echo "  backup : Execute system-wide data backup"
    echo "  restore: Execute system-wide data restore"
    echo "           restore [-y] <backup_date_folder> {all | db | data}"
    echo "           (no arguments lists the available backups and exits non-zero)"
    echo "  clean  : Stop and remove all Compose managed containers"
    echo ""
    echo "  Platform: $TIGER_PLATFORM (override with TIGER_PLATFORM=...)"
}

# --- 3) 資料根目錄 -----------------------------------------------------------
# 三份舊腳本這裡不一致（amd 是 ${SUDO_USER:-${USER:-wrt}}，另兩份是
# ${SUDO_USER:-wrt}）。取 amd 的版本：非 sudo 情境下 $USER 比硬編 wrt 正確。
REAL_USER="${SUDO_USER:-${USER:-wrt}}"
BASE_DIR="${BASE_DIR:-/home/wrt/TigerAI}"
mkdir -p "$BASE_DIR"
chown "$REAL_USER":"$REAL_USER" "$BASE_DIR"

# --- 4) 硬體調校參數 ---------------------------------------------------------
# tiger-tuning.env 已由 lib/common.sh 的 tiger_load_env 匯入（若存在）。
# 這裡只處理「檔案不存在」時的保守預設。
if [ -f "${SCRIPT_DIR}/tiger-tuning.env" ]; then
    LOG "Optimization profile detected (tiger-tuning.env), parameters injected."
else
    WARN "No tiger-tuning.env — falling back to [CONSERVATIVE] defaults"
    export TIGER_OPTIMIZATION_PROFILE="CONSERVATIVE"
    TIGER_CPU_THREADS=$(( $(nproc) / 2 ))
    [ "$TIGER_CPU_THREADS" -lt 1 ] && TIGER_CPU_THREADS=1
    export TIGER_CPU_THREADS
    export TIGER_N8N_WORKERS=2
    # 這四個值與 00-pre-flight-advisor/deploy.sh 的 CONSERVATIVE profile 對齊
    # （THREADS=CPU/2、N8N_WORKERS=2、OWUI_UVICORN_WORKERS=2、LOG_MAX_SIZE=10m）。
    # TIGER_OWUI_UVICORN_WORKERS 原本漏在這裡：03 的
    # ${TIGER_OWUI_UVICORN_WORKERS:-${OWUI_UVICORN_WORKERS:-2}} 剛好也落到 2，
    # 所以目前沒有症狀 —— 但一旦 advisor 的 CONSERVATIVE 改了值，這個不對稱就會
    # 變成「有 tiger-tuning.env 跟沒有時 OWUI 行為不同」的真 bug。
    export TIGER_OWUI_UVICORN_WORKERS=2
    export TIGER_LOG_MAX_SIZE="10m"
fi

# --- 5) run_step -------------------------------------------------------------
# 用法：run_step <folder> [action] [額外參數...]
#
# 遷移期間：只跑已經搬進 compose-stack/ 的模組；還沒搬的印「尚未遷移，略過」
# 而不是報錯（報錯會讓 `all` 整個中斷），也不是靜默跳過（那會讓人以為跑完了）。
#
# 第三個以後的參數會原樣透傳給模組的 deploy.sh（`restore <date> <target>` 需要）。
# 絕大多數呼叫端只給 folder + action，$3 起是空的，展開後等於沒有多帶參數 ——
# 所以 all / restart / clean / system / app / init 的行為完全不變。
run_step() {
    local folder=$1
    local action=${2:-all}
    # ⚠️ 空陣列的 "${arr[@]}" 在 bash ≤4.3 + set -u 下會炸（macOS 內建 3.2 即是）。
    #    本檔沒有 set -u，用 +$ 形式只是不讓這支腳本挑 bash 版本。
    local -a extra=("${@:3}")

    if [ ! -d "$folder" ]; then
        WARN "模組 $folder 尚未遷移到 deployments/compose-stack/，略過"
        return 0
    fi

    LOG ">>> Processing module: $folder (platform=$TIGER_PLATFORM, action=$action)"
    if [ -f "$folder/deploy.sh" ]; then
        ( cd "$folder" && sudo -E bash ./deploy.sh "$action" ${extra[@]+"${extra[@]}"} )
    elif [ -f "$folder/docker-compose.base.yaml" ]; then
        WARN "$folder has no deploy.sh — falling back to tiger_compose"
        # 這條 fallback 只把 action 對應成 compose 指令，接不住額外參數。
        # 靜默丟掉會讓 `restore <date>` 之類的呼叫看起來成功卻沒帶到參數，所以出聲。
        # 用 if 而不是 `[ … ] && WARN …`：後者在條件不成立時整句回 1，而 set -e
        # 只有在它是函式／分支的**最後一句**時才會把那個 1 當成 run_step 的回傳值
        # 並中止呼叫端；夾在中間則無害（本檔第 49、125 行就是安全的同型寫法）。
        # 改用 if 是為了不依賴這個位置關係 —— 日後有人在後面插入程式碼、讓它變成
        # 最後一句時，不會突然多出一條路徑會中止整個部署。
        if [ "${#extra[@]}" -gt 0 ]; then
            WARN "  ↳ $folder 沒有 deploy.sh，額外參數被忽略：${extra[*]}"
        fi
        (
            # shellcheck disable=SC2034  # tiger_compose 於呼叫時讀取
            TIGER_MODULE_DIR="$SCRIPT_DIR/$folder"
            # `down` 一律帶 --remove-orphans（各模組 deploy.sh 的 down/restart 同此）。
            # 升級把某個 service 從 compose 檔移掉之後，該 service 的舊容器就成了
            # orphan，不帶旗標的 down 不會動它，會一直留著佔 RAM。爆炸半徑只限本
            # 模組：project name 由 tiger_compose 的 --project-directory 綁在模組目錄，
            # --remove-orphans 只清同 project 且帶 compose label 的容器。
            case "$action" in
                restart) tiger_compose restart ;;
                down)    tiger_compose down --remove-orphans ;;
                *)       tiger_compose up -d ;;
            esac
        )
    else
        WARN "$folder has neither deploy.sh nor docker-compose.base.yaml, skipping."
    fi
}

# --- 6) Actions --------------------------------------------------------------
case "${1:-}" in
    init)
        # ⚠️ 「GPU 驅動就緒了沒」的判斷**只有這一份**。呼叫端（deployments/
        #    tiger-deploy.sh）不重寫一次 nvidia-smi / rocm-smi 偵測，只認下面的
        #    退出碼 —— 否則同一個判斷會散在兩個檔案，改一邊忘一邊。
        #
        # 驅動還沒好 → 先裝驅動（冪等），提示 reboot 後再跑一次 init
        if ! nvidia-smi >/dev/null 2>&1 && ! rocm-smi >/dev/null 2>&1; then
            run_step "${DEPLOY_STEPS[0]}"
            # ⚠️ 「reboot 之後該做什麼」的指引**只印在這裡一處**，而且必須同時涵蓋
            #    兩種入口（本檔可以被 deployments/tiger-deploy.sh 呼叫，也可以被直接
            #    執行 —— 後者是 usage() 標為 [Mandatory] 的文件化入口）。
            #    呼叫端不再印自己的版本：兩則訊息同時出現只會讓操作者不知道聽誰的。
            WARN "──────────────────────────────────────────────"
            WARN " Driver installed. A reboot is REQUIRED."
            WARN " 重開機後，依你剛才使用的入口擇一："
            WARN "   [A] 用 tiger-deploy.sh 部署的 → 只要這一條（它會自己先跑 init）"
            WARN "         1) sudo reboot"
            WARN "         2) sudo bash deployments/tiger-deploy.sh all"
            WARN "   [B] 直接跑 master-deploy.sh 的 → init 之後再 all"
            WARN "         1) sudo reboot"
            WARN "         2) sudo bash master-deploy.sh init"
            WARN "         3) sudo bash master-deploy.sh all"
            WARN " 只照你自己那一條做，不要兩條都做。"
            WARN "──────────────────────────────────────────────"
            # 退出碼 10 = 「驅動已安裝，需要 reboot 後重跑 init」。
            # 刻意不回 0：0 與「驅動本來就好、advisor 也跑完了、可以往下部署」
            # 完全無法區分，呼叫端只好自己再偵測一次驅動 —— 那正是要避免的重複。
            # 改這個數字要同步 deployments/tiger-deploy.sh 的 RC_REBOOT_REQUIRED。
            exit 10
        fi

        # 驅動已就緒 → 再跑一次 system setup（冪等），然後跑 GPU-aware advisor
        run_step "${DEPLOY_STEPS[0]}"
        LOG "GPU driver active — running hardware advisor..."
        run_step "00-pre-flight-advisor"
        ;;
    all)
        for step in "${DEPLOY_STEPS[@]}"; do
            run_step "$step"
        done
        LOG "Full deployment mission completed"

        # Maintenance Cron（每日 5:00 VRAM purge）
        # ⚠️ 這裡刻意走 run_step 委派給 09 的 deploy.sh，不要改回
        #    `[ -f "./09-.../<某支腳本>" ]` 這種「用檔案存在與否當 guard」的寫法：
        #    模組一旦重組檔案佈局，那個 [ -f ] 就會永遠是 false —— 而 if 沒中就是
        #    「安靜跳過」，不會有任何錯誤訊息，結果是 VRAM purge cron 默默沒被安裝。
        #    模組內部的檔案佈局由模組自己解析，master 不該知道，也就不會過期。
        LOG "Setting up maintenance cron job (Daily 5:00 AM VRAM Purge)..."
        run_step "09-backup-recovery" cron

        # MQTT Device Monitor Cron
        # ⚠️ 這裡刻意走 run_step 委派給 05 的 deploy.sh，不要改回
        #    `[ -f "./05-.../<某支腳本>" ]` 這種「用檔案存在與否當 guard」的寫法：
        #    模組一旦重組檔案佈局，那個 [ -f ] 就會永遠是 false —— 而 if 沒中就是
        #    「安靜跳過」，不會有任何錯誤訊息，結果是 MQTT cron 默默沒被安裝。
        #    這個坑實際發生過。
        #    模組內部的檔案佈局由模組自己解析，master 不該知道，也就不會過期。
        LOG "Setting up MQTT Device Monitor cron jobs (@reboot)..."
        run_step "05-rag-stack-docling-qdrant-mosquitto" cron

        WARN "If this is the first run of Phase 00, please reboot: sudo reboot"
        ;;
    restart)
        for step in "${DEPLOY_STEPS[@]}"; do
            run_step "$step" restart
        done
        LOG "Stack restart mission completed"
        ;;
    system)
        run_step "00-system-setup-gpu-driver-and-docker"
        LOG "System initialization completed"
        ;;
    app)
        for step in "${DEPLOY_STEPS[@]:1}"; do
            run_step "$step"
        done
        LOG "App layer deployment commands sent"
        ;;
    status)
        LOG "--- [System-wide container status check] ---"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        ;;
    check)
        [ -f "$VALIDATION_MODULE_DIR/deploy.sh" ] || \
            ERROR "Validation module not found: $VALIDATION_MODULE_DIR/deploy.sh"
        # 用 exec 取代目前行程，讓健康檢查的 PASS/FAIL 退出碼原封傳回呼叫端
        # （若改成一般呼叫，set -e 的 ERR trap 會先印一行 FAILED 再退出，噪音蓋掉結果）。
        # 這一層保證自己不攔截退出碼；被委派的一端是否同樣透明，由該模組自己負責。
        cd "$VALIDATION_MODULE_DIR"
        exec bash ./deploy.sh check
        ;;
    backup|restore)
        # 委派給 09-backup-recovery/deploy.sh 的同名 action。理由同上面的 cron：
        # 用 `[ -f "./09-.../<某支腳本>" ]` 當 guard 會在模組重組佈局後永遠 false，
        # 把「找不到就報錯」變成「永遠找不到」。路徑解析交給模組自己。
        #
        # `$1` 是動作本身（backup / restore），`${@:2}` 是要交給模組的參數，例如
        #     sudo master-deploy.sh restore 20260202_120000 all
        #     sudo master-deploy.sh restore -y 20260202_120000 db
        # 由 run_step 透傳到 08 的 deploy.sh，再由該模組決定交給誰。
        # 08 目前的 backup action 不吃參數（多給的會被忽略），restore 則需要；
        # 兩個動作都轉發只是讓語意一致。
        #
        # run_step 對「模組目錄不存在」是 WARN + return 0（遷移期語意）。備份／還原
        # 不能 fail-open，所以這裡先自己擋一次並以非 0 退出，維持搬移前的行為。
        [ -d "./09-backup-recovery" ] || \
            ERROR "Backup/Recovery module not found: ./09-backup-recovery"
        run_step "09-backup-recovery" "$1" "${@:2}"
        ;;
    clean)
        WARN "Stopping and removing application containers..."
        # 反向（99 → 01）關閉，讓相依服務先停
        for (( i=${#DEPLOY_STEPS[@]}-1; i>=1; i-- )); do
            step=${DEPLOY_STEPS[$i]}
            [ -d "$step" ] || continue
            if [ -f "$step/deploy.sh" ]; then
                ( cd "$step" && sudo -E bash ./deploy.sh down ) || true
            elif [ -f "$step/docker-compose.base.yaml" ]; then
                (
                    # shellcheck disable=SC2034  # tiger_compose 於呼叫時讀取
                    TIGER_MODULE_DIR="$SCRIPT_DIR/$step"
                    tiger_compose down --remove-orphans
                ) || true
            fi
        done
        LOG "Cleanup completed"
        ;;
    *)
        # 未知動作（含無參數）一律以非 0 退出 —— fail-closed。
        # deployments/tiger-deploy.sh 是泛用轉發（不驗證動作名稱，直接
        # `exec bash master-deploy.sh "$@"`），所以本檔的退出碼就是它的退出碼。
        # 若這裡回 0，`tiger-deploy.sh check` 打錯成別的字時只會印 usage 卻回 0，
        # 看起來像健康檢查通過了 —— 那是最糟的靜默 fail-open。
        #
        # `case "${1:-}"` 讓「無參數」也落到這一支：目前沒有 help/-h 這種
        # 「明示求助」的動作，所以所有走到 usage() 的路徑都是「你沒給我有效動作」，
        # 屬使用錯誤，回 1 才一致。日後若要加 help，請另開一支並回 0。
        usage
        exit 1
        ;;
esac

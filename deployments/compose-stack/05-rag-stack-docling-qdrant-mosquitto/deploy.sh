#!/usr/bin/env bash
# =====================================================================
# TigerAI RAG Stack Deployer (Docling / Qdrant / Mosquitto)
# Path: deployments/compose-stack/05-rag-stack-docling-qdrant-mosquitto/deploy.sh
#
# 合併自三份舊 deploy.sh。compose 的平台差異全部走
# docker-compose.<platform>.yaml overlay；shell 這一層只剩一處平台分支：
# AMD 的 Docling ROCm 本機建置（見 build_docling_image / check_docling_image）。
#
# ⚠️ 舊架構是靠「這段程式碼只存在於 amd stack 的檔案裡」來防呆的。合併之後
#    那層保護沒了，所以 ROCm 建置一律用 `[ "$TIGER_PLATFORM" = "amd" ]` 明確 guard。
#
# 三份舊腳本行為不一致的地方（這裡各挑一個，並在此記錄）：
#   * restart      amd/arm64 才有；amd 是 `down && $0 all`（遞迴 re-exec），
#                  arm64 是 `docker compose restart`。這裡統一成 down + up -d，
#                  與 01-infra / 02-database / 03-ai-interface / 04-automation 一致。
#   * down         nvidia 沒有；這裡三平台都有。
#   * prep/network arm64 是在 case 分支裡才呼叫；這裡統一成進 case 之前先跑
#                  （amd / nvidia 的做法）。
#   * docling 預拉  nvidia 會先 `docker pull`，arm64 沒有。這裡兩者都預拉（僅在
#                  DOCLING_IMAGE 有設時），好處是失敗訊息落在這一步而不是 `up -d` 中間。
#   * REAL_USER    amd 是 ${SUDO_USER:-${USER:-wrt}}，另兩份是 ${SUDO_USER:-wrt}。
#                  取 amd 版（與 master-deploy.sh 一致）。
#
# Actions:
#   all | mosquitto | docling | qdrant | down | restart
#   build-docling  強制重建 Docling ROCm image（僅 AMD）
#   cron           安裝 register/monitor 的 @reboot crontab（resource/_shared/setup-cron.sh）
#
# 檔案歸屬（見 lib/common.sh 的 tiger_res）：
#   本模組已無平台專屬 resource 檔，全部在 resource/_shared/：
#     mosquitto.conf / monitor_device.py / setup-cron.sh
#   （tiger_res 仍會先找 resource/<platform>/，日後真的出現平台差異時直接放進去即可，
#     不必改這裡的呼叫端。）
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # 由 lib/common.sh 的 LOG/WARN/ERROR 讀取
TIGER_LOG_PREFIX="TigerAI RAG"
# lib 提供：set -Eeo pipefail + ERR trap、LOG/WARN/ERROR、env 三層載入、
#           ensure_network、tiger_compose、tiger_res
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    echo "Usage: sudo $0 {all | mosquitto | docling | qdrant | down | restart | build-docling | cron}"
    echo "  build-docling : Force a rebuild of the local Docling ROCm image (AMD only)"
    echo "  cron          : Install the @reboot register/monitor cron jobs"
    exit 1
}

[ $# -eq 0 ] && usage
ACTION=$1

# --- 路徑與預設值 -------------------------------------------------------------
BASE_DIR=${BASE_DIR:-/home/wrt/TigerAI}
MQTT_HOST_DIR="${MQTT_HOST_DIR:-$BASE_DIR/mosquitto}"
REAL_USER="${SUDO_USER:-${USER:-wrt}}"
# .venv 一律放模組根目錄（舊版是用 cwd，master-deploy.sh 剛好 `cd` 進模組目錄；
# 這裡寫死成絕對路徑，從任何 cwd 呼叫結果都一樣）。
VENV_DIR="${SCRIPT_DIR}/.venv"
VENV_PYTHON="${VENV_DIR}/bin/python3"

# --- Docling ROCm local build（僅 AMD）---------------------------------------
# No public ROCm docling-serve image exists on ghcr.io; upstream requires a
# local `make` build (docs/deployment.md). Variant must match the host ROCm:
#   rocm72 -> ROCm 7.2 (what 00-system-setup-gpu-driver-and-docker installs)
#   rocm   -> ROCm 6.3
DOCLING_ROCM_VARIANT=${DOCLING_ROCM_VARIANT:-rocm72}
DOCLING_ROCM_REF=${DOCLING_ROCM_REF:-main}
DOCLING_BUILD_DIR=${DOCLING_BUILD_DIR:-$BASE_DIR/build/docling-serve}
DOCLING_MIN_ROCM=${DOCLING_MIN_ROCM:-6.3}
# nvidia / arm64 的 DOCLING_IMAGE 預設由 docker-compose.<platform>.yaml 的
# inline default 承載（.env.{nvidia,arm64}.example 刻意留成註解，避免使用者
# 手上的 .env 在 overlay bump digest 後靜默釘住舊 image）。
# AMD 則必須讓它保持「未設定」，才會走下面這個本地建置的推導。
if [ "$TIGER_PLATFORM" = "amd" ]; then
    # The Makefile tags the build as ghcr.io/docling-project/docling-serve-<variant>:<BRANCH_TAG>
    DOCLING_IMAGE=${DOCLING_IMAGE:-ghcr.io/docling-project/docling-serve-${DOCLING_ROCM_VARIANT}:${DOCLING_ROCM_REF}}
    export DOCLING_IMAGE

    # GPU device group GIDs (same pattern as 06-ai-core-lemonade/deploy.sh)
    # ⚠️ 這兩行的 `|| echo` 依賴 lib/common.sh 的 `set -o pipefail`：有 pipefail 時
    #    管線才會沿用 getent 的非零退出碼、fallback 才會觸發；沒有 pipefail 時退出碼
    #    由 cut 決定（空輸入仍 exit 0），會靜默變成空字串。搬走或拿掉 pipefail 前請先確認。
    TIGER_RENDER_GID=${TIGER_RENDER_GID:-$(getent group render 2>/dev/null | cut -d: -f3 || echo "992")}
    TIGER_VIDEO_GID=${TIGER_VIDEO_GID:-$(getent group video  2>/dev/null | cut -d: -f3 || echo "44")}
    export TIGER_RENDER_GID TIGER_VIDEO_GID
fi

# nvidia overlay 的 docling 以 bare key 取 OMP_NUM_THREADS。必須明確 unset：
# sudo -E 會原樣轉發 host 的空字串，bare key 會把它帶進容器。
if [ -n "${TIGER_CPU_THREADS:-}" ]; then
    export OMP_NUM_THREADS="$TIGER_CPU_THREADS"
else
    unset OMP_NUM_THREADS
fi

prep_rag_env() {
    LOG " Configuring RAG environment..."
    # mosquitto.conf 由 compose 從 resource/_shared/ 掛入，不需要 host config 目錄。
    sudo mkdir -p "$BASE_DIR/docling" "$BASE_DIR/qdrant" \
                  "$MQTT_HOST_DIR/data" "$MQTT_HOST_DIR/log"
    # docling-serve runs as UID 1001 (non-root) → bind-mount must be writable by 1001
    sudo chown -R 1001:1001 "$BASE_DIR/docling"
    # qdrant runs as root (UID 0) → ownership is cosmetic, root writes regardless
    sudo chown -R "$REAL_USER":"$REAL_USER" "$BASE_DIR/qdrant"
    sudo chown -R 1883:1883 "$MQTT_HOST_DIR"
}

setup_python_env() {
    LOG " Setting up Python virtual environment for MQTT monitors..."

    # If .venv exists but is broken (missing activate), remove it
    if [ -d "$VENV_DIR" ] && [ ! -f "$VENV_DIR/bin/activate" ]; then
        LOG " Removing broken .venv..."
        rm -rf "$VENV_DIR"
    fi

    # Create venv if not present; install python3-venv and retry if needed
    if [ ! -f "$VENV_DIR/bin/activate" ]; then
        if ! python3 -m venv "$VENV_DIR" 2>/dev/null; then
            LOG " python3-venv might be missing. Installing..."
            sudo apt-get install -y python3-venv || ERROR "Failed to install python3-venv."
            rm -rf "$VENV_DIR"
            python3 -m venv "$VENV_DIR" || ERROR "Failed to create python venv after installing python3-venv."
        fi
    fi

    "$VENV_PYTHON" -m pip install --upgrade pip > /dev/null
    "$VENV_PYTHON" -m pip install aiomqtt python-dotenv > /dev/null
    LOG " Python environment ready."
}

# --- AMD: host ROCm 版本檢查 --------------------------------------------------
# Host ROCm must be >= DOCLING_MIN_ROCM (upstream docs/deployment.md requirement).
# Hard-fail on missing/old ROCm — never silently fall back to a CPU image.
check_rocm_version() {
    local ver=""
    if [ -r /opt/rocm/.info/version ]; then
        ver=$(tr -d '[:space:]' < /opt/rocm/.info/version)
    elif command -v hipconfig >/dev/null 2>&1; then
        ver=$(hipconfig --version 2>/dev/null)
    fi
    ver=$(echo "$ver" | grep -oE '^[0-9]+\.[0-9]+' || true)
    [ -n "$ver" ] || ERROR "Cannot determine the host ROCm version (/opt/rocm/.info/version and hipconfig both unavailable).
  Docling ROCm needs AMDGPU driver >= 6.3 and ROCm >= ${DOCLING_MIN_ROCM}.
  Install it first:  sudo ../00-system-setup-gpu-driver-and-docker/deploy.sh all
  Then verify with:  cat /opt/rocm/.info/version && rocm-smi --showdriverversion"

    # numeric major.minor comparison
    local have_maj=${ver%%.*} have_min=${ver##*.}
    local min_maj=${DOCLING_MIN_ROCM%%.*} min_min=${DOCLING_MIN_ROCM##*.}
    if [ "$have_maj" -lt "$min_maj" ] || { [ "$have_maj" -eq "$min_maj" ] && [ "$have_min" -lt "$min_min" ]; }; then
        ERROR "Host ROCm $ver is older than the required ${DOCLING_MIN_ROCM}. Upgrade ROCm before building the Docling ROCm image."
    fi
    LOG " Host ROCm $ver detected (>= ${DOCLING_MIN_ROCM}), OK."
    # ROCm 7.x hosts should use the rocm72 variant; 6.x hosts the rocm variant.
    if [ "$have_maj" -ge 7 ] && [ "$DOCLING_ROCM_VARIANT" != "rocm72" ]; then
        LOG " ${YELLOW}Warning:${NC} host ROCm is $ver but DOCLING_ROCM_VARIANT=$DOCLING_ROCM_VARIANT (ROCm 6.3 build)."
    fi
}

# Build the Docling ROCm image locally. Idempotent: skips when the tag already
# exists unless DOCLING_FORCE_REBUILD=1 (or the `build-docling` action) is used.
build_docling_image() {
    if [ "${DOCLING_FORCE_REBUILD:-0}" != "1" ] && docker image inspect "$DOCLING_IMAGE" >/dev/null 2>&1; then
        LOG " Docling image $DOCLING_IMAGE already present, skipping build."
        LOG " Force a rebuild with: sudo $0 build-docling"
        return 0
    fi

    check_rocm_version
    if ! command -v git >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y git make
    fi

    sudo mkdir -p "$(dirname "$DOCLING_BUILD_DIR")"
    sudo chown "$REAL_USER":"$REAL_USER" "$(dirname "$DOCLING_BUILD_DIR")"

    if [ -d "$DOCLING_BUILD_DIR/.git" ]; then
        LOG " Updating docling-serve source in $DOCLING_BUILD_DIR ($DOCLING_ROCM_REF)..."
        git -C "$DOCLING_BUILD_DIR" fetch --depth 1 origin "$DOCLING_ROCM_REF" \
            || ERROR "git fetch failed in $DOCLING_BUILD_DIR"
        # Keep a real branch checked out: the Makefile tags with `git rev-parse --abbrev-ref HEAD`
        git -C "$DOCLING_BUILD_DIR" checkout -B "$DOCLING_ROCM_REF" FETCH_HEAD \
            || ERROR "git checkout $DOCLING_ROCM_REF failed"
    else
        LOG " Cloning docling-serve into $DOCLING_BUILD_DIR ($DOCLING_ROCM_REF)..."
        rm -rf "$DOCLING_BUILD_DIR"
        git clone --depth 1 --branch "$DOCLING_ROCM_REF" \
            https://github.com/docling-project/docling-serve.git "$DOCLING_BUILD_DIR" \
            || ERROR "git clone of docling-serve failed"
    fi

    LOG " Building $DOCLING_IMAGE via 'make docling-serve-${DOCLING_ROCM_VARIANT}-image' (this takes a long time)..."
    ( cd "$DOCLING_BUILD_DIR" && sudo make "docling-serve-${DOCLING_ROCM_VARIANT}-image" ) \
        || ERROR "Docling ROCm image build failed. Re-run with: sudo $0 build-docling"

    docker image inspect "$DOCLING_IMAGE" >/dev/null 2>&1 \
        || ERROR "Build finished but $DOCLING_IMAGE does not exist. Check the tag the Makefile produced with: docker images | grep docling-serve-${DOCLING_ROCM_VARIANT}"
    LOG " Docling ROCm image ready: $DOCLING_IMAGE"
}

# nvidia / arm64: 預拉 docling image。
#
# ⚠️ 刻意不帶 fallback 值。帶了就成為這個 pin 的第三份字面副本，而且這支函式不分
#    平台 —— nvidia 是 cu130、arm64 是 cpu，單一 fallback 必然對其中一邊是錯的
#    （合併後 arm64 曾因此白拉一顆 5 GB 的 CUDA image，然後 compose 再拉 CPU 版）。
#    沒設就跳過預拉，交給 compose up 自己拉；image 的來源只剩 .env 與 overlay。
pull_docling_image() {
    if [ -z "${DOCLING_IMAGE:-}" ]; then
        LOG "DOCLING_IMAGE 未設定，跳過預拉（compose up 會自行拉取）。"
        return 0
    fi
    # Match on the exact ref (incl. digest), not the repo name, so a digest
    # bump actually triggers a pull.
    if ! docker image inspect "$DOCLING_IMAGE" >/dev/null 2>&1; then
        LOG "📥 Docling image not found locally. Pulling from registry..."
        docker pull "$DOCLING_IMAGE"
        LOG "✅ Docling image ready."
    else
        LOG "✅ Docling image already exists, skipping pull."
    fi
}

# Only (re)build / pull when docling is actually part of this invocation.
check_docling_image() {
    case "$ACTION" in
        all|docling|build-docling) ;;
        *) return 0 ;;
    esac
    if [ "$TIGER_PLATFORM" = "amd" ]; then
        build_docling_image
    else
        [ "$ACTION" = "build-docling" ] && ERROR "build-docling 只適用於 AMD（TIGER_PLATFORM=$TIGER_PLATFORM 用的是官方 CUDA image）"
        pull_docling_image
    fi
}

# --- host 端腳本入口 ----------------------------------------------------------
# 搬進 resource/ 之前使用者的入口是 `cd 05-… && ./setup-cron.sh`；搬完後
# 那兩個檔案不在模組根目錄了，這兩個 action 就是替代入口（同 07 的 `check`）。
# 路徑一律走 tiger_res，檔案不存在時由 tiger_res 報錯並 exit 1。
run_host_script() {
    local script
    script="$(tiger_res "$1")"
    LOG "Running: $script"
    exec bash "$script"
}

[ "$ACTION" = "build-docling" ] && DOCLING_FORCE_REBUILD=1

case "$ACTION" in
    cron)        run_host_script setup-cron.sh ;;
esac

prep_rag_env
ensure_network
check_docling_image

case "$ACTION" in
    build-docling)
        LOG " Docling image build finished (no services were started)."
        ;;
    all)
        setup_python_env
        LOG " Starting RAG Stack (Docling, Qdrant, Mosquitto)..."
        tiger_compose up -d
        ;;
    docling|qdrant|mosquitto)
        LOG " Starting specific service: $ACTION..."
        tiger_compose up -d "$ACTION"
        ;;
    down)
        LOG " Stopping RAG services..."
        tiger_compose down --remove-orphans
        ;;
    restart)
        # 與 01-infra / 02-database / 03-ai-interface / 04-automation 一致的
        # restart 語意：down + up -d（舊 amd 版是遞迴 re-exec 自己，行為相同）。
        LOG " Restarting RAG Stack..."
        setup_python_env
        tiger_compose down --remove-orphans
        tiger_compose up -d
        ;;
    *)
        usage
        ;;
esac

LOG " RAG Deployment command finished."

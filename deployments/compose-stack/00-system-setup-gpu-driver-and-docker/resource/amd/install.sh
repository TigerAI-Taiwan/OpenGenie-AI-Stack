#!/usr/bin/env bash
# =====================================================================
# TigerAI ROCm + Docker 安裝腳本
# 版本: 見「1) 參數與日誌」的 SCRIPT_VERSION —— 那是本檔**唯一**的版本字串字面值。
#       這裡刻意不重複寫版號：曾經檔頭與啟動日誌各寫一份，兩批改動各動一處就漂成
#       檔頭 .33 / 日誌 .32，使用者看到的與檔案寫的不一致。
# Path: deployments/compose-stack/00-system-setup-gpu-driver-and-docker/resource/amd/install.sh
#
# 由同模組的 deploy.sh 透過 `tiger_res install.sh` 解析後 exec 起來，
# 也可以人工單獨執行（sudo bash resource/amd/install.sh）。
#
# ⚠️ 這支腳本會改變 host 狀態（裝 ROCm / 裝 Docker / 寫 sysctl / 寫 udev 規則 /
#    寫 systemd unit / 改 gdm3），跑完要 reboot。
#
# ---------------------------------------------------------------------
# 📖 背景知識都在 docs/substacks/00-system-setup/README.md
# ---------------------------------------------------------------------
# 本檔的註解只留「離開這幾行就沒有意義」的 why。以下讀一次就懂的背景知識放文件。
#
# 下表是**完整**清單：檔內每一處「見 README 的『…』」都在表上，順序同它們在檔內
# 出現的順序。新增 inline 指標時請一併補這裡（曾經這份總覽只列 8 條、檔內實際有
# 14 條，名不副實）。
#
#   「env 載入的兩個陷阱」 為什麼用 temp file、為什麼不能拿掉剝 \r 的 sed
#   「ROCM_DEB_URL 的兩段版號」 目錄段（行銷版號）≠ 檔名段（build 版號），猜錯是 404
#   「AMD [1/5] 的執行期決策：dkms vs no-dkms」 三種模式的差異與完整決策樹
#   「AMDGPU_INSTALL_MODE 只吃 .env」 命令列前綴為何被 env 載入迴圈蓋掉
#   「冪等守衛的兩個誤 SKIP 例外」 dkms / no-dkms 失敗後 rocm 仍是 ii 的容器實測輸出
#   「冪等守衛刻意不驗的東西」 為什麼不驗 dkms 模組是否已為執行中 kernel 重編
#   「linux-modules-extra 與 amdgpu.ko 的 flavour 差異」 哪些 flavour 沒有這個套件
#   「amdgpu-dkms 與 kernel 版本的綁定關係」 為什麼綁世代、實測到的兩個編譯錯誤
#   「版本比對的 epoch 陷阱」 dpkg epoch 讓 sort -V 全盤倒向 no-dkms 的完整推導
#   「usermod 加到的是 root」 sudo 下 $USER 是 root 的既有問題與另案方向
#   「/etc/sysctl.conf 的生效機制與時序」 誰在開機時讀它、為什麼贏過 10-map-count.conf
#   「kfd udev 規則為什麼放在 [4/5]」 三件事併一步、不拆進 install_rocm() 的理由
#   「70-kfd.rules 的實際增量」 相對發行版預設規則，我們只多了 TAG+="uaccess"
#   「install.sh 的五步（三平台共同骨架）」 三平台對照表 + 5 個不可消除的差異
#       ↑ 唯一沒有對應 inline 指標的一條：它講的是全檔結構，不屬於任何單一行。
# =====================================================================

set -eo pipefail

# ----------------------- 0) 載入配置 -----------------------
# 載入順序（後者覆蓋前者）與 lib/common.sh 的 tiger_load_env 一致：
#   <stack>/tiger-tuning.env → <stack>/.env → <module>/.env
#
# ⚠️ 路徑一定要從本檔位置推導；寫錯的話 `if [ -f ... ]` 沒中就是**靜默跳過**，
#    設定被無聲忽略、不會有任何錯誤訊息。
# ⚠️ 不可改寫成 `source <(sed …)`，也不可拿掉剝 \r 的 sed。兩者的理由見
#    README 的「env 載入的兩個陷阱」。
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_MODULE_DIR="$(cd "${_SELF_DIR}/../.." && pwd -P)"
_STACK_DIR="$(cd "${_MODULE_DIR}/.." && pwd -P)"

set -a
for _envfile in "${_STACK_DIR}/tiger-tuning.env" \
                "${_STACK_DIR}/.env" \
                "${_MODULE_DIR}/.env"; do
  if [ -f "$_envfile" ]; then
    _tmp=$(mktemp)
    sed 's/\r$//' "$_envfile" > "$_tmp"
    # shellcheck disable=SC1090
    source "$_tmp"
    rm -f "$_tmp"
  fi
done
set +a

# ----------------------- 1) 參數與日誌 -----------------------
# 本檔版本 —— 全檔唯一的版本字面值，啟動日誌直接引用它，不要在別處再寫一次。
# ⚠️ 定義在 env 載入之後、且是無 fallback 的直接賦值：這是腳本自身的身分，
#    不接受 .env 覆寫（就算 .env 誤設同名變數也會被這行蓋掉）。
SCRIPT_VERSION="v2.12.34"

# ⚠️ URL 的目錄段（行銷版號）與檔名段（build 版號）不同，都不能猜，猜錯是 404。
#    對照圖與版本清單連結見 README 的「配置 → ROCM_DEB_URL 的兩段版號」。
ROCM_DEB_URL=${ROCM_DEB_URL:-"https://repo.radeon.com/amdgpu-install/7.2.4/ubuntu/noble/amdgpu-install_7.2.4.70204-1_all.deb"}
# 下載到的 .deb 一律落在模組目錄（不是 CWD）—— 用裸檔名等於「誰的 CWD 就寫到誰家」，
# deploy.sh 可能從 stack 根目錄被呼叫，快取檔會四散、下次跑又重新下載一次。
DEB_PATH="${_MODULE_DIR}/$(basename "$ROCM_DEB_URL")"

# amdgpu 核心驅動安裝模式 auto（預設）/ dkms / no-dkms —— 三者的差異與決策樹見 README
# 的「AMD [1/5] 的執行期決策：dkms vs no-dkms」。
#
# ⚠️ 這段一定要在套用 ${VAR:-auto} fallback 之前，否則分不出「沒設」和「設成 auto」。
#    判定用「值」而非 ${VAR+x} 的 set-ness：.env.amd.example 出貨就帶一行
#    AMDGPU_INSTALL_MODE=auto，測 set-ness 會永遠為真、守衛永遠不生效。
#
# 🔴 已知限制：命令列前綴（sudo AMDGPU_INSTALL_MODE=… bash install.sh）會被上面的
#    env 載入迴圈用 .env 的值蓋掉，等於沒指定；因此本檔所有指引都只教「改
#    <stack>/.env」。理由與待處理方向見 README 的「AMDGPU_INSTALL_MODE 只吃 .env」。
# ⚠️ 刻意不做值的白名單檢查（打錯字會靜默走 no-dkms 分支）—— 既有容錯行為，另案處理。
if [ -n "${AMDGPU_INSTALL_MODE:-}" ] && [ "${AMDGPU_INSTALL_MODE}" != "auto" ]; then
    AMDGPU_MODE_EXPLICIT=1
else
    AMDGPU_MODE_EXPLICIT=0
fi
AMDGPU_INSTALL_MODE=${AMDGPU_INSTALL_MODE:-auto}

VM_MAP_COUNT=${VM_MAP_COUNT:-2097152}
SET_PERF_LEVEL=${SET_PERF_LEVEL:-"high"}
# vm.swappiness 刻意保持硬編（不開成 env）：三平台的 .env.example 都沒有這個 key，
# 為它新增一個變數就得同步三份共用區。要調的人直接改 /etc/sysctl.conf 即可。
SWAPPINESS=10

# log.sh and not lib/common.sh: this file also runs standalone
# (sudo bash resource/amd/install.sh), where TIGER_PLATFORM is unset and
# common.sh's ERR trap is unwanted. Paths reuse _STACK_DIR from the env load.
if [ ! -f "${_STACK_DIR}/lib/log.sh" ]; then
    echo "[TigerAI ERROR] not found: ${_STACK_DIR}/lib/log.sh (_SELF_DIR=${_SELF_DIR})" >&2
    exit 1
fi
# shellcheck source-path=SCRIPTDIR/../../../lib
# shellcheck source=log.sh
source "${_STACK_DIR}/lib/log.sh"
TIGER_LOG_PREFIX="TigerAI Foundation (AMD)"

# ===================== [1/5] 安裝 ROCm =====================
# 冪等判準：「上一輪跑到了安裝 rocm 那一步」＋「執行中的 kernel 有 amdgpu module」。
#
# ⚠️ 不可換成 `command -v rocm-smi`（nvidia 那邊的對應物）：dkms 編譯失敗中止時
#    rocm-smi 可能已經留下來，用它當守衛會把失敗指引教的 no-dkms 復原路徑整條擋掉。
# ⚠️ 條件 (1) 用 dpkg-query 的 Status 而不是 `dpkg -l | grep`：後者對 rc / iU / iF
#    這些壞掉的狀態一樣會 grep 到，等於把半安裝當成裝好的。
# ⚠️ 條件 (2) 用 modinfo -k 而不是 `[ -e /dev/kfd ]` / `lsmod`：本腳本的合約是「跑完
#    要 reboot」，守衛要解決的情境正是 reboot 前跑第二次 —— 拿載入狀態當判準會在那裡
#    誤判。modinfo -k 查的是 /lib/modules/<執行中 kernel>/，與載入狀態無關。
#
# ⚠️ 條件 (1) 是「跑到了那一步」，**不是「整條路徑都成功」**。有兩個實測重現過的
#    「誤 SKIP」例外（dkms 編譯失敗、no-dkms 中途失敗，rocm 都仍是 ii），容器實測輸出
#    與「為什麼這樣仍可接受」見 README 的「冪等守衛的兩個誤 SKIP 例外」。
#    逃生門：在 <stack>/.env 設 AMDGPU_INSTALL_MODE=dkms 或 no-dkms。
#
# ⚠️ 刻意不納入判準：linux-headers / linux-modules-extra 的安裝狀態、amdgpu-dkms 是否
#    已為執行中 kernel 重編。理由見 README 的「冪等守衛刻意不驗的東西」。
rocm_install_complete() {
    [ "$(dpkg-query -W -f='${Status}' rocm 2>/dev/null)" = "install ok installed" ] || return 1
    modinfo -k "$(uname -r)" amdgpu >/dev/null 2>&1 || return 1
    return 0
}

install_rocm() {
    LOG "📦 [1/5] 安裝 ROCm（核心驅動模式 AMDGPU_INSTALL_MODE=${AMDGPU_INSTALL_MODE}）..."

    if [ "$AMDGPU_MODE_EXPLICIT" = "1" ]; then
        # 明確指定 dkms / no-dkms＝使用者要換核心驅動路線，一定要真的重跑。
        LOG "AMDGPU_INSTALL_MODE=${AMDGPU_INSTALL_MODE} 為明確指定，跳過冪等檢查、強制重跑安裝。"
    elif rocm_install_complete; then
        SKIP "ROCm 已完整安裝（rocm metapackage=ii，執行中 kernel $(uname -r) 有 amdgpu module），跳過安裝。"
        # ⚠️ 只能教「改 .env」——命令列前綴會被 env 載入迴圈蓋掉（見上方已知限制）。
        SKIP "要強制重跑：在 <stack>/.env 設 AMDGPU_INSTALL_MODE=no-dkms（或 dkms）後重跑 master-deploy.sh system"
        # 讓收尾摘要仍能報出正確的模式（此時沒有跑版本決策，直接回報實際的 dpkg 狀態）。
        if [ "$(dpkg-query -W -f='${Status}' amdgpu-dkms 2>/dev/null)" = "install ok installed" ]; then
            AMDGPU_MODE_RESOLVED="dkms"
        else
            AMDGPU_MODE_RESOLVED="no-dkms"
        fi
        return 0
    fi

    # 刪除可能存在的損壞檔案
    if [ -f "$DEB_PATH" ] && [ ! -s "$DEB_PATH" ]; then
        rm -f "$DEB_PATH"
    fi

    # 下載 amdgpu-install
    if [ ! -f "$DEB_PATH" ]; then
        LOG "下載: $ROCM_DEB_URL"
        if ! wget --progress=bar:force "$ROCM_DEB_URL" -O "$DEB_PATH"; then
            ERROR "下載失敗，請檢查網路或 URL: $ROCM_DEB_URL"
        fi
    else
        LOG "✅ 找到本地檔案: $DEB_PATH"
    fi

    # 安裝 amdgpu-install
    # apt 要靠路徑中的 "/" 才會把參數當本地檔案而不是套件名；$DEB_PATH 是絕對路徑，
    # 本來就滿足。
    LOG "安裝 amdgpu-install..."
    sudo apt install -y "$DEB_PATH"

    # 更新套件列表
    LOG "更新套件列表..."
    sudo apt update

    # 安裝 kernel headers（必要）
    # amdgpu-dkms 需要 kernel headers 才能為目前執行中的 kernel 編譯 kernel module，
    # 缺少時 dkms build 必定失敗，所以這一步失敗就直接中止。
    KERNEL_REL="$(uname -r)"
    LOG "安裝 kernel headers (linux-headers-${KERNEL_REL})..."
    if ! sudo apt install -y "linux-headers-${KERNEL_REL}"; then
        ERROR "無法安裝 linux-headers-${KERNEL_REL}；amdgpu-dkms 需要它才能為目前的 kernel 編譯 module，缺少時必定失敗。
       請依序檢查：
         apt-cache policy linux-headers-${KERNEL_REL}   # 套件在 apt 中是否可取得
         dpkg -l | grep linux-headers                   # HWE meta package（如 linux-headers-generic-hwe-24.04）是否已安裝
         sudo apt update                                # 套件索引過舊時先更新再重試
       若目前執行中的 kernel 已從 archive 移除，請先 sudo apt install linux-generic-hwe-24.04，重開機到有 headers 的 kernel 後再跑一次。"
    fi

    # 安裝 linux-modules-extra（best-effort）
    # ⚠️ 這個套件裝的是 in-tree 的 amdgpu.ko —— 對 no-dkms 路徑**是必要的**，不是可有可無。
    #    「不存在就跳過」之所以安全，是因為它不存在就代表這個 kernel flavour 已把
    #    amdgpu.ko 併進 base 套件了 —— flavour 對照表見 README 的
    #    「linux-modules-extra 與 amdgpu.ko 的 flavour 差異」。
    # ⚠️ 不可併回上面那行 apt install：apt 對不存在的套件回非零，會中止整個 init。
    if apt-cache show "linux-modules-extra-${KERNEL_REL}" >/dev/null 2>&1; then
        LOG "安裝 linux-modules-extra-${KERNEL_REL}..."
        sudo apt install -y "linux-modules-extra-${KERNEL_REL}" \
            || WARN "linux-modules-extra-${KERNEL_REL} 安裝失敗，略過（非 amdgpu-dkms 必要條件）"
    else
        WARN "apt 中找不到 linux-modules-extra-${KERNEL_REL}，略過。"
        WARN "此 kernel flavour 未發佈該套件，amdgpu-dkms 只需要 linux-headers，可正常繼續。"
    fi

    # ---------- 核心驅動：out-of-tree amdgpu-dkms vs kernel in-tree amdgpu ----------
    # amdgpu-dkms 的套件版本號就是它對應的 DRM/kernel 世代；執行中的 kernel 比它新時
    # DKMS build 幾乎必定失敗。實測到的兩個編譯錯誤、以及「為什麼刻意用版本比大小而
    # 不硬編一份 AMD 支援 kernel 清單」，見 README 的
    # 「amdgpu-dkms 與 kernel 版本的綁定關係」。
    #
    # 🔴 下面三段字串處理**一段都不能省**：candidate 版本號帶 dpkg epoch，漏剝 epoch
    #    會讓 sort -V 把它當主版本 1，於是永遠選 no-dkms、dkms 分支成為死碼，而且日誌
    #    看起來完全正常。完整推導與實測結果見 README 的「版本比對的 epoch 陷阱」。
    local dkms_cand dkms_kver run_kver newest mode
    mode="$AMDGPU_INSTALL_MODE"
    dkms_cand=$(apt-cache policy amdgpu-dkms 2>/dev/null | awk '/Candidate:/{print $2}')
    dkms_kver=$(echo "${dkms_cand#*:}" | sed 's/-.*//' | cut -d. -f1,2)
    run_kver=$(uname -r | cut -d. -f1,2)                    # 7.0.0-28-generic → 7.0

    if [ "$mode" = "auto" ]; then
        if [ -z "$dkms_cand" ] || [ "$dkms_cand" = "(none)" ]; then
            # 取不到 candidate（apt 索引尚未更新，或這個發行版根本沒提供 amdgpu-dkms）。
            # 無法判斷版本關係時選 no-dkms：in-tree amdgpu 在任何 Ubuntu kernel 上都能用，
            # 而在這種狀態下硬跑 dkms 反而會在 apt 端就失敗、還留下要人工收拾的半安裝狀態。
            WARN "無法取得 amdgpu-dkms 的 apt candidate 版本，改用 kernel in-tree 驅動（no-dkms）。"
            WARN "若確定要編 DKMS：先 sudo apt update，再在 <stack>/.env 設 AMDGPU_INSTALL_MODE=dkms 後重跑。"
            mode="no-dkms"
        else
            newest=$(printf '%s\n%s\n' "$dkms_kver" "$run_kver" | sort -V | tail -n1)
            if [ "$newest" = "$run_kver" ] && [ "$run_kver" != "$dkms_kver" ]; then
                mode="no-dkms"   # 執行中的 kernel 比 DKMS 新 → 用 in-tree
            else
                mode="dkms"
            fi
        fi
    fi
    AMDGPU_MODE_RESOLVED="$mode"

    if [ "$mode" = "dkms" ]; then
        LOG "ROCm 安裝模式: dkms（out-of-tree amdgpu-dkms + ROCm userspace）"
        LOG "    amdgpu-dkms candidate=${dkms_cand:-unknown} / 執行中 kernel=$(uname -r)"
        # 併成同一次 apt install 純粹是省一次 apt 往返（rocm 不相依 amdgpu-dkms）。
        # ⚠️ 別誤會這能讓「rocm=ii ⇒ dkms 也成功」成立 —— dpkg 沒有 transaction，
        #    實測 dkms 失敗時 rocm 仍是 ii（見 README 的「冪等守衛的兩個誤 SKIP 例外」）。
        LOG "安裝 amdgpu-dkms + rocm 完整套件..."
        if ! sudo apt install -y amdgpu-dkms rocm; then
            # 注意：ERROR() 會 exit 1，所有清理動作必須放在 ERROR 之前。
            WARN "amdgpu-dkms 安裝/編譯失敗，先清理殘留狀態再中止..."
            # ⚠️ 刻意只 purge amdgpu-dkms，不 purge rocm：壞掉的只有 dkms 那一個套件，
            #    而下面推薦的復原路徑（no-dkms）正需要 rocm 留著，否則要重下數 GB。
            #    實測依據見 README 的「冪等守衛的兩個誤 SKIP 例外」。
            #    rocm 若真的半安裝，收拾它的正確工具是下面那行 apt-get -f install。
            sudo apt-get remove --purge -y amdgpu-dkms || true
            sudo dkms remove -m amdgpu --all 2>/dev/null || true
            sudo rm -f /var/crash/amdgpu-dkms.*.crash || true
            sudo apt-get -f install -y || true
            ERROR "amdgpu-dkms 無法為目前的 kernel 編譯（candidate=${dkms_cand:-unknown}，kernel=$(uname -r)）。
       這通常是 kernel 比 DKMS 對應的世代新、kernel 內部 API 已變動所致（dpkg 半安裝狀態已清理）。
       編譯錯誤詳情請看： /var/lib/dkms/amdgpu/*/build/make.log
       兩種解法擇一：
         1) 改用 kernel in-tree amdgpu（推薦，kernel 比 DKMS 新時功能不會缺）：
              # 在 <stack>/.env 設定下面這行，然後重跑 sudo bash master-deploy.sh system
              AMDGPU_INSTALL_MODE=no-dkms
              # ⚠️ 一定要寫進 .env —— 命令列 sudo AMDGPU_INSTALL_MODE=no-dkms bash install.sh
              #    會被 install.sh 的 env 載入迴圈用 .env 的值蓋掉，等於沒指定。
         2) 降到 AMD 官方支援的 kernel 後再跑一次（Ubuntu 24.04: 6.8 [GA]）：
              sudo apt install -y linux-image-generic linux-headers-generic
              # 重開機選 6.8 kernel，再重跑本腳本"
        fi
    else
        LOG "ROCm 安裝模式: no-dkms（kernel in-tree amdgpu + ROCm userspace）"
        WARN "刻意跳過 amdgpu-dkms —— 這不是失敗。"
        WARN "amdgpu-dkms candidate=${dkms_cand:-unknown}（對應 kernel ${dkms_kver:-unknown}），執行中 kernel=$(uname -r)。"
        WARN "核心驅動改用 kernel 內建的 amdgpu（版本比 DKMS 新，功能不會缺），只安裝 ROCm userspace。"
        # amdgpu-install --usecase=rocm 本身就會裝 rocm metapackage
        # （其 USECASE_ROCM_PACKAGES=(rocm)），所以這條路徑不必再補 apt install rocm。
        sudo amdgpu-install --usecase=rocm --no-dkms -y
    fi

    LOG "✅ ROCm 基礎安裝完成（模式: ${mode}）"
}

# ===================== [2/5] 安裝 Docker =====================
install_docker_amd() {
    LOG "🐳 [2/5] 安裝 Docker..."

    if command -v docker &>/dev/null; then
        SKIP "Docker 已存在，跳過安裝"
    else
        LOG "安裝 Docker CE..."
        sudo apt update
        sudo apt install -y ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
        # shellcheck disable=SC1091  # /etc/os-release 是 Linux 執行期檔案，不在 repo 內
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo systemctl enable --now docker
        LOG "✅ Docker 安裝完成"
    fi

    # ⚠️ 這行刻意放在守衛**外面**（nvidia 的對應行在守衛裡面）——
    #    render 群組是 AMD 專屬的必要條件：configure_gpu_power() 寫的 kfd udev 規則
    #    設 GROUP="render"，使用者不在該群組就完全拿不到 /dev/kfd，ROCm 直接不能用。
    #    Docker 早就裝好（守衛命中）但群組沒設對的機器很常見（例如先手動裝過 Docker），
    #    放在裡面就永遠補不上。usermod -aG 本身冪等，重跑無副作用。
    # ⚠️ 既有問題：sudo 執行時 $USER 是 root，這行實際加的是 root（nvidia/arm64 同）。
    #    來龍去脈與另案處理的方向見 README 的「usermod 加到的是 root」。
    sudo usermod -aG docker,render,video "$USER"
}

# ===================== [3/5] 系統參數（sysctl） =====================
# 🔴 這兩個 key 寫 /etc/sysctl.conf、**不是**烤進 rocm-gpu-performance.sh 的 sysctl -w，
#    理由是時序：那支 unit 保證在 Docker 之後才跑，restart:always 的 Qdrant / Ollama
#    啟動的當下 vm.max_map_count 還是開機預設值 —— 每次開機必然如此，不是失敗耦合。
#    完整的 unit 依賴推導、以及「/etc/sysctl.conf 憑什麼開機會被讀」（99-sysctl.conf
#    symlink 由 systemd 提供、99- 蓋過 procps 的 10-map-count.conf）見 README 的
#    「/etc/sysctl.conf 的生效機制與時序」。
#
# ensure_sysctl() 是 nvidia configure_performance() 那段守衛的參數化版本（AMD 有兩個
# key 要寫，inline 兩份會重複）。**守衛每個細節的理由不在這裡重複** ——
# 見 resource/nvidia/install.sh 的 configure_performance()（為何只認 key 不認值、
# regex 為何要那樣錨、為何要補檔尾換行）。同一段文字不維護兩份。
# 本檔唯一的增量：key 由參數傳入，所以點要在執行期跳脫（見下方 key_re）。
ensure_sysctl() {
    local key="$1" value="$2" key_re existing
    # 把 key 中的 . 跳脫成 \. 供 ERE 使用（vm.swappiness → vm\.swappiness）
    key_re=$(printf '%s' "$key" | sed 's/\./\\./g')

    existing=$(grep -E "^[[:space:]]*${key_re}[[:space:]]*=" /etc/sysctl.conf 2>/dev/null || true)
    if [ "$existing" = "${key}=${value}" ]; then
        SKIP "${key} 已設定為 ${value}。"
        return 0
    fi

    if [ -n "$existing" ]; then
        LOG "取代 /etc/sysctl.conf 中既有的 ${key} 設定："
        echo "$existing"
        sudo sed -i -E "/^[[:space:]]*${key_re}[[:space:]]*=/d" /etc/sysctl.conf
    fi
    # 檔尾缺結尾換行時先補一個，否則 tee -a 會把新設定黏在最後一行後面
    # （例：fs.file-max=100000vm.max_map_count=2097152 —— 一次壞掉兩個 key）。
    # 判斷式為何長這樣：見 resource/nvidia/install.sh 的 configure_performance()。
    if [ -s /etc/sysctl.conf ] && [ -n "$(tail -c1 /etc/sysctl.conf)" ]; then
        echo | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
    echo "${key}=${value}" | sudo tee -a /etc/sysctl.conf
    SYSCTL_DIRTY=1
}

configure_performance() {
    LOG "🧮 [3/5] 設定系統參數（vm.max_map_count / vm.swappiness）..."
    SYSCTL_DIRTY=0
    ensure_sysctl vm.max_map_count "$VM_MAP_COUNT"
    ensure_sysctl vm.swappiness    "$SWAPPINESS"
    # 兩個 key 共用一次 sysctl -p（nvidia 只有一個 key，所以那邊寫在 else 分支裡）。
    # 全部命中守衛時不呼叫 —— 省掉一次無意義的全檔重新套用。
    if [ "$SYSCTL_DIRTY" = "1" ]; then
        sudo sysctl -p
    fi
}

# ===================== [4/5] GPU 存取權限與電源 =====================
# 對應 nvidia 的 configure_persistenced()（角色相同：把「GPU 開機就緒」固化成 systemd
# unit）。AMD 這一步含三件事：kfd udev 規則、GPU 效能腳本、跑該腳本的 systemd unit。
# 為什麼三件事併在這一步、而不是拆進 install_rocm() 或自成第 6 步，見 README 的
# 「kfd udev 規則為什麼放在 [4/5]」。
#
# ⚠️ 配套關係：規則設 GROUP="render"，使用者必須在 render 群組才拿得到 /dev/kfd
#    —— 由 install_docker_amd() 的 usermod -aG ... render 完成（該處有反向指標）。
#
# 🔴 這裡**不能**加冪等守衛：SET_PERF_LEVEL 烤進 perf script，用「檔案已存在」當守衛
#    會讓改 .env 重跑時新值靜默失效。不加也安全 —— 每件事都是整檔覆寫（tee 非 tee -a），
#    systemctl enable 本身冪等，重跑不會累積。nvidia 的 [4/5] / [5/5] 同樣無守衛。
configure_gpu_power() {
    LOG "⚡ [4/5] 設定 GPU 存取權限與電源..."

    # UDEV 權限：讓 render 群組成員拿得到 /dev/kfd（ROCm 的 compute device）
    # ⚠️ 檔名的 70- 前綴不可調大：必須早於 systemd 的 73-seat-late.rules，uaccess tag
    #    才會被 seat 管理接手；排在它之後是**靜默**失效。
    # ⚠️ 這行相對發行版預設規則的實際增量只有 TAG+="uaccess"（GROUP 是重申）——
    #    見 README 的「70-kfd.rules 的實際增量」。
    echo 'SUBSYSTEM=="kfd", KERNEL=="kfd", TAG+="uaccess", GROUP="render", MODE="0660"' | sudo tee /etc/udev/rules.d/70-kfd.rules > /dev/null
    sudo udevadm control --reload-rules && sudo udevadm trigger

    # GPU 效能優化腳本
    # ⚠️ vm.max_map_count / vm.swappiness 已移出本腳本（見 configure_performance()）。
    PERF_SCRIPT="/usr/local/bin/rocm-gpu-performance.sh"
    sudo tee "$PERF_SCRIPT" > /dev/null <<EOF
#!/bin/bash
GPU_DEVICES=\$(find /sys/class/drm/card*/device -maxdepth 0 -exec sh -c 'if [ -f "{}/vendor" ] && [ "\$(cat "{}/vendor" 2>/dev/null)" = "0x1002" ]; then echo "{}"; fi' \; 2>/dev/null)
for GPU_PATH in \$GPU_DEVICES; do
    echo "on" > "\$GPU_PATH/power/control" 2>/dev/null || true
    [ -f "\$GPU_PATH/power_dpm_force_performance_level" ] && echo "$SET_PERF_LEVEL" > "\$GPU_PATH/power_dpm_force_performance_level"
done
if command -v powerprofilesctl &>/dev/null; then powerprofilesctl set performance; fi
export DISPLAY=:0
# ⚠️ 這個 SUDO_USER 區塊在開機時不會執行 —— systemd 不設 SUDO_USER，所以
#    由 rocm-gpu-performance.service 觸發時 -n 判斷永遠為假。它只在操作者手動
#    \`sudo /usr/local/bin/rocm-gpu-performance.sh\` 時生效（docs 有記錄這種用法）。
#    開機後真正生效的 GNOME 設定由安裝期的 configure_ui_and_power() 寫進使用者的
#    dconf（會持久保存，不需要每次開機重套），所以這裡留著只是手動執行時的便利。
if [ -n "\$SUDO_USER" ]; then
    sudo -u "\$SUDO_USER" gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
    sudo -u "\$SUDO_USER" gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
fi
EOF
    sudo chmod +x "$PERF_SCRIPT"

    # Systemd 服務
    sudo tee "/etc/systemd/system/rocm-gpu-performance.service" > /dev/null <<EOF
[Unit]
Description=TigerAI Multi-GPU Optimizer
After=multi-user.target gdm.service
[Service]
Type=oneshot
ExecStart=$PERF_SCRIPT
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable rocm-gpu-performance.service

    LOG "✅ GPU 存取權限與電源設定完成"
}

# ===================== [5/5] 桌面與電源管理 =====================
# 與 nvidia configure_ui_and_power() 對齊。同樣沒有守衛：gdm3 是「先 sed -i 刪掉
# 再重新插入」、gsettings 是設定單一 key，兩者都是純覆寫、重跑不累積。
configure_ui_and_power() {
    LOG "🖥️ [5/5] 設定桌面工作階段與電源管理（關 Wayland、不休眠）..."

    # 1. 關 Wayland、固定用 Xorg session
    GDM_CONFIG="/etc/gdm3/custom.conf"
    if [ -f "$GDM_CONFIG" ]; then
        sudo sed -i '/^WaylandEnable=/d' "$GDM_CONFIG"
        sudo sed -i '/^DefaultSession=/d' "$GDM_CONFIG"
        sudo sed -i '/^\[daemon\]/a WaylandEnable=false\nDefaultSession=gnome-xorg.desktop' "$GDM_CONFIG"
    fi

    # 2. GNOME 電源與螢幕鎖定（以實際操作者的身分寫進他的 dconf）
    # ⚠️ 一定要用 ${SUDO_USER:-$USER}，不能用裸 $USER：本腳本以 sudo 執行時
    #    $USER 是 root，寫進去的是 root 的 dconf，對桌面上的操作者毫無作用。
    # ⚠️ 沒有 GNOME / 沒有 D-Bus session 的機器（server 版）gsettings 會失敗，
    #    用 || true 吞掉 —— 這幾行是選用的桌面體驗設定，不該讓整個安裝中止。
    #    注意 set -e 之下，沒有 || true 的失敗會直接終止腳本。
    # ⚠️ sleep-inactive-ac-type 'nothing' 是三行裡最重要的：它阻止 idle 休眠。
    #    長時間推論的機器休眠掉，等於服務中斷。
    LOG "套用 GNOME 電源與螢幕鎖定設定..."
    REAL_USER=${SUDO_USER:-$USER}
    sudo -u "$REAL_USER" gsettings set org.gnome.desktop.session idle-delay 0 || true
    sudo -u "$REAL_USER" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' || true
    sudo -u "$REAL_USER" gsettings set org.gnome.desktop.screensaver lock-enabled false || true

    LOG "✅ 桌面與電源管理設定完成"
}

# ----------------------- 主程式 -----------------------
LOG "TigerAI ROCm + Docker 安裝程式 ${SCRIPT_VERSION}"
LOG ""

# 與 nvidia / arm64 一致的 root 檢查。同模組的 deploy.sh:41 已經先擋過一次，
# 這是人工單獨執行（sudo bash resource/amd/install.sh）時的第二層防護 ——
# 沒有它的話，缺 sudo 會變成腳本中途每一行都跳密碼提示或失敗。
[ "$(id -u)" -ne 0 ] && ERROR "請用 sudo 執行（或走 sudo bash master-deploy.sh system）。"

install_rocm
install_docker_amd
configure_performance
configure_gpu_power
configure_ui_and_power

LOG "============================================================="
LOG "✅ 安裝完成！"
LOG ""
LOG "已安裝:"
if [ "${AMDGPU_MODE_RESOLVED:-}" = "no-dkms" ]; then
    LOG "  - ROCm (rocm 完整套件；核心驅動用 kernel in-tree amdgpu，未裝 amdgpu-dkms)"
else
    LOG "  - ROCm (amdgpu-dkms + rocm 完整套件)"
fi
LOG "  - Docker CE"
LOG "  - 系統參數 (/etc/sysctl.conf: vm.max_map_count / vm.swappiness)"
LOG "  - GPU 存取權限 (/dev/kfd udev 規則) 與效能優化服務"
LOG "  - GNOME 桌面電源設定 (不休眠、不鎖定)"
LOG ""
LOG "💡 請重啟系統以確保驅動生效："
LOG "   sudo reboot"
LOG ""
LOG "重啟後驗證:"
LOG "   rocm-smi"
LOG "   docker --version"
LOG "   sysctl vm.max_map_count"
LOG "============================================================="

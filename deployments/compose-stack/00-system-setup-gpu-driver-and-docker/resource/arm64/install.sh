#!/usr/bin/env bash
# =====================================================================
# TigerAI ARM64 + NVIDIA GPU Foundation (Grace Blackwell / GH200 Ready)
# Path: deployments/compose-stack/00-system-setup-gpu-driver-and-docker/resource/arm64/install.sh
#
# 由同模組的 deploy.sh 透過 `tiger_res install.sh` 解析後 exec 起來，
# 也可以人工單獨執行（sudo bash resource/arm64/install.sh）。
#
# ⚠️ 本檔與 resource/nvidia/install.sh 目前只差「字串」與一處
#    `arch=arm64` vs `arch=$(dpkg --print-architecture)`（在 arm64 host 上兩者
#    求值相同）。搬移時**刻意不合併** —— 使用者已拍板「每平台一支完整
#    install.sh」，而且真正的分歧遲早會出現（arm64 的 driver 套件名、
#    Jetson/GB10 的 L4T 流程都可能與 x86 NVIDIA 分家）。若日後決定合併，
#    請整批改成 07 / 09 的 `_shared 主體 + 平台入口` 形狀，不要只刪掉一支。
#
# ⚠️ 這支腳本會改變 host 狀態（裝驅動 / 裝 Docker / 寫 sysctl / 寫 systemd unit /
#    改 gdm3），跑完要 reboot。
# =====================================================================

set -eo pipefail

# --- 0) Configuration & Variables ---
# 載入順序（後者覆蓋前者）與 lib/common.sh 的 tiger_load_env 一致：
#   <stack>/tiger-tuning.env → <stack>/.env → <module>/.env
#
# ⚠️ 路徑以本檔位置推導，不用舊版的 `../tiger-tuning.env`。本檔已經從模組根目錄
#    下移兩層到 resource/arm64/，舊的相對路徑會指到 resource/ 底下（永遠不存在），
#    而 `if [ -f ... ]` 沒中就是靜默跳過 —— 結果是 NVIDIA_DRIVER_PACKAGE 之類的
#    設定被無聲忽略，只用 fallback 值，不會有任何錯誤訊息。
#    本檔位於 <stack>/<module>/resource/arm64/，所以 ../.. 是模組目錄、
#    ../../.. 是 stack 根目錄。
#
# ⚠️ 這三個 env 檔都是 .gitignore 的（.gitattributes 的 EOL 正規化管不到），
#    所以仍要 `sed 's/\r$//'` 剝行尾 CRLF。用 source 而非舊版的
#    `export $(... | xargs)`：後者會被含空白／引號的值打爛。
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_MODULE_DIR="$(cd "${_SELF_DIR}/../.." && pwd -P)"
_STACK_DIR="$(cd "${_MODULE_DIR}/.." && pwd -P)"

set -a
for _envfile in "${_STACK_DIR}/tiger-tuning.env" \
                "${_STACK_DIR}/.env" \
                "${_MODULE_DIR}/.env"; do
  if [ -f "$_envfile" ]; then
    # temp file 而非 source <(sed …)：後者在 bash 3.2 會靜默載入空內容
    _tmp=$(mktemp)
    sed 's/\r$//' "$_envfile" > "$_tmp"
    # shellcheck disable=SC1090
    source "$_tmp"
    rm -f "$_tmp"
  fi
done
set +a

# Fallback defaults
NVIDIA_DRIVER_PACKAGE=${NVIDIA_DRIVER_PACKAGE:-"nvidia-driver-580-open"}
NVIDIA_DKMS_PACKAGE=${NVIDIA_DKMS_PACKAGE:-"nvidia-dkms-580"}
NVIDIA_UTILS_PACKAGE=${NVIDIA_UTILS_PACKAGE:-"nvidia-utils-580"}
VM_MAP_COUNT=${VM_MAP_COUNT:-2097152}

# log.sh and not lib/common.sh: this file also runs standalone
# (sudo bash resource/arm64/install.sh), where TIGER_PLATFORM is unset and
# common.sh's ERR trap is unwanted. Paths reuse _STACK_DIR from the env load.
if [ ! -f "${_STACK_DIR}/lib/log.sh" ]; then
    echo "[TigerAI ERROR] not found: ${_STACK_DIR}/lib/log.sh (_SELF_DIR=${_SELF_DIR})" >&2
    exit 1
fi
# shellcheck source-path=SCRIPTDIR/../../../lib
# shellcheck source=log.sh
source "${_STACK_DIR}/lib/log.sh"
TIGER_LOG_PREFIX="TigerAI Foundation (ARM64-NVIDIA)"

# --- 1. NVIDIA Driver (PPA) ---
install_nvidia() {
    LOG " [1/5] Installing NVIDIA Drivers ($NVIDIA_DRIVER_PACKAGE)..."
    
    if command -v nvidia-smi &>/dev/null; then
        SKIP "NVIDIA Driver detected."
    else
        LOG "Adding PPA: graphics-drivers..."
        sudo add-apt-repository -y ppa:graphics-drivers/ppa
        sudo apt update
        
        LOG "Installing Driver Packages..."
        sudo apt install -y "$NVIDIA_DRIVER_PACKAGE" "$NVIDIA_DKMS_PACKAGE" "$NVIDIA_UTILS_PACKAGE"
    fi
}

# --- 2. Docker CE & NVIDIA Container Toolkit ---
install_docker_nvidia() {
    LOG " [2/5] Installing Docker CE & NVIDIA Container Toolkit (ARM64)..."
    
    # 2.1 Docker CE
    if command -v docker &>/dev/null; then
        SKIP "Docker already exists."
    else
        sudo apt update && sudo apt install -y ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
        # shellcheck disable=SC1091  # /etc/os-release 是 Linux 執行期檔案，不在 repo 內
        echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo systemctl enable --now docker
        sudo usermod -aG docker,render,video "$USER"
    fi

    # 2.2 NVIDIA Container Toolkit
    if dpkg -l | grep -q nvidia-container-toolkit; then
       SKIP "NVIDIA Container Toolkit already installed."
    else
       LOG "Configuring NVIDIA Container Toolkit Repository..."
       curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg --yes \
       && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
       sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
       sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

       sudo apt-get update
       sudo apt-get install -y nvidia-container-toolkit

       LOG "Generating CDI configuration..."
       sudo nvidia-ctk runtime configure --runtime=docker
       sudo systemctl restart docker
    fi
}

# --- 3. System Performance & Persistence ---
configure_performance() {
    LOG " [3/5] Configuring System Limits (vm.max_map_count)..."
    # 冪等守衛只認 key、不認值。舊版把「值」寫進 grep 條件（grep -q
    # "vm.max_map_count=$VM_MAP_COUNT"），使用者調過 VM_MAP_COUNT 再重跑 Phase 00
    # 就會 append 第二行而不是取代舊行 —— sysctl -p 後段勝出所以生效值仍正確，但
    # /etc/sysctl.conf 會累積互相矛盾的條目，越跑越髒。
    #
    # 作法：先讀出所有「生效中」的 vm.max_map_count 行；剛好只有一行且就是目標值
    # 才跳過，否則整批刪掉再 append 一行（順帶收掉舊版已經累積出來的重複條目）。
    # ⚠️ 這是使用者 host 的 /etc/sysctl.conf，刪除條件必須嚴格錨在行首的 key：
    #    - `^[[:space:]]*` 容許縮排，`vm\.max_map_count` 的點要跳脫（否則 . 會比對到
    #      任意字元，例如 vmXmax_map_count）
    #    - `[[:space:]]*=` 容許 `vm.max_map_count = 262144` 這種有空白的寫法
    #    - 註解掉的行（`# vm.max_map_count=…`）不符合此式，刻意保留 —— sysctl 不讀它，
    #      那是使用者自己的紀錄，不該被我們清掉
    # 檔案不存在時 grep 取不到東西、也不會走 sed（跟舊版一樣由 tee -a 建檔）。
    local existing
    existing=$(grep -E '^[[:space:]]*vm\.max_map_count[[:space:]]*=' /etc/sysctl.conf 2>/dev/null || true)
    if [ "$existing" = "vm.max_map_count=$VM_MAP_COUNT" ]; then
        SKIP "vm.max_map_count already configured."
    else
        if [ -n "$existing" ]; then
            LOG "取代 /etc/sysctl.conf 中既有的 vm.max_map_count 設定："
            echo "$existing"
            sudo sed -i -E '/^[[:space:]]*vm\.max_map_count[[:space:]]*=/d' /etc/sysctl.conf
        fi
        # 檔尾缺結尾換行時先補一個，否則 tee -a 會把新設定黏在最後一行後面
        # （例：fs.file-max=100000vm.max_map_count=2097152 —— 一次壞掉兩個 key）。
        # $( ) 會剝掉命令輸出結尾的換行，所以「最後一個位元組是 \n」→ 展開成空字串 → 不補；
        # 是其他字元（含空白）→ 非空 → 補。-s 先擋掉空檔與不存在的檔：
        # 兩者都不該補（空檔補了會多一個空行，不存在的檔由後面的 tee -a 建立）。
        if [ -s /etc/sysctl.conf ] && [ -n "$(tail -c1 /etc/sysctl.conf)" ]; then
            echo | sudo tee -a /etc/sysctl.conf > /dev/null
        fi
        echo "vm.max_map_count=$VM_MAP_COUNT" | sudo tee -a /etc/sysctl.conf
        sudo sysctl -p
    fi
}

configure_persistenced() {
    LOG " [4/5] Configuring NVIDIA Persistence Daemon (v1.7) to prevent GPU sleep..."
    
    sudo tee /etc/systemd/system/nvidia-persistenced.service > /dev/null <<EOF
[Unit]
Description=NVIDIA Persistence Daemon (TigerAI v1.7)
After=multi-user.target

[Service]
Type=forking
ExecStartPre=/bin/mkdir -p /var/run/nvidia-persistenced
ExecStartPre=/bin/chown root:root /var/run/nvidia-persistenced
ExecStart=/usr/bin/nvidia-persistenced --user root --verbose
ExecStopPost=/bin/rm -rf /var/run/nvidia-persistenced
PIDFile=/var/run/nvidia-persistenced/nvidia-persistenced.pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now nvidia-persistenced.service || true
    LOG " NVIDIA Persistence Daemon enabled."
}

# --- 5. UI and Power Management ---
configure_ui_and_power() {
    LOG " [5/5] Configuring UI & Power Management (Wayland off, No Sleep)..."
    
    # 1. Disable Wayland & Set Xorg
    LOG "Disabling Wayland and setting GNOME Xorg session..."
    sudo sed -i '/^WaylandEnable=/d' /etc/gdm3/custom.conf
    sudo sed -i '/^DefaultSession=/d' /etc/gdm3/custom.conf
    sudo sed -i '/^\[daemon\]/a WaylandEnable=false\nDefaultSession=gnome-xorg.desktop' /etc/gdm3/custom.conf
    
    # 2. GNOME GSettings (Run as the base user)
    LOG "Applying GNOME Power & Screen lock settings..."
    REAL_USER=${SUDO_USER:-$USER}
    sudo -u "$REAL_USER" gsettings set org.gnome.desktop.session idle-delay 0 || true
    sudo -u "$REAL_USER" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' || true
    sudo -u "$REAL_USER" gsettings set org.gnome.desktop.screensaver lock-enabled false || true
}

# --- Main Logic ---
[ "$(id -u)" -ne 0 ] && ERROR "Please run with sudo."
install_nvidia
install_docker_nvidia
configure_performance
configure_persistenced
configure_ui_and_power

# 收尾結構與 resource/amd/install.sh 對齊（範本在那邊）：完成清單 → reboot 提示 →
# 重啟後驗證指令。平台相關的部分各自寫實際做過的事，不逐字照抄。
# ⚠️ 結構與 amd 一致，但**文字用英文** —— compose-stack 的使用者可見輸出以英文為主，
#    amd 是既有的中文例外。不要為了「對齊範本」把這裡翻成中文。
# ⚠️ 「ARM64 + NVIDIA Foundation Setup Complete. GB10 Blackwell ready!」是使用者
#    辨識「跑對腳本」的字串，不要洗掉。
# ⚠️ 驗證指令用 nvidia-smi：GB10 / Grace Blackwell 上 nvidia-smi 就是正解，本檔
#    install_nvidia() 的冪等守衛、tiger-deploy.sh 的平台偵測、00-pre-flight-advisor
#    的 VRAM 量測在 arm64 上全部走同一支指令。
LOG "============================================================="
LOG "✅ ARM64 + NVIDIA Foundation Setup Complete. GB10 Blackwell ready!"
LOG ""
LOG "Installed:"
LOG "  - NVIDIA Driver ($NVIDIA_DRIVER_PACKAGE / $NVIDIA_DKMS_PACKAGE / $NVIDIA_UTILS_PACKAGE)"
LOG "  - Docker CE (arm64) + NVIDIA Container Toolkit"
LOG "  - Kernel parameters (/etc/sysctl.conf: vm.max_map_count)"
LOG "  - NVIDIA Persistence Daemon (nvidia-persistenced.service)"
LOG "  - GNOME desktop power settings (no sleep, no screen lock)"
LOG ""
LOG "💡 Please reboot so the driver takes effect:"
LOG "   sudo reboot"
LOG ""
LOG "Verify after reboot:"
LOG "   nvidia-smi"
LOG "   docker --version"
LOG "   sysctl vm.max_map_count"
LOG "============================================================="

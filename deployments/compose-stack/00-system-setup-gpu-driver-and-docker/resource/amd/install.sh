#!/usr/bin/env bash
# =====================================================================
# TigerAI GPU Driver + Docker Installer — amd
# Path: deployments/compose-stack/00-system-setup-gpu-driver-and-docker/resource/amd/install.sh
#
# WARNING: this script must stay at the FIRST level of resource/amd/.
# The `../..` below is a hard-coded depth.
#
# No shared body between the three platform entry points: installing ROCm,
# CUDA on x86 and CUDA on aarch64 have almost nothing in common beyond the
# Docker steps, and the pre-merge scripts had already drifted apart. Each one
# is kept whole rather than forced into a common skeleton.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# <module>/resource/amd/<this file>  ->  ../.. is the module directory.
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
TIGER_LOG_PREFIX="TigerAI System Setup"
# shellcheck source=../../../lib/common.sh
source "${TIGER_MODULE_DIR}/../lib/common.sh"

# ----------------------- 2) 安裝 ROCm -----------------------
install_rocm() {
    LOG "📦 [1/3] 安裝 ROCm..."

    # 刪除可能存在的損壞檔案
    if [ -f "$DEB_FILENAME" ] && [ ! -s "$DEB_FILENAME" ]; then
        rm -f "$DEB_FILENAME"
    fi

    # 下載 amdgpu-install
    if [ ! -f "$DEB_FILENAME" ]; then
        LOG "下載: $ROCM_DEB_URL"
        if ! wget --progress=bar:force "$ROCM_DEB_URL" -O "$DEB_FILENAME"; then
            ERROR "下載失敗，請檢查網路或 URL: $ROCM_DEB_URL"
        fi
    else
        LOG "✅ 找到本地檔案: $DEB_FILENAME"
    fi

    # 安裝 amdgpu-install
    LOG "安裝 amdgpu-install..."
    sudo apt install -y ./"$DEB_FILENAME"

    # 更新套件列表
    LOG "更新套件列表..."
    sudo apt update

    # 安裝 kernel headers
    LOG "安裝 kernel headers..."
    sudo apt install -y "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"

    # 安裝 amdgpu-dkms
    LOG "安裝 amdgpu-dkms..."
    sudo apt install -y amdgpu-dkms

    # 安裝 rocm 完整套件
    LOG "安裝 rocm 完整套件..."
    sudo apt install -y rocm

    LOG "✅ ROCm 基礎安裝完成"
}

# ----------------------- 3) 安裝 Docker -----------------------
install_docker() {
    LOG "🐳 [2/3] 安裝 Docker..."

    if command -v docker &>/dev/null; then
        SKIP "Docker 已存在，跳過安裝"
    else
        LOG "安裝 Docker CE..."
        sudo apt update
        sudo apt install -y ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo systemctl enable --now docker
        LOG "✅ Docker 安裝完成"
    fi

    sudo usermod -aG docker,render,video "$USER"
}

# ----------------------- 4) 系統優化 -----------------------
configure_system() {
    LOG "🖥️ [3/3] 系統優化..."

    # GDM3 設定
    GDM_CONFIG="/etc/gdm3/custom.conf"
    if [ -f "$GDM_CONFIG" ]; then
        sudo sed -i '/^WaylandEnable=/d' "$GDM_CONFIG"
        sudo sed -i '/^DefaultSession=/d' "$GDM_CONFIG"
        sudo sed -i '/^\[daemon\]/a WaylandEnable=false\nDefaultSession=gnome-xorg.desktop' "$GDM_CONFIG"
    fi

    # UDEV 權限
    echo 'SUBSYSTEM=="kfd", KERNEL=="kfd", TAG+="uaccess", GROUP="render", MODE="0660"' | sudo tee /etc/udev/rules.d/70-kfd.rules > /dev/null
    sudo udevadm control --reload-rules && sudo udevadm trigger

    # GPU 效能優化腳本
    PERF_SCRIPT="/usr/local/bin/rocm-gpu-performance.sh"
    sudo tee "$PERF_SCRIPT" > /dev/null <<EOF
#!/bin/bash
sysctl -w vm.max_map_count=$VM_MAP_COUNT
sysctl -w vm.swappiness=10
GPU_DEVICES=\$(find /sys/class/drm/card*/device -maxdepth 0 -exec sh -c 'if [ -f "{}/vendor" ] && [ "\$(cat "{}/vendor" 2>/dev/null)" = "0x1002" ]; then echo "{}"; fi' \; 2>/dev/null)
for GPU_PATH in \$GPU_DEVICES; do
    echo "on" > "\$GPU_PATH/power/control" 2>/dev/null || true
    [ -f "\$GPU_PATH/power_dpm_force_performance_level" ] && echo "$SET_PERF_LEVEL" > "\$GPU_PATH/power_dpm_force_performance_level"
done
if command -v powerprofilesctl &>/dev/null; then powerprofilesctl set performance; fi
export DISPLAY=:0
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

    LOG "✅ 系統優化完成"
}

# ----------------------- 5) 主程式 -----------------------
LOG "TigerAI ROCm + Docker 安裝程式 v2.12.31"
LOG ""

install_rocm
install_docker
configure_system

LOG "============================================================="
LOG "✅ 安裝完成！"
LOG ""
LOG "已安裝:"
LOG "  - ROCm (amdgpu-dkms + rocm 完整套件)"
LOG "  - Docker CE"
LOG "  - GPU 效能優化服務"
LOG ""
LOG "💡 請重啟系統以確保驅動生效："
LOG "   sudo reboot"
LOG ""
LOG "重啟後驗證:"
LOG "   rocm-smi"
LOG "   docker --version"
LOG "============================================================="

#!/usr/bin/env bash
# =====================================================================
# TigerAI ARM64 + NVIDIA GPU Foundation (Grace Blackwell / GH200 Ready)
# Path: deployments/arm64-compose-stack/00-system-setup-nvidia-docker/deploy.sh
# =====================================================================

set -eo pipefail

# --- 0) Configuration & Variables ---
# Import from .env
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Fallback defaults
NVIDIA_DRIVER_PACKAGE=${NVIDIA_DRIVER_PACKAGE:-"nvidia-driver-580-open"}
NVIDIA_DKMS_PACKAGE=${NVIDIA_DKMS_PACKAGE:-"nvidia-dkms-580"}
NVIDIA_UTILS_PACKAGE=${NVIDIA_UTILS_PACKAGE:-"nvidia-utils-580"}
VM_MAP_COUNT=${VM_MAP_COUNT:-2097152}

LOG_PREFIX="TigerAI Foundation (ARM64-NVIDIA)"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
SKIP(){ echo -e "${BLUE}[$LOG_PREFIX SKIP]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

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
       curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
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
    if ! grep -q "vm.max_map_count=$VM_MAP_COUNT" /etc/sysctl.conf; then
        echo "vm.max_map_count=$VM_MAP_COUNT" | sudo tee -a /etc/sysctl.conf
        sudo sysctl -p
    else
        SKIP "vm.max_map_count already configured."
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

LOG " ARM64 + NVIDIA Foundation Setup Complete. GB10 Blackwell ready!"

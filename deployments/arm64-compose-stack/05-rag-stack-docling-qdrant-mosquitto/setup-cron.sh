#!/usr/bin/env bash
# =====================================================================
# TigerAI Device MQTT Cron Installer
# Path: deployments/arm64-compose-stack/05-rag-stack-docling-qdrant-mosquitto/setup-cron.sh
# =====================================================================

set -eo pipefail

LOG_PREFIX="TigerAI Device Cron"
GREEN='\033[0;32m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_SCRIPT="$SCRIPT_DIR/monitor_device.py"
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python3"

# Check if scripts and venv exist
if [ ! -f "$MONITOR_SCRIPT" ]; then
    echo "Error: $MONITOR_SCRIPT not found"
    exit 1
fi
if [ ! -f "$VENV_PYTHON" ]; then
    echo "Error: Virtual environment not found at $VENV_PYTHON. Please run deploy.sh first."
    exit 1
fi

# 1. Setup Monitor Cron (@reboot)
MON_CRON_JOB="@reboot cd $SCRIPT_DIR && $VENV_PYTHON $MONITOR_SCRIPT > $SCRIPT_DIR/device_monitor.log 2>&1"

if crontab -l 2>/dev/null | grep -q "$MONITOR_SCRIPT"; then
    LOG "Device Monitor cron job already exists, skipping."
else
    LOG "Installing Device Monitor cron job (@reboot)..."
    (crontab -l 2>/dev/null; echo "$MON_CRON_JOB") | crontab -
fi

LOG "MQTT Device scripts installed to crontab."
crontab -l | grep "monitor_device"

#!/usr/bin/env bash
# =====================================================================
# TigerAI Device MQTT Cron Installer
# Path: deployments/compose-stack/05-rag-stack-docling-qdrant-mosquitto/resource/_shared/setup-cron.sh
#
# WARNING: this script must stay at the FIRST level of resource/_shared/.
# The `../..` below is a hard-coded depth.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# <module>/resource/_shared/<this file>  ->  ../.. is the module directory.
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Device Cron"
# shellcheck source=../../../lib/common.sh
source "${TIGER_MODULE_DIR}/../lib/common.sh"

MONITOR_SCRIPT="$(tiger_res monitor_device.py)"
# The virtualenv stays at the module level, not beside the script — deploy.sh
# creates it there and resource/ holds tracked files only.
VENV_PYTHON="${TIGER_MODULE_DIR}/.venv/bin/python3"

[ -f "$MONITOR_SCRIPT" ] || ERROR "monitor script not found: $MONITOR_SCRIPT"
[ -f "$VENV_PYTHON" ] || ERROR "virtualenv not found at $VENV_PYTHON. Run deploy.sh first."

# Unlike 08's purge job, this cron entry needs no TIGER_PLATFORM: it runs the
# python script directly and never sources lib/common.sh.
MON_CRON_JOB="@reboot cd ${TIGER_MODULE_DIR} && ${VENV_PYTHON} ${MONITOR_SCRIPT} > ${TIGER_MODULE_DIR}/device_monitor.log 2>&1"

if crontab -l 2>/dev/null | grep -q "$MONITOR_SCRIPT"; then
    LOG "Device monitor cron job already exists, skipping."
else
    LOG "Installing the device monitor cron job (@reboot)..."
    (crontab -l 2>/dev/null; echo "$MON_CRON_JOB") | crontab -
fi

LOG "MQTT device script installed to crontab:"
crontab -l | grep "monitor_device"

#!/usr/bin/env bash
# =====================================================================
# TigerAI Device MQTT Cron Installer
# Path: deployments/compose-stack/05-rag-stack-docling-qdrant-mosquitto/resource/_shared/setup-cron.sh
#
# Called by deploy.sh's `cron` action, and runnable directly. Two anchors, do
# not mix them: $SCRIPT_DIR holds what moves with this script
# (monitor_device.py), $MODULE_DIR what stays at the module root (.venv, .env,
# the log).
#
# WARNING: must stay at the FIRST level of resource/_shared/. The `../..` below
# is a hard-coded depth.
# =====================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
STACK_DIR="$(cd "${MODULE_DIR}/.." && pwd -P)"

# log.sh and not lib/common.sh: monitor_device.py sits beside this file, so
# tiger_res is unnecessary and TIGER_PLATFORM should not be required.
if [ ! -f "${STACK_DIR}/lib/log.sh" ]; then
    echo "[TigerAI Device Cron ERROR] not found: ${STACK_DIR}/lib/log.sh (SCRIPT_DIR=${SCRIPT_DIR})" >&2
    exit 1
fi
# shellcheck source-path=SCRIPTDIR/../../../lib
# shellcheck source=log.sh
source "${STACK_DIR}/lib/log.sh"
TIGER_LOG_PREFIX="TigerAI Device Cron"

MONITOR_SCRIPT="${SCRIPT_DIR}/monitor_device.py"
# The virtualenv stays at the module level: deploy.sh creates it there, and
# resource/ holds tracked files only.
VENV_PYTHON="${MODULE_DIR}/.venv/bin/python3"

[ -f "$MONITOR_SCRIPT" ] || ERROR "monitor script not found: $MONITOR_SCRIPT"
[ -f "$VENV_PYTHON" ] || ERROR "virtualenv not found at $VENV_PYTHON. Run deploy.sh first."

MON_CRON_JOB="@reboot cd ${MODULE_DIR} && ${VENV_PYTHON} ${MONITOR_SCRIPT} > ${MODULE_DIR}/device_monitor.log 2>&1"

if crontab -l 2>/dev/null | grep -q "$MONITOR_SCRIPT"; then
    LOG "Device monitor cron job already exists, skipping."
else
    LOG "Installing the device monitor cron job (@reboot)..."
    # WARNING: `|| true` is required. On a host with no crontab yet, `crontab -l`
    # exits 1, which under `set -e` ends the subshell before the echo runs —
    # `crontab -` then receives empty input and installs an EMPTY crontab, while
    # pipefail makes this script exit 1. Every fresh machine hits this.
    (crontab -l 2>/dev/null || true; echo "$MON_CRON_JOB") | crontab -
fi

LOG "MQTT device script installed to crontab:"
crontab -l 2>/dev/null | grep "monitor_device" || NO_MATCH=1
# `if`, not `[ ... ] && ERROR`: the latter's exit status is 1 on the happy path,
# which `set -e` would turn into a failed run.
if [ -n "${NO_MATCH:-}" ]; then
    ERROR "monitor_device is still absent from the crontab — the install did not take effect."
fi

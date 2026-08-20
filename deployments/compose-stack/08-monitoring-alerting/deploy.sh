#!/usr/bin/env bash
# =====================================================================
# TigerAI Monitoring Deployer
# Path: deployments/compose-stack/08-monitoring-alerting/deploy.sh
#
# No compose file and no platform entries — see
# resource/_shared/tiger-monitor.sh for why one shared copy is correct here.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Monitor Deploy"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

MONITOR_SCRIPT="$(tiger_res tiger-monitor.sh)"
chmod +x "$MONITOR_SCRIPT"

# -E so TIGER_PLATFORM survives the sudo boundary; the install action bakes it
# into the systemd unit.
sudo -E "$MONITOR_SCRIPT" install

LOG "Monitoring service deployed and activated."

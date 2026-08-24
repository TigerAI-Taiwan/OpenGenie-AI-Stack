#!/usr/bin/env bash
# =====================================================================
# TigerAI Monitoring Deployer
# Path: deployments/compose-stack/09-monitoring-alerting/deploy.sh
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

# `master-deploy.sh clean` runs `deploy.sh down` on every module. Without the
# branch below it would fall through and *start* the monitor instead.
ACTION=${1:-all}

case "$ACTION" in
    down)
        sudo "$MONITOR_SCRIPT" uninstall
        LOG "Monitoring service removed."
        ;;
    *)
        # -E so TIGER_PLATFORM survives the sudo boundary; the install action
        # bakes it into the systemd unit.
        sudo -E "$MONITOR_SCRIPT" install
        LOG "Monitoring service deployed and activated."
        ;;
esac

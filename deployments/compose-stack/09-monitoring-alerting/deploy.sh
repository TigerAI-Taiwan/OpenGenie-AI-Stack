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

# This module has no compose file, so it must dispatch on the action itself.
# Without the `down` branch, `master-deploy.sh clean` — which runs
# `deploy.sh down` on every module — would fall through to the install below
# and *start* the monitor as part of tearing the stack down.
ACTION=${1:-all}

case "$ACTION" in
    down)
        sudo "$MONITOR_SCRIPT" uninstall
        LOG "Monitoring service removed."
        ;;
    *)
        # Default, including the `all` / `restart` that master-deploy.sh passes.
        # Unknown arguments land here too, preserving the prior behaviour.
        # -E so TIGER_PLATFORM survives the sudo boundary; the install action
        # bakes it into the systemd unit.
        sudo -E "$MONITOR_SCRIPT" install
        LOG "Monitoring service deployed and activated."
        ;;
esac

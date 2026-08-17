#!/usr/bin/env bash
# =====================================================================
# TigerAI Infra Deployer (WebSSH, Portainer, Portainer Edge Agent)
# Path: deployments/compose-stack/01-infra-webssh-portainer/deploy.sh
#
# No platform overlay: the compose file was byte-identical across the amd,
# nvidia and arm64 stacks, so docker-compose.base.yaml serves all three.
#
# Merged from the three former per-platform deploy.sh scripts. The env
# loading, colors, logging and ensure_network boilerplate they each carried
# now lives in lib/common.sh; what differed beyond that was the subcommand
# set, and the union is taken:
#   - `agent` existed only in arm64          -> kept (the portainer-edge-agent
#                                               service is in the shared file,
#                                               so it works on every platform)
#   - `down` / `restart` were missing in nvidia -> kept
#   - `all` did `down` + `up -d --force-recreate` in nvidia but plain `up -d`
#     in amd / arm64 -> plain `up -d`, which is idempotent and does not tear
#     down running containers on a re-run. Use `restart` for a deliberate cycle.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Infra"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    echo "Usage: sudo $0 {all | webssh | portainer | agent | down | restart}"
    exit 1
}

[ $# -eq 0 ] && usage

ACTION="$1"
ensure_network

case "$ACTION" in
    all)
        LOG "Starting all infrastructure (WebSSH, Portainer, Edge Agent)..."
        tiger_compose up -d
        ;;
    webssh|portainer)
        LOG "Starting specific service: $ACTION..."
        tiger_compose up -d "$ACTION"
        ;;
    agent)
        LOG "Starting specific service: portainer-edge-agent..."
        tiger_compose up -d portainer-edge-agent
        ;;
    down)
        LOG "Removing all infrastructure containers..."
        tiger_compose down
        ;;
    restart)
        LOG "Restarting all infrastructure..."
        tiger_compose restart
        ;;
    *)
        usage
        ;;
esac

LOG "Deployment command finished."

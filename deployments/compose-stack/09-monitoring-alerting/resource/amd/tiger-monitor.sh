#!/usr/bin/env bash
# =====================================================================
# TigerAI Proactive Health Monitor — amd entry point
# Path: deployments/compose-stack/09-monitoring-alerting/resource/amd/tiger-monitor.sh
#
# The entry point does four things and nothing else. Env loading, the SERVICES base
# list, check_and_notify and the once/start/install dispatcher all live in the
# shared body — do not copy them back here.
#
# WARNING: must stay at the FIRST level of resource/amd/. The `../..` is a
# hard-coded depth.
# =====================================================================

export TIGER_PLATFORM=amd

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
# systemd's ExecStart must point here, not at the shared body.
TIGER_MONITOR_ENTRY="${BASH_SOURCE[0]}"
export TIGER_MONITOR_ENTRY
# shellcheck source=../_shared/tiger-monitor-common.sh
source "${TIGER_MODULE_DIR}/resource/_shared/tiger-monitor-common.sh"

# amd-only: Lemonade AI core (06-ai-core-lemonade). EDU is always up under
# either tiger-mode.
#
# WARNING: probe with /live, not /health. /health is behind the API key —
# it answers 401 when LEMONADE_API_KEY is set, and probe() uses `curl -f`, so
# a perfectly healthy engine would be reported as FAIL on any machine that set
# one. /live is the unauthenticated liveness endpoint, and it is what this
# module's own compose healthchecks already use
# (06-ai-core-lemonade/docker-compose.base.yaml: `curl -sf .../live`).
SERVICES+=(
    "Lemonade_EDU:http://$TARGET_HOST:8800/live"
)
# rag (8801) and embed (8802) are mutually exclusive — `deploy.sh rag` stops
# embed and vice versa — so exactly one of them answers at any time. Listing
# them individually would report a permanent FAIL for whichever mode is not
# active; as a group, the check is "at least one is up".
SERVICES_ANY_OF=(
    "Lemonade_RAG_or_EMBED:http://$TARGET_HOST:8801/live|http://$TARGET_HOST:8802/live"
)

tiger_monitor_main "${1:-}"

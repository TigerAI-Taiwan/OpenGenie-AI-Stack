#!/usr/bin/env bash
# =====================================================================
# TigerAI Proactive Health Monitor — arm64 entry point
# Path: deployments/compose-stack/09-monitoring-alerting/resource/arm64/tiger-monitor.sh
#
# The entry point does three things and nothing else. Env loading, the SERVICES base
# list, check_and_notify and the once/start/install dispatcher all live in the
# shared body — do not copy them back here.
#
# WARNING: must stay at the FIRST level of resource/arm64/. The `../..` is a
# hard-coded depth.
# =====================================================================

# Load bearing: the systemd unit sets no TIGER_PLATFORM, so this is the only
# place the platform gets set for the service. Do not remove.
export TIGER_PLATFORM=arm64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
# systemd's ExecStart must point here, not at the shared body.
TIGER_MONITOR_ENTRY="${BASH_SOURCE[0]}"
export TIGER_MONITOR_ENTRY
# shellcheck source=../_shared/tiger-monitor-common.sh
source "${TIGER_MODULE_DIR}/resource/_shared/tiger-monitor-common.sh"

# arm64 has no platform-specific services: 03-ai-core/lemonade is amd-only, and
# LLM inference here is Ollama in 03-ai-core/ollama, added by the shared body when
# TIGER_MONITOR_BACKEND=ollama.

tiger_monitor_main "${1:-}"

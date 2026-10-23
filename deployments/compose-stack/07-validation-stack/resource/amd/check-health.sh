#!/usr/bin/env bash
# =====================================================================
# TigerAI Stack Health Validator — amd entry point
# Path: deployments/compose-stack/07-validation-stack/resource/amd/check-health.sh
#
# The entry point does three things and nothing else. Env loading, the colors,
# check_endpoint and phases 1-4 all live in the shared body — do not copy them
# back here:
#   1. source the shared body
#   2. run it, then add this platform's own checks — amd is the only platform
#      that deploys 06-ai-core-lemonade
#   3. print the closing line, which must be last
#
# WARNING: must stay at the FIRST level of resource/amd/. The `../..` is a
# hard-coded depth.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
# shellcheck source=../_shared/check-health-common.sh
source "${TIGER_MODULE_DIR}/resource/_shared/check-health-common.sh"

tiger_check_health_main

# Phase 5: Lemonade Core — amd only.
LOG "--- [Phase 5: Lemonade Core] ---"
# /live is lemond's liveness endpoint, the same one the container healthcheck
# uses. Lemonade answers 401 when an API key is set but not supplied. That still
# means the service is up, hence the 200|401 alternation.
check_endpoint "Lemonade EDU (8800)" "http://$TARGET_HOST:8800/live" "200|401" \
    || WARN "Lemonade EDU (always-on) might be stopped"
# lemonade-rag and lemonade-embed are not checked: tiger-mode runs exactly one of
# them, so the idle one not answering is normal and a check would only be noise.

LOG "Validation Check Finished."

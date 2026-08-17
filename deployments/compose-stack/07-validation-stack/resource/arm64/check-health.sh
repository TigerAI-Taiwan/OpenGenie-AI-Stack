#!/usr/bin/env bash
# =====================================================================
# TigerAI Stack Health Validator — arm64 entry point
# Path: deployments/compose-stack/07-validation-stack/resource/arm64/check-health.sh
#
# The entry point does two things and nothing else. Env loading, the colors,
# check_endpoint and phases 1-4 all live in the shared body — do not copy them
# back here:
#   1. source the shared body and run it
#   2. print the closing line, which must be last
#
# arm64 has no platform-specific checks: 06-ai-core-lemonade is amd-only, and
# LLM inference on this platform is Ollama in 03-ai-interface, which the
# shared body already covers.
#
# WARNING: must stay at the FIRST level of resource/arm64/. The `../..` is a
# hard-coded depth.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
# shellcheck source=../_shared/check-health-common.sh
source "${TIGER_MODULE_DIR}/resource/_shared/check-health-common.sh"

tiger_check_health_main

LOG "Validation Check Finished."

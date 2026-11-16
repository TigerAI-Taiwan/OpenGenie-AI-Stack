#!/usr/bin/env bash
# =====================================================================
# TigerAI Phase 03 — AI Core pre-deploy (read-only)
# Path: deployments/compose-stack/03-ai-core/pre-deploy.sh
#
# Validates the raw INFERENCE_BACKEND value; never calls docker.
# Exit codes: 0 all set / 1 something is missing
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # read by lib/common.sh's LOG/WARN/ERROR
TIGER_LOG_PREFIX="Phase-03"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
MOD="03-ai-core"
ENV_FILE="${TIGER_STACK_DIR}/.env"

missing=0
if ! _ib_err="$(tiger_inference_backend_validate "${INFERENCE_BACKEND:-}" "$TIGER_PLATFORM" 2>&1)"; then
    missing=$((missing + 1))
    printf '[MISSING] %s/INFERENCE_BACKEND — %s\n' "$MOD" "$_ib_err"
    printf '    # Fix INFERENCE_BACKEND in %s\n' "$ENV_FILE"
fi
printf 'PRE-DEPLOY %s: %d missing\n' "$MOD" "$missing"
[ "$missing" -eq 0 ] || exit 1

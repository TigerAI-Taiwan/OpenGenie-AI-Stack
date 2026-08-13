#!/usr/bin/env bash
# =====================================================================
# TigerAI Validation Module Initializer
# Path: deployments/compose-stack/07-validation-stack/deploy.sh
#
# No compose file and no platform entries: every file here was identical
# across the three stacks apart from drift in check-health.sh, and none of
# the checks were GPU-specific. See resource/_shared/check-health.sh.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Validation"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

LOG "Initializing validation scripts..."

for s in check-health.sh benchmark-tps.sh; do
    chmod +x "$(tiger_res "$s")"
done

LOG "✅ Validation module ready. Run 'master-deploy.sh test' to verify the stack."

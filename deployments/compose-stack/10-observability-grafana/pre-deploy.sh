#!/usr/bin/env bash
# =====================================================================
# TigerAI Phase 10 — Observability pre-deploy (read-only)
# Path: deployments/compose-stack/10-observability-grafana/pre-deploy.sh
#
# Checks that GRAFANA_PASS and PG_PASS hold real values.
# Read-only: writes nothing and never calls docker.
# Exit codes: 0 all set / 1 something is missing
# Output: one `[MISSING] 10-observability-grafana/<name> — <reason>` per missing
#         item, followed by indented commands; the last line is
#         `PRE-DEPLOY 10-observability-grafana: N missing`.
# =====================================================================

# shellcheck disable=SC2016  # the $(...) in the printed fix commands must stay literal
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # read by lib/common.sh's LOG/WARN/ERROR
TIGER_LOG_PREFIX="Phase-10"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
MOD="10-observability-grafana"
ENV_FILE="${TIGER_STACK_DIR}/.env"

missing=0
if is_placeholder "${GRAFANA_PASS:-}"; then
    missing=$((missing + 1))
    printf '[MISSING] %s/GRAFANA_PASS — not set or still a placeholder (an empty value makes compose fall back to the literal CHANGE_ME)\n' "$MOD"
    printf '    # Only applied when the grafana database is first initialised; on a deployed host .env does not change the real admin password (change it in the Grafana UI or grafana cli)\n'
    printf '    # Already deployed: put back the value in use, or any non-placeholder value, to pass; no need to change it\n'
    printf '    # Fresh install only: generate a new value (writes %s; delete the line from %s/.env if it is there)\n' "$ENV_FILE" "$SCRIPT_DIR"
    printf '    if grep -q "^GRAFANA_PASS=" "%s"; then sed -i "s|^GRAFANA_PASS=.*|GRAFANA_PASS=$(openssl rand -hex 16)|" "%s"; else { echo; echo "GRAFANA_PASS=$(openssl rand -hex 16)"; } >> "%s"; fi\n' \
        "$ENV_FILE" "$ENV_FILE" "$ENV_FILE"
fi

# PG_PASS is also used here (GF_DATABASE_PASSWORD). When this module is deployed on its own,
# 02-database's check does not run, so check the effective value here too.
if is_placeholder "${PG_PASS:-}"; then
    missing=$((missing + 1))
    printf '[MISSING] %s/PG_PASS — not set or still a placeholder (Grafana would log in to postgres with the literal CHANGE_ME); see the 02-database pre-deploy for how to fix it\n' "$MOD"
fi

printf 'PRE-DEPLOY %s: %d missing\n' "$MOD" "$missing"
[ "$missing" -eq 0 ] || exit 1

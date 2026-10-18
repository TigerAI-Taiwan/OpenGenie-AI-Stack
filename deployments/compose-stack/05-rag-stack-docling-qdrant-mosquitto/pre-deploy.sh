#!/usr/bin/env bash
# =====================================================================
# TigerAI Phase 05 — RAG stack pre-deploy (read-only)
# Path: deployments/compose-stack/05-rag-stack-docling-qdrant-mosquitto/pre-deploy.sh
#
# Checks that MQTT_PASSWORD holds a real value.
# Read-only: writes nothing and never calls docker.
# Exit codes: 0 all set / 1 something is missing
# Output: `[MISSING] 05-rag-stack/MQTT_PASSWORD — <reason>` followed by indented
#         commands; the last line is `PRE-DEPLOY 05-rag-stack: N missing`.
# =====================================================================

# shellcheck disable=SC2016  # the $(...) in the printed fix commands must stay literal
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # read by lib/common.sh's LOG/WARN/ERROR
TIGER_LOG_PREFIX="Phase-05"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
MOD="05-rag-stack"
ENV_FILE="${TIGER_STACK_DIR}/.env"

missing=0

# Check the effective value: mirror compose's ${MQTT_PASSWORD:-CHANGE_ME}, so
# unset or empty lands on the placeholder and is blocked.
if is_placeholder "${MQTT_PASSWORD:-CHANGE_ME}"; then
    missing=$((missing + 1))
    printf '[MISSING] %s/MQTT_PASSWORD — not set or still a placeholder; mosquitto would accept the public string CHANGE_ME as the password of %s\n' "$MOD" "${MQTT_USERNAME:-tigerai}"
    printf '    # Used by: the mosquitto password file and healthcheck (05 docker-compose.base.yaml), 05 monitor_device.py, 09 tiger-monitor\n'
    printf '    # After changing it: redeploy 05 (the password file is regenerated when the container is recreated), then restart\n'
    printf '    #   monitor_device.py (a @reboot cron job: reboot, or kill it and re-run the cron line) and: sudo systemctl restart tiger-monitor\n'
    printf '    # If a real value is already set elsewhere (stack .env or 05/.env), put back the value in use instead of inventing one\n'
    printf '    # Fresh install only (writes %s; delete the line from %s/.env if it is there — it overrides the stack level):\n' "$ENV_FILE" "$SCRIPT_DIR"
    printf '    if grep -q "^MQTT_PASSWORD=" "%s"; then sed -i "s|^MQTT_PASSWORD=.*|MQTT_PASSWORD=$(openssl rand -hex 32)|" "%s"; else { echo; echo "MQTT_PASSWORD=$(openssl rand -hex 32)"; } >> "%s"; fi\n' \
        "$ENV_FILE" "$ENV_FILE" "$ENV_FILE"
fi

printf 'PRE-DEPLOY %s: %d missing\n' "$MOD" "$missing"
[ "$missing" -eq 0 ] || exit 1

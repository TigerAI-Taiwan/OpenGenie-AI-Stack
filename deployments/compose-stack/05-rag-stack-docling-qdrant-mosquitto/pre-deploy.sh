#!/usr/bin/env bash
# =====================================================================
# TigerAI Phase 05 — RAG stack pre-deploy (read-only)
# Path: deployments/compose-stack/05-rag-stack-docling-qdrant-mosquitto/pre-deploy.sh
#
# Checks that QDRANT_API_KEY, QDRANT_READ_ONLY_API_KEY and MQTT_PASSWORD hold
# real values. The two Qdrant keys being equal is only a WARN, not a block.
# Read-only: writes nothing and never calls docker.
# Exit codes: 0 all set / 1 something is missing
# Output: one `[MISSING] 05-rag-stack/<name> — <reason>` per missing item,
#         followed by indented commands; the last line is `PRE-DEPLOY 05-rag-stack: N missing`.
# =====================================================================

# shellcheck disable=SC2016  # the $(...) in the printed fix commands must stay literal
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # read by lib/common.sh's LOG/WARN/ERROR
TIGER_LOG_PREFIX="Phase-05"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
MOD="05-rag-stack"
ENV_FILE="${TIGER_STACK_DIR}/.env"

# 6333 is bound to 0.0.0.0 (the LAN plaintext path is kept on purpose), so the
# API key is the only access control; an empty key means no authentication at
# all, with no symptom. Both keys are always checked.
missing=0
for k in QDRANT_API_KEY QDRANT_READ_ONLY_API_KEY; do
    is_placeholder "${!k:-}" || continue
    missing=$((missing + 1))
    printf '[MISSING] %s/%s — not set or still a placeholder; Qdrant would accept requests without authentication\n' "$MOD" "$k"
    if [ "$k" = QDRANT_API_KEY ]; then
        printf '    # Do not change it on a host that already has a real value: the OpenWebUI and n8n credentials both carry this key\n'
    else
        printf '    # Generate it separately from QDRANT_API_KEY; the two must differ\n'
    fi
    printf '    # Writes %s; delete the line from %s/.env if it is there — it overrides the stack .env:\n' "$ENV_FILE" "$SCRIPT_DIR"
    printf '    if grep -q "^%s=" "%s"; then sed -i "s|^%s=.*|%s=$(openssl rand -hex 32)|" "%s"; else { echo; echo "%s=$(openssl rand -hex 32)"; } >> "%s"; fi\n' \
        "$k" "$ENV_FILE" "$k" "$k" "$ENV_FILE" "$k" "$ENV_FILE"
done

qdrant_missing=$missing

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

# Equal keys are not blocked, only flagged: Qdrant checks the admin key first, so
# a read-only key equal to it has write access. Checked only once both are real,
# otherwise two CHANGE_ME values would always match and be reported twice.
if [ "$qdrant_missing" -eq 0 ] && [ "$QDRANT_API_KEY" = "$QDRANT_READ_ONLY_API_KEY" ]; then
    WARN "QDRANT_API_KEY and QDRANT_READ_ONLY_API_KEY are equal — the read-only key has write access; deploying anyway. To fix, change only the read-only key (QDRANT_READ_ONLY_API_KEY=\$(openssl rand -hex 32)), then run sudo bash ${SCRIPT_DIR}/deploy.sh qdrant."
fi

printf 'PRE-DEPLOY %s: %d missing\n' "$MOD" "$missing"
[ "$missing" -eq 0 ] || exit 1

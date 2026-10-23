#!/usr/bin/env bash
# =====================================================================
# TigerAI Phase 03 — AI Interface pre-deploy (read-only)
# Path: deployments/compose-stack/03-ai-interface-ollama-openwebui-redis/pre-deploy.sh
#
# Checks that OWUI_SECRET_KEY and PG_PASS hold real values.
# Read-only: writes nothing and never calls docker.
# Exit codes: 0 all set / 1 something is missing
# Output: one `[MISSING] 03-ai-interface/<name> — <reason>` per missing item,
#         followed by indented commands; the last line is `PRE-DEPLOY 03-ai-interface: N missing`.
# =====================================================================

# shellcheck disable=SC2016  # the $(...) in the printed fix commands must stay literal
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # read by lib/common.sh's LOG/WARN/ERROR
TIGER_LOG_PREFIX="Phase-03"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
MOD="03-ai-interface"
ENV_FILE="${TIGER_STACK_DIR}/.env"

# An empty value makes compose fall back to the literal CHANGE_ME, so empty is
# blocked too. The value checked is the one left after tiger_load_env.
missing=0
if is_placeholder "${OWUI_SECRET_KEY:-}"; then
    missing=$((missing + 1))
    printf '[MISSING] %s/OWUI_SECRET_KEY — not set or still a placeholder (OpenWebUI WEBUI_SECRET_KEY: signs login tokens and derives the OAuth session encryption key; an empty value makes compose fall back to the literal CHANGE_ME)\n' "$MOD"
    printf '    # Already running? Do not generate a new value: changing it logs everyone out. Put back the value currently in use:\n'
    printf '    #   sudo docker exec openwebui-main printenv WEBUI_SECRET_KEY   # if the container is gone, look in an old .env or a backup\n'
    printf '    #   (if that prints CHANGE_ME, there is nothing to keep: generate a new value below; users must log in again)\n'
    printf '    # Fresh install (writes %s; delete the line from %s/.env if it is there):\n' "$ENV_FILE" "$SCRIPT_DIR"
    printf '    if grep -q "^OWUI_SECRET_KEY=" "%s"; then sed -i "s|^OWUI_SECRET_KEY=.*|OWUI_SECRET_KEY=$(openssl rand -hex 32)|" "%s"; else { echo; echo "OWUI_SECRET_KEY=$(openssl rand -hex 32)"; } >> "%s"; fi\n' \
        "$ENV_FILE" "$ENV_FILE" "$ENV_FILE"
fi

# PG_PASS is also used here (OpenWebUI DATABASE_URL). When this module is deployed on its own,
# 02-database's check does not run, so check the effective value here too.
if is_placeholder "${PG_PASS:-}"; then
    missing=$((missing + 1))
    printf '[MISSING] %s/PG_PASS — not set or still a placeholder (OpenWebUI would log in to postgres with the literal CHANGE_ME); see the 02-database pre-deploy for how to fix it\n' "$MOD"
fi

printf 'PRE-DEPLOY %s: %d missing\n' "$MOD" "$missing"
[ "$missing" -eq 0 ] || exit 1

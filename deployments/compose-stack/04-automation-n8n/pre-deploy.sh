#!/usr/bin/env bash
# =====================================================================
# TigerAI Phase 04 — n8n pre-deploy (read-only)
# Path: deployments/compose-stack/04-automation-n8n/pre-deploy.sh
#
# Checks that the n8n encryption key and database password hold real values.
# Read-only: writes nothing and never calls docker.
# Exit codes: 0 all set / 1 something is missing
# Output: one `[MISSING] 04-automation-n8n/<name> — <reason>` per missing item,
#         followed by indented guidance; the last line is
#         `PRE-DEPLOY 04-automation-n8n: N missing`.
# =====================================================================

# shellcheck disable=SC2016  # the $(...) in the printed fix commands must stay literal
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # read by lib/common.sh's LOG/WARN/ERROR
TIGER_LOG_PREFIX="Phase-04"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
MOD="04-automation-n8n"
ENV_FILE="${TIGER_STACK_DIR}/.env"
# Same default as deploy.sh and the compose volume.
N8N_DIR="${N8N_DIR:-/home/wrt/TigerAI/node/n8n}"

missing=0
# Same defaults as deploy.sh; printed into the fix commands below.
db_ctr="${DB_POSTGRESDB_HOST:-postgres}"
db_user="${DB_POSTGRESDB_USER:-${PG_USER:-adm}}"
db_name="${DB_POSTGRESDB_DATABASE:-n8n}"
db_schema="${DB_POSTGRESDB_SCHEMA:-public}"

# --- Encryption key ----------------------------------------------------------
# Only the new name counts. compose still falls back to N8N_SECRET, but this is
# the one place that can insist .env be migrated. Unset or empty lands on the
# compose default, which here IS the placeholder CHANGE_ME — and n8n would
# encrypt every credential with it and start with no symptom.
if is_placeholder "${N8N_ENCRYPTION_KEY:-}"; then
    missing=$((missing + 1))
    printf '[MISSING] %s/N8N_ENCRYPTION_KEY — not set or still a placeholder; n8n would encrypt every credential with the literal CHANGE_ME, with no symptom\n' "$MOD"
    # Must never read as "just set some key": an operator still on the old name,
    # or with credentials already encrypted, would generate a fresh one and orphan them.
    printf '    # If .env still has N8N_SECRET, that is this key'"'"'s former name: rename it to N8N_ENCRYPTION_KEY,\n'
    printf '    #   keep the value EXACTLY as it is, and delete the old line:\n'
    printf '    #     -N8N_SECRET=<your current value>\n'
    printf '    #     +N8N_ENCRYPTION_KEY=<the same value, unchanged>\n'
    if [ -n "${N8N_SECRET:-}" ] && ! is_placeholder "$N8N_SECRET"; then
        printf '    #   (N8N_SECRET is set in your env files right now)\n'
    fi
    if [ -e "${N8N_DIR}/config" ]; then
        printf '    # n8n has already run on this host: reuse the encryptionKey in %s/config. Do NOT generate a new key —\n' "$N8N_DIR"
        printf '    #   n8n either refuses to start or every existing credential becomes undecryptable.\n'
        printf '    #   Put it into N8N_ENCRYPTION_KEY in %s (delete the line from %s/.env if it is there — it overrides the stack .env).\n' "$ENV_FILE" "$SCRIPT_DIR"
        printf '    sudo grep -o '"'"'"encryptionKey":[[:space:]]*"[^"]*"'"'"' "%s/config"\n' "$N8N_DIR"
        printf '    # If that key is the literal CHANGE_ME: n8n 2.x cannot change its key in place. Do not just edit .env — n8n then refuses to start\n'
        printf '    #   ("Deployment key '"'"'signing.hmac'"'"' cannot be read with this instance encryption key": the deployment_key table is encrypted with the old key).\n'
        printf '    #   The only path is a new, empty n8n database with a new key, importing credentials and workflows exported beforehand.\n'
        printf '    #   That is a lossy migration (users, executions, variables and more are not carried over) and has to be planned by hand.\n'
        printf '    #   Keep the --decrypted export (plaintext) outside %s, in a directory only root can read, and delete it afterwards:\n' "$N8N_DIR"
        printf '    #   %s is chmod 775, readable by n8n workflows, and packed by 08-backup.\n' "$N8N_DIR"
    else
        printf '    # No %s/config. A fresh key is safe ONLY if n8n has never run against this postgres. n8n records every start-up\n' "$N8N_DIR"
        printf '    #   schema migration in its migrations table (1.x and 2.x alike), even with no credentials. Check:\n'
        if [[ "$db_ctr$db_user$db_name" =~ ^[A-Za-z0-9_.-]+$ ]] && [[ "$db_schema" =~ ^[A-Za-z0-9_]+$ ]]; then
            printf '    sudo docker exec %s psql -U %s -d %s -tAc '"'"'SELECT count(*) FROM "%s".migrations;'"'"'\n' "$db_ctr" "$db_user" "$db_name" "$db_schema"
        else
            printf '    #   (the postgres container / user / database / schema name has unusual characters: run that check manually)\n'
        fi
        printf '    #   Only "database "%s" does not exist" or "relation "%s.migrations" does not exist" means never run.\n' "$db_name" "$db_schema"
        # 04 compose does not pass DB_TABLE_PREFIX to n8n, so the table name is unaffected.
        if [ -n "${DB_TABLE_PREFIX:-}" ]; then
            printf '    #   (DB_TABLE_PREFIX is set in your env files, but 04 compose does not pass it to n8n: the table is still migrations)\n'
        fi
        printf '    #   Any count (even 0) means it has run: recover the old key from a backup of the config file or an old .env.\n'
        printf '    #   If it cannot be found, the only path is a new, empty n8n database with a new key — a lossy migration\n'
        printf '    #   (credentials and workflows exported beforehand; users, executions, variables and more are not carried over).\n'
        printf '    #   Keep the --decrypted export (plaintext) outside %s, in a directory only root can read, and delete it afterwards:\n' "$N8N_DIR"
        printf '    #   %s is chmod 775, readable by n8n workflows, and packed by 08-backup.\n' "$N8N_DIR"
        printf '    # Never run (or a new, empty database): generate one (writes %s; delete the line from %s/.env if it is there). It must never change afterwards.\n' "$ENV_FILE" "$SCRIPT_DIR"
        printf '    if grep -q "^N8N_ENCRYPTION_KEY=" "%s"; then sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)|" "%s"; else { echo; echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)"; } >> "%s"; fi\n' \
            "$ENV_FILE" "$ENV_FILE" "$ENV_FILE"
    fi
fi

# --- Database password -------------------------------------------------------
# Same chain as deploy.sh: DB_POSTGRESDB_PASSWORD -> PG_PASS -> CHANGE_ME.
# Both empty therefore means CHANGE_ME, which is blocked. The message does not
# name which of the two was used: deploy.sh exports DB_POSTGRESDB_PASSWORD with
# that fallback already applied before calling this script.
if is_placeholder "${DB_POSTGRESDB_PASSWORD:-${PG_PASS:-}}"; then
    missing=$((missing + 1))
    printf '[MISSING] %s/DB_POSTGRESDB_PASSWORD — the effective value (DB_POSTGRESDB_PASSWORD, else PG_PASS) is not set or still a placeholder; n8n would log in to postgres with the literal CHANGE_ME\n' "$MOD"
    printf '    # DB_POSTGRESDB_PASSWORD falls back to PG_PASS: delete its line (or set it to the same value as PG_PASS)\n'
    printf '    sed -i '"'"'/^DB_POSTGRESDB_PASSWORD=/d'"'"' "%s"\n' "$ENV_FILE"
    printf '    # Then make sure PG_PASS is real (02-database pre-deploy prints how). A line in %s/.env overrides the stack .env — delete it there too.\n' "$SCRIPT_DIR"
fi

printf 'PRE-DEPLOY %s: %d missing\n' "$MOD" "$missing"
[ "$missing" -eq 0 ] || exit 1

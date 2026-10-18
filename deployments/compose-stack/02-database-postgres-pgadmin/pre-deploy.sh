#!/usr/bin/env bash
# =====================================================================
# TigerAI Phase 02 — Database pre-deploy (read-only)
# Path: deployments/compose-stack/02-database-postgres-pgadmin/pre-deploy.sh
#
# Checks that PG_PASS, PGADMIN_EMAIL and PGADMIN_PASS hold real values.
# Read-only: writes nothing and never calls docker.
# Exit codes: 0 all set / 1 something is missing
# Output: one `[MISSING] 02-database/<name> — <reason>` per missing item,
#         followed by indented, pasteable commands; the last line is
#         `PRE-DEPLOY 02-database: N missing`.
# =====================================================================

# shellcheck disable=SC2016  # the $(...) in the printed fix commands must stay literal
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # read by lib/common.sh's LOG/WARN/ERROR
TIGER_LOG_PREFIX="Phase-02"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
MOD="02-database"
ENV_FILE="${TIGER_STACK_DIR}/.env"

missing=0
# Printed into the fix commands below; same default as deploy.sh.
pg_user="${PG_USER:-adm}"
pg_ctr="${PG_CONTAINER:-postgres}"

# PG_PASS only takes effect when postgres runs initdb for the first time. On a
# host that already has pgdata, a new value no longer matches the database.
if is_placeholder "${PG_PASS:-}"; then
    missing=$((missing + 1))
    printf '[MISSING] %s/PG_PASS — not set or still a placeholder (an empty value makes compose fall back to the literal CHANGE_ME)\n' "$MOD"
    printf '    # Already deployed (a pgdata volume exists)? Do NOT generate a new value: postgres keeps the old one and every service using it fails to authenticate.\n'
    printf '    #   Put the password the database actually uses back into PG_PASS in %s.\n' "$ENV_FILE"
    printf '    # If the database really was initialised with the literal CHANGE_ME, putting that back is still blocked. Set a new value in .env\n'
    printf '    #   and in the database in one go, then redeploy every module that reads PG_PASS (03-ai-interface, 04-automation-n8n, 10-observability-grafana).\n'
    printf '    #   Check %s/.env for a PG_PASS line too: it overrides the stack .env for this module.\n' "$SCRIPT_DIR"
    # Only print a pasteable command when nothing in it can unbalance the quotes
    # or be expanded by the operator's shell.
    if [[ "$pg_user" =~ ^[A-Za-z0-9_]+$ ]] && [[ "$pg_ctr" =~ ^[A-Za-z0-9_.-]+$ ]] && [[ "$ENV_FILE" != *[\"\$\`\\]* ]]; then
        q="'"
        printf '    #   ALTER runs first and .env is written only if it succeeded; the SQL goes in on stdin, not argv. If ALTER fails nothing has\n'
        printf '    #   changed: find out why and re-run. If the .env write fails, the new value is still in $NEW in the same shell.\n'
        printf '    #   %s\n' "NEW=\$(openssl rand -hex 16) && printf ${q}ALTER USER \"$pg_user\" PASSWORD ${q}\"${q}\"${q}%s${q}\"${q}\"${q};\\n${q} \"\$NEW\" | sudo docker exec -i $pg_ctr psql -v ON_ERROR_STOP=1 -U $pg_user -d postgres && { grep -q \"^PG_PASS=\" \"$ENV_FILE\" && sed -i \"s|^PG_PASS=.*|PG_PASS=\$NEW|\" \"$ENV_FILE\" || { echo; echo \"PG_PASS=\$NEW\"; } >> \"$ENV_FILE\"; }"
    else
        printf '    #   PG_USER / PG_CONTAINER / the .env path has unusual characters: change the password manually (ALTER USER via psql, then the same value in .env).\n'
    fi
    printf '    # Fresh install only (no pgdata volume yet): generate a new value (writes %s; delete the line from %s/.env if it is there)\n' "$ENV_FILE" "$SCRIPT_DIR"
    printf '    if grep -q "^PG_PASS=" "%s"; then sed -i "s|^PG_PASS=.*|PG_PASS=$(openssl rand -hex 16)|" "%s"; else { echo; echo "PG_PASS=$(openssl rand -hex 16)"; } >> "%s"; fi\n' \
        "$ENV_FILE" "$ENV_FILE" "$ENV_FILE"
fi

# Not a secret, but pgAdmin uses it as the login account and needs a valid
# email. Nothing can generate one, so a person has to fill it in.
email="${PGADMIN_EMAIL:-}"
if is_placeholder "$email" || ! [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    missing=$((missing + 1))
    printf '[MISSING] %s/PGADMIN_EMAIL — not set, still a placeholder, or not a valid email (pgAdmin creates its login account from it)\n' "$MOD"
    printf '    # Already deployed: put back the email you log in to pgAdmin with; no need to change it (it only seeds the initial admin account)\n'
    printf '    # Fresh install: fill in the email you want to use (cannot be generated; delete the line from %s/.env if it is there)\n' "$SCRIPT_DIR"
    printf '    if grep -q "^PGADMIN_EMAIL=" "%s"; then sed -i "s|^PGADMIN_EMAIL=.*|PGADMIN_EMAIL=you@example.com|" "%s"; else { echo; echo "PGADMIN_EMAIL=you@example.com"; } >> "%s"; fi   # replace you@example.com first\n' \
        "$ENV_FILE" "$ENV_FILE" "$ENV_FILE"
fi

if is_placeholder "${PGADMIN_PASS:-}"; then
    missing=$((missing + 1))
    printf '[MISSING] %s/PGADMIN_PASS — not set or still a placeholder (an empty value makes compose fall back to the literal CHANGE_ME)\n' "$MOD"
    printf '    # It only seeds the initial admin account. Already deployed: put back your current login password, or any non-placeholder value, to pass; change an existing login inside pgAdmin\n'
    printf '    # Fresh install only: generate a new value (delete the line from %s/.env if it is there)\n' "$SCRIPT_DIR"
    printf '    if grep -q "^PGADMIN_PASS=" "%s"; then sed -i "s|^PGADMIN_PASS=.*|PGADMIN_PASS=$(openssl rand -hex 16)|" "%s"; else { echo; echo "PGADMIN_PASS=$(openssl rand -hex 16)"; } >> "%s"; fi\n' \
        "$ENV_FILE" "$ENV_FILE" "$ENV_FILE"
fi

printf 'PRE-DEPLOY %s: %d missing\n' "$MOD" "$missing"
[ "$missing" -eq 0 ] || exit 1

#!/usr/bin/env bash
# =====================================================================
# TigerAI n8n Deployer (queue mode: 1 main + N workers)
# Path: deployments/compose-stack/04-automation-n8n/deploy.sh
#
# Platform overlay: amd only, to keep its host.docker.internal defaults for
# the editor and webhook URLs — see docker-compose.amd.yaml.
#
# Merged from the three former per-platform deploy.sh scripts. The env
# loading, colors, logging and ensure_network boilerplate now lives in
# lib/common.sh. The three bodies were otherwise identical apart from where
# the N8N_URL auto-detection block sat in the file, which has no effect.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI n8n"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# --- Variable mapping for n8n compatibility ---
# Prefer explicit DB_POSTGRESDB_*, fall back to the generic PG_*, then a
# hard default.
export DB_POSTGRESDB_USER="${DB_POSTGRESDB_USER:-${PG_USER:-adm}}"
export DB_POSTGRESDB_PASSWORD="${DB_POSTGRESDB_PASSWORD:-${PG_PASS:-CHANGE_ME}}"
export DB_POSTGRESDB_DATABASE="${DB_POSTGRESDB_DATABASE:-n8n}"
export DB_POSTGRESDB_HOST="${DB_POSTGRESDB_HOST:-postgres}"
export DB_POSTGRESDB_SCHEMA="${DB_POSTGRESDB_SCHEMA:-public}"
export REDIS_HOST="${REDIS_HOST:-redis}"
export N8N_DIR="${N8N_DIR:-/home/wrt/TigerAI/node/n8n}"
export FILES_DIR="${FILES_DIR:-/home/wrt/TigerAI/node/n8n/files}"

usage() {
    echo "Usage: sudo $0 {all | main | worker | down | restart}"
    exit 1
}

# The encryption key, database password and (when the AI Assistant is enabled)
# AI Assistant key checks live in pre-deploy.sh (called below), so
# master-deploy.sh can report every module's missing values at once.

# --- AI Assistant master switch -> compose profiles ---
# sandbox (privileged DinD) and searxng (takes host port 30366) sit behind
# compose profiles and do not start by default; a host whose .env does not set
# the switch stays as it was, with no extra containers.
# Keep is_true identical to the copy in pre-deploy.sh, which gates the key check.
is_true() { case "${1:-}" in true|TRUE|True|1|yes|on) return 0 ;; *) return 1 ;; esac; }

# `if` on purpose rather than `is_true … && …`: when the condition is false the
# whole && list returns 1. set -e ignores that in the middle of a script, but
# once such a line becomes the last command of a function or branch, the 1
# becomes its return value and aborts the caller. `if` does not depend on where
# the line sits (same reasoning as master-deploy.sh's run_step).
AI_ENABLED="${N8N_AI_ASSISTANT_ENABLED:-false}"
# A typo (e.g. "tru") is treated as off, and with the switch off all / main /
# worker remove the sandbox containers — so say so instead of doing it silently.
# Warn only; pre-deploy.sh applies the same is_true and needs no change.
case "$AI_ENABLED" in
    false|FALSE|False|0|no|off) ;;
    *)
        if ! is_true "$AI_ENABLED"; then
            WARN "N8N_AI_ASSISTANT_ENABLED='${AI_ENABLED}' is not recognised; treating it as off (sandbox / searxng containers will be removed). Use true or false."
        fi
        ;;
esac
PROFILE_ARGS=()
if is_true "$AI_ENABLED"; then
    PROFILE_ARGS+=(--profile sandbox --profile searxng)
    # While searxng is not running this stays empty (web search not configured)
    # rather than pointing n8n-main at a host that does not exist.
    export N8N_INSTANCE_AI_SEARXNG_URL="${N8N_INSTANCE_AI_SEARXNG_URL:-http://searxng:8080}"
fi
# Upstream variable name, read by n8n-main itself. Always derived from the master
# switch and exported (the shell environment wins over --env-file).
N8N_INSTANCE_AI_SANDBOX_ENABLED="$(is_true "$AI_ENABLED" && echo true || echo false)"
export N8N_INSTANCE_AI_SANDBOX_ENABLED

# With the switch off, `up` without profiles leaves containers of profiled
# services alone, so a host switched from true back to false would keep sandbox /
# searxng running. Stop and remove them explicitly. With nothing to remove it
# prints "No stopped containers" and exits 0. Named volumes are kept (no -v), so
# switching back on reuses the runner's image cache. The profiles are passed so
# the named services are in scope whatever the compose version.
remove_ai_assistant_if_disabled() {
    if is_true "$AI_ENABLED"; then
        return 0
    fi
    LOG "N8N_AI_ASSISTANT_ENABLED is off: removing any AI Assistant containers (sandbox / searxng)..."
    tiger_compose --profile sandbox --profile searxng rm -sf sandbox-certs sandbox-api sandbox-runner-1 searxng
}

# --- Ensure the dedicated n8n database exists ---
ensure_db() {
    LOG "🔍 Ensuring dedicated PostgreSQL database '$DB_POSTGRESDB_DATABASE' for n8n..."
    local PG_CONTAINER="${DB_POSTGRESDB_HOST:-postgres}"
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container '$PG_CONTAINER' not found. Please deploy infrastructure first."
    fi
    # CREATE DATABASE has no IF NOT EXISTS and cannot run in a transaction —
    # guard with a SELECT so this stays idempotent.
    local DB_EXISTS
    DB_EXISTS=$(docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_POSTGRESDB_PASSWORD" \
        psql -U "$DB_POSTGRESDB_USER" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$DB_POSTGRESDB_DATABASE';" 2>/dev/null || true)
    if [ "$DB_EXISTS" = "1" ]; then
        LOG "✅ Database '$DB_POSTGRESDB_DATABASE' already exists — skipping creation."
    else
        LOG "Creating database '$DB_POSTGRESDB_DATABASE' (owner $DB_POSTGRESDB_USER)..."
        docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_POSTGRESDB_PASSWORD" \
            psql -U "$DB_POSTGRESDB_USER" -d postgres \
            -c "CREATE DATABASE $DB_POSTGRESDB_DATABASE OWNER $DB_POSTGRESDB_USER;" \
            || ERROR "Failed to create database '$DB_POSTGRESDB_DATABASE'."
        LOG "✅ Database '$DB_POSTGRESDB_DATABASE' created."
    fi
    # Schema 'public' already exists in every new database.
}

[ $# -eq 0 ] && usage

prep_files() {
    LOG "Configuring directories and permissions..."
    sudo mkdir -p "$N8N_DIR" "$FILES_DIR"
    sudo chown "${SUDO_USER:-wrt}":"${SUDO_USER:-wrt}" "$(dirname "$N8N_DIR")"
    sudo chown -R 1000:1000 "$N8N_DIR" "$FILES_DIR"
    sudo chmod -R 775 "$N8N_DIR" "$FILES_DIR"
}

# Auto-detect N8N_URL from the hostname when .env leaves it unset or empty.
if [ -z "${N8N_URL:-}" ]; then
    N8N_URL="http://$(hostname).local:${N8N_PORT:-5678}"
    LOG "N8N_URL not set, auto-detected: $N8N_URL"
fi
export N8N_URL

ACTION="$1"
# Only the actions that start containers are guarded. `down` is deliberately not:
# a host in this state must still be stoppable, and locking the operator out of
# shutting the service down would be worse than the problem. Checked before
# prep_files / ensure_network / ensure_db, so a rejected run has not yet created
# directories, a network, or touched the database.
case "$ACTION" in
    all|main|worker|restart) bash "${SCRIPT_DIR}/pre-deploy.sh" || exit $? ;;
esac
prep_files
ensure_network

case "$ACTION" in
    all)
        ensure_db
        # TIGER_N8N_WORKERS comes from tiger-tuning.env when the advisor has run.
        WORKER_COUNT="${TIGER_N8N_WORKERS:-${N8N_WORKERS:-2}}"
        LOG "Starting the n8n stack with $WORKER_COUNT workers..."
        remove_ai_assistant_if_disabled
        tiger_compose "${PROFILE_ARGS[@]}" up -d --scale "n8n-worker=$WORKER_COUNT"
        LOG "✅ n8n deployed: 1 main + $WORKER_COUNT workers"
        ;;
    main)
        ensure_db
        LOG "Starting n8n main only..."
        remove_ai_assistant_if_disabled
        tiger_compose up -d n8n-main
        ;;
    worker)
        ensure_db
        WORKER_COUNT="${TIGER_N8N_WORKERS:-${N8N_WORKERS:-2}}"
        LOG "Launching the n8n workflow engine (queue mode) with $WORKER_COUNT workers..."
        remove_ai_assistant_if_disabled
        tiger_compose "${PROFILE_ARGS[@]}" up -d --scale "n8n-worker=$WORKER_COUNT"
        ;;
    down)
        LOG "Stopping n8n services..."
        # --profile '*': a down without profiles leaves the containers of
        # profiled services running (sandbox / searxng), and --remove-orphans does
        # not catch them either.
        tiger_compose --profile '*' down
        ;;
    restart)
        LOG "Restarting n8n..."
        # Full redeploy on purpose: `docker compose restart` does not re-apply
        # env or compose changes and does not respect --scale, so it cannot
        # reliably restore the multi-worker queue setup.
        # down stops everything (including a profile that was just switched off);
        # the `all` run brings up only the profiles currently enabled.
        tiger_compose --profile '*' down && bash "$0" all
        ;;
    *)
        usage
        ;;
esac

LOG "n8n deployment command finished."

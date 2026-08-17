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

# --- Guard: the encryption key must not still be the install placeholder ------
# CHANGE_ME is non-empty, so ${VAR:-fallback} never catches it.
check_encryption_key() {
    # Only the new name is accepted, so .env must be migrated; the compose file
    # still falls back to N8N_SECRET, but this is the one place that can insist.
    # Unset lands on the same default compose uses, which here IS the placeholder.
    local val="${N8N_ENCRYPTION_KEY:-CHANGE_ME}"

    [ "$val" != "CHANGE_ME" ] && return 0

    # Must never read as "just set some key": an operator still on the old name, or
    # with credentials already encrypted, would generate a fresh one and orphan them.
    ERROR "$(printf '%s\n' \
        "N8N_ENCRYPTION_KEY is not set, or is still the .env.example placeholder" \
        "CHANGE_ME. Deploying that way makes n8n encrypt every credential with the" \
        "literal string \"CHANGE_ME\", and the container starts normally with no symptom." \
        "" \
        "If .env still has N8N_SECRET, that is this key's former name: rename it to" \
        "N8N_ENCRYPTION_KEY, keep the value EXACTLY as it is, and delete the old line." \
        "" \
        "    -N8N_SECRET=<your current value>" \
        "    +N8N_ENCRYPTION_KEY=<the same value, unchanged>" \
        "" \
        "If n8n on this host has already run with a real key, that key is the" \
        "encryptionKey field in ${N8N_DIR}/config — reuse THAT one. Do not generate a" \
        "new key: a new one either stops n8n from starting, or leaves every existing" \
        "credential permanently undecryptable." \
        "" \
        "Only on a host where n8n has never started is a fresh key safe:" \
        "    openssl rand -hex 32")"
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
case "$ACTION" in all|main|worker|restart) check_encryption_key ;; esac
prep_files
ensure_network

case "$ACTION" in
    all)
        ensure_db
        # TIGER_N8N_WORKERS comes from tiger-tuning.env when the advisor has run.
        WORKER_COUNT="${TIGER_N8N_WORKERS:-${N8N_WORKERS:-2}}"
        LOG "Starting the n8n stack with $WORKER_COUNT workers..."
        tiger_compose up -d --scale "n8n-worker=$WORKER_COUNT"
        LOG "✅ n8n deployed: 1 main + $WORKER_COUNT workers"
        ;;
    main)
        ensure_db
        LOG "Starting n8n main only..."
        tiger_compose up -d n8n-main
        ;;
    worker)
        ensure_db
        WORKER_COUNT="${TIGER_N8N_WORKERS:-${N8N_WORKERS:-2}}"
        LOG "Launching the n8n workflow engine (queue mode) with $WORKER_COUNT workers..."
        tiger_compose up -d --scale "n8n-worker=$WORKER_COUNT"
        ;;
    down)
        LOG "Stopping n8n services..."
        tiger_compose down
        ;;
    restart)
        LOG "Restarting n8n..."
        # Full redeploy on purpose: `docker compose restart` does not re-apply
        # env or compose changes and does not respect --scale, so it cannot
        # reliably restore the multi-worker queue setup.
        tiger_compose down && bash "$0" all
        ;;
    *)
        usage
        ;;
esac

LOG "n8n deployment command finished."

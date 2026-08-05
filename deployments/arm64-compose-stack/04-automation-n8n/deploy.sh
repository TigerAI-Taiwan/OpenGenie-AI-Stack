#!/usr/bin/env bash
# =====================================================================
# TigerAI n8n Deployer
# Path: deployments/arm64-compose-stack/04-automation-n8n/deploy.sh
# =====================================================================

set -eo pipefail

# --- 0) Configuration & Variables ---
# Import order: local .env -> parent stack .env -> tiger-tuning.env (hardware optimized, highest priority)
if [ -f .env ]; then
  export $(grep -v '^#' .env | sed 's/\r//g' | xargs)
fi
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | sed 's/\r//g' | xargs)
fi
if [ -f ../tiger-tuning.env ]; then
  export $(grep -v '^#' ../tiger-tuning.env | sed 's/\r//g' | xargs)
fi

# --- Variable Mapping for n8n Compatibility ---
# Prefer explicit DB_POSTGRESDB_* ; fall back to generic PG_* ; finally hard default.
export DB_POSTGRESDB_USER="${DB_POSTGRESDB_USER:-${PG_USER:-adm}}"
export DB_POSTGRESDB_PASSWORD="${DB_POSTGRESDB_PASSWORD:-${PG_PASS:-CHANGE_ME}}"
export DB_POSTGRESDB_DATABASE="${DB_POSTGRESDB_DATABASE:-n8n}"
export DB_POSTGRESDB_HOST="${DB_POSTGRESDB_HOST:-postgres}"
export DB_POSTGRESDB_SCHEMA="${DB_POSTGRESDB_SCHEMA:-public}"
export REDIS_HOST="${REDIS_HOST:-redis}"
export N8N_DIR="${N8N_DIR:-/home/wrt/TigerAI/node/n8n}"
export FILES_DIR="${FILES_DIR:-/home/wrt/TigerAI/node/n8n/files}"

# Robust Variable Cleansing (Against Windows CRLF)
for var in $(env | grep -E 'PORT|IMAGE|URL|PATH|USER|PASS|DB|SECRET|TZ' | cut -d= -f1); do
  export "$var"="$(echo "${!var}" | tr -d '\r')"
done

LOG_PREFIX="TigerAI n8n"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

usage() {
    echo "Usage: sudo $0 {all | main | worker | down | restart}"
    exit 1
}

# --- 1) Ensure dedicated n8n database exists ---
ensure_db() {
    LOG "🔍 Ensuring dedicated PostgreSQL database '$DB_POSTGRESDB_DATABASE' for n8n..."
    local PG_CONTAINER=${DB_POSTGRESDB_HOST:-postgres}
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container '$PG_CONTAINER' not found. Please deploy infrastructure first."
    fi
    # CREATE DATABASE has no IF NOT EXISTS and cannot run in a transaction — SELECT-guard (idempotent).
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
    # Schema 'public' already exists in every new database — no schema creation needed.
}

# --- 2) Logic ---
[ $# -eq 0 ] && usage

# Auto-detect N8N_URL from hostname if not set in .env
if [ -z "$N8N_URL" ]; then
    N8N_URL="http://$(hostname).local:${N8N_PORT:-5678}"
    LOG "N8N_URL not set, auto-detected: $N8N_URL"
fi
export N8N_URL

prep_files() {
    LOG " Configuring Directories and Permissions..."
    sudo mkdir -p "$N8N_DIR" "$FILES_DIR"
    sudo chown "${SUDO_USER:-wrt}":"${SUDO_USER:-wrt}" "$(dirname "$N8N_DIR")"
    sudo chown -R 1000:1000 "$N8N_DIR" "$FILES_DIR"
    sudo chmod -R 775 "$N8N_DIR" "$FILES_DIR"
}

ensure_network() {
    docker network inspect ai_stack_net >/dev/null 2>&1 || docker network create ai_stack_net
}

ACTION=$1
prep_files
ensure_network

case "$ACTION" in
    all)
        ensure_db
        # Use TIGER_N8N_WORKERS if available (from tiger-tuning.env), otherwise N8N_WORKERS
        WORKER_COUNT=${TIGER_N8N_WORKERS:-${N8N_WORKERS:-2}}
        LOG " Starting n8n Full Stack with $WORKER_COUNT workers..."
        docker compose up -d --scale n8n-worker=$WORKER_COUNT
        LOG "✅ n8n deployed: 1 main + $WORKER_COUNT workers"
        ;;
    main)
        ensure_db
        LOG " Starting n8n Main only..."
        docker compose up -d n8n-main
        ;;
    worker)
        ensure_db
        WORKER_COUNT=${TIGER_N8N_WORKERS:-${N8N_WORKERS:-2}}
        LOG " Launching n8n Workflow Engine (Queue Mode) with $WORKER_COUNT workers..."
        docker compose up -d --scale n8n-worker=$WORKER_COUNT
        ;;
    down)
        LOG " Stopping n8n services..."
        docker compose down
        ;;
    restart)
        LOG " Restarting n8n..."
        docker compose down && bash "$0" all
        ;;
    *)
        usage
        ;;
esac

LOG " n8n Deployment command finished."

#!/usr/bin/env bash
# =====================================================================
# TigerAI AI Interface Deployer (ARM64 Optimized)
# Path: deployments/arm64-compose-stack/03-ai-interface-ollama-openwebui-redis/deploy.sh
# =====================================================================

set -eo pipefail

# --- 0) Configuration & Variables ---
# Import from local .env first
if [ -f .env ]; then
  export $(grep -v '^#' .env | sed 's/\r//g' | xargs)
fi

# Then import from tiger-tuning.env (hardware optimized)
if [ -f ../tiger-tuning.env ]; then
  export $(grep -v '^#' ../tiger-tuning.env | sed 's/\r//g' | xargs)
fi

# Finally import from parent stack .env (if exists)
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | sed 's/\r//g' | xargs)
fi

# Robust Variable Cleansing (Against Windows CRLF)
for var in $(env | grep -E 'PORT|IMAGE|URL|PATH|USER|PASS|DB|SECRET|TZ' | cut -d= -f1); do
  export "$var"="$(echo "${!var}" | tr -d '\r')"
done

LOG_PREFIX="TigerAI Interface"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

usage() {
    echo "Usage: sudo $0 {all | redis | ollama | openwebui | down | restart}"
    exit 1
}

# --- Ensure the dedicated `openwebui` database exists (DB isolation) ---
ensure_db() {
    LOG "🔍 Verifying PostgreSQL connection and OpenWebUI database..."
    local PG_CONTAINER="${PG_HOST:-postgres}"
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container '$PG_CONTAINER' not found. Please deploy 02-database first."
    fi
    local DB_USER="${PG_USER:-adm}"
    local DB_NAME="${OWUI_DB_NAME:-openwebui}"
    local DB_EXISTS
    DB_EXISTS=$(docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="${PG_PASS:-CHANGE_ME}" \
        psql -U "$DB_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';")
    if [ "$DB_EXISTS" = "1" ]; then
        LOG "✅ Database '$DB_NAME' already exists."
    else
        LOG "⚠️  Database '$DB_NAME' does not exist. Creating it now..."
        docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="${PG_PASS:-CHANGE_ME}" \
            psql -U "$DB_USER" -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" \
            || ERROR "Failed to create database '$DB_NAME'."
        LOG "✅ Database '$DB_NAME' created successfully."
    fi
}

# --- 2) Logic ---
[ $# -eq 0 ] && usage

ensure_network() {
    docker network inspect ai_stack_net >/dev/null 2>&1 || docker network create ai_stack_net
}

ACTION=$1
ensure_network

case "$ACTION" in
    all)
        ensure_db
        # Use TIGER_OWUI_WORKERS if available, otherwise use OWUI_WORKERS
        WORKER_COUNT=${TIGER_OWUI_WORKERS:-${OWUI_WORKERS:-2}}
        LOG " Starting AI Stack (Redis, Ollama, OpenWebUI: 1 main + $WORKER_COUNT workers)..."
        docker compose up -d --scale openwebui-worker=$WORKER_COUNT
        LOG "✅ AI Interface deployed: Redis + Ollama + OpenWebUI (1 main + $WORKER_COUNT workers)"
        ;;
    redis|ollama)
        LOG " Starting specific service: $ACTION..."
        docker compose up -d "$ACTION"
        ;;
    openwebui)
        ensure_db
        LOG " Starting OpenWebUI..."
        docker compose up -d openwebui-main
        ;;
    down)
        LOG " Stopping AI Interface services..."
        docker compose down
        ;;
    restart)
        LOG " Restarting AI Stack..."
        # docker compose down && bash $0 all
        docker compose restart 
        ;;
    *)
        usage
        ;;
esac

LOG " Interface Deployment command finished."

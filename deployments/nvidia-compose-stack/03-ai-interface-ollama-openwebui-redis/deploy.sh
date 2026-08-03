#!/usr/bin/env bash
# =====================================================================
# TigerAI AI Interface Deployer
# Path: deployments/amd-compose-stack/03-ai-interface-ollama-openwebui-redis/deploy.sh
# =====================================================================

set -eo pipefail

# --- 0) Configuration & Variables ---
# Import from local .env first
if [ -f .env ]; then
  export $(grep -v '^#' .env | sed 's/\r//g' | xargs)
fi

# Then import from tuning if exists
if [ -f ../tiger-tuning.env ]; then
  export $(grep -v '^#' ../tiger-tuning.env | sed 's/\r//g' | xargs)
fi

# Finally import from parent stack .env (if exists)
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | sed 's/\r//g' | xargs)
fi

# And global root .env (highest priority overrides)
if [ -f ../../.env ]; then
  export $(grep -v '^#' ../../.env | sed 's/\r//g' | xargs)
fi

# Robust Variable Cleansing (Against Windows CRLF)
for var in $(env | grep -E 'PORT|IMAGE|URL|PATH|USER|PASS|DB|SECRET|TZ|LANG' | cut -d= -f1); do
  export "$var"="$(echo "${!var}" | tr -d '\r')"
done

LOG_PREFIX="TigerAI Interface"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

usage() {
    echo "Usage: sudo $0 {all | redis | ollama | openwebui}"
    exit 1
}

[ $# -eq 0 ] && usage

ensure_network() {
    docker network inspect ai_stack_net >/dev/null 2>&1 || docker network create ai_stack_net
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

ACTION=$1
ensure_network

case "$ACTION" in
    all)
        ensure_db
        LOG " [Phase 1] Starting Infrastructure (Redis & Ollama)..."
        docker compose up -d redis ollama
        
        LOG " ⏳ Waiting for Redis to become healthy..."
        # Wait up to 30 seconds for Redis
        MAX_RETRIES=30
        COUNT=0
        while [ $COUNT -lt $MAX_RETRIES ]; do
            HEALTH=$(docker inspect --format='{{.State.Health.Status}}' redis 2>/dev/null || echo "unknown")
            if [ "$HEALTH" == "healthy" ]; then
                LOG " ✅ Redis is Healthy."
                break
            fi
            sleep 1
            echo -n "."
            COUNT=$((COUNT+1))
        done
        
        if [ $COUNT -eq $MAX_RETRIES ]; then
            LOG " ⚠️ Redis health check timed out. Proceeding anyway..."
        fi
        echo ""

        LOG " [Phase 2] Starting OpenWebUI Cluster (Main + 2 Workers)..."
        docker compose up -d openwebui-main openwebui-worker-01 openwebui-worker-02
        ;;
    redis|ollama)
        LOG " Starting specific service: $ACTION..."
        docker compose up -d "$ACTION"
        ;;
    openwebui)
        ensure_db
        LOG " Starting OpenWebUI Cluster..."
        docker compose up -d openwebui-main openwebui-worker-01 openwebui-worker-02
        ;;
    *)
        usage
        ;;
esac

LOG " Interface Deployment command finished."

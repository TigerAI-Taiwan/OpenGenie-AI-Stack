#!/usr/bin/env bash
# =====================================================================
# TigerAI Database Deployer
# Path: deployments/amd-compose-stack/02-database-postgres-pgadmin/deploy.sh
# =====================================================================

set -eo pipefail

# --- 0) Configuration & Variables ---
# Import from local .env first (with CRLF handling)
if [ -f .env ]; then
  export $(grep -v '^#' .env | sed 's/\r//g' | xargs)
fi

# Then import from parent stack .env (overrides local, with CRLF handling)
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | sed 's/\r//g' | xargs)
fi

LOG_PREFIX="TigerAI Database"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

usage() {
    echo "Usage: sudo $0 {all | postgres | pgadmin}"
    exit 1
}

# --- 1) Logic ---
[ $# -eq 0 ] && usage

# Fallback defaults (used when .env is not present or incomplete)
PG_USER=${PG_USER:-adm}
PG_DB_NAME=${PG_DB_NAME:-tigerai}
PG_DB=${PG_DB:-$PG_DB_NAME}

ensure_network() {
    docker network inspect ai_stack_net >/dev/null 2>&1 || \
    (LOG "Creating Docker network: ai_stack_net" && docker network create ai_stack_net)
}

wait_for_db() {
    LOG " Waiting for Postgres to be ready..."
    local count=0
    until docker exec postgres pg_isready -U "$PG_USER" >/dev/null 2>&1; do
      sleep 2
      count=$((count + 1))
      [ $count -gt 30 ] && ERROR "Postgres failed to start."
    done
}

ACTION=$1
ensure_network

case "$ACTION" in
    all)
        LOG " Starting Database Stack (Postgres, pgAdmin)..."
        docker compose up -d
        wait_for_db
        LOG "✅ Database bootstrap completed."
        ;;
    postgres|pgadmin)
        LOG " Starting specific service: $ACTION..."
        docker compose up -d "$ACTION"
        [ "$ACTION" == "postgres" ] && wait_for_db
        ;;
    down)
        LOG " Stopping database services..."
        docker compose down
        ;;
    restart)
        LOG " Restarting database stack..."
        docker compose down && $0 all
        ;;
    *)
        usage
        ;;
esac

LOG " Database Deployment command finished."

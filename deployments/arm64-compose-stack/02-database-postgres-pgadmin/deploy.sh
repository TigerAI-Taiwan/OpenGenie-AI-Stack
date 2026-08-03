#!/usr/bin/env bash
# =====================================================================
# TigerAI Database Deployer (ARM64 Optimized)
# Path: deployments/arm64-compose-stack/02-database-postgres-pgadmin/deploy.sh
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

# Finally import from parent stack .env (overrides local)
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | sed 's/\r//g' | xargs)
fi

# Robust Variable Cleansing (Against Windows CRLF)
for var in $(env | grep -E 'PORT|IMAGE|URL|PATH|USER|PASS|DB|SECRET|TZ|LANG' | cut -d= -f1); do
  export "$var"="$(echo "${!var}" | tr -d '\r')"
done

LOG_PREFIX="TigerAI Database"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

usage() {
    echo "Usage: sudo $0 {all | postgres | pgadmin | down | restart}"
    exit 1
}

# --- 1) Logic ---
[ $# -eq 0 ] && usage

# Fallback defaults (used when .env is not present or incomplete)
PG_USER=${PG_USER:-adm}
PG_DB_NAME=${PG_DB_NAME:-tigerai}

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
      if [ $count -gt 30 ]; then
        ERROR "Postgres failed to start."
      fi
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
        # docker compose down && bash $0 all
        docker compose restart 
        ;;
    *)
        usage
        ;;
esac

LOG " Database Deployment command finished."

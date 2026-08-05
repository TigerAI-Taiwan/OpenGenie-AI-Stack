#!/usr/bin/env bash
# =====================================================================
# TigerAI NVIDIA Observability Deployer
# Path: deployments/nvidia-compose-stack/10-observability-grafana/deploy.sh
# =====================================================================

set -eo pipefail

# Load env: tiger-tuning (global defaults) → ../.env (parent) → .env (local, highest priority)
# Import tiger-tuning.env first (lowest priority - hardware defaults)
if [ -f ../tiger-tuning.env ]; then
  export $(grep -v '^#' ../tiger-tuning.env | sed 's/\r//g' | xargs)
fi
# Then parent stack .env (overrides tiger-tuning)
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | sed 's/\r//g' | xargs)
fi
# Finally local .env (highest priority - overrides all)
if [ -f .env ]; then
  export $(grep -v '^#' .env | sed 's/\r//g' | xargs)
fi

LOG_PREFIX="TigerAI Observability"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

cd "$(dirname "$0")"

# --- Ensure dedicated 'grafana' database exists (Grafana uses PG as backend) ---
# Mirrors k3s (GF_DATABASE_TYPE=postgres). CREATE DATABASE has no IF NOT EXISTS
# and cannot run inside a transaction, so SELECT-guard it (idempotent).
ensure_db() {
    local PG_CONTAINER="${PG_CONTAINER:-postgres}"
    local DB_USER="${PG_USER:-adm}"
    local DB_PASS="${PG_PASS:-CHANGE_ME}"
    local DB_NAME="${GF_DB_NAME:-grafana}"

    LOG " Ensuring dedicated PostgreSQL database '$DB_NAME' for Grafana..."
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container '$PG_CONTAINER' not found. Please deploy the database stack first."
    fi

    local DB_EXISTS
    DB_EXISTS=$(docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_PASS" \
        psql -U "$DB_USER" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';" 2>/dev/null || true)

    if [ "$DB_EXISTS" = "1" ]; then
        LOG " Database '$DB_NAME' already exists — skipping creation."
    else
        LOG " Creating database '$DB_NAME' (owner $DB_USER)..."
        docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_PASS" \
            psql -U "$DB_USER" -d postgres \
            -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" \
            || ERROR "Failed to create database '$DB_NAME'."
        LOG " Database '$DB_NAME' created."
    fi
}

LOG " Launching NVIDIA Observability Stack (Grafana/Prometheus/DCGM)..."
ensure_db
docker compose up -d

LOG " Observability stack is up. Access Grafana at http://localhost:3000 (User: admin / Pass: CHANGE_ME)"

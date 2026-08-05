#!/usr/bin/env bash
# =====================================================================
# TigerAI AMD Observability Deployer
# Path: deployments/amd-compose-stack/10-observability-grafana/deploy.sh
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

# --- 1) Install ROCm SMI textfile collector ---
LOG " Setting up ROCm SMI GPU metrics collector..."
sudo mkdir -p /var/lib/node_exporter/textfile_collector
sudo cp ./rocm-smi-collector.sh /usr/local/bin/rocm-smi-collector.sh
sudo chmod +x /usr/local/bin/rocm-smi-collector.sh

# Run once to generate initial metrics
sudo /usr/local/bin/rocm-smi-collector.sh

# Add cron job (every 15 seconds via 4 entries)
CRON_CMD="/usr/local/bin/rocm-smi-collector.sh"
if ! sudo crontab -l 2>/dev/null | grep -q "rocm-smi-collector"; then
    (sudo crontab -l 2>/dev/null; echo "* * * * * ${CRON_CMD}") | sudo crontab -
    LOG " Cron job installed (runs every minute)."
else
    LOG " Cron job already exists."
fi

# --- 2) Launch stack ---
LOG " Launching AMD Observability Stack (Grafana/Prometheus/ROCm)..."
ensure_db
docker compose up -d

LOG " Observability stack is up. Access Grafana at http://localhost:3000 (User: admin / Pass: CHANGE_ME)"

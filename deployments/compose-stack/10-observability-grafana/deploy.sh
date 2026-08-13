#!/usr/bin/env bash
# =====================================================================
# TigerAI Observability Deployer (Grafana / Prometheus / Loki / cAdvisor)
# Path: deployments/compose-stack/10-observability-grafana/deploy.sh
#
# All three platforms carry an overlay — see docker-compose.base.yaml. The
# gpu-exporter service is defined entirely per platform (DCGM on nvidia and
# arm64, ROCm's device-metrics-exporter on amd).
#
# Merged from the three pre-merge deploy.sh scripts. Beyond the env loading
# and logging boilerplate that lib/common.sh now owns, the only real
# difference was an amd-only ROCm textfile collector, which was removed rather
# than merged — see the note above ensure_network below.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Observability"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# Grafana keeps its internal state in PostgreSQL, mirroring the k3s setup
# (GF_DATABASE_TYPE=postgres). CREATE DATABASE has no IF NOT EXISTS and cannot
# run inside a transaction, so guard it with a SELECT to stay idempotent.
ensure_db() {
    local PG_CONTAINER="${PG_CONTAINER:-postgres}"
    local DB_USER="${PG_USER:-adm}"
    local DB_PASS="${PG_PASS:-CHANGE_ME}"
    local DB_NAME="${GF_DB_NAME:-grafana}"

    LOG "Ensuring the dedicated PostgreSQL database '$DB_NAME' for Grafana..."
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container '$PG_CONTAINER' not found. Please deploy the database stack first."
    fi

    local DB_EXISTS
    DB_EXISTS=$(docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_PASS" \
        psql -U "$DB_USER" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';" 2>/dev/null || true)

    if [ "$DB_EXISTS" = "1" ]; then
        LOG "Database '$DB_NAME' already exists — skipping creation."
    else
        LOG "Creating database '$DB_NAME' (owner $DB_USER)..."
        docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_PASS" \
            psql -U "$DB_USER" -d postgres \
            -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" \
            || ERROR "Failed to create database '$DB_NAME'."
        LOG "Database '$DB_NAME' created."
    fi
}

# GPU metrics come from the platform's official exporter container, scraped by
# the 'gpu-metrics' Prometheus job:
#   amd            rocm/device-metrics-exporter on :5000
#   nvidia, arm64  dcgm-exporter on :9400
# No host-side collector, cron job or node-exporter textfile plumbing is
# involved. The amd stack used to install a rocm-smi-collector.sh cron job that
# shelled out to rocm-smi on the HOST — where it is not installed, because ROCm
# runs inside containers via /dev/kfd + /dev/dri. Every reading came back
# empty and it published a well-formed set of zeros once a minute, which reads
# as an idle GPU rather than a broken collector.

ensure_network

LOG "Launching the observability stack (Grafana / Prometheus / Loki / cAdvisor)..."
ensure_db
tiger_compose up -d

LOG "Observability stack is up. Grafana: http://localhost:${GRAFANA_PORT:-3000}"

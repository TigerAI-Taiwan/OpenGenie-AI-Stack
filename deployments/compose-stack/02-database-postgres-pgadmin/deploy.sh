#!/usr/bin/env bash
# =====================================================================
# TigerAI Database Deployer (PostgreSQL, pgAdmin)
# Path: deployments/compose-stack/02-database-postgres-pgadmin/deploy.sh
#
# Platform overlay: amd only, and only to select the image variable name
# (PG_IMAGE vs POSTGRES_IMAGE) — see docker-compose.amd.yaml.
#
# Merged from the three former per-platform deploy.sh scripts. The env
# loading, colors, logging and ensure_network boilerplate now lives in
# lib/common.sh. Beyond that:
#   - `down` / `restart` were missing in amd  -> kept
#   - amd's `restart` did `down && $0 all`, nvidia / arm64 used
#     `docker compose restart` -> the latter, which preserves the volumes and
#     does not re-run the bootstrap wait on every restart
#   - amd aliased PG_DB=${PG_DB:-$PG_DB_NAME} -> kept, so an amd .env that
#     sets PG_DB continues to work
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Database"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    echo "Usage: sudo $0 {all | postgres | pgadmin | down | restart}"
    exit 1
}

[ $# -eq 0 ] && usage

# Fallback defaults, used when .env is absent or incomplete.
PG_USER="${PG_USER:-adm}"
PG_DB_NAME="${PG_DB_NAME:-tigerai}"
# Compatibility alias carried over from the amd stack.
PG_DB="${PG_DB:-$PG_DB_NAME}"
export PG_USER PG_DB_NAME PG_DB

wait_for_db() {
    LOG "Waiting for Postgres to be ready..."
    local count=0
    until docker exec postgres pg_isready -U "$PG_USER" >/dev/null 2>&1; do
        sleep 2
        count=$((count + 1))
        if [ "$count" -gt 30 ]; then
            ERROR "Postgres failed to start."
        fi
    done
}

ACTION="$1"
ensure_network

case "$ACTION" in
    all)
        LOG "Starting database stack (Postgres, pgAdmin)..."
        tiger_compose up -d
        wait_for_db
        LOG "✅ Database bootstrap completed."
        ;;
    postgres|pgadmin)
        LOG "Starting specific service: $ACTION..."
        tiger_compose up -d "$ACTION"
        [ "$ACTION" = "postgres" ] && wait_for_db
        ;;
    down)
        LOG "Stopping database services..."
        tiger_compose down
        ;;
    restart)
        LOG "Restarting database stack..."
        tiger_compose restart
        ;;
    *)
        usage
        ;;
esac

#!/usr/bin/env bash
# =====================================================================
# TigerAI AI Interface Deployer (OpenWebUI)
# Path: deployments/compose-stack/04-ai-interface-openwebui/deploy.sh
#
# The platform overlays are empty placeholders today. The model connection is
# layered per INFERENCE_BACKEND (docker-compose.backend-<backend>.yaml); redis
# lives in 02-database.
#
# TOPOLOGY CHANGE: there are no more openwebui-worker containers. OpenWebUI is
# one openwebui-main running `uvicorn --workers N`, gated behind a one-shot
# openwebui-migrate. `--scale` no longer applies to this module; worker count
# is OWUI_UVICORN_WORKERS. See the base compose file for why.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI AI-Interface"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# tiger-tuning.env may set TIGER_OWUI_UVICORN_WORKERS; OWUI_UVICORN_WORKERS is
# the .env-level override. Whichever wins is what the compose file reads as
# openwebui-main's UVICORN_WORKERS.
export OWUI_UVICORN_WORKERS="${TIGER_OWUI_UVICORN_WORKERS:-${OWUI_UVICORN_WORKERS:-2}}"

usage() {
    echo "Usage: sudo $0 {all | openwebui | down | restart}"
    exit 1
}

[ $# -eq 0 ] && usage

ensure_db() {
    LOG "🔍 Verifying the PostgreSQL connection and the OpenWebUI database..."
    local PG_CONTAINER="${PG_HOST:-postgres}"
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container '$PG_CONTAINER' not found. Please deploy 02-database first."
    fi
    local DB_USER="${PG_USER:-adm}"
    local DB_NAME="${OWUI_DB_NAME:-openwebui}"
    local DB_EXISTS
    DB_EXISTS=$(docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="${PG_PASS:-CHANGE_ME}" \
        psql -U "$DB_USER" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';" 2>/dev/null || true)
    if [ "$DB_EXISTS" = "1" ]; then
        LOG "✅ Database '$DB_NAME' already exists."
    else
        LOG "⚠️  Database '$DB_NAME' does not exist. Creating it now..."
        docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="${PG_PASS:-CHANGE_ME}" \
            psql -U "$DB_USER" -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" \
            || ERROR "Failed to create database '$DB_NAME'."
        LOG "✅ Database '$DB_NAME' created."
    fi
}

# --- Guard: QDRANT_API_KEY must not be empty or the install placeholder ---
# Qdrant 6333 is reachable on the LAN and its API key is the only control.
# Without the key (or with the wrong one) OpenWebUI gets 401, and silently: the
# container is Running, /health returns 200, chat works, only RAG is dead.
# It must be the ADMIN key, not the read-only one: OpenWebUI does
# create_collection / upsert / delete_collection.
# 06-rag-stack's pre-deploy.sh is the primary check; this is defence in depth for
# running 04 on its own. Deploy paths only (all / openwebui / restart): down does
# not touch OpenWebUI, and blocking it would only leave a host that cannot be
# stopped.
check_qdrant_api_key() {
    if is_placeholder "${QDRANT_API_KEY:-}"; then
        ERROR "$(printf '%s\n' \
            "QDRANT_API_KEY is not set or still the install placeholder." \
            "Without the key Qdrant rejects OpenWebUI with 401, yet the container stays Running," \
            "/health returns 200 and chat works — only RAG silently dies." \
            "" \
            "Set it in ${TIGER_STACK_DIR}/.env to the same admin key 06-rag-stack uses" \
            "(QDRANT__SERVICE__API_KEY), not the read-only key — the read-only key gets 403 on writes." \
            "" \
            "Also: 06-rag-stack needs QDRANT_READ_ONLY_API_KEY as well (04 does not use it)." \
            "Set it now too, so the 06 deploy is not blocked a second time.")"
    fi
}

# redis lives in 02-database: cross-project depends_on is impossible, so wait for it here.
wait_for_redis() {
    local waited=0 status
    docker ps -a --format '{{.Names}}' | grep -qx redis \
        || ERROR "No redis container - deploy 02-database first: sudo -E bash ${TIGER_STACK_DIR}/02-database-postgres-pgadmin/deploy.sh all"
    until status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' redis 2>/dev/null) && [ "$status" = "healthy" ]; do
        [ "$waited" -ge 60 ] && ERROR "redis not healthy within 60s (now: ${status:-unknown}) - docker logs redis --tail 50"
        sleep 2
        waited=$((waited + 2))
    done
    LOG "✅ redis is healthy."
}

ACTION="$1"
# Only actions that start containers are checked; `down` is not, so a host in
# this state can still be stopped. restart is down + up, so it is checked too.
case "$ACTION" in
    all|openwebui|restart)
        bash "${SCRIPT_DIR}/pre-deploy.sh" || exit $?
        # Before ensure_network, like pre-deploy.sh: a rejected run has not yet
        # created the network.
        check_qdrant_api_key
        ;;
esac

# Stop actions ignore the backend: down only needs the project name.
_BACKEND_OVERLAY=()
case "$ACTION" in
    all|openwebui|restart)
        tiger_inference_backend_resolve
        _BACKEND_OVERLAY=(-f "${SCRIPT_DIR}/docker-compose.backend-${TIGER_INFERENCE_BACKEND}.yaml")
        LOG "INFERENCE_BACKEND=${TIGER_INFERENCE_BACKEND}"
        ;;
esac
ensure_network

case "$ACTION" in
    all)
        ensure_db
        wait_for_redis
        LOG "Starting the AI interface (OpenWebUI: $OWUI_UVICORN_WORKERS uvicorn workers)..."
        tiger_compose "${_BACKEND_OVERLAY[@]}" up -d
        LOG "✅ AI interface deployed: OpenWebUI ($OWUI_UVICORN_WORKERS uvicorn workers)"
        ;;
    openwebui)
        ensure_db
        wait_for_redis
        LOG "Starting OpenWebUI ($OWUI_UVICORN_WORKERS uvicorn workers)..."
        # openwebui-migrate is pulled in automatically by openwebui-main's
        # depends_on (service_completed_successfully) — no need to name it.
        tiger_compose "${_BACKEND_OVERLAY[@]}" up -d openwebui-main
        ;;
    down)
        LOG "Stopping AI interface services..."
        # --remove-orphans clears the old openwebui-worker-01 / -02 / -worker
        # containers left behind by the pre-merge topology.
        tiger_compose down --remove-orphans
        ;;
    restart)
        LOG "Restarting the AI interface..."
        ensure_db
        wait_for_redis
        tiger_compose down --remove-orphans
        tiger_compose "${_BACKEND_OVERLAY[@]}" up -d
        LOG "✅ AI interface deployed: OpenWebUI ($OWUI_UVICORN_WORKERS uvicorn workers)"
        ;;
    *)
        usage
        ;;
esac

#!/usr/bin/env bash
# =====================================================================
# TigerAI OpenWebUI — one-time DB isolation migration
# Path: deployments/<stack>/03-ai-interface-ollama-openwebui-redis/migrations/db-rename-migration.sh
# =====================================================================
#
# Moves EXISTING OpenWebUI data from the shared `tigerai` DB (schema `openwebui`)
# into a dedicated `openwebui` DB (schema `public`), to match the k3s stacks and
# the new compose defaults (DATABASE_URL -> /openwebui, no search_path override).
#
# Idempotent + check-first:
#   • Already migrated (dedicated DB has OWUI tables) -> exit 0.
#   • No legacy data (fresh install)                  -> exit 0.
#   • Legacy data present                             -> migrate (destructive; confirm).
#
# RUN ORDER (IMPORTANT):
#   1. sudo bash ../03-ai-interface-ollama-openwebui-redis/deploy.sh down   (this script ALSO force-stops OWUI)
#   2. sudo bash ./openwebui-db-rename-migration.sh [-y]                     (THIS script)
#   3. sudo bash ../03-ai-interface-ollama-openwebui-redis/deploy.sh all     (redeploy AFTER migrating)
#   ⚠ Running `deploy.sh all` BEFORE this migration seeds an empty dedicated DB;
#     OpenWebUI creates public.alembic_version on first boot, so THIS script then
#     detects "already migrated" and SKIPS — leaving your legacy data behind in
#     tigerai. Always migrate first, then redeploy.
# Usage: sudo bash ./db-rename-migration.sh [-y]   (-y / ASSUME_YES=1 skips confirm)
# =====================================================================

set -eo pipefail

# --- 0) Config + env cascade (SCRIPT_DIR-anchored, like the backup scripts) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load env: tiger-tuning (../) -> root .env (../). Script lives in <stack>/migrations/.
# Anchored to script dir so an arbitrary CWD still resolves the stack env files.
[ -f "$SCRIPT_DIR/../tiger-tuning.env" ] && export $(grep -v '^#' "$SCRIPT_DIR/../tiger-tuning.env" | sed 's/\r//g' | xargs)
[ -f "$SCRIPT_DIR/../.env" ]             && export $(grep -v '^#' "$SCRIPT_DIR/../.env" | sed 's/\r//g' | xargs)

PG_USER="${PG_USER:-adm}"
export PGPASSWORD="${PG_PASS:-tigerai}"
PG_CONTAINER="${PG_CONTAINER:-${PG_HOST:-postgres}}"

SRC_DB="tigerai"                                   # legacy shared DB
SRC_SCHEMA="openwebui"                              # legacy schema inside tigerai
DST_DB="${OWUI_DB_NAME:-openwebui}"                 # dedicated target DB
APP_DIR="$SCRIPT_DIR/../03-ai-interface-ollama-openwebui-redis"  # app compose dir (for force-stop)
APP_MATCH='openwebui-main|openwebui-worker'         # container-name match (incl. scaled workers)

LOG_PREFIX="TigerAI OWUI migrate"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} $*"; }
WARN(){ echo -e "${YELLOW}[$LOG_PREFIX WARN]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; exit 1; }

# Confirmation gate for destructive actions (mirrors restore-tigerai.sh).
ASSUME_YES=${ASSUME_YES:-0}
[ "$1" = "-y" ] && { ASSUME_YES=1; shift; }
confirm() {
    if [ "$ASSUME_YES" = "1" ]; then
        WARN "ASSUME_YES set; proceeding without confirmation: $1"
        return 0
    fi
    if [ ! -t 0 ]; then
        ERROR "Refusing destructive action on non-interactive stdin. Re-run with -y or ASSUME_YES=1: $1"
    fi
    WARN "$1"
    printf "Type 'yes' to continue: "
    local reply
    read -r reply
    [ "$reply" = "yes" ] || ERROR "Aborted by user."
}

# psql helper: psql_qb <db> <sql> -> tuples-only, unaligned (may be empty on error)
psql_qb() {
    docker exec -e PGPASSWORD="$PGPASSWORD" -i "$PG_CONTAINER" \
        psql -U "$PG_USER" -d "$1" -tAc "$2" 2>/dev/null || true
}

# Force-stop the app so NO writes land after the pg_dump snapshot (silent data loss).
# Actively stops the compose project (catches scaled workers), then verifies none remain.
force_stop_app() {
    LOG "Force-stopping OpenWebUI containers (main + all scaled workers) before dump..."
    # The base file plus the platform overlay, matching how deploy.sh drives
    # compose. Before the stack merge this was a single docker-compose.yaml;
    # keeping that name here would have made the stop a silent no-op and left
    # the app writing during pg_dump.
    if [ -f "$APP_DIR/docker-compose.base.yaml" ]; then
        local -a _f=(-f "$APP_DIR/docker-compose.base.yaml")
        [ -f "$APP_DIR/docker-compose.${TIGER_PLATFORM}.yaml" ] && \
            _f+=(-f "$APP_DIR/docker-compose.${TIGER_PLATFORM}.yaml")
        docker compose --project-directory "$APP_DIR" "${_f[@]}" stop 2>/dev/null || true
    else
        WARN "Compose file not found at $APP_DIR/docker-compose.base.yaml; relying on the running-container check."
    fi
    local still_up
    still_up=$(docker ps --format '{{.Names}}' | grep -E "$APP_MATCH" || true)
    [ -n "$still_up" ] && ERROR "OpenWebUI still running after stop: ${still_up//$'\n'/ } — stop them manually and re-run."
    LOG "Confirmed no OpenWebUI containers are running."
}

# --- 1) Secret-key reminder (never touched by this script) ---
LOG "OpenWebUI DB isolation migration: ${SRC_DB}.${SRC_SCHEMA}  ->  dedicated '${DST_DB}' DB (public schema)"
WARN "OWUI_SECRET_KEY / WEBUI_SECRET_KEY MUST stay unchanged after this migration."
WARN "It encrypts stored fields; changing it makes them undecryptable. This script does NOT touch it."

docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" \
    || ERROR "PostgreSQL container '$PG_CONTAINER' is not running."

# --- 2) Already-migrated check ---
# Dedicated DB exists AND has a core OWUI table (alembic_version or "user").
# to_regclass returns NULL (empty) instead of erroring when the table is absent.
already_migrated() {
    local exists reg
    exists=$(psql_qb postgres "SELECT 1 FROM pg_database WHERE datname='$DST_DB';")
    [ "$exists" = "1" ] || return 1
    reg=$(psql_qb "$DST_DB" "SELECT to_regclass('public.alembic_version');")
    [ -n "$reg" ] && return 0
    reg=$(psql_qb "$DST_DB" "SELECT to_regclass('public.\"user\"');")
    [ -n "$reg" ] && return 0
    return 1
}

if already_migrated; then
    LOG "Dedicated DB '$DST_DB' already contains OpenWebUI tables — already migrated, skipping."
    exit 0
fi

# --- 3) Legacy-data check ---
has_legacy_data() {
    local exists reg
    exists=$(psql_qb postgres "SELECT 1 FROM pg_database WHERE datname='$SRC_DB';")
    [ "$exists" = "1" ] || return 1
    exists=$(psql_qb "$SRC_DB" "SELECT 1 FROM information_schema.schemata WHERE schema_name='$SRC_SCHEMA';")
    [ "$exists" = "1" ] || return 1
    reg=$(psql_qb "$SRC_DB" "SELECT to_regclass('${SRC_SCHEMA}.alembic_version');")
    [ -n "$reg" ] && return 0
    reg=$(psql_qb "$SRC_DB" "SELECT to_regclass('${SRC_SCHEMA}.\"user\"');")
    [ -n "$reg" ] && return 0
    return 1
}

if ! has_legacy_data; then
    LOG "No legacy OpenWebUI data found in ${SRC_DB}.${SRC_SCHEMA} — fresh install."
    LOG "Nothing to migrate; deploy.sh will create a fresh '${DST_DB}' DB on deploy."
    exit 0
fi

# --- 4) Migrate (destructive) ---
WARN "This script will force-stop OpenWebUI main + ALL workers before dumping (no post-snapshot writes)."
confirm "Migrate OpenWebUI data from ${SRC_DB}.${SRC_SCHEMA} into dedicated DB '${DST_DB}'? This DROPs the new DB's empty public schema."

# 4-pre) Force-stop the app BEFORE the dump so no rows are written after the snapshot.
force_stop_app

# 4a) Full safety snapshot of the source DB (timestamped, kept on disk).
TS="$(date +%Y%m%d_%H%M%S)"
SNAP="${SCRIPT_DIR}/owui-premigration-${SRC_DB}-${TS}.sql"
LOG "Snapshotting source DB '${SRC_DB}' -> ${SNAP} ..."
docker exec -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
    pg_dump -U "$PG_USER" "$SRC_DB" > "$SNAP" \
    || ERROR "Snapshot failed; aborting before any changes."
[ -s "$SNAP" ] || ERROR "Snapshot file is empty (${SNAP}); aborting before any destructive step."
LOG "Snapshot saved: ${SNAP}"

# 4b) Create dedicated DB (SELECT-guarded; CREATE DATABASE has no IF NOT EXISTS,
#     and cannot run inside a transaction).
DST_EXISTS=$(psql_qb postgres "SELECT 1 FROM pg_database WHERE datname='$DST_DB';")
if [ "$DST_EXISTS" = "1" ]; then
    LOG "Database '${DST_DB}' already exists — reusing it."
else
    LOG "Creating database '${DST_DB}' (owner ${PG_USER})..."
    docker exec -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
        psql -U "$PG_USER" -d postgres -c "CREATE DATABASE \"$DST_DB\" OWNER \"$PG_USER\";" \
        || ERROR "Failed to create database '${DST_DB}'."
fi

# 4b-2) Clear any leftover '${SRC_SCHEMA}' schema in DST from a prior partial run,
#       so the restore below re-runs cleanly (no "schema already exists" jam).
LOG "Clearing any leftover '${SRC_SCHEMA}' schema in '${DST_DB}' (idempotent re-run)..."
docker exec -e PGPASSWORD="$PGPASSWORD" -i "$PG_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$DST_DB" \
    -c "DROP SCHEMA IF EXISTS \"${SRC_SCHEMA}\" CASCADE;" \
    || ERROR "Failed to clear leftover schema '${SRC_SCHEMA}' in '${DST_DB}'."

# 4c) Copy the openwebui schema (structure + data, INCLUDING alembic_version) from
#     tigerai into the dedicated DB via a custom-format dump. alembic_version travels
#     with the schema so OpenWebUI does NOT re-run migrations / start empty.
LOG "Copying schema '${SRC_SCHEMA}' from '${SRC_DB}' into '${DST_DB}'..."
docker exec -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
    pg_dump -Fc --no-owner --no-acl -n "$SRC_SCHEMA" "$SRC_DB" \
  | docker exec -e PGPASSWORD="$PGPASSWORD" -i "$PG_CONTAINER" \
    pg_restore --no-owner --no-acl --exit-on-error -d "$DST_DB" \
    || ERROR "Schema copy failed. Source data is untouched; snapshot at ${SNAP}."

# 4d-guard) DST public-empty guard: refuse to DROP public if it holds tables that are
#           NOT part of the app (protects against wiping unrelated data in a non-dedicated DB).
#           At this point the app tables live in schema '${SRC_SCHEMA}' (just restored);
#           any public table NOT in that set is unrelated -> abort.
PUB_UNEXPECTED=$(psql_qb "$DST_DB" "SELECT string_agg(table_name, ',') FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' AND table_name NOT IN (SELECT table_name FROM information_schema.tables WHERE table_schema='${SRC_SCHEMA}');")
[ -n "$PUB_UNEXPECTED" ] && ERROR "DST '${DST_DB}' public schema holds unrelated tables: ${PUB_UNEXPECTED}. Refusing to DROP public. Migrate into a dedicated DB; snapshot at ${SNAP}."

# 4d) Promote the copied 'openwebui' schema to 'public' — atomically, so a mid-step
#     failure never leaves public dropped without the rename applied.
LOG "Promoting schema '${SRC_SCHEMA}' -> 'public' in '${DST_DB}' (single transaction)..."
docker exec -e PGPASSWORD="$PGPASSWORD" -i "$PG_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$DST_DB" <<SQL || ERROR "Schema promotion failed (rolled back); snapshot at ${SNAP}."
BEGIN;
DROP SCHEMA IF EXISTS public CASCADE;
ALTER SCHEMA "${SRC_SCHEMA}" RENAME TO public;
GRANT ALL ON SCHEMA public TO "${PG_USER}";
COMMIT;
SQL

# --- 5) Verify (ASSERT required tables exist; do NOT report success on a partial restore) ---
LOG "Verifying migrated data in '${DST_DB}'..."
[ -n "$(psql_qb "$DST_DB" "SELECT to_regclass('public.\"user\"');")" ] \
    || ERROR "Verify failed: public.\"user\" missing in '${DST_DB}'. Snapshot at ${SNAP}."
[ -n "$(psql_qb "$DST_DB" "SELECT to_regclass('public.alembic_version');")" ] \
    || ERROR "Verify failed: public.alembic_version missing in '${DST_DB}'. Snapshot at ${SNAP}."
USERS=$(psql_qb "$DST_DB" "SELECT count(*) FROM public.\"user\";");             USERS=${USERS:-n/a}
CHATS=$(psql_qb "$DST_DB" "SELECT count(*) FROM public.chat;");                 CHATS=${CHATS:-n/a}
ALEMBIC=$(psql_qb "$DST_DB" "SELECT version_num FROM public.alembic_version LIMIT 1;"); ALEMBIC=${ALEMBIC:-n/a}
LOG "  user rows        : ${USERS}"
LOG "  chat rows        : ${CHATS}"
LOG "  alembic_version  : ${ALEMBIC}"

# --- 6) Done + rollback note ---
LOG "-----------------------------------------------------------------"
LOG "Migration complete. Redeploy OpenWebUI: sudo bash ../03-ai-interface-ollama-openwebui-redis/deploy.sh all"
LOG "Rollback: the old '${SRC_DB}.${SRC_SCHEMA}' schema is left INTACT."
LOG "  • To roll back, point DATABASE_URL back at ${SRC_DB} (?options=-csearch_path=${SRC_SCHEMA}) and redeploy."
LOG "  • DROP the old schema ONLY after verifying the new DB in the OpenWebUI UI:"
LOG "      docker exec -e PGPASSWORD=... ${PG_CONTAINER} psql -U ${PG_USER} -d ${SRC_DB} -c 'DROP SCHEMA ${SRC_SCHEMA} CASCADE;'"
LOG "Reminder: keep OWUI_SECRET_KEY / WEBUI_SECRET_KEY identical to pre-migration."
LOG "Pre-migration snapshot: ${SNAP}"

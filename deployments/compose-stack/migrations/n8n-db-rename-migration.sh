#!/usr/bin/env bash
# =====================================================================
# TigerAI n8n — one-time DB isolation migration
# Path: deployments/<stack>/04-automation-n8n/migrations/db-rename-migration.sh
# =====================================================================
#
# Moves EXISTING n8n data from the shared `tigerai` DB (schema `n8n`) into a
# dedicated `n8n` DB (schema `public`), to match the k3s stacks and the new
# compose defaults (DB_POSTGRESDB_DATABASE=n8n / DB_POSTGRESDB_SCHEMA=public).
#
# Idempotent + check-first:
#   • Already migrated (dedicated DB has n8n tables with rows) -> exit 0.
#   • No legacy data (fresh install)                           -> exit 0.
#   • Legacy data present                                      -> migrate (destructive; confirm).
#
# RUN ORDER (IMPORTANT):
#   1. sudo bash ../04-automation-n8n/deploy.sh down   (this script ALSO force-stops n8n)
#   2. sudo bash ./n8n-db-rename-migration.sh [-y]     (THIS script)
#   3. sudo bash ../04-automation-n8n/deploy.sh all    (redeploy AFTER migrating)
#   ⚠ Running `deploy.sh all` BEFORE this migration seeds an empty dedicated DB;
#     n8n populates public.migrations on first boot, so THIS script then detects
#     "already migrated" and SKIPS — leaving your legacy data behind in tigerai.
#     Always migrate first, then redeploy.
# Usage: sudo bash ./db-rename-migration.sh [-y]   (-y / ASSUME_YES=1 skips confirm)
# =====================================================================

set -eo pipefail

# --- 0) Config + env cascade (SCRIPT_DIR-anchored, like the backup scripts) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load env: tiger-tuning (../) -> root .env (../). Script lives in <stack>/migrations/.
# Anchored to script dir so an arbitrary CWD still resolves the stack env files.
[ -f "$SCRIPT_DIR/../tiger-tuning.env" ] && export $(grep -v '^#' "$SCRIPT_DIR/../tiger-tuning.env" | sed 's/\r//g' | xargs)
[ -f "$SCRIPT_DIR/../.env" ]             && export $(grep -v '^#' "$SCRIPT_DIR/../.env" | sed 's/\r//g' | xargs)

PG_USER="${PG_USER:-${DB_POSTGRESDB_USER:-adm}}"
export PGPASSWORD="${PG_PASS:-${DB_POSTGRESDB_PASSWORD:-tigerai}}"
PG_CONTAINER="${PG_CONTAINER:-${DB_POSTGRESDB_HOST:-postgres}}"

SRC_DB="tigerai"                                   # legacy shared DB
SRC_SCHEMA="n8n"                                   # legacy schema inside tigerai
DST_DB="${DB_POSTGRESDB_DATABASE:-n8n}"            # dedicated target DB
APP_DIR="$SCRIPT_DIR/../04-automation-n8n"         # app compose dir (for force-stop)
APP_MATCH='n8n-main|n8n-worker'                    # container-name match (incl. scaled workers)

LOG_PREFIX="TigerAI n8n migrate"
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
    LOG "Force-stopping n8n containers (main + all scaled workers) before dump..."
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
    [ -n "$still_up" ] && ERROR "n8n still running after stop: ${still_up//$'\n'/ } — stop them manually and re-run."
    LOG "Confirmed no n8n containers are running."
}

# --- 1) N8N_SECRET reminder (never touched by this script) ---
LOG "n8n DB isolation migration: ${SRC_DB}.${SRC_SCHEMA}  ->  dedicated '${DST_DB}' DB (public schema)"
WARN "N8N_SECRET / N8N_ENCRYPTION_KEY MUST stay unchanged after this migration."
WARN "It encrypts stored credentials; changing it makes them undecryptable. This script does NOT touch it."

docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" \
    || ERROR "PostgreSQL container '$PG_CONTAINER' is not running."

# --- 2) Already-migrated check ---
already_migrated() {
    local exists reg cnt
    exists=$(psql_qb postgres "SELECT 1 FROM pg_database WHERE datname='$DST_DB';")
    [ "$exists" = "1" ] || return 1
    # public.migrations (or workflow_entity) exists AND has rows -> already migrated
    reg=$(psql_qb "$DST_DB" "SELECT to_regclass('public.migrations');")
    if [ -n "$reg" ]; then
        cnt=$(psql_qb "$DST_DB" "SELECT count(*) FROM public.migrations;")
        [ "${cnt:-0}" -ge 1 ] 2>/dev/null && return 0
    fi
    reg=$(psql_qb "$DST_DB" "SELECT to_regclass('public.workflow_entity');")
    if [ -n "$reg" ]; then
        cnt=$(psql_qb "$DST_DB" "SELECT count(*) FROM public.workflow_entity;")
        [ "${cnt:-0}" -ge 1 ] 2>/dev/null && return 0
    fi
    return 1
}

if already_migrated; then
    LOG "Dedicated DB '$DST_DB' already contains n8n tables with data — already migrated, skipping."
    exit 0
fi

# --- 3) Legacy-data check ---
has_legacy_data() {
    local exists reg
    exists=$(psql_qb postgres "SELECT 1 FROM pg_database WHERE datname='$SRC_DB';")
    [ "$exists" = "1" ] || return 1
    exists=$(psql_qb "$SRC_DB" "SELECT 1 FROM information_schema.schemata WHERE schema_name='$SRC_SCHEMA';")
    [ "$exists" = "1" ] || return 1
    reg=$(psql_qb "$SRC_DB" "SELECT to_regclass('${SRC_SCHEMA}.migrations');")
    [ -n "$reg" ] && return 0
    reg=$(psql_qb "$SRC_DB" "SELECT to_regclass('${SRC_SCHEMA}.workflow_entity');")
    [ -n "$reg" ] && return 0
    return 1
}

if ! has_legacy_data; then
    LOG "No legacy n8n data found in ${SRC_DB}.${SRC_SCHEMA} — fresh install."
    LOG "Nothing to migrate; deploy.sh will create a fresh '${DST_DB}' DB on deploy."
    exit 0
fi

# --- 4) Migrate (destructive) ---
WARN "This script will force-stop n8n main + ALL workers before dumping (no post-snapshot writes)."
WARN "Note: the n8n schema includes execution_entity (execution history), which can be large —"
WARN "the snapshot and copy below may take a while / use significant disk on busy instances."
confirm "Migrate n8n data from ${SRC_DB}.${SRC_SCHEMA} into dedicated DB '${DST_DB}'? This DROPs the new DB's empty public schema."

# 4-pre) Force-stop the app BEFORE the dump so no rows are written after the snapshot.
force_stop_app

# 4a) Full safety snapshot of the source DB (timestamped, kept on disk).
TS="$(date +%Y%m%d_%H%M%S)"
SNAP="${SCRIPT_DIR}/n8n-premigration-${SRC_DB}-${TS}.sql"
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

# 4c) Copy the n8n schema (data + structure) from tigerai into the dedicated DB.
LOG "Copying schema '${SRC_SCHEMA}' from '${SRC_DB}' into '${DST_DB}'..."
docker exec -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
    pg_dump --no-owner --no-acl -n "$SRC_SCHEMA" "$SRC_DB" \
  | docker exec -e PGPASSWORD="$PGPASSWORD" -i "$PG_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$DST_DB" \
    || ERROR "Schema copy failed. Source data is untouched; snapshot at ${SNAP}."

# 4d-guard) DST public-empty guard: refuse to DROP public if it holds tables that are
#           NOT part of the app (protects against wiping unrelated data in a non-dedicated DB).
#           At this point the app tables live in schema '${SRC_SCHEMA}' (just restored);
#           any public table NOT in that set is unrelated -> abort.
PUB_UNEXPECTED=$(psql_qb "$DST_DB" "SELECT string_agg(table_name, ',') FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' AND table_name NOT IN (SELECT table_name FROM information_schema.tables WHERE table_schema='${SRC_SCHEMA}');")
[ -n "$PUB_UNEXPECTED" ] && ERROR "DST '${DST_DB}' public schema holds unrelated tables: ${PUB_UNEXPECTED}. Refusing to DROP public. Migrate into a dedicated DB; snapshot at ${SNAP}."

# 4d) Promote the copied 'n8n' schema to 'public' — atomically, so a mid-step failure
#     never leaves public dropped without the rename applied.
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
[ -n "$(psql_qb "$DST_DB" "SELECT to_regclass('public.workflow_entity');")" ] \
    || ERROR "Verify failed: public.workflow_entity missing in '${DST_DB}'. Snapshot at ${SNAP}."
[ -n "$(psql_qb "$DST_DB" "SELECT to_regclass('public.migrations');")" ] \
    || ERROR "Verify failed: public.migrations missing in '${DST_DB}'. Snapshot at ${SNAP}."
WF=$(psql_qb "$DST_DB" "SELECT count(*) FROM public.workflow_entity;");    WF=${WF:-n/a}
CRED=$(psql_qb "$DST_DB" "SELECT count(*) FROM public.credentials_entity;"); CRED=${CRED:-n/a}
MIG=$(psql_qb "$DST_DB" "SELECT name FROM public.migrations ORDER BY id DESC LIMIT 1;"); MIG=${MIG:-n/a}
LOG "  workflow_entity rows    : ${WF}"
LOG "  credentials_entity rows : ${CRED}"
LOG "  latest migration        : ${MIG}"

# --- 6) Done + rollback note ---
LOG "-----------------------------------------------------------------"
LOG "Migration complete. Redeploy n8n: sudo bash ../04-automation-n8n/deploy.sh all"
LOG "Rollback: the old '${SRC_DB}.${SRC_SCHEMA}' schema is left INTACT."
LOG "  • To roll back, set DB_POSTGRESDB_DATABASE=${SRC_DB} / DB_POSTGRESDB_SCHEMA=${SRC_SCHEMA} and redeploy."
LOG "  • DROP the old schema ONLY after verifying the new DB in the n8n UI:"
LOG "      docker exec -e PGPASSWORD=... ${PG_CONTAINER} psql -U ${PG_USER} -d ${SRC_DB} -c 'DROP SCHEMA ${SRC_SCHEMA} CASCADE;'"
LOG "Reminder: keep N8N_SECRET / N8N_ENCRYPTION_KEY identical to pre-migration."
LOG "Pre-migration snapshot: ${SNAP}"

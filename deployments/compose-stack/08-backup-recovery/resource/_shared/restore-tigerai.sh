#!/usr/bin/env bash
# =====================================================================
# TigerAI Data Restoration Tool (P1 Tier)
# Path: deployments/compose-stack/08-backup-recovery/resource/_shared/restore-tigerai.sh
#
# WARNING: this script must stay at the FIRST level of resource/_shared/.
# The `../..` below is a hard-coded depth — see backup-tigerai.sh for what
# breaks silently if it moves.
# =====================================================================

# --- 0) Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# <module>/resource/_shared/<this file>  ->  ../.. is the module directory.
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Restore"
# shellcheck source=../../../lib/common.sh
source "${TIGER_MODULE_DIR}/../lib/common.sh"

# In-script defaults (env cascade above overrides these when set)
BASE_DIR=${BASE_DIR:-/home/wrt/TigerAI}
PG_CONTAINER=${PG_CONTAINER:-postgres}
# DATA_DIRS unset -> back up everything under BASE_DIR (space-separated list to narrow)
DATA_DIRS=${DATA_DIRS:-"$BASE_DIR"}

BACKUP_ROOT=${BACKUP_ROOT:-"/opt/tigerai/backups"}

# LOG / WARN / ERROR and the color definitions come from lib/common.sh.

# Confirmation gate for destructive actions. Skipped when ASSUME_YES=1 or -y is
# passed (for automation); aborts on a non-interactive stdin unless bypassed.
ASSUME_YES=${ASSUME_YES:-0}
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

usage() {
    echo "Usage: sudo $0 [-y] [backup_date_folder] {all | db | data}"
    echo "Example: sudo $0 20260202_120000 all"
    echo "  -y / ASSUME_YES=1  skip the overwrite confirmation (non-interactive)"
    echo ""
    echo "Available backups in $BACKUP_ROOT:"
    ls -1 "$BACKUP_ROOT" 2>/dev/null || echo "  (None found)"
    exit 1
}

# --- Validation ---
[ "$(id -u)" -ne 0 ] && ERROR "Please run with sudo."
[ "$1" = "-y" ] && { ASSUME_YES=1; shift; }
[ $# -lt 2 ] && usage

RESTORE_DIR="${BACKUP_ROOT}/$1"
TARGET=$2

[ ! -d "$RESTORE_DIR" ] && ERROR "Backup directory $RESTORE_DIR does not exist."

# --- 1) Restore Database ---
# Handles per-DB dumps (db_<name>.sql.gz, one file per app database). Falls back
# to the legacy single-DB dump (database.sql.gz -> $PG_DB_NAME) for old backups.
restore_db() {
    LOG " [1/2] Restoring PostgreSQL Databases..."
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container ($PG_CONTAINER) is not running."
    fi

    local file db
    local dbs=()
    for file in "${RESTORE_DIR}"/db_*.sql.gz; do
        [ -f "$file" ] || continue
        db=$(basename "$file" .sql.gz); db=${db#db_}
        dbs+=("$db")
    done

    # Backward-compat: legacy backups stored a single database.sql.gz -> $PG_DB_NAME.
    local legacy="${RESTORE_DIR}/database.sql.gz"
    local has_legacy=0
    [ "${#dbs[@]}" -eq 0 ] && [ -f "$legacy" ] && has_legacy=1

    if [ "${#dbs[@]}" -eq 0 ] && [ "$has_legacy" -eq 0 ]; then
        WARN "No database backup files (db_*.sql.gz or database.sql.gz) found in $RESTORE_DIR."
        return
    fi

    WARN "This will DROP and re-create the following databases (all current data in them is lost):"
    if [ "$has_legacy" -eq 1 ]; then
        echo "    - ${PG_DB_NAME} (from legacy database.sql.gz)"
    else
        for db in "${dbs[@]}"; do echo "    - ${db}"; done
    fi
    confirm "Drop and re-create the databases listed above?"

    if [ "$has_legacy" -eq 1 ]; then
        LOG "Restoring legacy dump into '${PG_DB_NAME}'..."
        docker exec "$PG_CONTAINER" dropdb -U "$PG_USER" --if-exists "$PG_DB_NAME"
        docker exec "$PG_CONTAINER" createdb -U "$PG_USER" "$PG_DB_NAME"
        gunzip -c "$legacy" | docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" "$PG_DB_NAME"
    else
        for db in "${dbs[@]}"; do
            file="${RESTORE_DIR}/db_${db}.sql.gz"
            LOG "Restoring '${db}' from $(basename "$file")..."
            docker exec "$PG_CONTAINER" dropdb -U "$PG_USER" --if-exists "$db"
            docker exec "$PG_CONTAINER" createdb -U "$PG_USER" "$db"
            gunzip -c "$file" | docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" "$db"
        done
    fi
    LOG " Database restoration complete."
}

# --- 2) Restore Data Directories ---
restore_data() {
    LOG " [2/2] Restoring Application Data Volumes..."

    local manifest="${RESTORE_DIR}/data-paths.manifest"
    local file tar_name target_path entry
    local targets=()

    # Resolve each archive to its recorded source path first (round-trip via the
    # manifest) so we can show exactly what will be overwritten before touching disk.
    for file in "${RESTORE_DIR}"/data_*.tar.gz; do
        [ -f "$file" ] || continue
        tar_name=$(basename "$file")
        target_path=""
        [ -f "$manifest" ] && target_path=$(grep -F "${tar_name}=" "$manifest" | head -n1 | cut -d= -f2-) || true
        if [ -z "$target_path" ]; then
            WARN "No source path recorded for ${tar_name}; skipping to avoid restoring to the wrong location."
            continue
        fi
        targets+=("${tar_name}=${target_path}")
    done

    if [ "${#targets[@]}" -eq 0 ]; then
        WARN "No restorable data archives found in $RESTORE_DIR."
        return
    fi

    WARN "This will OVERWRITE existing data at the following paths (services should be stopped):"
    for entry in "${targets[@]}"; do
        echo "    - ${entry#*=}"
    done
    confirm "Overwrite the data paths listed above?"

    for entry in "${targets[@]}"; do
        tar_name="${entry%%=*}"
        target_path="${entry#*=}"
        file="${RESTORE_DIR}/${tar_name}"
        LOG "Restoring ${tar_name} to ${target_path}..."
        sudo mkdir -p "$target_path"
        sudo tar -xzf "$file" -C "$target_path"
    done
    LOG " Data volumes restoration complete."
}

# --- Execution ---
LOG " Starting restoration from $RESTORE_DIR..."
case "$TARGET" in
    all)
        restore_db
        restore_data
        ;;
    db) restore_db ;;
    data) restore_data ;;
    *) usage ;;
esac
LOG " Restoration Process Finished."

#!/usr/bin/env bash
# =====================================================================
# TigerAI Automated Backup (P1 Tier)
# Path: deployments/compose-stack/08-backup-recovery/resource/_shared/backup-tigerai.sh
#
# WARNING: this script must stay at the FIRST level of resource/_shared/.
# The `../..` below is a hard-coded depth. Move it into a subdirectory and
# TIGER_MODULE_DIR silently points one level too high, every env file misses
# the `[ -f ]` test, every value falls back to its built-in default, and the
# script still exits 0 — with the default host and the default password.
# =====================================================================

# --- 0) Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# <module>/resource/_shared/<this file>  ->  ../.. is the module directory.
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Backup"
# Setting TIGER_MODULE_DIR before sourcing is required: common.sh otherwise
# derives it from the caller's own directory, which here is resource/_shared/.
# shellcheck source=../../../lib/common.sh
source "${TIGER_MODULE_DIR}/../lib/common.sh"

# In-script defaults (env cascade above overrides these when set)
BASE_DIR=${BASE_DIR:-/home/wrt/TigerAI}
PG_CONTAINER=${PG_CONTAINER:-postgres}
# DATA_DIRS unset -> back up everything under BASE_DIR (space-separated list to narrow)
DATA_DIRS=${DATA_DIRS:-"$BASE_DIR"}

BACKUP_ROOT=${BACKUP_ROOT:-"/opt/tigerai/backups"}
RETENTION_DAYS=${RETENTION_DAYS:-7}
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_ROOT}/${DATE}"
MANIFEST="${BACKUP_PATH}/data-paths.manifest"
INCOMPLETE=0

# LOG / WARN / ERROR and the color definitions come from lib/common.sh.

# Create backup directory
mkdir -p "$BACKUP_PATH"

# --- 1) PostgreSQL Backup ---
backup_db() {
    LOG " [1/3] Dumping PostgreSQL Databases..."
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        WARN "PostgreSQL container '$PG_CONTAINER' not running; skipping DB backup. Backup is INCOMPLETE."
        INCOMPLETE=1
        return
    fi

    # Enumerate every non-template, non-system database dynamically so each app DB
    # (tigerai, n8n, openwebui, grafana, ...) is dumped to its own file and
    # any future per-service DB is auto-covered without editing this script.
    local db_list
    if ! db_list=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -tAc \
        "SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres')"); then
        WARN "Failed to query database list from '$PG_CONTAINER'; skipping DB backup. Backup is INCOMPLETE."
        INCOMPLETE=1
        return
    fi

    if [ -z "${db_list//[[:space:]]/}" ]; then
        WARN "No user databases found in '$PG_CONTAINER'; nothing to dump. Backup is INCOMPLETE."
        INCOMPLETE=1
        return
    fi

    local db
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        LOG "Dumping database '$db'..."
        if docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" "$db" | gzip > "${BACKUP_PATH}/db_${db}.sql.gz"; then
            LOG "  -> db_${db}.sql.gz"
        else
            WARN "pg_dump failed for database '$db'. Backup is INCOMPLETE."
            INCOMPLETE=1
        fi
    done <<< "$db_list"
    LOG " Database dump completed."
}

# --- 2) Critical Data Directories ---
backup_data_dirs() {
    LOG " [2/3] Backing up Application Data Directories..."
    if [ -z "${DATA_DIRS// /}" ]; then
        WARN "DATA_DIRS is empty (BASE_DIR='${BASE_DIR}'); no application data backed up. Backup is INCOMPLETE."
        INCOMPLETE=1
        return
    fi
    local seen_names=" "
    for dir in $DATA_DIRS; do
        if [ -d "$dir" ]; then
            name=$(basename "$dir")
            # Guard against basename collisions (e.g. /a/n8n vs /b/n8n): the tar filename
            # and manifest key are both keyed on basename, so a duplicate would clobber the
            # earlier archive and misdirect restore. Fail loud and skip the colliding entry.
            if [[ "$seen_names" == *" ${name} "* ]]; then
                WARN "Duplicate basename '${name}' (from '$dir') collides with an earlier DATA_DIRS entry; skipping to avoid overwrite. Backup is INCOMPLETE."
                INCOMPLETE=1
                continue
            fi
            seen_names="${seen_names}${name} "
            LOG "Packaging $dir..."
            sudo tar -czf "${BACKUP_PATH}/data_${name}.tar.gz" -C "$dir" .
            # Record source path so restore returns data to the exact same location
            echo "data_${name}.tar.gz=${dir}" >> "$MANIFEST"
        else
            WARN "Directory '$dir' not found; skipping. Backup is INCOMPLETE."
            INCOMPLETE=1
        fi
    done
    LOG " Data directory backup completed."
}

# --- 3) Retention Policy ---
cleanup_old_backups() {
    LOG " [3/3] Applying Retention Policy (Keeping last $RETENTION_DAYS days)..."
    find "$BACKUP_ROOT" -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} +
    LOG " Cleanup finished."
}

# --- Main Logic ---
[ "$(id -u)" -ne 0 ] && ERROR "Please run with sudo."

LOG " Starting Full System Backup to ${BACKUP_PATH}..."
backup_db
backup_data_dirs
cleanup_old_backups

if [ "$INCOMPLETE" -eq 1 ]; then
    WARN "Backup finished but is INCOMPLETE — review the warnings above."
else
    LOG " Backup Process Finished Successfully."
fi
LOG "Backup Location: ${BACKUP_PATH}"

# Exit non-zero when incomplete so cron / callers can detect the failure.
if [ "$INCOMPLETE" -eq 1 ]; then
    exit 1
fi

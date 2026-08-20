#!/usr/bin/env bash
# =====================================================================
# TigerAI Automated Backup (P1 Tier)
# Path: deployments/compose-stack/09-backup-recovery/resource/_shared/backup-tigerai.sh
#
# 三平台共用一份（舊三份逐字相同，只差各自的 "# Path:" 檔頭）。備份內容沒有
# 任何 GPU / 平台相依性 —— 就是 pg_dump + tar，所以放 _shared/。
#
# 可由 deploy.sh 的 `backup` action 呼叫，也可以直接跑（cron / 人工）。
# 刻意不 source lib/common.sh：本檔不需要 tiger_compose，也不該在沒有
# TIGER_PLATFORM 的 cron 環境下因為 lib 的平台驗證而失敗。
# =====================================================================

set -eo pipefail

# --- 0) Configuration ---
# 路徑一律以本檔位置推導，不依賴 CWD（cron 起來時 CWD 是家目錄）。
# 本檔位於 <stack>/09-backup-recovery/resource/_shared/，因此 ../.. 是模組目錄、
# ../../.. 是 stack 根目錄。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STACK_DIR="$(cd "$MODULE_DIR/.." && pwd)"

# LOG/WARN/ERROR and the colors come from lib/log.sh, which is side-effect free
# (no set, no trap, no TIGER_PLATFORM) — so this file's "does not source
# lib/common.sh" design is unaffected. Loaded before the env cascade so the
# errors below have ERROR available. Never fall back to built-ins.
if [ ! -f "$STACK_DIR/lib/log.sh" ]; then
    echo "[TigerAI ERROR] not found: $STACK_DIR/lib/log.sh (SCRIPT_DIR=$SCRIPT_DIR)" >&2
    exit 1
fi
# shellcheck source-path=SCRIPTDIR/../../../lib
# shellcheck source=log.sh
source "$STACK_DIR/lib/log.sh"

# Load env（後者覆蓋前者），順序與 lib/common.sh 的 tiger_load_env 一致：
#   <stack>/tiger-tuning.env → <stack>/.env → <module>/.env
# ⚠️ 這三個檔都是 .gitignore 的，.gitattributes 的 EOL 正規化管不到，所以仍要
#    `sed 's/\r$//'` 剝掉行尾 CRLF（PG_USER=adm\r 會讓 pg_dump 全數失敗）。
# ⚠️ 用 source 而非舊版的 `export $(grep -v '^#' … | xargs)`：後者遇到行內註解會
#    rc=1 中止、遇到含空白的值會靜默截斷。temp file 而非 source <(sed …)：
#    後者在 bash 3.2 會靜默載入空內容。
set -a
for _envfile in "$STACK_DIR/tiger-tuning.env" "$STACK_DIR/.env" "$MODULE_DIR/.env"; do
    if [ -f "$_envfile" ]; then
        _tmp=$(mktemp)
        sed 's/\r$//' "$_envfile" > "$_tmp"
        # shellcheck disable=SC1090
        source "$_tmp"
        rm -f "$_tmp"
    fi
done
set +a

# In-script defaults (env cascade above overrides these when set)
BASE_DIR=${BASE_DIR:-/home/wrt/TigerAI}
PG_CONTAINER=${PG_CONTAINER:-postgres}
# Must match 02-database-postgres-pgadmin (deploy.sh 與 docker-compose.base.yaml
# 都是 ${PG_USER:-adm}）。沒有預設值時 .env 不存在會展開成空字串，pg_dump -U ''
# 的錯誤訊息指不到根因。
PG_USER=${PG_USER:-adm}
# DATA_DIRS unset -> back up everything under BASE_DIR (space-separated list to narrow)
DATA_DIRS=${DATA_DIRS:-"$BASE_DIR"}

BACKUP_ROOT=${BACKUP_ROOT:-"/opt/tigerai/backups"}
RETENTION_DAYS=${RETENTION_DAYS:-7}
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_ROOT}/${DATE}"
MANIFEST="${BACKUP_PATH}/data-paths.manifest"
INCOMPLETE=0

# The prefix is evaluated at call time, so setting it after the source works.
# Kept after the env cascade so this file's value still beats any .env.
TIGER_LOG_PREFIX="TigerAI Backup"

# Everything written below is operational data: globals.sql.gz carries every role's
# SCRAM password hash, and the db_*.sql.gz / data_*.tar.gz next to it carry the
# actual contents of those databases and volumes. Default 0022 would leave all of
# it world-readable under /opt, so create it 0700/0600 from the start.
umask 077

# Create backup directory
mkdir -p "$BACKUP_PATH"

# --- 1) PostgreSQL Backup ---
backup_db() {
    LOG " [1/4] Dumping PostgreSQL Databases..."
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

    # Roles/tablespaces are cluster-wide, so pg_dump (which is per-database) never
    # includes them. Restoring onto a fresh pgdata volume would otherwise come up
    # with only the initdb-created "$PG_USER" and every `GRANT ... TO <role>` in
    # the dumps would fail. Dumped before the per-DB loop to mirror restore order.
    LOG "Dumping global objects (roles, tablespaces)..."
    if docker exec "$PG_CONTAINER" pg_dumpall -U "$PG_USER" --globals-only | gzip > "${BACKUP_PATH}/globals.sql.gz"; then
        LOG "  -> globals.sql.gz"
    else
        WARN "pg_dumpall --globals-only failed. Backup is INCOMPLETE."
        INCOMPLETE=1
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
    LOG " [2/4] Backing up Application Data Directories..."
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
            # --sparse: Qdrant's segment files are sparse; without it tar stores every
            # hole as real zero bytes (3.9 MB -> 1.2 GB on restore). Create-side only,
            # so older archives stay inflated — `fallocate --dig-holes` reclaims those.
            sudo tar --sparse -czf "${BACKUP_PATH}/data_${name}.tar.gz" -C "$dir" .
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
    LOG " [3/4] Applying Retention Policy (Keeping last $RETENTION_DAYS days)..."
    find "$BACKUP_ROOT" -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} +
    LOG " Cleanup finished."
}

# --- 4) Permissions ---
# umask only covers what THIS run created. BACKUP_ROOT and the backups from every
# earlier run (taken before this hardening, or with `sudo tar` under sudo's own
# 0022 umask) are still whatever they were, so tighten the whole tree — it is
# idempotent and the tree is small (a few files per daily backup).
harden_backup_perms() {
    LOG " [4/4] Tightening permissions under $BACKUP_ROOT (dirs 700, files 600)..."
    # Both passes are non-fatal and independent on purpose. BACKUP_ROOT can be
    # pointed at an NFS/SMB or shared directory (it is overridable from .env), where
    # a chmod on someone else's leftover file fails. Under `set -e` that would (a)
    # kill the run before the INCOMPLETE summary and the "Backup Location:" line,
    # so a perfectly good backup looks like a failed one with no diagnosis, and
    # (b) skip the file pass entirely — leaving every dump at 0644 in exactly the
    # environment that needs 0600 most. INCOMPLETE=1 keeps the non-zero exit for
    # cron, and the WARN below says which half failed.
    local perm_failed=0
    # find starts at BACKUP_ROOT itself, so the root directory is covered too.
    find "$BACKUP_ROOT" -type d -exec chmod 700 {} + || perm_failed=1
    find "$BACKUP_ROOT" -type f -exec chmod 600 {} + || perm_failed=1
    if [ "$perm_failed" -eq 1 ]; then
        WARN "Some files/directories under $BACKUP_ROOT could not be chmod'ed (see the errors above); they may still be world-readable. The backup content itself is unaffected. Backup is INCOMPLETE."
        INCOMPLETE=1
        return
    fi
    LOG " Permissions applied."
}

# --- Main Logic ---
[ "$(id -u)" -ne 0 ] && ERROR "Please run with sudo."

LOG " Starting Full System Backup to ${BACKUP_PATH}..."
backup_db
backup_data_dirs
cleanup_old_backups
harden_backup_perms

if [ "$INCOMPLETE" -eq 1 ]; then
    WARN "Backup finished but is INCOMPLETE — review the warnings above."
else
    LOG " Backup Process Finished Successfully."
fi

# The verdict must be on stdout. WARN goes to stderr, so `backup-tigerai.sh
# 2>/dev/null` swallows every INCOMPLETE warning and leaves only
# "Backup Location: ..." on screen — it reads as a clean success, with just
# rc=1 giving it away. Details stay on stderr; rc is still the gate.
if [ "$INCOMPLETE" -eq 1 ]; then
    LOG "Result: INCOMPLETE — one or more items failed; see the warnings on stderr (exit code 1)"
else
    LOG "Result: OK"
fi
LOG "Backup Location: ${BACKUP_PATH}"

# Exit non-zero when incomplete so cron / callers can detect the failure.
if [ "$INCOMPLETE" -eq 1 ]; then
    exit 1
fi

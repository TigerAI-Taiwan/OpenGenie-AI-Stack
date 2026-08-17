#!/usr/bin/env bash
# =====================================================================
# TigerAI Data Restoration Tool (P1 Tier)
# Path: deployments/compose-stack/08-backup-recovery/resource/_shared/restore-tigerai.sh
#
# 三平台共用一份（舊三份逐字相同，只差各自的 "# Path:" 檔頭）。還原內容沒有
# 任何 GPU / 平台相依性 —— 就是 psql + tar，所以放 _shared/。
#
# 可由 deploy.sh 的 `restore` action 呼叫（參數會原樣透傳），也可以直接跑。
# 主流程刻意不 source lib/common.sh：本檔在沒有 TIGER_PLATFORM 的環境下仍要能
# 跑完（lib 在該情況會直接 ERROR + exit）。需要 tiger_compose 的地方（停／啟
# 服務）改在**子 shell 內**才 source lib —— 見 compose_in_module()。
# =====================================================================

set -eo pipefail

# --- 0) Configuration ---
# 路徑一律以本檔位置推導，不依賴 CWD。本檔位於
# <stack>/08-backup-recovery/resource/_shared/，因此 ../.. 是模組目錄、
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
# ⚠️ CRLF 與 `export $(… | xargs)` 的坑同 backup-tigerai.sh，說明見該檔。
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
# 都是 ${PG_USER:-adm} / ${PG_DB_NAME:-tigerai}）。沒有預設值時 .env 不存在會
# 展開成空字串，psql -U '' 的錯誤訊息指不到根因。
PG_USER=${PG_USER:-adm}
PG_DB_NAME=${PG_DB_NAME:-tigerai}
# Service name on ai_stack_net (same default as every module's compose file). Used
# only by the post-restore password check, which must go over TCP — see
# verify_pg_password().
PG_HOST=${PG_HOST:-postgres}
# DATA_DIRS unset -> back up everything under BASE_DIR (space-separated list to narrow)
DATA_DIRS=${DATA_DIRS:-"$BASE_DIR"}

BACKUP_ROOT=${BACKUP_ROOT:-"/opt/tigerai/backups"}

# The prefix is evaluated at call time, so setting it after the source works.
# Kept after the env cascade so this file's value still beats any .env.
# on_exit() / report_abort() also read this directly (hand-written echoes, not
# LOG/WARN/ERROR), so only this one name is used — keeping a LOG_PREFIX alias
# too would let the two drift apart.
TIGER_LOG_PREFIX="TigerAI Restore"

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

# Escape hatch for the preflight gate below: `dropdb --force` (= DROP DATABASE …
# WITH FORCE, PG 13+; this stack pins postgres:17-alpine in 02-database and in all
# three .env examples). Off by default — with the stop/start handling below there
# should be nothing left to terminate, so needing this means something the script
# does not know about is still connected.
FORCE_DROP=${FORCE_DROP:-0}

usage() {
    echo "Usage: sudo $0 [-y] [--force] [backup_date_folder] {all | db | data}"
    echo "Example: sudo $0 20260202_120000 all"
    echo "  -y / ASSUME_YES=1  skip the overwrite confirmation (non-interactive)"
    echo "  --force            let dropdb terminate any remaining client connections"
    echo "                     instead of aborting (see the preflight gate)"
    echo ""
    echo "Available backups in $BACKUP_ROOT:"
    ls -1 "$BACKUP_ROOT" 2>/dev/null || echo "  (None found)"
    exit 1
}

# --- Validation ---
[ "$(id -u)" -ne 0 ] && ERROR "Please run with sudo."
# Flags may be given in any order; the first non-flag argument ends the loop.
while [ $# -gt 0 ]; do
    case "$1" in
        -y)      ASSUME_YES=1; shift ;;
        --force) FORCE_DROP=1;  shift ;;
        *)       break ;;
    esac
done
[ $# -lt 2 ] && usage

RESTORE_DIR="${BACKUP_ROOT}/$1"
TARGET=$2

[ ! -d "$RESTORE_DIR" ] && ERROR "Backup directory $RESTORE_DIR does not exist."

# --- Stop / start the containers that hold PostgreSQL connections ---------------
# Every service listed here opens a pooled connection to postgres and reconnects
# on its own, so it must be down for the whole restore: `dropdb` fails while any
# client session exists. postgres itself is NEVER in this list — the restore runs
# through it. pgadmin is: it lives in the same 02-database module as postgres and
# survives "stop the app containers", and its idle sessions block dropdb just as
# much (CountOtherDBBackends() counts connections regardless of state).
#
# openwebui-migrate is deliberately absent: it is a one-shot alembic container
# that exits as soon as it finishes, and `compose ps -q` only lists running
# containers, so an entry for it would be a no-op on every restore.
PG_CLIENT_SERVICES=(
    "02-database-postgres-pgadmin|pgadmin"
    "03-ai-interface-ollama-openwebui-redis|openwebui-main"
    "04-automation-n8n|n8n-main"
    "04-automation-n8n|n8n-worker"
    "10-observability-grafana|grafana"
)
# "<module>|<service>" entries this run actually stopped (so only those get started
# again — a service the operator had already stopped stays stopped).
STOPPED_SERVICES=()
# Counters, because "STOPPED_SERVICES is empty" has two very different meanings:
# nothing was running, or every stop failed. The second is the key clue when the
# preflight gate then refuses, so the two must not print the same line.
STOP_ATTEMPTED=0
STOP_FAILED=0

# Run a compose command against another module. lib/common.sh is sourced **inside
# the subshell**, so its `set -Eeo pipefail`, ERR trap and LOG/WARN/ERROR stay
# there and the main script keeps working without TIGER_PLATFORM. Same trick as
# vram-purge-common.sh, which restarts other modules' services the same way.
# A bare `docker compose` is not an option: modules have no docker-compose.yaml,
# only docker-compose.base.yaml + the platform overlay, which tiger_compose stacks
# together along with the --env-file chain.
compose_in_module() {
    local module="$1"; shift
    (
        TIGER_MODULE_DIR="${STACK_DIR}/${module}"
        TIGER_LOG_PREFIX="TigerAI Restore"
        # shellcheck source=../../../lib/common.sh
        source "${STACK_DIR}/lib/common.sh"
        tiger_compose "$@"
    )
}

stop_pg_clients() {
    # Without TIGER_PLATFORM there is no way to pick the right overlay, so we do
    # not touch any container — the script stays runnable standalone (cron, a
    # recovery shell) and the preflight gate still refuses if clients are live.
    if [ -z "${TIGER_PLATFORM:-}" ]; then
        WARN "TIGER_PLATFORM is not set; this run will NOT stop or start any container. Stop the PostgreSQL clients yourself (including pgadmin, but not '$PG_CONTAINER'), or re-run via: sudo -E TIGER_PLATFORM={amd|nvidia|arm64} bash ${MODULE_DIR}/deploy.sh restore ..."
        return 0
    fi

    LOG "Stopping the containers that hold PostgreSQL connections..."
    local entry module svc ids
    for entry in "${PG_CLIENT_SERVICES[@]}"; do
        module="${entry%%|*}"; svc="${entry#*|}"
        [ -f "${STACK_DIR}/${module}/docker-compose.base.yaml" ] || continue
        # `ps -q` lists running containers only, so a service the operator already
        # stopped is left alone and is not started again at the end.
        if ! ids=$(compose_in_module "$module" ps -q "$svc" 2>/dev/null); then
            WARN "Could not query '${svc}' in ${module}; leaving it alone."
            continue
        fi
        [ -z "$ids" ] && continue
        LOG "  stopping ${module} / ${svc}"
        STOP_ATTEMPTED=$((STOP_ATTEMPTED + 1))
        if compose_in_module "$module" stop "$svc"; then
            STOPPED_SERVICES+=("${module}|${svc}")
        else
            # Not fatal on its own: the preflight gate below is what actually
            # decides whether the restore may proceed.
            STOP_FAILED=$((STOP_FAILED + 1))
            WARN "Failed to stop ${module}/${svc}."
        fi
    done
    if [ "$STOP_ATTEMPTED" -eq 0 ]; then
        LOG "  (nothing was running that needed stopping)"
    elif [ "$STOP_FAILED" -gt 0 ]; then
        WARN "  ${STOP_FAILED} of ${STOP_ATTEMPTED} container(s) could NOT be stopped and are still running; the preflight gate below decides whether the restore may proceed."
    fi
    return 0
}

start_pg_clients() {
    LOG "Starting the containers stopped for this restore..."
    local i entry module svc rc=0
    for (( i=${#STOPPED_SERVICES[@]}-1; i>=0; i-- )); do
        entry="${STOPPED_SERVICES[$i]}"
        module="${entry%%|*}"; svc="${entry#*|}"
        LOG "  starting ${module} / ${svc}"
        compose_in_module "$module" start "$svc" || rc=1
    done
    return "$rc"
}

# Copy-pasteable commands for whatever we stopped, printed when we cannot (or must
# not) start the services ourselves. TIGER_COMPOSE_DRY_RUN makes tiger_compose
# print the exact `docker compose -f … --env-file …` line instead of running it,
# so the hint can never drift from what the stack actually uses.
print_restart_hint() {
    local entry module svc
    echo "  Restart the stopped containers with:"
    for entry in "${STOPPED_SERVICES[@]}"; do
        module="${entry%%|*}"; svc="${entry#*|}"
        printf '    '
        TIGER_COMPOSE_DRY_RUN=1 compose_in_module "$module" start "$svc" 2>/dev/null || \
            echo "docker compose (module ${module}, service ${svc}) start"
    done
}

# --- Progress tracking (for the abort report) ---------------------------------
# Populated by restore_db so the EXIT trap can say what state the cluster is in.
DB_TARGETS=()      # every database this run intends to restore
DB_RESTORED=()     # databases whose dump finished loading
DB_IN_FLIGHT=""    # the database being restored right now
# ""        untouched (dropdb not run yet, or dropdb failed -> the DB is intact)
# "dropped"  dropdb done, createdb not -> the DB does not exist at all
# "empty"    dropped+re-created, dump not loaded yet -> the DB exists but is empty
DB_IN_FLIGHT_STATE=""
# 0 = 沒跑到；1 = 載入中斷（無 ON_ERROR_STOP 且每句自動 commit，套用到哪裡未知、
# 無法回滾）；2 = 完整載入。1 與 2 都代表 roles／密碼已被動過，所以中止報告不能說
# 「什麼都沒變」，但兩者的確定程度不同，措辭要分開。
GLOBALS_APPLIED=0

# "a, b, c" — built by hand because "${*}" with IFS=', ' only uses the first IFS
# character as the separator.
join_list() {
    [ "$#" -eq 0 ] && { echo "(none)"; return; }
    local out="$1" x; shift
    for x in "$@"; do out="${out}, ${x}"; done
    echo "$out"
}

# shellcheck disable=SC2031  # RED/NC 也被 compose_in_module 的子 shell 內那份
# lib/common.sh 指派，但兩邊是同樣的字面值，這裡讀到的一定是本檔頂端定義的那份。
report_abort() {
    local db t pending=()
    for db in "${DB_TARGETS[@]}"; do
        for t in ${DB_RESTORED[@]+"${DB_RESTORED[@]}"}; do
            [ "$db" = "$t" ] && continue 2
        done
        pending+=("$db")
    done

    echo ""
    echo -e "${RED}RESTORE ABORTED${NC}"
    echo "  已還原：$(join_list ${DB_RESTORED[@]+"${DB_RESTORED[@]}"})"
    echo "  未還原：$(join_list ${pending[@]+"${pending[@]}"})"
    # 三個中斷點各自對應不同的現場狀態，不能合併：dropdb 與 createdb 之間失敗時
    # 資料庫「已經不存在」，說成「仍是還原前的資料」是反向說謊。
    local damaged=0 advice="排除上面的錯誤後重跑"
    if [ -n "$DB_IN_FLIGHT" ]; then
        case "$DB_IN_FLIGHT_STATE" in
            empty)
                echo "  → ${DB_IN_FLIGHT} 目前是空庫（已 drop+create 但 psql 載入失敗）"
                advice="檢查備份檔完整性後重跑"
                damaged=1 ;;
            dropped)
                echo "  → ${DB_IN_FLIGHT} 已被 drop 且尚未重建，目前不存在（createdb 失敗）"
                advice="排除 createdb 失敗的原因（殘留連線／磁碟空間等）後重跑，重跑會把該庫建回來"
                damaged=1 ;;
            *)
                echo "  → ${DB_IN_FLIGHT} 尚未被 drop（dropdb 未執行或失敗），仍是還原前的資料" ;;
        esac
    fi
    if [ "${#pending[@]}" -eq 0 ]; then
        echo "  → 所有資料庫都已還原；失敗發生在資料庫還原之後（資料目錄階段）"
    fi
    if [ "${#DB_RESTORED[@]}" -eq 0 ] && [ "$damaged" -eq 0 ]; then
        # 沒有任何資料庫被 drop（gate 擋下、dropdb 失敗、或 globals 階段就掛了）。
        echo "  → 尚未有任何資料庫被 drop"
        if [ "$GLOBALS_APPLIED" -eq 1 ]; then
            # globals 刻意不帶 ON_ERROR_STOP（見 restore_db 的註解），每句 CREATE ROLE /
            # ALTER ROLE 各自 autocommit —— 所以真正特別的不是「密碼被改」（那是還原的
            # 正常語意），而是「套用到哪裡未知」。密碼本身由 verify_pg_password 實測。
            echo "  → 但 globals 載入中斷，已套用到哪裡無法確定，也無法回滾"
        elif [ "$GLOBALS_APPLIED" -eq 2 ]; then
            echo "  → 但 globals 已完整還原：roles／密碼已回捲成備份當時的值（還原的正常語意）"
        else
            echo "  → 叢集仍是還原前的狀態"
        fi
    fi
    echo "  → 建議：${advice}"
}

# --- Post-restore password check ----------------------------------------------
# Restoring globals rolls every role back to its backup-time password. That is the
# normal semantics of a restore — the password is part of cluster state — but if
# PG_PASS in .env was changed after the backup was taken, every service will now
# fail to authenticate. That question has an objective answer, so we answer it
# instead of telling the operator to "please check".
#
# ⚠️ The connection MUST go over TCP to $PG_HOST. The rest of this script uses
#    `docker exec … psql -U "$PG_USER"` over the container's local socket, which
#    the official image sets to trust — a check built on that would pass no matter
#    what the password is. The entrypoint appends `host all all all <method>` to
#    pg_hba.conf (scram-sha-256 unless POSTGRES_HOST_AUTH_METHOD says otherwise),
#    and $PG_HOST resolves to the container's network address, so this path really
#    does authenticate.
#
# The password is fed through stdin, never as an argument: `docker exec -e
# PGPASSWORD=…` would expose it in the host's process list.
pg_try_connect() {
    printf '%s\n' "$1" | docker exec -i "$PG_CONTAINER" sh -c '
        IFS= read -r pw
        PGPASSWORD="$pw" psql -h "$0" -U "$1" -d postgres -tAc "SELECT 1" >/dev/null
    ' "$PG_HOST" "$PG_USER" 2>&1
}

verify_pg_password() {
    [ "$GLOBALS_APPLIED" -ge 1 ] || return 0

    if [ "$GLOBALS_APPLIED" -eq 2 ]; then
        LOG "globals 已還原，'${PG_USER}' 的密碼現在是【備份當時】的值（還原的正常語意）。以 .env 的 PG_PASS 實測連線中..."
    else
        LOG "globals 載入中斷，'${PG_USER}' 的密碼可能已回捲成【備份當時】的值（套用到哪裡未知）。以 .env 的 PG_PASS 實測連線中..."
    fi
    if [ -z "${PG_PASS:-}" ]; then
        WARN "PG_PASS 未在 env 中設定，無法實測；請自行確認 '${PG_USER}' 的密碼與服務設定一致。"
        return 0
    fi

    local out rc=0
    out=$(pg_try_connect "$PG_PASS") || rc=$?
    if [ "$rc" -ne 0 ]; then
        if printf '%s' "$out" | grep -qiE 'password authentication failed|no password supplied|authentication failed'; then
            WARN "'${PG_USER}' 現在的密碼與 .env 的 PG_PASS 不符（實際試連被拒）。二選一修復："
            echo "    1) 把 .env 的 PG_PASS 改回備份當時的值，再重啟相關服務"
            echo "    2) 把叢集密碼改成 .env 現在的值（自行填入，不要從 log 複製）："
            echo "       docker exec -it ${PG_CONTAINER} psql -U ${PG_USER} -d postgres -c \"ALTER ROLE ${PG_USER} PASSWORD '<你 .env 裡的 PG_PASS>'\""
        else
            # 連不上、DNS 解析不到、容器已停 …… 都不是「密碼不符」，不要誤報。
            WARN "密碼檢查無法完成（不是認證失敗）：${out}"
        fi
        return 0
    fi

    # 檢查自身的有效性檢查：故意用錯的密碼再連一次。如果連錯密碼都能過，代表這條
    # 連線路徑根本不驗密碼（pg_hba 是 trust），此時「通過」不能當成保證。
    if pg_try_connect "tigerai-restore-deliberately-wrong-$$" >/dev/null 2>&1; then
        WARN "這條連線路徑不驗證密碼（pg_hba 對 ${PG_HOST} 是 trust），因此無法判定 '${PG_USER}' 的密碼是否與服務設定一致，請自行確認。"
    else
        LOG "密碼檢查通過：.env 的 PG_PASS 可以通過密碼認證連上 '${PG_USER}'。"
    fi
}

# Failure must not leave the services down and silent. Success starts them again;
# failure prints the state report plus the restart commands and keeps the non-zero
# exit code — deliberately not an automatic restart, which would make a failed
# restore look like it went fine.
# shellcheck disable=SC2031  # 同 report_abort：顏色變數在子 shell 內被重新指派成
# 相同的字面值，本函式讀到的仍是本檔頂端那份。
on_exit() {
    local rc=$?
    # 兩條路徑都跑密碼實測：成功時密碼一定被回捲；失敗時 globals 可能只套用一半，
    # 實測結果反而更有價值。verify_pg_password 自己判斷 globals 有沒有跑過，
    # 沒跑過就完全沉默。它永遠回 0 —— 密碼不符不是「還原失敗」，資料已經在位了，
    # 把退出碼改成 1 會讓 cron／master 把一次成功的還原記成失敗，
    # 也會讓下面的服務啟動被跳過。
    if [ "$rc" -eq 0 ]; then
        verify_pg_password
        if [ "${#STOPPED_SERVICES[@]}" -gt 0 ]; then
            if ! start_pg_clients; then
                echo -e "${RED}[$TIGER_LOG_PREFIX ERROR]${NC} Restore finished but some containers failed to start." >&2
                print_restart_hint >&2
                exit 1
            fi
        fi
        return 0
    fi
    [ "${#DB_TARGETS[@]}" -gt 0 ] && report_abort >&2
    verify_pg_password >&2
    if [ "${#STOPPED_SERVICES[@]}" -gt 0 ]; then
        echo -e "${YELLOW}[$TIGER_LOG_PREFIX WARN]${NC} The containers below are still STOPPED — restore failed, so they are left down on purpose." >&2
        print_restart_hint >&2
    fi
    exit "$rc"
}
trap on_exit EXIT

# --- Preflight: no client may hold a connection to a database we are about to drop ---
# `dropdb` on a database with live sessions fails ("is being accessed by other
# users"), and under `set -eo pipefail` that aborts the restore loop **mid-way**:
# the databases already processed are back at backup state, the rest are still
# live, and there is no rollback. Because the loop walks db_*.sql.gz in glob
# (dictionary) order, the realistic case is db_grafana finishing before db_n8n
# trips on the still-connected n8n-main/-worker.
#
# Checking every target up front turns that half-restore into a clean no-op abort
# — nothing has been dropped yet when we bail.
#
# Deliberately a gate rather than pg_terminate_backend: the app containers run
# `restart: always` with reconnecting pools, so a terminated backend is back
# before dropdb runs and the same failure recurs, just less predictably.
# Terminating is only safe once the services are down — at which point there is
# nothing left to terminate.
assert_no_active_connections() {
    local targets=("$@")
    local busy db cnt t
    local conflicts=()

    # Query every connected database and intersect in bash, so no target name is
    # ever interpolated into SQL. pg_backend_pid() excludes this very session
    # (it connects to 'postgres', which is never a restore target, but the
    # restore must not be able to trip over its own connection).
    #
    # backend_type = 'client backend' filters out autovacuum workers, which do
    # carry a datname and would otherwise trip the gate as a transient false
    # positive — DROP DATABASE actually succeeds against them, because
    # CountOtherDBBackends() SIGTERMs autovacuum workers and retries for 5s.
    # Only real clients block the drop. (backend_type exists since PG 10; this
    # stack pins postgres:17-alpine in 02-database and all three .env examples.)
    if ! busy=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -tA -F'|' -c \
        "SELECT datname, count(*) FROM pg_stat_activity
          WHERE datname IS NOT NULL AND pid <> pg_backend_pid()
            AND backend_type = 'client backend'
          GROUP BY datname"); then
        ERROR "Could not query pg_stat_activity on '$PG_CONTAINER'; refusing to restore blind."
    fi

    while IFS='|' read -r db cnt; do
        [ -z "$db" ] && continue
        for t in "${targets[@]}"; do
            [ "$db" = "$t" ] && conflicts+=("${db} (${cnt} active connection(s))")
        done
    done <<< "$busy"

    if [ "${#conflicts[@]}" -gt 0 ]; then
        WARN "These databases are scheduled to be dropped but still have live clients:"
        for t in "${conflicts[@]}"; do echo "    - ${t}"; done
        if [ "$FORCE_DROP" = "1" ]; then
            # Explicit escape hatch. Logged loudly with the exact connection counts
            # so "which sessions did we kill" is answerable from the transcript.
            WARN "--force given: dropdb --force (DROP DATABASE … WITH FORCE) will TERMINATE the client connections listed above instead of aborting."
            return 0
        fi
        # pgAdmin is called out explicitly: it lives in the same 02-database module
        # as postgres itself and is `restart: always`, so it survives "stop the app
        # containers" — and an idle pgAdmin session still blocks dropdb, because
        # CountOtherDBBackends() counts connections regardless of their state.
        ERROR "Refusing to restore: dropdb would fail part-way through and leave a partially restored system with no way back. Stop whatever still holds these connections — including pgAdmin, whose idle sessions block dropdb just as much — but keep '$PG_CONTAINER' running, then re-run. To terminate them instead, re-run with --force."
    fi
    LOG "Preflight OK: no live clients on the databases to be restored."
}

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
    # Gate before the confirmation prompt, so the operator is not asked to type
    # 'yes' only to be turned away afterwards.
    if [ "$has_legacy" -eq 1 ]; then
        DB_TARGETS=("$PG_DB_NAME")
        assert_no_active_connections "$PG_DB_NAME"
    else
        DB_TARGETS=("${dbs[@]}")
        assert_no_active_connections "${dbs[@]}"
    fi

    confirm "Drop and re-create the databases listed above?"

    # Roles/tablespaces live outside any single database, so the per-DB dumps do
    # not contain them and must be re-created first: every dump's
    # `GRANT ... TO <role>` fails if the role does not exist yet.
    # No ON_ERROR_STOP on purpose — pg_dumpall re-emits CREATE ROLE for roles
    # that already exist (notably "$PG_USER", which initdb recreates from
    # POSTGRES_USER), which errors harmlessly while the following ALTER ROLE
    # still applies.
    local globals="${RESTORE_DIR}/globals.sql.gz"
    if [ -f "$globals" ]; then
        LOG "Restoring global objects (roles, tablespaces) from globals.sql.gz..."
        # The dump's ALTER ROLE carries each role's password, so the roles are rolled
        # back together with everything else. That is what a restore means, not a
        # defect (--no-role-passwords would avoid it only by dropping every password).
        # The end of the run re-checks it for real — see verify_pg_password().
        WARN "這會把 '${PG_USER}' 的密碼一併回捲成【備份當時】的值 —— 密碼也是叢集狀態的一部分，這是還原的正常語意。若備份之後改過 .env 的 PG_PASS，還原結束時的實測會告訴你，並印出修復指令。"
        GLOBALS_APPLIED=1
        gunzip -c "$globals" | docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d postgres
        GLOBALS_APPLIED=2
    else
        WARN "No globals.sql.gz in $RESTORE_DIR (backup predates globals support); roles are NOT restored. Any GRANT to a role other than '${PG_USER}' will fail below."
    fi

    # --force only reaches dropdb when the operator asked for it on the command line.
    local dropdb_opts=(-U "$PG_USER" --if-exists)
    if [ "$FORCE_DROP" = "1" ]; then
        dropdb_opts+=(--force)
        LOG "dropdb will run with --force."
    fi

    # DB_IN_FLIGHT / DB_IN_FLIGHT_STATE feed the abort report: between dropdb and a
    # finished psql load the database exists but is empty, and that is exactly the
    # state the operator cannot see from the last error line alone.
    if [ "$has_legacy" -eq 1 ]; then
        LOG "Restoring legacy dump into '${PG_DB_NAME}'..."
        DB_IN_FLIGHT="$PG_DB_NAME"; DB_IN_FLIGHT_STATE=""
        docker exec "$PG_CONTAINER" dropdb "${dropdb_opts[@]}" "$PG_DB_NAME"
        DB_IN_FLIGHT_STATE="dropped"
        docker exec "$PG_CONTAINER" createdb -U "$PG_USER" "$PG_DB_NAME"
        DB_IN_FLIGHT_STATE="empty"
        gunzip -c "$legacy" | docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" "$PG_DB_NAME"
        DB_RESTORED+=("$PG_DB_NAME"); DB_IN_FLIGHT=""; DB_IN_FLIGHT_STATE=""
    else
        for db in "${dbs[@]}"; do
            file="${RESTORE_DIR}/db_${db}.sql.gz"
            LOG "Restoring '${db}' from $(basename "$file")..."
            DB_IN_FLIGHT="$db"; DB_IN_FLIGHT_STATE=""
            docker exec "$PG_CONTAINER" dropdb "${dropdb_opts[@]}" "$db"
            DB_IN_FLIGHT_STATE="dropped"
            docker exec "$PG_CONTAINER" createdb -U "$PG_USER" "$db"
            DB_IN_FLIGHT_STATE="empty"
            gunzip -c "$file" | docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" "$db"
            DB_RESTORED+=("$db"); DB_IN_FLIGHT=""; DB_IN_FLIGHT_STATE=""
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

    # State of play, not a to-do: stop_pg_clients() already ran. It only stops the
    # PostgreSQL clients, so anything else that writes under these paths (ollama,
    # qdrant, …) is still up and has to be handled by the operator.
    if [ "${#STOPPED_SERVICES[@]}" -eq 0 ]; then
        WARN "This will OVERWRITE existing data at the following paths. No container was stopped by this run — stop whatever writes to them first:"
    elif [ "$STOP_FAILED" -gt 0 ]; then
        WARN "This will OVERWRITE existing data at the following paths. ${#STOPPED_SERVICES[@]} PostgreSQL client(s) are stopped, but ${STOP_FAILED} could NOT be stopped (see the warnings above) and other containers (ollama, qdrant, …) were never touched — stop them yourself if they write to these paths:"
    else
        WARN "This will OVERWRITE existing data at the following paths. The PostgreSQL clients listed above are stopped for the duration of this restore; other containers (ollama, qdrant, …) are still running — stop them yourself if they write to these paths:"
    fi
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
# Before anything destructive: the DB clients must be down for dropdb to work, and
# the data archives are extracted over directories those same containers write to.
# on_exit() starts them again on success.
case "$TARGET" in
    all|db|data) stop_pg_clients ;;
esac
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

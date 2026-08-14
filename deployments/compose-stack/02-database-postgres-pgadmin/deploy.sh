#!/usr/bin/env bash
# =====================================================================
# TigerAI Database Deployer (Postgres / pgAdmin)
# Path: deployments/compose-stack/02-database-postgres-pgadmin/deploy.sh
#
# 三平台共用：compose 定義完全沒有平台差異，所以本模組只有
# docker-compose.base.yaml，沒有任何 docker-compose.<platform>.yaml overlay。
#
# wait_for_db / db_diagnostics 刻意留在模組裡而不是搬進 lib/common.sh：
# 那是 Postgres 專屬的診斷邏輯，只有這個模組會用到。
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # 由 lib/common.sh 的 LOG/WARN/ERROR 讀取
TIGER_LOG_PREFIX="TigerAI Database"
# lib 提供：set -Eeo pipefail + ERR trap、LOG/WARN/ERROR、env 三層載入、
#           ensure_network、tiger_compose、tiger_res
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    echo "Usage: sudo $0 {all | postgres | pgadmin | down | restart}"
    exit 1
}

[ $# -eq 0 ] && usage

# Fallback defaults (used when .env is not present or incomplete)
PG_USER=${PG_USER:-adm}
PG_DB_NAME=${PG_DB_NAME:-tigerai}
# Seconds to wait for Postgres to accept connections. First boot has to run initdb
# (with --locale-provider=icu), which on slow disks — e.g. while docker is pulling
# multi-GB images — can take several minutes. This is only a give-up ceiling: a warm
# start still returns in ~2s, so a large value costs nothing in the normal case.
PG_WAIT_TIMEOUT=${PG_WAIT_TIMEOUT:-300}

# Everything we need to tell "still doing initdb" apart from "container is dead".
db_diagnostics() {
    local waited="$1"
    {
      echo ""
      echo -e "${RED}[${TIGER_LOG_PREFIX} DIAG]${NC} Postgres not ready after ${waited}s — dumping diagnostics"
      echo -e "${YELLOW}--- effective settings ---${NC}"
      echo "PG_USER=${PG_USER}  PG_DB_NAME=${PG_DB_NAME}  PG_PORT=${PG_PORT:-<unset>}  PG_WAIT_TIMEOUT=${PG_WAIT_TIMEOUT}"
      echo -e "${YELLOW}--- docker ps -a --filter name=^postgres\$ ---${NC}"
      docker ps -a --filter 'name=^postgres$' \
        --format 'table {{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}' 2>&1 || true
      echo -e "${YELLOW}--- healthcheck (docker inspect) ---${NC}"
      docker inspect postgres --format \
        '{{if .State.Health}}Health={{.State.Health.Status}} FailingStreak={{.State.Health.FailingStreak}}
{{range .State.Health.Log}}  probe end={{.End}} exit={{.ExitCode}} out={{.Output}}
{{end}}{{else}}<container has no healthcheck>{{end}}' 2>&1 || true
      echo -e "${YELLOW}--- docker logs postgres --tail 50 ---${NC}"
      docker logs postgres --tail 50 2>&1 || true
      echo -e "${YELLOW}--------------------------------------${NC}"
    } >&2
}

wait_for_db() {
    LOG " Waiting for Postgres to be ready (timeout ${PG_WAIT_TIMEOUT}s, override with PG_WAIT_TIMEOUT)..."
    local waited=0
    until docker exec postgres pg_isready -U "$PG_USER" >/dev/null 2>&1; do
      if [ "$waited" -ge "$PG_WAIT_TIMEOUT" ]; then
        db_diagnostics "$waited"
        ERROR "Postgres failed to start: not ready after ${PG_WAIT_TIMEOUT}s (see diagnostics above)."
      fi
      sleep 2
      waited=$((waited + 2))
      # Progress feedback on one line: a dot per probe, elapsed seconds every 10s.
      if [ $((waited % 10)) -eq 0 ]; then printf ' %ss' "$waited"; else printf '.'; fi
    done
    if [ "$waited" -gt 0 ]; then echo ""; fi
    LOG " Postgres is ready (took ${waited}s)."
}

ACTION=$1
ensure_network

case "$ACTION" in
    all)
        LOG " Starting Database Stack (Postgres, pgAdmin)..."
        tiger_compose up -d
        wait_for_db
        LOG "✅ Database bootstrap completed."
        ;;
    postgres|pgadmin)
        LOG " Starting specific service: $ACTION..."
        tiger_compose up -d "$ACTION"
        [ "$ACTION" = "postgres" ] && wait_for_db
        ;;
    down)
        LOG " Stopping database services..."
        tiger_compose down --remove-orphans
        ;;
    restart)
        # 與 01-infra 一致的 restart 語意：down + up -d。
        # 舊 amd 版是 `docker compose down && $0 all`（遞迴 re-exec 自己），
        # 舊 nvidia/arm64 版是 `docker compose restart`（不會重新套用 env / compose
        # 變更，等於只是重啟行程）。這裡取 amd 的實質行為但不遞迴。
        LOG " Restarting database stack..."
        tiger_compose down --remove-orphans
        tiger_compose up -d
        wait_for_db
        ;;
    *)
        usage
        ;;
esac

LOG " Database Deployment command finished."

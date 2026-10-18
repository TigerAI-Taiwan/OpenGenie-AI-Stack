#!/usr/bin/env bash
# =====================================================================
# TigerAI Observability Deployer (Grafana / Prometheus / Loki / Alloy / exporters)
# Path: deployments/compose-stack/10-observability-grafana/deploy.sh
#
# 三份舊 deploy.sh（amd / nvidia / arm64）除了檔頭註解、啟動訊息的 GPU 字樣
# 與 arm64 多出來的 CRLF 清洗迴圈以外逐字相同（ensure_db 完全一致），
# 所以這裡只留單一份、沒有任何 shell 層的平台分支。
# compose 的平台差異（gpu-exporter / loki.command / resource 掛載）
# 全部走 docker-compose.<platform>.yaml overlay。
#
# 與舊版的行為差異（刻意）：
#   1. 舊版完全不解析參數，不管收到什麼都跑 `docker compose up -d`。
#      master-deploy.sh 的 `down` 流程會呼叫 `deploy.sh down`，舊版因此會在
#      使用者要求停機時反而把服務拉起來。這裡補上 usage/case，與 01~04 一致。
#   2. arm64 舊版的 CRLF 清洗迴圈拿掉 —— lib/common.sh 的 env 載入已經
#      逐行剝掉行尾 \r，三平台一致。
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # 由 lib/common.sh 的 LOG/WARN/ERROR 讀取
TIGER_LOG_PREFIX="TigerAI Observability"
# lib 提供：set -Eeo pipefail + ERR trap、LOG/WARN/ERROR、env 三層載入、
#           ensure_network、tiger_compose、tiger_res
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    echo "Usage: sudo $0 {all | down | restart}"
    exit 1
}

# 啟動訊息裡的 GPU exporter 字樣（舊版三份各自寫死）。
case "$TIGER_PLATFORM" in
    amd)   GPU_STACK_LABEL="ROCm" ;;
    *)     GPU_STACK_LABEL="DCGM" ;;
esac

# --- Ensure dedicated 'grafana' database exists (Grafana uses PG as backend) ---
# Mirrors k3s (GF_DATABASE_TYPE=postgres). CREATE DATABASE has no IF NOT EXISTS
# and cannot run inside a transaction, so SELECT-guard it (idempotent).
ensure_db() {
    local PG_CONTAINER="${PG_CONTAINER:-postgres}"
    local DB_USER="${PG_USER:-adm}"
    local DB_PASS="${PG_PASS:-CHANGE_ME}"
    local DB_NAME="${GF_DB_NAME:-grafana}"

    LOG " Ensuring dedicated PostgreSQL database '$DB_NAME' for Grafana..."
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container '$PG_CONTAINER' not found. Please deploy the database stack first."
    fi

    local DB_EXISTS
    DB_EXISTS=$(docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_PASS" \
        psql -U "$DB_USER" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';" 2>/dev/null || true)

    if [ "$DB_EXISTS" = "1" ]; then
        LOG " Database '$DB_NAME' already exists — skipping creation."
    else
        LOG " Creating database '$DB_NAME' (owner $DB_USER)..."
        docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_PASS" \
            psql -U "$DB_USER" -d postgres \
            -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" \
            || ERROR "Failed to create database '$DB_NAME'."
        LOG " Database '$DB_NAME' created."
    fi
}

# GPU metrics come from the platform's official exporter container
# (amd: rocm/device-metrics-exporter:5000, nvidia/arm64: dcgm-exporter:9400),
# scraped by the 'gpu-metrics' Prometheus job — no host-side rocm-smi collector
# / cron / node-exporter textfile plumbing is needed.

# prometheus.yml / alloy-config.alloy are single-file bind mounts, and `up -d`
# compares only the service definition, not the source file's content. After a
# config edit it decides nothing needs recreating, and the container keeps the
# config it read at start-up without reporting anything. Compare hashes and
# restart only when they really differ; equal means leave it, so a deploy does
# not drop connections every time.
#
# Usage: restart_if_config_changed <container> <host file> <path in container>
restart_if_config_changed() {
    local ctr="$1" host_cfg="$2" ctr_path="$3"
    local host_sum ctr_sum
    host_sum=$(sha256sum "$host_cfg" | awk '{print $1}')
    # Blind spot: an in-place rewrite (same inode) shows the new content inside
    # the container, so the hashes match and nothing restarts, while the process
    # still holds the old config in memory.
    # The `|| true` is required: without it a failing docker exec fires the ERR
    # trap inside the command substitution (`set -E` makes subshells inherit it)
    # and prints a false [FAILED].
    ctr_sum=$({ docker exec "$ctr" sha256sum "$ctr_path" 2>/dev/null || true; } | awk '{print $1}')

    if [ -z "$ctr_sum" ]; then
        # Container not running (first deploy / an earlier step failed): nothing
        # to restart. Running but unreadable means the mounted inode is stale and
        # only a restart picks up the new file. Neither should abort the deploy.
        if docker ps --format '{{.Names}}' | grep -qx "$ctr"; then
            LOG " ${ctr}: $(basename "$host_cfg") is unreadable inside the container (stale mount inode), restarting..."
            docker restart "$ctr" >/dev/null || WARN "docker restart ${ctr} failed; restart it by hand to apply the new config."
        else
            LOG " ${ctr} is not running; skipping the config comparison."
        fi
        return 0
    fi

    if [ "$host_sum" = "$ctr_sum" ]; then
        LOG " ${ctr}: $(basename "$host_cfg") matches the container — no restart needed."
    else
        LOG " ${ctr}: $(basename "$host_cfg") has changed, restarting..."
        docker restart "$ctr" >/dev/null || WARN "docker restart ${ctr} failed; restart it by hand to apply the new config."
    fi
}

[ $# -eq 0 ] && usage

ACTION=$1
# Missing values must be caught before any docker action; `down` is not checked,
# so a host in this state can still be stopped.
case "$ACTION" in
    all|restart) bash "${SCRIPT_DIR}/pre-deploy.sh" || exit $? ;;
esac
ensure_network

case "$ACTION" in
    all)
        LOG " Launching Observability Stack (Grafana/Prometheus/${GPU_STACK_LABEL})..."
        ensure_db
        LOG " Pulling images and starting containers (first run downloads several GB — this can take a few minutes depending on network and disk speed)..."
        tiger_compose up -d
        # restart) needs none of this: down + up recreates the containers anyway.
        # alloy-config.alloy exists only in resource/_shared/; tiger_res falls back to it.
        restart_if_config_changed prometheus "$(tiger_res prometheus.yml)" /etc/prometheus/prometheus.yml
        restart_if_config_changed alloy "$(tiger_res alloy-config.alloy)" /etc/alloy/config.alloy
        LOG " Observability stack is up. Access Grafana at http://localhost:${GRAFANA_PORT:-3000} (User: admin / Pass: ${GRAFANA_PASS:-CHANGE_ME})"
        ;;
    down)
        LOG " Stopping Observability services..."
        tiger_compose down --remove-orphans
        ;;
    restart)
        # 與 01-infra / 02-database / 03-ai-interface 一致的 restart 語意：down + up -d。
        LOG " Restarting Observability Stack..."
        ensure_db
        tiger_compose down --remove-orphans
        tiger_compose up -d
        LOG " Observability stack is up. Access Grafana at http://localhost:${GRAFANA_PORT:-3000} (User: admin / Pass: ${GRAFANA_PASS:-CHANGE_ME})"
        ;;
    *)
        usage
        ;;
esac

LOG " Observability Deployment command finished."

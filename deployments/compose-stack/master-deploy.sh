#!/usr/bin/env bash
# =====================================================================
# TigerAI Compose Stack Master Deployer
# Path: deployments/compose-stack/master-deploy.sh
#
# One deployer for all three platforms. The platform is selected by
# TIGER_PLATFORM (amd | nvidia | arm64), normally set by
# deployments/tiger-deploy.sh.
#
# Merged from the three former per-platform master-deploy.sh scripts.
# Where they disagreed, the union was taken:
#   - `restart` existed only in arm64            -> kept
#   - `restore` existed only in amd / nvidia     -> kept
#   - `clean` iterated forwards in amd / nvidia and backwards in arm64
#     -> backwards, so services come down before their dependencies
#   - arm64 checked `uname -m`                   -> generalized below into a
#     TIGER_PLATFORM vs. detected-hardware cross-check
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="Master"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Check privileges
[ "$(id -u)" -ne 0 ] && ERROR "Please run this script with sudo"

# Warn when TIGER_PLATFORM disagrees with the hardware actually present.
# This replaces arm64's `uname -m` check and covers all three platforms.
# It only warns: a user may legitimately stage a deployment on other hardware.
tiger_check_platform_matches_host() {
    local arch; arch="$(uname -m)"
    case "$TIGER_PLATFORM" in
        arm64)
            [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] || \
                WARN "TIGER_PLATFORM=arm64 but the host reports $arch. This stack may not work here."
            ;;
        nvidia)
            command -v nvidia-smi >/dev/null 2>&1 || \
                WARN "TIGER_PLATFORM=nvidia but nvidia-smi was not found."
            ;;
        amd)
            command -v rocm-smi >/dev/null 2>&1 || \
                WARN "TIGER_PLATFORM=amd but rocm-smi was not found."
            ;;
    esac
}
tiger_check_platform_matches_host

# Deployment steps, in order.
# NOTE: 09 runs before 08 deliberately — the backup module's cron setup expects
# the monitoring module to already exist. This ordering came from all three
# pre-merge stacks and is preserved as-is.
DEPLOY_STEPS=(
    "00-system-setup-gpu-driver-and-docker"
    "01-infra-webssh-portainer"
    "02-database-postgres-pgadmin"
    "03-ai-interface-ollama-openwebui-redis"
    "04-automation-n8n"
    "05-rag-stack-docling-qdrant-mosquitto"
    "06-ai-core-lemonade"
    "07-validation-stack"
    "09-monitoring-alerting"
    "08-backup-recovery"
    "10-observability-grafana"
)

# check-health.sh lives under the validation module's resource/ tree, so it is
# resolved through tiger_res rather than by a fixed path. Pointing
# TIGER_MODULE_DIR at that module is required — tiger_res reads it.
tiger_validation_script() {
    local saved="$TIGER_MODULE_DIR" path
    TIGER_MODULE_DIR="${SCRIPT_DIR}/07-validation-stack"
    path="$(tiger_res check-health.sh)"
    TIGER_MODULE_DIR="$saved"
    printf '%s\n' "$path"
}

usage() {
    echo "Usage: sudo $0 {init | all | restart | system | app | status | test | backup | restore | clean}"
    echo ""
    echo "  init   : Install the GPU driver if needed (prompts for reboot), then run the hardware advisor"
    echo "  all    : Full deployment, phase 00 through 10"
    echo "  restart: Restart every module in the stack"
    echo "  system : Phase 00 system initialization (GPU driver + Docker)"
    echo "  app    : Application layer only, phase 01 onwards"
    echo "  status : Show container status"
    echo "  test   : Run the system-wide health check"
    echo "  backup : Run the system-wide data backup"
    echo "  restore: Run the system-wide data restore"
    echo "  clean  : Stop and remove all Compose-managed containers"
    echo ""
    echo "  Platform: TIGER_PLATFORM=${TIGER_PLATFORM}"
}

# Ensure the base data directory exists and is owned by the invoking user
REAL_USER="${SUDO_USER:-wrt}"
BASE_DIR="${BASE_DIR:-/home/wrt/TigerAI}"
mkdir -p "$BASE_DIR"
chown "$REAL_USER":"$REAL_USER" "$BASE_DIR"

# Hardware tuning profile.
# lib/common.sh has already loaded <stack>/tiger-tuning.env if it exists, so
# this only supplies conservative fallbacks when the advisor has not run.
if [ -f "${SCRIPT_DIR}/tiger-tuning.env" ]; then
    LOG "Optimization profile detected, parameters injected"
else
    WARN "No tuning profile found — falling back to conservative defaults"
    export TIGER_OPTIMIZATION_PROFILE="CONSERVATIVE"
    TIGER_CPU_THREADS=$(( $(nproc) / 2 ))
    [ "$TIGER_CPU_THREADS" -lt 1 ] && TIGER_CPU_THREADS=1
    export TIGER_CPU_THREADS
    export TIGER_N8N_WORKERS=2
    export TIGER_LOG_MAX_SIZE="10m"
fi

run_step() {
    local folder="$1"
    local action="${2:-all}"
    local dir="${SCRIPT_DIR}/${folder}"

    if [ ! -d "$dir" ]; then
        WARN "Directory not found: $folder, skipping"
        return 0
    fi

    LOG ">>> Processing module: $folder (action: $action)"
    if [ -f "${dir}/deploy.sh" ]; then
        # -E preserves TIGER_PLATFORM across the sudo boundary
        sudo -E bash "${dir}/deploy.sh" "$action"
        return 0
    fi

    if [ -f "${dir}/docker-compose.base.yaml" ]; then
        WARN "No deploy.sh in $folder, driving compose directly"
        # tiger_compose reads TIGER_MODULE_DIR, so point it at this module.
        # It is not exported, so this only affects the current shell.
        local saved="$TIGER_MODULE_DIR"
        TIGER_MODULE_DIR="$dir"
        if [ "$action" = "restart" ]; then
            tiger_compose restart
        else
            tiger_compose up -d
        fi
        TIGER_MODULE_DIR="$saved"
        return 0
    fi

    WARN "$folder has neither deploy.sh nor docker-compose.base.yaml, skipping"
}

case "${1:-}" in
    init)
        # Driver not ready yet -> install it (idempotent), prompt for reboot, stop
        if ! nvidia-smi >/dev/null 2>&1 && ! rocm-smi >/dev/null 2>&1; then
            run_step "${DEPLOY_STEPS[0]}"
            WARN "──────────────────────────────────────────────"
            WARN " Driver installed. A reboot is REQUIRED, then re-run init:"
            WARN "   1) sudo reboot"
            WARN "   2) sudo bash master-deploy.sh init"
            WARN "   3) sudo bash master-deploy.sh all"
            WARN "──────────────────────────────────────────────"
            exit 0
        fi

        # Driver already up -> re-run system setup (idempotent), then the advisor
        run_step "${DEPLOY_STEPS[0]}"
        LOG "GPU driver active — running hardware advisor..."
        run_step "00-pre-flight-advisor"
        ;;
    all)
        for step in "${DEPLOY_STEPS[@]}"; do
            run_step "$step"
        done
        LOG "Full deployment completed"

        # Maintenance cron (daily 5:00 AM VRAM purge)
        cron_script="${SCRIPT_DIR}/08-backup-recovery/setup-cron.sh"
        if [ -f "$cron_script" ]; then
            LOG "Setting up the maintenance cron job..."
            bash "$cron_script"
        fi

        # MQTT device monitor cron (@reboot)
        mqtt_cron_script="${SCRIPT_DIR}/05-rag-stack-docling-qdrant-mosquitto/setup-cron.sh"
        if [ -f "$mqtt_cron_script" ]; then
            LOG "Setting up the MQTT device monitor cron job..."
            bash "$mqtt_cron_script"
        fi

        WARN "If this was the first run of phase 00, reboot now: sudo reboot"
        ;;
    restart)
        for step in "${DEPLOY_STEPS[@]}"; do
            run_step "$step" restart
        done
        LOG "Stack restart completed"
        ;;
    system)
        run_step "${DEPLOY_STEPS[0]}"
        LOG "System initialization completed"
        ;;
    app)
        for step in "${DEPLOY_STEPS[@]:1}"; do
            run_step "$step"
        done
        LOG "Application layer deployment completed"
        ;;
    status)
        LOG "--- container status ---"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        ;;
    test)
        bash "$(tiger_validation_script)"
        ;;
    backup)
        backup_script="${SCRIPT_DIR}/08-backup-recovery/backup-tigerai.sh"
        [ -f "$backup_script" ] || ERROR "Backup script not found: $backup_script"
        sudo -E bash "$backup_script"
        ;;
    restore)
        restore_script="${SCRIPT_DIR}/08-backup-recovery/restore-tigerai.sh"
        [ -f "$restore_script" ] || ERROR "Restore script not found: $restore_script"
        sudo -E bash "$restore_script"
        ;;
    clean)
        WARN "Stopping and removing application containers..."
        # Iterate backwards so services come down before their dependencies
        for (( i=${#DEPLOY_STEPS[@]}-1; i>=1; i-- )); do
            step="${DEPLOY_STEPS[$i]}"
            dir="${SCRIPT_DIR}/${step}"
            if [ -d "$dir" ] && [ -f "${dir}/docker-compose.base.yaml" ]; then
                saved="$TIGER_MODULE_DIR"
                TIGER_MODULE_DIR="$dir"
                tiger_compose down || true
                TIGER_MODULE_DIR="$saved"
            fi
        done
        LOG "Cleanup completed"
        ;;
    *)
        usage
        ;;
esac

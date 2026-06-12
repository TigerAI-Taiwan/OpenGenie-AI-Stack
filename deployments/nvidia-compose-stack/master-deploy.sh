#!/usr/bin/env bash
# =====================================================================
# TigerAI NVIDIA-Compose-Stack Master Deployer
# Path: deployments/nvidia-compose-stack/master-deploy.sh
# Version: v1.0.0 (TigerAI Stable)
# =====================================================================

set -eo pipefail

# Color Definitions
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

LOG_INFO() { echo -e "${GREEN}[Master INFO]${NC} $*"; }
LOG_WARN() { echo -e "${YELLOW}[Master WARN]${NC} $*"; }
LOG_ERROR() { echo -e "${RED}[Master ERROR]${NC} $*"; exit 1; }

# Check Privileges
[ "$(id -u)" -ne 0 ] && LOG_ERROR "Please run this script with sudo"

# Deployment Steps (Sequential)
DEPLOY_STEPS=(
    "00-system-setup-nvidia-docker"
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
    "11-lifecycle-wud"
)

VALIDATION_SCRIPT="./07-validation-stack/check-health.sh"

usage() {
    echo "Usage: sudo $0 {init | all | system | app | status | test | backup | clean}"
    echo ""
    echo "  init   : [Mandatory] Hardware assessment and optimization"
    echo "  all    : Execute full deployment (from Phase 00 to 12)"
    echo "  system : Execute Phase 00 system initialization (NVIDIA/Docker)"
    echo "  app    : Execute App layer deployment (Phase 01-06 & 12)"
    echo "  status : Check all container status"
    echo "  test   : Execute system-wide health check"
    echo "  backup : Execute system-wide data backup"
    echo "  restore: Execute system-wide data restore (path required)"
    echo "  clean  : Stop and remove all Compose managed containers"
}

# Ensure base data directory exists and is owned by the invoking user
REAL_USER="${SUDO_USER:-wrt}"
BASE_DIR="${BASE_DIR:-/home/wrt/TigerAI}"
mkdir -p "$BASE_DIR"
chown "$REAL_USER":"$REAL_USER" "$BASE_DIR"

# Conservativedefaults
TUNING_FILE="./00-pre-flight-advisor/tiger-tuning.env"
if [ -f "$TUNING_FILE" ]; then
    LOG_INFO " Optimization profile detected, injecting parameters..."
    export $(grep -v '^#' "$TUNING_FILE" | xargs)
else
    LOG_WARN "Detected [Conservative (Conservative)] mode"
    export TIGER_OPTIMIZATION_PROFILE="CONSERVATIVE"
    export TIGER_CPU_THREADS=$(( $(nproc) / 2 ))
    [ $TIGER_CPU_THREADS -lt 1 ] && TIGER_CPU_THREADS=1
    export TIGER_N8N_WORKERS=2
    export TIGER_LOG_MAX_SIZE="10m"
fi

run_step() {
    local folder=$1

    # AI Core Lemonade is exclusively required for AMD ROCm environments
    if [ "$folder" == "06-ai-core-lemonade" ]; then
        LOG_INFO ">>> Skipping module: $folder (Not required for non-AMD environments)"
        return 0
    fi

    if [ -d "$folder" ]; then
        LOG_INFO ">>> Processing module: $folder"
        pushd "$folder" > /dev/null
        if [ -f "./deploy.sh" ]; then
            #  all 
            sudo bash ./deploy.sh all
        elif [ -f "./docker-compose.yaml" ]; then
            LOG_WARN " $folder deploy.sh not found, falling back to docker compose up..."
            docker compose up -d
        else
            LOG_WARN " $folder has no deploy.sh or docker-compose.yaml, skipping."
        fi
        popd > /dev/null
    else
        LOG_WARN "Directory not found: $folder, skipping"
    fi
}

case "$1" in
    init)
        advisor_script="./00-pre-flight-advisor/tiger-advisor.sh"
        if [ -f "$advisor_script" ]; then
            bash "$advisor_script"
        else
            LOG_ERROR "Advisor script not found: $advisor_script"
        fi
        ;;
    all)
        for step in "${DEPLOY_STEPS[@]}"; do
            run_step "$step"
        done
        LOG_INFO " Full deployment mission completed"
        
        # Maintenance Cron
        cron_script="./08-backup-recovery/setup-cron.sh"
        if [ -f "$cron_script" ]; then
            LOG_INFO "Setting up maintenance cron job (Daily 5:00 AM VRAM Purge)..."
            bash "$cron_script"
        fi

        # MQTT Device Monitor Cron
        mqtt_cron_script="./05-rag-stack-docling-qdrant-mosquitto/setup-cron.sh"
        if [ -f "$mqtt_cron_script" ]; then
            LOG_INFO "Setting up MQTT Device Monitor cron jobs (@reboot)..."
            bash "$mqtt_cron_script"
        fi

        LOG_WARN "If first time running Phase 00, please reboot: sudo reboot: sudo reboot"
        ;;
    system)
        run_step "00-system-setup-nvidia-docker"
        LOG_INFO " System initialization completed"
        ;;
    app)
        for step in "${DEPLOY_STEPS[@]:1}"; do
            run_step "$step"
        done
        LOG_INFO " App layer deployment commands sent"
        ;;
    status)
        LOG_INFO "--- [System-wide container status check] ---"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        ;;
    test)
        if [ -f "$VALIDATION_SCRIPT" ]; then
            bash "$VALIDATION_SCRIPT"
        else
            LOG_ERROR ": $VALIDATION_SCRIPT"
        fi
        ;;
    backup)
        backup_script="./08-backup-recovery/backup-tigerai.sh"
        if [ -f "$backup_script" ]; then
            sudo bash "$backup_script"
        else
            LOG_ERROR "Backup script not found: $backup_script"
        fi
        ;;
    restore)
        restore_script="./08-backup-recovery/restore-tigerai.sh"
        if [ -f "$restore_script" ]; then
            sudo bash "$restore_script"
        else
            LOG_ERROR "Restore script not found: $restore_script"
        fi
        ;;
    clean)
        LOG_WARN " Stopping and removing application containers..."
        for step in "${DEPLOY_STEPS[@]:1}"; do
            if [ -d "$step" ] && [ -f "$step/docker-compose.yaml" ]; then
                pushd "$step" > /dev/null
                docker compose down || true
                popd > /dev/null
            fi
        done
        LOG_INFO " Cleanup completed"
        ;;
    *)
        usage
        ;;
esac

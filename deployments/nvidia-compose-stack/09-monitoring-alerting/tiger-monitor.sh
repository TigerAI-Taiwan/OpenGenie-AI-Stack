#!/usr/bin/env bash
# =====================================================================
# TigerAI Proactive Health Monitor (Unattended Ops)
# Path: deployments/09-monitoring-alerting/tiger-monitor.sh
# =====================================================================

set -eo pipefail

# --- 0) Configuration ---
cd "$(dirname "$0")"
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

MQTT_BROKER=${MQTT_BROKER:-"localhost"}
MQTT_TOPIC_HEALTH=${MQTT_TOPIC_HEALTH:-"tigerai/monitor/health"}
MQTT_TOPIC_ALARM=${MQTT_TOPIC_ALARM:-"tigerai/monitor/alarm"}
TARGET_HOST=${TARGET_HOST:-"localhost"}

LOG_PREFIX="TigerAI Monitor"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} (Target: $TARGET_HOST) $*"; }

# Check dependencies
if ! command -v mosquitto_pub &>/dev/null; then
    LOG "Installing mosquitto-clients for MQTT notifications..."
    sudo apt update && sudo apt install -y mosquitto-clients
fi

# Service List to Monitor
SERVICES=(
    "Portainer:http://$TARGET_HOST:9000"
    "Ollama:http://$TARGET_HOST:11434"
    "n8n:http://$TARGET_HOST:5678/healthz"
    "OpenWebUI:http://$TARGET_HOST:8080/health"
    "Qdrant:http://$TARGET_HOST:6333/info"
    "Docling:http://$TARGET_HOST:5001/health"
    "Lemonade_EDU:http://$TARGET_HOST:8800/health"
)

check_and_notify() {
    local full_report="Status Report ($DATE):\n"
    local has_failure=false
    local failed_services=""

    for item in "${SERVICES[@]}"; do
        name="${item%%:*}"
        url="${item#*:}"
        
        if curl -s -k --max-time 5 "$url" > /dev/null; then
            full_report+="[PASS] $name\n"
        else
            full_report+="[FAIL] $name\n"
            has_failure=true
            failed_services+="$name, "
        fi
    done

    # 1. Always publish raw status to health topic
    echo -e "$full_report" | mosquitto_pub -h "$MQTT_BROKER" -t "$MQTT_TOPIC_HEALTH" -s

    # 3. Performance Intelligence (NEW)
    # Check if CPU Load exceeds the allocated threads from Advisor
    local load_1=$(awk '{print $1}' /proc/loadavg)
    local threshold=${TIGER_CPU_THREADS:-2}
    
    if (( $(echo "$load_1 > $threshold" | bc -l) )); then
        perf_msg="PERF_WARN: System load ($load_1) exceeds allocated profile threads ($threshold). Impacting AI inference speed."
        echo "$perf_msg" | mosquitto_pub -h "$MQTT_BROKER" -t "$MQTT_TOPIC_ALARM" -s
        full_report+="[PERF_WARN] Overload detected\n"
        LOG " Performance bottleneck detected (Load: $load_1 > Lim: $threshold)"
    fi

    # 4. Final Reporting
    echo -e "$full_report" | mosquitto_pub -h "$MQTT_BROKER" -t "$MQTT_TOPIC_HEALTH" -s
}

# Run once if no argument, or run as loop if 'start'
case "$1" in
    once)
        check_and_notify
        ;;
    start)
        LOG "Starting unattended monitoring loop..."
        while true; do
            check_and_notify
            sleep "$HEARTBEAT_INTERVAL"
        done
        ;;
    install)
        LOG "Installing as Systemd service..."
        cat <<EOF | sudo tee /etc/systemd/system/tiger-monitor.service > /dev/null
[Unit]
Description=TigerAI Proactive Health Monitor
After=network.target mosquitto.service

[Service]
Type=simple
User=root
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/tiger-monitor.sh start
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable --now tiger-monitor.service
        LOG " Systemd service installed and started."
        ;;
    *)
        echo "Usage: $0 {once | start | install}"
        ;;
esac

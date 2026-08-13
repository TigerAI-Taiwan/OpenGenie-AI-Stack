#!/usr/bin/env bash
# =====================================================================
# TigerAI Proactive Health Monitor (Unattended Ops) — shared body
# Path: deployments/compose-stack/09-monitoring-alerting/resource/_shared/tiger-monitor-common.sh
#
# Sourced by resource/<platform>/tiger-monitor.sh. Defines
# tiger_monitor_main() and does NOT call it — the entry point does, after
# appending its own SERVICES entries. Today that means the amd entry adds the
# Lemonade endpoints, because only amd deploys 06-ai-core-lemonade.
#
# The -common.sh suffix is deliberate: tiger_res resolves
# resource/<platform>/ before resource/_shared/, so a platform entry point
# named tiger-monitor.sh that went missing would silently fall back to this
# file, which defines functions and calls nothing — the service would install,
# start, and monitor nothing while looking perfectly healthy.
#
# The arm64 version is taken as the base because it was the only complete
# one. What the other two were missing was not cosmetic:
#
#   - amd's check_and_notify() was an empty stub — a `local report=` line and
#     the comment "# Logic for health check...". No service list, no curl, no
#     mosquitto_pub. The systemd unit installed fine and looped every 60
#     seconds doing nothing at all, so amd hosts have never been monitored.
#   - nvidia had no "alarm on service failure" branch. It collected PASS/FAIL
#     per service and published the report, but only ever raised an alarm for
#     CPU overload, so a service going down produced no alert. It also
#     published the same health report twice.
#
# arm64 additionally defaulted HEARTBEAT_INTERVAL (the others hard-coded
# sleep 60) and timestamped the report.
#
# WARNING: this script must stay at the FIRST level of resource/_shared/.
# The `../..` below is a hard-coded depth.
# =====================================================================

# --- 0) Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# <module>/resource/_shared/<this file>  ->  ../.. is the module directory.
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Monitor"
# shellcheck source=../../../lib/common.sh
source "${TIGER_MODULE_DIR}/../lib/common.sh"

MQTT_BROKER=${MQTT_BROKER:-"localhost"}
# The broker requires authentication. These must match what the mosquitto
# service in 05-rag-stack feeds to mosquitto_passwd — same variables, same
# defaults. Without them every publish below is rejected, and mosquitto_pub
# reports that on stderr while this script carries on regardless.
MQTT_USERNAME=${MQTT_USERNAME:-tigerai}
MQTT_PASSWORD=${MQTT_PASSWORD:-CHANGE_ME}
MQTT_PORT=${MQTT_PORT:-1883}
MQTT_TOPIC_HEALTH=${MQTT_TOPIC_HEALTH:-"tigerai/monitor/health"}
MQTT_TOPIC_ALARM=${MQTT_TOPIC_ALARM:-"tigerai/monitor/alarm"}
TARGET_HOST=${TARGET_HOST:-"localhost"}
HEARTBEAT_INTERVAL=${HEARTBEAT_INTERVAL:-60}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-5}

# WARN / ERROR and the colors come from lib/common.sh. LOG is redefined here
# to prefix the target host.
LOG(){ echo -e "${GREEN}[${TIGER_LOG_PREFIX} INFO]${NC} (Target: $TARGET_HOST) $*"; }

# Check dependencies
if ! command -v mosquitto_pub &>/dev/null; then
    LOG "Installing mosquitto-clients for MQTT notifications..."
    sudo apt update && sudo apt install -y mosquitto-clients
fi
# Still missing after the install attempt: keep probing services locally rather
# than dying, but say so — silently skipping every publish would look exactly
# like a healthy stack with nothing to report.
MQTT_ENABLED=true
command -v mosquitto_pub &>/dev/null || {
    MQTT_ENABLED=false
    WARN "mosquitto_pub not found — MQTT publishing disabled, probing locally only."
}

# publish <topic> <payload>
#
# A failed publish is the ONLY signal that the broker is down: mosquitto has no
# HTTP endpoint for the service loop to probe. So it must not stay silent —
# before the merge these were bare `mosquitto_pub ... -s` calls with no
# credentials and no error handling, which meant a rejected or unreachable
# broker produced no alerts AND no complaint.
#
# Warn once per sweep; MQTT_WARNED is reset at the top of check_and_notify.
MQTT_WARNED=false
publish() {
    [ "$MQTT_ENABLED" = true ] || return 0
    if ! echo -e "$2" | mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" \
            -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t "$1" -s 2>/dev/null; then
        [ "$MQTT_WARNED" = true ] || WARN "MQTT publish failed (topic: $1) — broker ${MQTT_BROKER}:${MQTT_PORT} unreachable or credentials rejected. Alerts are NOT being delivered."
        MQTT_WARNED=true
    fi
    return 0
}

# probe <url> -> 0 on HTTP 2xx/3xx
#
# WARNING: -f is not optional. Without it curl exits 0 for ANY response, so a
# service answering 500 counted as healthy — the pre-merge script used a bare
# `curl -s` and reported PASS for anything still listening on the port.
probe() {
    curl -fs -k --max-time "$PROBE_TIMEOUT" "$1" >/dev/null 2>&1
}

# --- Service list (host-published ports of this stack) ---
# Ports read from the same variables the compose files use, so changing a port
# in .env does not leave the monitor probing the old one and reporting FAIL.
SERVICES=(
    "Portainer:http://$TARGET_HOST:${PORTAINER_PORT:-9000}/api/system/status"
    "pgAdmin:http://$TARGET_HOST:${PGADMIN_PORT:-8000}/misc/ping"
    "Ollama:http://$TARGET_HOST:${OLLAMA_PORT:-11434}/"
    "OpenWebUI:http://$TARGET_HOST:${OWUI_PORT:-8080}/health"
    "n8n:http://$TARGET_HOST:${N8N_PORT:-5678}/healthz/readiness"
    "Qdrant:http://$TARGET_HOST:${QDRANT_PORT:-6333}/healthz"
    "Docling:http://$TARGET_HOST:${HTTP_DOCLING_PORT:-5001}/health"
    "Grafana:http://$TARGET_HOST:${GRAFANA_PORT:-3000}/api/health"
    # Loki and cAdvisor host ports are hard-coded in 10-observability-grafana's
    # compose file ("3100:3100" / "8088:8080"), so there is no env var to use.
    "Loki:http://$TARGET_HOST:3100/ready"
    "cAdvisor:http://$TARGET_HOST:8088/healthz"
)

# Mutually-exclusive service groups ("Name:url1|url2"): PASS when ANY member
# answers. Empty by default; the amd entry point fills in Lemonade RAG/EMBED,
# which take turns under tiger-mode so exactly one of them is ever up.
SERVICES_ANY_OF=()

# Lemonade is amd-only (06-ai-core-lemonade), so resource/amd/tiger-monitor.sh
# appends its entries to both arrays before calling the dispatcher below.

check_and_notify() {
    local DATE=$(date "+%Y-%m-%d %H:%M:%S")
    MQTT_WARNED=false
    local full_report="Status Report ($DATE):\n"
    local has_failure=false
    local failed_services=""

    local name url
    for item in "${SERVICES[@]}"; do
        name="${item%%:*}"
        url="${item#*:}"
        if probe "$url"; then
            full_report+="[PASS] $name\n"
        else
            full_report+="[FAIL] $name\n"
            has_failure=true
            failed_services+="$name, "
        fi
    done

    # Mutually-exclusive groups: PASS when ANY member answers.
    # ${arr[@]+"${arr[@]}"} so an empty array is safe under `set -u`.
    for item in ${SERVICES_ANY_OF[@]+"${SERVICES_ANY_OF[@]}"}; do
        name="${item%%:*}"
        local group_ok=false
        for url in $(echo "${item#*:}" | tr '|' ' '); do
            probe "$url" && { group_ok=true; break; }
        done
        if [ "$group_ok" = true ]; then
            full_report+="[PASS] $name\n"
        else
            full_report+="[FAIL] $name\n"
            has_failure=true
            failed_services+="$name, "
        fi
    done

    # 1. Publish status to health topic
    publish "$MQTT_TOPIC_HEALTH" "$full_report"

    # 2. Alarm on failure
    if [ "$has_failure" = true ]; then
        LOG "${RED}ALERT: Services failed: $failed_services${NC}"
        publish "$MQTT_TOPIC_ALARM" "ALERT: Services down: $failed_services"
    fi

    # 3. Performance Intelligence
    # Check if CPU Load exceeds the allocated threads from Advisor
    local load_1=$(awk '{print $1}' /proc/loadavg)
    local threshold=${TIGER_CPU_THREADS:-2}
    
    if (( $(echo "$load_1 > $threshold" | bc -l) )); then
        local perf_msg="PERF_WARN: System load ($load_1) exceeds allocated profile threads ($threshold). Impacting AI inference speed."
        publish "$MQTT_TOPIC_ALARM" "$perf_msg"
        LOG " Performance bottleneck detected (Load: $load_1 > Lim: $threshold)"
    fi
}

# Dispatcher. The platform entry point calls this after appending its own
# SERVICES entries.
tiger_monitor_main() {
case "${1:-}" in
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
        LOG "Installing as a systemd service..."
        # The unit must carry TIGER_PLATFORM itself.
        #
        # Before the stack merge the platform was implied by which of the three
        # stack directories this script lived in, so the unit needed no
        # environment. lib/common.sh now requires TIGER_PLATFORM and refuses to
        # guess, and systemd starts services with a nearly empty environment —
        # a unit without it would fail on every start and restart forever.
        #
        # ExecStart must be the PLATFORM ENTRY POINT, not this shared body.
        # TIGER_MONITOR_ENTRY is set by the entry point before it sources this
        # file. Pointing systemd at _shared/ would start a script that defines
        # functions and calls nothing.
        local entry="${TIGER_MONITOR_ENTRY:?TIGER_MONITOR_ENTRY not set by the platform entry point}"
        sudo tee /etc/systemd/system/tiger-monitor.service > /dev/null <<EOF
[Unit]
Description=TigerAI Proactive Health Monitor
After=network.target mosquitto.service

[Service]
Type=simple
User=root
Environment=TIGER_PLATFORM=${TIGER_PLATFORM}
WorkingDirectory=$(dirname "$entry")
ExecStart=${entry} start
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable --now tiger-monitor.service
        LOG "Systemd service installed and started."
        # The baked-in value does not follow the machine — see the same note in
        # 08-backup-recovery/resource/_shared/setup-cron.sh.
        WARN "TIGER_PLATFORM=${TIGER_PLATFORM} is baked into the unit file."
        WARN "If the platform ever changes, re-run '$0 install'."
        ;;
    *)
        echo "Usage: $0 {once | start | install}"
        ;;
esac
}

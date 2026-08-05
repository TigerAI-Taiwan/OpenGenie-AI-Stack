#!/usr/bin/env bash
# =====================================================================
# TigerAI Stack Health Validator
# Path: deployments/07-validation-stack/check-health.sh
# =====================================================================

set -eo pipefail

# --- 0) Load Environment Variables ---
# Try to find tiger-tuning.env in current or parent directory
if [ -f ../tiger-tuning.env ]; then
  export $(grep -v '^#' ../tiger-tuning.env | sed 's/\r//g' | xargs)
elif [ -f tiger-tuning.env ]; then
  export $(grep -v '^#' tiger-tuning.env | sed 's/\r//g' | xargs)
fi

# Load local .env if exists
if [ -f .env ]; then
  export $(grep -v '^#' .env | sed 's/\r//g' | xargs)
fi

# Set defaults if not loaded
PG_USER=${PG_USER:-adm}
TARGET_HOST=${TARGET_HOST:-"localhost"}

LOG_PREFIX="TigerAI Validator"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX INFO]${NC} (Target: $TARGET_HOST) $*"; }
WARN(){ echo -e "${YELLOW}[$LOG_PREFIX WARN]${NC} $*"; }
ERROR(){ echo -e "${RED}[$LOG_PREFIX ERROR]${NC} $*"; }

check_endpoint() {
    local name=$1
    local url=$2
    local expected_code=$3
    
    LOG "Checking $name ($url)..."
    if curl -s -o /dev/null -w "%{http_code}" "$url" | grep -q "$expected_code"; then
        echo -e "  [${GREEN}PASS${NC}] $name is healthy."
    else
        echo -e "  [${RED}FAIL${NC}] $name is unreachable or returned error."
        return 1
    fi
}

# 1. Infrastructure Checks
LOG "--- [Phase 1: Base Infrastructure] ---"
check_endpoint "Portainer" "http://$TARGET_HOST:9000" "200" || true

# 2. Database Connectivity (via pg_isready)
LOG "--- [Phase 2: Database] ---"
# Precise check for container named 'postgres' that is currently running
if docker ps --filter "name=^postgres$" --filter "status=running" --quiet | grep -q . ; then
    # Try pg_isready, with a single retry if it's not ready yet (handles transient states)
    if docker exec postgres pg_isready -U adm >/dev/null 2>&1; then
        echo -e "  [${GREEN}PASS${NC}] Postgres is accepting connections."
    else
        WARN "Postgres is not ready, retrying in 2s..."
        sleep 2
        if docker exec postgres pg_isready -U adm >/dev/null 2>&1; then
            echo -e "  [${GREEN}PASS${NC}] Postgres is accepting connections."
        else
            echo -e "  [${RED}FAIL${NC}] Postgres is running but NOT accepting connections (check logs)."
        fi
    fi
else
    echo -e "  [${RED}FAIL${NC}] Postgres container ('postgres') is NOT running."
fi

# 3. AI Stack Checks
LOG "--- [Phase 3: AI Interfaces] ---"
check_endpoint "Ollama API" "http://$TARGET_HOST:11434/api/tags" "200" || true
check_endpoint "OpenWebUI" "http://$TARGET_HOST:8080/health" "200" || true

# 4. Automation & RAG Checks
LOG "--- [Phase 4: Automation & RAG] ---"
check_endpoint "n8n Health" "http://$TARGET_HOST:5678/healthz" "200" || true
check_endpoint "Qdrant API" "http://$TARGET_HOST:6333/healthz" "200" || true
check_endpoint "Docling API" "http://$TARGET_HOST:5001/health" "200" || true
check_endpoint "cAdvisor" "http://$TARGET_HOST:8088/healthz" "200" || true

# 5. Core Engine Checks
LOG "--- [Phase 5: Lemonade Core] ---"
check_endpoint "Lemonade EDU (8800)" "http://$TARGET_HOST:8800/health" "200|401" || WARN "Lemonade EDU might be stopped (check tiger-mode)"
check_endpoint "Lemonade RAG (8801)" "http://$TARGET_HOST:8801/health" "200|401" || WARN "Lemonade RAG might be stopped (check tiger-mode)"

LOG " Validation Check Finished."

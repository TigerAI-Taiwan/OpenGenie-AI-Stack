#!/usr/bin/env bash
# =====================================================================
# TigerAI Stack Health Validator
# Path: deployments/07-validation-stack/check-health.sh
# =====================================================================

set -eo pipefail

LOG_PREFIX="TigerAI Validator"
TARGET_HOST=${TARGET_HOST:-"localhost"}
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
check_endpoint "Portainer" "http://$TARGET_HOST:9000" "200|302" || true

# 2. Database Connectivity (via pg_isready)
LOG "--- [Phase 2: Database] ---"
# Note: For HA, remote pg_isready requires different syntax, but for now we check local container
if docker ps | grep -q postgres && docker exec postgres pg_isready -U adm >/dev/null 2>&1; then
    echo -e "  [${GREEN}PASS${NC}] Postgres is accepting connections."
else
    echo -e "  [${RED}FAIL${NC}] Postgres is NOT ready on this host."
fi

# 3. AI Stack Checks
LOG "--- [Phase 3: AI Interfaces] ---"
check_endpoint "Ollama API" "http://$TARGET_HOST:11434/api/tags" "200" || true
check_endpoint "OpenWebUI" "http://$TARGET_HOST:8080/health" "200" || true

# 4. Automation & RAG Checks
LOG "--- [Phase 4: Automation & RAG] ---"
check_endpoint "n8n Health" "http://$TARGET_HOST:5678/healthz" "200" || true
check_endpoint "Qdrant API" "http://$TARGET_HOST:6333/info" "200" || true
check_endpoint "Docling API" "http://$TARGET_HOST:5001/health" "200" || true
check_endpoint "cAdvisor" "http://$TARGET_HOST:8088/healthz" "200" || true

# 5. Core Engine Checks
LOG "--- [Phase 5: Lemonade Core] ---"
check_endpoint "Lemonade EDU (8800)" "http://$TARGET_HOST:8800/health" "200|401" || WARN "Lemonade EDU might be stopped (check tiger-mode)"
check_endpoint "Lemonade RAG (8801)" "http://$TARGET_HOST:8801/health" "200|401" || WARN "Lemonade RAG might be stopped (check tiger-mode)"

LOG " Validation Check Finished."

#!/usr/bin/env bash
# =====================================================================
# TigerAI Stack Health Validator
# Path: deployments/compose-stack/07-validation-stack/resource/_shared/check-health.sh
#
# Shared body, sourced by resource/<platform>/check-health.sh. It defines
# tiger_check_health_main() and does NOT call it — the entry point does, after
# adding whatever that platform checks on its own. Today that means the amd
# entry adds Phase 5 (Lemonade Core), because only amd deploys
# 06-ai-core-lemonade.
#
# The -common.sh suffix is deliberate. tiger_res resolves
# resource/<platform>/ before resource/_shared/, so if a platform entry point
# were ever named check-health.sh and went missing, tiger_res would silently
# fall back to this file — which defines a function and calls nothing, exiting
# 0 without running a single check. Different names make that impossible:
# tiger_res check-health.sh can only ever hit an entry point.
#
# The three pre-merge versions differed only by drift, not by platform.
#
# The amd version is taken as the base because it was a strict improvement:
# it read PG_USER instead of hard-coding adm, reported the actual HTTP code,
# filtered the postgres container precisely and retried once, used
# /healthz for Qdrant, and accepted 200|302 for Portainer (which redirects).
#
# It also fixed a real defect that nvidia and arm64 still carried:
# `grep -q "$expected_code"` with expected_code="200|401" matches the literal
# string "200|401" under basic grep, so it never matched an actual HTTP code —
# the Lemonade checks reported failure on those two platforms even when the
# service was perfectly healthy. `grep -qE` below is the fix.
#
# WARNING: this script must stay at the FIRST level of resource/_shared/.
# The `../..` below is a hard-coded depth.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# <module>/resource/_shared/<this file>  ->  ../.. is the module directory.
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Validator"
# shellcheck source=../../../lib/common.sh
source "${TIGER_MODULE_DIR}/../lib/common.sh"

# Guard: this file only defines a function. Running it directly would exit 0
# having checked nothing, which reads exactly like a passing health check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ERROR "check-health-common.sh must be sourced by a platform entry point, not run directly."
fi

PG_USER="${PG_USER:-adm}"
TARGET_HOST=${TARGET_HOST:-"localhost"}

# LOG / WARN / ERROR come from lib/common.sh. This module's LOG additionally
# prefixes the target host, so it is redefined here — and unlike common.sh's
# version, ERROR here must NOT exit: the validator is expected to report every
# failing check and keep going.
LOG()   { echo -e "${GREEN}[${TIGER_LOG_PREFIX} INFO]${NC} (Target: $TARGET_HOST) $*"; }
ERROR() { echo -e "${RED}[${TIGER_LOG_PREFIX} ERROR]${NC} $*"; }

check_endpoint() {
    local name=$1
    local url=$2
    local expected_code=$3
    
    LOG "Checking $name ($url)..."
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    if echo "$http_code" | grep -qE "$expected_code"; then
        echo -e "  [${GREEN}PASS${NC}] $name is healthy. (HTTP $http_code)"
    else
        echo -e "  [${RED}FAIL${NC}] $name is unreachable or returned error. (HTTP $http_code)"
        return 1
    fi
}

# Shared body. The platform entry point sources this file, optionally adds its
# own checks, then calls this function and prints the closing line.
tiger_check_health_main() {

# 1. Infrastructure Checks
LOG "--- [Phase 1: Base Infrastructure] ---"
check_endpoint "Portainer" "http://$TARGET_HOST:9000" "200|302" || true

# 2. Database Connectivity (via pg_isready)
LOG "--- [Phase 2: Database] ---"
# Precise check for container named 'postgres' that is currently running
if docker ps --filter "name=^postgres$" --filter "status=running" --quiet | grep -q . ; then
    # Try pg_isready, with a single retry if it's not ready yet (handles transient states)
    if docker exec postgres pg_isready -U ${PG_USER} >/dev/null 2>&1; then
        echo -e "  [${GREEN}PASS${NC}] Postgres is accepting connections."
    else
        WARN "Postgres is not ready, retrying in 2s..."
        sleep 2
        if docker exec postgres pg_isready -U ${PG_USER} >/dev/null 2>&1; then
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
check_endpoint "n8n Health" "http://$TARGET_HOST:5678/healthz/readiness" "200" || true
check_endpoint "Qdrant API" "http://$TARGET_HOST:6333/healthz" "200" || true
check_endpoint "Docling API" "http://$TARGET_HOST:5001/health" "200" || true
check_endpoint "cAdvisor" "http://$TARGET_HOST:8088/healthz" "200" || true

# Phase 5 (Lemonade Core) is amd-only and lives in resource/amd/check-health.sh,
# because only amd deploys 06-ai-core-lemonade.
#
# The closing line is printed by the platform entry point, not here, so that
# platform-specific checks land before it.
}


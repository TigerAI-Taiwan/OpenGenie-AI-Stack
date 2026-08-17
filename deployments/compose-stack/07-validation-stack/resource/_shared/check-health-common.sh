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

# Guard: this file only defines a function. Running it directly would exit 0
# having checked nothing, which reads exactly like a passing health check.
# Hand-written rather than ERROR(), because logging is not loaded yet.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "[TigerAI Validator ERROR] $(basename "${BASH_SOURCE[0]}") must be sourced by a platform entry point, not run directly." >&2
    exit 1
fi

set -eo pipefail

# --- 0) Environment ----------------------------------------------------------
# Load order matches lib/common.sh's tiger_load_env. ${BASH_SOURCE[0]} points at
# THIS file even when sourced, so the paths stay independent of the entry point.
#
# WARNING: keep all three details. The env files are gitignored so
# .gitattributes never normalizes them and the trailing CR must be stripped
# (PG_USER=adm\r makes `pg_isready` fail forever); `source` rather than
# `export $(... | xargs)`, which mangles values with whitespace or quotes; and a
# temp file rather than `source <(sed ...)`, which loads nothing under bash 3.2.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
STACK_DIR="$(cd "${MODULE_DIR}/.." && pwd -P)"

set -a
for _envfile in "${STACK_DIR}/tiger-tuning.env" "${STACK_DIR}/.env" "${MODULE_DIR}/.env"; do
    if [ -f "$_envfile" ]; then
        _tmp=$(mktemp)
        sed 's/\r$//' "$_envfile" > "$_tmp"
        # shellcheck disable=SC1090
        source "$_tmp"
        rm -f "$_tmp"
    fi
done
set +a

PG_USER="${PG_USER:-adm}"
TARGET_HOST=${TARGET_HOST:-"localhost"}

# --- 1) Logging --------------------------------------------------------------
# log.sh and not lib/common.sh: common.sh's ERR trap would abandon the run on
# the first failed check, and its TIGER_PLATFORM requirement would break
# `bash check-health.sh` run directly by a user.
if [ ! -f "${STACK_DIR}/lib/log.sh" ]; then
    echo "[TigerAI Validator ERROR] not found: ${STACK_DIR}/lib/log.sh (SCRIPT_DIR=${SCRIPT_DIR})" >&2
    exit 1
fi
# shellcheck source-path=SCRIPTDIR/../../../lib
# shellcheck source=log.sh
source "${STACK_DIR}/lib/log.sh"

# shellcheck disable=SC2034  # read by lib/log.sh's LOG/WARN/ERROR
TIGER_LOG_PREFIX="TigerAI Validator"
# Must come after TARGET_HOST is settled — expanded on assignment.
# shellcheck disable=SC2034  # read by lib/log.sh's LOG/WARN/ERROR
TIGER_LOG_CONTEXT="(Target: ${TARGET_HOST})"

# WARNING: log.sh's ERROR() exits 1, unlike the print-and-continue ERROR this
# file used to define. No ERROR call site remains below, so that is safe. For a
# non-fatal error message add a separate FAIL() — the validator must finish
# every phase.

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


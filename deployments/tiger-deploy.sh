#!/usr/bin/env bash
# =====================================================================
# TigerAI Unified Deployment Entry Point
# Path: deployments/tiger-deploy.sh
#
# Detects the hardware, exports TIGER_PLATFORM, and hands off to the
# single compose-stack. Before the stack merge this picked one of three
# sibling directories; now it picks a platform for one directory.
# =====================================================================
set -Eeo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STACK_DIR="${SCRIPT_DIR}/compose-stack"

echo -e "${BLUE}=====================================================================${NC}"
echo -e "${CYAN}   TigerAI Stack Intelligent Deployment System${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

# Respect an explicit override; otherwise detect. The detection order is
# unchanged from the pre-merge script: architecture first, then GPU tooling.
if [ -n "${TIGER_PLATFORM:-}" ]; then
    echo -e "${YELLOW}TIGER_PLATFORM is preset: ${TIGER_PLATFORM}${NC}"
else
    ARCH="$(uname -m)"
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        TIGER_PLATFORM="arm64"
    elif command -v nvidia-smi >/dev/null 2>&1; then
        TIGER_PLATFORM="nvidia"
    elif command -v rocm-smi >/dev/null 2>&1; then
        TIGER_PLATFORM="amd"
    else
        echo -e "${CYAN}No GPU detected, defaulting to the arm64 platform${NC}"
        TIGER_PLATFORM="arm64"
    fi
fi
export TIGER_PLATFORM

echo -e "${GREEN}Platform: ${TIGER_PLATFORM}${NC}"
echo ""

[ -d "$STACK_DIR" ] || { echo "compose-stack not found at $STACK_DIR" >&2; exit 1; }

# Run the hardware advisor. It writes <stack>/tiger-tuning.env, which
# lib/common.sh then loads as the lowest-priority env layer.
bash "${STACK_DIR}/00-pre-flight-advisor/deploy.sh"

echo ""
echo -e "${GREEN}✅ Intelligent configuration complete!${NC}"
echo -e "${CYAN}Continue with: sudo -E bash ${STACK_DIR}/master-deploy.sh all${NC}"

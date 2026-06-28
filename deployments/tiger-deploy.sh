#!/usr/bin/env bash
# =====================================================================
# TigerAI Unified Deployment Entry Point
# =====================================================================
set -eo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${BLUE}=====================================================================${NC}"
echo -e "${CYAN}   TigerAI Enterprise Stack Intelligent Deployment System${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

# Detect current architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    STACK_DIR="arm64-compose-stack"
elif command -v nvidia-smi &>/dev/null; then
    STACK_DIR="nvidia-compose-stack"
elif command -v rocm-smi &>/dev/null; then
    STACK_DIR="amd-compose-stack"
else
    echo -e "${CYAN}No GPU detected, defaulting to ARM64 architecture${NC}"
    STACK_DIR="arm64-compose-stack"
fi

echo -e "${GREEN}Detected architecture: $STACK_DIR${NC}"
echo ""

# Execute hardware advisor
cd "$STACK_DIR/00-pre-flight-advisor"
bash deploy.sh

echo ""
echo -e "${GREEN}✅ Intelligent configuration complete!${NC}"
echo -e "${CYAN}Please follow the instructions above to continue deployment.${NC}"

#!/usr/bin/env bash
# =====================================================================
# TigerAI Hardware Intelligence Advisor (Pre-flight)
# Path: deployments/00-pre-flight-advisor/tiger-advisor.sh
# =====================================================================

set -eo pipefail

LOG_PREFIX="TigerAI Advisor"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG(){ echo -e "${GREEN}[$LOG_PREFIX]${NC} $*"; }

# --- 1. Hardware Investigation ---
LOG " Investigating Hardware Resources..."

CPU_CORES=$(nproc)
TOTAL_RAM=$(free -g | awk '/^Mem:/{print $2}')
GPU_TYPE="Unknown"
VRAM="0"

if command -v nvidia-smi &>/dev/null; then
    GPU_TYPE="NVIDIA"
    # Use awk to sum all VRAM lines without closing the pipe early, preventing SIGPIPE crashes in multi-GPU setups.
    VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{sum+=$1} END {print sum}')
elif command -v rocm-smi &>/dev/null; then
    GPU_TYPE="AMD"
    VRAM=$(rocm-smi --showmeminfo vram --json | grep -oP '"size": \K\d+' | awk '{sum+=$1} END {print sum}' || echo "0")
    VRAM=$((VRAM / 1024 / 1024)) # Convert to MB
fi

echo -e "\n${BLUE}--- Hardware Report ---${NC}"
echo "CPU Cores : $CPU_CORES"
echo "Total RAM : ${TOTAL_RAM}GB"
echo "GPU Type  : $GPU_TYPE"
echo "GPU VRAM  : ${VRAM}MB"
echo -e "${BLUE}-----------------------${NC}\n"

# --- 2. Profile Selection ---
echo -e "Please select an optimization profile:"
echo -e "1) ${GREEN}Conservative (Conservative)${NC} - Stability first, low resource overhead."
echo -e "2) ${YELLOW}Balanced (Balanced)${NC} - Optimized for general AI workloads (Recommended)."
echo -e "3) ${RED}Optimal (Optimal)${NC} - Maximum performance, high concurrency."
read -p "Selection [1-3] (Default: 1 - Conservative): " CHOICE
CHOICE=${CHOICE:-1}

case "$CHOICE" in
    1)
        PROFILE="CONSERVATIVE"
        THREADS=$((CPU_CORES / 2))
        [ $THREADS -lt 1 ] && THREADS=1
        N8N_WORKERS=2
        LOG_MAX_SIZE="10m"
        ;;
    2)
        PROFILE="BALANCED"
        THREADS=$((CPU_CORES * 3 / 4))
        N8N_WORKERS=5
        LOG_MAX_SIZE="50m"
        ;;
    3)
        PROFILE="OPTIMAL"
        THREADS=$CPU_CORES
        N8N_WORKERS=10
        LOG_MAX_SIZE="100m"
        ;;
    *)
        LOG "Invalid choice. Falling back to Conservative (Conservative)."
        PROFILE="CONSERVATIVE"
        THREADS=$((CPU_CORES / 2))
        [ $THREADS -lt 1 ] && THREADS=1
        N8N_WORKERS=2
        LOG_MAX_SIZE="10m"
        ;;
esac

# --- 3. Save Recommendations ---
OUTPUT_FILE="../tiger-tuning.env"
cat <<EOF > "$OUTPUT_FILE"
# TigerAI Auto-Generated Tuning Configuration
# Profile: $PROFILE
TIGER_OPTIMIZATION_PROFILE=$PROFILE
TIGER_CPU_THREADS=$THREADS
TIGER_N8N_WORKERS=$N8N_WORKERS
TIGER_LOG_MAX_SIZE=$LOG_MAX_SIZE
TIGER_GPU_TYPE=$GPU_TYPE
TIGER_VRAM=$VRAM
EOF

LOG " Optimization Profile [$PROFILE] has been saved to $OUTPUT_FILE"
LOG "The master deployer will now use these settings to calibrate all layers."

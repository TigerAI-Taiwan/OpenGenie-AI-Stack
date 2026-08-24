#!/usr/bin/env bash
# =====================================================================
# TigerAI Hardware Intelligence Advisor (Pre-flight)
# Path: deployments/compose-stack/00-pre-flight-advisor/deploy.sh
#
# No compose file and no platform entries: the probe is the same everywhere,
# it just reports whatever GPU tooling it finds.
#
# Merged from the three pre-merge versions, which had drifted rather than
# specialized. The amd version emitted the richer tuning profile (it also
# wrote the OWUI worker count, TIGER_TOTAL_RAM and TIGER_CPU_CORES) and is the
# base here; the nvidia version's VRAM detection is the one kept, because it
# sums every GPU instead of reading only the first — see below.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Advisor"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# --- 1. Hardware Investigation ---
LOG " Investigating Hardware Resources..."

CPU_CORES=$(nproc)
TOTAL_RAM=$(free -g | awk '/^Mem:/{print $2}')
GPU_TYPE="Unknown"
VRAM="0"

if command -v nvidia-smi &>/dev/null; then
    GPU_TYPE="NVIDIA"
    # Sum every GPU rather than reading the first. `head -n 1` — what the amd
    # and arm64 versions used — both under-reports a multi-GPU host and closes
    # the pipe early, which makes nvidia-smi die on SIGPIPE.
    #
    # Safe to sum here: --query-gpu=memory.total emits exactly one value per
    # card. printf "%.0f" so an empty result is 0 rather than an empty string.
    VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits \
        | awk '{sum+=$1} END {printf "%.0f\n", sum}')
elif command -v rocm-smi &>/dev/null; then
    GPU_TYPE="AMD"
    # WARNING: match the explicit "VRAM Total Memory (B)" key, NOT a short
    # '"size"' pattern. `--showmeminfo vram` prints TWO numbers per block,
    # Total and Used. The pre-merge script paired a short pattern with
    # `head -n 1`, which happened to take only the first — but summing a short
    # pattern adds Used into the total, so a 32GB card reports 64GB. That looks
    # entirely plausible for a machine with GPUs, so nobody investigates it.
    # A wrong number that looks reasonable is worse than a zero.
    #
    # Deliberately NOT also accepting the legacy '"size"' key: if that format
    # names both Total and Used the same way, accepting it reintroduces the
    # doubling. The cost is that such a host reports 0 — exactly what it did
    # before this change, so no regression.
    #
    # (This module's own former rocm-smi-collector.sh read the same key from
    # the non-JSON output, which is the corroboration for the name.)
    VRAM=$( { rocm-smi --showmeminfo vram --json \
        | grep -oP '"VRAM Total Memory \(B\)"\s*:\s*"?\K\d+' || true; } \
        | awk '{sum+=$1} END {printf "%.0f\n", sum}')
    VRAM=$((VRAM / 1024 / 1024)) # Convert to MB (rocm-smi reports bytes per card)
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
# WARNING: `read` returns 1 at EOF, and lib/common.sh's `set -e` aborts the
# script on that — BEFORE the CHOICE default on the next line, so no tuning
# file is written at all. Every non-interactive caller hits it: tiger-deploy.sh,
# master-deploy.sh init, pipes, cron, CI.
if [ -t 0 ]; then
    read -r -p "Selection [1-3] (Default: 1 - Conservative): " CHOICE
else
    LOG "Non-interactive stdin — defaulting to 1 (Conservative)."
    CHOICE=""
fi
CHOICE=${CHOICE:-1}

case "$CHOICE" in
    1)
        PROFILE="CONSERVATIVE"
        THREADS=$((CPU_CORES / 2))
        [ $THREADS -lt 1 ] && THREADS=1
        N8N_WORKERS=2
        OWUI_UVICORN_WORKERS=2
        LOG_MAX_SIZE="10m"
        ;;
    2)
        PROFILE="BALANCED"
        THREADS=$((CPU_CORES * 3 / 4))
        N8N_WORKERS=5
        OWUI_UVICORN_WORKERS=3
        LOG_MAX_SIZE="50m"
        ;;
    3)
        PROFILE="OPTIMAL"
        THREADS=$CPU_CORES
        N8N_WORKERS=10
        OWUI_UVICORN_WORKERS=5
        LOG_MAX_SIZE="100m"
        ;;
    *)
        LOG "Invalid choice. Falling back to Conservative (Conservative)."
        PROFILE="CONSERVATIVE"
        THREADS=$((CPU_CORES / 2))
        [ $THREADS -lt 1 ] && THREADS=1
        N8N_WORKERS=2
        OWUI_UVICORN_WORKERS=2
        LOG_MAX_SIZE="10m"
        ;;
esac

# --- 3. Save Recommendations ---
# Anchored to the stack directory, not to the caller's cwd. As a relative
# "../tiger-tuning.env" this landed wherever the invoker happened to be —
# tiger-deploy.sh runs this from a different directory than master-deploy.sh
# does, and lib/common.sh only ever reads <stack>/tiger-tuning.env.
#
# ⚠️ 輸出的 key 必須是 TIGER_OWUI_UVICORN_WORKERS：03-ai-interface 讀的是
# TIGER_OWUI_UVICORN_WORKERS（fallback 到 OWUI_UVICORN_WORKERS，再 fallback 到 2），
# 語意是「單一 openwebui-main 容器內的 uvicorn process 數」，不是額外容器數。
# 舊名 TIGER_OWUI_WORKERS 全倉庫沒有任何消費者，等於這份建議值從來沒生效過。
#
# ⚠️ 下面的 heredoc 沒有引號，內容會做變數展開；註解也一樣會被展開後寫進輸出檔，
#    所以說明文字一律寫在這裡，不要放進 heredoc。
OUTPUT_FILE="${TIGER_STACK_DIR}/tiger-tuning.env"
cat <<EOF > "$OUTPUT_FILE"
# TigerAI Auto-Generated Tuning Configuration
# Generated: $(date)
# Profile: $PROFILE
TIGER_OPTIMIZATION_PROFILE=$PROFILE
TIGER_CPU_THREADS=$THREADS
TIGER_N8N_WORKERS=$N8N_WORKERS
TIGER_OWUI_UVICORN_WORKERS=$OWUI_UVICORN_WORKERS
TIGER_LOG_MAX_SIZE=$LOG_MAX_SIZE
TIGER_GPU_TYPE=$GPU_TYPE
TIGER_VRAM=$VRAM
TIGER_TOTAL_RAM=$TOTAL_RAM
TIGER_CPU_CORES=$CPU_CORES
EOF

LOG "✅ Optimization Profile [$PROFILE] has been saved to $OUTPUT_FILE"
LOG "📊 Hardware Profile:"
LOG "   - CPU Cores: $CPU_CORES"
LOG "   - Total RAM: ${TOTAL_RAM}GB"
LOG "   - GPU Type: $GPU_TYPE"
LOG "   - GPU VRAM: ${VRAM}MB"
LOG ""
LOG "🎯 Recommended Settings:"
LOG "   - Worker Threads: $THREADS"
LOG "   - n8n Workers: $N8N_WORKERS"
LOG "   - OpenWebUI Workers: $OWUI_UVICORN_WORKERS"
LOG "   - Log Max Size: $LOG_MAX_SIZE"
LOG ""
LOG "💡 All deployment scripts will now use these optimized settings automatically."



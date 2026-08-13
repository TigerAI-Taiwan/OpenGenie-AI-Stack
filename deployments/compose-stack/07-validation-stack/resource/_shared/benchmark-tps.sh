#!/usr/bin/env bash
# =====================================================================
# TigerAI TPS Benchmark Tool
# Path: deployments/07-validation-stack/benchmark-tps.sh
# =====================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 檢查 Python 環境與依賴
if ! python3 -c "import requests" &>/dev/null; then
    echo "正在安裝必要的 Python 依賴 (requests)..."
    pip3 install requests --quiet
fi

# 執行測試
# 可以傳入模型名稱作為參數，例如: ./benchmark-tps.sh llama3
MODEL=${1:-""}

python3 benchmark_tps.py "$MODEL"

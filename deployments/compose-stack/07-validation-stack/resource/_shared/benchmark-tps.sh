#!/usr/bin/env bash
# =====================================================================
# TigerAI TPS Benchmark Tool
# Path: deployments/07-validation-stack/benchmark-tps.sh
# =====================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# <module>/resource/_shared/<this file>  ->  ../.. is the module directory.
MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$SCRIPT_DIR"

# ⚠️ 不要改回 `pip3 install requests`：近期 Debian/Ubuntu 的系統 Python 是
#    externally-managed。venv 位置與 05-rag-stack 同慣例。
VENV_DIR="$MODULE_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python3"

if [ ! -f "$VENV_PYTHON" ]; then
    echo "建立 Python venv 並安裝依賴 (requests)..."
    if ! python3 -m venv "$VENV_DIR" 2>/dev/null; then
        echo "python3-venv 可能未安裝，嘗試安裝..."
        sudo apt-get install -y python3-venv
        rm -rf "$VENV_DIR"
        python3 -m venv "$VENV_DIR"
    fi
    "$VENV_PYTHON" -m pip install --upgrade pip -q
    "$VENV_PYTHON" -m pip install requests -q
fi

# 執行測試
# 可以傳入模型名稱作為參數，例如: ./benchmark-tps.sh llama3
MODEL=${1:-""}

"$VENV_PYTHON" benchmark_tps.py "$MODEL"

#!/usr/bin/env bash
# =====================================================================
# TigerAI TPS Benchmark Tool
# Path: deployments/07-validation-stack/benchmark-tps.sh
# =====================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# <module>/resource/_shared/<this file>  ->  ../.. is the module directory.
MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STACK_DIR="$(cd "${MODULE_DIR}/.." && pwd)"
cd "$SCRIPT_DIR"

# Read just this one variable instead of sourcing the whole .env: an inline
# comment in .env can run as a command under `source`, which is not worth the
# risk for a port number. File order matches check-health-common.sh (later
# wins); `sed 's/\r$//'` strips CRLF. An optional `export ` prefix and one pair
# of surrounding double or single quotes are accepted.
read_env_var() {
  local key="$1" val="" f line
  for f in "${STACK_DIR}/tiger-tuning.env" "${STACK_DIR}/.env" "${MODULE_DIR}/.env"; do
    [ -f "$f" ] || continue
    line=$(sed 's/\r$//' "$f" | grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" | tail -1 || true)
    [ -n "$line" ] && val=$(printf '%s' "${line#*=}" | sed "s/#.*\$//; s/[[:space:]]*\$//; s/^[\"']//; s/[\"']\$//")
  done
  printf '%s' "$val"
}

# benchmark_tps.py reads OLLAMA_HOST. An OLLAMA_HOST already in the environment
# wins; ${VAR:-…} does not expand the fallback then.
OLLAMA_PORT_RESOLVED="$(read_env_var OLLAMA_PORT)"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:${OLLAMA_PORT_RESOLVED:-11434}}"
# An inherited OLLAMA_HOST may be the server bind form from .env.example
# (0.0.0.0:11434): add the scheme (any case), and aim at localhost when the
# whole host is 0.0.0.0 — not when it merely starts with it.
case "$OLLAMA_HOST" in
    [Hh][Tt][Tt][Pp]://*|[Hh][Tt][Tt][Pp][Ss]://*) ;;
    *) OLLAMA_HOST="http://${OLLAMA_HOST}" ;;
esac
if [[ "$OLLAMA_HOST" =~ ^([A-Za-z]+://)0\.0\.0\.0([:/].*)?$ ]]; then
    OLLAMA_HOST="${BASH_REMATCH[1]}localhost${BASH_REMATCH[2]}"
fi
export OLLAMA_HOST

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

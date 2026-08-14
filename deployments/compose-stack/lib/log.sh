#!/usr/bin/env bash
# =====================================================================
# TigerAI Compose Stack — Logging and colors (single source of truth)
# Path: deployments/compose-stack/lib/log.sh
#
# Contract: NO side effects. No `set`, no trap, no path derivation, no .env,
# no exports, safe to source twice, never overwrites a color the caller
# already defined. That is why it is separate from lib/common.sh, which
# forces `set -Eeo pipefail` + an ERR trap and requires TIGER_PLATFORM —
# host-side scripts (install.sh, backup/restore, migrations) cannot take that.
#
#   LOG / SKIP   -> stdout      WARN / ERROR -> stderr, ERROR exits 1
#   prefix  = ${TIGER_LOG_PREFIX:-${LOG_PREFIX:-TigerAI}}, evaluated at CALL
#             time, so setting it after sourcing works. New code must set
#             TIGER_LOG_PREFIX: setting only LOG_PREFIX lets any exported
#             TIGER_LOG_PREFIX silently win (env cascades run under `set -a`).
#   TIGER_LOG_CONTEXT  text inserted after the label, e.g. "(Target: host)".
#
# Standard source snippet for <module>/resource/<platform|_shared>/*.sh
# (use `..` instead of `../../..` at the deploy.sh level):
#
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
#     STACK_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd -P)"
#     [ -f "${STACK_DIR}/lib/log.sh" ] || { echo "..." >&2; exit 1; }
#     # shellcheck source-path=SCRIPTDIR/../../../lib
#     # shellcheck source=log.sh
#     source "${STACK_DIR}/lib/log.sh"
#     TIGER_LOG_PREFIX="TigerAI Backup"
#
# WARNING: a missing log.sh must fail loudly. Never fall back to built-in
# definitions — "silently use a default, then exit 0" is this repo's recurring
# failure shape.
#
# WARNING: `../../..` is a hard-coded depth, valid only while the script sits
# at the FIRST level of resource/<platform|_shared>/.
#   Self-check (must print nothing):
#     find deployments/compose-stack/*/resource -mindepth 3 -name '*.sh'
# =====================================================================

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "lib/log.sh must be sourced, not executed" >&2
    exit 1
fi

# common.sh sources this file, and a consumer may source both in either order.
if [ -n "${TIGER_LOG_SH_LOADED:-}" ]; then
    return 0
fi
TIGER_LOG_SH_LOADED=1

# `[ -n ] ||` rather than `${VAR:=...}`: same semantics, no quote-escaping
# needed around '\033'.
[ -n "${GREEN:-}"  ] || GREEN='\033[0;32m'
[ -n "${YELLOW:-}" ] || YELLOW='\033[1;33m'
[ -n "${RED:-}"    ] || RED='\033[0;31m'
[ -n "${BLUE:-}"   ] || BLUE='\033[0;34m'
[ -n "${CYAN:-}"   ] || CYAN='\033[0;36m'
[ -n "${NC:-}"     ] || NC='\033[0m'

# `${c:+ ${c}}` expands to a space plus the content only when c is non-empty.
LOG() {
    local p="${TIGER_LOG_PREFIX:-${LOG_PREFIX:-TigerAI}}" c="${TIGER_LOG_CONTEXT:-}"
    echo -e "${GREEN}[${p} INFO]${NC}${c:+ ${c}} $*"
}

SKIP() {
    local p="${TIGER_LOG_PREFIX:-${LOG_PREFIX:-TigerAI}}" c="${TIGER_LOG_CONTEXT:-}"
    echo -e "${BLUE}[${p} SKIP]${NC}${c:+ ${c}} $*"
}

WARN() {
    local p="${TIGER_LOG_PREFIX:-${LOG_PREFIX:-TigerAI}}" c="${TIGER_LOG_CONTEXT:-}"
    echo -e "${YELLOW}[${p} WARN]${NC}${c:+ ${c}} $*" >&2
}

ERROR() {
    local p="${TIGER_LOG_PREFIX:-${LOG_PREFIX:-TigerAI}}" c="${TIGER_LOG_CONTEXT:-}"
    echo -e "${RED}[${p} ERROR]${NC}${c:+ ${c}} $*" >&2
    exit 1
}

# Aliases used by the pre-merge deploy.sh scripts.
LOG_INFO()  { LOG "$@"; }
LOG_WARN()  { WARN "$@"; }
LOG_ERROR() { ERROR "$@"; }

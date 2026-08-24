#!/usr/bin/env bash
# =====================================================================
# TigerAI Compose Stack — Shared Shell Library
# Path: deployments/compose-stack/lib/common.sh
#
# Usage (top of every module's deploy.sh):
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
#     TIGER_LOG_PREFIX="TigerAI Infra"
#     source "${SCRIPT_DIR}/../lib/common.sh"
#
# After sourcing:
#     LOG / WARN / ERROR / SKIP  uniform logging (ERROR exits 1)
#                                implemented in lib/log.sh; this file sources it
#     ensure_network [name]      create ai_stack_net (idempotent)
#     tiger_compose <args...>    docker compose with -f overlays + --env-file
#     tiger_res <name>           resource lookup (platform -> _shared)
#     TIGER_PLATFORM / TIGER_STACK_DIR / TIGER_MODULE_DIR / TIGER_MODULE
#     tiger_env_files            env files that exist, lowest priority first
#
# This file sets `set -Eeo pipefail` and an ERR trap for the sourcing
# shell, so module deploy.sh scripts must not set them again.
#
# Logging lives in lib/log.sh because this file's three side effects (the
# `set`, the trap, the TIGER_PLATFORM requirement) are wanted by module
# deploy.sh scripts but not by host-side scripts that must run standalone.
# This file is just one of log.sh's consumers.
# =====================================================================

# --- 0) Guard: this file may only be sourced ---------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "lib/common.sh must be sourced, not executed" >&2
    exit 1
fi

set -Eeo pipefail

# --- 1) Colors and logging ---------------------------------------------------
# Implementation is in lib/log.sh. This file adds the exports (relied on by
# module deploy.sh and their children) and the TIGER_LOG_PREFIX default that
# the ERR trap below expands. TIGER_LIB_DIR is computed here rather than in §3
# because sourcing log.sh needs it.
TIGER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ ! -f "${TIGER_LIB_DIR}/log.sh" ]; then
    # Hand-written: no ERROR() yet. Never fall back to built-in definitions.
    echo "[TigerAI ERROR] not found: ${TIGER_LIB_DIR}/log.sh — lib/ is incomplete, aborting." >&2
    exit 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=log.sh
source "${TIGER_LIB_DIR}/log.sh"
export GREEN YELLOW RED BLUE CYAN NC

TIGER_LOG_PREFIX="${TIGER_LOG_PREFIX:-TigerAI}"

# --- 2) ERR trap -------------------------------------------------------------
# Print line number / command / exit code on failure. `set -E` above makes
# functions and subshells inherit the trap.
#
# WARNING: the backticks around $BASH_COMMAND must stay escaped as \`. A trap
# argument is evaluated as a command at trigger time, so unescaped backticks
# would command-substitute at that moment — re-running the command that just
# failed. Do not remove the backslashes.
# shellcheck disable=SC2154  # rc is assigned inside the trap
trap 'rc=$?; echo -e "${RED}[${TIGER_LOG_PREFIX} FAILED]${NC} line $LINENO: \`$BASH_COMMAND\` (exit $rc)" >&2; exit $rc' ERR

# --- 3) Paths and platform ---------------------------------------------------
# The parent of lib/ is the stack root (deployments/compose-stack).
# TIGER_LIB_DIR was already computed in §1, where sourcing log.sh needed it.
TIGER_STACK_DIR="$(cd "${TIGER_LIB_DIR}/.." && pwd -P)"

# The module directory is wherever the calling deploy.sh lives. A module may
# set TIGER_MODULE_DIR itself first (e.g. when sourced from elsewhere).
if [ -z "${TIGER_MODULE_DIR:-}" ]; then
    # ${BASH_SOURCE[1]} = the script that sourced this file
    if [ -n "${BASH_SOURCE[1]:-}" ]; then
        TIGER_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd -P)"
    else
        TIGER_MODULE_DIR="$(pwd -P)"
    fi
fi
# shellcheck disable=SC2034  # consumed by module deploy.sh for logging
TIGER_MODULE="$(basename "$TIGER_MODULE_DIR")"

TIGER_PLATFORMS=(amd nvidia arm64)

# TIGER_PLATFORM comes from tiger-deploy.sh / master-deploy.sh or the user's
# environment. Refuse to guess: silently picking a platform pulls the wrong
# GPU image and the wrong overlay.
if [ -z "${TIGER_PLATFORM:-}" ]; then
    ERROR "TIGER_PLATFORM is not set. Run via deployments/tiger-deploy.sh or master-deploy.sh," \
          "or set it explicitly: TIGER_PLATFORM={amd|nvidia|arm64} sudo -E bash ./deploy.sh all"
fi
# An equality loop, not `case " ${TIGER_PLATFORMS[*]} " in *" $x "*)` — that
# matches a SUBSTRING, so TIGER_PLATFORM="amd nvidia" passed validation.
# Do not shorten the body to `[ … ] && _tp_ok=1`: as the loop's last statement
# a non-matching final iteration returns 1 and fires the ERR trap.
_tp_ok=""
for _tp in "${TIGER_PLATFORMS[@]}"; do
    if [ "$_tp" = "$TIGER_PLATFORM" ]; then _tp_ok=1; break; fi
done
unset _tp
if [ -z "$_tp_ok" ]; then
    ERROR "TIGER_PLATFORM='${TIGER_PLATFORM}' is not valid. Allowed: ${TIGER_PLATFORMS[*]}"
fi
unset _tp_ok
# WARNING: export TIGER_PLATFORM only. TIGER_MODULE_DIR / TIGER_MODULE /
# TIGER_STACK_DIR are deliberately NOT exported: master-deploy.sh launches each
# module with `sudo -E bash ./deploy.sh`, and an exported module dir would be
# inherited by the child (pointing at the stack root), making tiger_compose look
# for <stack>/docker-compose.base.yaml instead of the module's own file.
export TIGER_PLATFORM

# --- 4) Three-layer env loading ----------------------------------------------
# Order (later overrides earlier):
#     <stack>/tiger-tuning.env   hardware defaults from 00-pre-flight-advisor
#     <stack>/.env               the user's stack-level settings
#     <module>/.env              module-level override (highest)
#
# Both consumers are fed, with identical semantics:
#   (a) shell   — deploy.sh needs the values itself (ensure_db needs PG_USER).
#                 Imported with `set -a` + `source`, replacing the pre-merge
#                 `export $(grep -v '^#' … | xargs)`, which mangles any value
#                 containing whitespace or quotes.
#   (b) compose — tiger_env_files output becomes --env-file arguments, appended
#                 by tiger_compose. Compose precedence is
#                 "shell env > later --env-file > earlier", so the two paths
#                 share a source and an order and therefore agree.
#
# WARNING: the CRLF handling must stay. .gitattributes normalization only
# covers version-controlled files, and all three env files are gitignored:
#   <stack>/.env          user copies .env.example and edits it, possibly via
#                         Windows / SMB / clipboard
#   <module>/.env         same
#   tiger-tuning.env      generated on the host by 00-pre-flight-advisor
# Without it, PG_USER=adm\r makes `pg_isready -U $'adm\r'` fail forever, and a
# POSTGRES_PASSWORD carrying \r is written into initdb, breaking authentication
# for n8n / OpenWebUI / everything downstream with no visible cause.
#
# Strip only a trailing \r, so values containing whitespace or quotes survive.
#
# WARNING: this deliberately uses a temp file rather than
# `source <(sed 's/\r$//' "$f")`. Process substitution fails silently under
# bash 3.2 (the macOS default): sed takes SIGPIPE and source reads empty input,
# so nothing is loaded and nothing is reported. The deployment target is Linux
# bash 5, where that form works — but the temp-file form works in both, which
# is what makes local verification trustworthy.
#
# tiger_env_files() recomputes every call rather than caching, because
# master-deploy.sh's fallback path rewrites TIGER_MODULE_DIR before calling
# tiger_compose.
tiger_env_files() {
    local f
    for f in "${TIGER_STACK_DIR}/tiger-tuning.env" \
             "${TIGER_STACK_DIR}/.env" \
             "${TIGER_MODULE_DIR}/.env"; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

tiger_load_env() {
    local f tmp
    set -a
    while IFS= read -r f; do
        # Strip trailing \r only (see above). Do not switch back to
        # `source "$f"`, and do not use `source <(sed …)`.
        tmp=$(mktemp)
        sed 's/\r$//' "$f" > "$tmp"
        # shellcheck disable=SC1090
        source "$tmp"
        rm -f "$tmp"
    done < <(tiger_env_files)
    set +a
}
tiger_load_env

# --- 5) Docker network -------------------------------------------------------
TIGER_NETWORK="${TIGER_NETWORK:-ai_stack_net}"

ensure_network() {
    local net="${1:-$TIGER_NETWORK}"
    if ! docker network inspect "$net" >/dev/null 2>&1; then
        LOG "Creating Docker network: $net"
        docker network create "$net" >/dev/null
    fi
}

# --- 6) tiger_compose --------------------------------------------------------
# Builds `docker compose -f base [-f <platform> overlay] --env-file … <args>`.
#
# WARNING: compose derives the project name from the project directory's
# basename, and named volumes are prefixed with it (e.g.
# 01-infra-webssh-portainer_portainer_data). This pins it with
# --project-directory "$TIGER_MODULE_DIR", and therefore —
# **module directory names must never be renamed**. Renaming changes the
# project name, so an upgraded machine attaches to a fresh, empty set of
# volumes and the data appears to have vanished. Modules may be moved, never
# renamed in passing.
#
# WARNING: the base file is docker-compose.base.yaml, not docker-compose.yaml.
# docker compose auto-loads the latter, so anyone running `docker compose up`
# inside a module directory would silently skip the platform overlay. With
# .base.yaml that fails loudly instead of quietly running the wrong config.
tiger_compose() {
    local base="${TIGER_MODULE_DIR}/docker-compose.base.yaml"
    [ -f "$base" ] || ERROR "not found: $base"

    local -a args=(--project-directory "$TIGER_MODULE_DIR" -f "$base")
    local overlay="${TIGER_MODULE_DIR}/docker-compose.${TIGER_PLATFORM}.yaml"
    [ -f "$overlay" ] && args+=(-f "$overlay")

    local f
    while IFS= read -r f; do
        args+=(--env-file "$f")
    done < <(tiger_env_files)

    if [ -n "${TIGER_COMPOSE_DRY_RUN:-}" ]; then
        # Test aid: print the exact command that would run, without calling docker
        printf 'docker compose'
        printf ' %q' "${args[@]}" "$@"
        printf '\n'
        return 0
    fi
    docker compose "${args[@]}" "$@"
}

# --- 7) tiger_res ------------------------------------------------------------
# Resource lookup for shell callers: resource/<platform>/<name> wins,
# falling back to resource/_shared/<name>.
#
# Note: do not use this for resource paths inside compose files. There, the
# overlay overrides the volumes entry directly to select the platform file,
# which is both clearer and needs no shell involvement.
tiger_res() {
    local name="$1" p
    for p in "${TIGER_MODULE_DIR}/resource/${TIGER_PLATFORM}/${name}" \
             "${TIGER_MODULE_DIR}/resource/_shared/${name}"; do
        if [ -e "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    ERROR "resource not found: ${name} (looked in resource/${TIGER_PLATFORM}/ and resource/_shared/)"
}

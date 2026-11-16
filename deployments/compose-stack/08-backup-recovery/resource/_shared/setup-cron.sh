#!/usr/bin/env bash
# =====================================================================
# TigerAI Maintenance Cron Installer
# Path: deployments/compose-stack/08-backup-recovery/resource/_shared/setup-cron.sh
#
# Called by deploy.sh's `cron` action, and runnable directly. vram-purge.sh is
# platform-specific, so this file (in resource/_shared/) cannot resolve it:
#   $1               the path deploy.sh resolved via tiger_res (preferred)
#   $TIGER_PLATFORM  fallback for a direct run
#   $2               the inference backend (ollama | lemonade), resolved by
#                    deploy.sh and written into the cron line (required)
# Neither present is a hard error — guessing installs a cron job that drives
# the wrong GPU stack.
#
# WARNING: must stay at the FIRST level of resource/_shared/. The `../..` below
# is a hard-coded depth.
# =====================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
STACK_DIR="$(cd "${MODULE_DIR}/.." && pwd -P)"

# log.sh and not lib/common.sh: nothing here needs tiger_res or the compose
# helpers, and common.sh would refuse to run without TIGER_PLATFORM.
if [ ! -f "${STACK_DIR}/lib/log.sh" ]; then
    echo "[TigerAI Cron ERROR] not found: ${STACK_DIR}/lib/log.sh (SCRIPT_DIR=${SCRIPT_DIR})" >&2
    exit 1
fi
# shellcheck source-path=SCRIPTDIR/../../../lib
# shellcheck source=log.sh
source "${STACK_DIR}/lib/log.sh"
TIGER_LOG_PREFIX="TigerAI Cron"

PURGE_SCRIPT="${1:-}"
if [ -z "$PURGE_SCRIPT" ]; then
    if [ -z "${TIGER_PLATFORM:-}" ]; then
        ERROR "No vram-purge.sh path given and TIGER_PLATFORM is unset.
  Use: sudo TIGER_PLATFORM={amd|nvidia|arm64} bash <module>/deploy.sh cron
  or pass the path: bash $0 <path/to/vram-purge.sh>"
    fi
    PURGE_SCRIPT="${SCRIPT_DIR}/../${TIGER_PLATFORM}/vram-purge.sh"
fi
[ -f "$PURGE_SCRIPT" ] || ERROR "purge script not found: $PURGE_SCRIPT"
PURGE_SCRIPT="$(cd "$(dirname "$PURGE_SCRIPT")" && pwd -P)/$(basename "$PURGE_SCRIPT")"
chmod +x "$PURGE_SCRIPT"

BACKEND="${2:-}"
case "$BACKEND" in
    ollama|lemonade) ;;
    *) ERROR "Inference backend '${BACKEND}' invalid or missing. Use: sudo -E TIGER_PLATFORM={amd|nvidia|arm64} bash <module>/deploy.sh cron" ;;
esac

# No TIGER_PLATFORM in the cron line: it runs the platform entry point, which
# exports the value itself (see the note above that export). The backend is
# fixed here; the purge never re-resolves it.
CRON_JOB="0 5 * * * /bin/bash $PURGE_SCRIPT $BACKEND >> $MODULE_DIR/maintenance.log 2>&1"

if crontab -l 2>/dev/null | grep -qxF -- "$CRON_JOB"; then
    LOG "VRAM purge cron job already exists, skipping."
else
    LOG "Installing the daily 5:00 AM VRAM purge cron job (INFERENCE_BACKEND=${BACKEND})..."
    # WARNING: `|| true` is required. On a host with no crontab yet, `crontab -l`
    # exits 1, which under `set -e` ends the subshell before the echo runs —
    # `crontab -` then receives empty input and installs an EMPTY crontab, while
    # pipefail makes this script exit 1. Every fresh machine hits this.
    # Any older line for the same script (e.g. one without a backend) is replaced;
    # grep -v exiting 1 when nothing else is left is not a failure.
    ({ crontab -l 2>/dev/null || true; } | { grep -vF -- "$PURGE_SCRIPT" || true; }; echo "$CRON_JOB") | crontab -
    LOG "Installed."
fi

LOG "Current crontab entry:"
# grep exiting 1 on no match must not decide this script's success.
crontab -l 2>/dev/null | grep "vram-purge" || NO_MATCH=1
# `if`, not `[ ... ] && ERROR`: the latter's exit status is 1 on the happy path,
# which `set -e` would turn into a failed run.
if [ -n "${NO_MATCH:-}" ]; then
    ERROR "vram-purge is still absent from the crontab — the install did not take effect."
fi

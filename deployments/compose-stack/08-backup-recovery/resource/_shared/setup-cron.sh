#!/usr/bin/env bash
# =====================================================================
# TigerAI Maintenance Cron Installer
# Path: deployments/compose-stack/08-backup-recovery/resource/_shared/setup-cron.sh
#
# WARNING: this script must stay at the FIRST level of resource/_shared/.
# The `../..` below is a hard-coded depth — see backup-tigerai.sh.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# <module>/resource/_shared/<this file>  ->  ../.. is the module directory.
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Cron"
# shellcheck source=../../../lib/common.sh
source "${TIGER_MODULE_DIR}/../lib/common.sh"

PURGE_SCRIPT="$(tiger_res vram-purge.sh)"
[ -f "$PURGE_SCRIPT" ] || ERROR "purge script not found: $PURGE_SCRIPT"
chmod +x "$PURGE_SCRIPT"

# The cron job must carry TIGER_PLATFORM itself.
#
# Before the stack merge the platform was implied by which of the three stack
# directories the script lived in, so cron needed no environment at all. Now
# lib/common.sh requires TIGER_PLATFORM and refuses to guess — which is the
# right call for a deploy path, but it means a bare `/bin/bash vram-purge.sh`
# from cron would abort every night. cron starts with a nearly empty
# environment and does not read the user's shell profile, so the value is
# baked into the crontab line at install time.
CRON_JOB="0 5 * * * TIGER_PLATFORM=${TIGER_PLATFORM} /bin/bash ${PURGE_SCRIPT} >> ${TIGER_MODULE_DIR}/maintenance.log 2>&1"

if crontab -l 2>/dev/null | grep -q "$PURGE_SCRIPT"; then
    LOG "VRAM purge cron job already exists, skipping."
else
    LOG "Installing the daily 5:00 AM VRAM purge cron job..."
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    LOG "Installed."
fi

LOG "Current crontab entry:"
crontab -l | grep "vram-purge"

# The baked-in value does not follow the machine. Changing TIGER_PLATFORM, or
# copying this crontab to a host of a different platform, leaves the old value
# in place — and `crontab -l` looks perfectly normal either way.
WARN "TIGER_PLATFORM=${TIGER_PLATFORM} is baked into the cron entry above."
WARN "If the platform ever changes, re-run this script; editing .env alone will not update it."

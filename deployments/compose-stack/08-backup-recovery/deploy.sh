#!/usr/bin/env bash
# =====================================================================
# TigerAI Backup/Recovery Module Initializer
# Path: deployments/compose-stack/08-backup-recovery/deploy.sh
#
# No compose file: this module is a set of maintenance scripts. They live in
# resource/_shared/ because all three stacks carried byte-identical copies.
#
# The nvidia stack had no deploy.sh here at all, so master-deploy.sh fell
# through to its "no deploy.sh" branch and never chmod'ed the scripts. The
# amd / arm64 version is taken as the merged one.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI Backup/Recovery"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

LOG "Initializing backup/recovery scripts..."

for s in backup-tigerai.sh restore-tigerai.sh setup-cron.sh vram-purge.sh; do
    chmod +x "$(tiger_res "$s")"
done

LOG "✅ Backup/Recovery module ready."

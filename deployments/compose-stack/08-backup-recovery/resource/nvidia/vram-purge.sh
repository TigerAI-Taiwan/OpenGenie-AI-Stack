#!/usr/bin/env bash
# =====================================================================
# TigerAI VRAM Purge — nvidia entry point
# Path: deployments/compose-stack/08-backup-recovery/resource/nvidia/vram-purge.sh
#
# The entry point does two things and nothing else — path derivation, the
# compose bridge and the Ollama restart all live in the shared body:
#   1. export TIGER_PLATFORM=nvidia
#   2. call tiger_vram_purge_main
#
# nvidia has no platform-specific restart step: 06-ai-core-lemonade is amd-only,
# and LLM inference here is Ollama in 03-ai-interface, which the shared body
# already restarts.
#
# WARNING: must stay at the FIRST level of resource/nvidia/. The `../..` is a
# hard-coded depth.
# =====================================================================

export TIGER_PLATFORM=nvidia

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
# shellcheck source=../_shared/vram-purge-common.sh
source "${TIGER_MODULE_DIR}/resource/_shared/vram-purge-common.sh"

tiger_vram_purge_main

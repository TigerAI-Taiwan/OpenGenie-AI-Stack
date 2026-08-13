#!/usr/bin/env bash
# =====================================================================
# TigerAI System Setup (GPU driver + Docker)
# Path: deployments/compose-stack/00-system-setup-gpu-driver-and-docker/deploy.sh
#
# Replaces the two former modules, whose names encoded the platform:
#   00-system-setup-rocm-docker     (amd)
#   00-system-setup-nvidia-docker   (nvidia and arm64, with different bodies)
#
# The per-platform installers live in resource/<platform>/install.sh. There is
# no shared body — installing ROCm, CUDA on x86 and CUDA on aarch64 have
# little in common beyond the Docker steps, and the three scripts had already
# drifted apart before the merge.
#
# NOTE: this module has no compose file. It installs host packages.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TIGER_LOG_PREFIX="TigerAI System Setup"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

INSTALLER="$(tiger_res install.sh)"
chmod +x "$INSTALLER"

LOG "Running the ${TIGER_PLATFORM} host setup..."
# -E so TIGER_PLATFORM survives the sudo boundary; the installer sources
# lib/common.sh too and would abort without it.
exec sudo -E bash "$INSTALLER" "$@"

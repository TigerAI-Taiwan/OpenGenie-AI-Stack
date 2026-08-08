#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
git -C "${repository_root}" config core.hooksPath .githooks
chmod +x "${repository_root}/.githooks/pre-push"

echo "Git hooks enabled for ${repository_root}"

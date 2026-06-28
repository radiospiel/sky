#!/bin/bash
# Session-start hook run by Claude Code.
# Add project-specific setup tasks below (e.g. install toolchain deps,
# verify environment, warm caches).
# This file is maintained by the sky submodule.

set -uo pipefail

# Example: auto-install gopls in the Claude Code cloud sandbox.
# Uncomment and customize for your language toolchain.
#
# if [ "${CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE:-}" != "cloud_default" ]; then
#   exit 0
# fi
#
# if ! command -v gopls >/dev/null 2>&1 && command -v go >/dev/null 2>&1; then
#   go install golang.org/x/tools/gopls@latest
#   mkdir -p "$HOME/.local/bin"
#   ln -sf "$(go env GOPATH)/bin/gopls" "$HOME/.local/bin/gopls"
# fi

exit 0

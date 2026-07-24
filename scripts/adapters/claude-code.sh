#!/usr/bin/env bash
# Claude Code host adapter.  bridge.sh also detects this automatically; this
# wrapper exists so every supported host has an explicit, symmetric entrypoint.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLI_BRIDGE_HOST="claude-code"
: "${CLI_BRIDGE_HOST_SESSION_ID:=${CLAUDE_CODE_SESSION_ID:-}}"
export CLI_BRIDGE_HOST_SESSION_ID
exec "$SCRIPT_DIR/../bridge.sh" "$@"

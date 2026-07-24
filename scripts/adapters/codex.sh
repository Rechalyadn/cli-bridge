#!/usr/bin/env bash
# Codex-host adapter.  It deliberately does not use Codex's *target* thread
# ID: that ID belongs to the Codex CLI conversation cli-bridge may create.
# A host integration can provide its own current session via CODEX_SESSION_ID
# or CLI_BRIDGE_HOST_SESSION_ID when Codex exposes it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLI_BRIDGE_HOST="codex"
: "${CLI_BRIDGE_HOST_SESSION_ID:=${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}"
export CLI_BRIDGE_HOST_SESSION_ID
exec "$SCRIPT_DIR/../bridge.sh" "$@"

#!/usr/bin/env bash
# OpenCode-host adapter.  OPENCode sessions created *by* cli-bridge are kept
# separately in thread/session_id; this optional value identifies the host
# conversation that invoked the skill.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLI_BRIDGE_HOST="opencode"
: "${CLI_BRIDGE_HOST_SESSION_ID:=${OPENCODE_SESSION_ID:-}}"
export CLI_BRIDGE_HOST_SESSION_ID
exec "$SCRIPT_DIR/../bridge.sh" "$@"

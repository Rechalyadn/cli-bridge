#!/usr/bin/env bash
# Integration tests for bridge-owned host/session metadata. They exercise only
# the local `list` path and never invoke a model CLI or the network.
set -eu
cd "$(dirname "$0")"

TMPHOME="$(mktemp -d)"
fail=0

assert_file() {
  local desc="$1" file="$2" expected="$3" actual=""
  [ -f "$file" ] && actual="$(cat "$file")"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (expected [$expected], got [$actual])"
    fail=1
  fi
}

CLI_BRIDGE_HOME="$TMPHOME" CODEX_SESSION_ID="root-42" \
CLI_BRIDGE_PARENT_SESSION_ID="claude-code--parent-7" \
bash ./adapters/codex.sh codex list >/dev/null

SCOPE="$TMPHOME/sessions/codex--root-42"
assert_file "Codex adapter records host" "$SCOPE/host" "codex"
assert_file "Codex adapter records host session" "$SCOPE/host_session_id" "root-42"
assert_file "Codex adapter records parent" "$SCOPE/parent_bridge_session_id" "claude-code--parent-7"

CLI_BRIDGE_HOME="$TMPHOME" OPENCODE_SESSION_ID="ses_host_12" \
bash ./adapters/opencode.sh opencode list >/dev/null
assert_file "OpenCode adapter records host" "$TMPHOME/sessions/opencode--ses_host_12/host" "opencode"

rm -rf "$TMPHOME"
[ "$fail" -eq 0 ] || exit 1
echo "--- ALL TESTS PASSED ---"

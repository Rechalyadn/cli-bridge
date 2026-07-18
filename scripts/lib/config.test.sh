#!/usr/bin/env bash
# Pure-logic tests for config.sh. No network/CLI calls, fully deterministic.
set -uo pipefail
cd "$(dirname "$0")"

TMPHOME="$(mktemp -d)"
export CLI_BRIDGE_HOME="$TMPHOME"
# shellcheck source=./config.sh
source ./config.sh

fail=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc (expected [$expected], got [$actual])"
    fail=1
  else
    echo "PASS: $desc"
  fi
}

assert_eq "no model notes initially" "" "$(read_model_notes)"
assert_eq "no guidance initially" "" "$(read_guidance)"

upsert_model_note codex gpt-5.6-sol expert "贵但最聪明，适合当辅助专家"
assert_eq "model note roundtrip" "codex|gpt-5.6-sol|expert|贵但最聪明，适合当辅助专家" "$(read_model_notes)"

upsert_model_note opencode deepseek-v4-flash bulk "量大管饱，随便使唤"
assert_eq "second model note appended" "2" "$(read_model_notes | wc -l | tr -d '[:space:]')"

upsert_model_note codex gpt-5.6-sol expert "更新后的说明"
assert_eq "upsert replaces existing entry, not appends" "2" "$(read_model_notes | wc -l | tr -d '[:space:]')"
assert_eq "upsert kept the updated note text" "codex|gpt-5.6-sol|expert|更新后的说明" "$(read_model_notes | grep '^codex|gpt-5.6-sol|')"

remove_model_note codex gpt-5.6-sol
assert_eq "remove_model_note removes only the targeted entry" "opencode|deepseek-v4-flash|bulk|量大管饱，随便使唤" "$(read_model_notes)"

remove_model_note codex nonexistent-model
assert_eq "remove_model_note on a missing entry is a no-op" "opencode|deepseek-v4-flash|bulk|量大管饱，随便使唤" "$(read_model_notes)"

write_guidance "codex 干脏活累活，opencode 备用"
assert_eq "guidance roundtrip" "codex 干脏活累活，opencode 备用" "$(read_guidance)"

write_guidance "更新后的职责分配说明"
assert_eq "guidance overwrite replaces whole file" "更新后的职责分配说明" "$(read_guidance)"

if [ "$fail" -ne 0 ]; then
  echo "--- SOME TESTS FAILED ---"
  exit 1
fi
echo "--- ALL TESTS PASSED ---"

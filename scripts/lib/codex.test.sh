#!/usr/bin/env bash
# Pure-logic tests for codex.sh's flag/parsing/error-detection helpers.
# codex_ask_raw itself calls the real `codex` CLI and is NOT covered here —
# see the manual smoke test in the plan (Task 2, Step 5).
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=./codex.sh
source ./codex.sh

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

FIXTURE_BANNER='OpenAI Codex v0.144.5
--------
workdir: C:\Users\QiuYuan
model: gpt-5.5
provider: openai
approval: never
sandbox: workspace-write [workdir, /tmp, $TMPDIR]
reasoning effort: medium
reasoning summaries: none
session id: 019f6f28-da02-70f1-9dc4-6f8522622019
--------
user
hi'

assert_eq "extract session id from banner" "019f6f28-da02-70f1-9dc4-6f8522622019" "$(codex_extract_session_id "$FIXTURE_BANNER")"
assert_eq "extract session id: no match returns empty" "" "$(codex_extract_session_id "no session id here")"

FIXTURE_UNTRUSTED="Not inside a trusted directory and --skip-git-repo-check was not specified."
if codex_is_untrusted_dir_error "$FIXTURE_UNTRUSTED"; then
  echo "PASS: detects untrusted-dir error"
else
  echo "FAIL: should detect untrusted-dir error"
  fail=1
fi
if codex_is_untrusted_dir_error "some unrelated error"; then
  echo "FAIL: should not detect untrusted-dir error in unrelated text"
  fail=1
else
  echo "PASS: does not false-positive on unrelated text"
fi

FIXTURE_INVALID_SESSION="Error: thread/resume: thread/resume failed: no rollout found for thread id 00000000-0000-0000-0000-000000000000 (code -32600)"
if codex_is_invalid_session_error "$FIXTURE_INVALID_SESSION"; then
  echo "PASS: detects invalid-session error"
else
  echo "FAIL: should detect invalid-session error"
  fail=1
fi

FIXTURE_THREAD_STARTED='{"type":"thread.started","thread_id":"019f72dc-cfeb-7090-abce-48f54014d64b"}'
assert_eq "extract session id from --json thread.started event" "019f72dc-cfeb-7090-abce-48f54014d64b" "$(codex_extract_session_id "$FIXTURE_THREAD_STARTED")"

FIXTURE_CMD_STARTED='{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"ls -la","status":"in_progress"}}'
assert_eq "activity line for command_execution start" "正在运行命令：ls -la" "$(codex_format_activity_line "$FIXTURE_CMD_STARTED")"

FIXTURE_CMD_COMPLETED='{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"ls -la","aggregated_output":"x","exit_code":0,"status":"completed"}}'
assert_eq "activity line for command_execution completion" "命令已完成（退出码 0）：ls -la" "$(codex_format_activity_line "$FIXTURE_CMD_COMPLETED")"

FIXTURE_AGENT_MESSAGE='{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"secret reply content"}}'
assert_eq "activity line suppresses agent_message content" "" "$(codex_format_activity_line "$FIXTURE_AGENT_MESSAGE")"

FIXTURE_REASONING='{"type":"item.completed","item":{"id":"item_3","type":"reasoning","text":"internal chain of thought"}}'
assert_eq "activity line suppresses reasoning content" "" "$(codex_format_activity_line "$FIXTURE_REASONING")"

assert_eq "no extra flags when model/effort empty" "" "$(codex_build_extra_flags "" "" "0")"
assert_eq "model flag" "-m
gpt-5.5" "$(codex_build_extra_flags "gpt-5.5" "" "0")"
assert_eq "model+effort flags" "-m
gpt-5.5
-c
model_reasoning_effort=high" "$(codex_build_extra_flags "gpt-5.5" "high" "0")"
assert_eq "danger flag" "-s
danger-full-access" "$(codex_build_extra_flags "" "" "1")"

if [ "$fail" -ne 0 ]; then
  echo "--- SOME TESTS FAILED ---"
  exit 1
fi
echo "--- ALL TESTS PASSED ---"

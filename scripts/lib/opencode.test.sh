#!/usr/bin/env bash
# Pure-logic tests for opencode.sh. opencode_ask_raw / opencode_session_ids
# call the real `opencode` CLI and are NOT covered here — see the manual
# smoke test in the plan (Task 3, Step 5).
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=./opencode.sh
source ./opencode.sh

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

FIXTURE_INVALID="$(printf '\033[91m\033[1mError: \033[0mSession not found')"
if opencode_is_invalid_session_error "$FIXTURE_INVALID"; then
  echo "PASS: detects invalid-session error"
else
  echo "FAIL: should detect invalid-session error"
  fail=1
fi
if opencode_is_invalid_session_error "some unrelated error"; then
  echo "FAIL: should not false-positive on unrelated text"
  fail=1
else
  echo "PASS: does not false-positive on unrelated text"
fi

FIXTURE_RAW="$(printf '\033[0m\n> build \xc2\xb7 deepseek-v4-flash-260425\n\033[0m\n\n\xe5\xb7\xb2\xe8\xae\xb0\xe4\xbd\x8f\n')"
cleaned="$(opencode_clean_reply "$FIXTURE_RAW")"
assert_eq "clean reply strips ansi/header/blank lines" "已记住" "$cleaned"

assert_eq "no extra flags when model empty" "" "$(opencode_build_extra_flags "")"
assert_eq "model flag" "-m
huoshan/deepseek-v4-flash-260425" "$(opencode_build_extra_flags "huoshan/deepseek-v4-flash-260425")"

assert_eq "finds the one newly created session" "ses_new" "$(opencode_new_session_id $'ses_old1\nses_old2' $'ses_new\nses_old2\nses_old1')"
if opencode_new_session_id $'ses_old' $'ses_other\nses_new' >/dev/null; then
  echo "FAIL: should reject ambiguous new sessions"
  fail=1
else
  echo "PASS: rejects ambiguous new sessions"
fi
if opencode_new_session_id $'ses_old' $'ses_old' >/dev/null; then
  echo "FAIL: should reject a missing new session"
  fail=1
else
  echo "PASS: rejects a missing new session"
fi

if [ "$fail" -ne 0 ]; then
  echo "--- SOME TESTS FAILED ---"
  exit 1
fi
echo "--- ALL TESTS PASSED ---"

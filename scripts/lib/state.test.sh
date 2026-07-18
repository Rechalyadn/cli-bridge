#!/usr/bin/env bash
# Pure-logic tests for state.sh. No network/CLI calls, fully deterministic.
set -uo pipefail
cd "$(dirname "$0")"

TMPHOME="$(mktemp -d)"
export CLI_BRIDGE_HOME="$TMPHOME"
export BRIDGE_SCOPE="testscope"
# shellcheck source=./state.sh
source ./state.sh

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

assert_eq "default thread initial value" "default" "$(get_default_thread codex)"

write_field codex mythread model gpt-5.5
assert_eq "model roundtrip" "gpt-5.5" "$(read_field codex mythread model)"

if find "$TMPHOME" -name '*.tmp' -print -quit | grep -q .; then
  echo "FAIL: atomic write left a temporary file"
  fail=1
else
  echo "PASS: atomic write leaves no temporary file"
fi

if acquire_thread_lock codex mythread; then
  if [ -d "$(thread_dir codex mythread)/.lock" ]; then
    echo "PASS: acquire_thread_lock creates a lock"
  else
    echo "FAIL: acquire_thread_lock did not create a lock"
    fail=1
  fi
  release_thread_lock
  if [ -d "$(thread_dir codex mythread)/.lock" ]; then
    echo "FAIL: release_thread_lock did not remove the lock"
    fail=1
  else
    echo "PASS: release_thread_lock removes the lock"
  fi
else
  echo "FAIL: acquire_thread_lock should succeed"
  fail=1
fi

if thread_exists codex mythread; then
  echo "PASS: thread_exists true after write_field"
else
  echo "FAIL: thread_exists should be true after write_field"
  fail=1
fi

if thread_exists codex neverwritten; then
  echo "FAIL: thread_exists should be false for untouched thread"
  fail=1
else
  echo "PASS: thread_exists false for untouched thread"
fi

set_default_thread codex review
assert_eq "default thread after switch" "review" "$(get_default_thread codex)"

write_field codex another model gpt-5.4
names="$(list_thread_names codex | sort | tr '\n' ',')"
assert_eq "list_thread_names" "another,mythread," "$names"

assert_eq "unset field reads empty" "" "$(read_field codex mythread effort)"

touch_last_used codex mythread
last="$(read_field codex mythread last_used)"
if [ -n "$last" ]; then
  echo "PASS: touch_last_used wrote a non-empty timestamp"
else
  echo "FAIL: touch_last_used should have written a timestamp"
  fail=1
fi

rm -rf "$TMPHOME"

if [ "$fail" -ne 0 ]; then
  echo "--- SOME TESTS FAILED ---"
  exit 1
fi
echo "--- ALL TESTS PASSED ---"

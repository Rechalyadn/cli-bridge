# cli-bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude Code Skill (`cli-bridge`) with a bundled bash script that lets Codex and OpenCode CLI conversations be resumed across multiple turns, with named parallel threads scoped to the current Claude Code conversation.

**Architecture:** A pure-bash flat-file state store (one field = one file, no JSON/jq) under `~/.claude/cli-bridge/sessions/<scope>/<tool>/threads/<thread>/`, plus three library files (`state.sh`, `codex.sh`, `opencode.sh`) with pure/testable helpers, wired together by a single dispatcher (`bridge.sh`) that parses `<tool> <action> [flags] [prompt]` and shells out to the real `codex`/`opencode` CLIs.

**Tech Stack:** bash only (no jq, no python). Targets both Git Bash (Windows, bash 5.3 here) and macOS's stock bash 3.2.

## Global Constraints

- **This directory now has its own git repo** (`~/.claude/skills/cli-bridge/.git`, initialized specifically to support the subagent-driven-development workflow's per-task commits and diff-based review packages — it is scoped to this one skill directory only, not the wider filesystem). Commit after each task's tests pass, as the task steps describe.
- **Target bash 3.2+ (macOS system default).** Do not use `mapfile`/`readarray`, associative arrays (`declare -A`), or nameref locals (`local -n`) — none of these exist in bash 3.2. Use `while IFS= read -r line; do arr+=("$line"); done < <(...)` to fill arrays from command output instead.
- **No jq, no python dependency.** State is stored as one plain-text file per field (see design.md §2.2), read/written with `cat`/`printf` only.
- **Verified facts to build against exactly** (do not re-derive or guess these — they were confirmed by live testing against the installed `codex` v0.144.5 and `opencode` CLIs on 2026-07-17):
  - Running `codex exec` outside a trusted/git directory fails with the literal text `Not inside a trusted directory and --skip-git-repo-check was not specified.` → always pass `--skip-git-repo-check`.
  - `codex exec` / `codex exec resume` both print a banner line of the exact form `session id: <uuid>` (36-char UUID) to stdout before the reply.
  - `codex exec resume <bad-uuid> --skip-git-repo-check "..."` fails with text containing the substring `no rollout found for thread id`.
  - `codex exec -o <file> ...` writes **only** the clean final agent reply to `<file>`, with no banner/log noise — this is the only text we should surface to the user, never raw stdout.
  - `opencode run -s <bad-session-id> "..."` fails with output containing the substring `Session not found`.
  - `opencode session list` prints a header line, a separator line of `─` characters, then data rows newest-first, each starting with a `ses_...` id token — the id of a session just created by `opencode run` (no `-s`) is the first field of line 3.
  - OpenCode session ids look like `ses_090d52a2effe...` — not UUIDs. Do not reuse the codex UUID regex for opencode.

## File Structure

```
~/.claude/skills/cli-bridge/
  SKILL.md                    # Task 5
  design.md                   # already written (brainstorming phase)
  plan.md                     # this file
  scripts/
    lib/
      state.sh                # Task 1 — scope/thread flat-file storage, pure, no external CLI calls
      state.test.sh            # Task 1
      codex.sh                 # Task 2 — codex flag-building/output-parsing/error-detection + codex_ask_raw
      codex.test.sh             # Task 2 (pure-logic subset only)
      opencode.sh               # Task 3 — same shape for opencode
      opencode.test.sh          # Task 3 (pure-logic subset only)
    bridge.sh                  # Task 4 — CLI dispatcher wiring the above together
```

---

### Task 1: State library

**Files:**
- Create: `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\state.sh`
- Create: `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\state.test.sh`

**Interfaces:**
- Produces (used by Tasks 2-4):
  - `resolve_scope()` → prints scope name to stdout
  - `scope_dir()` → prints absolute path to the scope's root dir
  - `thread_dir(tool, thread)` → prints absolute path to a thread's dir
  - `thread_exists(tool, thread)` → returns 0/1
  - `read_field(tool, thread, field)` → prints field value (empty if unset), never errors
  - `write_field(tool, thread, field, value)` → creates dirs as needed, writes value
  - `get_default_thread(tool)` → prints default thread name (`default` if unset)
  - `set_default_thread(tool, thread)` → persists the default thread name
  - `list_thread_names(tool)` → prints one thread name per line, nothing if none exist
  - `touch_last_used(tool, thread)` → writes current UTC ISO8601 timestamp to the `last_used` field
- Consumes: `CLI_BRIDGE_HOME` env var (optional override, defaults to `$HOME/.claude/cli-bridge`), `BRIDGE_SCOPE` env var (optional override), `CLAUDE_CODE_SESSION_ID` env var (fallback scope source)

- [ ] **Step 1: Write the failing test**

Create `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\state.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/lib/state.test.sh`
Expected: fails immediately with something like `./state.sh: No such file or directory` (state.sh doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\state.sh`:

```bash
#!/usr/bin/env bash
# state.sh - flat-file thread state storage for cli-bridge.
# Every function here is pure file I/O — no network or external CLI calls.

: "${CLI_BRIDGE_HOME:=$HOME/.claude/cli-bridge}"

resolve_scope() {
  if [ -n "${BRIDGE_SCOPE:-}" ]; then
    printf '%s' "$BRIDGE_SCOPE"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_CODE_SESSION_ID"
  else
    printf '%s' "manual"
  fi
}

scope_dir() {
  printf '%s/sessions/%s' "$CLI_BRIDGE_HOME" "$(resolve_scope)"
}

thread_dir() {
  local tool="$1" thread="$2"
  printf '%s/%s/threads/%s' "$(scope_dir)" "$tool" "$thread"
}

thread_exists() {
  local tool="$1" thread="$2"
  [ -d "$(thread_dir "$tool" "$thread")" ]
}

read_field() {
  local tool="$1" thread="$2" field="$3"
  local f
  f="$(thread_dir "$tool" "$thread")/$field"
  if [ -f "$f" ]; then
    cat "$f"
  fi
}

write_field() {
  local tool="$1" thread="$2" field="$3" value="$4"
  local d
  d="$(thread_dir "$tool" "$thread")"
  mkdir -p "$d"
  printf '%s' "$value" > "$d/$field"
}

get_default_thread() {
  local tool="$1"
  local f
  f="$(scope_dir)/$tool/default_thread"
  if [ -f "$f" ]; then
    cat "$f"
  else
    printf 'default'
  fi
}

set_default_thread() {
  local tool="$1" thread="$2"
  local d
  d="$(scope_dir)/$tool"
  mkdir -p "$d"
  printf '%s' "$thread" > "$d/default_thread"
}

list_thread_names() {
  local tool="$1"
  local d
  d="$(scope_dir)/$tool/threads"
  [ -d "$d" ] || return 0
  local t
  for t in "$d"/*/; do
    [ -d "$t" ] || continue
    t="${t%/}"
    printf '%s\n' "${t##*/}"
  done
}

touch_last_used() {
  local tool="$1" thread="$2"
  write_field "$tool" "$thread" "last_used" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/lib/state.test.sh`
Expected: every line starts with `PASS:`, ending with `--- ALL TESTS PASSED ---`, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/state.sh scripts/lib/state.test.sh
git commit -m "Add state.sh flat-file thread storage with passing tests"
```

---

### Task 2: Codex helpers

**Files:**
- Create: `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\codex.sh`
- Create: `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\codex.test.sh`

**Interfaces:**
- Consumes: nothing from Task 1 (this file is standalone; `bridge.sh` in Task 4 wires it to `state.sh`)
- Produces (used by Task 4):
  - `codex_extract_session_id(raw_text)` → prints the UUID from a `session id: <uuid>` line, or empty
  - `codex_is_untrusted_dir_error(raw_text)` → returns 0/1
  - `codex_is_invalid_session_error(raw_text)` → returns 0/1
  - `codex_build_extra_flags(model, effort, danger)` → prints extra CLI flags, one token per line
  - `codex_ask_raw(session_id_or_empty, prompt, reply_file, sid_out_file, [extra_flags...])` → runs `codex exec` (new) or `codex exec resume` (continuing); on success writes the clean reply to `reply_file`, the (possibly new) session id to `sid_out_file`, returns 0; on failure writes raw combined output to `reply_file`, returns 1

- [ ] **Step 1: Write the failing test (pure-logic functions only — `codex_ask_raw` needs the real CLI and is smoke-tested manually in Step 5, not here)**

Create `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\codex.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/lib/codex.test.sh`
Expected: fails with `./codex.sh: No such file or directory` (codex.sh doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\codex.sh`:

```bash
#!/usr/bin/env bash
# codex.sh - codex-specific helpers for cli-bridge.
# codex_extract_session_id / codex_is_*_error / codex_build_extra_flags are
# pure text-processing and are unit-tested in codex.test.sh. codex_ask_raw
# shells out to the real `codex` CLI and is covered by a manual smoke test
# only (see plan.md Task 2, Step 5) — it is not practical or desirable to
# hit the real Codex API in an automated test.

CODEX_UNTRUSTED_DIR_MARKER="Not inside a trusted directory"
CODEX_INVALID_SESSION_MARKER="no rollout found for thread id"

codex_extract_session_id() {
  local raw="$1"
  printf '%s' "$raw" | grep -o 'session id: [0-9a-f-]\{36\}' | head -n1 | sed 's/^session id: //'
}

codex_is_untrusted_dir_error() {
  local raw="$1"
  case "$raw" in
    *"$CODEX_UNTRUSTED_DIR_MARKER"*) return 0 ;;
    *) return 1 ;;
  esac
}

codex_is_invalid_session_error() {
  local raw="$1"
  case "$raw" in
    *"$CODEX_INVALID_SESSION_MARKER"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints extra codex flags, one token per line, for the given thread settings.
codex_build_extra_flags() {
  local model="$1" effort="$2" danger="$3"
  if [ -n "$model" ]; then
    printf -- '-m\n%s\n' "$model"
  fi
  if [ -n "$effort" ]; then
    printf -- '-c\nmodel_reasoning_effort=%s\n' "$effort"
  fi
  if [ "$danger" = "1" ]; then
    printf -- '-s\ndanger-full-access\n'
  fi
}

# codex_ask_raw SESSION_ID_OR_EMPTY PROMPT REPLY_FILE SESSION_ID_OUT_FILE [EXTRA_FLAGS...]
# On success: writes the clean reply to REPLY_FILE, writes the (possibly
# new) session id to SESSION_ID_OUT_FILE, returns 0.
# On failure: writes raw combined stdout+stderr to REPLY_FILE, returns 1.
# --skip-git-repo-check is always passed (see Global Constraints).
codex_ask_raw() {
  local session_id="$1" prompt="$2" reply_file="$3" sid_out_file="$4"
  shift 4
  local extra=("$@")
  local raw status
  # NOTE: bash <4.4 (including macOS's stock 3.2) throws "unbound variable"
  # under `set -u` when expanding "${extra[@]}" on a zero-element array.
  # Branch on length instead of expanding a possibly-empty array directly.
  if [ -n "$session_id" ]; then
    if [ "${#extra[@]}" -gt 0 ]; then
      raw="$(codex exec resume "$session_id" --skip-git-repo-check -o "$reply_file" "${extra[@]}" "$prompt" 2>&1)"
    else
      raw="$(codex exec resume "$session_id" --skip-git-repo-check -o "$reply_file" "$prompt" 2>&1)"
    fi
    status=$?
  else
    if [ "${#extra[@]}" -gt 0 ]; then
      raw="$(codex exec --skip-git-repo-check -o "$reply_file" "${extra[@]}" "$prompt" 2>&1)"
    else
      raw="$(codex exec --skip-git-repo-check -o "$reply_file" "$prompt" 2>&1)"
    fi
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    printf '%s' "$raw" > "$reply_file"
    return 1
  fi
  codex_extract_session_id "$raw" > "$sid_out_file"
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/lib/codex.test.sh`
Expected: every line starts with `PASS:`, ending with `--- ALL TESTS PASSED ---`, exit code 0.

- [ ] **Step 5: Manual smoke test of `codex_ask_raw` against the real CLI, run under `set -u` with zero extra flags (not automated — run once by hand and eyeball the result)**

Run under `set -u` specifically because that's what `bridge.sh` (Task 4) runs under, and calling with no extra flags is the common case (no model/effort override) — this combination is exactly what would trip an unguarded `"${extra[@]}"` expansion on bash <4.4:

```bash
cd scripts/lib
bash -c '
set -uo pipefail
source ./codex.sh
reply=$(mktemp); sid=$(mktemp)
codex_ask_raw "" "只回复一个词：冒烟测试" "$reply" "$sid"
echo "exit status: $?"
echo "reply: $(cat "$reply")"
echo "session id captured: $(cat "$sid")"
rm -f "$reply" "$sid"
'
```

Expected: exit status `0`, reply contains something like "冒烟测试" with no banner noise, session id looks like a UUID, and critically **no "unbound variable" error**.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/codex.sh scripts/lib/codex.test.sh
git commit -m "Add codex.sh helpers with passing tests and manual smoke test"
```

---

### Task 3: OpenCode helpers

**Files:**
- Create: `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\opencode.sh`
- Create: `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\opencode.test.sh`

**Interfaces:**
- Consumes: nothing from Tasks 1-2 (standalone; wired together in Task 4)
- Produces (used by Task 4):
  - `opencode_is_invalid_session_error(raw_text)` → returns 0/1
  - `opencode_clean_reply(raw_text)` → prints reply with ANSI codes, `>` header lines, and blank lines stripped
  - `opencode_build_extra_flags(model)` → prints extra CLI flags, one token per line
  - `opencode_latest_session_id()` → prints the most-recently-updated session id from `opencode session list`
  - `opencode_ask_raw(session_id_or_empty, prompt, reply_file, sid_out_file, [extra_flags...])` → same contract shape as `codex_ask_raw`

- [ ] **Step 1: Write the failing test (pure-logic functions only)**

Create `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\opencode.test.sh`:

```bash
#!/usr/bin/env bash
# Pure-logic tests for opencode.sh. opencode_ask_raw / opencode_latest_session_id
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

if [ "$fail" -ne 0 ]; then
  echo "--- SOME TESTS FAILED ---"
  exit 1
fi
echo "--- ALL TESTS PASSED ---"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/lib/opencode.test.sh`
Expected: fails with `./opencode.sh: No such file or directory` (opencode.sh doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\lib\opencode.sh`:

```bash
#!/usr/bin/env bash
# opencode.sh - opencode-specific helpers for cli-bridge.
# opencode_is_invalid_session_error / opencode_clean_reply / opencode_build_extra_flags
# are pure text-processing and are unit-tested in opencode.test.sh.
# opencode_ask_raw / opencode_latest_session_id shell out to the real
# `opencode` CLI and are covered by a manual smoke test only (see plan.md
# Task 3, Step 5).

OPENCODE_INVALID_SESSION_MARKER="Session not found"

opencode_is_invalid_session_error() {
  local raw="$1"
  case "$raw" in
    *"$OPENCODE_INVALID_SESSION_MARKER"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Strips ANSI escape codes, opencode's "> build · model" header line(s),
# and blank lines, leaving just the reply text.
opencode_clean_reply() {
  local raw="$1"
  local esc
  esc=$(printf '\033')
  printf '%s\n' "$raw" \
    | sed "s/${esc}\[[0-9;]*m//g" \
    | grep -v '^>' \
    | sed '/^[[:space:]]*$/d'
}

opencode_build_extra_flags() {
  local model="$1"
  if [ -n "$model" ]; then
    printf -- '-m\n%s\n' "$model"
  fi
}

# Prints the most-recently-updated session id. Best-effort: assumes no
# concurrent opencode usage happens between a run and this call.
opencode_latest_session_id() {
  opencode session list 2>/dev/null | sed -n '3p' | awk '{print $1}'
}

# opencode_ask_raw SESSION_ID_OR_EMPTY PROMPT REPLY_FILE SESSION_ID_OUT_FILE [EXTRA_FLAGS...]
opencode_ask_raw() {
  local session_id="$1" prompt="$2" reply_file="$3" sid_out_file="$4"
  shift 4
  local extra=("$@")
  local raw status
  # NOTE: bash <4.4 (including macOS's stock 3.2) throws "unbound variable"
  # under `set -u` when expanding "${extra[@]}" on a zero-element array.
  # Branch on length instead of expanding a possibly-empty array directly.
  if [ -n "$session_id" ]; then
    if [ "${#extra[@]}" -gt 0 ]; then
      raw="$(opencode run --auto -s "$session_id" "${extra[@]}" "$prompt" 2>&1)"
    else
      raw="$(opencode run --auto -s "$session_id" "$prompt" 2>&1)"
    fi
    status=$?
  else
    if [ "${#extra[@]}" -gt 0 ]; then
      raw="$(opencode run --auto "${extra[@]}" "$prompt" 2>&1)"
    else
      raw="$(opencode run --auto "$prompt" 2>&1)"
    fi
    status=$?
  fi
  if [ "$status" -ne 0 ] || opencode_is_invalid_session_error "$raw"; then
    printf '%s' "$raw" > "$reply_file"
    return 1
  fi
  opencode_clean_reply "$raw" > "$reply_file"
  if [ -n "$session_id" ]; then
    printf '%s' "$session_id" > "$sid_out_file"
  else
    opencode_latest_session_id > "$sid_out_file"
  fi
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/lib/opencode.test.sh`
Expected: every line starts with `PASS:`, ending with `--- ALL TESTS PASSED ---`, exit code 0.

- [ ] **Step 5: Manual smoke test of `opencode_ask_raw` against the real CLI, run under `set -u` with zero extra flags (not automated)**

Run under `set -u` specifically because that's what `bridge.sh` (Task 4) runs under, and calling with no extra flags is the common case (no model override) — this combination is exactly what would trip an unguarded `"${extra[@]}"` expansion on bash <4.4:

```bash
cd scripts/lib
bash -c '
set -uo pipefail
source ./opencode.sh
reply=$(mktemp); sid=$(mktemp)
opencode_ask_raw "" "只回复一个词：冒烟测试" "$reply" "$sid"
echo "exit status: $?"
echo "reply: $(cat "$reply")"
echo "session id captured: $(cat "$sid")"
rm -f "$reply" "$sid"
'
```

Expected: exit status `0`, reply contains something like "冒烟测试" with no ANSI/header noise, session id looks like `ses_...`, and critically **no "unbound variable" error**.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/opencode.sh scripts/lib/opencode.test.sh
git commit -m "Add opencode.sh helpers with passing tests and manual smoke test"
```

---

### Task 4: Main dispatcher (`bridge.sh`)

**Files:**
- Create: `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\bridge.sh`

**Interfaces:**
- Consumes: everything produced in Tasks 1-3 (`state.sh`, `codex.sh`, `opencode.sh` functions, called exactly by the names listed in their Interfaces sections above)
- Produces: the `bridge.sh <tool> <action> ...` CLI described in design.md §3 — this is the final user/Claude-facing surface, no later task builds on top of its internals.

- [ ] **Step 1: Write the implementation**

There is no automated-test-first cycle for this task's `ask` path — it is thin orchestration over Tasks 1-3, whose logic is already unit-tested, plus a call to the real CLI that can't be meaningfully mocked. The local-only actions (`list`/`switch`/`model`/`effort`/`new`) **are** deterministic and get an automated test in Step 3.

Create `C:\Users\QiuYuan\.claude\skills\cli-bridge\scripts\bridge.sh`:

```bash
#!/usr/bin/env bash
# bridge.sh - cli-bridge entry point. See ../design.md for the full design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=./lib/codex.sh
source "$SCRIPT_DIR/lib/codex.sh"
# shellcheck source=./lib/opencode.sh
source "$SCRIPT_DIR/lib/opencode.sh"

DEFAULT_TIMEOUT=720

# Portable timeout: works without GNU coreutils' `timeout` (absent by
# default on macOS). Polls once a second; exit 124 signals a timeout,
# matching GNU timeout's convention.
run_with_timeout() {
  local secs="$1"; shift
  # `set -m` puts the backgrounded job in its own process group (pgid ==
  # pid of the group leader). Without this, killing $pid on timeout only
  # kills the subshell wrapper -- the actual codex/opencode process (a
  # grandchild spawned via `$(...)` inside codex_ask_raw/opencode_ask_raw)
  # is not a direct child of $pid and survives, orphaned, still consuming
  # API/quota after we've already reported "timed out". Killing the whole
  # group (`-$pid`) reaches it. Verified empirically that a grandchild
  # process spawned this way is actually terminated by this approach.
  set -m
  ("$@") &
  local pid=$!
  set +m
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  return $?
}

usage() {
  cat <<'EOF'
Usage: bridge.sh <codex|opencode> <ask|new|switch|list|model|effort> [options] [prompt]

  ask    [--thread NAME] [--model M] [--effort LEVEL] [--danger-full-access] "<prompt>"
  new    --thread NAME [--model M] [--effort LEVEL]
  switch <thread>
  list
  model  <thread> <model>
  effort <thread> <level>      (codex only)

Global: --scope NAME (overrides CLAUDE_CODE_SESSION_ID-based scope), --timeout SECONDS
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

[ $# -ge 1 ] || { usage; exit 1; }

# First pass: pull --scope out from anywhere in the arg list, so it's set
# before any state.sh function runs, regardless of where the user put it.
args=("$@")
filtered=()
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  if [ "$a" = "--scope" ]; then
    i=$((i + 1))
    # NOTE: bash <4.4 throws "unbound variable" under `set -u` when indexing
    # past the end of an array (e.g. `--scope` is the very last CLI token,
    # with no value after it) -- check bounds before indexing.
    [ "$i" -lt "${#args[@]}" ] || die "missing value for --scope"
    export BRIDGE_SCOPE="${args[$i]}"
  else
    filtered+=("$a")
  fi
  i=$((i + 1))
done
# NOTE: bash <4.4 throws "unbound variable" under `set -u` when expanding
# "${filtered[@]}" if filtered ended up with zero elements (e.g. the user
# ran `bridge.sh --scope foo` with nothing else) — branch on length instead.
if [ "${#filtered[@]}" -gt 0 ]; then
  set -- "${filtered[@]}"
else
  set --
fi

[ $# -ge 1 ] || { usage; exit 1; }
TOOL="$1"; shift
[ "$TOOL" = "codex" ] || [ "$TOOL" = "opencode" ] || die "unknown tool '$TOOL' (expected codex or opencode)"

[ $# -ge 1 ] || { usage; exit 1; }
ACTION="$1"; shift

THREAD=""
MODEL=""
EFFORT=""
DANGER=0
TIMEOUT="$DEFAULT_TIMEOUT"
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    # NOTE: bash <4.4 throws "unbound variable" under `set -u` when reading
    # "$2" if the flag is the last CLI token (no value follows it) --
    # check `$#` before consuming it, same hazard family as the array-guard
    # fixes above.
    --thread) [ $# -ge 2 ] || die "missing value for --thread"; THREAD="$2"; shift 2 ;;
    --model) [ $# -ge 2 ] || die "missing value for --model"; MODEL="$2"; shift 2 ;;
    --effort) [ $# -ge 2 ] || die "missing value for --effort"; EFFORT="$2"; shift 2 ;;
    --danger-full-access) DANGER=1; shift ;;
    --timeout) [ $# -ge 2 ] || die "missing value for --timeout"; TIMEOUT="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [ "$TOOL" = "opencode" ] && { [ -n "$EFFORT" ] || [ "$DANGER" -eq 1 ]; }; then
  die "--effort/--danger-full-access are codex-only"
fi

do_list() {
  local names
  names="$(list_thread_names "$TOOL")"
  if [ -z "$names" ]; then
    echo "暂无线程"
    return 0
  fi
  local dflt
  dflt="$(get_default_thread "$TOOL")"
  echo "$names" | while IFS= read -r name; do
    local sid model effort last marker
    sid="$(read_field "$TOOL" "$name" session_id)"
    model="$(read_field "$TOOL" "$name" model)"
    effort="$(read_field "$TOOL" "$name" effort)"
    last="$(read_field "$TOOL" "$name" last_used)"
    marker=" "
    [ "$name" = "$dflt" ] && marker="*"
    printf '%s %-12s session=%-10s model=%-20s effort=%-8s last_used=%s\n' \
      "$marker" "$name" "${sid:0:10}" "${model:-<default>}" "${effort:-<default>}" "${last:-never}"
  done
}

do_switch() {
  local thread="${POSITIONAL[0]:-}"
  [ -n "$thread" ] || die "usage: bridge.sh $TOOL switch <thread>"
  set_default_thread "$TOOL" "$thread"
  echo "已切换默认线程为 $thread"
}

do_model() {
  local thread="${POSITIONAL[0]:-}" model="${POSITIONAL[1]:-}"
  [ -n "$thread" ] && [ -n "$model" ] || die "usage: bridge.sh $TOOL model <thread> <model>"
  write_field "$TOOL" "$thread" model "$model"
  echo "线程 $thread 的模型已设为 $model"
}

do_effort() {
  [ "$TOOL" = "codex" ] || die "effort 仅 codex 支持"
  local thread="${POSITIONAL[0]:-}" level="${POSITIONAL[1]:-}"
  [ -n "$thread" ] && [ -n "$level" ] || die "usage: bridge.sh codex effort <thread> <level>"
  write_field "$TOOL" "$thread" effort "$level"
  echo "线程 $thread 的 reasoning effort 已设为 $level"
}

do_new() {
  [ -n "$THREAD" ] || die "usage: bridge.sh $TOOL new --thread NAME [--model M] [--effort E]"
  local existing_model existing_effort
  existing_model="$(read_field "$TOOL" "$THREAD" model)"
  existing_effort="$(read_field "$TOOL" "$THREAD" effort)"
  write_field "$TOOL" "$THREAD" session_id ""
  write_field "$TOOL" "$THREAD" model "${MODEL:-$existing_model}"
  [ "$TOOL" = "codex" ] && write_field "$TOOL" "$THREAD" effort "${EFFORT:-$existing_effort}"
  echo "线程 $THREAD 已重置，下次 ask 会建立新会话"
}

do_ask() {
  local prompt="${POSITIONAL[0]:-}"
  [ -n "$prompt" ] || die "usage: bridge.sh $TOOL ask [--thread NAME] \"<prompt>\""
  local thread="${THREAD:-$(get_default_thread "$TOOL")}"
  local session_id model effort
  session_id="$(read_field "$TOOL" "$thread" session_id)"
  model="${MODEL:-$(read_field "$TOOL" "$thread" model)}"
  effort="${EFFORT:-$(read_field "$TOOL" "$thread" effort)}"

  local reply_file sid_out_file
  reply_file="$(mktemp)"
  sid_out_file="$(mktemp)"

  local extra=()
  local status

  # NOTE: bash <4.4 throws "unbound variable" under `set -u` (this script's
  # own header) when expanding "${extra[@]}" on a zero-element array — the
  # common case, since most threads have no model/effort override. Branch
  # on length instead of expanding a possibly-empty array directly.
  if [ "$TOOL" = "codex" ]; then
    # `codex exec resume` does not accept -s/--sandbox at all (confirmed
    # live: "unexpected argument '-s' found") -- sandbox mode is fixed at
    # session creation and cannot be changed on resume. Force danger off
    # when resuming (non-empty session_id), and tell the caller why if
    # they actually asked for it, instead of silently dropping the flag.
    local effective_danger="$DANGER"
    if [ -n "$session_id" ] && [ "$DANGER" -eq 1 ]; then
      echo "注意：--danger-full-access 对续接的线程无效（沙盒模式在会话创建时就已固定），本次调用未生效" >&2
      effective_danger=0
    fi
    while IFS= read -r line; do
      [ -n "$line" ] && extra+=("$line")
    done < <(codex_build_extra_flags "$model" "$effort" "$effective_danger")
    if [ "${#extra[@]}" -gt 0 ]; then
      run_with_timeout "$TIMEOUT" codex_ask_raw "$session_id" "$prompt" "$reply_file" "$sid_out_file" "${extra[@]}"
    else
      run_with_timeout "$TIMEOUT" codex_ask_raw "$session_id" "$prompt" "$reply_file" "$sid_out_file"
    fi
    status=$?
  else
    while IFS= read -r line; do
      [ -n "$line" ] && extra+=("$line")
    done < <(opencode_build_extra_flags "$model")
    if [ "${#extra[@]}" -gt 0 ]; then
      run_with_timeout "$TIMEOUT" opencode_ask_raw "$session_id" "$prompt" "$reply_file" "$sid_out_file" "${extra[@]}"
    else
      run_with_timeout "$TIMEOUT" opencode_ask_raw "$session_id" "$prompt" "$reply_file" "$sid_out_file"
    fi
    status=$?
  fi

  if [ "$status" -eq 124 ]; then
    rm -f "$reply_file" "$sid_out_file"
    die "超时未完成（超过 ${TIMEOUT} 秒）"
  fi

  if [ "$status" -ne 0 ]; then
    local raw
    raw="$(cat "$reply_file")"
    rm -f "$reply_file" "$sid_out_file"
    if [ "$TOOL" = "codex" ] && codex_is_untrusted_dir_error "$raw"; then
      die "未预期的 trusted-directory 报错，请检查 bridge.sh 是否传了 --skip-git-repo-check"
    fi
    if [ "$TOOL" = "codex" ] && codex_is_invalid_session_error "$raw"; then
      die "线程 $thread 的会话已失效，请用 'bridge.sh codex new --thread $thread' 重建"
    fi
    if [ "$TOOL" = "opencode" ] && opencode_is_invalid_session_error "$raw"; then
      die "线程 $thread 的会话已失效，请用 'bridge.sh opencode new --thread $thread' 重建"
    fi
    die "$raw"
  fi

  cat "$reply_file"
  local new_sid
  new_sid="$(cat "$sid_out_file")"
  rm -f "$reply_file" "$sid_out_file"
  if [ -n "$new_sid" ]; then
    write_field "$TOOL" "$thread" session_id "$new_sid"
  fi
  touch_last_used "$TOOL" "$thread"
  if [ -n "$model" ] && [ -z "$(read_field "$TOOL" "$thread" model)" ]; then
    write_field "$TOOL" "$thread" model "$model"
  fi
  if [ "$TOOL" = "codex" ] && [ -n "$effort" ] && [ -z "$(read_field "$TOOL" "$thread" effort)" ]; then
    write_field "$TOOL" "$thread" effort "$effort"
  fi
}

case "$ACTION" in
  ask) do_ask ;;
  new) do_new ;;
  switch) do_switch ;;
  list) do_list ;;
  model) do_model ;;
  effort) do_effort ;;
  *) usage; exit 1 ;;
esac
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/bridge.sh`

- [ ] **Step 3: Automated test of the local-only actions (no real CLI calls)**

Run this directly in the shell (not a checked-in test file — it's a one-time verification of the dispatcher's local-state actions):

```bash
export CLI_BRIDGE_HOME="$(mktemp -d)"
export BRIDGE_SCOPE="dispatcher-test"
cd scripts

bash bridge.sh codex list
# Expected: 暂无线程

bash bridge.sh codex model review gpt-5.5
bash bridge.sh codex effort review high
bash bridge.sh codex switch review
bash bridge.sh codex list
# Expected: one line for "review", marked with "*" (it's now the default),
# showing model=gpt-5.5 effort=high, session=<10 blank-ish chars> (empty
# session id since no ask has run yet), last_used=never

bash bridge.sh opencode effort review high
# Expected: exits non-zero with "Error: effort 仅 codex 支持" (this is the
# `effort` ACTION, handled by do_effort's own tool check -- distinct from
# the `--effort`/`--danger-full-access` FLAG check below, which fires a
# different message)

bash bridge.sh opencode ask --effort high "hello"
# Expected: exits non-zero with "Error: --effort/--danger-full-access are codex-only"

bash bridge.sh codex new --thread review
bash bridge.sh codex list
# Expected: review's model/effort are preserved (gpt-5.5 / high), session
# cleared

rm -rf "$CLI_BRIDGE_HOME"
```

- [ ] **Step 4: Manual smoke test of `ask` against the real CLIs — this is the acceptance test for the whole feature, and explicitly walks through all 9 scenarios from design.md §8 (not automated: it calls the real Codex/OpenCode APIs)**

```bash
export CLI_BRIDGE_HOME="$(mktemp -d)"
export BRIDGE_SCOPE="scope-a"
cd scripts

# --- design.md scenario 1: bare `ask` (no --thread) auto-creates "default" ---
bash bridge.sh codex ask "记住这个数字：11。只回复\"已记住\"。"
# Expected: 已记住
bash bridge.sh codex list
# Expected: a "default" thread, marked with "*", non-empty session_id

# --- scenario 2: same thread, second ask recalls the number -> continuity works ---
bash bridge.sh codex ask "我刚才让你记住的数字是多少？"
# Expected: 11

# --- scenario 3: new --thread review --model gpt-5.5, ask --thread review uses it ---
bash bridge.sh codex new --thread review --model gpt-5.5
bash bridge.sh codex ask --thread review "只回复一个词：模型测试"
bash bridge.sh codex list
# Expected: review row shows model=gpt-5.5

# --- scenario 4: switch review, then bare ask (no --thread) lands on review ---
bash bridge.sh codex switch review
bash bridge.sh codex ask "记住这个数字：99。只回复\"已记住\"。"
bash bridge.sh codex list
# Expected: review's last_used is now the most recent (the bare ask went to
# review, not default) -- confirm by then running:
bash bridge.sh codex ask --thread review "我刚才让你记住的数字是多少？"
# Expected: 99 (proves the bare ask above actually landed on review's session)

# --- scenario 5: list shows thread/session_id/model together ---
bash bridge.sh codex list
# Expected: both "default" and "review" rows show non-empty session_id and correct model column

# --- scenario 6: corrupted session_id -> clear "线程已失效" error, not a hang or silent new session ---
review_dir="$CLI_BRIDGE_HOME/sessions/scope-a/codex/threads/review"
echo "00000000-0000-0000-0000-000000000000" > "$review_dir/session_id"
bash bridge.sh codex ask --thread review "hello"; echo "exit status: $?"
# Expected: stderr "Error: 线程 review 的会话已失效，请用 'bridge.sh codex new --thread review' 重建", exit status 1

# --- scenario 9: everything above ran with cwd inside $HOME, which is not a
# git repo -- if --skip-git-repo-check weren't being passed, every command
# above would have failed with "Not inside a trusted directory" instead of
# the expected output, so this is implicitly verified by every prior step
# succeeding. ---

# --- scenario 8: switching --scope isolates threads ---
export BRIDGE_SCOPE="scope-b"
bash bridge.sh codex list
# Expected: 暂无线程 (scope-b has never seen "review" or "default" --
# proves scope-a's threads are invisible here)
export BRIDGE_SCOPE="scope-a"

# --- scenario 7: repeat 1/2/4/5 for opencode ---
bash bridge.sh opencode ask --model huoshan/deepseek-v4-flash-260425 "记住这个数字：22。只回复\"已记住\"。"
bash bridge.sh opencode ask "我刚才让你记住的数字是多少？"
# Expected: 22
bash bridge.sh opencode switch default
bash bridge.sh opencode list
# Expected: default row present with non-empty session_id (ses_...) and model

rm -rf "$CLI_BRIDGE_HOME"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/bridge.sh
git commit -m "Add bridge.sh dispatcher wiring state/codex/opencode together"
```

---

### Task 5: SKILL.md

**Files:**
- Create: `C:\Users\QiuYuan\.claude\skills\cli-bridge\SKILL.md`

**Interfaces:**
- Consumes: the `bridge.sh` CLI surface from Task 4 (documents it, doesn't change it)
- Produces: nothing further consumes this — it's the terminal deliverable that makes the skill discoverable/invocable in Claude Code.

- [ ] **Step 1: Write SKILL.md**

Create `C:\Users\QiuYuan\.claude\skills\cli-bridge\SKILL.md`:

```markdown
---
name: cli-bridge
description: Maintain multi-turn, resumable conversations with the Codex and OpenCode CLIs, scoped to the current Claude Code conversation. Use when the user asks to "tell codex...", "ask opencode...", wants Codex/OpenCode to remember earlier turns, or wants to manage named codex/opencode threads (switch/list/model/effort).
---

# cli-bridge

Wraps `codex exec` / `codex exec resume` and `opencode run` so conversations
with Codex / OpenCode can span multiple turns, instead of the one-shot
behavior of the Multi-CLI MCP's `Ask-Codex` / `Ask-OpenCode` tools. See
`design.md` next to this file for the full design rationale, and `plan.md`
for how it was built.

## When to use this instead of Ask-Codex / Ask-OpenCode

- The user wants Codex/OpenCode to remember something from an earlier call
  in the same Claude Code conversation.
- The user wants multiple independent named conversations with Codex/OpenCode
  running in parallel (e.g. one exploring, one reviewing).
- The user explicitly invokes `/cli-bridge ...`.

For a genuine one-off question with no need for follow-up, `Ask-Codex` /
`Ask-OpenCode` are simpler — prefer those when continuity isn't needed.

## Usage

```
bash scripts/bridge.sh <codex|opencode> ask    [--thread NAME] [--model M] [--effort LEVEL] [--danger-full-access] "<prompt>"
bash scripts/bridge.sh <codex|opencode> new    --thread NAME [--model M] [--effort LEVEL]
bash scripts/bridge.sh <codex|opencode> switch <thread>
bash scripts/bridge.sh <codex|opencode> list
bash scripts/bridge.sh <codex|opencode> model  <thread> <model>
bash scripts/bridge.sh codex effort <thread> <level>
```

`--thread` defaults to whatever `switch` last set (starts as `default`,
auto-created on first `ask`). `--scope NAME` overrides the automatic
per-conversation binding (`$CLAUDE_CODE_SESSION_ID`, or `manual` outside
Claude Code). `--effort` and `--danger-full-access` are codex-only.

This is a plain bash script with no Claude Code dependency — it also runs
standalone in any terminal (Windows Git Bash, macOS bash/zsh) for manual
debugging, outside of any Claude Code conversation.

## Calling from Claude

`ask` can take 1-15 minutes (it calls a real LLM CLI). Always invoke it via
the Bash tool with `run_in_background: true` and rely on the automatic
completion notification — do not poll or sleep-loop waiting for it.
Management actions (`new`, `switch`, `list`, `model`, `effort`) are instant
local file operations; run those in the foreground.

## Known error messages

- `线程 X 的会话已失效，请用 'bridge.sh <tool> new --thread X' 重建` — the
  underlying codex/opencode session was deleted or expired. Recreate the
  thread with `new`; there's no automatic recovery.
- `超时未完成（超过 N 秒）` — the call exceeded `--timeout` (default 720s).
  Retry, raise `--timeout`, or lower `--effort`.
```

- [ ] **Step 2: Verify the skill is discoverable**

Run: `ls ~/.claude/skills/cli-bridge/` and confirm `SKILL.md`, `design.md`, `plan.md`, and `scripts/` (with `bridge.sh` and `lib/`) are all present. This skill will be picked up the next time skills are listed (per-session skill discovery) — no separate registration step is needed.

- [ ] **Step 3: Commit**

```bash
git add SKILL.md
git commit -m "Add SKILL.md documenting cli-bridge usage"
```

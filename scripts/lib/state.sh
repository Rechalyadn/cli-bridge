#!/usr/bin/env bash
# state.sh - flat-file thread state storage for cli-bridge.
# Every function here is pure file I/O — no network or external CLI calls.

: "${CLI_BRIDGE_HOME:=$HOME/.claude/cli-bridge}"
: "${CLI_BRIDGE_LOCK_WAIT_SECONDS:=30}"

# Process-local state used by acquire_thread_lock/release_thread_lock. A
# directory lock is portable across macOS and the Git Bash environments used
# on Windows.
THREAD_LOCK_DIR=""

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

atomic_write_file() {
  local target="$1" value="$2" parent base tmp
  parent="${target%/*}"
  base="${target##*/}"
  mkdir -p "$parent" || return 1
  tmp="$parent/.${base}.${$}.tmp"
  printf '%s' "$value" > "$tmp" && mv -f "$tmp" "$target"
}

write_field() {
  local tool="$1" thread="$2" field="$3" value="$4"
  local d
  d="$(thread_dir "$tool" "$thread")"
  atomic_write_file "$d/$field" "$value"
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
  atomic_write_file "$d/default_thread" "$thread"
}

acquire_thread_lock() {
  local tool="$1" thread="$2" lock owner waited=0
  lock="$(thread_dir "$tool" "$thread")/.lock"
  mkdir -p "${lock%/*}" || return 1

  while ! mkdir "$lock" 2>/dev/null; do
    owner=""
    [ -f "$lock/pid" ] && owner="$(cat "$lock/pid" 2>/dev/null || true)"
    case "$owner" in
      ''|*[!0-9]*) ;;
      *)
        if ! kill -0 "$owner" 2>/dev/null; then
          rm -f "$lock/pid"
          rmdir "$lock" 2>/dev/null || true
          continue
        fi
        ;;
    esac
    [ "$waited" -lt "$CLI_BRIDGE_LOCK_WAIT_SECONDS" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done

  printf '%s' "$$" > "$lock/pid"
  THREAD_LOCK_DIR="$lock"
}

release_thread_lock() {
  [ -n "${THREAD_LOCK_DIR:-}" ] || return 0
  rm -f "$THREAD_LOCK_DIR/pid"
  rmdir "$THREAD_LOCK_DIR" 2>/dev/null || true
  THREAD_LOCK_DIR=""
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

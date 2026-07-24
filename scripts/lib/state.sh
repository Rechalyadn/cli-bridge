#!/usr/bin/env bash
# state.sh - flat-file thread state storage for cli-bridge.
# Every function here is pure file I/O — no network or external CLI calls.

: "${CLI_BRIDGE_HOME:=$HOME/.cli-bridge}"
: "${CLI_BRIDGE_LOCK_WAIT_SECONDS:=30}"

# Process-local state used by acquire_thread_lock/release_thread_lock. A
# directory lock is portable across macOS and the Git Bash environments used
# on Windows.
THREAD_LOCK_DIR=""

resolve_host() {
  if [ -n "${CLI_BRIDGE_HOST:-}" ]; then
    printf '%s' "$CLI_BRIDGE_HOST"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf '%s' "claude-code"
  else
    printf '%s' "manual"
  fi
}

resolve_host_session_id() {
  if [ -n "${CLI_BRIDGE_HOST_SESSION_ID:-}" ]; then
    printf '%s' "$CLI_BRIDGE_HOST_SESSION_ID"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_CODE_SESSION_ID"
  else
    # Codex/OpenCode adapters set CLI_BRIDGE_HOST_SESSION_ID when their host
    # exposes one.  Do not invent a native session ID here: a stable but
    # incorrect binding is worse than requiring an explicit --host-session.
    printf '%s' "manual"
  fi
}

resolve_parent_bridge_session_id() {
  if [ -n "${CLI_BRIDGE_PARENT_SESSION_ID:-}" ]; then
    printf '%s' "$CLI_BRIDGE_PARENT_SESSION_ID"
  elif [ -n "${CLI_BRIDGE_BRIDGE_SESSION_ID:-}" ]; then
    # A bridge-created child process inherits this value.  Its adapter can
    # therefore attach the child's host session to the parent without asking
    # the calling agent to rediscover any native IDs.
    printf '%s' "$CLI_BRIDGE_BRIDGE_SESSION_ID"
  fi
}

resolve_scope() {
  if [ -n "${BRIDGE_SCOPE:-}" ]; then
    printf '%s' "$BRIDGE_SCOPE"
  else
    printf '%s--%s' "$(resolve_host)" "$(resolve_host_session_id)"
  fi
}

scope_dir() {
  printf '%s/sessions/%s' "$CLI_BRIDGE_HOME" "$(resolve_scope)"
}

# Record bridge-owned lineage once per logical session.  Native Codex and
# OpenCode IDs remain thread fields; this metadata describes the host session
# which owns those threads and, when applicable, the bridge parent that created
# it.
ensure_scope_metadata() {
  local d host host_session parent
  d="$(scope_dir)"
  host="$(resolve_host)"
  host_session="$(resolve_host_session_id)"
  parent="$(resolve_parent_bridge_session_id)"
  atomic_write_file "$d/host" "$host"
  atomic_write_file "$d/host_session_id" "$host_session"
  [ -z "$parent" ] || atomic_write_file "$d/parent_bridge_session_id" "$parent"
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

turns_dir() {
  local tool="$1" thread="$2"
  printf '%s/turns' "$(thread_dir "$tool" "$thread")"
}

turn_dir() {
  local tool="$1" thread="$2" turn="$3"
  printf '%s/%s' "$(turns_dir "$tool" "$thread")" "$turn"
}

new_turn_id() {
  local tool="$1" thread="$2" base turn n=1
  base="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  turn="$base"
  while [ -d "$(turn_dir "$tool" "$thread" "$turn")" ]; do
    turn="${base}-${n}"
    n=$((n + 1))
  done
  printf '%s' "$turn"
}

write_turn_field() {
  local tool="$1" thread="$2" turn="$3" field="$4" value="$5"
  atomic_write_file "$(turn_dir "$tool" "$thread" "$turn")/$field" "$value"
}

read_turn_field() {
  local tool="$1" thread="$2" turn="$3" field="$4"
  local f
  f="$(turn_dir "$tool" "$thread" "$turn")/$field"
  [ -f "$f" ] && cat "$f"
}

list_turn_ids() {
  local tool="$1" thread="$2" d turn
  d="$(turns_dir "$tool" "$thread")"
  [ -d "$d" ] || return 0
  for turn in "$d"/*/; do
    [ -d "$turn" ] || continue
    turn="${turn%/}"
    printf '%s\n' "${turn##*/}"
  done
}

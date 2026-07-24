#!/usr/bin/env bash
# opencode.sh - opencode-specific helpers for cli-bridge.
# opencode_is_invalid_session_error / opencode_clean_reply / opencode_build_extra_flags
# are pure text-processing and are unit-tested in opencode.test.sh.
# opencode_ask_raw / opencode_session_ids shell out to the real
# `opencode` CLI and are covered by a manual smoke test only (see plan.md
# Task 3, Step 5).

OPENCODE_INVALID_SESSION_MARKER="Session not found"
: "${CLI_BRIDGE_MAX_RAW_BYTES:=65536}"

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

# Prints session IDs from OpenCode's machine-readable list output.  Do not
# scrape the human table: its headings and columns are not a stable interface.
opencode_session_ids() {
  opencode session list --format json -n 1000 2>/dev/null \
    | sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p'
}

# Prints the one session ID which is present in AFTER but not BEFORE.  Fails
# if there is no unique answer so a concurrent OpenCode call can never cause
# this bridge thread to attach itself to an unrelated conversation.
opencode_new_session_id() {
  local before="$1" after="$2" id new_ids="" count=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "
$before
" in
      *"
$id
"*) ;;
      *) new_ids="${new_ids}${id}"$'\n'; count=$((count + 1)) ;;
    esac
  done <<EOF
$after
EOF
  [ "$count" -eq 1 ] || return 1
  printf '%s' "${new_ids%$'\n'}"
}

# opencode_ask_raw SESSION_ID_OR_EMPTY PROMPT REPLY_FILE SESSION_ID_OUT_FILE CWD [EXTRA_FLAGS...]
opencode_ask_raw() {
  local session_id="$1" prompt="$2" reply_file="$3" sid_out_file="$4" cwd="$5"
  shift 5
  local extra=("$@")
  local raw status before_ids after_ids new_session_id
  # NOTE: bash <4.4 (including macOS's stock 3.2) throws "unbound variable"
  # under `set -u` when expanding "${extra[@]}" on a zero-element array.
  # Branch on length instead of expanding a possibly-empty array directly.
  if [ -n "$session_id" ]; then
    if [ "${#extra[@]}" -gt 0 ]; then
      raw="$(opencode run --auto --dir "$cwd" -s "$session_id" "${extra[@]}" "$prompt" 2>&1 | tail -c "$CLI_BRIDGE_MAX_RAW_BYTES")"
    else
      raw="$(opencode run --auto --dir "$cwd" -s "$session_id" "$prompt" 2>&1 | tail -c "$CLI_BRIDGE_MAX_RAW_BYTES")"
    fi
    status=$?
  else
    before_ids="$(opencode_session_ids)"
    if [ "${#extra[@]}" -gt 0 ]; then
      raw="$(opencode run --auto --dir "$cwd" "${extra[@]}" "$prompt" 2>&1 | tail -c "$CLI_BRIDGE_MAX_RAW_BYTES")"
    else
      raw="$(opencode run --auto --dir "$cwd" "$prompt" 2>&1 | tail -c "$CLI_BRIDGE_MAX_RAW_BYTES")"
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
    after_ids="$(opencode_session_ids)"
    if ! new_session_id="$(opencode_new_session_id "$before_ids" "$after_ids")"; then
      printf '%s' 'OpenCode completed, but the bridge could not uniquely identify the newly created session. Another OpenCode session may have been created concurrently; retry this request.' > "$reply_file"
      return 1
    fi
    printf '%s' "$new_session_id" > "$sid_out_file"
  fi
  return 0
}

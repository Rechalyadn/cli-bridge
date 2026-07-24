#!/usr/bin/env bash
# codex.sh - codex-specific helpers for cli-bridge.
# codex_extract_session_id / codex_is_*_error / codex_build_extra_flags are
# pure text-processing and are unit-tested in codex.test.sh. codex_ask_raw
# shells out to the real `codex` CLI and is covered by a manual smoke test
# only (see plan.md Task 2, Step 5) — it is not practical or desirable to
# hit the real Codex API in an automated test.

CODEX_UNTRUSTED_DIR_MARKER="Not inside a trusted directory"
CODEX_INVALID_SESSION_MARKER="no rollout found for thread id"
: "${CLI_BRIDGE_MAX_RAW_BYTES:=65536}"
: "${CLI_BRIDGE_ACTIVITY_MAX_LINES:=200}"

codex_extract_session_id() {
  local raw="$1"
  local session_id
  session_id="$(codex_json_string_field "$raw" thread_id 1 | head -n1)"
  if [ -n "$session_id" ]; then
    printf '%s' "$session_id"
  else
    # Keep accepting the pre-JSON banner for compatibility with old logs.
    printf '%s' "$raw" | grep -o 'session id: [0-9a-f-]\{36\}' | head -n1 | sed 's/^session id: //'
  fi
}

# Extracts the Nth JSON string field without decoding or evaluating it. This is
# deliberately small rather than a general JSON parser: Codex JSONL emits one
# compact object per line, and the fields used here are always JSON strings.
codex_json_string_field() {
  local raw="$1" field="$2" occurrence="$3"
  printf '%s\n' "$raw" | awk -v wanted="$field" -v wanted_n="$occurrence" '
    {
      rest = $0
      needle = "\"" wanted "\""
      seen = 0
      while ((at = index(rest, needle)) > 0) {
        seen++
        rest = substr(rest, at + length(needle))
        if (seen != wanted_n) continue
        if (!match(rest, /^[[:space:]]*:[[:space:]]*"/)) next
        rest = substr(rest, RLENGTH + 1)
        value = ""
        escaped = 0
        for (i = 1; i <= length(rest); i++) {
          ch = substr(rest, i, 1)
          if (ch == "\"" && !escaped) {
            print value
            next
          }
          value = value ch
          if (ch == "\\" && !escaped) escaped = 1
          else escaped = 0
        }
        next
      }
    }
  '
}

codex_activity_value() {
  local value="$1"
  # Keep each entry one-line and bounded. JSON escapes remain escaped so no
  # embedded control character can turn one event into arbitrary log lines.
  printf '%.180s' "$value" | sed 's/\\n/ /g; s/\\r/ /g; s/\\t/ /g'
}

# Formats one JSONL event as a terse procedural status line. The allowlist is
# intentional: content-bearing and unknown item types produce no output.
codex_format_activity_line() {
  local line="$1" event_type item_type detail exit_code
  event_type="$(codex_json_string_field "$line" type 1 | head -n1)"
  item_type="$(codex_json_string_field "$line" type 2 | head -n1)"

  case "$item_type" in
    command_execution)
      detail="$(codex_json_string_field "$line" command 1 | head -n1)"
      detail="$(codex_activity_value "$detail")"
      if [ "$event_type" = "item.started" ]; then
        printf '正在运行命令：%s\n' "${detail:-<未提供命令>}"
      elif [ "$event_type" = "item.completed" ]; then
        exit_code="$(printf '%s' "$line" | sed -n 's/.*"exit_code"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p')"
        printf '命令已完成%s：%s\n' "${exit_code:+（退出码 ${exit_code}）}" "${detail:-<未提供命令>}"
      fi
      ;;
    file_change)
      if [ "$event_type" = "item.started" ]; then
        printf '正在修改文件\n'
      elif [ "$event_type" = "item.completed" ]; then
        printf '文件修改已完成\n'
      fi
      ;;
    mcp_tool_call)
      detail="$(codex_json_string_field "$line" tool 1 | head -n1)"
      [ -n "$detail" ] || detail="$(codex_json_string_field "$line" name 1 | head -n1)"
      detail="$(codex_activity_value "$detail")"
      if [ "$event_type" = "item.started" ]; then
        printf '正在调用工具：%s\n' "${detail:-<未提供名称>}"
      elif [ "$event_type" = "item.completed" ]; then
        printf '工具调用已完成：%s\n' "${detail:-<未提供名称>}"
      fi
      ;;
  esac
}

# Passes the raw stream through to stdout (where codex_ask_raw captures it in
# memory for existing error checks) while persisting only filtered activity.
# Model messages, reasoning, command output, and unknown events never hit disk.
codex_capture_stream() {
  local live_file="$1" sid_capture_file="$2" line activity session_id activity_count=0
  : > "$live_file"
  : > "$sid_capture_file"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    session_id="$(codex_extract_session_id "$line")"
    if [ -n "$session_id" ] && [ ! -s "$sid_capture_file" ]; then
      printf '%s' "$session_id" > "$sid_capture_file"
    fi
    activity="$(codex_format_activity_line "$line")"
    if [ -n "$activity" ] && [ "$activity_count" -lt "$CLI_BRIDGE_ACTIVITY_MAX_LINES" ]; then
      printf '%s\n' "$activity" >> "$live_file"
      activity_count=$((activity_count + 1))
    fi
  done
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

# codex_ask_raw SESSION_ID_OR_EMPTY PROMPT REPLY_FILE SESSION_ID_OUT_FILE CWD LIVE_FILE [EXTRA_FLAGS...]
# On success: writes the clean reply to REPLY_FILE, writes the (possibly
# new) session id to SESSION_ID_OUT_FILE, returns 0.
# On failure: writes raw combined stdout+stderr to REPLY_FILE, returns 1.
# --skip-git-repo-check is always passed (see Global Constraints).
# NOTE: `codex exec resume --help` has no -C/--cd option -- like sandbox
# mode, the working directory is fixed at session creation and cannot be
# changed on resume. -C is therefore only passed on the new-session branch.
codex_ask_raw() {
  local session_id="$1" prompt="$2" reply_file="$3" sid_out_file="$4" cwd="$5" live_file="$6"
  shift 6
  local extra=("$@")
  local raw status sid_capture_file
  sid_capture_file="$(mktemp)"
  # NOTE: bash <4.4 (including macOS's stock 3.2) throws "unbound variable"
  # under `set -u` when expanding "${extra[@]}" on a zero-element array.
  # Branch on length instead of expanding a possibly-empty array directly.
  if [ -n "$session_id" ]; then
    if [ "${#extra[@]}" -gt 0 ]; then
      raw="$(codex exec resume "$session_id" --json --skip-git-repo-check -o "$reply_file" "${extra[@]}" "$prompt" 2>&1 | codex_capture_stream "$live_file" "$sid_capture_file" | tail -c "$CLI_BRIDGE_MAX_RAW_BYTES")"
    else
      raw="$(codex exec resume "$session_id" --json --skip-git-repo-check -o "$reply_file" "$prompt" 2>&1 | codex_capture_stream "$live_file" "$sid_capture_file" | tail -c "$CLI_BRIDGE_MAX_RAW_BYTES")"
    fi
    status=$?
  else
    if [ "${#extra[@]}" -gt 0 ]; then
      raw="$(codex exec --json --skip-git-repo-check -C "$cwd" -o "$reply_file" "${extra[@]}" "$prompt" 2>&1 | codex_capture_stream "$live_file" "$sid_capture_file" | tail -c "$CLI_BRIDGE_MAX_RAW_BYTES")"
    else
      raw="$(codex exec --json --skip-git-repo-check -C "$cwd" -o "$reply_file" "$prompt" 2>&1 | codex_capture_stream "$live_file" "$sid_capture_file" | tail -c "$CLI_BRIDGE_MAX_RAW_BYTES")"
    fi
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    rm -f "$sid_capture_file"
    printf '%s' "$raw" > "$reply_file"
    return 1
  fi
  if [ -s "$sid_capture_file" ]; then
    cat "$sid_capture_file" > "$sid_out_file"
  else
    codex_extract_session_id "$raw" > "$sid_out_file"
  fi
  rm -f "$sid_capture_file"
  return 0
}

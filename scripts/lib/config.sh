#!/usr/bin/env bash
# config.sh - global (not per-scope, not per-thread) preference storage for
# cli-bridge's `setup` command family. Unlike state.sh's thread fields, this
# is meant to persist across every Claude Code conversation and every scope:
# a user's opinion of "gpt-5.6-sol is smart but expensive" doesn't belong to
# one conversation, it's a standing preference. Pure file I/O, no network or
# external CLI calls -- fully unit-testable, unlike `setup probe` itself.

: "${CLI_BRIDGE_HOME:=$HOME/.claude/cli-bridge}"

model_notes_file() {
  printf '%s/model_notes.txt' "$CLI_BRIDGE_HOME"
}

guidance_file() {
  printf '%s/routing_guidance.txt' "$CLI_BRIDGE_HOME"
}

# Model notes are stored one-per-line as `tool|model|tier|note`. The `|`
# delimiter means none of the four fields may themselves contain `|` --
# callers must reject that before calling upsert_model_note/remove_model_note
# (see bridge.sh's do_setup_note), this layer assumes it's already clean.
upsert_model_note() {
  local tool="$1" model="$2" tier="$3" note="$4" file tmp
  file="$(model_notes_file)"
  mkdir -p "$CLI_BRIDGE_HOME" || return 1
  tmp="$CLI_BRIDGE_HOME/.model_notes.$$.tmp"
  if [ -f "$file" ]; then
    awk -F'|' -v t="$tool" -v m="$model" '!($1 == t && $2 == m)' "$file" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s|%s|%s|%s\n' "$tool" "$model" "$tier" "$note" >> "$tmp"
  mv -f "$tmp" "$file"
}

remove_model_note() {
  local tool="$1" model="$2" file tmp
  file="$(model_notes_file)"
  [ -f "$file" ] || return 0
  tmp="$CLI_BRIDGE_HOME/.model_notes.$$.tmp"
  awk -F'|' -v t="$tool" -v m="$model" '!($1 == t && $2 == m)' "$file" > "$tmp"
  mv -f "$tmp" "$file"
}

read_model_notes() {
  local file
  file="$(model_notes_file)"
  [ -f "$file" ] && cat "$file"
  return 0
}

write_guidance() {
  local text="$1" file
  file="$(guidance_file)"
  mkdir -p "$CLI_BRIDGE_HOME" || return 1
  printf '%s\n' "$text" > "$file"
}

read_guidance() {
  local file
  file="$(guidance_file)"
  [ -f "$file" ] && cat "$file"
  return 0
}

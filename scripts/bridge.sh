#!/usr/bin/env bash
# bridge.sh - cli-bridge entry point. See ../design.md for the full design.
set -uo pipefail

# Git for Windows can invoke bash with a Windows-only PATH when launched from
# PowerShell.  Restore its POSIX tools before sourcing helpers that use sed,
# awk, mktemp, and other standard utilities.
case "${OSTYPE:-}" in
  msys*|cygwin*) PATH="/usr/bin:/bin:$PATH" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=./lib/codex.sh
source "$SCRIPT_DIR/lib/codex.sh"
# shellcheck source=./lib/opencode.sh
source "$SCRIPT_DIR/lib/opencode.sh"
# shellcheck source=./lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

DEFAULT_TIMEOUT=720
: "${CLI_BRIDGE_MAX_REPLY_BYTES:=24576}"
: "${CLI_BRIDGE_MAX_ERROR_BYTES:=16384}"

print_bounded_file() {
  local file="$1" limit="$2" size half payload_budget=128
  size="$(wc -c < "$file" | tr -d '[:space:]')"
  if [ "$size" -le "$limit" ]; then
    cat "$file"
    return 0
  fi
  [ "$limit" -gt "$payload_budget" ] || payload_budget=2
  half=$(((limit - payload_budget) / 2))
  head -c "$half" "$file"
  printf '\n\n[cli-bridge: output truncated; original was %s bytes]\n\n' "$size"
  tail -c "$half" "$file"
}

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
Usage: bridge.sh <version|codex|opencode> <ask|peek|history|details|new|switch|list|model|effort|cwd> [options] [prompt]

  ask    [--thread NAME] [--model M] [--effort LEVEL] [--danger-full-access] [--cwd DIR] "<prompt>"
  peek   <thread>               (仅 codex；显示最近 10 条活动)
  history <thread>              (列出已完成调用的摘要)
  details <thread> <turn> [--reply]  (显示某次调用的活动；--reply 附带最终答复)
  new    --thread NAME [--model M] [--effort LEVEL] [--cwd DIR]
  switch <thread>
  list
  model  <thread> <model>
  effort <thread> <level>      (codex only)
  cwd    <thread> <dir>

Global: --scope NAME, --host NAME, --host-session ID, --parent-session ID,
        --timeout SECONDS

Also see: bridge.sh setup <preflight|probe|note|notes|note-rm|guidance>  (environment
probing + global model-preference notes; run with no args for its own usage)
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_dir() {
  [ -d "$1" ] || die "目录不存在：$1"
}

require_positive_integer() {
  case "$2" in
    ''|*[!0-9]*|0) die "$1 must be a positive integer" ;;
  esac
}

validate_identifier() {
  local label="$1" value="$2"
  case "$value" in
    ''|.|..|*/*|*\\*|*[!A-Za-z0-9._-]*)
      die "$label must contain only letters, digits, '.', '_', or '-'"
      ;;
  esac
}

setup_usage() {
  cat <<'EOF'
Usage: bridge.sh setup <preflight|probe|note|notes|note-rm|guidance> [args...]

  preflight                              扫描 V1/V2 安装副本，并检查 codex/opencode 可用性
  probe                                  探测本机 codex/opencode 安装、登录、可用模型情况
  note    <tool> <model> <tier> <note>   记录/更新一条模型偏好（tool: codex|opencode）
  notes                                  列出所有模型偏好记录
  note-rm <tool> <model>                 删除一条模型偏好记录
  guidance ["<text>"]                    查看，或整体覆盖写入"职责分配"说明文字

这些记录仅供参考，供 Claude 阅读后自行决定用什么模型/工具，bridge.sh 不会
用它们校验或拦截 ask/new 的 --model 参数。
EOF
}

print_install_status() {
  local host="$1" path="$2" version
  if [ ! -d "$path" ]; then
    printf '%-12s status=absent path=%s\n' "$host" "$path"
    return 0
  fi
  if [ -f "$path/VERSION" ]; then
    version="$(tr -d '[:space:]' < "$path/VERSION")"
    printf '%-12s status=v2 version=%s path=%s\n' "$host" "${version:-unknown}" "$path"
  elif [ -f "$path/SKILL.md" ] || [ -f "$path/scripts/bridge.sh" ]; then
    printf '%-12s status=legacy-v1 path=%s\n' "$host" "$path"
  else
    printf '%-12s status=unrecognized path=%s\n' "$host" "$path"
  fi
}

print_cli_status() {
  local tool="$1" version status
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '%-12s status=missing\n' "$tool"
    return 0
  fi
  if version="$("$tool" --version 2>&1)"; then
    status="found"
  else
    status="error"
  fi
  version="$(printf '%.512s' "$version" | tr '\n' ' ')"
  printf '%-12s status=%s version=%s\n' "$tool" "$status" "${version:-unknown}"
}

cli_is_usable() {
  command -v "$1" >/dev/null 2>&1 && "$1" --version >/dev/null 2>&1
}

# Installation preflight: only reads local paths and CLI status.  It never
# installs, removes, or calls a model, so an agent can safely use it before
# presenting a V1-to-V2 migration plan to the user.
do_setup_preflight() {
  echo "=== cli-bridge ==="
  printf 'version=%s\n' "$(tr -d '[:space:]' < "$SKILL_DIR/VERSION" 2>/dev/null || printf unknown)"
  printf 'runtime=%s\n' "$CLI_BRIDGE_HOME"
  printf 'current_skill=%s\n' "$SKILL_DIR"
  echo "=== installed skills ==="
  print_install_status "claude-code" "$HOME/.claude/skills/cli-bridge"
  print_install_status "codex" "$HOME/.codex/skills/cli-bridge"
  print_install_status "opencode" "$HOME/.config/opencode/skills/cli-bridge"
  echo "=== cli availability ==="
  print_cli_status codex
  print_cli_status opencode
  if cli_is_usable codex; then
    echo "=== codex login ==="
    codex login status 2>&1 | head -c 1024
    echo
  fi
  if cli_is_usable opencode; then
    echo "=== opencode providers ==="
    opencode providers list 2>&1 | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | head -c 1024
    echo
  fi
}

# Pure fact-gathering: prints raw CLI output under section headers, makes no
# judgment about whether a version is "fresh enough" or a login is valid —
# that interpretation is left to whichever agent is running setup, since
# bridge.sh has no reliable way to know the current latest version without
# a network call this project deliberately avoids.
do_setup_probe() {
  echo "=== codex ==="
  if command -v codex >/dev/null 2>&1; then
    codex --version
    codex login status 2>&1
    codex doctor --json --summary 2>&1
  else
    echo "codex 未找到（不在 PATH 中）"
  fi
  echo
  echo "=== opencode ==="
  if command -v opencode >/dev/null 2>&1; then
    opencode --version
    # opencode's TUI-style output uses ANSI color/box-drawing codes; strip
    # them so the raw text is readable by a plain-text reader (same
    # approach opencode_clean_reply already uses for `run` output).
    opencode providers list 2>&1 | sed 's/\x1b\[[0-9;]*[A-Za-z]//g'
    opencode models 2>&1
  else
    echo "opencode 未找到（不在 PATH 中）"
  fi
}

do_setup_note() {
  local tool="$1" model="$2" tier="$3" note="$4"
  [ -n "$tool" ] && [ -n "$model" ] && [ -n "$tier" ] && [ -n "$note" ] \
    || die "usage: bridge.sh setup note <tool> <model> <tier> <note>"
  [ "$tool" = "codex" ] || [ "$tool" = "opencode" ] || die "tool 必须是 codex 或 opencode"
  case "$model$tier$note" in
    *'|'*) die "model/tier/note 不能包含 '|' 字符（用作内部分隔符）" ;;
  esac
  upsert_model_note "$tool" "$model" "$tier" "$note"
  echo "已记录：$tool / $model → $tier：$note"
}

do_setup_notes() {
  local notes
  notes="$(read_model_notes)"
  if [ -z "$notes" ]; then
    echo "暂无模型偏好记录"
    return 0
  fi
  printf '%s\n' "$notes" | awk -F'|' '{printf "%-10s %-30s %-12s %s\n", $1, $2, $3, $4}'
}

do_setup_note_rm() {
  local tool="$1" model="$2"
  [ -n "$tool" ] && [ -n "$model" ] || die "usage: bridge.sh setup note-rm <tool> <model>"
  remove_model_note "$tool" "$model"
  echo "已移除：$tool / $model"
}

do_setup_guidance() {
  local text="$1"
  if [ -z "$text" ]; then
    local current
    current="$(read_guidance)"
    if [ -z "$current" ]; then
      echo "尚未设置职责分配说明"
    else
      printf '%s\n' "$current"
    fi
    return 0
  fi
  write_guidance "$text"
  echo "职责分配说明已更新"
}

require_positive_integer CLI_BRIDGE_MAX_RAW_BYTES "$CLI_BRIDGE_MAX_RAW_BYTES"
require_positive_integer CLI_BRIDGE_MAX_REPLY_BYTES "$CLI_BRIDGE_MAX_REPLY_BYTES"
require_positive_integer CLI_BRIDGE_MAX_ERROR_BYTES "$CLI_BRIDGE_MAX_ERROR_BYTES"
require_positive_integer CLI_BRIDGE_ACTIVITY_MAX_LINES "$CLI_BRIDGE_ACTIVITY_MAX_LINES"
require_positive_integer CLI_BRIDGE_LOCK_WAIT_SECONDS "$CLI_BRIDGE_LOCK_WAIT_SECONDS"
[ "$CLI_BRIDGE_MAX_RAW_BYTES" -ge 256 ] || die "CLI_BRIDGE_MAX_RAW_BYTES must be at least 256"
[ "$CLI_BRIDGE_MAX_REPLY_BYTES" -ge 256 ] || die "CLI_BRIDGE_MAX_REPLY_BYTES must be at least 256"
[ "$CLI_BRIDGE_MAX_ERROR_BYTES" -ge 256 ] || die "CLI_BRIDGE_MAX_ERROR_BYTES must be at least 256"

[ $# -ge 1 ] || { usage; exit 1; }

if [ "$1" = "version" ]; then
  printf 'cli-bridge %s\n' "$(tr -d '[:space:]' < "$SKILL_DIR/VERSION" 2>/dev/null || printf unknown)"
  exit 0
fi

# First pass: pull session-identity flags out from anywhere in the arg list,
# so host/scope resolution is stable before any state.sh function runs.
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
  elif [ "$a" = "--host" ]; then
    i=$((i + 1))
    [ "$i" -lt "${#args[@]}" ] || die "missing value for --host"
    export CLI_BRIDGE_HOST="${args[$i]}"
  elif [ "$a" = "--host-session" ]; then
    i=$((i + 1))
    [ "$i" -lt "${#args[@]}" ] || die "missing value for --host-session"
    export CLI_BRIDGE_HOST_SESSION_ID="${args[$i]}"
  elif [ "$a" = "--parent-session" ]; then
    i=$((i + 1))
    [ "$i" -lt "${#args[@]}" ] || die "missing value for --parent-session"
    export CLI_BRIDGE_PARENT_SESSION_ID="${args[$i]}"
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

# Setup is global configuration/inspection, not a host conversation.  Keep it
# ahead of scope initialization so `setup preflight` is genuinely read-only.
if [ "$1" = "setup" ]; then
  shift
  case "${1:-}" in
    preflight) do_setup_preflight ;;
    probe) do_setup_probe ;;
    note) shift; do_setup_note "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    notes) do_setup_notes ;;
    note-rm) shift; do_setup_note_rm "${1:-}" "${2:-}" ;;
    guidance) shift; do_setup_guidance "${1:-}" ;;
    *) setup_usage; exit 1 ;;
  esac
  exit 0
fi

validate_identifier "scope" "$(resolve_scope)"
validate_identifier "host" "$(resolve_host)"
validate_identifier "host session" "$(resolve_host_session_id)"
[ -z "$(resolve_parent_bridge_session_id)" ] || validate_identifier "parent session" "$(resolve_parent_bridge_session_id)"
ensure_scope_metadata

TOOL="$1"; shift
[ "$TOOL" = "codex" ] || [ "$TOOL" = "opencode" ] || die "unknown tool '$TOOL' (expected codex or opencode)"

[ $# -ge 1 ] || { usage; exit 1; }
ACTION="$1"; shift

THREAD=""
MODEL=""
EFFORT=""
DANGER=0
CWD=""
TIMEOUT="$DEFAULT_TIMEOUT"
POSITIONAL=()
DETAIL_REPLY=0

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
    --cwd) [ $# -ge 2 ] || die "missing value for --cwd"; CWD="$2"; shift 2 ;;
    --timeout) [ $# -ge 2 ] || die "missing value for --timeout"; TIMEOUT="$2"; shift 2 ;;
    --reply) DETAIL_REPLY=1; shift ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

require_positive_integer --timeout "$TIMEOUT"

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
    local sid model effort last marker cwd
    sid="$(read_field "$TOOL" "$name" session_id)"
    model="$(read_field "$TOOL" "$name" model)"
    effort="$(read_field "$TOOL" "$name" effort)"
    last="$(read_field "$TOOL" "$name" last_used)"
    cwd="$(read_field "$TOOL" "$name" cwd)"
    marker=" "
    [ "$name" = "$dflt" ] && marker="*"
    printf '%s %-12s session=%-10s model=%-20s effort=%-8s cwd=%-30s last_used=%s\n' \
      "$marker" "$name" "${sid:0:10}" "${model:-<default>}" "${effort:-<default>}" "${cwd:-<none>}" "${last:-never}"
  done
}

do_switch() {
  local thread="${POSITIONAL[0]:-}"
  [ -n "$thread" ] || die "usage: bridge.sh $TOOL switch <thread>"
  validate_identifier "thread" "$thread"
  set_default_thread "$TOOL" "$thread"
  echo "已切换默认线程为 $thread"
}

do_model() {
  local thread="${POSITIONAL[0]:-}" model="${POSITIONAL[1]:-}"
  [ -n "$thread" ] && [ -n "$model" ] || die "usage: bridge.sh $TOOL model <thread> <model>"
  validate_identifier "thread" "$thread"
  acquire_thread_lock "$TOOL" "$thread" || die "thread '$thread' is busy"
  write_field "$TOOL" "$thread" model "$model"
  release_thread_lock
  echo "线程 $thread 的模型已设为 $model"
}

do_effort() {
  [ "$TOOL" = "codex" ] || die "effort 仅 codex 支持"
  local thread="${POSITIONAL[0]:-}" level="${POSITIONAL[1]:-}"
  [ -n "$thread" ] && [ -n "$level" ] || die "usage: bridge.sh codex effort <thread> <level>"
  validate_identifier "thread" "$thread"
  acquire_thread_lock "$TOOL" "$thread" || die "thread '$thread' is busy"
  write_field "$TOOL" "$thread" effort "$level"
  release_thread_lock
  echo "线程 $thread 的 reasoning effort 已设为 $level"
}

do_peek() {
  [ "$TOOL" = "codex" ] || die "peek 子命令仅 codex 支持"
  local thread="${POSITIONAL[0]:-${THREAD:-}}"
  [ -n "$thread" ] || die "usage: bridge.sh codex peek <thread>"
  validate_identifier "thread" "$thread"
  local live_file
  live_file="$(thread_dir "$TOOL" "$thread")/activity.log"
  if [ ! -f "$live_file" ]; then
    echo "线程 $thread 暂无活动记录"
    return 0
  fi
  tail -n 10 "$live_file"
}

activity_count() {
  local file="$1" prefix="$2" count
  [ -f "$file" ] || { printf '0'; return 0; }
  count="$(grep -c "^$prefix" "$file" 2>/dev/null || true)"
  printf '%s' "${count:-0}"
}

write_turn_summary() {
  local thread="$1" turn="$2" status="$3" started="$4" ended="$5" native_session="$6" live_file="$7"
  local commands tools duration
  duration=$((ended - started))
  commands="$(activity_count "$live_file" "正在运行命令")"
  tools="$(activity_count "$live_file" "正在调用工具")"
  write_turn_field "$TOOL" "$thread" "$turn" status "$status"
  write_turn_field "$TOOL" "$thread" "$turn" started_at "$started"
  write_turn_field "$TOOL" "$thread" "$turn" ended_at "$ended"
  write_turn_field "$TOOL" "$thread" "$turn" duration_seconds "$duration"
  write_turn_field "$TOOL" "$thread" "$turn" native_session_id "$native_session"
  write_turn_field "$TOOL" "$thread" "$turn" command_count "$commands"
  write_turn_field "$TOOL" "$thread" "$turn" tool_call_count "$tools"
  printf '[cli-bridge] tool=%s thread=%s turn=%s status=%s duration=%ss commands=%s tools=%s details="bridge.sh %s details %s %s"\n' \
    "$TOOL" "$thread" "$turn" "$status" "$duration" "$commands" "$tools" "$TOOL" "$thread" "$turn"
}

do_history() {
  local thread="${POSITIONAL[0]:-${THREAD:-}}" turn
  [ -n "$thread" ] || die "usage: bridge.sh $TOOL history <thread>"
  validate_identifier "thread" "$thread"
  for turn in $(list_turn_ids "$TOOL" "$thread"); do
    printf '%-28s status=%-8s duration=%4ss commands=%s tools=%s\n' "$turn" \
      "$(read_turn_field "$TOOL" "$thread" "$turn" status)" \
      "$(read_turn_field "$TOOL" "$thread" "$turn" duration_seconds)" \
      "$(read_turn_field "$TOOL" "$thread" "$turn" command_count)" \
      "$(read_turn_field "$TOOL" "$thread" "$turn" tool_call_count)"
  done
}

do_details() {
  local thread="${POSITIONAL[0]:-${THREAD:-}}" turn="${POSITIONAL[1]:-}" d
  [ -n "$thread" ] && [ -n "$turn" ] || die "usage: bridge.sh $TOOL details <thread> <turn> [--reply]"
  validate_identifier "thread" "$thread"
  validate_identifier "turn" "$turn"
  d="$(turn_dir "$TOOL" "$thread" "$turn")"
  [ -d "$d" ] || die "turn '$turn' not found for thread '$thread'"
  printf '[cli-bridge] tool=%s thread=%s turn=%s status=%s duration=%ss commands=%s tools=%s\n' \
    "$TOOL" "$thread" "$turn" "$(read_turn_field "$TOOL" "$thread" "$turn" status)" \
    "$(read_turn_field "$TOOL" "$thread" "$turn" duration_seconds)" \
    "$(read_turn_field "$TOOL" "$thread" "$turn" command_count)" \
    "$(read_turn_field "$TOOL" "$thread" "$turn" tool_call_count)"
  if [ -f "$d/activity.log" ]; then
    echo "--- activity ---"
    cat "$d/activity.log"
  fi
  if [ "$DETAIL_REPLY" -eq 1 ] && [ -f "$d/reply.txt" ]; then
    echo "--- reply ---"
    print_bounded_file "$d/reply.txt" "$CLI_BRIDGE_MAX_REPLY_BYTES"
  fi
  if [ -f "$d/error.txt" ]; then
    echo "--- error ---"
    print_bounded_file "$d/error.txt" "$CLI_BRIDGE_MAX_ERROR_BYTES"
  fi
}

do_new() {
  [ -n "$THREAD" ] || die "usage: bridge.sh $TOOL new --thread NAME [--model M] [--effort E] [--cwd DIR]"
  validate_identifier "thread" "$THREAD"
  [ -z "$CWD" ] || require_dir "$CWD"
  acquire_thread_lock "$TOOL" "$THREAD" || die "thread '$THREAD' is busy"
  local existing_model existing_effort
  existing_model="$(read_field "$TOOL" "$THREAD" model)"
  existing_effort="$(read_field "$TOOL" "$THREAD" effort)"
  write_field "$TOOL" "$THREAD" session_id ""
  write_field "$TOOL" "$THREAD" model "${MODEL:-$existing_model}"
  [ "$TOOL" = "codex" ] && write_field "$TOOL" "$THREAD" effort "${EFFORT:-$existing_effort}"
  local existing_cwd cwd
  existing_cwd="$(read_field "$TOOL" "$THREAD" cwd)"
  if [ -n "$CWD" ]; then
    require_dir "$CWD"
    cwd="$CWD"
  else
    cwd="${existing_cwd:-$(pwd)}"
  fi
  write_field "$TOOL" "$THREAD" cwd "$cwd"
  echo "线程 $THREAD 已重置，下次 ask 会建立新会话（工作目录：$cwd）"
  release_thread_lock
}

do_ask() {
  local prompt="${POSITIONAL[0]:-}"
  [ -n "$prompt" ] || die "usage: bridge.sh $TOOL ask [--thread NAME] \"<prompt>\""
  local thread="${THREAD:-$(get_default_thread "$TOOL")}"
  validate_identifier "thread" "$thread"
  acquire_thread_lock "$TOOL" "$thread" || die "thread '$thread' is busy"
  # Nested Codex/OpenCode CLI processes inherit this logical session ID.  If
  # they later invoke their host adapter, it becomes the child's parent link.
  export CLI_BRIDGE_BRIDGE_SESSION_ID="$(resolve_scope)"
  local turn started_at
  turn="$(new_turn_id "$TOOL" "$thread")"
  started_at="$(date +%s)"
  write_turn_field "$TOOL" "$thread" "$turn" host "$(resolve_host)"
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
    # cwd is locked the first time a thread is used (whether via `new` or a
    # bare `ask` that auto-creates it) and then fixed for the thread's
    # lifetime, mirroring how sandbox mode is fixed at session creation and
    # cannot change on resume (see the danger-flag handling below). Gate on
    # whether the cwd field is already populated, not on session_id: `new`
    # writes cwd immediately, before any session_id exists, so gating on
    # session_id let a later --cwd silently overwrite/be-discarded-against
    # an already-locked value with no warning.
    local cwd live_file existing_cwd
    existing_cwd="$(read_field "$TOOL" "$thread" cwd)"
    if [ -n "$existing_cwd" ] && [ -n "$CWD" ]; then
      release_thread_lock
      die "线程 '$thread' 的工作目录已锁定为 $existing_cwd；如需修改，请用 'bridge.sh codex cwd $thread <dir>'（仅在会话尚未开始时有效）或新建线程"
    fi
    cwd="$existing_cwd"
    if [ -z "$cwd" ]; then
      if [ -n "$CWD" ]; then
        require_dir "$CWD"
        cwd="$CWD"
      else
        cwd="$(pwd)"
      fi
      write_field "$TOOL" "$thread" cwd "$cwd"
    fi
    live_file="$(thread_dir "$TOOL" "$thread")/activity.log"
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
      run_with_timeout "$TIMEOUT" codex_ask_raw "$session_id" "$prompt" "$reply_file" "$sid_out_file" "$cwd" "$live_file" "${extra[@]}"
    else
      run_with_timeout "$TIMEOUT" codex_ask_raw "$session_id" "$prompt" "$reply_file" "$sid_out_file" "$cwd" "$live_file"
    fi
    status=$?
  else
    local cwd existing_cwd
    existing_cwd="$(read_field "$TOOL" "$thread" cwd)"
    if [ -n "$existing_cwd" ] && [ -n "$CWD" ]; then
      release_thread_lock
      die "线程 '$thread' 的工作目录已锁定为 $existing_cwd；如需修改，请用 'bridge.sh opencode cwd $thread <dir>'"
    fi
    cwd="$existing_cwd"
    if [ -z "$cwd" ]; then
      if [ -n "$CWD" ]; then
        require_dir "$CWD"
        cwd="$CWD"
      else
        cwd="$(pwd)"
      fi
      write_field "$TOOL" "$thread" cwd "$cwd"
    fi
    while IFS= read -r line; do
      [ -n "$line" ] && extra+=("$line")
    done < <(opencode_build_extra_flags "$model")
    if [ "${#extra[@]}" -gt 0 ]; then
      run_with_timeout "$TIMEOUT" opencode_ask_raw "$session_id" "$prompt" "$reply_file" "$sid_out_file" "$cwd" "${extra[@]}"
    else
      run_with_timeout "$TIMEOUT" opencode_ask_raw "$session_id" "$prompt" "$reply_file" "$sid_out_file" "$cwd"
    fi
    status=$?
  fi

  if [ "$status" -eq 124 ]; then
    write_turn_field "$TOOL" "$thread" "$turn" error "timeout after ${TIMEOUT} seconds"
    write_turn_summary "$thread" "$turn" timeout "$started_at" "$(date +%s)" "$session_id" "$(thread_dir "$TOOL" "$thread")/activity.log" >&2
    rm -f "$reply_file" "$sid_out_file"
    release_thread_lock
    die "超时未完成（超过 ${TIMEOUT} 秒）"
  fi

  if [ "$status" -ne 0 ]; then
    local raw
    raw="$(tail -c "$CLI_BRIDGE_MAX_ERROR_BYTES" "$reply_file")"
    printf '%s' "$raw" > "$(turn_dir "$TOOL" "$thread" "$turn")/error.txt"
    write_turn_summary "$thread" "$turn" error "$started_at" "$(date +%s)" "$session_id" "$(thread_dir "$TOOL" "$thread")/activity.log" >&2
    if [ "$TOOL" = "codex" ] && codex_is_untrusted_dir_error "$raw"; then
      rm -f "$reply_file" "$sid_out_file"
      release_thread_lock
      die "未预期的 trusted-directory 报错，请检查 bridge.sh 是否传了 --skip-git-repo-check"
    fi
    if [ "$TOOL" = "codex" ] && codex_is_invalid_session_error "$raw"; then
      rm -f "$reply_file" "$sid_out_file"
      release_thread_lock
      die "线程 $thread 的会话已失效，请用 'bridge.sh codex new --thread $thread' 重建"
    fi
    if [ "$TOOL" = "opencode" ] && opencode_is_invalid_session_error "$raw"; then
      rm -f "$reply_file" "$sid_out_file"
      release_thread_lock
      die "线程 $thread 的会话已失效，请用 'bridge.sh opencode new --thread $thread' 重建"
    fi
    print_bounded_file "$reply_file" "$CLI_BRIDGE_MAX_ERROR_BYTES" >&2
    rm -f "$reply_file" "$sid_out_file"
    release_thread_lock
    exit 1
  fi

  local new_sid
  new_sid="$(cat "$sid_out_file")"
  local native_session="${new_sid:-$session_id}"
  cp "$(thread_dir "$TOOL" "$thread")/activity.log" "$(turn_dir "$TOOL" "$thread" "$turn")/activity.log" 2>/dev/null || true
  cp "$reply_file" "$(turn_dir "$TOOL" "$thread" "$turn")/reply.txt"
  write_turn_summary "$thread" "$turn" ok "$started_at" "$(date +%s)" "$native_session" "$(thread_dir "$TOOL" "$thread")/activity.log"
  print_bounded_file "$reply_file" "$CLI_BRIDGE_MAX_REPLY_BYTES"
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
  release_thread_lock
}

# OpenCode has a per-invocation --dir option, so its threads can persist a
# working directory just like Codex threads.
do_cwd() {
  local thread="${POSITIONAL[0]:-}" dir="${POSITIONAL[1]:-}"
  [ -n "$thread" ] && [ -n "$dir" ] || die "usage: bridge.sh $TOOL cwd <thread> <dir>"
  validate_identifier "thread" "$thread"
  require_dir "$dir"
  acquire_thread_lock "$TOOL" "$thread" || die "thread '$thread' is busy"
  if [ "$TOOL" = "codex" ] && [ -n "$(read_field "$TOOL" "$thread" session_id)" ]; then
    release_thread_lock
    die "线程 '$thread' 的 Codex 会话已开始，无法再修改工作目录；请新建线程并指定 --cwd"
  fi
  write_field "$TOOL" "$thread" cwd "$dir"
  release_thread_lock
  echo "线程 $thread 的工作目录已设为 $dir"
}

case "$ACTION" in
  ask) do_ask ;;
  peek) do_peek ;;
  history) do_history ;;
  details) do_details ;;
  new) do_new ;;
  switch) do_switch ;;
  list) do_list ;;
  model) do_model ;;
  effort) do_effort ;;
  cwd) do_cwd ;;
  *) usage; exit 1 ;;
esac

---
name: cli-bridge
description: Maintain multi-turn, resumable conversations with the Codex and OpenCode CLIs, scoped to the current host-agent conversation. Use when the user asks to "tell codex...", "ask opencode...", wants Codex/OpenCode to remember earlier turns, wants to manage named codex/opencode threads (switch/list/model/effort/cwd), wants to install or set up cli-bridge on a new machine, or record model/provider preferences.
---

# cli-bridge

Wraps `codex exec` / `codex exec resume` and `opencode run` so conversations
with Codex / OpenCode can span multiple turns, instead of one-shot delegation.
The same core can be installed for Claude Code, Codex, or OpenCode. See
`design.md` next to this file for the full design rationale, `plan*.md` for
how each part was built, and `SETUP.md` for first-time installation.

## When to use this instead of Ask-Codex / Ask-OpenCode

- The user wants Codex/OpenCode to remember something from an earlier call
  in the same host-agent conversation.
- The user wants multiple independent named conversations with Codex/OpenCode
  running in parallel (e.g. one exploring, one reviewing).
- The user explicitly invokes `/cli-bridge ...`.

For a genuine one-off question with no need for follow-up, `Ask-Codex` /
`Ask-OpenCode` are simpler — prefer those when continuity isn't needed.

## Usage

```
bash scripts/bridge.sh <codex|opencode> ask    [--thread NAME] [--model M] [--effort LEVEL] [--danger-full-access] [--cwd DIR] "<prompt>"
bash scripts/bridge.sh <codex|opencode> new    --thread NAME [--model M] [--effort LEVEL] [--cwd DIR]
bash scripts/bridge.sh <codex|opencode> switch <thread>
bash scripts/bridge.sh <codex|opencode> list
bash scripts/bridge.sh <codex|opencode> history <thread>
bash scripts/bridge.sh <codex|opencode> details <thread> <turn> [--reply]
bash scripts/bridge.sh version
bash scripts/bridge.sh setup preflight
bash scripts/bridge.sh <codex|opencode> model  <thread> <model>
bash scripts/bridge.sh <codex|opencode> cwd    <thread> <dir>
bash scripts/bridge.sh codex effort <thread> <level>
bash scripts/bridge.sh codex peek   <thread>              # 最近 10 条实时活动，仅 codex
```

`--thread` defaults to whatever `switch` last set (starts as `default`,
auto-created on first `ask`). `--scope NAME` overrides automatic binding.
Host adapters set `CLI_BRIDGE_HOST` and, when the host exposes it, a native
host-session ID. `--host-session ID` is available when an integration needs to
provide that ID explicitly. `--effort` and `--danger-full-access` are codex-only.
`--cwd` works with both tools; it is stored per thread and passed to OpenCode
as `--dir` on every call.

To protect the calling agent's context and the wrapper's memory, process
output is bounded by `CLI_BRIDGE_MAX_RAW_BYTES` (default 64 KiB), successful
replies by `CLI_BRIDGE_MAX_REPLY_BYTES` (default 24 KiB), and errors by
`CLI_BRIDGE_MAX_ERROR_BYTES` (default 16 KiB). Truncated replies include an
explicit marker.

This is a plain bash script with no Claude Code dependency — it also runs
standalone in any terminal (Windows Git Bash, macOS bash/zsh) for manual
debugging, outside of any Claude Code conversation.

## Output contract

`ask` prints one compact `[cli-bridge]` summary followed by the final answer.
The summary contains tool, thread, turn ID, status, elapsed seconds, and
available command/tool-call counts. It never includes raw tool output or model
reasoning. Each completed call is archived under the thread's `turns/` folder:
use `history` to list summaries, then `details <thread> <turn>` to retrieve
the filtered activity, adding `--reply` only when the final answer itself is
needed again.

Before a V2 installation or migration, run `setup preflight`. It is read-only:
it reports this package version, classifies global Claude Code/Codex/OpenCode
skill copies as `legacy-v1`, `v2`, or `absent`, and checks local CLI versions.
Do not delete a legacy copy until the replacement V2 copy has been installed
and verified.

## Calling from a host agent

Use the host adapter, rather than calling `bridge.sh` directly:

```bash
bash scripts/adapters/claude-code.sh codex ask "..."
bash scripts/adapters/codex.sh opencode ask "..."
bash scripts/adapters/opencode.sh codex ask "..."
```

The adapter records the host identity. When cli-bridge launches a nested
Codex/OpenCode CLI, its child inherits the parent logical bridge session; this
links the child scope without requiring the agent to locate a native session ID.

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
- `线程 'X' 的工作目录已锁定为 ...` — cwd is fixed the first time a thread
  is used (via `new --cwd` or a bare first `ask`) and stays fixed for that
  thread's lifetime. Use `bridge.sh <tool> cwd <thread> <dir>` (only works
  before the thread's first successful turn) or create a new thread.

## First-time setup / model preferences

`bridge.sh setup <probe|note|notes|note-rm|guidance>` is a separate command
family (not a `<tool>`) for installing cli-bridge on a fresh machine and
recording standing model/provider preferences. **See `SETUP.md`** for the
step-by-step walkthrough — only open it when you're actually installing or
recording preferences, not for routine `ask` calls.

Quick reference for routine use: before picking a `--model` or choosing
codex vs. opencode for a task, run `bridge.sh setup notes` and
`bridge.sh setup guidance` and factor in what's there. It's advisory only —
`ask`/`new` never read, validate, or enforce these notes.

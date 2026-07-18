# Plan: live activity visibility for codex `ask` calls

## Why

`codex_ask_raw` currently captures Codex's entire stdout+stderr via a bash
command substitution (`raw="$(codex exec ... 2>&1)"`). Command substitution
fully buffers — nothing is observable, by anyone, until the process exits.
During a long-running call (which can take many minutes, or hit the
timeout), there is no way for a human or for Claude-as-caller to see what
Codex is actually doing. The only externally visible signal is OS-level
process liveness (what a process monitor shows) — not activity. On a
timeout, the reply file is often empty, because nothing was ever written
incrementally.

We want real-time visibility into Codex's *activity* (tool calls, commands
run, files touched) while it's working — WITHOUT dumping its full
chain-of-thought or reply content into any log that could end up back in a
caller's context window. Some callers of `bridge.sh codex ask` are humans
watching a terminal; others are Claude Code itself, dispatching Codex as a
sub-agent — and Claude's own context is precious, so anything that isn't
the final clean reply must never be auto-printed back to the caller.

## Requirements

R1. Real-time visibility into what Codex is doing while a call is
    in-flight — don't wait until it finishes to know anything.

R2. The visibility feed must be TERSE: short one-line "activity" entries
    (e.g. "running command: X", "editing file: Y"). It must NEVER include
    the model's reasoning/chain-of-thought or its actual reply text/message
    content — only structural/procedural events (what tool/command ran),
    never content.

R3. This activity feed is a strictly separate channel from the `ask`
    action's return value. `bridge.sh codex ask`'s stdout must remain
    EXACTLY what it is today: just the clean final reply. Nothing from the
    activity feed may be concatenated into it automatically, regardless of
    whether the caller is a human terminal or Claude Code itself.

R4. Add an opt-in command, `bridge.sh codex peek <thread>`, that a human
    (or Claude) can run any time to check in on a thread's current or most
    recently finished call. Output must be bounded (last N entries, not
    unbounded growth) and must go through the same terse
    activity-only filter as R2 — never raw/full content.

R5. Each new `ask` call for a given thread starts a fresh activity feed
    (the previous call's feed is overwritten, not appended-to-forever), so
    `peek` always reflects the most recent call.

R6. Must not regress existing behavior:
    - session continuity across resumes
    - the cwd feature just added (`-C` only on new-session, never on
      resume — confirmed via `codex exec resume --help` that resume has no
      `-C`/`--cd` option at all)
    - model/effort overrides
    - `--danger-full-access` forced off on resume (sandbox is fixed at
      session creation, confirmed `-s` is rejected on resume)
    - the timeout + process-group-kill behavior in `run_with_timeout`
      (verified previously that killing the whole process group is
      required to actually terminate the real `codex` process, not just a
      wrapper subshell)
    - the existing untrusted-dir / invalid-session error detection
      (`codex_is_untrusted_dir_error`, `codex_is_invalid_session_error`)

R7. Stay within existing project conventions (see any existing file for
    examples): pure bash targeting 3.2+, no mapfile/associative
    arrays/nameref, guard any possibly-empty array expansion with an
    explicit `[ "${#arr[@]}" -gt 0 ]` branch (not the `"${arr[@]+...}"`
    idiom), check `$#` before consuming a flag's value, user-facing
    messages in Chinese, no jq/python dependency (plain grep/sed/awk only).

R8. Update/extend the automated pure-logic test suite
    (`scripts/lib/codex.test.sh`) to cover the new parsing logic with
    fixture strings (not live CLI calls) — in particular:
    - session-id extraction against the new output format
    - the activity-line formatter: MUST include a test asserting that a
      fixture line containing the model's actual message/reasoning content
      produces NO output (empty) from the formatter — this is the concrete
      check that R2/R3 are actually satisfied, not just intended.

R9. Out of scope for this task: `opencode.sh`, the cwd feature (already
    done, don't touch it), and the "escalate" feature (separate, future
    task).

## What we already know (verified empirically, don't re-derive)

- `codex exec --json` (also supported on `codex exec resume --json`,
  confirmed via `--help` on both) switches output to JSONL: one event
  object per line, e.g.:
  ```
  {"type":"thread.started","thread_id":"<uuid>"}
  {"type":"turn.started"}
  {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
  {"type":"item.started","item":{"type":"command_execution","command":"...","status":"in_progress"}}
  {"type":"item.completed","item":{"type":"command_execution","command":"...","aggregated_output":"...","exit_code":0,"status":"completed"}}
  {"type":"turn.completed","usage":{...}}
  ```
  This was observed from ONE real probe — there may be other `item.type`
  values (file edits, web search, MCP tool calls, etc.) not seen in that
  single sample.
- Once `--json` is added, the old human-readable banner (which included
  the literal text `session id: <uuid>` that `codex_extract_session_id`
  currently greps for) is NOT printed at all — session id must now come
  from the `thread.started` event's `thread_id` field instead. The
  existing test fixture for this in codex.test.sh is now stale and needs
  replacing with a `--json`-shaped fixture.
- `-o/--output-last-message <FILE>` is an independent flag from `--json`
  (both were listed separately in `codex exec --help`) — they can be
  combined, so the "write only the clean final reply to reply_file"
  mechanism should keep working unchanged even with `--json` added.

## Open questions intentionally left to you (the implementer)

You (Codex) know your own CLI's actual behavior and full event schema far
better than this plan's author does from one manual probe. Use your
judgment on:

- The complete set of `item.type` values worth surfacing as "activity" in
  the terse feed, and how to phrase each as a short Chinese one-liner.
  `agent_message` must never produce a line (that's content, not
  activity) — but if the CLI can emit other content-bearing event types
  (e.g. an explicit reasoning/thinking event type), those must be
  excluded too, using the same reasoning: anything that carries the
  model's actual words is content and must be suppressed; anything that
  describes a tool/command/file action is activity and may be surfaced.
- The cleanest bash-3.2-safe mechanism to simultaneously (a) write the raw
  JSONL stream incrementally to a live file as it's produced, and (b)
  still correctly determine the process's real exit status and still
  have the full raw text available for the existing error-marker checks
  (`codex_is_untrusted_dir_error`, `codex_is_invalid_session_error`). A
  `... | tee "$live_file"` inside the existing `$(...)` capture is one
  option (bridge.sh already runs under `set -o pipefail`, sourced
  scripts share that), but verify the exit status you get is actually
  codex's, not tee's, and that `run_with_timeout`'s process-group kill
  still reaches every process in the pipeline (it was written and
  verified against a single backgrounded command, not a pipeline —
  re-verify this still holds, since a timeout that leaves an orphaned
  `codex` process running is exactly the bug that was fixed before).
- Exact file naming/location for the live feed (suggest something under
  the existing thread directory returned by `thread_dir`, e.g. a
  `live.jsonl` field/file next to the existing `session_id`/`model`/
  `effort`/`cwd` files — but this is your call).

## Suggested shape (not mandatory, adjust as you see fit)

- `codex_ask_raw` gains a live-log file path (or derives one from the
  thread dir it's already given indirectly) and adds `--json` to every
  `codex exec` / `codex exec resume` invocation.
- A new pure function, e.g. `codex_format_activity_line`, takes one raw
  JSONL line as input and prints either nothing (skip) or one short
  Chinese status line. This is the function R8's key test targets.
- `bridge.sh` gains `do_peek()` + a `peek` case in the action dispatch
  table (codex-only, mirroring how `effort`/`cwd` are already codex-only),
  reading the thread's live file, running each line through the
  formatter, and printing the last ~10 non-empty results.
- `codex_extract_session_id` (or a replacement) is updated to parse
  `thread_id` from the `thread.started` JSONL line instead of the old
  banner text.

## Testing

1. Update `scripts/lib/codex.test.sh` fixtures for the new session-id
   extraction format.
2. Add fixture-based tests for `codex_format_activity_line`: at minimum
   one `command_execution` start event → non-empty activity line, one
   `command_execution` completed event → non-empty activity line, one
   `agent_message` event → asserted EMPTY output.
3. Run `bash scripts/lib/state.test.sh && bash scripts/lib/codex.test.sh`
   and confirm all pass, including the pre-existing tests (no regressions).
4. Manual smoke test against the real CLI (this one you should actually
   run, since it's the only way to validate the live file truly updates
   incrementally and `peek` shows something sensible): create a thread,
   fire an `ask` that triggers at least one tool call, and confirm (a)
   `peek` after/during the call shows only terse activity lines, never
   reply content, and (b) the `ask` command's own stdout is still just
   the clean final reply, unchanged.

## Deliverable

Modify `scripts/lib/codex.sh` and `scripts/bridge.sh` only. Do not modify
`scripts/lib/opencode.sh`, `scripts/lib/state.sh`, or the cwd feature
already in place. Do not commit — report back what you changed, why, and
the test results (including the manual smoke test transcript/observations)
so the controller (a different Claude Code session) can review the diff
before committing.

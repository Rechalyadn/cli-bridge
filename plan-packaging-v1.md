# Plan: cli-bridge v1 packaging — setup/config for fresh installs

## Why

cli-bridge so far has only ever been configured by hand, on one machine, by
the person who wrote it. To hand this skill to someone else (or reinstall it
cleanly on a new machine), an installing agent needs a repeatable way to:

1. Find out whether `codex`/`opencode` are installed, working, and logged in
   on the target machine.
2. Learn what models are actually available, ask the user which
   providers/models they want used for what, and remember that.
3. Record how responsibilities should split across codex/opencode (and,
   later, the not-yet-built escalate feature) so future Claude Code sessions
   dispatching work through cli-bridge have that context.

Confirmed decisions (asked the user directly, not guessed):

- **Setup mechanism**: a real `bridge.sh setup ...` subcommand family, not
  prose-only SKILL.md instructions. Keeps setup testable/reproducible like
  everything else in this project.
- **Model preference table**: pure reference documentation. `ask`/`new`
  never validate or block a `--model` value against it — it's there for
  Claude to *read* before choosing a model, nothing more. No enforcement
  logic, no "task type" auto-routing. (Can revisit later if it proves
  insufficient.)
- **Distribution scope**: this must tolerate genuinely foreign environments
  — CLI not installed, not logged in, network/proxy trouble, old versions —
  not just "reinstall on my own machine again."

## What's actually available (verified by running these commands, not assumed)

- `codex --version` → e.g. `codex-cli 0.144.5`.
- `codex login status` → plain text, e.g. `Logged in using ChatGPT` (or an
  error/prompt-to-login text otherwise — not yet observed, since this
  machine is logged in).
- `codex doctor --json --summary` → single JSON object, notably:
  `overallStatus`, `codexVersion`, and (inside `checks.*.details`) the
  currently configured default model + provider, auth mode, and network
  reachability. No `models` list — Codex doesn't expose an enumerable model
  list via CLI (model comes from account/plan + `~/.codex/config.toml`
  overrides, not a discrete queryable catalog).
- `opencode --version` → e.g. `1.18.3`.
- `opencode models [provider]` → plain text, one `provider/model` per line,
  ~60+ entries observed (deepseek, gpt-5.x, claude-*, glm, gemini, etc.).
- `opencode providers list` (alias `ls`) → ANSI-styled box-drawing output
  showing which providers have stored credentials. Needs ANSI-stripping
  (same technique `opencode_clean_reply` already uses) to be readable in a
  plain log, but doesn't need full parsing — a human/LLM reader can just
  read it once stripped.
- None of `codex`/`opencode` support any kind of "list models" call that
  itself needs JSON parsing on the bash side to consume — the consumer of
  `setup probe`'s output is always an LLM agent, not another script, so
  raw JSON/text passthrough is fine. This is a deliberate scope-narrowing
  from the rest of the project's "no jq" rule: that rule is about bridge.sh
  never needing to *parse* JSON itself, not about refusing to ever print it.

## Requirements

R1. New `bridge.sh setup <subaction>` command family, special-cased before
    the existing `TOOL="$1"` parsing (mirroring how `--scope` is
    pre-extracted today) — `setup` is not `codex`/`opencode`, it applies to
    both at once.

R2. `bridge.sh setup probe` — pure fact-gathering, zero judgment calls:
    - runs `codex --version`, `codex login status`,
      `codex doctor --json --summary` (or just `--json`, decide during
      implementation which is more useful) if `codex` is on PATH; otherwise
      prints a clear "codex 未找到" line and moves on — never dies/exits
      non-zero just because one tool is missing, since an installer must be
      able to probe an environment that only has one of the two tools.
    - same for `opencode --version`, `opencode providers list` (ANSI
      stripped), `opencode models`.
    - Output is plain concatenated text under clear section headers (e.g.
      `=== codex ===`, `=== opencode ===`) — the installing agent reads and
      interprets it (is the version stale? is login expired? what models
      exist?). bridge.sh does not encode "fresh enough" thresholds anywhere
      — it has no reliable way to know the current latest version without a
      network call this project doesn't want to make, and that judgment
      belongs to the smarter party (the same principle applied in the
      live-status feature: let the agent that actually knows interpret raw
      facts, don't hardcode brittle judgment into bash).

R3. Global (not per-scope, not per-thread) model preference storage:
    - New file `~/.claude/cli-bridge/model_notes.txt`, flat, pipe-delimited:
      `tool|model|tier|note`. One line per (tool, model) pair; setting a
      note for an existing pair overwrites its line (upsert by key), it
      does not append a duplicate.
    - `bridge.sh setup note <tool> <model> <tier> <note text>` — validates
      `tool` ∈ {codex, opencode}, `tier` is free-form short text (e.g.
      `expert`/`bulk`/`cheap`/`disallowed` — no fixed enum, since the user's
      own vocabulary for this should be their choice, not the script's).
    - `bridge.sh setup notes` — prints the whole table.
    - `bridge.sh setup note-rm <tool> <model>` — removes one line (typo
      correction / no-longer-relevant entries).
    - This file is documentation only — nothing in `ask`/`new` reads or
      enforces it (per the confirmed decision above).

R4. Global routing/responsibility guidance:
    - New file `~/.claude/cli-bridge/routing_guidance.txt`, free-text,
      whole-file overwrite semantics (not append-only) — whoever calls
      `setup guidance` is expected to pass the complete, current text each
      time, since the installing agent will have read the old version
      first if it's revising it.
    - `bridge.sh setup guidance "<full text>"` — writes the file.
    - `bridge.sh setup guidance` (no argument) — prints current content, or
      "尚未设置" if absent.
    - This is where "codex 适合脏活累活，gpt-5.6-sol 适合当专家复核" style
      free-text notes about tool/model responsibility split live. Also
      documentation only, never enforced.

R5. `bridge.sh setup` with no subaction, or an unrecognized one, prints a
    short usage block (mirroring the top-level `usage()` function) rather
    than falling through to the generic "unknown tool" error.

R6. Stay within existing project conventions: pure bash 3.2+, no
    mapfile/associative arrays/nameref, guard empty-array expansions, check
    `$#` before consuming flag values, Chinese user-facing messages
    (`setup probe`'s raw CLI passthrough is naturally bilingual/English
    where the underlying CLI output already is — that's fine, only
    bridge.sh's own messages need to be Chinese), no jq/python dependency
    for anything bridge.sh itself needs to parse (this doesn't apply to
    `setup probe`'s passthrough output, see R2).

R7. Automated tests:
    - `setup note` / `setup notes` / `setup note-rm` / `setup guidance` are
      pure file I/O (like everything in state.sh) — cover them with real
      fixture-based tests (upsert behavior, removal, missing-file defaults)
      in a new `scripts/lib/setup.test.sh` or folded into `state.test.sh` if
      the storage logic ends up living in state.sh.
    - `setup probe` shells out to real CLIs — manual smoke test only (same
      pattern as `codex_ask_raw`/`opencode_ask_raw`), not automated.

R8. Documentation:
    - `SKILL.md` gains a "首次安装 / Setup" section instructing an
      installing agent, step by step: run `setup probe` → interpret
      results (missing tool → tell user how to get it themselves, don't
      guess install commands/URLs; not logged in → tell user to run
      `codex login` / `opencode providers login` themselves, these need a
      browser/interactive flow and can't be scripted; old version → use the
      agent's own judgment, optionally suggest `codex update` /
      `opencode upgrade`) → discuss available models with the user → record
      preferences via `setup note` (repeatable, one call per model worth
      noting) → optionally record routing guidance via `setup guidance`.
    - `SKILL.md` also gains a short section telling Claude to run
      `setup notes` / `setup guidance` and read them before picking a
      `--model` or deciding codex-vs-opencode for a task — advisory only.
    - `design.md` is currently stale (predates cwd, peek/live-status,
      locking, bounded output, `validate_identifier`, and now this setup
      feature) — needs a refresh pass alongside this work, not deferred.

R9. Out of scope for this task (explicitly deferred by the user): the
    "escalate" / sandbox-upgrade-via-context-carryover feature. Setup and
    docs should not reference it as if it already exists.

## Suggested shape (not mandatory)

- A new block near the top of `bridge.sh`, right after the `--scope`
  pre-extraction pass and before `TOOL="$1"`, that special-cases
  `if [ "${1:-}" = "setup" ]; then ...; fi` and dispatches to
  `do_setup_probe` / `do_setup_note` / `do_setup_notes` / `do_setup_note_rm`
  / `do_setup_guidance`, then exits — bypassing the normal
  `TOOL`/`ACTION`/flag-parsing pipeline entirely, since none of it applies.
- `model_notes.txt` upsert: read existing file (if any), filter out any
  line matching `^tool|model|` via `grep -v` (careful with `|` as both the
  field separator and a regex metacharacter — needs literal escaping or
  `grep -F`-style matching on a constructed prefix), append the new line,
  write back atomically (reuse `atomic_write_file` from state.sh).
- ANSI-stripping for `opencode providers list`: grep for how
  `opencode_clean_reply` already strips ANSI in `opencode.sh` and reuse the
  same `sed`/regex approach rather than inventing a new one.

## Testing

1. Add `scripts/lib/setup.test.sh` (or extend `state.test.sh`) with fixture
   tests for note upsert/removal/listing and guidance read/write, following
   the existing `assert_eq` style.
2. Run the full existing suite
   (`state.test.sh` + `codex.test.sh` + `opencode.test.sh` + the new one) to
   confirm no regressions.
3. Manual smoke test of `setup probe` against the real CLIs on this
   machine, confirming it degrades gracefully — temporarily renaming/hiding
   one CLI off PATH (or simulating via a broken PATH) to confirm the
   "missing tool" branch doesn't crash the whole probe.

## Deliverable

Modify `scripts/bridge.sh`, add `scripts/lib/setup.test.sh` (or extend
`state.test.sh`), update `SKILL.md` and `design.md`. Commit when done and
verified — this is foundational enough that it should land as its own
reviewed commit, not folded silently into an unrelated change.

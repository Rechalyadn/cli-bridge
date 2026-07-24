#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"

output="$(./install.sh --agent codex --agent opencode --dry-run)"
case "$output" in
  *'skills add Rechalyadn/cli-bridge --copy --global --skill cli-bridge --yes --agent codex --agent opencode'*)
    echo "PASS: installer targets selected agents" ;;
  *) echo "FAIL: unexpected installer command: $output" >&2; exit 1 ;;
esac

interactive="$(./install.sh --dry-run)"
case "$interactive" in
  *'skills add Rechalyadn/cli-bridge --copy --global'*)
    echo "PASS: installer defaults to interactive target selection" ;;
  *) echo "FAIL: unexpected interactive installer command: $interactive" >&2; exit 1 ;;
esac

help="$(./install.sh --help)"
case "$help" in
  *'preflight'*) echo "PASS: installer documents preflight" ;;
  *) echo "FAIL: installer help omits preflight" >&2; exit 1 ;;
esac

#!/usr/bin/env bash
# Install cli-bridge into one or more agent-native skill directories through
# skills-lc-cli.  The installer owns distribution only; all hosts share the
# same cli-bridge runtime under ~/.cli-bridge.
set -eu

SOURCE="Rechalyadn/cli-bridge"
GLOBAL=1
DRY_RUN=0
AGENTS=()

usage() {
  cat <<'EOF'
Usage: scripts/install.sh <preflight|install> [options]

Options:
  preflight        inspect legacy installs and local CLI availability
  install          open the Skills CLI target-selection flow; this is the default action
  --source SOURCE  Skills CLI source (default: Rechalyadn/cli-bridge)
  --project        install into the current project instead of the user profile
  --dry-run        print the skills-lc-cli command without running it
  -h, --help       show this help

Examples:
  scripts/install.sh preflight
  scripts/install.sh                 # interactively choose installation targets
  scripts/install.sh --agent codex
  scripts/install.sh --agent opencode --project
  scripts/install.sh --agent codex --agent opencode
EOF
}

add_agent() {
  case "$1" in
    claude-code|codex|opencode) AGENTS+=("$1") ;;
    all) AGENTS+=(claude-code codex opencode) ;;
    *) echo "Error: unsupported agent '$1'" >&2; exit 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    preflight) exec "$(dirname "$0")/bridge.sh" setup preflight ;;
    install) shift ;;
    --agent) [ "$#" -ge 2 ] || { echo "Error: missing value for --agent" >&2; exit 1; }; add_agent "$2"; shift 2 ;;
    --source) [ "$#" -ge 2 ] || { echo "Error: missing value for --source" >&2; exit 1; }; SOURCE="$2"; shift 2 ;;
    --project) GLOBAL=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

cmd=(npx skills-lc-cli add "$SOURCE")
[ "$GLOBAL" -eq 1 ] && cmd+=(--global)
if [ "${#AGENTS[@]}" -gt 0 ]; then
  cmd+=(--skill cli-bridge --yes)
  for agent in "${AGENTS[@]}"; do cmd+=(--agent "$agent"); done
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Would run:'; printf ' %q' "${cmd[@]}"; printf '\n'
  exit 0
fi
command -v npx >/dev/null 2>&1 || { echo "Error: npx is required to run skills-lc-cli" >&2; exit 1; }
exec "${cmd[@]}"

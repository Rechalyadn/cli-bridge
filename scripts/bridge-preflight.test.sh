#!/usr/bin/env bash
# Verify version/preflight without real CLIs, network, or user files.
set -eu
cd "$(dirname "$0")"

TMPHOME="$(mktemp -d)"
FAKEBIN="$TMPHOME/bin"
mkdir -p "$FAKEBIN" "$TMPHOME/.claude/skills/cli-bridge" "$TMPHOME/.codex/skills/cli-bridge" "$TMPHOME/.config/opencode/skills/cli-bridge"
printf '%s\n' 'legacy' > "$TMPHOME/.claude/skills/cli-bridge/SKILL.md"
printf '%s\n' '2.0.0' > "$TMPHOME/.codex/skills/cli-bridge/VERSION"
cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex 9.9.9' ;;
  login) echo 'logged in' ;;
esac
EOF
cat > "$FAKEBIN/opencode" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'opencode 8.8.8' ;;
  providers) echo 'provider: available' ;;
esac
EOF
chmod +x "$FAKEBIN/codex" "$FAKEBIN/opencode"

version="$(HOME="$TMPHOME" bash ./bridge.sh version)"
[ "$version" = 'cli-bridge 2.0.0' ] || { echo "FAIL: unexpected version: $version" >&2; exit 1; }
output="$(HOME="$TMPHOME" PATH="$FAKEBIN:$PATH" CLI_BRIDGE_HOME="$TMPHOME/.cli-bridge" bash ./bridge.sh setup preflight)"
case "$output" in
  *'claude-code  status=legacy-v1'*'codex        status=v2 version=2.0.0'*'opencode     status=unrecognized'*'codex        status=found version=codex 9.9.9'*'opencode     status=found version=opencode 8.8.8'*)
    echo "PASS: preflight classifies installs and probes CLI availability" ;;
  *) echo "FAIL: unexpected preflight output: $output" >&2; exit 1 ;;
esac

if [ -e "$TMPHOME/.cli-bridge" ]; then
  echo "FAIL: preflight created runtime state" >&2
  exit 1
fi
echo "PASS: preflight does not create runtime state"

rm -rf "$TMPHOME"
echo "--- ALL TESTS PASSED ---"

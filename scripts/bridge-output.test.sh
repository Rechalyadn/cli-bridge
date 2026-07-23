#!/usr/bin/env bash
# Exercise the successful Codex output path without a real Codex account.
set -eu
cd "$(dirname "$0")"

TMPHOME="$(mktemp -d)"
FAKEBIN="$TMPHOME/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
set -eu
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' '最终答复' > "$out"
printf '%s\n' '{"type":"thread.started","thread_id":"thread-123"}'
printf '%s\n' '{"type":"item.started","item":{"type":"command_execution","command":"rg --files"}}'
printf '%s\n' '{"type":"item.started","item":{"type":"mcp_tool_call","tool":"github"}}'
EOF
chmod +x "$FAKEBIN/codex"

output="$(PATH="$FAKEBIN:$PATH" CLI_BRIDGE_HOME="$TMPHOME/state" BRIDGE_SCOPE="test" bash ./bridge.sh codex ask --thread demo 'test prompt')"
case "$output" in
  *'[cli-bridge] tool=codex thread=demo'*'status=ok'*'commands=1 tools=1'*$'\n最终答复'*)
    echo "PASS: ask prints concise summary then final reply" ;;
  *) echo "FAIL: unexpected ask output: $output" >&2; exit 1 ;;
esac

turn="$(PATH="$FAKEBIN:$PATH" CLI_BRIDGE_HOME="$TMPHOME/state" BRIDGE_SCOPE="test" bash ./bridge.sh codex history demo | awk '{print $1}')"
detail="$(PATH="$FAKEBIN:$PATH" CLI_BRIDGE_HOME="$TMPHOME/state" BRIDGE_SCOPE="test" bash ./bridge.sh codex details demo "$turn" --reply)"
case "$detail" in
  *'--- activity ---'*'正在运行命令：rg --files'*'正在调用工具：github'*'--- reply ---'*'最终答复'*)
    echo "PASS: details retrieves archived activity and reply" ;;
  *) echo "FAIL: unexpected details output: $detail" >&2; exit 1 ;;
esac

rm -rf "$TMPHOME"
echo "--- ALL TESTS PASSED ---"

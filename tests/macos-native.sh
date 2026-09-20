#!/bin/bash
# Native integration checks. Run on a logged-in macOS runner with Node 24+.
# The only HTTP server is a local fixture; this never installs the dsh package.
set -eu

[ "$(uname -s)" = Darwin ] || { printf 'This test requires native macOS.\n' >&2; exit 1; }
[ "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" = 3.2 ] || { printf 'Run this test with /bin/bash (Bash 3.2).\n' >&2; exit 1; }
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
NATIVE_NODE="$(command -v node)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dsh-native.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
SERVER_PIDS=''
SELF_TEST_DIR="$TEST_ROOT/self test"
MENU_TEST_DIR="$TEST_ROOT/menu test"
RUNTIME_TEST_DIR="$TEST_ROOT/runtime test"

cleanup() {
  local result=$? candidate command_text log attempt
  set +e
  if [ "$result" != 0 ]; then
    while IFS= read -r -d '' log; do
      printf '\n--- %s ---\n' "$log" >&2
      cat "$log" >&2
    done < <(find "$TEST_ROOT" -type f \( -name '*.log' -o -name '*.error' \) -print0)
  fi
  if declare -f stop_tray >/dev/null 2>&1; then
    PORT=3080
    stop_tray "$SELF_TEST_DIR"
    stop_tray "$MENU_TEST_DIR"
  fi
  # A failed start may have left a PID record before the test captured its PID.
  for log in "$RUNTIME_TEST_DIR"/server-*.pid; do
    [ -f "$log" ] || continue
    SERVER_PIDS="$SERVER_PIDS $(cat "$log")"
  done
  for candidate in $SERVER_PIDS; do
    case "$candidate" in ''|*[!0-9]*) continue ;; esac
    command_text="$(ps -p "$candidate" -o command= 2>/dev/null)"
    case "$command_text" in
      *"$TEST_ROOT/"*)
        kill "$candidate" 2>/dev/null || true
        attempt=0
        while kill -0 "$candidate" 2>/dev/null && [ "$attempt" -lt 20 ]; do
          sleep 0.1
          attempt=$((attempt + 1))
        done
        if [ "$(ps -p "$candidate" -o command= 2>/dev/null)" = "$command_text" ]; then
          kill -9 "$candidate" 2>/dev/null || true
        fi
        ;;
    esac
  done
  # Only the absolute mktemp directory owned by this test is ever removed.
  case "$TEST_ROOT" in
    /*/dsh-native.??????) rm -rf -- "$TEST_ROOT" ;;
    *) printf 'Refusing unexpected cleanup path: %s\n' "$TEST_ROOT" >&2 ;;
  esac
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Sourcing is supported by the launcher and does not invoke main.
source "$REPO_DIR/dsh-window.sh"
assert_native() { [ "$1" = "$2" ] || { printf 'FAIL: %s (expected %s, got %s)\n' "$3" "$2" "$1" >&2; exit 1; }; }
PORT=3080
EXTERNAL_URL=''

# Exercise the real --self-test path. The wrapper only disables creating user
# shortcuts; it leaves HOME, native compilation, app launch, and shutdown alone.
cat > "$TEST_ROOT/self-test-wrapper.sh" <<'WRAPPER'
#!/bin/bash
set -eu
launcher="$1"
shift
source "$launcher"
install_shortcuts() { :; }
main
WRAPPER
/bin/bash "$TEST_ROOT/self-test-wrapper.sh" "$REPO_DIR/dsh-window.sh" \
  --self-test --no-sync --app-dir "$SELF_TEST_DIR" --port "$PORT" > "$TEST_ROOT/self-test.log" 2>&1
cat "$TEST_ROOT/self-test.log"
[ -x "$(tray_app_path "$SELF_TEST_DIR")/Contents/MacOS/applet" ]
[ -f "$(tray_work_dir "$SELF_TEST_DIR")/ready" ]
! tray_running "$SELF_TEST_DIR"
[ ! -e "$SELF_TEST_DIR/node_modules" ] && [ ! -e "$SELF_TEST_DIR/node" ] && [ ! -e "$SELF_TEST_DIR/node-runtime.path" ]
printf 'ok - native --self-test compiled, initialized, and stopped its tray without installing Node or dsh\n'

# Compile a second real applet from the generated source. Replace only the
# action executor with a recorder, then ask NSMenu itself to dispatch its items.
mkdir -p "$MENU_TEST_DIR/assets" "$(tray_work_dir "$MENU_TEST_DIR")"
cp "$REPO_DIR/assets/tray-template.png" "$MENU_TEST_DIR/assets/"
cp "$REPO_DIR/assets/tray-template@2x.png" "$MENU_TEST_DIR/assets/"
tray_source "$MENU_TEST_DIR" 23 17 > "$TEST_ROOT/menu-original.applescript"
python3 - "$TEST_ROOT/menu-original.applescript" "$TEST_ROOT/menu-test.applescript" "$TEST_ROOT" <<'PYTHON'
import pathlib
import re
import sys

source_path, output_path, root = map(pathlib.Path, sys.argv[1:])
source = source_path.read_text()

def literal(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

printf_command = literal("/usr/bin/printf '%s\\n' ")
action = f'''on runAction(flag)
    do shell script {printf_command} & quoted form of flag & " >> " & quoted form of {literal(root / 'menu-flags.log')}
end runAction'''
source, count = re.subn(r'^on runAction\(flag\)\n.*?^end runAction$', lambda _: action, source, flags=re.M | re.S)
if count != 1:
    raise SystemExit('Expected exactly one generated runAction handler')
source, count = re.subn(r'^end run$', '\tmy testNativeMenu()\nend run', source, count=1, flags=re.M)
if count != 1:
    raise SystemExit('Generated run handler was not found')
source += f'''
on testNativeMenu()
    try
        set itemCount to theMenu's numberOfItems() as integer
        if itemCount is not 8 then error "Expected eight menu items including the separator"
        set expectedTitles to {{"Open Window", "Open in Browser", "Restart Server", "Copy URL", "Open Log", "Open Install Folder", "", "Exit (stop server)"}}
        repeat with menuIndex from 0 to 7
            set nativeItem to theMenu's itemAtIndex_(menuIndex)
            set expectedTitle to item (menuIndex + 1) of expectedTitles
            if (nativeItem's title() as text) is not expectedTitle then error "Unexpected menu title at index " & menuIndex
        end repeat
        set separatorItem to theMenu's itemAtIndex_(6)
        if not (separatorItem's isSeparatorItem() as boolean) then error "Menu separator is missing"
        repeat with selectedIndex in {{0, 1, 2, 4, 5, 7}}
            theMenu's performActionForItemAtIndex_(selectedIndex as integer)
        end repeat
        do shell script {printf_command} & quoted form of (itemCount as text) & " > " & quoted form of {literal(root / 'menu.success')}
    on error errorText number errorNumber
        do shell script {printf_command} & quoted form of (errorText & " (" & (errorNumber as text) & ")") & " > " & quoted form of {literal(root / 'menu.error')}
    end try
end testNativeMenu
'''
output_path.write_text(source)
PYTHON
osacompile -s -o "$(tray_app_path "$MENU_TEST_DIR")" "$TEST_ROOT/menu-test.applescript" > "$TEST_ROOT/menu-build.log" 2>&1
set_tray_agent "$(tray_app_path "$MENU_TEST_DIR")"
open "$(tray_app_path "$MENU_TEST_DIR")"
attempt=0
while [ ! -f "$TEST_ROOT/menu.success" ] && [ ! -f "$TEST_ROOT/menu.error" ] && [ "$attempt" -lt 100 ]; do
  sleep 0.2
  attempt=$((attempt + 1))
done
[ ! -f "$TEST_ROOT/menu.error" ] || { cat "$TEST_ROOT/menu.error" >&2; exit 1; }
[ -f "$TEST_ROOT/menu.success" ] || { printf 'Native menu dispatch timed out.\n' >&2; exit 1; }
assert_native "$(cat "$TEST_ROOT/menu.success")" 8 'native menu count'
printf '%s\n' --open-window --open-browser --restart --open-log --open-folder --stop > "$TEST_ROOT/menu-expected.log"
cmp "$TEST_ROOT/menu-expected.log" "$TEST_ROOT/menu-flags.log"
tray_running "$MENU_TEST_DIR"
stop_tray "$MENU_TEST_DIR"
! tray_running "$MENU_TEST_DIR"
printf 'ok - native NSMenu dispatched all six launcher callbacks, including Exit\n'

# A real Node process implements the relevant dsh HTTP behavior: token URLs
# redirect, bare/stale URLs return 401, and restarting creates a new token.
mkdir -p "$RUNTIME_TEST_DIR/node_modules/@deepseek-ai/dsh/lib"
FIXTURE_BIN="$RUNTIME_TEST_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
cat > "$FIXTURE_BIN" <<'NODE'
const http = require('node:http');
const crypto = require('node:crypto');
const args = process.argv.slice(2);
if (args[0] !== 'web' || !args.includes('--no-open')) process.exit(2);
const port = Number(args[args.indexOf('--port') + 1]);
const token = crypto.randomBytes(24).toString('base64url');
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  if (url.searchParams.get('token') === token) {
    res.writeHead(302, {Location: '/'}).end();
  } else {
    res.writeHead(401, {'Content-Type': 'text/plain'}).end('Unauthorized');
  }
});
server.on('error', error => { console.error(error); process.exit(1); });
server.listen(port, '127.0.0.1', () => console.log(`Ready: http://127.0.0.1:${port}/?token=${token}`));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
NODE
PORT="$("$NATIVE_NODE" -e 'const s=require("node:net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close();});')"
first_url="$(start_dsh_server "$NATIVE_NODE" "$FIXTURE_BIN" "$PORT" "$RUNTIME_TEST_DIR")"
first_pid="$(cat "$RUNTIME_TEST_DIR/server-$PORT.pid")"
SERVER_PIDS="$first_pid"
assert_native "$(port_owner_pid "$PORT")" "$first_pid" 'real listening process ownership'
assert_native "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")" 401 'bare URL authentication'
assert_native "$(authenticated_server_url "$PORT" "$RUNTIME_TEST_DIR")" "$first_url" 'recorded token recovery'
printf '%s\n' "http://127.0.0.1:$PORT/?token=stale-token-0000000000" > "$RUNTIME_TEST_DIR/server-$PORT.url"
assert_native "$(authenticated_server_url "$PORT" "$RUNTIME_TEST_DIR")" "$first_url" 'valid token recovered from the real server log'

# Keep browser UI out of a server lifecycle test. Node, HTTP, lsof, PID records,
# process ownership checks and termination remain the real launcher code.
close_app_window() { :; }
browser_exe() { printf '/test-browser'; }
open_app_window() { printf '%s\n' "$2" > "$TEST_ROOT/reopened-url.log"; }
action_restart "$RUNTIME_TEST_DIR" "$PORT"
second_pid="$(cat "$RUNTIME_TEST_DIR/server-$PORT.pid")"
SERVER_PIDS="$SERVER_PIDS $second_pid"
second_url="$(cat "$RUNTIME_TEST_DIR/server-$PORT.url")"
[ "$second_pid" != "$first_pid" ] && [ "$second_url" != "$first_url" ]
! kill -0 "$first_pid" 2>/dev/null
assert_native "$(port_owner_pid "$PORT")" "$second_pid" 'restart process ownership'
assert_native "$(authenticated_server_url "$PORT" "$RUNTIME_TEST_DIR")" "$second_url" 'restarted token authentication'
assert_native "$(curl -s -o /dev/null -w '%{http_code}' "$first_url")" 401 'old token after restart'
assert_native "$(cat "$TEST_ROOT/reopened-url.log")" "$second_url" 'reopened browser uses the new token'
action_stop "$RUNTIME_TEST_DIR" "$PORT"
! kill -0 "$second_pid" 2>/dev/null
! port_serving "$PORT"
[ ! -e "$RUNTIME_TEST_DIR/server-$PORT.pid" ] && [ ! -e "$RUNTIME_TEST_DIR/server-$PORT.url" ]
printf 'ok - native Node HTTP process authenticated, recovered its token, restarted, and stopped\n'

# A lookalike entry point is still another program, even if the PID record is
# present. This protects against prefix matches when deciding what to kill.
cp "$FIXTURE_BIN" "$FIXTURE_BIN.other"
foreign_url="$(start_dsh_server "$NATIVE_NODE" "$FIXTURE_BIN.other" "$PORT" "$RUNTIME_TEST_DIR")"
foreign_pid="$(cat "$RUNTIME_TEST_DIR/server-$PORT.pid")"
SERVER_PIDS="$SERVER_PIDS $foreign_pid"
if stop_managed_port_owner "$PORT" "$RUNTIME_TEST_DIR"; then
  printf 'FAIL: a lookalike entry point was treated as the managed server.\n' >&2
  exit 1
fi
kill -0 "$foreign_pid"
url_authenticated "$foreign_url"
printf 'ok - native process ownership checks preserve a lookalike foreign server\n'
printf 'Passed native macOS integration checks on %s.\n' "$(uname -m)"

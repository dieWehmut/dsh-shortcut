#!/usr/bin/env bash
# Offline behavior tests for the macOS launcher: browser process selection,
# server ownership, tray actions, the generated menu bar source, and the
# command-line contract. No GUI, network, or dsh package is used, so this runs
# on any macOS runner with Bash 3.2 (and on Git Bash during development).
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dsh-launcher-tests.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
cleanup() {
  case "$TEST_ROOT" in
    */dsh-launcher-tests.??????) rm -rf -- "$TEST_ROOT" ;;
    *) printf 'Refusing to remove unexpected test path: %s\n' "$TEST_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail_test "$3: expected '$2', got '$1'"; }
passed=0
pass() {
  passed=$((passed + 1))
  printf 'ok %s - %s\n' "$passed" "$1"
}

# Sourcing is supported by the launcher and does not invoke main.
source "$REPO_DIR/dsh-window.sh"
PORT=3080
EXTERNAL_URL=''
BROWSER='chrome'
note() { :; }
fail() { printf 'ERROR: %s\n' "$1" >&2; }

# ---- command-line contract -------------------------------------------------

cli_bin="$TEST_ROOT/cli-bin"
mkdir -p "$cli_bin"
printf '#!/bin/sh\nprintf "Darwin\\n"\n' > "$cli_bin/uname"
chmod +x "$cli_bin/uname"
run_launcher() { PATH="$cli_bin:$PATH" "$BASH" "$REPO_DIR/dsh-window.sh" "$@"; }

run_launcher --help > "$TEST_ROOT/help.log" 2>&1 || fail_test '--help must succeed'
grep -F -- '--app-dir' "$TEST_ROOT/help.log" >/dev/null || fail_test '--help must list the options'
grep -F -- '--self-test' "$TEST_ROOT/help.log" >/dev/null || fail_test '--help must list the menu bar self-test'
if run_launcher --definitely-unknown > "$TEST_ROOT/unknown.log" 2>&1; then
  fail_test 'an unknown option was accepted'
fi
grep -F 'unknown option' "$TEST_ROOT/unknown.log" >/dev/null || fail_test 'an unknown option must be reported'
if run_launcher --port > "$TEST_ROOT/missing.log" 2>&1; then
  fail_test 'a missing option value was accepted'
fi
grep -F 'missing value' "$TEST_ROOT/missing.log" >/dev/null || fail_test 'a missing option value must be reported'
if run_launcher --port 99999 > "$TEST_ROOT/range.log" 2>&1; then
  fail_test 'an out-of-range port was accepted'
fi
grep -F 'port must be 1-65535' "$TEST_ROOT/range.log" >/dev/null || fail_test 'an out-of-range port must be reported'
if run_launcher --port 'abc' > "$TEST_ROOT/nan.log" 2>&1; then
  fail_test 'a non-numeric port was accepted'
fi
grep -F 'port must be an integer' "$TEST_ROOT/nan.log" >/dev/null || fail_test 'a non-numeric port must be reported'
pass 'invalid command lines fail before any launch step runs'

# ---- browser process selection ---------------------------------------------

# The whole --user-data-dir argument identifies this installation: a prefix such
# as browser-profile-30801 belongs to a different installation, and a renderer
# process is not the window owner.
ps_scenario='mixed'
fixture_ps() {
  if [ "$ps_scenario" = renderer_only ]; then
    cat <<'PS'
  222 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=renderer --user-data-dir=/apps/state/browser-profile-3080
PS
    return 0
  fi
  cat <<'PS'
  111 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/apps/state/browser-profile-30801 --no-first-run
  222 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=renderer --user-data-dir=/apps/state/browser-profile-3080
  333 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/apps/state/browser-profile-3080 --no-first-run
  444 /Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge --user-data-dir=/apps/state/browser-profile-3080
PS
}
ps() {
  case "$1" in
    -ax) fixture_ps ;;
    *) return 1 ;;
  esac
}

chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
edge='/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'
profile='/apps/state/browser-profile-3080'
assert_eq "$(browser_pid "$chrome" "$profile")" 333 'the exact executable and profile select the window process'
assert_eq "$(browser_pid "$edge" "$profile")" 444 'another browser owning the same profile is found separately'
assert_eq "$(browser_pid "$chrome" '/apps/state/browser-profile-308')" '' 'a shorter profile must not match a longer one'
assert_eq "$(browser_pid "$chrome" '/apps/state/browser-profile-30801')" 111 'the exact longer profile still matches'
ps_scenario='renderer_only'
assert_eq "$(browser_pid "$chrome" "$profile")" '' 'a renderer with the profile is not the window owner'
ps_scenario='mixed'
pass 'browser windows are selected only by the exact executable and whole profile argument'

# ---- managed server ownership ----------------------------------------------

install_dir="$TEST_ROOT/app dir"
mkdir -p "$install_dir"
entry="$install_dir/node_modules/@deepseek-ai/dsh/lib/bin.js"
kill_log="$TEST_ROOT/kill.log"
kill() {
  printf '%s\n' "$*" >> "$kill_log"
  return 1
}

owner_pid=4242
printf '%s\n' "$owner_pid" > "$install_dir/server-3080.pid"
printf '%s\n' 'http://127.0.0.1:3080/?token=stale-token' > "$install_dir/server-3080.url"
port_owner_pid() { printf '%s' "$owner_pid"; }

# A recycled PID that now runs a lookalike entry point is another program.
pid_command() { printf 'node %s.other web --no-open --port 3080' "$entry"; }
: > "$kill_log"
if stop_managed_port_owner 3080 "$install_dir"; then
  fail_test 'a lookalike entry point was treated as the managed server'
fi
[ ! -s "$kill_log" ] || fail_test 'a lookalike foreign server was signalled'
pass 'a lookalike entry point is never stopped'

# The recorded PID must still match the port owner.
printf '%s\n' 1111 > "$install_dir/server-3080.pid"
: > "$kill_log"
if stop_managed_port_owner 3080 "$install_dir"; then
  fail_test 'a mismatched pid record was accepted'
fi
[ ! -s "$kill_log" ] || fail_test 'an unrelated listener was signalled'
pass 'a pid record that no longer matches is refused'

# The managed server is stopped by its own record and command line.
printf '%s\n' "$owner_pid" > "$install_dir/server-3080.pid"
pid_command() { printf 'node %s web --no-open --port 3080' "$entry"; }
: > "$kill_log"
stop_managed_port_owner 3080 "$install_dir" || fail_test 'the managed server was not stopped'
grep -Fx -- "$owner_pid" "$kill_log" >/dev/null || fail_test 'the managed server was never signalled'
[ ! -e "$install_dir/server-3080.pid" ] && [ ! -e "$install_dir/server-3080.url" ] || fail_test 'server records were left behind'
pass 'the managed server is stopped and its records removed'

# ---- tray actions ------------------------------------------------------------

action_log="$TEST_ROOT/actions.log"
close_app_window() { printf 'close\n' >> "$action_log"; }
stop_tray() { printf 'tray\n' >> "$action_log"; }
printf '%s\n' close tray > "$TEST_ROOT/expected.log"

# Exit must leave the menu bar even when the port belongs to another process.
stop_managed_port_owner() { return 1; }
: > "$action_log"
action_stop "$install_dir" 3080 || fail_test 'Exit refused to leave the menu bar while a foreign server was running'
cmp "$TEST_ROOT/expected.log" "$action_log" || fail_test 'Exit did not close the window and stop the tray'

stop_managed_port_owner() { return 0; }
: > "$action_log"
action_stop "$install_dir" 3080 || fail_test 'Exit failed for a managed server'
cmp "$TEST_ROOT/expected.log" "$action_log" || fail_test 'Exit skipped cleanup for a managed server'
pass 'Exit always leaves the menu bar and stops only the managed server'

# ---- generated menu bar source ---------------------------------------------

tray_dir="$TEST_ROOT/tray dir"
mkdir -p "$tray_dir"
generated="$TEST_ROOT/tray.applescript"
tray_source "$tray_dir" 23 17 > "$generated"

# AppleScript closes an interleaved-parameter handler with its name parts and a
# trailing colon; `end handlerName:parameter` is not the documented form.
if grep -Eq '^end [A-Za-z][A-Za-z0-9]*:[A-Za-z]' "$generated"; then
  fail_test 'a handler is closed with a parameter name'
fi
for handler in statusClicked menuOpenWindow menuOpenBrowser menuRestart menuOpenLog menuOpenFolder menuCopyUrl menuExit; do
  grep -F "on ${handler}:sender" "$generated" >/dev/null || fail_test "handler ${handler}: is missing from the generated source"
  grep -F "end ${handler}:" "$generated" >/dev/null || fail_test "handler ${handler}: is not closed with its own name"
done
grep -F 'on addItem(itemTitle, handlerName)' "$generated" >/dev/null || fail_test 'the positional handler is missing'
grep -F 'end addItem' "$generated" >/dev/null || fail_test 'the positional handler is not closed'
grep -F 'on runAction(flag)' "$generated" >/dev/null || fail_test 'the action runner is missing'
grep -F 'end runAction' "$generated" >/dev/null || fail_test 'the action runner is not closed'
pass 'generated AppleScript closes every handler with the documented form'

printf 'Passed %s macOS launcher behavior tests.\n' "$passed"
#!/usr/bin/env bash
# Installer integration tests with offline fixtures; no macOS UI is launched.
set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dsh-install-tests.XXXXXX")"
cleanup() {
  case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/dsh-install-tests.*) rm -rf "$TEST_ROOT" ;; esac
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/fixtures"
export TEST_FIXTURES="$TEST_ROOT/fixtures"
export TEST_RUN_LOG="$TEST_ROOT/run.log"
export TEST_SHORTCUT_LOG="$TEST_ROOT/shortcuts.log"
export TEST_DOWNLOAD_LOG="$TEST_ROOT/download.log"
export PATH="$TEST_ROOT/bin:$PATH"

cat > "$TEST_FIXTURES/dsh-window.sh" <<'LAUNCHER'
#!/usr/bin/env bash
APP_DIR=launcher-default
PORT=3080
BROWSER=chrome
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf '%s\n' "$@" > "$TEST_RUN_LOG"
else
  [ "$#" = 0 ] || { printf 'source received unexpected args\n' >&2; exit 1; }
  install_shortcuts() {
    printf '%s\n' "$1" "$APP_DIR" "$PORT" "$BROWSER" > "$TEST_SHORTCUT_LOG"
  }
fi
LAUNCHER
cp "$REPO_DIR/assets/tray-template.png" "$TEST_FIXTURES/tray-template.png"
cp "$REPO_DIR/assets/tray-template@2x.png" "$TEST_FIXTURES/tray-template@2x.png"
cp "$TEST_FIXTURES/dsh-window.sh" "$TEST_ROOT/good-launcher.sh"

cat > "$TEST_ROOT/bin/uname" <<'UNAME'
#!/usr/bin/env bash
printf '%s\n' "${TEST_OS:-Darwin}"
UNAME
cat > "$TEST_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -eu
out=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$TEST_DOWNLOAD_LOG"
[ "${TEST_DOWNLOAD_FAIL:-0}" = 0 ] || exit 22
name="${url##*/}"
if [ "$name" = "${TEST_EMPTY_FILE:-}" ]; then
  : > "$out"
else
  cp "$TEST_FIXTURES/$name" "$out"
fi
CURL
cat > "$TEST_ROOT/bin/sips" <<'SIPS'
#!/usr/bin/env bash
if [ "${TEST_IMAGE_FAIL:-0}" = 1 ]; then
  printf '  format: <nil>\n  pixelWidth: 0\n  pixelHeight: 0\n'
else
  printf '  format: png\n  pixelWidth: 18\n  pixelHeight: 18\n'
fi
SIPS
chmod +x "$TEST_ROOT/bin/"*

installer() { "$BASH" "$REPO_DIR/install.sh" "$@"; }
expect_failure() {
  if installer "$@" > "$TEST_ROOT/output.log" 2>&1; then
    fail "installer unexpectedly accepted: $*"
  fi
}
assert_no_staging() {
  local stage
  for stage in "$1"/.install.*; do
    [ ! -d "$stage" ] || fail 'staging directory was left behind'
  done
}

app_dir="$TEST_ROOT/app space'quote\$dollar"
installer --app-dir "$app_dir" --port 08080 --browser '/Applications/Custom Browser' \
  --url 'http://127.0.0.1:8080/?token=a&next=b' --no-window --no-tray --silent-node-install \
  > "$TEST_ROOT/output.log" 2>&1
printf '%s\n' --app-dir "$app_dir" --port 8080 --browser '/Applications/Custom Browser' --no-sync \
  --url 'http://127.0.0.1:8080/?token=a&next=b' --no-window --no-tray --silent-node-install > "$TEST_ROOT/expected.log"
cmp "$TEST_ROOT/expected.log" "$TEST_RUN_LOG" || fail 'launch arguments were not preserved'
[ -x "$app_dir/dsh-window.sh" ] || fail 'launcher is not executable'
[ -f "$app_dir/.dsh-shortcut" ] || fail 'installation marker is missing'
cmp "$TEST_FIXTURES/tray-template.png" "$app_dir/assets/tray-template.png" || fail '1x icon was not installed'
cmp "$TEST_FIXTURES/tray-template@2x.png" "$app_dir/assets/tray-template@2x.png" || fail '2x icon was not installed'
assert_no_staging "$app_dir"
printf 'PASS: install and launch preserve paths, flags, and both icons\n'

rm -f "$TEST_RUN_LOG"
installer --app-dir "$app_dir" --port 4321 --browser edge --no-start > "$TEST_ROOT/output.log" 2>&1
[ ! -e "$TEST_RUN_LOG" ] || fail '--no-start ran the launcher'
printf '%s\n' "$app_dir/dsh-window.sh" "$app_dir" 4321 edge > "$TEST_ROOT/expected.log"
cmp "$TEST_ROOT/expected.log" "$TEST_SHORTCUT_LOG" || fail '--no-start lost shortcut settings'
printf 'PASS: --no-start only creates shortcuts with the selected settings\n'

cp "$app_dir/dsh-window.sh" "$TEST_ROOT/installed-launcher.sh"
cp "$app_dir/assets/tray-template.png" "$TEST_ROOT/installed-icon.png"
printf 'if broken syntax\n' > "$TEST_FIXTURES/dsh-window.sh"
expect_failure --app-dir "$app_dir" --no-start
cmp "$TEST_ROOT/installed-launcher.sh" "$app_dir/dsh-window.sh" || fail 'bad script replaced the launcher'
cmp "$TEST_ROOT/installed-icon.png" "$app_dir/assets/tray-template.png" || fail 'bad script replaced an icon'
assert_no_staging "$app_dir"
cp "$TEST_ROOT/good-launcher.sh" "$TEST_FIXTURES/dsh-window.sh"
printf 'not a PNG\n' > "$TEST_FIXTURES/tray-template@2x.png"
expect_failure --app-dir "$app_dir" --no-start
cmp "$TEST_ROOT/installed-launcher.sh" "$app_dir/dsh-window.sh" || fail 'bad icon replaced the launcher'
cmp "$TEST_ROOT/installed-icon.png" "$app_dir/assets/tray-template.png" || fail 'bad icon replaced another icon'
assert_no_staging "$app_dir"
cp "$REPO_DIR/assets/tray-template@2x.png" "$TEST_FIXTURES/tray-template@2x.png"
export TEST_IMAGE_FAIL=1
expect_failure --app-dir "$app_dir" --no-start
unset TEST_IMAGE_FAIL
cmp "$TEST_ROOT/installed-launcher.sh" "$app_dir/dsh-window.sh" || fail 'unreadable PNG replaced the launcher'
export TEST_EMPTY_FILE=dsh-window.sh
expect_failure --app-dir "$app_dir" --no-start
unset TEST_EMPTY_FILE
export TEST_DOWNLOAD_FAIL=1
expect_failure --app-dir "$app_dir" --no-start
unset TEST_DOWNLOAD_FAIL
cmp "$TEST_ROOT/installed-launcher.sh" "$app_dir/dsh-window.sh" || fail 'download failure replaced the launcher'
assert_no_staging "$app_dir"
printf 'PASS: invalid syntax, invalid PNGs, empty files, and network failures preserve installed files\n'

download_count="$(wc -l < "$TEST_DOWNLOAD_LOG")"
installer --app-dir "$app_dir" --port 4321 --uninstall > "$TEST_ROOT/output.log" 2>&1
printf '%s\n' --app-dir "$app_dir" --port 4321 --uninstall > "$TEST_ROOT/expected.log"
cmp "$TEST_ROOT/expected.log" "$TEST_RUN_LOG" || fail '--uninstall lost the installation directory or port'
[ "$(wc -l < "$TEST_DOWNLOAD_LOG")" = "$download_count" ] || fail '--uninstall downloaded files'
installer --app-dir "$TEST_ROOT/absent" --uninstall > "$TEST_ROOT/output.log" 2>&1
[ ! -d "$TEST_ROOT/absent" ] || fail '--uninstall created a directory'
printf 'PASS: uninstall delegates locally and handles an absent installation\n'

# Exercise the real shortcut generator, then replace only the generated target
# with a recorder so executing the shortcut cannot launch a server or UI.
cp "$REPO_DIR/dsh-window.sh" "$TEST_FIXTURES/dsh-window.sh"
test_home="$TEST_ROOT/test home"
mkdir -p "$test_home"
HOME="$test_home" installer --app-dir "$app_dir" --port 4321 --browser '/Applications/Custom Browser' \
  --no-start --silent-node-install > "$TEST_ROOT/output.log" 2>&1
desktop_shortcut="$test_home/Desktop/DeepSeek Harness.command"
app_shortcut="$test_home/Applications/DeepSeek Harness.command"
[ -x "$desktop_shortcut" ] && [ -x "$app_shortcut" ] || fail 'real shortcuts were not created'
"$BASH" -n "$desktop_shortcut"
cmp "$desktop_shortcut" "$app_shortcut" || fail 'desktop and application shortcuts differ'
cp "$TEST_ROOT/good-launcher.sh" "$app_dir/dsh-window.sh"
"$BASH" "$desktop_shortcut"
printf '%s\n' --app-dir "$app_dir" --port 4321 --browser '/Applications/Custom Browser' --silent-node-install > "$TEST_ROOT/expected.log"
cmp "$TEST_ROOT/expected.log" "$TEST_RUN_LOG" || fail 'real shortcut did not preserve settings and literal paths'
printf 'PASS: real shortcut generator preserves literal paths and silent Node installation\n'

mkdir -p "$test_home/.dsh" "$test_home/child"
for protected_dir in / "$test_home" "$test_home/.dsh" "$test_home/child/.."; do
  if HOME="$test_home" installer --app-dir "$protected_dir" --no-start > "$TEST_ROOT/output.log" 2>&1; then
    fail "installer accepted a protected directory: $protected_dir"
  fi
done
[ ! -e "$test_home/.dsh-shortcut" ] && [ ! -e "$test_home/.dsh/.dsh-shortcut" ] || fail 'a protected directory received an installation marker'
printf 'PASS: protected directories cannot be marked as an installation\n'

for invalid_port in 0 65536 -1 1.5 10000000000000000000; do
  expect_failure --app-dir "$TEST_ROOT/invalid" --port "$invalid_port"
done
expect_failure --port
expect_failure --app-dir --no-start
expect_failure --unknown
export TEST_OS=Linux
expect_failure --app-dir "$TEST_ROOT/invalid"
installer --help > "$TEST_ROOT/output.log"
[ ! -d "$TEST_ROOT/invalid" ] || fail 'invalid invocation created a directory'
printf 'PASS: invalid options and unsupported platforms fail before installation\n'
printf 'All macOS installer fixture tests passed. Native macOS UI behavior is not covered.\n'

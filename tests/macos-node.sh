#!/usr/bin/env bash
# Behavior tests for the macOS portable Node installer; no network or GUI.
# Runs on Bash 3.2+ with tar, awk and shasum (or sha256sum).
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dsh-macos-node.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
cleanup() {
  case "$TEST_ROOT" in
    */dsh-macos-node.??????) rm -rf -- "$TEST_ROOT" ;;
    *) printf 'Refusing to remove unexpected test path: %s\n' "$TEST_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

# Load only the launcher functions under test, never the launcher entry point.
eval "$(sed -n '/^node_arch() {/,/^read_server_url() {/p' "$REPO_DIR/dsh-window.sh" | sed '$d')"
eval "$(sed -n '/^node_version_supported() {/,/^}/p' "$REPO_DIR/dsh-window.sh" | sed 's/^node_version_supported()/actual_node_version_supported()/')"
# Keep a developer's real Homebrew/Volta/Node installation out of the fixtures.
node_version_supported() {
  case "$1" in
    "$TEST_ROOT"/*) actual_node_version_supported "$@" ;;
    *) return 1 ;;
  esac
}

step() { printf '%s\n' "$1" >&2; }
note() { printf '%s\n' "$1" >&2; }
sha256_of_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail_test "$3: expected '$2', got '$1'"; }
assert_file() { [ -f "$1" ] || fail_test "missing file: $1"; }
assert_absent() { [ ! -e "$1" ] || fail_test "unexpected path: $1"; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail_test "$3"; }
passed=0
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

make_node() {
  local target="$1" version="$2" exit_code="${3:-0}"
  mkdir -p "$(dirname "$target")"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit %s\n' "$version" "$exit_code" > "$target"
  chmod +x "$target"
}

for version in v22.18.0 v22.19.0 v23.9.0 v24.0.0 v25.0.0 bad-v24.0.0 v24.0.invalid; do
  make_node "$TEST_ROOT/versions/$version/node" "$version"
done
for version in v22.19.0 v24.0.0 v25.0.0; do
  assert_eq "$(node_version_supported "$TEST_ROOT/versions/$version/node")" "${version#v}" "supported Node version"
done
for version in v22.18.0 v23.9.0 bad-v24.0.0 v24.0.invalid; do
  if node_version_supported "$TEST_ROOT/versions/$version/node"; then fail_test "accepted $version"; fi
done
make_node "$TEST_ROOT/versions/nonzero/node" v24.0.0 1
if node_version_supported "$TEST_ROOT/versions/nonzero/node"; then fail_test 'accepted failed --version command'; fi
make_node "$TEST_ROOT/versions/multiline/node" $'v24.0.0\ninvalid'
if node_version_supported "$TEST_ROOT/versions/multiline/node"; then fail_test 'accepted malformed multiline version output'; fi
pass 'only usable supported Node versions are accepted'

make_node "$TEST_ROOT/old node/bin/node" v18.20.0
make_node "$TEST_ROOT/new node/bin/node" v24.3.0
assert_eq "$(PATH="$TEST_ROOT/old node/bin:$TEST_ROOT/new node/bin:$PATH" find_node_exe)" "$TEST_ROOT/new node/bin/node" 'PATH must skip old Node and preserve spaces'
pass 'unsupported earlier PATH entries do not hide a newer runtime'

make_node "$TEST_ROOT/managed app/node/old runtime/bin/node" v22.18.0
make_node "$TEST_ROOT/managed app/node/new runtime/bin/node" v24.3.0
assert_eq "$(find_managed_node_exe "$TEST_ROOT/managed app")" "$TEST_ROOT/managed app/node/new runtime/bin/node" 'managed traversal preserves spaces'
printf '%s\n' "$TEST_ROOT/missing external/node" > "$TEST_ROOT/managed app/node-runtime.path"
assert_eq "$(find_managed_node_exe "$TEST_ROOT/managed app")" "$TEST_ROOT/managed app/node/new runtime/bin/node" 'stale external record falls back to internal runtime'
pass 'managed traversal handles spaces and stale external records'

# Real archives/checksums with executable fixtures stand in for downloaded Node.
FIXTURES="$TEST_ROOT/fixtures"
mkdir -p "$FIXTURES"
for fixture_version in v24.3.0 v22.19.0; do
  for fixture_arch in x64 arm64; do
    package="node-${fixture_version}-darwin-${fixture_arch}"
    make_node "$FIXTURES/build/$package/bin/node" "$fixture_version"
    tar -czf "$FIXTURES/$package.tar.gz" -C "$FIXTURES/build" "$package"
  done
done
make_node "$FIXTURES/corrupt/node-v24.3.0-darwin-x64/bin/node" v25.0.0
tar -czf "$FIXTURES/corrupt.tar.gz" -C "$FIXTURES/corrupt" node-v24.3.0-darwin-x64
printf 'not an archive\n' > "$FIXTURES/unextractable.tar.gz"

begin_case() {
  CASE_DIR="$TEST_ROOT/$1"
  APP_DIR="$CASE_DIR/App Support"
  mkdir -p "$APP_DIR"
  : > "$CASE_DIR/requests"
  : > "$CASE_DIR/downloads"
  DESKTOP=1
  SILENT_NODE_INSTALL=0
  SELECTED_DIR="$CASE_DIR/Custom Node's folder"
  mkdir -p "$SELECTED_DIR"
  CHOOSER_CANCEL=0
  TEST_ARCH=x64
  SCENARIO=success
}
uname() { printf '%s\n' "$TEST_ARCH" | sed 's/^x64$/x86_64/'; }
osascript() {
  printf '%s\n' "$@" > "$CASE_DIR/chooser-arguments"
  cat > "$CASE_DIR/chooser-script"
  [ "$CHOOSER_CANCEL" = 0 ] || return 1
  printf '%s/\n' "$SELECTED_DIR"
}
fetch_text() {
  local url="$1" version archive digest
  printf '%s\n' "$url" >> "$CASE_DIR/requests"
  case "$SCENARIO:$url" in
    unavailable:*|v22:*latest-v24.x/*) return 1 ;;
    v22:*nodejs.org*) return 1 ;;
  esac
  case "$url" in
    */latest-v24.x/SHASUMS256.txt) version=v24.3.0 ;;
    */latest-v22.x/SHASUMS256.txt) version=v22.19.0 ;;
    *) return 1 ;;
  esac
  archive="node-${version}-darwin-${TEST_ARCH}.tar.gz"
  digest="$(sha256_of_file "$FIXTURES/$archive")"
  case "$SCENARIO:$url" in
    invalid_digest:*nodejs.org*) digest=badchecksum ;;
    bad_tar:*nodejs.org*) digest="$(sha256_of_file "$FIXTURES/unextractable.tar.gz")" ;;
  esac
  printf '%s  %s\n' "$digest" "$archive"
}
fetch_file() {
  local url="$1" target="$2" archive
  printf '%s\n' "$url" >> "$CASE_DIR/downloads"
  archive="${url##*/}"
  case "$SCENARIO:$url" in
    corrupt:*nodejs.org*) cp "$FIXTURES/corrupt.tar.gz" "$target" ;;
    bad_tar:*nodejs.org*) cp "$FIXTURES/unextractable.tar.gz" "$target" ;;
    failed_download:*nodejs.org*) printf partial > "$target"; return 1 ;;
    *) cp "$FIXTURES/$archive" "$target" ;;
  esac
}
check_install() {
  local expected_version="$1"
  NODE_EXE="$(install_node_runtime "$APP_DIR" 2> "$CASE_DIR/install.log")" || fail_test "installation failed in $CASE_DIR"
  assert_file "$NODE_EXE"
  assert_eq "$(node_version_supported "$NODE_EXE")" "$expected_version" 'installed version'
  assert_eq "$(cat "$APP_DIR/node-runtime.path")" "$NODE_EXE" 'persisted runtime executable'
  assert_eq "$(find_managed_node_exe "$APP_DIR")" "$NODE_EXE" 'runtime recovered on next launch'
  if find "$APP_DIR" -name 'node-download.*' | grep . >/dev/null; then fail_test 'download file was not cleaned up'; fi
}

begin_case silent
SILENT_NODE_INSTALL=1
check_install 24.3.0
assert_absent "$CASE_DIR/chooser-script"
assert_eq "$NODE_EXE" "$APP_DIR/node/node-v24.3.0-darwin-x64/bin/node" 'silent install destination'
assert_eq "$(wc -l < "$CASE_DIR/downloads" | tr -d '[:space:]')" 1 'prefer v24 official source'
pass 'silent installation uses v24 x64 in the application directory'

begin_case custom
check_install 24.3.0
assert_eq "$NODE_EXE" "$SELECTED_DIR/dsh-node-runtime/node-v24.3.0-darwin-x64/bin/node" 'custom destination'
assert_contains "$CASE_DIR/chooser-script" 'choose folder' 'native folder chooser not called'
assert_contains "$CASE_DIR/chooser-arguments" "$APP_DIR" 'default folder was not passed as an argument'
if grep -F 'installer -pkg' "$CASE_DIR/chooser-script" >/dev/null; then fail_test 'system installer used'; fi
pass 'native chooser installs in a custom folder and persists its runtime path'

begin_case cancel
CHOOSER_CANCEL=1
check_install 24.3.0
assert_file "$CASE_DIR/chooser-script"
assert_eq "$NODE_EXE" "$APP_DIR/node/node-v24.3.0-darwin-x64/bin/node" 'cancelled chooser destination'
pass 'cancelled chooser falls back to the application directory'

begin_case headless
DESKTOP=0
TEST_ARCH=arm64
check_install 24.3.0
assert_absent "$CASE_DIR/chooser-script"
assert_eq "$NODE_EXE" "$APP_DIR/node/node-v24.3.0-darwin-arm64/bin/node" 'headless arm64 destination'
pass 'headless installation skips the GUI and selects arm64'

begin_case fallback22
SILENT_NODE_INSTALL=1
SCENARIO=v22
check_install 22.19.0
assert_eq "$(wc -l < "$CASE_DIR/requests" | tr -d '[:space:]')" 4 'v24/v22 and official/mirror request ordering'
assert_contains "$CASE_DIR/downloads" 'https://registry.npmmirror.com/-/binary/node/latest-v22.x/node-v22.19.0-darwin-x64.tar.gz' 'v22 mirror was not used'
pass 'both v24 sources can fall back to the v22 mirror'

begin_case corrupt
SILENT_NODE_INSTALL=1
SCENARIO=corrupt
check_install 24.3.0
assert_contains "$CASE_DIR/install.log" 'checksum mismatch' 'corrupt archive was not rejected by SHA256'
assert_eq "$(wc -l < "$CASE_DIR/downloads" | tr -d '[:space:]')" 2 'retry mirror after checksum failure'
pass 'a runnable but corrupt archive is rejected before trying the mirror'

begin_case invalid_digest
SILENT_NODE_INSTALL=1
SCENARIO=invalid_digest
check_install 24.3.0
assert_eq "$(wc -l < "$CASE_DIR/downloads" | tr -d '[:space:]')" 1 'invalid checksum must prevent the official archive download'
assert_contains "$CASE_DIR/downloads" 'registry.npmmirror.com' 'invalid manifest did not fall back to mirror'
pass 'malformed SHA256 manifest entries are never used'

begin_case bad_tar
SILENT_NODE_INSTALL=1
SCENARIO=bad_tar
check_install 24.3.0
assert_contains "$CASE_DIR/install.log" 'could not provide a supported runtime' 'archive extraction failure was not handled'
if find "$APP_DIR/node" -name 'node-install.*' | grep . >/dev/null; then fail_test 'failed extraction directory was not cleaned'; fi
pass 'verified but unusable archives are cleaned up before a mirror retry'

begin_case failed_download
SILENT_NODE_INSTALL=1
SCENARIO=failed_download
check_install 24.3.0
assert_eq "$(wc -l < "$CASE_DIR/downloads" | tr -d '[:space:]')" 2 'failed download retry'
pass 'partial failed downloads are cleaned up before retrying'

begin_case unavailable
SILENT_NODE_INSTALL=1
SCENARIO=unavailable
if install_node_runtime "$APP_DIR" > "$CASE_DIR/stdout" 2> "$CASE_DIR/install.log"; then fail_test 'unavailable installation succeeded'; fi
assert_absent "$APP_DIR/node-runtime.path"
assert_eq "$(cat "$CASE_DIR/stdout")" '' 'failed installation must return no runtime'
pass 'unavailable sources return failure without a runtime record'

printf 'Passed %s macOS Node behavior tests.\n' "$passed"

#!/usr/bin/env bash
#
# Start DeepSeek Harness in a standalone application window on macOS.
#
# Installs (first run) and launches @deepseek-ai/dsh, then opens the Web UI in
# a Chromium application window (Chrome, Edge, or Brave) with its own browser
# profile; a fallback opens the default browser when no Chromium browser is
# installed.
#
# A menu bar icon stays behind while the task runs: closing the window does not
# stop the server, left clicking the icon brings the window back, right clicking
# opens the menu, and only its Exit item stops the server.
#
# Each launch compares the installed launcher with the repository and replaces
# it when it differs, so a published fix reaches this machine without
# reinstalling. An unavailable network leaves the installed copy in place and
# the launch continues.
#
# Usage:
#   dsh-window.sh [--port N] [--app-dir DIR] [--browser chrome|edge|brave|PATH]
#                 [--url URL] [--no-window] [--no-sync] [--uninstall]
#                 [--no-tray] [--silent-node-install] [--self-test]
#
# The menu bar icon calls this same script with --open-window, --open-browser,
# --restart, --copy-url, --open-log, --open-folder, or --stop, so those flags
# act on the launch recorded on this machine.
#
# Requires macOS and the tools macOS ships with (curl, shasum, osascript).

set -u

DSH_PACKAGE='@deepseek-ai/dsh'
SHORTCUT_NAME='DeepSeek Harness'
REPO_RAW='https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main'

PORT=3080
APP_DIR="${HOME}/Library/Application Support/dsh-shortcut"
URL=''
BROWSER='chrome'
NO_WINDOW=0
NO_SYNC=0
UNINSTALL=0
SELF_TEST=0
NO_TRAY=0
SILENT_NODE_INSTALL=0
ACTION=''
EXTERNAL_URL=''

# Keep the invocation for the restart that follows a launcher update.
ORIGINAL_ARGS=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --port|--app-dir|--url|--browser)
      [ $# -ge 2 ] && [ -n "$2" ] || { printf 'missing value for %s\n' "$1" >&2; exit 2; }
      ;;
  esac
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --browser) BROWSER="$2"; shift 2 ;;
    --no-window) NO_WINDOW=1; shift ;;
    --no-sync) NO_SYNC=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    --no-tray) NO_TRAY=1; shift ;;
    --silent-node-install) SILENT_NODE_INSTALL=1; shift ;;
    --open-window) ACTION='open-window'; shift ;;
    --open-browser) ACTION='open-browser'; shift ;;
    --restart) ACTION='restart'; shift ;;
    --copy-url) ACTION='copy-url'; shift ;;
    --open-log) ACTION='open-log'; shift ;;
    --open-folder) ACTION='open-folder'; shift ;;
    --stop) ACTION='stop'; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
EXTERNAL_URL="$URL"

# Status output goes to stderr so a function that returns a value on stdout (a
# URL, a path) is safe to call inside a command substitution.
step() { printf '==> %s\n' "$1" >&2; }
note() { printf '    %s\n' "$1" >&2; }
fail() { printf 'ERROR: %s\n' "$1" >&2; }

die() {
  fail "$1"
  if [ "${DESKTOP:-1}" = "1" ]; then
    show_alert "$1"
  fi
  exit 1
}

# Show a native dialog when a desktop session is available; a hidden launch
# would otherwise fail silently.
show_alert() {
  command -v osascript >/dev/null 2>&1 || return 0
  osascript - "$SHORTCUT_NAME" "$1" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  display alert (item 1 of argv) message (item 2 of argv) as critical
end run
APPLESCRIPT
}

sha256_of_file() {
  [ -f "$1" ] || return 1
  shasum -a 256 "$1" | awk '{print $1}'
}

sha256_of_string() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

# Read a repository file into stdout; fails fast so a launch never stalls on an
# unavailable network.
fetch_text() {
  curl -fsSL --connect-timeout 8 --max-time 20 "$1"
}

# Download a file without loading it into memory; Node.js archives are ~40 MB.
fetch_file() {
  curl -fL --connect-timeout 15 --max-time 600 -o "$2" "$1"
}

node_arch() {
  case "$(uname -m)" in
    arm64) printf 'arm64' ;;
    x86_64) printf 'x64' ;;
    *) printf 'x64' ;;
  esac
}

# Skip unsupported installations, including an old node earlier on PATH.
find_node_exe() {
  local candidate directory
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node \
      /opt/homebrew/opt/node@24/bin/node /usr/local/opt/node@24/bin/node \
      /opt/homebrew/opt/node@22/bin/node /usr/local/opt/node@22/bin/node \
      "${HOME}/.volta/bin/node"; do
    if node_version_supported "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  while IFS= read -r directory; do
    candidate="${directory:-.}/node"
    if node_version_supported "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done < <(printf '%s\n' "${PATH:-}" | tr ':' '\n')
  return 1
}

# A selected external runtime is remembered without changing the user's PATH.
# Its record belongs to this application; the external runtime does not.
find_managed_node_exe() {
  local install_dir="$1" root candidate
  if [ -f "${install_dir}/node-runtime.path" ]; then
    candidate=''
    IFS= read -r candidate < "${install_dir}/node-runtime.path" || true
    if node_version_supported "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  fi
  root="${install_dir}/node"
  [ -d "$root" ] || return 1
  while IFS= read -r -d '' candidate; do
    if node_version_supported "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done < <(find "$root" -maxdepth 3 -name node -type f -print0 2>/dev/null)
  return 1
}

# Let the user choose the portable runtime's parent folder. AppleScript receives
# paths as arguments, so spaces and quotes never become executable script text.
node_install_root() {
  local install_dir="$1" selected=''
  if [ "${DESKTOP:-1}" = '1' ] && [ "${SILENT_NODE_INSTALL:-0}" != '1' ] && command -v osascript >/dev/null 2>&1; then
    step 'Choose a folder for Node.js (Cancel uses the application folder)'
    selected="$(osascript - "$install_dir" 2>/dev/null <<'APPLESCRIPT'
on run argv
  activate
  set chosenFolder to choose folder with prompt "Choose where to install Node.js. A dsh-node-runtime folder will be created there. Cancel installs inside the application folder." default location (POSIX file (item 1 of argv))
  return POSIX path of chosenFolder
end run
APPLESCRIPT
    )" || selected=''
  fi
  if [ -n "$selected" ]; then
    printf '%s' "${selected%/}/dsh-node-runtime"
  else
    printf '%s' "${install_dir}/node"
  fi
}

# Install the CPU-specific portable archive, preferring v24 then v22. Every
# source must publish the matching SHA256 before its archive can be extracted.
install_node_runtime() {
  local install_dir="$1" arch major line source sums archive_line expected archive
  local runtime_root tarball staging destination found record_tmp
  mkdir -p "$install_dir" || return 1
  install_dir="$(cd "$install_dir" && pwd -P)" || return 1
  arch="$(node_arch)"
  runtime_root="$(node_install_root "$install_dir")"
  if ! mkdir -p "$runtime_root" || [ ! -w "$runtime_root" ]; then
    note 'the selected folder is not writable; using the application folder'
    runtime_root="${install_dir}/node"
    mkdir -p "$runtime_root" || return 1
  fi
  runtime_root="$(cd "$runtime_root" && pwd -P)" || return 1
  for major in 24 22; do
    line="latest-v${major}.x"
    for source in https://nodejs.org/dist https://registry.npmmirror.com/-/binary/node; do
      sums="$(fetch_text "${source}/${line}/SHASUMS256.txt" 2>/dev/null || true)"
      [ -n "$sums" ] || continue
      archive_line="$(printf '%s\n' "$sums" | awk -v major="$major" -v arch="$arch" '
        length($1) == 64 && $1 ~ /^[0-9a-fA-F]+$/ &&
        $2 ~ ("^node-v" major "\\.[0-9]+\\.[0-9]+-darwin-" arch "\\.tar\\.gz$") {
          print tolower($1), $2; exit
        }')"
      [ -n "$archive_line" ] || continue
      expected="${archive_line%% *}"
      archive="${archive_line#* }"
      tarball="$(mktemp "${install_dir}/node-download.XXXXXX")" || return 1
      note "downloading ${archive} from ${source}"
      if ! fetch_file "${source}/${line}/${archive}" "$tarball" 2>/dev/null; then
        rm -f "$tarball"
        continue
      fi
      if [ "$(sha256_of_file "$tarball")" != "$expected" ]; then
        rm -f "$tarball"
        note 'checksum mismatch for the Node.js archive; discarding it'
        continue
      fi
      staging="$(mktemp -d "${runtime_root}/node-install.XXXXXX")" || { rm -f "$tarball"; return 1; }
      if ! tar -xzf "$tarball" -C "$staging" --strip-components=1 || ! node_version_supported "${staging}/bin/node" >/dev/null 2>&1; then
        rm -f "$tarball"
        rm -rf "$staging"
        note 'the Node.js archive could not provide a supported runtime; trying another source'
        continue
      fi
      rm -f "$tarball"
      destination="${runtime_root}/${archive%.tar.gz}"
      # Never replace a directory the user already has. The unique staging
      # directory is also a complete, usable installation if this name exists.
      if [ -e "$destination" ]; then
        destination="$staging"
      elif ! mv "$staging" "$destination"; then
        rm -rf "$staging"
        continue
      fi
      found="${destination}/bin/node"
      record_tmp="$(mktemp "${install_dir}/node-runtime.path.XXXXXX")" || return 1
      if ! printf '%s\n' "$found" > "$record_tmp" || ! mv -f "$record_tmp" "${install_dir}/node-runtime.path"; then
        rm -f "$record_tmp"
        return 1
      fi
      printf '%s' "$found"
      return 0
    done
  done
  return 1
}

# Echo the version when the runtime is supported (22.19+, or 24+), else nothing.
node_version_supported() {
  local exe="$1" text major minor
  [ -x "$exe" ] || return 1
  text="$("$exe" --version 2>/dev/null)" || return 1
  case "$text" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$text" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || return 1
  text="${text#v}"
  major="${text%%.*}"
  minor="${text#*.}"
  minor="${minor%%.*}"
  if { [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; } || [ "$major" -ge 24 ]; then
    printf '%s' "$text"
    return 0
  fi
  return 1
}

read_server_url() {
  local log="$1" pid="${2:-}" attempt text match
  attempt=0
  while [ "$attempt" -lt 150 ]; do
    sleep 0.8
    attempt=$((attempt + 1))
    [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null || return 1
    [ -f "$log" ] || continue
    text="$(cat "$log" 2>/dev/null || true)"
    match="$(printf '%s' "$text" | grep -Eo 'https?://127\.0\.0\.1:[0-9]+/\?token=[^[:space:]]+' | head -n 1 || true)"
    if [ -n "$match" ]; then
      printf '%s' "$match"
      return 0
    fi
  done
  return 1
}

# True when something answers HTTP on the loopback port.
port_serving() {
  local port="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

# True when the URL authenticates: dsh answers a redirect for a valid token or
# signed cookie and 401 for everything else.
url_authenticated() {
  local url="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
  case "$code" in
    2*|3*) return 0 ;;
    *) return 1 ;;
  esac
}

port_owner_pid() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n 1
}

# The process on the port, as a full command line.
pid_command() {
  ps -p "$1" -o command= 2>/dev/null || true
}

# Recover an authenticated URL for a harness that already runs: the launch
# token lives in the records a previous launch wrote, and every candidate is
# verified against the running server before it is trusted.
authenticated_server_url() {
  local port="$1" install_dir="$2" owner pid_file url_file recorded_pid candidate token log
  owner="$(port_owner_pid "$port")"
  pid_file="${install_dir}/server-${port}.pid"
  url_file="${install_dir}/server-${port}.url"
  if [ -n "$owner" ] && [ -f "$pid_file" ] && [ -f "$url_file" ]; then
    recorded_pid="$(head -n 1 "$pid_file" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$recorded_pid" ] && [ "$recorded_pid" = "$owner" ]; then
      candidate="$(head -n 1 "$url_file" 2>/dev/null)"
      if [ -n "$candidate" ] && url_authenticated "$candidate"; then
        printf '%s' "$candidate"
        return 0
      fi
    fi
  fi
  for log in "${install_dir}/server-${port}.log" "${install_dir}/server.log"; do
    [ -f "$log" ] || continue
    for token in $(grep -Eo "http://127\.0\.0\.1:${port}/\?token=[A-Za-z0-9_-]{16,}" "$log" 2>/dev/null | sort -r || true); do
      if url_authenticated "$token"; then
        printf '%s' "$token"
        return 0
      fi
    done
  done
  return 1
}

# Stop the server this installation started on the port. A server someone else
# started is left alone.
stop_managed_port_owner() {
  local port="$1" install_dir="$2" owner pid_file recorded_pid entry command_text deadline
  owner="$(port_owner_pid "$port")"
  [ -n "$owner" ] || { ! port_serving "$port"; return $?; }
  pid_file="${install_dir}/server-${port}.pid"
  recorded_pid=""
  [ -f "$pid_file" ] && recorded_pid="$(head -n 1 "$pid_file" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$recorded_pid" ]; then
    [ "$recorded_pid" = "$owner" ] || return 1
  fi
  # A PID can be recycled. Its command must still belong to this installation.
  entry="${install_dir}/node_modules/@deepseek-ai/dsh/lib/bin.js"
  command_text="$(pid_command "$owner")"
  # The entry path has to be one whole argument followed by the web
  # subcommand: a lookalike path such as bin.js.other is another program.
  case "$command_text" in
    "$entry web"|"$entry web "*|*" $entry web"|*" $entry web "*) ;;
    *) return 1 ;;
  esac
  note "stopping the managed server (pid ${owner})"
  kill "$owner" 2>/dev/null || true
  deadline=$(( $(date +%s) + 10 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$pid_file" "${install_dir}/server-${port}.url"
      return 0
    fi
    sleep 0.25
  done
  # Recheck ownership before escalating, in case the process exited meanwhile.
  [ "$(pid_command "$owner")" = "$command_text" ] && kill -9 "$owner" 2>/dev/null || true
  sleep 1
  if ! port_serving "$port"; then
    rm -f "$pid_file" "${install_dir}/server-${port}.url"
    return 0
  fi
  return 1
}

start_dsh_server() {
  local node_exe="$1" bin="$2" port="$3" install_dir="$4" log log_err pid url
  log="${install_dir}/server-${port}.log"
  log_err="${install_dir}/server-${port}.err.log"
  step "Starting dsh web on port ${port}"
  PATH="$(dirname "$node_exe"):$PATH" nohup "$node_exe" "$bin" web --no-open --port "$port" >"$log" 2>"$log_err" </dev/null &
  pid=$!
  printf '%s' "$pid" > "${install_dir}/server-${port}.pid"
  note "server pid ${pid}; log ${log}"
  url="$(read_server_url "$log" "$pid")" || {
    kill "$pid" 2>/dev/null || true
    rm -f "${install_dir}/server-${port}.pid" "${install_dir}/server-${port}.url"
    return 1
  }
  printf '%s' "$url" > "${install_dir}/server-${port}.url"
  printf '%s' "$pid" > "${install_dir}/server-${port}.pid"
  printf '%s' "$url"
}

get_dsh_bin() {
  local bin="$1/node_modules/@deepseek-ai/dsh/lib/bin.js"
  [ -f "$bin" ] && printf '%s' "$bin"
}

# Browser executable for an application window. A path is used as given; a name
# is resolved to the usual macOS application bundles, preferring the requested
# browser and falling back to any Chromium browser that is installed.
browser_exe() {
  local preference="$1" candidate preferred
  case "$preference" in
    */*)
      [ -x "$preference" ] && printf '%s' "$preference"
      return 0
      ;;
  esac
  case "$preference" in
    edge) preferred="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" ;;
    brave) preferred="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" ;;
    *) preferred="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ;;
  esac
  for candidate in "$preferred" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
    "${HOME}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "${HOME}/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
    "${HOME}/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"; do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

open_app_window() {
  local exe="$1" url="$2" profile="$3"
  if [ -z "$exe" ]; then
    note 'no Chromium browser found; opening the default browser instead'
    open "$url"
    return 0
  fi
  note "application window via $(basename "$exe")"
  nohup "$exe" --app="$url" --no-first-run --user-data-dir="$profile" >/dev/null 2>&1 </dev/null &
}

# The application window, when one is already open: the profile directory is
# unique to this installation, so a Chromium process carrying it owns the
# window. Activating that browser raises the window instead of stacking a
# second one.
focus_app_window() {
  local exe="$1" profile="$2" pid result
  [ -n "$exe" ] || return 1
  pid="$(browser_pid "$exe" "$profile")"
  [ -n "$pid" ] || return 1
  # Chromium can keep a process after its last window closes. Only activate it
  # if CoreGraphics reports an actual window; otherwise create a new app window.
  # Window ownership/layer metadata does not require Accessibility permission.
  result="$(osascript -l JavaScript - "$pid" 2>/dev/null <<'JXA'
ObjC.import('AppKit');
ObjC.import('CoreGraphics');
function run(argv) {
  var pid = Number(argv[0]);
  var windows = ObjC.deepUnwrap($.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, $.kCGNullWindowID));
  if (!windows.some(function(w) { return Number(w.kCGWindowOwnerPID) === pid && Number(w.kCGWindowLayer) === 0; })) return 'missing';
  var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pid);
  app.unhide;
  app.activateWithOptions(3);
  return 'focused';
}
JXA
)"
  [ "$result" = focused ]
}

browser_profile() { printf '%s/browser-profile-%s' "$1" "$PORT"; }

browser_pid() {
  local exe="$1" profile="$2"
  ps -ax -o pid=,command= 2>/dev/null | awk -v exe="$exe" -v marker="--user-data-dir=$profile" '
    { pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
      if (index($0, exe " ")!=1 || index($0, "--type=")>0) next
      # The profile has to be a whole argument: a prefix of a longer value such
      # as browser-profile-30801 belongs to another installation, not this one.
      rest=$0; offset=0
      while ((pos=index(rest, marker))>0) {
        at=offset+pos
        before=(at==1) ? "" : substr($0, at-1, 1)
        after=substr($0, at+length(marker), 1)
        if ((before=="" || before==" ") && (after=="" || after==" ")) { print pid; exit }
        offset=at; rest=substr($0, at+1)
      }
    }'
}

close_app_window() {
  local exe pid
  exe="$(browser_exe "$BROWSER" || true)"
  [ -n "$exe" ] || return 0
  pid="$(browser_pid "$exe" "$(browser_profile "$1")")"
  # This process owns only our dedicated Chromium profile.
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
}

invoke_dsh_install() {
  local install_dir="$1" node_exe="$2" npm
  npm="$(dirname "$node_exe")/npm"
  [ -x "$npm" ] || npm="$(command -v npm 2>/dev/null || true)"
  [ -n "$npm" ] || die 'npm was not found next to the selected Node.js runtime.'
  mkdir -p "$install_dir"
  if [ ! -f "${install_dir}/package.json" ]; then
    printf '{\n  "name": "dsh-shortcut",\n  "private": true\n}\n' > "${install_dir}/package.json"
  fi
  step "Installing ${DSH_PACKAGE} (first run; 1-3 minutes)"
  (
    cd "$install_dir" || exit 1
    PATH="$(dirname "$node_exe"):${PATH}" "$npm" install "$DSH_PACKAGE" --no-audit --no-fund --loglevel=error
  ) || die "npm install failed"
}

# Replace the installed launcher when the repository has a different one. The
# bytes are staged first, and a download that does not parse is discarded, so a
# bad push cannot break a working installation.
valid_png() {
  [ "$(od -An -tx1 -N8 "$1" | tr -d ' \n')" = '89504e470d0a1a0a' ]
}

update_from_repo() {
  local install_dir="$1" script_path="$2" stage name changed=0
  stage="$(mktemp -d "${install_dir}/.sync.XXXXXX")" || return 1
  # Validate the complete set before replacing any installed file.
  for name in dsh-window.sh assets/tray-template.png assets/tray-template@2x.png; do
    mkdir -p "$(dirname "$stage/$name")"
    if ! fetch_text "${REPO_RAW}/${name}" > "$stage/$name" 2>/dev/null || [ ! -s "$stage/$name" ]; then
      note 'sync skipped (repository unavailable); keeping the installed files'
      rm -rf "$stage"
      return 1
    fi
    case "$name" in
      *.sh) bash -n "$stage/$name" || { rm -rf "$stage"; return 1; } ;;
      *.png) valid_png "$stage/$name" || { rm -rf "$stage"; return 1; } ;;
    esac
  done
  for name in dsh-window.sh assets/tray-template.png assets/tray-template@2x.png; do
    if [ "$(sha256_of_file "$stage/$name")" != "$(sha256_of_file "$install_dir/$name" || true)" ]; then
      mkdir -p "$(dirname "$install_dir/$name")"
      mv "$stage/$name" "$install_dir/$name" || { rm -rf "$stage"; return 1; }
      changed=1
      note "updated $name"
    fi
  done
  chmod +x "$install_dir/dsh-window.sh"
  rm -rf "$stage"
  [ "$changed" = 1 ] && [ "$script_path" = "$install_dir/dsh-window.sh" ]
}

install_local_files() {
  local script_path="$1" name source_dir
  source_dir="$(dirname "$script_path")"
  if [ "$script_path" != "$APP_DIR/dsh-window.sh" ]; then
    cp "$script_path" "$APP_DIR/.launcher.new" && mv "$APP_DIR/.launcher.new" "$APP_DIR/dsh-window.sh" || return 1
  fi
  mkdir -p "$APP_DIR/assets"
  for name in tray-template.png tray-template@2x.png; do
    if [ "$source_dir" != "$APP_DIR" ] && [ -f "$source_dir/assets/$name" ]; then
      cp "$source_dir/assets/$name" "$APP_DIR/assets/$name" || return 1
    fi
  done
  chmod +x "$APP_DIR/dsh-window.sh"
  printf '%s\n' 'dsh-shortcut' > "$APP_DIR/.dsh-shortcut"
}

install_shortcuts() {
  local script_path="$1" target
  for target in "${HOME}/Desktop/${SHORTCUT_NAME}.command" "${HOME}/Applications/${SHORTCUT_NAME}.command"; do
    mkdir -p "$(dirname "$target")"
    {
      printf '#!/bin/bash\n'
      printf 'exec "%s"\n' "$script_path"
    } > "$target"
    chmod +x "$target"
    note "shortcut: ${target}"
  done
}

# Serialize startup and tray callbacks, including simultaneous double clicks.
# Record process start time as well as PID so PID reuse cannot hold the slot.
acquire_launch_lock() {
  local lock="$APP_DIR/.launch-lock" attempt=0 owner started actual
  while ! mkdir "$lock" 2>/dev/null; do
    owner=''; started=''
    if [ -f "$lock/owner" ]; then
      { IFS= read -r owner; IFS= read -r started; } < "$lock/owner"
      case "$owner" in ''|*[!0-9]*) owner='' ;; esac
      actual=''
      [ -z "$owner" ] || actual="$(ps -p "$owner" -o lstart= 2>/dev/null)"
      if [ -n "$owner" ] && { [ -z "$actual" ] || [ "$actual" != "$started" ]; }; then
        rm -f "$lock/owner"
        rmdir "$lock" 2>/dev/null || true
        continue
      fi
    elif [ "$attempt" -ge 25 ]; then
      # A creator that died before writing its PID left an empty directory.
      rmdir "$lock" 2>/dev/null || true
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 300 ] || { fail 'another launch is still busy; try again when it finishes'; return 1; }
    sleep 0.2
  done
  LAUNCH_LOCK="$lock"
  printf '%s\n%s\n' "$$" "$(ps -p "$$" -o lstart=)" > "$lock/owner"
  trap 'release_launch_lock' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
}

release_launch_lock() {
  [ -n "${LAUNCH_LOCK:-}" ] || return 0
  if [ "$(head -n 1 "$LAUNCH_LOCK/owner" 2>/dev/null)" = "$$" ]; then
    rm -f "$LAUNCH_LOCK/owner"
    rmdir "$LAUNCH_LOCK" 2>/dev/null || true
  fi
  LAUNCH_LOCK=''
}

invoke_uninstall() {
  local install_dir="$1" port="$2" target
  [ -f "$install_dir/.dsh-shortcut" ] && [ -f "$install_dir/dsh-window.sh" ] || {
    fail 'refusing to remove a directory without this launcher installation marker'
    return 1
  }
  stop_managed_port_owner "$port" "$install_dir" || { fail 'the port is owned by another process'; return 1; }
  close_app_window "$install_dir"
  stop_tray "$install_dir"
  for target in "${HOME}/Desktop/${SHORTCUT_NAME}.command" "${HOME}/Applications/${SHORTCUT_NAME}.command"; do
    if [ -f "$target" ] && grep -F -- "$(shell_literal "$install_dir/dsh-window.sh")" "$target" >/dev/null; then
      rm -f "$target"
    fi
  done
  release_launch_lock
  rm -rf "$install_dir"
  step 'Uninstalled. Your Harness data under ~/.dsh and external Node.js runtimes were left in place.'
}

# ---- menu bar tray ---------------------------------------------------------
#
# macOS has no notification-area API a shell script can call, so the tray is a
# small AppleScriptObjC applet: it draws a status item in the menu bar, and
# every menu item runs this same script with one action flag. The applet is
# generated from the launcher so its menu can only act on the state this
# installation recorded, and it stays out of the Dock.

tray_app_path() {
  printf '%s' "$1/${SHORTCUT_NAME}-${PORT}.app"
}

tray_work_dir() {
  printf '%s/tray-%s' "$1" "$PORT"
}

tray_source_file() {
  printf '%s/tray.applescript' "$(tray_work_dir "$1")"
}

# PID of the applet this installation started, found by the bundle path in its
# command line. The path is unique to the installation, so another install's
# applet is never mistaken for this one. index() compares the literal path, so
# a directory with characters that are special to a regular expression still
# matches.
tray_pid() {
  local install_dir="$1" marker pid
  marker="$(tray_app_path "$install_dir")/Contents/MacOS/applet"
  pid="$(ps -ax -o pid=,command= 2>/dev/null | awk -v marker="$marker" '{ pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0==marker || index($0, marker " ")==1) { print pid; exit } }' || true)"
  [ -n "$pid" ] || return 1
  printf '%s' "$pid"
}

tray_running() {
  tray_pid "$1" >/dev/null 2>&1
}

# Leave the menu bar: the applet is asked to quit, and is forced out when it
# does not.
stop_tray() {
  local install_dir="$1" pid deadline
  pid="$(tray_pid "$install_dir" || true)"
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  deadline=$(( $(date +%s) + 5 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -9 "$pid" 2>/dev/null || true
  return 0
}

# Quote a value so it survives both AppleScript and the shell it is embedded in.
applescript_literal() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

shell_literal() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# The applet source. The launcher command is baked in so a menu item runs this
# script without an argument list of its own; the icon is a template image, so
# macOS inverts it for a light or dark menu bar.
tray_source() {
  local install_dir="$1" icon_width="$2" icon_height="$3" launcher command icon
  launcher="${install_dir}/dsh-window.sh"
  command="/bin/bash $(shell_literal "$launcher") --no-sync --port ${PORT} --app-dir $(shell_literal "$install_dir") --browser $(shell_literal "$BROWSER")"
  [ -z "$EXTERNAL_URL" ] || command="$command --url $(shell_literal "$EXTERNAL_URL")"
  icon="${install_dir}/assets/tray-template.png"
  cat <<APPLESCRIPT
use framework "Cocoa"
use scripting additions

-- The DeepSeek Harness menu bar icon. Left clicking opens the window; right
-- clicking shows the menu. Every action runs the launcher again, so the menu
-- only ever acts on the state this installation recorded.

property launcherCommand : $(applescript_literal "$command")
property iconPath : $(applescript_literal "$icon")
property iconWidth : ${icon_width}
property iconHeight : ${icon_height}
property appTitle : $(applescript_literal "$SHORTCUT_NAME")
property statusItem : missing value
property theMenu : missing value
property readyPath : $(applescript_literal "$(tray_work_dir "$install_dir")/ready")

on run
	set statusItem to current application's NSStatusBar's systemStatusBar()'s statusItemWithLength_(current application's NSVariableStatusItemLength)
	try
		set iconImage to current application's NSImage's alloc()'s initWithContentsOfFile_(iconPath)
		iconImage's setTemplate_(true)
		iconImage's setSize_({iconWidth, iconHeight})
		statusItem's button's setImage_(iconImage)
		if iconImage is missing value then error "Missing tray icon"
	on error
		statusItem's button's setTitle_("DSH")
	end try
	statusItem's button's setToolTip_(appTitle)
	statusItem's button's setTarget_(me)
	statusItem's button's setAction_("statusClicked:")
	-- NSEventMaskLeftMouseUp (2) + NSEventMaskRightMouseUp (8): a right click
	-- has to reach the handler too, or the menu can never open.
	statusItem's button's sendActionOn_(10)
	set theMenu to current application's NSMenu's alloc()'s init()
	my addItem("Open Window", "menuOpenWindow:")
	my addItem("Open in Browser", "menuOpenBrowser:")
	my addItem("Restart Server", "menuRestart:")
	my addItem("Copy URL", "menuCopyUrl:")
	my addItem("Open Log", "menuOpenLog:")
	my addItem("Open Install Folder", "menuOpenFolder:")
	theMenu's addItem_(current application's NSMenuItem's separatorItem())
	my addItem("Exit (stop server)", "menuExit:")
	-- A running PID alone does not prove that the menu was initialized.
	do shell script "/usr/bin/touch " & quoted form of readyPath
end run

on addItem(itemTitle, handlerName)
	set menuItem to theMenu's addItemWithTitle_action_keyEquivalent_(itemTitle, missing value, "")
	menuItem's setTarget_(me)
	menuItem's setAction_(handlerName)
end addItem

on statusClicked:sender
	set evt to current application's NSApplication's sharedApplication()'s currentEvent()
	if (evt's buttonNumber() as integer) is 0 then
		-- Left click: the window is what a click asks for.
		my menuOpenWindow:missing value
	else
		statusItem's popUpStatusItemMenu_(theMenu)
	end if
end statusClicked:

on menuOpenWindow:sender
	my runAction("--open-window")
end menuOpenWindow:

on menuOpenBrowser:sender
	my runAction("--open-browser")
end menuOpenBrowser:

on menuRestart:sender
	my runAction("--restart")
end menuRestart:

on menuOpenLog:sender
	my runAction("--open-log")
end menuOpenLog:

on menuOpenFolder:sender
	my runAction("--open-folder")
end menuOpenFolder:

on menuCopyUrl:sender
	set theUrl to ""
	try
		set theUrl to do shell script launcherCommand & " --copy-url"
	end try
	if theUrl is not "" then
		set the clipboard to theUrl
		display notification "The launch URL is on the clipboard" with title appTitle
	end if
end menuCopyUrl:

on menuExit:sender
	my runAction("--stop")
end menuExit:

on runAction(flag)
	-- The action outlives this call, so it is started in the background.
	try
		do shell script "nohup " & launcherCommand & " " & flag & " > /dev/null 2>&1 < /dev/null &"
	end try
end runAction

on idle
	-- Stay open: the menu bar icon is the way back to the window.
	return 30
end idle

on quit
	try
		current application's NSStatusBar's systemStatusBar()'s removeStatusItem_(statusItem)
	end try
	continue quit
end quit
APPLESCRIPT
}

# Build the applet when the generated source changed. Keeping the built app
# means a launch does not pay for osacompile every time.
build_tray_app() {
  local install_dir="$1" app work src generated staged
  app="$(tray_app_path "$install_dir")"
  work="$(tray_work_dir "$install_dir")"
  src="$(tray_source_file "$install_dir")"
  command -v osacompile >/dev/null 2>&1 || return 1
  mkdir -p "$work"
  generated="$(tray_source "$install_dir" "$2" "$3")"
  if [ ! -x "$app/Contents/MacOS/applet" ] || [ ! -f "$src" ] || [ "$(sha256_of_string "$generated")" != "$(sha256_of_string "$(cat "$src")")" ]; then
    staged="$(mktemp -d "$work/build.XXXXXX")" || return 1
    printf '%s\n' "$generated" > "$staged/tray.applescript"
    # -s keeps the applet open after its run handler returns, which a menu bar
    # icon needs.
    if ! osacompile -s -o "$staged/Tray.app" "$staged/tray.applescript" >"$work/build.log" 2>&1 || ! set_tray_agent "$staged/Tray.app"; then
      rm -rf "$staged"
      return 1
    fi
    stop_tray "$install_dir"
    rm -rf "$app"
    mv "$staged/Tray.app" "$app" && mv "$staged/tray.applescript" "$src" || { rm -rf "$staged"; return 1; }
    rm -rf "$staged"
  fi
  [ -x "${app}/Contents/MacOS/applet" ] || return 1
}

# A menu bar applet has no business in the Dock or the app switcher.
set_tray_agent() {
  local app="$1" info="$1/Contents/Info.plist"
  [ -f "$info" ] || return 1
  if /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$info" >/dev/null 2>&1; then
    :
  else
    /usr/libexec/PlistBuddy -c 'Set :LSUIElement true' "$info" >/dev/null 2>&1 \
      || return 1
  fi
  # Editing Info.plist invalidates the signature an ad-hoc applet carries, and
  # an invalid signature will not launch; sign it again when a tool is present.
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$app" >/dev/null 2>&1 || return 1
  fi
  return 0
}

start_tray() {
  local install_dir="$1" attempt=0 ready
  ready="$(tray_work_dir "$install_dir")/ready"
  if ! build_tray_app "$install_dir" "$2" "$3"; then
    note 'the menu bar applet could not be built; continuing without it'
    return 1
  fi
  if tray_running "$install_dir" && [ -f "$ready" ]; then return 0; fi
  stop_tray "$install_dir"
  rm -f "$ready"
  if ! open "$(tray_app_path "$install_dir")" >/dev/null 2>&1; then
    note 'the menu bar applet could not be started; continuing without it'
    return 1
  fi
  while [ "$attempt" -lt 50 ]; do
    if tray_running "$install_dir" && [ -f "$ready" ]; then
      note 'menu bar icon active: left-click opens the window, right-click shows the menu'
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fail "menu bar initialization failed; see $(tray_work_dir "$install_dir")/build.log"
  return 1
}
# ---- CLI actions the menu bar icon runs ------------------------------------

# The URL this installation recorded for the port, when it still authenticates.
recorded_url() {
  local install_dir="$1" port="$2" url
  [ -z "$EXTERNAL_URL" ] || { printf '%s' "$EXTERNAL_URL"; return 0; }
  url="$(authenticated_server_url "$port" "$install_dir" || true)"
  [ -n "$url" ] || return 1
  printf '%s' "$url"
}

# Bring the window back, starting a server first when none is running.
action_open_window() {
  local install_dir="$1" port="$2" url
  url="$(recorded_url "$install_dir" "$port" || true)"
  if [ -z "$url" ]; then
    note 'no harness is running for this installation; starting one'
    return 1
  fi
  if focus_app_window "$(browser_exe "$BROWSER" || true)" "$(browser_profile "$install_dir")"; then
    note 'raised the open window'
    return 0
  fi
  open_app_window "$(browser_exe "$BROWSER" || true)" "$url" "$(browser_profile "$install_dir")"
}

# Stop the server this installation started and start a fresh one. Restarting
# mints a new launch token, so the window is reopened with the new URL; a
# server this installation did not start is left alone.
action_restart() {
  local install_dir="$1" port="$2" node_exe node_bin url
  [ -z "$EXTERNAL_URL" ] || { fail 'an external URL is not managed by this launcher'; return 1; }
  if ! stop_managed_port_owner "$port" "$install_dir"; then
    note 'the running server was not started by this installation; not restarting it'
    return 1
  fi
  node_exe="$(find_node_exe || true)"
  [ -n "$node_exe" ] || node_exe="$(find_managed_node_exe "$install_dir" || true)"
  node_bin="$(get_dsh_bin "$install_dir")"
  if [ -z "$node_exe" ] || [ -z "$node_bin" ]; then
    note 'this installation has no runtime to start; run the shortcut instead'
    return 1
  fi
  url="$(start_dsh_server "$node_exe" "$node_bin" "$port" "$install_dir")" || {
    note "the restart failed; see ${install_dir}/server-${port}.log"
    return 1
  }
  note "restarted; Ready: ${url}"
  close_app_window "$install_dir"
  open_app_window "$(browser_exe "$BROWSER" || true)" "$url" "$(browser_profile "$install_dir")"
}

# Print the recorded URL so the menu can put it on the clipboard.
action_copy_url() {
  local install_dir="$1" port="$2" url
  url="$(recorded_url "$install_dir" "$port" || true)"
  [ -n "$url" ] || return 1
  printf '%s' "$url"
}

action_open_log() {
  local install_dir="$1" port="$2"
  [ -f "${install_dir}/server-${port}.log" ] || return 1
  open "${install_dir}/server-${port}.log" >/dev/null 2>&1
}

action_open_folder() {
  open "$1" >/dev/null 2>&1
}

# Leave the tray and stop the server this installation started; the menu bar
# icon is the only place that stops the task. A server someone else started is
# left alone, but the icon still leaves the menu bar.
action_stop() {
  local install_dir="$1" port="$2"
  if [ -z "$EXTERNAL_URL" ]; then
    stop_managed_port_owner "$port" "$install_dir" || note 'a server this installation did not start is still running; leaving it alone'
  fi
  close_app_window "$install_dir"
  stop_tray "$install_dir"
  note 'exited'
}

# Report what the tray builds without leaving an icon behind, so a build machine
# can check the menu bar applet.
tray_self_test() {
  local install_dir="$1" info
  start_tray "$install_dir" "$2" "$3" || return 1
  info="$(tray_app_path "$install_dir")/Contents/Info.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$info")" = true ] || return 1
  # Give initialization errors time to surface before accepting the test.
  sleep 2
  tray_running "$install_dir" && [ -f "$(tray_work_dir "$install_dir")/ready" ] || return 1
  stop_tray "$install_dir"
  step 'Tray self-test passed (menu initialized, agent stayed alive, exit confirmed)'
}

main() {
  [ "$(uname -s)" = Darwin ] || { fail 'this launcher requires macOS'; return 1; }
  case "$PORT" in ''|*[!0-9]*) fail 'port must be an integer from 1 to 65535'; return 2 ;; esac
  [ "${#PORT}" -le 5 ] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { fail 'port must be 1-65535'; return 2; }
  PORT=$((10#$PORT))
  case "$APP_DIR" in /*) ;; *) APP_DIR="$PWD/$APP_DIR" ;; esac
  case "$APP_DIR$BROWSER$URL" in *$'\n'*|*$'\r'*) fail 'paths and URLs must not contain line breaks'; return 2 ;; esac
  # New logs and token records are private to this user.
  umask 077
  mkdir -p "$APP_DIR" || return 1
  APP_DIR="$(cd "$APP_DIR" && pwd -P)" || return 1
  [ "$APP_DIR" != / ] && [ "$APP_DIR" != "$HOME" ] && [ "$APP_DIR" != "$HOME/.dsh" ] || { fail 'choose a dedicated installation directory'; return 2; }
  DESKTOP="${DESKTOP:-0}"
  if [ "$DESKTOP" = 0 ] && [ -z "${SSH_CONNECTION:-}" ] && [ "$(stat -f '%u' /dev/console 2>/dev/null)" = "$(id -u)" ]; then DESKTOP=1; fi
  acquire_launch_lock || return 1

  if [ "$UNINSTALL" = 1 ]; then invoke_uninstall "$APP_DIR" "$PORT"; return $?; fi
  case "$ACTION" in
    open-window) if action_open_window "$APP_DIR" "$PORT"; then return 0; fi ;;
    open-browser)
      local action_url
      action_url="$(recorded_url "$APP_DIR" "$PORT")" || die 'no running harness was found for this installation.'
      open "$action_url"; return $? ;;
    restart) action_restart "$APP_DIR" "$PORT" || die 'the server could not be restarted; see its log'; return 0 ;;
    copy-url) action_copy_url "$APP_DIR" "$PORT"; return $? ;;
    open-log) action_open_log "$APP_DIR" "$PORT"; return $? ;;
    open-folder) action_open_folder "$APP_DIR"; return $? ;;
    stop) action_stop "$APP_DIR" "$PORT" || die 'the server could not be stopped'; return 0 ;;
  esac

  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  install_local_files "$script_path" || die 'the launcher could not be installed'
  if [ "$NO_SYNC" = 0 ] && [ "$SELF_TEST" = 0 ]; then
    if update_from_repo "$APP_DIR" "$script_path"; then
      step 'The launcher was updated from the repository; restarting'
      release_launch_lock
      if [ "${#ORIGINAL_ARGS[@]}" -gt 0 ]; then
        exec /bin/bash "$APP_DIR/dsh-window.sh" "${ORIGINAL_ARGS[@]}" --no-sync
      fi
      exec /bin/bash "$APP_DIR/dsh-window.sh" --no-sync
    fi
  fi
  install_shortcuts "$APP_DIR/dsh-window.sh"
  # This check never installs Node or starts a Harness server.
  if [ "$SELF_TEST" = 1 ]; then tray_self_test "$APP_DIR" 23 17; return $?; fi

  if [ -z "$URL" ]; then
    if port_serving "$PORT"; then
      URL="$(authenticated_server_url "$PORT" "$APP_DIR" || true)"
      if [ -z "$URL" ]; then
        stop_managed_port_owner "$PORT" "$APP_DIR" || die "Port ${PORT} is occupied and its launch token could not be recovered. Choose another --port or use the server's own URL."
      else
        note 'reused the authenticated launch URL recorded on this machine'
      fi
    fi
    if [ -z "$URL" ]; then
      local node_exe version node_bin
      node_exe="$(find_node_exe || true)"
      [ -n "$node_exe" ] || node_exe="$(find_managed_node_exe "$APP_DIR" || true)"
      if [ -z "$node_exe" ]; then
        step 'Installing Node.js for this machine'
        node_exe="$(install_node_runtime "$APP_DIR" || true)"
      fi
      version="$(node_version_supported "$node_exe" || true)"
      [ -n "$version" ] || die 'No supported Node.js runtime is available. Install Node.js 22.19+ or 24+ and try again.'
      note "node ${version} (${node_exe})"
      node_bin="$(get_dsh_bin "$APP_DIR")"
      if [ -z "$node_bin" ]; then
        invoke_dsh_install "$APP_DIR" "$node_exe"
        node_bin="$(get_dsh_bin "$APP_DIR")"
      fi
      [ -n "$node_bin" ] || die 'The dsh package did not install correctly.'
      URL="$(start_dsh_server "$node_exe" "$node_bin" "$PORT" "$APP_DIR")" || die "the server did not report a URL; see ${APP_DIR}/server-${PORT}.log"
    fi
  fi
  step "Ready: ${URL}"
  [ "$NO_WINDOW" = 0 ] || return 0
  # Compile/update the tray on every launch so changed settings take effect.
  if [ "$NO_TRAY" = 0 ]; then
    start_tray "$APP_DIR" 23 17 || die "the menu bar icon could not start; see $(tray_work_dir "$APP_DIR")/build.log. Use --no-tray to run without it."
  fi
  if ! focus_app_window "$(browser_exe "$BROWSER" || true)" "$(browser_profile "$APP_DIR")"; then
    open_app_window "$(browser_exe "$BROWSER" || true)" "$URL" "$(browser_profile "$APP_DIR")"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

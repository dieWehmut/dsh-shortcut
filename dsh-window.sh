#!/usr/bin/env bash
#
# Start DeepSeek Harness in a standalone application window on macOS.
#
# Installs (first run) and launches @deepseek-ai/dsh, then opens the Web UI in
# a Chromium application window (Chrome, Edge, or Brave) with its own browser
# profile; a fallback opens the default browser when no Chromium browser is
# installed.
#
# Each launch compares the installed launcher with the repository and replaces
# it when it differs, so a published fix reaches this machine without
# reinstalling. An unavailable network leaves the installed copy in place and
# the launch continues.
#
# Usage:
#   dsh-window.sh [--port N] [--app-dir DIR] [--browser chrome|edge|brave|PATH]
#                 [--url URL] [--no-window] [--no-sync] [--uninstall]
#                 [--self-test]
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

# Keep the invocation for the restart that follows a launcher update.
ORIGINAL_ARGS=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --browser) BROWSER="$2"; shift 2 ;;
    --no-window) NO_WINDOW=1; shift ;;
    --no-sync) NO_SYNC=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

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
  osascript -e "display alert \"${SHORTCUT_NAME}\" message \"$1\" as critical" >/dev/null 2>&1 || true
}

sha256_of_file() {
  [ -f "$1" ] || return 1
  shasum -a 256 "$1" | awk '{print $1}'
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

# Locations Node.js is commonly installed to on macOS, then PATH.
find_node_exe() {
  local candidate on_path
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node "${HOME}/.volta/bin/node"; do
    [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  on_path="$(command -v node 2>/dev/null || true)"
  [ -n "$on_path" ] && { printf '%s' "$on_path"; return 0; }
  return 1
}

# A portable runtime this launcher installed lives under the application
# directory, so it needs no PATH entry.
find_managed_node_exe() {
  local install_dir="$1" root candidate
  root="${install_dir}/node"
  [ -d "$root" ] || return 1
  for candidate in $(find "$root" -maxdepth 3 -name node -type f 2>/dev/null || true); do
    if [ -n "$(node_version_supported "$candidate" || true)" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Install a Node.js runtime matched to this machine.
#
# The official .pkg opens the standard installer so the destination can be
# chosen; when that is skipped or fails, the archive for this CPU ships as a
# portable runtime under the application directory. Every download is accepted
# only after its SHA256 matches the published sums from the same source.
install_node_runtime() {
  local install_dir="$1" arch line source sums pkg_line expected version found tarball pkg
  arch="$(node_arch)"
  found=''

  for line in latest-v24.x latest-v22.x; do
    for source in https://nodejs.org/dist https://registry.npmmirror.com/-/binary/node; do
      sums="$(fetch_text "${source}/${line}/SHASUMS256.txt" 2>/dev/null || true)"
      [ -n "$sums" ] || continue
      # Prefer the interactive installer: it lets the destination be chosen.
      pkg_line="$(printf '%s' "$sums" | grep -E "node-v[0-9.]+\.pkg$" | head -n 1 || true)"
      if [ -n "$pkg_line" ]; then
        expected="$(printf '%s' "$pkg_line" | awk '{print $1}')"
        version="$(printf '%s' "$pkg_line" | awk '{print $2}' | sed -e 's/^node-//' -e 's/\.pkg$//')"
        if [ "${DESKTOP:-1}" = "1" ] && command -v installer >/dev/null 2>&1; then
          pkg="${install_dir}/node-${version}.pkg"
          note "downloading node-${version}.pkg from ${source}"
          if fetch_file "${source}/${line}/node-${version}.pkg" "$pkg" 2>/dev/null; then
            if [ "$(sha256_of_file "$pkg")" = "$expected" ]; then
              step 'Opening the Node.js installer (choose the destination there)'
              if osascript -e "do shell script \"installer -pkg '${pkg}' -target /\" with administrator privileges" >/dev/null 2>&1; then
                rm -f "$pkg"
                found="$(find_node_exe || true)"
                [ -n "$found" ] && { printf '%s' "$found"; return 0; }
              else
                note 'the Node.js installer was cancelled; using the portable runtime instead'
                rm -f "$pkg"
              fi
            else
              rm -f "$pkg"
              note 'checksum mismatch for the Node.js installer; discarding it'
            fi
          fi
        fi
      fi
      # Portable runtime for this CPU.
      pkg_line="$(printf '%s' "$sums" | grep -E "node-v[0-9.]+-darwin-${arch}\.tar\.gz$" | head -n 1 || true)"
      [ -n "$pkg_line" ] || continue
      expected="$(printf '%s' "$pkg_line" | awk '{print $1}')"
      version="$(printf '%s' "$pkg_line" | awk '{print $2}' | sed -e 's/^node-//' -e "s/-darwin-${arch}\.tar\.gz$//")"
      tarball="${install_dir}/node-${version}-darwin-${arch}.tar.gz"
      note "downloading node-${version}-darwin-${arch}.tar.gz from ${source}"
      fetch_file "${source}/${line}/node-${version}-darwin-${arch}.tar.gz" "$tarball" 2>/dev/null || continue
      if [ "$(sha256_of_file "$tarball")" != "$expected" ]; then
        rm -f "$tarball"
        note 'checksum mismatch for the Node.js archive; discarding it'
        continue
      fi
      mkdir -p "${install_dir}/node"
      tar -xzf "$tarball" -C "${install_dir}/node"
      rm -f "$tarball"
      found="$(find_managed_node_exe "$install_dir" || true)"
      [ -n "$found" ] && { printf '%s' "$found"; return 0; }
    done
  done
  return 1
}

# Echo the version when the runtime is supported (22.19+, or 24+), else nothing.
node_version_supported() {
  local exe="$1" text major minor
  [ -x "$exe" ] || return 1
  text="$("$exe" --version 2>/dev/null | sed 's/^v//')"
  case "$text" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) return 1 ;;
  esac
  major="${text%%.*}"
  minor="$(printf '%s' "$text" | cut -d. -f2)"
  if { [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; } || [ "$major" -ge 24 ]; then
    printf '%s' "$text"
    return 0
  fi
  return 1
}

read_server_url() {
  local log="$1" attempt text match
  attempt=0
  while [ "$attempt" -lt 150 ]; do
    sleep 0.8
    attempt=$((attempt + 1))
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
  [ -n "$owner" ] || return 1
  pid_file="${install_dir}/server-${port}.pid"
  recorded_pid=""
  [ -f "$pid_file" ] && recorded_pid="$(head -n 1 "$pid_file" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$recorded_pid" ]; then
    [ "$recorded_pid" = "$owner" ] || return 1
  else
    entry="${install_dir}/node_modules/@deepseek-ai/dsh/lib/bin.js"
    command_text="$(pid_command "$owner")"
    case "$command_text" in
      *"$entry"*) ;;
      *) return 1 ;;
    esac
  fi
  note "stopping the previous server (pid ${owner}) to mint a fresh launch token"
  kill "$owner" 2>/dev/null || true
  deadline=$(( $(date +%s) + 10 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! port_serving "$port"; then
      return 0
    fi
    sleep 0.25
  done
  kill -9 "$owner" 2>/dev/null || true
  sleep 1
  ! port_serving "$port"
}

start_dsh_server() {
  local node_exe="$1" bin="$2" port="$3" install_dir="$4" log log_err pid url
  log="${install_dir}/server-${port}.log"
  log_err="${install_dir}/server-${port}.err.log"
  step "Starting dsh web on port ${port}"
  nohup "$node_exe" "$bin" web --no-open --port "$port" >"$log" 2>"$log_err" &
  pid=$!
  note "server pid ${pid}; log ${log}"
  url="$(read_server_url "$log")" || return 1
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
  "$exe" --app="$url" --no-first-run --user-data-dir="$profile" >/dev/null 2>&1 &
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
update_from_repo() {
  local install_dir="$1" script_path="$2" name uri path remote installed_hash changed
  changed=0
  for target in \
    "dsh-window.sh|${REPO_RAW}/dsh-window.sh|${install_dir}/dsh-window.sh"; do
    name="${target%%|*}"
    uri="$(printf '%s' "$target" | cut -d'|' -f2)"
    path="$(printf '%s' "$target" | cut -d'|' -f3)"
    remote="$(mktemp)"
    if ! fetch_text "$uri" > "$remote" 2>/dev/null; then
      note 'sync skipped (the repository is unavailable); keeping the installed copy'
      rm -f "$remote"
      return 1
    fi
    if [ ! -s "$remote" ]; then
      note 'sync skipped (the repository returned an empty file); keeping the installed copy'
      rm -f "$remote"
      return 1
    fi
    installed_hash="$(sha256_of_file "$path" || true)"
    if [ "$(sha256_of_file "$remote")" = "$installed_hash" ]; then
      rm -f "$remote"
      continue
    fi
    case "$name" in
      *.sh)
        if ! bash -n "$remote" 2>/dev/null; then
          note "sync skipped (the repository ${name} does not parse); keeping the installed copy"
          rm -f "$remote"
          return 1
        fi
        ;;
    esac
    mkdir -p "$(dirname "$path")"
    mv "$remote" "$path"
    chmod +x "$path"
    note "updated ${name}"
    changed=1
  done
  if [ "$changed" = "0" ]; then
    note 'launcher is current'
    return 1
  fi
  [ "$script_path" = "${install_dir}/dsh-window.sh" ] && return 0
  return 1
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

invoke_uninstall() {
  local install_dir="$1" port="$2" target
  stop_managed_port_owner "$port" "$install_dir" || true
  for target in "${HOME}/Desktop/${SHORTCUT_NAME}.command" "${HOME}/Applications/${SHORTCUT_NAME}.command"; do
    [ -f "$target" ] && { rm -f "$target"; note "removed ${target}"; }
  done
  case "$install_dir" in
    "${HOME}"/*)
      [ -d "$install_dir" ] && { rm -rf "$install_dir"; note "removed ${install_dir}"; }
      ;;
    *)
      fail "refusing to remove ${install_dir} outside the home directory"
      ;;
  esac
  step "Uninstalled. Your Harness data under ~/.dsh was left in place."
}

main() {
  if [ "$UNINSTALL" = "1" ]; then
    invoke_uninstall "$APP_DIR" "$PORT"
    return 0
  fi

  local script_path
  script_path="${BASH_SOURCE[0]}"
  if [ "$NO_SYNC" = "0" ]; then
    if update_from_repo "$APP_DIR" "$script_path"; then
      step 'The launcher was updated from the repository; restarting'
      if [ "${#ORIGINAL_ARGS[@]}" -gt 0 ]; then
        exec bash "$script_path" "${ORIGINAL_ARGS[@]}"
      fi
      exec bash "$script_path"
    fi
  fi

  mkdir -p "$APP_DIR"

  local node_exe version node_bin
  node_exe="$(find_node_exe || true)"
  version=""
  [ -n "$node_exe" ] && version="$(node_version_supported "$node_exe" || true)"
  if [ -z "$version" ]; then
    node_exe="$(find_managed_node_exe "$APP_DIR" || true)"
    [ -n "$node_exe" ] && version="$(node_version_supported "$node_exe" || true)"
  fi
  if [ -z "$version" ]; then
    step 'Installing Node.js for this machine (once; about 40 MB)'
    node_exe="$(install_node_runtime "$APP_DIR" || true)"
    [ -n "$node_exe" ] && version="$(node_version_supported "$node_exe" || true)"
  fi
  if [ -z "$version" ]; then
    die 'No supported Node.js runtime is available and the automatic install failed. Install Node.js 22.19+ or 24+ from https://nodejs.org/ and run this script again.'
  fi
  note "node ${version} (${node_exe})"

  node_bin="$(get_dsh_bin "$APP_DIR")"
  if [ -z "$node_bin" ]; then
    invoke_dsh_install "$APP_DIR" "$node_exe"
    node_bin="$(get_dsh_bin "$APP_DIR")"
  fi
  [ -n "$node_bin" ] || die 'The dsh package did not install correctly.'

  install_shortcuts "$script_path"

  if [ -z "$URL" ]; then
    if port_serving "$PORT"; then
      step "Port ${PORT} already serves a harness instance; reusing it"
      URL="$(authenticated_server_url "$PORT" "$APP_DIR" || true)"
      if [ -z "$URL" ]; then
        stop_managed_port_owner "$PORT" "$APP_DIR" || die "Port ${PORT} is serving but its launch token could not be recovered. Close that process, choose another --port, or open its own dsh web URL."
      else
        note 'reused the launch token recorded on this machine'
      fi
    fi
    if [ -z "$URL" ]; then
      URL="$(start_dsh_server "$node_exe" "$node_bin" "$PORT" "$APP_DIR")" || die "the server did not report a URL; see ${APP_DIR}/server-${PORT}.log"
    fi
  fi

  step "Ready: ${URL}"

  if [ "$NO_WINDOW" = "1" ]; then
    return 0
  fi

  open_app_window "$(browser_exe "$BROWSER" || true)" "$URL" "${APP_DIR}/browser-profile"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

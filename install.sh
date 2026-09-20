#!/usr/bin/env bash
# Install the DeepSeek Harness application window for the current macOS user.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main/install.sh | bash
#   bash install.sh --port 8080 --browser edge
#   bash install.sh --no-start
#   bash install.sh --uninstall

set -eu

INSTALL_REPO_RAW='https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main'
INSTALL_APP_DIR="${HOME}/Library/Application Support/dsh-shortcut"
INSTALL_PORT=3080
INSTALL_BROWSER=chrome
INSTALL_NO_START=0
INSTALL_UNINSTALL=0
INSTALL_SILENT_NODE_INSTALL=0
INSTALL_EXTRA_ARGS=()
INSTALL_STAGE=''

install_usage() {
  cat <<'EOF'
Usage: bash install.sh [options]

  --app-dir DIR           Installation directory
  --port N                Web UI port (default: 3080)
  --browser NAME|PATH     chrome (default), edge, brave, or a Chromium executable
  --url URL              Open an existing instance
  --no-window            Start the server without opening a window
  --no-tray              Do not start the menu bar icon
  --silent-node-install  Use the default portable Node.js directory without a dialog
  --no-start             Install the launcher, icons, and shortcuts only
  --no-sync              Accepted; the initial launch always skips a second download
  --uninstall            Uninstall through the existing local launcher
  -h, --help             Show this help
EOF
}

install_fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
install_value() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || install_fail "$1 needs a value."
  case "$2" in --*) install_fail "$1 needs a value." ;; esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-dir) install_value "$@"; INSTALL_APP_DIR="$2"; shift 2 ;;
    --port) install_value "$@"; INSTALL_PORT="$2"; shift 2 ;;
    --browser) install_value "$@"; INSTALL_BROWSER="$2"; shift 2 ;;
    --url) install_value "$@"; INSTALL_EXTRA_ARGS+=("--url" "$2"); shift 2 ;;
    --no-window|--no-tray) INSTALL_EXTRA_ARGS+=("$1"); shift ;;
    --silent-node-install) INSTALL_SILENT_NODE_INSTALL=1; INSTALL_EXTRA_ARGS+=("$1"); shift ;;
    --no-start) INSTALL_NO_START=1; shift ;;
    --no-sync) shift ;;
    --uninstall) INSTALL_UNINSTALL=1; shift ;;
    -h|--help) install_usage; exit 0 ;;
    *) install_fail "Unknown option: $1" ;;
  esac
done

case "$INSTALL_PORT" in ''|*[!0-9]*) install_fail '--port must be an integer from 1 to 65535.' ;; esac
[ "${#INSTALL_PORT}" -le 5 ] || install_fail '--port must be an integer from 1 to 65535.'
INSTALL_PORT=$((10#$INSTALL_PORT))
[ "$INSTALL_PORT" -ge 1 ] && [ "$INSTALL_PORT" -le 65535 ] || install_fail '--port must be an integer from 1 to 65535.'
[ "$(uname -s)" = Darwin ] || install_fail 'This installer requires macOS. On Windows, use install.ps1.'
case "$INSTALL_APP_DIR$INSTALL_BROWSER" in *$'\n'*|*$'\r'*) install_fail 'Paths must not contain line breaks.' ;; esac
case "$INSTALL_APP_DIR" in /*) ;; *) INSTALL_APP_DIR="$PWD/$INSTALL_APP_DIR" ;; esac

# Uninstall never needs the network or creates an installation directory.
if [ "$INSTALL_UNINSTALL" = 1 ]; then
  if [ -f "${INSTALL_APP_DIR}/dsh-window.sh" ]; then
    exec /bin/bash "${INSTALL_APP_DIR}/dsh-window.sh" --app-dir "$INSTALL_APP_DIR" --port "$INSTALL_PORT" --uninstall
  fi
  printf 'Nothing to uninstall: launcher not found.\n'
  exit 0
fi

for install_tool in curl sips od tr mktemp; do
  command -v "$install_tool" >/dev/null 2>&1 || install_fail "Required macOS tool not found: ${install_tool}"
done

mkdir -p "$INSTALL_APP_DIR"
INSTALL_APP_DIR="$(cd "$INSTALL_APP_DIR" && pwd -P)"
INSTALL_USER_HOME="$(cd "$HOME" && pwd -P)"
INSTALL_DATA_DIR="$INSTALL_USER_HOME/.dsh"
if [ -d "$INSTALL_DATA_DIR" ]; then INSTALL_DATA_DIR="$(cd "$INSTALL_DATA_DIR" && pwd -P)"; fi
[ "$INSTALL_APP_DIR" != / ] && [ "$INSTALL_APP_DIR" != "$INSTALL_USER_HOME" ] && [ "$INSTALL_APP_DIR" != "$INSTALL_DATA_DIR" ] \
  || install_fail 'Choose a dedicated installation directory.'
INSTALL_STAGE="$(mktemp -d "${INSTALL_APP_DIR}/.install.XXXXXX")"
install_cleanup() {
  if [ -n "$INSTALL_STAGE" ] && [ -d "$INSTALL_STAGE" ]; then
    # Only remove the private staging directory returned by mktemp above.
    case "$INSTALL_STAGE" in "$INSTALL_APP_DIR"/.install.*) rm -rf "$INSTALL_STAGE" ;; esac
  fi
}
trap install_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '==> Installing the DeepSeek Harness launcher\n'
mkdir -p "${INSTALL_STAGE}/assets"
for install_file in dsh-window.sh assets/tray-template.png assets/tray-template@2x.png; do
  printf '    download %s\n' "$install_file"
  curl -fsSL --connect-timeout 15 --max-time 120 \
    -o "${INSTALL_STAGE}/${install_file}" "${INSTALL_REPO_RAW}/${install_file}" \
    || install_fail "Could not download ${install_file}; existing files were kept."
  [ -s "${INSTALL_STAGE}/${install_file}" ] || install_fail "Downloaded ${install_file} is empty; existing files were kept."
done

# Validate every download before replacing any existing launcher or icon.
/bin/bash -n "${INSTALL_STAGE}/dsh-window.sh" || install_fail 'The downloaded launcher has invalid Bash syntax; existing files were kept.'
for install_file in tray-template.png tray-template@2x.png; do
  install_png="${INSTALL_STAGE}/assets/${install_file}"
  install_signature="$(od -An -tx1 -N8 "$install_png" | tr -d ' \n\r')"
  [ "$install_signature" = 89504e470d0a1a0a ] || install_fail "Downloaded ${install_file} is not a PNG; existing files were kept."
  install_image_info="$(sips -g format -g pixelWidth -g pixelHeight "$install_png" 2>/dev/null)" \
    || install_fail "Downloaded ${install_file} cannot be read as an image; existing files were kept."
  printf '%s\n' "$install_image_info" | awk '
    $1 == "format:" && $2 == "png" { format = 1 }
    $1 == "pixelWidth:" && $2 ~ /^[0-9]+$/ && $2 > 0 { width = 1 }
    $1 == "pixelHeight:" && $2 ~ /^[0-9]+$/ && $2 > 0 { height = 1 }
    END { exit !(format && width && height) }
  ' || install_fail "Downloaded ${install_file} is not a valid PNG; existing files were kept."
done

mkdir -p "${INSTALL_APP_DIR}/assets"
chmod 755 "${INSTALL_STAGE}/dsh-window.sh"
chmod 644 "${INSTALL_STAGE}/assets/"*.png
mv -f "${INSTALL_STAGE}/assets/tray-template.png" "${INSTALL_APP_DIR}/assets/tray-template.png"
mv -f "${INSTALL_STAGE}/assets/tray-template@2x.png" "${INSTALL_APP_DIR}/assets/tray-template@2x.png"
mv -f "${INSTALL_STAGE}/dsh-window.sh" "${INSTALL_APP_DIR}/dsh-window.sh"
printf '%s\n' 'dsh-shortcut' > "${INSTALL_APP_DIR}/.dsh-shortcut"
install_cleanup
INSTALL_STAGE=''

if [ "$INSTALL_NO_START" = 1 ]; then
  # Sourcing with no arguments exposes shortcut creation without running main,
  # installing Node.js/npm packages, or starting the server or menu bar applet.
  (
    set --
    source "${INSTALL_APP_DIR}/dsh-window.sh"
    APP_DIR="$INSTALL_APP_DIR"
    PORT="$INSTALL_PORT"
    BROWSER="$INSTALL_BROWSER"
    SILENT_NODE_INSTALL="$INSTALL_SILENT_NODE_INSTALL"
    install_shortcuts "${INSTALL_APP_DIR}/dsh-window.sh"
  )
  printf '==> Installed. Open DeepSeek Harness from Desktop or ~/Applications to start.\n'
  exit 0
fi

printf '==> Launching\n'
INSTALL_LAUNCH_ARGS=(--app-dir "$INSTALL_APP_DIR" --port "$INSTALL_PORT" --browser "$INSTALL_BROWSER" --no-sync)
if [ "${#INSTALL_EXTRA_ARGS[@]}" -gt 0 ]; then
  INSTALL_LAUNCH_ARGS+=("${INSTALL_EXTRA_ARGS[@]}")
fi
exec /bin/bash "${INSTALL_APP_DIR}/dsh-window.sh" "${INSTALL_LAUNCH_ARGS[@]}"

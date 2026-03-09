#!/bin/sh
# ─────────────────────────────────────────────────────────────────
# Ohm — Universal Installer
# Supports: macOS · Linux · Termux (Android) · sh · bash · zsh
# Source:   https://apoorvak-dev.github.io/ohm-website/installer-ohmCLI.sh
# Usage:    curl -fsSL https://apoorvak-dev.github.io/ohm-website/installer-ohmCLI.sh | sh
# ─────────────────────────────────────────────────────────────────
set -e

# ── Colours (safe for sh) ─────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m' GREEN='\033[0;32m' AMBER='\033[0;33m'
  BLUE='\033[0;34m' BOLD='\033[1m' RESET='\033[0m'
else
  RED='' GREEN='' AMBER='' BLUE='' BOLD='' RESET=''
fi

log()  { printf "${BLUE}▸${RESET} %s\n" "$1"; }
ok()   { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn() { printf "${AMBER}⚠${RESET} %s\n" "$1"; }
die()  { printf "${RED}✗ Error:${RESET} %s\n" "$1" >&2; exit 1; }

# ── Banner ────────────────────────────────────────────────────────
printf "\n${BOLD}  Ω  Ohm Installer${RESET}\n\n"

# ── Detect platform ───────────────────────────────────────────────
detect_platform() {
  # OS detection
  OS=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]') || die "Cannot detect OS"

  # Architecture detection
  ARCH=$(uname -m 2>/dev/null) || die "Cannot detect architecture"
  case "$ARCH" in
    x86_64|amd64)          ARCH="x64" ;;
    aarch64|arm64|armv8*)  ARCH="arm64" ;;
    armv7*|armv6*)         die "32-bit ARM not supported. Use a 64-bit Termux build." ;;
    *)                     die "Unsupported architecture: $ARCH" ;;
  esac

  # Termux detection (Android)
  if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ]; then
    PLATFORM="linux-${ARCH}"
    IS_TERMUX=1
    INSTALL_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
    DATA_DIR="${HOME}/.ohm"
    SERVICE_TYPE="termux"
    return
  fi

  IS_TERMUX=0

  case "$OS" in
    darwin)
      PLATFORM="darwin-${ARCH}"
      INSTALL_DIR="/usr/local/bin"
      DATA_DIR="${HOME}/.ohm"
      SERVICE_TYPE="launchd"
      # Use ~/.local/bin if /usr/local/bin not writable without sudo
      if [ ! -w "/usr/local/bin" ] 2>/dev/null; then
        INSTALL_DIR="${HOME}/.local/bin"
        mkdir -p "$INSTALL_DIR"
        # Ensure it's in PATH
        _ensure_path "$INSTALL_DIR"
      fi
      ;;
    linux)
      PLATFORM="linux-${ARCH}"
      INSTALL_DIR="${HOME}/.local/bin"
      DATA_DIR="${HOME}/.ohm"
      SERVICE_TYPE="systemd"
      mkdir -p "$INSTALL_DIR"
      _ensure_path "$INSTALL_DIR"
      ;;
    *)
      die "Unsupported OS: $OS. For Windows use install.ps1."
      ;;
  esac
}

_ensure_path() {
  _DIR="$1"
  case ":${PATH}:" in
    *":${_DIR}:"*) ;; # already in PATH
    *)
      # Append to shell rc files
      for RC in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        if [ -f "$RC" ]; then
          printf '\nexport PATH="%s:$PATH"\n' "$_DIR" >> "$RC"
        fi
      done
      export PATH="${_DIR}:${PATH}"
      warn "$_DIR added to PATH (restart shell or run: export PATH=\"${_DIR}:\$PATH\")"
      ;;
  esac
}

# ── Check dependencies ────────────────────────────────────────────
check_deps() {
  for DEP in curl; do
    command -v "$DEP" >/dev/null 2>&1 || die "$DEP is required but not installed."
  done

  # On Termux, offer to install missing tools
  if [ "${IS_TERMUX:-0}" = "1" ]; then
    for DEP in tar gzip; do
      command -v "$DEP" >/dev/null 2>&1 || {
        log "Installing $DEP via pkg..."
        pkg install -y -q "$DEP" 2>/dev/null || warn "Could not install $DEP"
      }
    done
  fi
}

# ── Download daemon binary ────────────────────────────────────────
download_daemon() {
  # Binaries are hosted publicly on ohm-website (not the private ohm repo)
  BASE_URL="https://apoorvak-dev.github.io/ohm-website/releases"
  BINARY_NAME="ohm-daemon-${PLATFORM}"
  DOWNLOAD_URL="${BASE_URL}/${BINARY_NAME}"
  TMP_FILE="${TMPDIR:-/tmp}/ohm-daemon-download-$$"

  log "Downloading ohm-daemon (${PLATFORM})..."
  log "URL: ${DOWNLOAD_URL}"

  # Check if release exists before downloading
  HTTP_CODE=$(curl -o /dev/null -sI -w "%{http_code}" "$DOWNLOAD_URL" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "404" ] || [ "$HTTP_CODE" = "000" ]; then
    printf "\n"
    printf "  ${AMBER}Ohm daemon binaries are not released yet.${RESET}\n"
    printf "  The daemon is currently in development (Sprint 1).\n"
    printf "  Star the repo to get notified when binaries are available:\n"
    printf "  https://github.com/ApoorvaK-dev/ohm\n\n"
    printf "  If you already have a binary, place it at:\n"
    printf "  ${INSTALL_DIR}/ohm-daemon\n\n"
    exit 0
  fi

  curl -fsSL "$DOWNLOAD_URL" -o "$TMP_FILE" || \
    die "Download failed (HTTP ${HTTP_CODE}). Try again or visit https://github.com/ApoorvaK-dev/ohm"

  # Verify download is not empty
  if [ ! -s "$TMP_FILE" ]; then
    rm -f "$TMP_FILE"
    die "Downloaded file is empty for ${PLATFORM}."
  fi

  # Install
  mkdir -p "$INSTALL_DIR"
  mv "$TMP_FILE" "${INSTALL_DIR}/ohm-daemon"
  chmod +x "${INSTALL_DIR}/ohm-daemon"

  ok "ohm-daemon installed → ${INSTALL_DIR}/ohm-daemon"
}

# ── Create data directory + base config ──────────────────────────
init_data_dir() {
  mkdir -p "${DATA_DIR}/bin"
  mkdir -p "${DATA_DIR}/logs"
  mkdir -p "${DATA_DIR}/users"

  # Write base config if not exists
  if [ ! -f "${DATA_DIR}/config.json" ]; then
    cat > "${DATA_DIR}/config.json" << CONFIGEOF
{
  "version": "0.1.0",
  "port": 47832,
  "data_dir": "${DATA_DIR}",
  "log_level": "info",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CONFIGEOF
  fi

  ok "Data directory: ${DATA_DIR}"
}

# ── Register system service ───────────────────────────────────────
register_service() {
  case "$SERVICE_TYPE" in

    termux)
      # termux-boot: runs on Android boot
      mkdir -p "${HOME}/.termux/boot"
      cat > "${HOME}/.termux/boot/ohm-daemon.sh" << BOOTEOF
#!/data/data/com.termux/files/usr/bin/sh
# Ohm daemon — started on boot by termux-boot
${INSTALL_DIR}/ohm-daemon start >> ${DATA_DIR}/logs/daemon.log 2>&1
BOOTEOF
      chmod +x "${HOME}/.termux/boot/ohm-daemon.sh"

      # Start immediately
      "${INSTALL_DIR}/ohm-daemon" start >> "${DATA_DIR}/logs/daemon.log" 2>&1 &
      ok "Service registered (termux-boot)"
      warn "Install Termux:Boot from F-Droid for auto-start on Android reboot"
      ;;

    launchd)
      # macOS launchd
      PLIST_DIR="${HOME}/Library/LaunchAgents"
      PLIST_FILE="${PLIST_DIR}/sh.ohm.daemon.plist"
      mkdir -p "$PLIST_DIR"
      cat > "$PLIST_FILE" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>sh.ohm.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_DIR}/ohm-daemon</string>
    <string>start</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${DATA_DIR}/logs/daemon.log</string>
  <key>StandardErrorPath</key>
  <string>${DATA_DIR}/logs/daemon-error.log</string>
</dict>
</plist>
PLISTEOF
      launchctl unload "$PLIST_FILE" 2>/dev/null || true
      launchctl load "$PLIST_FILE"
      ok "Service registered (launchd) — auto-starts on login"
      ;;

    systemd)
      # Linux systemd (user unit — no root required)
      UNIT_DIR="${HOME}/.config/systemd/user"
      mkdir -p "$UNIT_DIR"
      cat > "${UNIT_DIR}/ohm.service" << UNITEOF
[Unit]
Description=Ohm Daemon
Documentation=https://apoorvak-dev.github.io/ohm-website
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/ohm-daemon start
Restart=always
RestartSec=5
StandardOutput=append:${DATA_DIR}/logs/daemon.log
StandardError=append:${DATA_DIR}/logs/daemon-error.log

[Install]
WantedBy=default.target
UNITEOF
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload
        systemctl --user enable ohm
        systemctl --user start ohm
        ok "Service registered (systemd user unit) — auto-starts on login"
      else
        warn "systemd not available — starting daemon directly"
        "${INSTALL_DIR}/ohm-daemon" start >> "${DATA_DIR}/logs/daemon.log" 2>&1 &
      fi
      ;;
  esac
}

# ── Print next steps ──────────────────────────────────────────────
print_next_steps() {
  printf "\n${GREEN}${BOLD}  ✓  Ohm daemon installed successfully!${RESET}\n\n"
  printf "  Open the Ohm app on your device and enter your pairing code.\n"
  printf "  The daemon will show a 6-digit code on first start.\n\n"
  printf "  Daemon logs:  ${DATA_DIR}/logs/daemon.log\n"
  printf "  Data dir:     ${DATA_DIR}/\n\n"
  if [ "${IS_TERMUX:-0}" = "1" ]; then
    printf "  Termux tip: Install ${BOLD}Termux:Boot${RESET} from F-Droid\n"
    printf "  to auto-start the daemon when your phone boots.\n\n"
  fi
}

# ── Main ──────────────────────────────────────────────────────────
main() {
  detect_platform
  log "Platform: ${PLATFORM} | Service: ${SERVICE_TYPE}"

  check_deps
  download_daemon
  init_data_dir
  register_service
  print_next_steps
}

main

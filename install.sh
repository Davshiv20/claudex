#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${CLAUDEX_INSTALL_DIR:-$HOME/.claudex}"
BIN_DIR="$INSTALL_DIR/bin"
CONFIG_DIR="${CLIPROXY_CONFIG_DIR:-$HOME/.cli-proxy-api}"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
API_KEY_FILE="$INSTALL_DIR/api-key"
SHELL_RC=""

log() { printf '\033[1;34m[claudex]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[claudex]\033[0m %s\n' "$*"; }

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$CONFIG_DIR/logs"

install_cliproxyapi() {
  if command -v cliproxyapi >/dev/null 2>&1 || command -v cli-proxy-api >/dev/null 2>&1; then
    log "CLIProxyAPI already installed"
    return
  fi

  if command -v brew >/dev/null 2>&1; then
    log "Installing CLIProxyAPI with Homebrew"
    brew tap router-for-me/tap >/dev/null 2>&1 || true
    if brew install cliproxyapi; then
      return
    fi
    warn "Homebrew install failed; falling back to GitHub release binary"
  fi

  local os arch asset tmp version bin_name
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os:$arch" in
    darwin:arm64) asset="cli-proxy-api_darwin_arm64.tar.gz" ;;
    darwin:x86_64) asset="cli-proxy-api_darwin_amd64.tar.gz" ;;
    linux:aarch64|linux:arm64) asset="cli-proxy-api_linux_arm64.tar.gz" ;;
    linux:x86_64) asset="cli-proxy-api_linux_amd64.tar.gz" ;;
    *) echo "Unsupported platform: $os/$arch" >&2; exit 1 ;;
  esac
  tmp="$(mktemp -d)"
  version="$(curl -fsSL https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
  curl -fL "https://github.com/router-for-me/CLIProxyAPI/releases/download/${version}/${asset}" -o "$tmp/$asset"
  tar -xzf "$tmp/$asset" -C "$tmp"
  bin_name="$(find "$tmp" -type f \( -name 'cli-proxy-api' -o -name 'cliproxyapi' \) | head -1)"
  install -m 0755 "$bin_name" "$BIN_DIR/cli-proxy-api"
}

make_api_key() {
  if [[ ! -f "$API_KEY_FILE" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      printf 'sk-claudex-%s\n' "$(openssl rand -hex 24)" > "$API_KEY_FILE"
    else
      printf 'sk-claudex-%s\n' "$(date +%s)-$RANDOM-$RANDOM" > "$API_KEY_FILE"
    fi
    chmod 600 "$API_KEY_FILE"
  fi
}

write_config() {
  local api_key
  api_key="$(cat "$API_KEY_FILE")"
  if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.backup.$(date +%Y%m%d%H%M%S)"
    warn "Backed up existing config.yaml"
  fi
  sed "s#__CLAUDEX_API_KEY__#${api_key}#g; s#__HOME__#${HOME}#g" \
    "$ROOT_DIR/templates/config.yaml" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  log "Wrote $CONFIG_FILE"
}

install_wrappers() {
  for f in claudex claudex-auth claudex-proxy; do
    sed "s#__CLAUDEX_INSTALL_DIR__#${INSTALL_DIR}#g; s#__CLIPROXY_CONFIG_FILE__#${CONFIG_FILE}#g" \
      "$ROOT_DIR/bin/$f" > "$BIN_DIR/$f"
    chmod +x "$BIN_DIR/$f"
  done
}

update_shell() {
  case "${SHELL:-}" in
    */zsh) SHELL_RC="$HOME/.zshrc" ;;
    */bash) SHELL_RC="$HOME/.bashrc" ;;
    *) SHELL_RC="$HOME/.profile" ;;
  esac
  touch "$SHELL_RC"
  if ! grep -q 'CLAUDEX PATH' "$SHELL_RC"; then
    cat >> "$SHELL_RC" <<EOFRC

# CLAUDEX PATH
export PATH="${BIN_DIR}:\$PATH"
EOFRC
    log "Added $BIN_DIR to $SHELL_RC"
  fi
  if ! grep -q 'CLAUDEX ALIAS' "$SHELL_RC"; then
    cat >> "$SHELL_RC" <<EOFRC
# CLAUDEX ALIAS
alias claudex="${BIN_DIR}/claudex"
EOFRC
    log "Added claudex alias to $SHELL_RC"
  fi
}

install_cliproxyapi
make_api_key
write_config
install_wrappers
update_shell

log "Done. Open a new shell or run: export PATH=\"$BIN_DIR:\$PATH\""
log "Next: claudex-auth codex && claudex-proxy start && claudex"

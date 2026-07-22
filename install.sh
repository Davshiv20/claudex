#!/usr/bin/env bash
set -euo pipefail

# Secrets and config must never be world-readable, even briefly. Setting a
# strict umask up front means every file/dir we create starts private (0600/0700).
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${CLAUDEX_INSTALL_DIR:-$HOME/.claudex}"
BIN_DIR="$INSTALL_DIR/bin"
CONFIG_DIR="${CLIPROXY_CONFIG_DIR:-$HOME/.cli-proxy-api}"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
API_KEY_FILE="$INSTALL_DIR/api-key"
MODELS_CONF="$INSTALL_DIR/models.conf"
SHELL_RC=""

# Pinned by default for reproducible, reviewable installs. Override with:
#   CLAUDEX_CLIPROXY_VERSION=vX.Y.Z ./install.sh
#
# VOUCHED_CLIPROXY_VERSION is the version this repo has reviewed and vouches for.
# It installs with no age check. Any *other* version (including "latest") must be
# at least MIN_RELEASE_AGE_DAYS old, so brand-new (possibly bad/unsafe) releases
# are given time to be caught before we install them.
VOUCHED_CLIPROXY_VERSION="v7.2.93"
MIN_RELEASE_AGE_DAYS="${CLAUDEX_MIN_RELEASE_AGE_DAYS:-7}"
CLIPROXY_VERSION=""   # resolved in install_cliproxyapi
RESET_CONFIG=0

log() { printf '\033[1;34m[claudex]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[claudex]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[claudex]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

Options:
  --reset        Overwrite an existing CLIProxyAPI config.yaml (a backup is kept).
                 By default an existing config is preserved.
  -h, --help     Show this help.

Environment:
  CLAUDEX_CLIPROXY_VERSION=vX.Y.Z   Install a specific CLIProxyAPI version.
  CLAUDEX_CLIPROXY_VERSION=latest   Newest release that is >= the minimum age.
  CLAUDEX_MIN_RELEASE_AGE_DAYS=N    Refuse releases younger than N days (default: 7).
                                    Set 0 to disable the age gate.
  CLAUDEX_SKIP_RELEASE_AGE_CHECK=1  Bypass the age gate (which otherwise fails closed).
  CLAUDEX_USE_SYSTEM_CLIPROXY=1     Use an existing system/Homebrew CLIProxyAPI
                                    (NOT version-pinned or checksum-verified).
  CLAUDEX_SKIP_CHECKSUM=1           Skip SHA256 verification (NOT recommended).
  CLAUDEX_INSTALL_DIR=DIR           Where claudex lives (default: ~/.claudex).
  CLIPROXY_CONFIG_DIR=DIR           CLIProxyAPI config/auth dir (default: ~/.cli-proxy-api).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset|--overwrite) RESET_CONFIG=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$CONFIG_DIR/logs"

CURL=(curl --connect-timeout 10 --max-time 120 -fsSL)
RELEASES_API="https://api.github.com/repos/router-for-me/CLIProxyAPI/releases"

# SHA256 of the VOUCHED release's assets, embedded in this repo so the pinned
# version is verified against a value we control — NOT one fetched from the same
# (possibly mutated) release. If you bump VOUCHED_CLIPROXY_VERSION, update these
# too or the install will fail closed on a mismatch.
embedded_sha256() {
  case "$1" in
    darwin_aarch64) echo "3ebffcf346c79925ff393225c2769a509a2297dcc1b8154c49235cb1d80a69ac" ;;
    darwin_amd64)   echo "1fa5b1324c43fada01234559f382ba0878681292f6d653056aef9ff99ccc7b86" ;;
    linux_aarch64)  echo "fc9d27799c97950614e98f191c3a6fea5c1b61bd390c44d2977090678b1c5794" ;;
    linux_amd64)    echo "3ca18073c87a7d21391dcc437558c37ee9b98ce1eb1cd2c013e064a236664322" ;;
    *) echo "" ;;
  esac
}

# Age (in whole days) of a release tag, printed to stdout. Non-zero on failure.
release_age_days() {
  local tag="$1" json
  json="$("${CURL[@]}" "$RELEASES_API/tags/$tag" 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys,datetime
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
p = d.get("published_at")
if not p:
    sys.exit(1)
t = datetime.datetime.strptime(p, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
print(int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() // 86400))
'
}

# Newest non-draft, non-prerelease tag that is at least MIN_RELEASE_AGE_DAYS old.
resolve_latest_aged() {
  local json
  json="$("${CURL[@]}" "$RELEASES_API?per_page=30" 2>/dev/null)" || return 1
  printf '%s' "$json" | MIN="$MIN_RELEASE_AGE_DAYS" python3 -c '
import json,sys,os,datetime
min_age = int(os.environ["MIN"])
now = datetime.datetime.now(datetime.timezone.utc)
try:
    rels = json.load(sys.stdin)
except Exception:
    sys.exit(1)
cands = []
for r in rels:
    if r.get("draft") or r.get("prerelease"):
        continue
    p, tag = r.get("published_at"), r.get("tag_name")
    if not p or not tag:
        continue
    t = datetime.datetime.strptime(p, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    if (now - t).total_seconds() // 86400 >= min_age:
        cands.append((t, tag))
cands.sort(reverse=True)
if not cands:
    sys.exit(1)
print(cands[0][1])
'
}

# Decide which version to install, applying the minimum-age safety policy.
resolve_version() {
  local requested="${CLAUDEX_CLIPROXY_VERSION:-}"

  if [[ -z "$requested" ]]; then
    CLIPROXY_VERSION="$VOUCHED_CLIPROXY_VERSION"
    log "Using pinned CLIProxyAPI $CLIPROXY_VERSION"
    return
  fi

  if [[ "$requested" == "latest" ]]; then
    log "Resolving newest CLIProxyAPI release at least ${MIN_RELEASE_AGE_DAYS} day(s) old"
    local tag
    tag="$(resolve_latest_aged)" || die "Could not find a CLIProxyAPI release >= ${MIN_RELEASE_AGE_DAYS} days old. Pin one with CLAUDEX_CLIPROXY_VERSION=vX.Y.Z."
    CLIPROXY_VERSION="$tag"
    log "Selected $CLIPROXY_VERSION"
    return
  fi

  CLIPROXY_VERSION="$requested"
  if [[ "$MIN_RELEASE_AGE_DAYS" -gt 0 && "$CLIPROXY_VERSION" != "$VOUCHED_CLIPROXY_VERSION" ]]; then
    if [[ "${CLAUDEX_SKIP_RELEASE_AGE_CHECK:-0}" == "1" ]]; then
      warn "Skipping release-age check (CLAUDEX_SKIP_RELEASE_AGE_CHECK=1)"
      return
    fi
    # Fail closed: if we cannot prove the release is old enough, do not install it.
    local age
    age="$(release_age_days "$CLIPROXY_VERSION")" \
      || die "Could not verify release age for $CLIPROXY_VERSION (network down or unknown tag). The age policy fails closed. Override with CLAUDEX_SKIP_RELEASE_AGE_CHECK=1 if you're sure."
    if (( age < MIN_RELEASE_AGE_DAYS )); then
      die "CLIProxyAPI $CLIPROXY_VERSION is only ${age} day(s) old (minimum ${MIN_RELEASE_AGE_DAYS}). Fresh releases are held back for safety. Override with CLAUDEX_MIN_RELEASE_AGE_DAYS=0 or CLAUDEX_SKIP_RELEASE_AGE_CHECK=1 if you're sure."
    fi
    log "$CLIPROXY_VERSION is ${age} day(s) old (>= ${MIN_RELEASE_AGE_DAYS}) — OK"
  fi
}

install_cliproxyapi() {
  # Prefer the binary we downloaded and checksum-verified ourselves.
  if [[ "${CLAUDEX_FORCE_CLIPROXY:-0}" != "1" && -x "$BIN_DIR/cli-proxy-api" ]]; then
    log "Using verified CLIProxyAPI at $BIN_DIR/cli-proxy-api"
    return
  fi

  # Opt in to an existing system/Homebrew binary. This is NOT version-pinned or
  # checksum-verified, so it is off by default.
  if [[ "${CLAUDEX_USE_SYSTEM_CLIPROXY:-0}" == "1" ]]; then
    if command -v cliproxyapi >/dev/null 2>&1 || command -v cli-proxy-api >/dev/null 2>&1; then
      warn "Using existing system CLIProxyAPI (CLAUDEX_USE_SYSTEM_CLIPROXY=1) — not version-pinned or checksum-verified"
      return
    fi
    if command -v brew >/dev/null 2>&1; then
      warn "Installing CLIProxyAPI via Homebrew (CLAUDEX_USE_SYSTEM_CLIPROXY=1) — not version-pinned or checksum-verified"
      brew tap router-for-me/tap >/dev/null 2>&1 || true
      if brew install cliproxyapi; then
        return
      fi
      warn "Homebrew install failed; falling back to the verified pinned binary"
    else
      warn "No system CLIProxyAPI found; falling back to the verified pinned binary"
    fi
  fi

  resolve_version

  local os arch plat version_num asset tmp bin_name
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os:$arch" in
    darwin:arm64)           plat="darwin_aarch64" ;;
    darwin:x86_64)          plat="darwin_amd64" ;;
    linux:aarch64|linux:arm64) plat="linux_aarch64" ;;
    linux:x86_64)           plat="linux_amd64" ;;
    *) die "Unsupported platform: $os/$arch. Install CLIProxyAPI manually and re-run." ;;
  esac

  version_num="${CLIPROXY_VERSION#v}"
  asset="CLIProxyAPI_${version_num}_${plat}.tar.gz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local base="https://github.com/router-for-me/CLIProxyAPI/releases/download/${CLIPROXY_VERSION}"
  log "Downloading CLIProxyAPI ${CLIPROXY_VERSION} ($plat)"
  "${CURL[@]}" "$base/$asset" -o "$tmp/$asset" \
    || die "Download failed for $asset. Check CLAUDEX_CLIPROXY_VERSION or your network."

  if [[ "${CLAUDEX_SKIP_CHECKSUM:-0}" == "1" ]]; then
    warn "Skipping checksum verification (CLAUDEX_SKIP_CHECKSUM=1)"
  else
    log "Verifying SHA256 checksum"
    local expected=""
    if [[ "$CLIPROXY_VERSION" == "$VOUCHED_CLIPROXY_VERSION" ]]; then
      expected="$(embedded_sha256 "$plat")"
      [[ -n "$expected" ]] && log "Using SHA256 embedded in this repo"
    fi
    if [[ -z "$expected" ]]; then
      # Non-vouched version: best-effort against the release's own checksums.txt.
      # This guards against corrupted downloads, not a mutated/compromised release.
      if ! "${CURL[@]}" "$base/checksums.txt" -o "$tmp/checksums.txt"; then
        die "Could not fetch checksums.txt for ${CLIPROXY_VERSION}. Re-run with CLAUDEX_SKIP_CHECKSUM=1 to bypass (not recommended)."
      fi
      expected="$(grep " ${asset}\$" "$tmp/checksums.txt" | awk '{print $1}' | head -1)"
      [[ -n "$expected" ]] || die "No checksum entry for $asset in checksums.txt."
      warn "Verifying against checksums.txt from the same release (best-effort; not an independent signature)"
    fi
    local actual
    if command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
    else
      die "Neither shasum nor sha256sum available to verify the download."
    fi
    [[ "$actual" == "$expected" ]] || die "Checksum mismatch for $asset (expected $expected, got $actual). Aborting."
    log "Checksum OK"
  fi

  tar -xzf "$tmp/$asset" -C "$tmp"
  bin_name="$(find "$tmp" -type f \( -iname 'cli-proxy-api' -o -iname 'cliproxyapi' \) | head -1)"
  if [[ -z "$bin_name" ]]; then
    # Fall back to the largest extracted file (the binary dwarfs any config/docs).
    bin_name="$(find "$tmp" -type f ! -name '*.tar.gz' -exec ls -S {} + 2>/dev/null | head -1)"
  fi
  [[ -n "$bin_name" ]] || die "Could not locate the CLIProxyAPI binary inside $asset."
  install -m 0755 "$bin_name" "$BIN_DIR/cli-proxy-api"
  log "Installed CLIProxyAPI to $BIN_DIR/cli-proxy-api"
}

make_api_key() {
  if [[ -f "$API_KEY_FILE" ]]; then
    return
  fi
  local tmp key
  tmp="$(mktemp "$INSTALL_DIR/.api-key.XXXXXX")"
  if command -v openssl >/dev/null 2>&1; then
    key="sk-claudex-$(openssl rand -hex 24)"
  else
    key="sk-claudex-$(date +%s)-${RANDOM}-${RANDOM}"
  fi
  printf '%s\n' "$key" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$API_KEY_FILE"
}

write_config() {
  local api_key tmp
  api_key="$(cat "$API_KEY_FILE")"

  if [[ -f "$CONFIG_FILE" && "$RESET_CONFIG" -ne 1 ]]; then
    log "Preserving existing $CONFIG_FILE (use --reset to overwrite)"
    return
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.backup.$(date +%Y%m%d%H%M%S)"
    warn "Backed up existing config.yaml"
  fi

  tmp="$(mktemp "$CONFIG_DIR/.config.XXXXXX")"
  sed "s#__CLAUDEX_API_KEY__#${api_key}#g; s#__CLIPROXY_CONFIG_DIR__#${CONFIG_DIR}#g" \
    "$ROOT_DIR/templates/config.yaml" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  log "Wrote $CONFIG_FILE"
}

install_models_conf() {
  if [[ -f "$MODELS_CONF" ]]; then
    log "Keeping existing models.conf (edit it or run: claudex-models set)"
    return
  fi
  cp "$ROOT_DIR/templates/models.conf" "$MODELS_CONF"
  log "Wrote $MODELS_CONF"
}

install_wrappers() {
  local f
  for f in claudex claudex-auth claudex-proxy claudex-models claudex-doctor claudex-uninstall claudex-update; do
    sed "s#__CLAUDEX_INSTALL_DIR__#${INSTALL_DIR}#g; \
         s#__CLIPROXY_CONFIG_FILE__#${CONFIG_FILE}#g; \
         s#__CLIPROXY_CONFIG_DIR__#${CONFIG_DIR}#g; \
         s#__CLAUDEX_REPO_DIR__#${ROOT_DIR}#g" \
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
install_models_conf
install_wrappers
update_shell

log "Done. Open a new shell or run: export PATH=\"$BIN_DIR:\$PATH\""
log "Next: claudex-auth codex && claudex-proxy start && claudex"
log "Pick your models interactively: claudex-models set"
log "Check your setup any time:       claudex-doctor"

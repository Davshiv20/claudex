#!/usr/bin/env bash
#
# claudex bootstrap — one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Davshiv20/claudex/main/bootstrap.sh | bash
#
# This clones the (inspectable) claudex repo, then runs its install.sh, which
# downloads a pinned, checksum-verified CLIProxyAPI binary. Prefer the manual
# clone path in the README if you'd rather read the code before running it.
set -euo pipefail

REPO="${CLAUDEX_REPO:-https://github.com/Davshiv20/claudex.git}"
REF="${CLAUDEX_REF:-main}"
SRC="${CLAUDEX_SRC_DIR:-$HOME/.claudex/src}"
BIN_DIR="${CLAUDEX_INSTALL_DIR:-$HOME/.claudex}/bin"

say()  { printf '\033[1;34m[claudex]\033[0m %s\n' "$*"; }
step() { printf '\033[1;34m[%s/4]\033[0m %s\n' "$1" "$2"; }
die()  { printf '\033[1;31m[claudex]\033[0m %s\n' "$*" >&2; exit 1; }

step 1 "Checking dependencies"
for dep in git curl python3; do
  command -v "$dep" >/dev/null 2>&1 || die "Missing dependency: $dep. Install it and re-run."
done

step 2 "Fetching claudex ($REF)"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --depth 1 origin "$REF" >/dev/null 2>&1 || die "git fetch failed for $REF"
  git -C "$SRC" checkout -q FETCH_HEAD || die "git checkout failed"
else
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --branch "$REF" "$REPO" "$SRC" >/dev/null 2>&1 \
    || git clone --depth 1 "$REPO" "$SRC" >/dev/null 2>&1 \
    || die "git clone failed for $REPO"
fi

step 3 "Installing verified proxy + commands"
# Pass through any args (e.g. --reset) to install.sh.
"$SRC/install.sh" "$@"

step 4 "Starting guided setup"
# If we have a terminal, jump straight into the guided setup for a smooth finish.
if [ "${CLAUDEX_NO_SETUP:-0}" != "1" ] && [ -r /dev/tty ] && [ -x "$BIN_DIR/claudex-setup" ]; then
  exec "$BIN_DIR/claudex-setup"
else
  say "Open a new shell, then run: claudex-setup"
fi

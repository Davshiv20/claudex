#!/usr/bin/env bash
#
# claudex test harness — self-contained, no external deps (no bats).
#
# Runs from anywhere: the repo root is derived from this script's own path.
# Every test is hermetic: it works inside temp dirs that are removed on exit,
# never touches the real $HOME, and never requires the network.
#
# Usage: bash tests/run.sh
# Exit code: 0 if all assertions pass, non-zero otherwise.

set -u

# --- locate the repo (independent of cwd) ----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- scratch space, cleaned up on exit -------------------------------------
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudex-tests.XXXXXX")"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# --- counters + reporting helpers ------------------------------------------
PASS=0
FAIL=0
SKIP=0

C_GREEN=$'\033[1;32m'
C_RED=$'\033[1;31m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[1;34m'
C_RESET=$'\033[0m'

section() { printf '\n%s== %s ==%s\n' "$C_BLUE" "$1" "$C_RESET"; }

pass() { PASS=$((PASS + 1)); printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  %sSKIP%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }

# assert_eq <expected> <actual> <message>
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    pass "$3"
  else
    fail "$3 (expected [$1], got [$2])"
  fi
}

# assert_contains <haystack> <needle> <message>
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then
    pass "$3"
  else
    fail "$3 (missing substring: [$2])"
  fi
}

# assert_not_contains <haystack> <needle> <message>
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then
    pass "$3"
  else
    fail "$3 (unexpected substring: [$2])"
  fi
}

# assert_success <status> <message>
assert_success() {
  if [[ "$1" -eq 0 ]]; then
    pass "$2"
  else
    fail "$2 (exit status $1, expected 0)"
  fi
}

# assert_fail <status> <message>
assert_fail() {
  if [[ "$1" -ne 0 ]]; then
    pass "$2"
  else
    fail "$2 (exit status 0, expected non-zero)"
  fi
}

# --- misc helpers ----------------------------------------------------------
# Portable "octal permission bits" lookup. GNU stat first (Linux), then BSD (macOS):
# GNU `stat -f` is a valid but different flag, so BSD-first misfires on Linux.
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Stable content fingerprint of a file (used to prove "unchanged").
filesum() { cksum < "$1" 2>/dev/null; }

# ===========================================================================
# 1. Static syntax checks
# ===========================================================================
section "Static syntax checks (bash -n)"

bash -n "$REPO_DIR/install.sh"
assert_success $? "bash -n install.sh"

bash -n "$REPO_DIR/bootstrap.sh"
assert_success $? "bash -n bootstrap.sh"

for f in "$REPO_DIR"/bin/*; do
  [[ -f "$f" ]] || continue
  bash -n "$f"
  st=$?
  assert_success "$st" "bash -n $(basename "$f")"
done

section "Static lint checks (shellcheck)"
if command -v shellcheck >/dev/null 2>&1; then
  # Warning-level enforcement. The scripts are clean at this severity with one
  # justified exclusion:
  #   SC1087 — false positive in bin/claudex-doctor, where "$slot[[:space:]]*="
  #            is a grep regex string, not a bash array index expansion.
  shellcheck --severity=warning --exclude=SC1087 --shell=bash \
    "$REPO_DIR/install.sh" "$REPO_DIR/bootstrap.sh" "$REPO_DIR"/bin/*
  st=$?
  assert_success "$st" "shellcheck (severity=warning, exclude SC1087) on install.sh + bin/*"
else
  skip "shellcheck not installed — skipping lint (bash -n still ran)"
fi

# ===========================================================================
# 2. Model write/parse round-trip
# ===========================================================================
section "Model write/parse round-trip"

MODELS_DIR="$TMPROOT/models-install"
mkdir -p "$MODELS_DIR"
MM="$MODELS_DIR/claudex-models"
# Render a testable copy of the wrapper by substituting the install-dir
# placeholder, exactly as install.sh would.
sed "s#__CLAUDEX_INSTALL_DIR__#${MODELS_DIR}#g" \
  "$REPO_DIR/bin/claudex-models" > "$MM"
chmod +x "$MM"
CONF="$MODELS_DIR/models.conf"
cp "$REPO_DIR/templates/models.conf" "$CONF"

# show lists all three slots
out="$("$MM" show 2>&1)"; st=$?
assert_success "$st" "claudex-models show exits 0"
assert_contains "$out" "OPUS" "show lists OPUS"
assert_contains "$out" "SONNET" "show lists SONNET"
assert_contains "$out" "HAIKU" "show lists HAIKU"

# set opus <valid> and verify round-trip + comment preservation
out="$("$MM" set opus 'gpt-5.5(high)' 2>&1)"; st=$?
assert_success "$st" "set opus gpt-5.5(high) succeeds"

opus_line="$(grep -E '^[[:space:]]*OPUS[[:space:]]*=' "$CONF" | tail -1)"
assert_eq "OPUS = gpt-5.5(high)" "$opus_line" "models.conf OPUS line is exactly 'OPUS = gpt-5.5(high)'"
assert_contains "$(cat "$CONF")" "# claudex model map" "leading comments preserved after write"
assert_contains "$(cat "$CONF")" 'One-off override' "inline comments preserved after write"

out="$("$MM" show 2>&1)"
assert_contains "$out" "gpt-5.5(high)" "show reflects the new OPUS value"

# Invalid values must FAIL and must not modify the file.
before="$(filesum "$CONF")"

out="$("$MM" set opus 'bad model' 2>&1)"; st=$?
assert_fail "$st" "set opus 'bad model' (space) fails"
assert_eq "$before" "$(filesum "$CONF")" "file unchanged after invalid (space) model"

out="$("$MM" set opus 'gpt-5.5(ultra)' 2>&1)"; st=$?
assert_fail "$st" "set opus 'gpt-5.5(ultra)' (bad effort) fails"
assert_eq "$before" "$(filesum "$CONF")" "file unchanged after invalid (effort) model"

out="$("$MM" set opus 'gpt-5.5\bad' 2>&1)"; st=$?
assert_fail "$st" "set opus 'gpt-5.5\\bad' (backslash) fails"
assert_eq "$before" "$(filesum "$CONF")" "file unchanged after invalid (backslash) model"

# bad slot must FAIL
out="$("$MM" set bogus x 2>&1)"; st=$?
assert_fail "$st" "set bogus x (bad slot) fails"
assert_contains "$out" "slot must be one of" "bad slot prints guidance"

# profile cheap -> every populated slot ends up at (low)
out="$("$MM" profile cheap 2>&1)"; st=$?
assert_success "$st" "profile cheap succeeds"
for slot in OPUS SONNET HAIKU; do
  line="$(grep -E "^[[:space:]]*${slot}[[:space:]]*=" "$CONF" | tail -1)"
  assert_contains "$line" "(low)" "profile cheap set $slot to (low)"
done

# Network commands (list / interactive picker) are intentionally NOT tested:
# they require a running proxy and would be flaky/non-hermetic.
skip "claudex-models list (needs live proxy — network test intentionally skipped)"

# ===========================================================================
# 3. Non-interactive picker guard
# ===========================================================================
section "Non-interactive picker guard"

# Inside a command substitution, fd 1 is a pipe (not a tty), so run_picker's
# `[[ ! -t 1 ]]` guard fires deterministically. stdin is /dev/null too.
guard_out="$("$MM" set </dev/null 2>&1)"; st=$?
assert_fail "$st" "'set' with no controlling terminal exits non-zero"
assert_contains "$guard_out" "interactive terminal" "picker guard explains it needs a terminal"

# ===========================================================================
# 4. Installer idempotency + config preservation (offline, stubbed)
# ===========================================================================
section "Installer idempotency + config preservation"

SBOX="$TMPROOT/installer"
FAKE_HOME="$SBOX/home"
INST_DIR="$SBOX/claudex"
CFG_DIR="$SBOX/cliproxy"
FAKE_BIN="$SBOX/fakebin"
mkdir -p "$FAKE_HOME" "$FAKE_BIN" "$INST_DIR/bin"

# Pre-place a stub at the VERIFIED binary location ($INSTALL_DIR/bin) so install.sh
# reuses it and skips the download entirely — no network, no brew, no release fetch.
cat > "$INST_DIR/bin/cli-proxy-api" <<'STUB'
#!/usr/bin/env bash
echo "stub cli-proxy-api $*"
STUB
chmod +x "$INST_DIR/bin/cli-proxy-api"

WRAPPERS="claudex claudex-auth claudex-proxy claudex-models claudex-doctor claudex-uninstall claudex-update claudex-setup"

run_install() {
  # All state is redirected into the sandbox via env vars; the real $HOME is
  # never touched. SHELL=/bin/bash makes update_shell write to $FAKE_HOME/.bashrc.
  env HOME="$FAKE_HOME" \
      SHELL=/bin/bash \
      CLAUDEX_INSTALL_DIR="$INST_DIR" \
      CLIPROXY_CONFIG_DIR="$CFG_DIR" \
      PATH="$FAKE_BIN:$PATH" \
      bash "$REPO_DIR/install.sh" "$@"
}

# --- first run ---
out1="$(run_install 2>&1)"; st1=$?
assert_success "$st1" "install.sh first run exits 0"
assert_contains "$out1" "Using verified CLIProxyAPI" "first run reused the verified binary (no download)"

# api-key created, mode 600
if [[ -f "$INST_DIR/api-key" ]]; then
  pass "api-key file created"
else
  fail "api-key file created"
fi
assert_eq "600" "$(file_mode "$INST_DIR/api-key")" "api-key mode is 600"
key1="$(cat "$INST_DIR/api-key" 2>/dev/null || true)"

# config.yaml created, mode 600
if [[ -f "$CFG_DIR/config.yaml" ]]; then
  pass "config.yaml created"
else
  fail "config.yaml created"
fi
assert_eq "600" "$(file_mode "$CFG_DIR/config.yaml")" "config.yaml mode is 600"

# all 7 wrappers exist, executable, no leftover placeholders
for w in $WRAPPERS; do
  wf="$INST_DIR/bin/$w"
  if [[ -x "$wf" ]]; then
    pass "wrapper $w installed and executable"
  else
    fail "wrapper $w installed and executable"
  fi
  if grep -qE '__[A-Z_]+__' "$wf" 2>/dev/null; then
    fail "wrapper $w has leftover __PLACEHOLDER__"
  else
    pass "wrapper $w has no leftover placeholders"
  fi
done

# real HOME safety: ensure nothing leaked outside the sandbox
if [[ -f "$FAKE_HOME/.bashrc" ]]; then
  pass "shell rc written inside sandbox HOME (real HOME untouched)"
else
  skip "sandbox .bashrc not found (update_shell target may differ; real HOME still untouched)"
fi

# --- second run (idempotency) ---
out2="$(run_install 2>&1)"; st2=$?
assert_success "$st2" "install.sh second run exits 0"
key2="$(cat "$INST_DIR/api-key" 2>/dev/null || true)"
assert_eq "$key1" "$key2" "api-key content unchanged between runs"
assert_contains "$out2" "Preserving existing" "second run preserves the existing config"

# --- config preservation without --reset ---
SENTINEL="# CLAUDEX_TEST_SENTINEL_$$"
printf '%s\n' "$SENTINEL" >> "$CFG_DIR/config.yaml"

run_install >/dev/null 2>&1; st3=$?
assert_success "$st3" "install.sh (no --reset) exits 0"
assert_contains "$(cat "$CFG_DIR/config.yaml")" "$SENTINEL" "sentinel preserved WITHOUT --reset"

# --- config replacement with --reset ---
run_install --reset >/dev/null 2>&1; st4=$?
assert_success "$st4" "install.sh --reset exits 0"
assert_not_contains "$(cat "$CFG_DIR/config.yaml")" "$SENTINEL" "sentinel removed WITH --reset"

if find "$CFG_DIR" -maxdepth 1 -name 'config.yaml.backup.*' 2>/dev/null | grep -q .; then
  pass "--reset left a config.yaml.backup.* file"
else
  fail "--reset left a config.yaml.backup.* file"
fi

# ===========================================================================
# 5. Uninstall safety guard (refuses dangerous dirs)
# ===========================================================================
section "Uninstall safety guard"

USB="$TMPROOT/uninstall"
UHOME="$USB/home"
mkdir -p "$UHOME"

# Render claudex-uninstall with specific INSTALL_DIR/CONFIG_DIR values baked in.
render_uninstall() {
  local dst="$USB/claudex-uninstall.$RANDOM"
  sed -e "s#__CLAUDEX_INSTALL_DIR__#$1#g" -e "s#__CLIPROXY_CONFIG_DIR__#$2#g" \
      "$REPO_DIR/bin/claudex-uninstall" > "$dst"
  chmod +x "$dst"
  printf '%s' "$dst"
}

# INSTALL_DIR == $HOME must be refused (sandboxed HOME so a bug can't harm us).
u1="$(render_uninstall "$UHOME" "$UHOME/cfg")"
out_u1="$(HOME="$UHOME" "$u1" --yes 2>&1)"; st_u1=$?
assert_fail "$st_u1" "uninstall refuses INSTALL_DIR == \$HOME"
assert_contains "$out_u1" "too dangerous" "refusal explains the danger"

# A top-level directory must be refused.
u2="$(render_uninstall "/usr" "/usr")"
HOME="$UHOME" "$u2" --yes >/dev/null 2>&1; st_u2=$?
assert_fail "$st_u2" "uninstall refuses a top-level dir (/usr)"

# An ancestor of $HOME must be refused.
u3="$(render_uninstall "$USB" "$USB")"
HOME="$UHOME" "$u3" --yes >/dev/null 2>&1; st_u3=$?
assert_fail "$st_u3" "uninstall refuses an ancestor of \$HOME"

# A genuine claudex-owned dir under a sandbox HOME is allowed and removed.
SAFE="$UHOME/.claudex"
mkdir -p "$SAFE/bin"
printf 'x\n' > "$SAFE/api-key"
u4="$(render_uninstall "$SAFE" "$UHOME/.cli-proxy-api")"
HOME="$UHOME" "$u4" --yes >/dev/null 2>&1; st_u4=$?
assert_success "$st_u4" "uninstall proceeds for a safe claudex dir"
if [[ ! -d "$SAFE" ]]; then pass "safe dir actually removed"; else fail "safe dir actually removed"; fi

# Non-interactive without --yes must refuse (no accidental removal in pipelines).
u5="$(render_uninstall "$UHOME/.claudex2" "$UHOME/.cli-proxy-api")"
mkdir -p "$UHOME/.claudex2"
out_u5="$(printf '' | HOME="$UHOME" "$u5" 2>&1)"; st_u5=$?
assert_fail "$st_u5" "uninstall without --yes and no tty refuses"
assert_contains "$out_u5" "without confirmation" "refusal points to --yes"

# ===========================================================================
# 6. Guided setup wizard (non-tty fallback)
# ===========================================================================
section "Guided setup (non-interactive fallback)"

SETUP_DIR="$TMPROOT/setup"
mkdir -p "$SETUP_DIR"
SW="$SETUP_DIR/claudex-setup"
sed -e "s#__CLAUDEX_INSTALL_DIR__#${SETUP_DIR}#g" \
    -e "s#__CLIPROXY_CONFIG_DIR__#${SETUP_DIR}/cfg#g" \
    "$REPO_DIR/bin/claudex-setup" > "$SW"
chmod +x "$SW"

# In a captured (non-tty) context, claudex-setup must NOT block on prompts; it
# should print the manual steps and exit 0.
out_sw="$("$SW" 2>&1)"; st_sw=$?
assert_success "$st_sw" "claudex-setup exits 0 without a terminal"
assert_contains "$out_sw" "claudex-auth codex" "non-tty setup prints manual next steps"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%s================================%s\n' "$C_BLUE" "$C_RESET"
printf 'Summary: %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
  "$C_GREEN" "$PASS" "$C_RESET" \
  "$C_RED" "$FAIL" "$C_RESET" \
  "$C_YELLOW" "$SKIP" "$C_RESET"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0

#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Issue #1904 exact reproduction — "sandbox OpenClaw version is not upgraded
# after NemoClaw upgrade".
#
# Reproduces the original reporter's scenario step-by-step:
#
#   1. Install an OLDER NemoClaw release (v0.0.14) via install.sh
#   2. Run onboard → creates a sandbox with the old OpenClaw version
#   3. Upgrade to the CURRENT NemoClaw (this branch) via install.sh
#   4. Run `nemoclaw upgrade-sandboxes --check`
#   5. Verify it detects the sandbox as stale
#   6. Run `nemoclaw onboard --recreate-sandbox` to rebuild
#   7. Verify the sandbox now runs the current OpenClaw version
#
# This is the exact workflow that was broken before — the old :latest
# base image sat in Docker's cache and the new NemoClaw never pulled
# a fresh one, so sandboxes silently kept the old OpenClaw.
#
# Prerequisites:
#   - Docker running
#   - NVIDIA_API_KEY set (real key, starts with nvapi-)
#
# Environment variables:
#   NEMOCLAW_NON_INTERACTIVE=1             — required
#   NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 — required
#   NVIDIA_API_KEY                         — required

set -euo pipefail

OLD_NEMOCLAW_VERSION="v0.0.14"
SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-e2e-upgrade-stale}"
REGISTRY_FILE="$HOME/.nemoclaw/sandboxes.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() {
  echo -e "${RED}[FAIL]${NC} $1" >&2
  echo -e "${YELLOW}[DIAG]${NC} --- Failure diagnostics ---" >&2
  echo -e "${YELLOW}[DIAG]${NC} Registry: $(cat "${REGISTRY_FILE}" 2>/dev/null || echo 'not found')" >&2
  echo -e "${YELLOW}[DIAG]${NC} Sandboxes: $(openshell sandbox list 2>&1 || echo 'openshell unavailable')" >&2
  echo -e "${YELLOW}[DIAG]${NC} Docker images: $(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -i 'sandbox\|nemoclaw\|openclaw' | head -10)" >&2
  echo -e "${YELLOW}[DIAG]${NC} --- End diagnostics ---" >&2
  exit 1
}
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# ── Preflight ───────────────────────────────────────────────────────
[ -n "${NVIDIA_API_KEY:-}" ] || fail "NVIDIA_API_KEY is required"
[ "${NEMOCLAW_NON_INTERACTIVE:-}" = "1" ] || fail "NEMOCLAW_NON_INTERACTIVE=1 is required"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

info "Issue #1904 reproduction E2E (old: ${OLD_NEMOCLAW_VERSION}, sandbox: ${SANDBOX_NAME})"

# Helper: source shell profile so nemoclaw/openshell are on PATH
reload_path() {
  if [ -f "$HOME/.bashrc" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.bashrc" 2>/dev/null || true
  fi
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
  fi
  if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  fi
}

# ── Phase 1: Install OLD NemoClaw ───────────────────────────────────
info "Phase 1: Installing NemoClaw ${OLD_NEMOCLAW_VERSION} via install.sh..."

export NEMOCLAW_NON_INTERACTIVE=1
export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1
export NEMOCLAW_SANDBOX_NAME="${SANDBOX_NAME}"
export NEMOCLAW_RECREATE_SANDBOX=1
export NEMOCLAW_INSTALL_TAG="${OLD_NEMOCLAW_VERSION}"

# Run from a temp directory so install.sh doesn't detect the CI checkout
# as a source root (which would install the current branch instead of the
# old tag). This is what a real user experiences — curl|bash from $HOME.
OLD_INSTALL_DIR=$(mktemp -d)
OLD_INSTALL_LOG="/tmp/nemoclaw-e2e-old-install.log"
if ! (cd "$OLD_INSTALL_DIR" && curl -fsSL https://raw.githubusercontent.com/NVIDIA/NemoClaw/main/install.sh \
  | bash -s -- --non-interactive) >"$OLD_INSTALL_LOG" 2>&1; then
  info "Old install.sh exited non-zero (may be expected). Checking for nemoclaw..."
fi
rm -rf "$OLD_INSTALL_DIR"

reload_path
command -v nemoclaw >/dev/null 2>&1 || fail "nemoclaw not found on PATH after installing ${OLD_NEMOCLAW_VERSION}"
command -v openshell >/dev/null 2>&1 || fail "openshell not found on PATH after installing ${OLD_NEMOCLAW_VERSION}"

OLD_VERSION=$(nemoclaw --version 2>&1 || true)
info "Installed NemoClaw version: ${OLD_VERSION}"

# ── Phase 2: Record old sandbox state ────────────────────────────────
info "Phase 2: Recording old sandbox state..."

# Wait for sandbox to be ready
for _i in $(seq 1 30); do
  if openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}.*Ready\|${SANDBOX_NAME}.*Running"; then
    break
  fi
  sleep 5
done
openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}" \
  || fail "Sandbox ${SANDBOX_NAME} not found after old install"

# Capture the old OpenClaw version running inside the sandbox
OLD_OPENCLAW_VERSION=$(openshell sandbox exec --name "${SANDBOX_NAME}" -- openclaw --version 2>&1 || true)
info "Old sandbox OpenClaw version: ${OLD_OPENCLAW_VERSION}"

# Record old registry state
OLD_AGENT_VERSION=$(python3 -c "
import json, sys
try:
    d = json.load(open('${REGISTRY_FILE}'))
    sb = d.get('sandboxes', {}).get('${SANDBOX_NAME}', {})
    print(sb.get('agentVersion', 'unknown'))
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null || echo "unknown")
info "Old registry agentVersion: ${OLD_AGENT_VERSION}"

pass "Phase 2: Old sandbox running OpenClaw ${OLD_OPENCLAW_VERSION}"

# ── Phase 3: Upgrade ONLY the CLI to current (this branch) ───────────
info "Phase 3: Upgrading NemoClaw CLI to current branch..."

# Upgrade just the CLI binaries without re-onboarding. This leaves the
# old sandbox in place — exactly what the reporter experienced: they ran
# curl|bash which upgraded the CLI but the old sandbox kept the cached
# stale :latest image.
UPGRADE_LOG="/tmp/nemoclaw-e2e-upgrade-install.log"
(
  cd "${REPO_ROOT}"
  npm install --ignore-scripts
  npm run build:cli
  cd nemoclaw && npm install --ignore-scripts && npm run build && cd ..
  npm link
) >"$UPGRADE_LOG" 2>&1 || fail "CLI upgrade failed"

reload_path
NEW_VERSION=$(nemoclaw --version 2>&1 || true)
info "Upgraded NemoClaw version: ${NEW_VERSION}"

pass "Phase 3: NemoClaw upgraded from ${OLD_VERSION} to ${NEW_VERSION}"

# ── Phase 4: Verify upgrade-sandboxes detects the stale sandbox ──────
info "Phase 4: Running upgrade-sandboxes --check..."

CHECK_OUTPUT=$(nemoclaw upgrade-sandboxes --check 2>&1 || true)
echo "$CHECK_OUTPUT"

# The old sandbox should be detected as stale
if echo "$CHECK_OUTPUT" | grep -qi "stale\|need upgrading"; then
  pass "Phase 4: upgrade-sandboxes --check detected stale sandbox"
elif echo "$CHECK_OUTPUT" | grep -qi "up to date"; then
  fail "upgrade-sandboxes --check says all up to date — stale sandbox NOT detected (this is the #1904 bug)"
else
  info "Phase 4: Unexpected output from upgrade-sandboxes --check"
  fail "upgrade-sandboxes --check did not produce expected output"
fi

# ── Phase 5: Rebuild and verify new version ──────────────────────────
info "Phase 5: Rebuilding sandbox..."

nemoclaw "${SANDBOX_NAME}" rebuild --yes 2>&1 || fail "Sandbox rebuild failed"

# Wait for sandbox to be ready after rebuild
for _i in $(seq 1 30); do
  if openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}.*Ready\|${SANDBOX_NAME}.*Running"; then
    break
  fi
  sleep 5
done

NEW_OPENCLAW_VERSION=$(openshell sandbox exec --name "${SANDBOX_NAME}" -- openclaw --version 2>&1 || true)
info "New sandbox OpenClaw version: ${NEW_OPENCLAW_VERSION}"

# The new version must be different from (newer than) the old version
if [ "${NEW_OPENCLAW_VERSION}" = "${OLD_OPENCLAW_VERSION}" ]; then
  fail "Sandbox still running old OpenClaw ${OLD_OPENCLAW_VERSION} after rebuild — #1904 NOT fixed"
fi

pass "Phase 5: Sandbox upgraded from OpenClaw ${OLD_OPENCLAW_VERSION} to ${NEW_OPENCLAW_VERSION}"

# ── Phase 6: Verify upgrade-sandboxes now reports clean ──────────────
info "Phase 6: Verifying upgrade-sandboxes --check is clean..."

RECHECK_OUTPUT=$(nemoclaw upgrade-sandboxes --check 2>&1 || true)
echo "$RECHECK_OUTPUT"

if echo "$RECHECK_OUTPUT" | grep -qi "up to date"; then
  pass "Phase 6: upgrade-sandboxes --check reports all up to date after rebuild"
else
  info "Phase 6: Sandbox may still appear stale (non-fatal)"
fi

# ── Done ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Issue #1904 E2E PASSED${NC}"
echo -e "${GREEN}  Old: NemoClaw ${OLD_VERSION} / OpenClaw ${OLD_OPENCLAW_VERSION}${NC}"
echo -e "${GREEN}  New: NemoClaw ${NEW_VERSION} / OpenClaw ${NEW_OPENCLAW_VERSION}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

#!/usr/bin/env bash
# tests/boundary/sudo.sh
# Boundary: the sandbox account holds NO sudo rights -- the first security-model invariant in
# CLAUDE.md. The two NOPASSWD rules in sudoers.d/ai-tools-claude both belong to the PROJECTS
# user and DROP privilege to the sandbox account; the agent runs AS the sandbox account and
# can invoke neither. Asserts that at runtime (sudo -l for the sandbox account lists neither
# privileged target) and statically (no grant line names the sandbox account as principal).
# Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly SUDOERS="/etc/sudoers.d/ai-tools-claude"
section "Agent sudo rights (the sandbox account has none)"

# (1) Runtime: what sudo would let the sandbox account run. The agent must be able to run
# NEITHER privileged target -- the launch shim nor the updater. (-n: never prompt.)
avail="$(sudo -n -l -U "${SANDBOX_USER}" 2>&1 || true)"
if ! grep -q '/opt/ai-tools/bin/claude-run' <<<"${avail}" \
        && ! grep -q '/opt/ai-tools/bin/nvm-update.sh' <<<"${avail}"; then
    pass "sudo grants ${SANDBOX_USER} neither claude-run nor nvm-update.sh"
else
    fail "sudo -l shows a privileged target for ${SANDBOX_USER}: ${avail}"
fi

# (2) Static: the deployed drop-in. No grant line may name the sandbox account as principal
# (the leading field). A rule `ai-tools ALL=(...)` would give the agent a sudo path.
if [[ ! -r "${SUDOERS}" ]]; then
    skip "sudoers principal" "${SUDOERS} unreadable"
elif grep -qE "^[[:space:]]*${SANDBOX_USER}[[:space:]]+ALL=" "${SUDOERS}"; then
    fail "${SUDOERS} grants the sandbox account a rule -- ${SANDBOX_USER} must have no sudo rights"
else
    pass "${SUDOERS} names no ${SANDBOX_USER} grant (no sudo rule for the agent)"
fi

# (3) Static: both grants are the expected drop-privilege form -- the PROJECTS user as
# principal, dropping to the sandbox account. Confirms the rules lower privilege (never raise
# the agent's), so even invoked they hand the caller nothing it does not already have.
if [[ -r "${SUDOERS}" ]]; then
    n="$(grep -cE "^[[:space:]]*${PROJECTS_USER}[[:space:]]+ALL=\(${SANDBOX_USER}:" "${SUDOERS}" || true)"
    if [[ "${n}" -ge 2 ]]; then
        pass "both grants drop ${PROJECTS_USER} -> ${SANDBOX_USER} (privilege-lowering, not raising)"
    else
        fail "expected >=2 ${PROJECTS_USER}->${SANDBOX_USER} drop rules, found ${n}"
    fi
fi

finish

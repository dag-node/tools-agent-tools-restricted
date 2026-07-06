#!/usr/bin/env bash
# tests/boundary/sudo.sh
# Boundary: the sandbox account holds NO sudo rights -- the first security-model invariant in
# CLAUDE.md. The two NOPASSWD rules in sudoers.d/ai-tools-claude both belong to the PROJECTS
# user and DROP privilege to the sandbox account; the agent runs AS the sandbox account and
# can invoke neither. Asserts that at runtime (sudo -l for the sandbox account reports it is not
# allowed to run sudo at all) and statically (no grant line names the sandbox account as
# principal). Also pins the account hygiene the invariant depends on -- nologin shell, locked
# password, and non-membership in ai-ops. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly SUDOERS="/etc/sudoers.d/ai-tools-claude"
section "Agent sudo rights (the sandbox account has none)"

# (1) Runtime: what sudo would let the sandbox account run. The invariant is that the agent can
# run NOTHING via sudo -- so assert the canonical "not allowed to run sudo" message positively,
# not merely the absence of the two known targets. A negative check (no claude-run / no relabel)
# would pass a rogue drop-in granting the agent some OTHER command (e.g. ALL=(ALL) NOPASSWD:ALL);
# the positive form fails on any grant at all. (-n: never prompt.)
avail="$(sudo -n -l -U "${SANDBOX_USER}" 2>&1 || true)"
if grep -qiE 'not allowed to run sudo|is not allowed to execute' <<<"${avail}"; then
    pass "sudo grants ${SANDBOX_USER} nothing (\"not allowed to run sudo\")"
else
    fail "sudo -l shows one or more privileged targets for ${SANDBOX_USER} (expected none): ${avail}"
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

# (3) Static: the privilege-lowering grant uses the operators group (%ai-ops) as principal and
# drops to the sandbox account. Exactly one such drop rule exists (claude-run); the other rule
# targets root (the relabel helper), not the sandbox account. Confirms the rule lowers privilege
# (never raises the agent's), so even invoked it hands the caller nothing it does not already have.
if [[ -r "${SUDOERS}" ]]; then
    n="$(grep -cE "^[[:space:]]*%ai-ops[[:space:]]+ALL=\(${SANDBOX_USER}:" "${SUDOERS}" || true)"
    if [[ "${n}" -eq 1 ]]; then
        pass "the %ai-ops grant drops to ${SANDBOX_USER} (claude-run; privilege-lowering, not raising)"
    else
        fail "expected exactly 1 %ai-ops->${SANDBOX_USER} drop rule, found ${n}"
    fi
fi

# ── Account hygiene the "no sudo rights" invariant leans on ──────────────────────
# CLAUDE.md: the sandbox account has no login shell and no password, and is never a member of
# ai-ops (claude-run refuses to launch if it is). A shell or password would give an attacker who
# reached the account an interactive foothold; ai-ops membership would hand it the operator grant.
section "Sandbox account hygiene (${SANDBOX_USER})"

if ! getent passwd "${SANDBOX_USER}" >/dev/null 2>&1; then
    skip "sandbox account hygiene" "${SANDBOX_USER} account not present"
else
    # (4) No login shell: the passwd shell field is a nologin/false variant.
    shell="$(getent passwd "${SANDBOX_USER}" | cut -d: -f7)"
    if [[ "${shell}" == *nologin || "${shell}" == */false ]]; then
        pass "${SANDBOX_USER} has no login shell (${shell})"
    else
        fail "${SANDBOX_USER} login shell is '${shell}' -- expected a nologin/false shell"
    fi

    # (5) No usable password: the shadow password field is locked (! or *) or empty-locked, so
    # the account cannot be authenticated into. Prefer `passwd -S`; fall back to the shadow field.
    if command -v passwd >/dev/null 2>&1 && pw_status="$(passwd -S "${SANDBOX_USER}" 2>/dev/null)"; then
        # passwd -S field 2: L (locked), NP (no password), or P (usable password).
        pw_state="$(awk '{print $2}' <<<"${pw_status}")"
        if [[ "${pw_state}" == "L" || "${pw_state}" == "LK" ]]; then
            pass "${SANDBOX_USER} password is locked (passwd -S: ${pw_state})"
        elif [[ "${pw_state}" == "NP" ]]; then
            fail "${SANDBOX_USER} has NO password set (passwd -S: NP) -- account must be locked, not passwordless"
        else
            fail "${SANDBOX_USER} has a usable password (passwd -S: ${pw_state}) -- expected locked"
        fi
    else
        hash="$(getent shadow "${SANDBOX_USER}" 2>/dev/null | cut -d: -f2 || true)"
        if [[ -z "${hash}" ]]; then
            skip "sandbox password locked" "shadow entry unreadable (passwd -S unavailable)"
        elif [[ "${hash}" == '!'* || "${hash}" == '*'* ]]; then
            pass "${SANDBOX_USER} password is locked (shadow field '${hash:0:1}')"
        else
            fail "${SANDBOX_USER} shadow field is not locked ('${hash:0:1}...') -- expected a '!' or '*' lock"
        fi
    fi

    # (6) Not in ai-ops: the operator grant is a %ai-ops group rule, so membership would give the
    # agent the operator's privileges. claude-run also refuses to launch when this holds.
    if id -nG "${SANDBOX_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx 'ai-ops'; then
        fail "${SANDBOX_USER} is a member of ai-ops -- the agent would hold the operator sudo grant"
    else
        pass "${SANDBOX_USER} is not a member of ai-ops (holds no operator grant)"
    fi
fi

finish

#!/usr/bin/env bash
# tests/integration/handback.sh
# Integration: the handback-bridge + entrypoint regression guards. Pins the labels and DAC
# that the socket privilege bridge and the SELinux domain-transition depend on: the claude.exe
# entrypoint type, the socket's owner/mode and /run/ai-tools traversability, the socket-unit
# directives (systemd-252 traps), a live SYMLINK verb end-to-end as the agent, and the
# in-session auto-updater pin. Unit validity and enablement live in systemd.sh. Run as root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

# The systemd units (the nvm-update timer in the sandbox account's --user instance, the
# relabel watcher, this socket) are validated and their enablement checked in systemd.sh.

section "Handback bridge + entrypoint (regression guards)"

# (1) claude.exe must carry ai_tools_exec_t, or the unconfined_t/init_t -> ai_tools_t
# transition never fires and claude-run's preflight refuses to launch. It is a HARD LINK to
# the platform-package ELF, so a bulk restorecon can demote the shared inode to lib_t;
# install-selinux.sh relabels it LAST. Only meaningful when the ai_tools module is installed.
_exe="$(ls -1 /opt/ai-tools/.nvm/versions/node/*/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe 2>/dev/null | head -1)"
if [[ -z "${_exe}" ]]; then
    skip "claude.exe entrypoint label" "no claude.exe under the nvm tree"
elif ! command -v matchpathcon >/dev/null 2>&1 || [[ "$(matchpathcon -n "${_exe}" 2>/dev/null)" != *ai_tools_exec_t* ]]; then
    skip "claude.exe entrypoint label" "ai_tools SELinux module not installed"
elif [[ "$(stat -c '%C' "${_exe}" 2>/dev/null)" == *:ai_tools_exec_t:* ]]; then
    pass "claude.exe labelled ai_tools_exec_t (entrypoint transition fires)"
else
    fail "claude.exe is '$(stat -c '%C' "${_exe}" 2>/dev/null)', NOT ai_tools_exec_t -- claude-run will refuse to launch. Fix: install-selinux.sh relabel"
fi

# (2) Handback socket is 0660 root:SANDBOX_GROUP and /run/ai-tools is traversable by the
# sandbox user. The systemd-252 RuntimeDirectoryGroup= trap left the dir root:root and
# un-traversable; the fix is RuntimeDirectoryMode=0711 (world --x, contents unlistable).
_sock="/run/ai-tools/handback.sock"
if [[ ! -S "${_sock}" ]]; then
    skip "handback socket DAC" "${_sock} not present (service not started?)"
else
    check_file "${_sock}" root "${SANDBOX_GROUP}" 660
    if command -v runuser >/dev/null 2>&1 && runuser -u "${SANDBOX_USER}" -- test -x /run/ai-tools 2>/dev/null; then
        pass "/run/ai-tools traversable by ${SANDBOX_USER} (can reach the socket)"
    else
        fail "/run/ai-tools NOT traversable by ${SANDBOX_USER} -- RuntimeDirectoryMode regressed? (want 0711)"
    fi
fi

# (3) Deployed socket unit must NOT use RuntimeDirectoryGroup= (unknown key on systemd 252,
# silently ignored -> dir root:root) and MUST set RuntimeDirectoryMode=0711.
_unit="/usr/lib/systemd/system/ai-tools-handback.socket"
if [[ ! -f "${_unit}" ]]; then
    skip "handback socket unit directives" "${_unit} missing"
else
    if grep -qE '^[[:space:]]*RuntimeDirectoryGroup=' "${_unit}"; then
        fail "${_unit}: has RuntimeDirectoryGroup= -- unknown key on systemd 252, dir falls back to root:root. Use RuntimeDirectoryMode=0711"
    else
        pass "socket unit: no invalid RuntimeDirectoryGroup="
    fi
    if grep -qE '^[[:space:]]*RuntimeDirectoryMode=0711[[:space:]]*$' "${_unit}"; then
        pass "socket unit: RuntimeDirectoryMode=0711"
    else
        fail "${_unit}: RuntimeDirectoryMode is not 0711 -- ${SANDBOX_USER} may not traverse /run/ai-tools"
    fi
fi

# (4) Live SYMLINK verb end-to-end, idempotent (repoint to the CURRENT target). Exercises
# the full bridge as ${SANDBOX_USER}: socket reach (0711) + SO_PEERCRED + the daemon's
# getattr on the ai_tools_exec_t entrypoint. No net change: the target is unchanged.
_client="/usr/local/bin/ai-tools-handback-client"
_tgt="$(readlink /opt/ai-tools/bin/claude 2>/dev/null || true)"
if ! command -v runuser >/dev/null 2>&1; then
    skip "handback SYMLINK verb end-to-end" "runuser unavailable"
elif [[ ! -x "${_client}" || ! -S "${_sock}" ]]; then
    skip "handback SYMLINK verb end-to-end" "client or socket unavailable"
elif [[ -z "${_tgt}" ]]; then
    skip "handback SYMLINK verb end-to-end" "cannot read /opt/ai-tools/bin/claude target"
elif runuser -u "${SANDBOX_USER}" -- "${_client}" SYMLINK "${_tgt}" >/dev/null 2>&1; then
    pass "handback SYMLINK verb OK (socket reach + getattr on entrypoint)"
else
    fail "handback SYMLINK verb FAILED -- check /run/ai-tools (0711) reachable and ai_tools_handback_t getattr on ai_tools_exec_t"
fi

# (5) claude-run pins DISABLE_AUTOUPDATER=1: the node tree is read-only to the agent, so the
# in-session auto-updater would fail every launch (+ AVC). Updates are the timer's job.
_crun="/opt/ai-tools/bin/claude-run"
if [[ ! -r "${_crun}" ]]; then
    skip "claude-run disables auto-updater" "${_crun} unreadable"
elif grep -qE 'setenv=DISABLE_AUTOUPDATER=1' "${_crun}"; then
    pass "claude-run pins DISABLE_AUTOUPDATER=1 (no in-session self-update)"
else
    fail "claude-run does not pin DISABLE_AUTOUPDATER=1 -- agent will attempt the denied npm self-update"
fi

# (5a) claude-run pins the session's kernel-confinement properties on the transient unit:
# RestrictNamespaces=yes (the seccomp filter that blocks clone(CLONE_NEWUSER) and forces
# PR_SET_NO_NEW_PRIVS) and NoNewPrivileges=yes. These are trust-chain step 4; a revert here would
# launch sessions without namespace isolation or with SUID escalation reachable, and the only
# other signal is an on-box AVC. Pin them statically alongside DISABLE_AUTOUPDATER (the sibling
# self-update pin above) so a regression fails the suite, not just enforcing bring-up. The
# properties reach systemd-run as `--property=NAME=yes`.
if [[ -r "${_crun}" ]]; then
    for _prop in RestrictNamespaces NoNewPrivileges; do
        if grep -qE -- "--property=${_prop}=yes" "${_crun}"; then
            pass "claude-run pins ${_prop}=yes on the session unit"
        else
            fail "claude-run does not pin ${_prop}=yes -- session confinement (trust-chain step 4) weakened"
        fi
    done
    # UMask=0007 keeps agent-written files 660/770 (world stripped, operator+agent co-writers).
    if grep -qE -- '--property=UMask=0007' "${_crun}"; then
        pass "claude-run pins UMask=0007 on the session unit"
    else
        fail "claude-run does not pin UMask=0007 -- agent files may be born world-accessible"
    fi
fi

# ── Bridge input validation + allowlist boundary (negative, as the agent) ────────
#
# The whole privilege bridge rests on the daemon rejecting bad input and the helper
# re-validating the allowlist. Drive the real client AS the sandbox account and prove a
# request it must NOT honour changes nothing. The client exits non-zero and relays the
# daemon's ERR reason on any rejection.
section "Handback bridge: input validation + allowlist boundary (negative)"

if ! command -v runuser >/dev/null 2>&1 || [[ ! -x "${_client}" || ! -S "${_sock}" ]]; then
    skip "handback negative" "runuser, client, or socket unavailable"
else
    # Drive the client as the agent; capture combined output and the exit code without
    # tripping set -e (the assignment failure sits in a && / || list, which is exempt).
    drive() { runuser -u "${SANDBOX_USER}" -- "${_client}" "$@" 2>&1; }

    # (6) Unknown verb is rejected before any helper runs.
    out="$(drive BOGUS /etc/hostname)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'unknown verb' <<<"${out}"; then
        pass "daemon rejects an unknown verb (no helper dispatched)"
    else
        fail "unknown verb not cleanly rejected (rc=${rc}): ${out}"
    fi

    # (7) A non-absolute argument is rejected by the daemon's fail-fast pre-filter.
    out="$(drive CHOWN relative/path)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'malformed' <<<"${out}"; then
        pass "daemon rejects a non-absolute (malformed) argument"
    else
        fail "non-absolute arg not cleanly rejected (rc=${rc}): ${out}"
    fi

    # (8) The allowlist boundary holds THROUGH the bridge: a CHOWN on a root-owned file that
    # is NOT in any allowlist is refused by ai-tools-chown, leaving the victim untouched. The
    # victim lives under /var/opt/ai-tools (root-owned, NOT /tmp -- which is polyinstantiated
    # and would not cross to the daemon, and NOT allowlisted), so a buggy bridge that chowned
    # it would be a real privilege leak this test would catch.
    victim="$(mktemp /var/opt/ai-tools/.handback-negtest.XXXXXX)"
    _cleanup+=("${victim}")
    chown root:root "${victim}"; chmod 0600 "${victim}"
    before="$(stat -c '%U:%G' "${victim}")"
    drive CHOWN "${victim}" >/dev/null 2>&1 || true
    if [[ "$(stat -c '%U:%G' "${victim}")" == "${before}" && "${before}" == "root:root" ]]; then
        pass "out-of-allowlist CHOWN is refused through the bridge (victim stays root:root)"
    else
        fail "out-of-allowlist CHOWN changed the victim: ${before} -> $(stat -c '%U:%G' "${victim}")"
    fi
fi

finish

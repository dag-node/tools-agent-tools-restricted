#!/usr/bin/env bash
# tests/integration/handback.sh
# Integration: the auto-update timer plus the handback-bridge + entrypoint regression
# guards. Pins the labels and DAC that the socket privilege bridge and the SELinux
# domain-transition depend on: the claude.exe entrypoint type, the socket's owner/mode and
# /run/ai-tools traversability, the socket-unit directives (systemd-252 traps), a live
# SYMLINK verb end-to-end as the agent, and the in-session auto-updater pin. Run as root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

# ── Auto-update timer ────────────────────────────────────────────────────────────
section "Systemd auto-update timer"
if sudo -u "${PROJECTS_USER}" \
    XDG_RUNTIME_DIR="/run/user/${PROJECTS_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${PROJECTS_UID}/bus" \
    systemctl --user is-active nvm-update.timer > /dev/null 2>&1; then
    pass "nvm-update.timer is active"
else
    fail "nvm-update.timer is not active -- run: systemctl --user start nvm-update.timer"
fi

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

finish

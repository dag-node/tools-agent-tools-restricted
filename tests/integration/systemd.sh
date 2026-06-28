#!/usr/bin/env bash
# tests/integration/systemd.sh
# Integration: the shipped systemd units parse cleanly and are enabled in the right instance.
# `systemd-analyze verify` catches a directive typo that would otherwise ship silently; the
# enablement checks confirm the install wired each unit where it runs -- the toolchain timer in
# the sandbox account's own --user instance, the relabel watcher and handback socket in the
# system instance. Run as root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly UNITDIR=/usr/lib/systemd/system
readonly USERUNITDIR=/usr/lib/systemd/user
SANDBOX_UID="$(id -u "${SANDBOX_USER}" 2>/dev/null || true)"

# sandbox_systemctl <args...>: run `systemctl --user` in the sandbox account's own instance.
sandbox_systemctl() {
    sudo -u "${SANDBOX_USER}" \
        XDG_RUNTIME_DIR="/run/user/${SANDBOX_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SANDBOX_UID}/bus" \
        systemctl --user "$@"
}

section "Unit file validity (systemd-analyze verify)"
if ! command -v systemd-analyze >/dev/null 2>&1; then
    skip "unit verify" "systemd-analyze not installed"
else
    # verify_judge tolerates a verify failure whose ONLY complaint is an unresolved
    # Documentation=man: page -- minimal images (and any host without the man page installed) ship
    # nodocs, so `man restorecon(8)` is an environment gap, not a unit defect; any other complaint
    # still FAILs.
    verify_judge() {
        if [[ -z "$(printf '%s\n' "$2" | grep -vE "Command 'man .+' failed" | tr -d '[:space:]')" ]]; then
            pass "$1 (man-page Documentation not installed; unit otherwise valid)"
        else
            fail "$1: $2"
        fi
    }
    # System units. The handback@.service template is instantiated at runtime (the socket
    # passes the connection), so it is not verifiable standalone and is left to handback.sh.
    for u in ai-tools-handback.socket ai-tools-relabel.path ai-tools-relabel.service; do
        if out="$(systemd-analyze verify "${UNITDIR}/${u}" 2>&1)"; then
            pass "verify ${u}"
        else
            verify_judge "verify ${u}" "${out}"
        fi
    done
    # User units verify against the --user manager context, so run as the sandbox account with
    # its runtime dir. `systemd-analyze --user` as root has no XDG_RUNTIME_DIR and fails the
    # RuntimeDirectory lookup -- that is the caller's missing context, not a unit defect.
    if [[ -z "${SANDBOX_UID}" || ! -d "/run/user/${SANDBOX_UID}" ]]; then
        skip "verify nvm-update user units" "${SANDBOX_USER}'s --user instance not reachable"
    else
        for u in nvm-update.service nvm-update.timer; do
            if out="$(sudo -u "${SANDBOX_USER}" \
                          XDG_RUNTIME_DIR="/run/user/${SANDBOX_UID}" \
                          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SANDBOX_UID}/bus" \
                          systemd-analyze --user verify "${USERUNITDIR}/${u}" 2>&1)"; then
                pass "verify ${u} (--user)"
            else
                verify_judge "verify ${u} (--user)" "${out}"
            fi
        done
    fi
fi

section "Enablement in the correct instance"

# (1) Handback socket: active in the system instance (the privilege bridge the hooks reach).
if systemctl is-active ai-tools-handback.socket >/dev/null 2>&1; then
    pass "ai-tools-handback.socket is active (system)"
else
    fail "ai-tools-handback.socket is not active -- run: systemctl start ai-tools-handback.socket"
fi

# (2) Relabel watcher: enabled in the system instance, so a post-upgrade symlink repoint
# triggers the entrypoint relabel without operator action.
if systemctl is-enabled ai-tools-relabel.path >/dev/null 2>&1; then
    pass "ai-tools-relabel.path is enabled (system)"
else
    fail "ai-tools-relabel.path is not enabled -- run: systemctl enable --now ai-tools-relabel.path"
fi

# (3) Toolchain timer: active in the SANDBOX account's own --user instance (not the operator's),
# where the updater writes the shared .nvm tree directly. Needs the sandbox account's linger.
if [[ -z "${SANDBOX_UID}" ]]; then
    skip "nvm-update.timer" "no ${SANDBOX_USER} account"
elif [[ ! -d "/run/user/${SANDBOX_UID}" ]]; then
    fail "${SANDBOX_USER}'s --user instance is not reachable -- enable linger: loginctl enable-linger ${SANDBOX_USER}"
elif sandbox_systemctl is-active nvm-update.timer >/dev/null 2>&1; then
    pass "nvm-update.timer is active in ${SANDBOX_USER}'s --user instance"
else
    fail "nvm-update.timer is not active in ${SANDBOX_USER}'s instance -- run: sudo -u ${SANDBOX_USER} systemctl --user enable --now nvm-update.timer"
fi

finish

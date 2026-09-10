#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
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
# The --user units this project ships. Other packages install into the same directory, and this
# suite judges only its own units, so every check over the user units reads this one list.
readonly -a SHIPPED_USER_UNITS=(nvm-update.service nvm-update.timer)
SANDBOX_UID="$(id -u "${SANDBOX_USER}" 2>/dev/null || true)"

# sandbox_systemctl <args...>: run `systemctl --user` in the sandbox account's own instance.
# XDG_RUNTIME_DIR alone lets systemctl auto-discover D-Bus (EL9) or Varlink (EL10); forcing
# DBUS_SESSION_BUS_ADDRESS breaks EL10 where the bus socket may not exist.
sandbox_systemctl() {
    # Prefer the machine transport. This suite runs as root, and dropping into the account with
    # sudo needs that account's own bus to accept the connection -- which a host may refuse while
    # the manager is perfectly healthy, making a bus refusal indistinguishable from an absent
    # manager. The machine transport reaches the same manager over the system bus, where root is
    # already authorized; the sudo form is the fallback for a systemd without it.
    systemctl --user -M "${SANDBOX_USER}@.host" "$@" 2>/dev/null && return 0
    sudo -u "${SANDBOX_USER}" \
        XDG_RUNTIME_DIR="/run/user/${SANDBOX_UID}" \
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
        for u in "${SHIPPED_USER_UNITS[@]}"; do
            if out="$(sudo -u "${SANDBOX_USER}" \
                          XDG_RUNTIME_DIR="/run/user/${SANDBOX_UID}" \
                          systemd-analyze --user verify "${USERUNITDIR}/${u}" 2>&1)"; then
                pass "verify ${u} (--user)"
            else
                verify_judge "verify ${u} (--user)" "${out}"
            fi
        done
    fi
fi

section "No --user unit carries a mount-namespace option"

# In a per-user service manager an option that needs a mount namespace implies PrivateUsers=
# (systemd.exec(5)), which maps that account's uid alone -- so every other host uid, root included,
# reads back as the overflow uid 65534 while stat(1) still exits 0. Every uid-based trust predicate
# in the payload then refuses: ai_tools_conf_is_trusted requires owner 0, so the updater reads
# root-owned manifests as nobody-owned and resolves NO agent. nvm-update.sh ends that run as a
# fault, so the state is reported once it exists; this check keeps it from existing.
#
# It is a text check rather than a runtime one because the unit starts either way:
# `systemd-analyze verify` does not report the option, and RestrictNamespaces= does not prevent it
# (it filters the payload's own unshare/clone/setns, which systemd installs after building the
# namespace), so the unit file is where it is catchable.
#
# The check covers EVERY --user unit this project ships, not the one where this was found, because
# the property belongs to the manager rather than to the updater. A unit another package installs
# beside them is that package's to judge, so only SHIPPED_USER_UNITS is read.
_NS_OPTS='PrivateTmp|PrivateUsers|PrivateDevices|PrivateMounts|PrivateNetwork|ProtectSystem|ProtectHome|ProtectKernelTunables|ProtectKernelModules|ProtectControlGroups|ProtectProc|ReadOnlyPaths|ReadWritePaths|InaccessiblePaths|BindPaths|BindReadOnlyPaths|TemporaryFileSystem|RootDirectory|RootImage|MountAPIVFS'
for u in "${SHIPPED_USER_UNITS[@]}"; do
    if [[ ! -f "${USERUNITDIR}/${u}" ]]; then
        skip "${u} carries no mount-namespace option" "not installed in ${USERUNITDIR}"
        continue
    fi
    # Assignments only, so a directive named in a comment (this rationale, or a unit header
    # explaining the prohibition) is not read as one being set.
    if out="$(grep -nE "^[[:space:]]*(${_NS_OPTS})[[:space:]]*=" "${USERUNITDIR}/${u}")"; then
        fail "${u} sets a mount-namespace option, which makes every host uid read as 65534 in this manager and leaves the payload's trust checks refusing root-owned files: ${out//$'\n'/; }"
    else
        pass "${u} carries no mount-namespace option (uids stay untranslated)"
    fi
done

section "Enablement in the correct instance"

# (1) Handback socket: enabled AND active in the system instance (the privilege bridge the hooks
# reach). is-enabled is asserted on its own because the enable comes from the shipped preset
# (85-ai-tools.preset) -- a package that ships it disabled leaves the handback silently dead (the
# class of bug where a source install worked but the RPM did not), which this catches even if the
# socket happens to be started by hand.
if systemctl is-enabled ai-tools-handback.socket >/dev/null 2>&1; then
    pass "ai-tools-handback.socket is enabled (system, via preset)"
else
    fail "ai-tools-handback.socket is not enabled -- the 85-ai-tools.preset enable did not take; run: systemctl enable --now ai-tools-handback.socket"
fi
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

# sandbox_user_mgr_up: succeed once the sandbox account's --user manager answers on its bus.
sandbox_user_mgr_up() { sandbox_systemctl show -p Version --value >/dev/null 2>&1; }

# (3) Toolchain timer: active in the SANDBOX account's own --user instance (not the operator's),
# where the updater writes the shared .nvm tree directly. The timer is active only while that
# --user manager runs, and what keeps the manager running with no login is the account's
# linger, which `ai-tools-admin operators add` enables. This reads that state and does not
# repair it -- the suite starts and stops nothing on the host, and a manager it had started
# would either stay up as a change the run made or be stopped along with any session launched
# meanwhile. So: linger absent is a FAILURE (the enrolment did not take, and ai-tools-run
# aborts at the bus socket on such a host); linger present with the manager down is the
# container case, where logind does not sustain the lingering instance across the suite's
# session open/close, and the runtime state is untestable here -- skip with the start command
# named (the on-disk enablement and `systemd-analyze verify` above already cover correctness).
if [[ -z "${SANDBOX_UID}" ]]; then
    skip "nvm-update.timer" "no ${SANDBOX_USER} account"
elif [[ ! -e "/var/lib/systemd/linger/${SANDBOX_USER}" ]]; then
    fail "linger is not enabled for ${SANDBOX_USER}, so its --user manager (and nvm-update.timer) does not run without a login -- run: loginctl enable-linger ${SANDBOX_USER}"
else
    pass "linger is enabled for ${SANDBOX_USER} (its --user manager runs without a login)"
    # The manager reaches timers.target (and starts the wants-linked timer) shortly after its
    # bus comes up, so retry briefly rather than reading the state in the same instant.
    _timer_active=""
    for _i in $(seq 1 10); do
        sandbox_systemctl is-active nvm-update.timer >/dev/null 2>&1 && { _timer_active=1; break; }
        sleep 0.5
    done
    if [[ -n "${_timer_active}" ]]; then
        pass "nvm-update.timer is active in ${SANDBOX_USER}'s --user instance"
    elif ! sandbox_user_mgr_up; then
        skip "nvm-update.timer is-active" \
            "${SANDBOX_USER}'s --user manager is not running despite linger (a container where logind does not sustain the lingering instance); enablement verified on disk. To bring it up by hand: systemctl start user@${SANDBOX_UID}.service"
    else
        # Manager is up but the timer is not active -- a real enablement gap. Dump its view.
        printf '\n--- nvm-update.timer diagnostics ---\n'
        sandbox_systemctl show nvm-update.timer \
            -p LoadState -p ActiveState -p SubState -p Result \
            -p UnitFileState -p TriggeredBy -p NextElapseUSecRealtime 2>&1 || true
        sandbox_systemctl status --no-pager nvm-update.timer 2>&1 | head -n 12 || true
        printf -- '--- end diagnostics ---\n\n'
        fail "nvm-update.timer is not active in ${SANDBOX_USER}'s instance -- run: sudo -u ${SANDBOX_USER} systemctl --user enable --now nvm-update.timer"
    fi
fi

# ai-tools --status reports these same units end to end (it sources services.lib.sh, iterates the
# registry, and queries systemctl). Run as the projects user (the CLI refuses root); --status
# bypasses the provisioning gate, so it works regardless of bootstrap state.
#
# What is asserted is that the REPORT ran and named the handback socket -- the same registry the
# launch-time warning shares -- not that this host is healthy. --status exits 1 when it reports
# something broken (see cli.rule.md), which is a successful report on an unhealthy host and must
# not fail the suite: a test host legitimately has a unit down. So 0 and 1 both pass provided the
# output is there, while any other status (or missing output) means the command itself broke.
section "ai-tools --status service report"
readonly CLI="/usr/local/bin/ai-tools"
if [[ ! -x "${CLI}" ]]; then
    skip "ai-tools --status" "CLI not installed at ${CLI}"
elif ! command -v runuser >/dev/null 2>&1; then
    skip "ai-tools --status" "runuser unavailable"
else
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" "${CLI}" --status 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -le 1 ]] && grep -q 'ai-tools-handback.socket' <<<"${out}"; then
        pass "ai-tools --status reports service health (lists ai-tools-handback.socket, rc=${rc})"
    else
        fail "ai-tools --status did not report services (rc=${rc}): ${out}"
    fi
fi

finish

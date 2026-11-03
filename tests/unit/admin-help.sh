#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/admin-help.sh
# The help contract on the admin side: a help request on any base path prints that path's help and does not run the
# command, on ai-tools-admin and on the dotnet command it dispatches. The checkout's ai-tools-admin.sh and dotnet
# fragment run as the projects user through runuser, with recorders first on PATH for the host tools the base commands
# and the fragment reach first (`id`, `usermod`, `semodule`, `getent`, `systemctl`, `rpm`; `dotnet`, `restorecon`,
# `semanage`, `getenforce`), so a command the help request ran would leave a line in the recorder log. Each row asserts
# exit 0, the expected help, and an empty log. Beside them:
#   * `operators add --version`, as root, is refused under MSG-J2S8 with no `id` call, and `operators add svc`, as
#     root, is the control that reaches the `id` recorder;
#   * `dotnet tools install help` and `tools install -- --help` are not help requests, so the projects user meets
#     the fragment's root refusal; `dotnet status` as root is the control that reaches the `dotnet` recorder.
# The fragment names the admin program by its fixed path for the reconcile, which a PATH recorder does not catch,
# so no row drives `tools install <pkg>` as root.
#
# Both programs source the installed libraries by fixed path, so the run reads the deployed tree: before an install
# carrying help.lib.sh the admin rows skip on the library the helper cannot load. Needs root.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADMIN="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
DOTNET="${ROOT}/src/usr/local/lib/ai-tools/admin-commands.d/dotnet.sh"
section "ai-tools-admin: a help request runs nothing (unit)"
if [[ ! -r "${ADMIN}" || ! -r "${DOTNET}" ]]; then
    skip "admin help" "the checkout's ai-tools-admin.sh or dotnet fragment is not readable"; finish; exit
fi

# x_bit_visible <dir>: succeed when a 0755 file created there reads as executable (tests/unit/atr.sh's probe).
x_bit_visible() {
    local probe="$1/.x-probe.$$" ok=1
    printf '' > "${probe}" 2>/dev/null || return 1
    chmod 0755 "${probe}" 2>/dev/null || { rm -f "${probe}"; return 1; }
    [[ -x "${probe}" ]] && ok=0
    rm -f "${probe}"
    return "${ok}"
}
mktestdir
FIXTURE="${TESTDIR}"
if ! x_bit_visible "${FIXTURE}"; then
    mk_fixture_dir FIXTURE "${PROJECTS_HOME}" admin-help 2>/dev/null || FIXTURE=""
fi
if [[ -z "${FIXTURE}" ]] || ! x_bit_visible "${FIXTURE}"; then
    skip_required "admin help" "no directory here reports a 0755 file as executable (a noexec mount)"
    finish; exit
fi
chmod 0755 "${FIXTURE}"
install -d -m 0755 "${FIXTURE}/bin"
install -d -m 0777 "${FIXTURE}/log"
for tool in id usermod semodule getent systemctl rpm dotnet restorecon semanage getenforce; do
    cat > "${FIXTURE}/bin/${tool}" <<EOF
#!/bin/bash
printf '%s %s\n' "${tool}" "\$*" >> "${FIXTURE}/log/calls"
exit 1
EOF
    chmod 0755 "${FIXTURE}/bin/${tool}"
done
readonly RUN_PATH="${FIXTURE}/bin:/usr/bin:/bin"

# run_as <user|root> <program> <arg>... : run <program> under the recorder PATH; sets RC, OUT (stdout) and ERR.
run_as() {
    local who="$1" program="$2"; shift 2
    rm -f "${FIXTURE}/log/calls"
    RC=0
    if [[ "${who}" == root ]]; then
        env -i PATH="${RUN_PATH}" "${RUN_ENV[@]}" bash "${program}" "$@" > "${FIXTURE}/out" 2> "${FIXTURE}/err" || RC=$?
    else
        runuser -u "${PROJECTS_USER}" -- env -i PATH="${RUN_PATH}" bash "${program}" "$@" \
            > "${FIXTURE}/out" 2> "${FIXTURE}/err" < /dev/null || RC=$?
    fi
    OUT="$(cat "${FIXTURE}/out")"; ERR="$(cat "${FIXTURE}/err")"
}
calls() { cat "${FIXTURE}/log/calls" 2>/dev/null || true; }
RUN_ENV=()

# The admin needs the installed help library; a host before that install skips the admin rows on it.
run_as user "${ADMIN}" --help
if grep -qx 'MSG-V6F4' <<< "${ERR}"; then
    skip_required "ai-tools-admin help rows" "the installed tree lacks a library the checkout's helper sources: ${ERR//$'\n'/ }"
else
    # helps <want> <arg>... : as the projects user, the admin prints <want> on stdout, exits 0, and does not call
    # a tool.
    helps() {
        local want="$1"; shift
        run_as user "${ADMIN}" "$@"
        if [[ "${RC}" -eq 0 && "${OUT}" == *"${want}"* && -z "$(calls)" ]]; then
            pass "ai-tools-admin $* prints its help and runs nothing"
        else
            fail "ai-tools-admin $*: rc=${RC} calls=[$(calls)] stdout=[${OUT}] stderr=[${ERR}]"
        fi
    }
    for flag in -h --help; do
        helps "atr admin operators [list] [OPTION...]"         operators list "${flag}"
        helps "atr admin operators add [USER] [OPTION...]"     operators add svc "${flag}"
        helps "atr admin operators remove USER [OPTION...]"    operators remove svc "${flag}"
        helps "atr admin selinux groups enable GROUP..."       selinux groups enable tmpmap "${flag}"
        helps "atr admin selinux groups disable GROUP"         selinux groups disable tmpmap "${flag}"
        helps "atr admin system bootstrap [OPTION...]"         system bootstrap --scope full "${flag}"
        helps "atr admin system entrypoints relabel"           system entrypoints relabel "${flag}"
        helps "atr admin system post-upgrade [OPTION...]"      system post-upgrade "${flag}"
        helps "atr admin system layout reconcile [OPTION...]"  system layout reconcile "${flag}"
        helps "atr admin assets enable ID... [OPTION...]"      assets enable core/skills/x "${flag}"
        helps "atr admin assets disable ID... [OPTION...]"     assets disable core/skills/x "${flag}"
        helps "atr admin assets reconcile [OPTION...]"         assets reconcile "${flag}"
        helps "atr admin status [OPTION...]"                   status "${flag}"
        helps "atr admin stop [OPTION...]"                     stop "${flag}"
    done
    helps "atr admin operators [COMMAND]"    operators help
    helps "atr admin selinux groups [COMMAND]" selinux groups help
    helps "atr admin system COMMAND"         system help
    helps "atr admin system layout [COMMAND]" system layout help
    helps "atr admin assets [COMMAND]"       help assets
    helps "Agent Tools Restricted -- host administration (ai-tools-admin)"
    helps "Agent Tools Restricted -- host administration (ai-tools-admin)" help

    # A help request on an unknown path reaches the arm that names it, under its own code, after the root check.
    unknown() {
        local code="$1"; shift
        run_as root "${ADMIN}" "$@"
        if [[ "${RC}" -eq 2 ]] && grep -qx "${code}" <<< "${ERR}" && grep -q '^ai-tools-admin: unknown command: ' <<< "${ERR}"; then
            pass "ai-tools-admin $* is the unknown command under its arm's code"
        else
            fail "ai-tools-admin $*: rc=${RC} stderr=[${ERR}]"
        fi
    }
    unknown MSG-D4S7 help assets bogus
    unknown MSG-D4S7 assets bogus --help
    unknown MSG-N2A5 help bogus
    unknown MSG-N2A5 bogus --help

    # A help request on a contributed domain reaches the fragment with its help flag first, ahead of any `--`, in every
    # form. The domain here is a recorder in a fixture directory, so a forwarding that dropped the flag records the argv
    # it passed and does not run the fragment's code.
    install -d -o root -g root -m 0755 "${FIXTURE}/domains"
    cat > "${FIXTURE}/domains/dotnet" <<EOF
#!/bin/bash
# ai-tools-admin-command: dotnet
# ai-tools-admin-api-min-version: 1.0
# ai-tools-admin-verbs: bootstrap tools status
printf '%s\n' "\$@" > "${FIXTURE}/log/forwarded"
EOF
    chown root:root "${FIXTURE}/domains/dotnet"; chmod 0750 "${FIXTURE}/domains/dotnet"
    RUN_ENV=(AI_TOOLS_ADMIN_COMMANDS_DIR="${FIXTURE}/domains")
    forwards() {
        local want="$1"; shift
        rm -f "${FIXTURE}/log/forwarded"
        run_as root "${ADMIN}" "$@"
        local got
        got="$(paste -sd' ' "${FIXTURE}/log/forwarded" 2>/dev/null || true)"
        if [[ "${got}" == "${want}" ]]; then
            pass "ai-tools-admin $* reaches the domain as: ${want}"
        else
            fail "ai-tools-admin $*: the domain received [${got}], expected [${want}]; rc=${RC} stderr=[${ERR}]"
        fi
    }
    forwards "--help tools install -- pkg" help dotnet tools install -- pkg
    forwards "--help tools"                --help dotnet tools
    forwards "--help tools"                -h dotnet tools
    forwards "--help"                      dotnet --help
    forwards "--help tools install pkg"    dotnet tools install pkg -h
    forwards "tools install -- --help"     dotnet tools install -- --help
    RUN_ENV=()

    # The account-name check answers before `id`, and the control reaches it.
    run_as root "${ADMIN}" operators add --version
    if [[ "${RC}" -eq 2 ]] && grep -qx MSG-J2S8 <<< "${ERR}" && [[ "$(calls)" != *"id "* ]]; then
        pass "operators add --version is refused as not an account name, with no id call"
    else
        fail "operators add --version: rc=${RC} calls=[$(calls)] stderr=[${ERR}]"
    fi
    run_as root "${ADMIN}" operators add svc
    if [[ "$(calls)" == *"id svc"* ]]; then
        pass "operators add svc reaches the id recorder (the control)"
    else
        fail "operators add svc did not reach id: rc=${RC} calls=[$(calls)] stderr=[${ERR}]"
    fi
fi

# ── the dotnet fragment ──────────────────────────────────────────────────────────────────────────
dotnet_helps() {
    run_as user "${DOTNET}" "$@"
    if [[ "${RC}" -eq 0 && "${OUT}" == *"Agent Tools Restricted -- .NET integration"* && -z "$(calls)" ]]; then
        pass "dotnet $* prints its help and runs nothing"
    else
        fail "dotnet $*: rc=${RC} calls=[$(calls)] stdout=[${OUT}] stderr=[${ERR}]"
    fi
}
dotnet_helps tools install --help
dotnet_helps tools install pkg -h
dotnet_helps bootstrap --help
dotnet_helps help
dotnet_helps tools help
for args in "tools install help" "tools install -- --help"; do
    read -r -a argv <<< "${args}"
    run_as user "${DOTNET}" "${argv[@]}"
    if [[ "${RC}" -eq 1 ]] && grep -qx MSG-C4T6 <<< "${ERR}" && [[ "${OUT}" != *"Usage:"* ]]; then
        pass "dotnet ${args} is not a help request: the projects user meets the root refusal"
    else
        fail "dotnet ${args}: rc=${RC} stdout=[${OUT}] stderr=[${ERR}]"
    fi
done
run_as root "${DOTNET}" status
if [[ "$(calls)" == *"dotnet "* ]]; then
    pass "dotnet status as root reaches the dotnet recorder (the control)"
else
    fail "dotnet status did not reach dotnet: rc=${RC} calls=[$(calls)] stderr=[${ERR}]"
fi

finish

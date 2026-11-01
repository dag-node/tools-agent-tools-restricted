#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/atr.sh
# Hermetic check of the short command `atr` (src/usr/local/bin/atr.sh): `atr admin <command>` runs ai-tools-admin,
# directly as root and otherwise through sudo after one notice line on stderr, and every other invocation runs ai-tools,
# each with its arguments as given and the program's exit status as its own.
#
# A copy of the checkout's atr.sh runs with its two program paths rewritten to recorders in a fixture directory, its
# help library path at the checkout's help.lib.sh (whose siblings are the checkout's libraries), its domain and manifest
# directories at fixtures, and a recorder named `sudo` first on PATH. Each recorder appends its argv to a log of its own
# as NUL-terminated fields, the field count first, and exits with the status a file beside it names, so an argument
# boundary, an empty argument and an option-looking one are each read back as they were passed. The wrapper execs its
# programs, so the fixture directory must report a 0755 file as executable: the testdir where it does, a directory
# beside the projects user's home otherwise, the fallback tests/unit/agent-installs.sh takes. Every fixture the projects
# user reads takes its mode explicitly, since a root run inherits the umask sudo hands it. The copy's path is printed
# first. A recorder records its basename and none of the paths the wrapper names, so the fixed paths themselves are
# asserted by reading the wrapper as text. As root the direct exec is driven, and the same copy through runuser
# as the projects user renders the help requests, takes the sudo route for every other command line, and lists a trusted
# fixture domain with its summary. The operator branch runs `id` and `stat`, which the recorder PATH links
# in from the host; a case forced onto the sudo route is the control that the no-sudo assertions read the operator
# branch. No install, no real
# sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${ROOT}/src/usr/local/bin/atr.sh"
[[ -r "${WRAPPER}" ]] || WRAPPER=/usr/local/bin/atr
readonly WRAPPER
section "atr: atr runs ai-tools, and atr admin runs ai-tools-admin as root (unit)"

if [[ ! -r "${WRAPPER}" ]]; then
    skip "atr" "neither the checkout's atr.sh nor /usr/local/bin/atr is readable"
    finish; exit
fi

# ── the fixed paths ───────────────────────────────────────────────────────────────────────────
admin_line="$(grep -E '^readonly AI_TOOLS_ATR__ADMIN=' -- "${WRAPPER}" || true)"
cli_line="$(grep -E '^readonly AI_TOOLS_ATR__CLI=' -- "${WRAPPER}" || true)"
[[ "${admin_line}" == 'readonly AI_TOOLS_ATR__ADMIN=/usr/local/libexec/ai-tools/ai-tools-admin' ]] \
    && pass "the wrapper names ai-tools-admin at /usr/local/libexec/ai-tools/ai-tools-admin" \
    || fail "the admin path line reads: ${admin_line:-absent}"
[[ "${cli_line}" == 'readonly AI_TOOLS_ATR__CLI=/usr/local/bin/ai-tools' ]] \
    && pass "the wrapper names ai-tools at /usr/local/bin/ai-tools" \
    || fail "the CLI path line reads: ${cli_line:-absent}"
[[ "$(sed -n '3p' -- "${WRAPPER}")" == '# /usr/local/bin/atr --'* ]] \
    && pass "the third line carries the marker the install's collision check reads" \
    || fail "the third line is not the marker: $(sed -n '3p' -- "${WRAPPER}")"

# ── the fixture: a copy of the wrapper and its recorders ─────────────────────────────────────────
# x_bit_visible <dir>: succeed when a 0755 file created there reads as executable.
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
    mk_fixture_dir FIXTURE "${PROJECTS_HOME}" atr 2>/dev/null || FIXTURE=""
fi
if [[ -z "${FIXTURE}" ]] || ! x_bit_visible "${FIXTURE}"; then
    skip_required "atr dispatch" "no directory here reports a 0755 file as executable (a noexec mount)"
    finish; exit
fi
chmod 0755 "${FIXTURE}"
mkdir -p "${FIXTURE}/bin" "${FIXTURE}/log" "${FIXTURE}/nosudo"
# The projects user reads the recorders and the copy through runuser, and the host umask decides the mode of a directory
# this run makes, so each directory that account reads takes its mode here; write_recorder_exit_status sets each status
# file's.
chmod 0755 "${FIXTURE}/bin" "${FIXTURE}/nosudo"
chmod 0777 "${FIXTURE}/log"
HELP_LIB="${ROOT}/src/usr/local/lib/ai-tools/help.lib.sh"
[[ -r "${HELP_LIB}" ]] || HELP_LIB=/usr/local/lib/ai-tools/help.lib.sh
DOMAINS="${FIXTURE}/admin-commands.d"
MANIFESTS="${FIXTURE}/integrations.d"
# write_copy <dest> [<sed-expression>...] : the wrapper with its fixed paths rewritten to the fixture, and any further
# expression applied after them.
write_copy() {
    local dest="$1"; shift
    local -a extra=()
    local expression
    for expression in "$@"; do extra+=(-e "${expression}"); done
    sed -e "s#^readonly AI_TOOLS_ATR__ADMIN=.*#readonly AI_TOOLS_ATR__ADMIN=${FIXTURE}/bin/ai-tools-admin#" \
        -e "s#^readonly AI_TOOLS_ATR__CLI=.*#readonly AI_TOOLS_ATR__CLI=${FIXTURE}/bin/ai-tools#" \
        -e "s#^readonly AI_TOOLS_ATR__HELP_LIB=.*#readonly AI_TOOLS_ATR__HELP_LIB=${HELP_LIB}#" \
        -e "s#^readonly AI_TOOLS_ATR__ADMIN_COMMANDS_DIR=.*#readonly AI_TOOLS_ATR__ADMIN_COMMANDS_DIR=${DOMAINS}#" \
        -e "s#^readonly AI_TOOLS_ATR__INTEGRATIONS_DIR=.*#readonly AI_TOOLS_ATR__INTEGRATIONS_DIR=${MANIFESTS}#" \
        -e "s#^readonly AI_TOOLS_ATR__AGENTS_DIR=.*#readonly AI_TOOLS_ATR__AGENTS_DIR=${FIXTURE}/agents.d#" \
        "${extra[@]}" -- "${WRAPPER}" > "${dest}"
    chmod 0644 "${dest}"
}
COPY="${FIXTURE}/atr.sh"
write_copy "${COPY}"
printf '  copy under test: %s\n' "${COPY}"
for line in "${HELP_LIB}" "${DOMAINS}" "${MANIFESTS}"; do
    grep -qF -- "${line}" "${COPY}" || fail "the copy does not carry the rewritten path ${line}"
done
for name in ai-tools ai-tools-admin sudo; do
    # Builtins alone, so the recorders run under a PATH naming the fixture directory alone. A status file present
    # and unreadable makes the recorder exit 99, which every case asserting a status reads as a failure.
    cat > "${FIXTURE}/bin/${name}" <<EOF
#!/bin/bash
{ printf '%s\0' "\$#" "\$@"; } >> "${FIXTURE}/log/${name}"
status=0
[[ -e "${FIXTURE}/log/${name}.status" ]] && { read -r status < "${FIXTURE}/log/${name}.status" || status=99; } 2>/dev/null
exit "\${status}"
EOF
    chmod 0755 "${FIXTURE}/bin/${name}"
done
readonly ADMIN_PATH="${FIXTURE}/bin/ai-tools-admin"
# The operator branch reads the caller with `id`, the trust predicate reads owner and mode with `stat`, and the manifest
# reader reads a manifest with `cat`; each comes from the host, into each PATH a case runs under.
for tool in id stat cat; do
    host_tool="$(command -v "${tool}")"
    ln -s "${host_tool}" "${FIXTURE}/bin/${tool}"
    ln -s "${host_tool}" "${FIXTURE}/nosudo/${tool}"
done

# atr_run <path-list> <arg>... : clear the logs, run the copy under PATH=<path-list>; sets RC, OUT and ERR.
atr_run() {
    local path_list="$1"; shift
    rm -f "${FIXTURE}/log/ai-tools" "${FIXTURE}/log/ai-tools-admin" "${FIXTURE}/log/sudo"
    RC=0
    env -i PATH="${path_list}" "${BASH}" "${COPY}" "$@" > "${FIXTURE}/out" 2> "${FIXTURE}/err" || RC=$?
    OUT="$(cat "${FIXTURE}/out")"; ERR="$(cat "${FIXTURE}/err"; printf x)"; ERR="${ERR%x}"
}
# list_calls <name> : print each call <name>'s recorder logged as one line, fields joined by `|`; empty for no call.
list_calls() {
    local -a fields=(); local i=0 count j line
    [[ -r "${FIXTURE}/log/$1" ]] || return 0
    mapfile -d '' -t fields < "${FIXTURE}/log/$1"
    while (( i < ${#fields[@]} )); do
        count="${fields[i]}"; line=""; i=$(( i + 1 ))
        for (( j = 0; j < count; j++ )); do line+="${line:+|}${fields[i]}"; [[ -n "${fields[i]}" ]] || line+='<empty>'; i=$(( i + 1 )); done
        printf '%s\n' "${line:-<no arguments>}"
    done
}
# write_recorder_exit_status <name> <status|-> : the exit status <name>'s recorder takes; `-` for 0.
write_recorder_exit_status() {
    if [[ "$2" == - ]]; then rm -f "${FIXTURE}/log/$1.status"
    else printf '%s\n' "$2" > "${FIXTURE}/log/$1.status"; chmod 0644 "${FIXTURE}/log/$1.status"; fi
}
readonly NOTICE=$'atr admin: runs as root through sudo\n'
WITH_SUDO="${FIXTURE}/bin"

# ── every invocation but admin runs ai-tools ──────────────────────────────────────────────────
if (( EUID == 0 )); then
    note "the CLI cases run as root" "the wrapper does not read the caller for a CLI command"
fi
atr_run "${WITH_SUDO}"
[[ "$(list_calls ai-tools)" == '<no arguments>' && -z "$(list_calls sudo)" && -z "${ERR}" ]] \
    && pass "no argument runs ai-tools with an empty argv" \
    || fail "no argument: ai-tools=[$(list_calls ai-tools)] sudo=[$(list_calls sudo)] stderr=[${ERR}]"
for args in "--for|op|projects|claim" "status" "--help" "--for|op|admin|x" "administer"; do
    IFS='|' read -r -a argv <<< "${args}"
    atr_run "${WITH_SUDO}" "${argv[@]}"
    if [[ "$(list_calls ai-tools)" == "${args}" && -z "$(list_calls sudo)" && -z "$(list_calls ai-tools-admin)" \
          && -z "${ERR}" ]]; then
        pass "atr ${args//|/ } runs ai-tools with its argv intact and nothing on stderr"
    else
        fail "atr ${args//|/ }: ai-tools=[$(list_calls ai-tools)] sudo=[$(list_calls sudo)] stderr=[${ERR}]"
    fi
done
write_recorder_exit_status ai-tools 3
atr_run "${WITH_SUDO}" status
(( RC == 3 )) && pass "ai-tools exiting 3 makes atr exit 3" || fail "ai-tools exited 3, atr exited ${RC}"
write_recorder_exit_status ai-tools -

# ── admin for a caller that is not root ──────────────────────────────────────────────────────────
# check_admin_dispatch_cases <runner> <caller> : the operator cases, each run through <runner> (atr_run,
# or atr_run_as_operator as root) as the account <caller> names.
check_admin_dispatch_cases() {
    local runner="$1" caller="$2" args expected keep
    local -a argv=()
    # A help request, a bare `atr admin` and `--version` render here, without sudo.
    for args in "--help" "-h" "help" "" "operators|help" "operators|add|--help" "stop|--help"; do
        argv=()
        [[ -n "${args}" ]] && IFS='|' read -r -a argv <<< "${args}"
        "${runner}" "${WITH_SUDO}" admin "${argv[@]}"
        if [[ "${OUT}" == *"Usage:"* && "${RC}" == 0 && -z "${ERR}" \
              && -z "$(list_calls sudo)$(list_calls ai-tools-admin)$(list_calls ai-tools)" ]]; then
            pass "atr admin ${args:-(bare)} prints the help on stdout with no sudo call"
        else
            fail "atr admin ${args:-(bare)}: sudo=[$(list_calls sudo)] rc=${RC} stderr=[${ERR}] stdout=[${OUT}]"
        fi
    done
    "${runner}" "${WITH_SUDO}" admin --version
    [[ "${OUT}" == "ai-tools-admin dev" && "${RC}" == 0 && -z "$(list_calls sudo)" ]] \
        && pass "atr admin --version prints the version with no sudo call" \
        || fail "atr admin --version: rc=${RC} stdout=[${OUT}] sudo=[$(list_calls sudo)]"
    "${runner}" "${WITH_SUDO}" admin stop --help
    [[ "${OUT}" == *"atr admin stop [OPTION...]"* ]] \
        && pass "atr admin stop --help prints the stop hint" || fail "atr admin stop --help: stdout=[${OUT}]"
    # stop without a help flag runs ai-tools stop, for every caller, with no sudo call.
    for args in "stop" "stop|--dry-run"; do
        IFS='|' read -r -a argv <<< "${args}"
        "${runner}" "${WITH_SUDO}" admin "${argv[@]}"
        [[ "$(list_calls ai-tools)" == "${args}" && -z "$(list_calls sudo)$(list_calls ai-tools-admin)" ]] \
            && pass "atr admin ${args//|/ } runs ai-tools ${args//|/ } with no sudo call" \
            || fail "atr admin ${args//|/ }: ai-tools=[$(list_calls ai-tools)] sudo=[$(list_calls sudo)]"
    done
    # Every other command line takes the sudo route whole: a command, a domain's help, an unknown path's help.
    for args in "status" "dotnet|--help" "bogus|--help" "operators|bogus|--help"; do
        IFS='|' read -r -a argv <<< "${args}"
        "${runner}" "${WITH_SUDO}" admin "${argv[@]}"
        expected="--|${ADMIN_PATH}|${args}"
        if [[ "$(list_calls sudo)" == "${expected}" && -z "$(list_calls ai-tools-admin)" \
              && -z "$(list_calls ai-tools)" \
              && "${ERR}" == "${NOTICE}" && -z "${OUT}" && "${RC}" == 0 ]]; then
            pass "atr admin ${args//|/ } asks sudo for the fixed admin path, after the one notice line"
        else
            fail "atr admin ${args//|/ }: sudo=[$(list_calls sudo)] admin=[$(list_calls ai-tools-admin)] rc=${RC} stderr=[${ERR}] stdout=[${OUT}]"
        fi
    done
    "${runner}" "${WITH_SUDO}" admin system bootstrap --agents 'a b' '' --dry-run -- x
    expected="--|${ADMIN_PATH}|system|bootstrap|--agents|a b|<empty>|--dry-run|--|x"
    [[ "$(list_calls sudo)" == "${expected}" ]] \
        && pass "each argument reaches sudo as one field, the spaced and the empty one included" \
        || fail "argv through sudo: [$(list_calls sudo)], expected [${expected}]"
    write_recorder_exit_status sudo 7
    "${runner}" "${WITH_SUDO}" admin status
    (( RC == 7 )) && pass "sudo exiting 7 makes atr exit 7" || fail "sudo exited 7, atr exited ${RC}"
    write_recorder_exit_status sudo -
    "${runner}" "${FIXTURE}/nosudo" admin status
    if (( RC == 1 )) \
          && [[ "${ERR}" == $'atr admin: runs as root, and sudo is not installed -- run the command as root: ai-tools-admin\n' ]] \
          && [[ -z "$(list_calls sudo)$(list_calls ai-tools-admin)$(list_calls ai-tools)" ]]; then
        pass "with no sudo on PATH atr admin exits 1 with the one line and runs no program"
    else
        fail "no sudo: rc=${RC} stderr=[${ERR}]" \
             "records=[$(list_calls sudo)$(list_calls ai-tools-admin)$(list_calls ai-tools)]"
    fi
    keep="${COPY}"
    # A help library that does not load sends the help request to sudo after one line naming it.
    COPY="${FIXTURE}/atr-nolib.sh"
    write_copy "${COPY}" "s#^readonly AI_TOOLS_ATR__HELP_LIB=.*#readonly AI_TOOLS_ATR__HELP_LIB=${FIXTURE}/absent.lib.sh#"
    "${runner}" "${WITH_SUDO}" admin --help
    if [[ "$(list_calls sudo)" == "--|${ADMIN_PATH}|--help" && "${ERR}" == *"cannot load ${FIXTURE}/absent.lib.sh"*"${NOTICE}" \
          && "$(printf '%s' "${ERR}" | grep -c '')" -eq 2 && -z "${OUT}" ]]; then
        pass "with the help library absent, atr admin --help takes the sudo route after one line naming it"
    else
        fail "absent help library: sudo=[$(list_calls sudo)] stderr=[${ERR}] stdout=[${OUT}]"
    fi
    # The sandbox account is not shown the help: with the account name rewritten to the caller's, `--help` takes sudo.
    # This is also the control that the rendered cases read the operator branch: the same line, forced onto the sudo
    # route, calls sudo.
    COPY="${FIXTURE}/atr-sandbox.sh"
    write_copy "${COPY}" "s#^readonly AI_TOOLS_ATR__SANDBOX_USER=.*#readonly AI_TOOLS_ATR__SANDBOX_USER=\"${caller}\"#"
    "${runner}" "${WITH_SUDO}" admin --help
    if [[ "$(list_calls sudo)" == "--|${ADMIN_PATH}|--help" && "${OUT}" != *"Usage:"* ]]; then
        pass "as the sandbox account, atr admin --help takes the sudo route and prints no Usage: line"
    else
        fail "as the sandbox account: sudo=[$(list_calls sudo)] stdout=[${OUT}]"
    fi
    COPY="${keep}"
}
# atr_run_as_operator <path-list> <arg>... : atr_run as the projects user through runuser.
atr_run_as_operator() {
    local path_list="$1"; shift
    rm -f "${FIXTURE}/log/ai-tools" "${FIXTURE}/log/ai-tools-admin" "${FIXTURE}/log/sudo"
    RC=0
    runuser -u "${PROJECTS_USER}" -- env -i PATH="${path_list}" "${BASH}" "${COPY}" "$@" \
        > "${FIXTURE}/out" 2> "${FIXTURE}/err" || RC=$?
    OUT="$(cat "${FIXTURE}/out")"; ERR="$(cat "${FIXTURE}/err"; printf x)"; ERR="${ERR%x}"
}

if (( EUID != 0 )); then
    check_admin_dispatch_cases atr_run "$(id -un)"
    skip "atr admin as root" "the direct exec needs a root run"
else
    # ── as root: the program directly ─────────────────────────────────────────────────────────────
    atr_run "${WITH_SUDO}" admin status
    if [[ "$(list_calls ai-tools-admin)" == status && -z "$(list_calls sudo)" && -z "${ERR}" && "${RC}" == 0 ]]; then
        pass "as root, atr admin status runs the admin program directly with no notice"
    else
        fail "as root: admin=[$(list_calls ai-tools-admin)] sudo=[$(list_calls sudo)] rc=${RC} stderr=[${ERR}]"
    fi
    write_recorder_exit_status ai-tools-admin 4
    atr_run "${WITH_SUDO}" admin status
    (( RC == 4 )) && pass "as root, the admin program exiting 4 makes atr exit 4" || fail "as root, atr exited ${RC}"
    write_recorder_exit_status ai-tools-admin -
    for args in "stop" "stop|--dry-run"; do
        IFS='|' read -r -a argv <<< "${args}"
        atr_run "${WITH_SUDO}" admin "${argv[@]}"
        [[ "$(list_calls ai-tools)" == "${args}" && -z "$(list_calls sudo)$(list_calls ai-tools-admin)" ]] \
            && pass "as root, atr admin ${args//|/ } runs ai-tools ${args//|/ }" \
            || fail "as root, atr admin ${args//|/ }: ai-tools=[$(list_calls ai-tools)] admin=[$(list_calls ai-tools-admin)]"
    done
    check_admin_dispatch_cases atr_run_as_operator "${PROJECTS_USER}"

    # ── the domain listing over the fixed directory, as the operator ─────────────────────────────────
    install -d -o root -g root -m 755 "${DOMAINS}" "${MANIFESTS}"
    printf '#!/bin/sh\nexit 0\n' > "${DOMAINS}/demo"; chown root:root "${DOMAINS}/demo"; chmod 750 "${DOMAINS}/demo"
    printf 'default_enable=no\nadmin_summary=Provision the demo state\n' > "${MANIFESTS}/demo.conf"
    chown root:root "${MANIFESTS}/demo.conf"; chmod 644 "${MANIFESTS}/demo.conf"
    atr_run_as_operator "${WITH_SUDO}" admin help
    if [[ "${OUT}" == *"  demo COMMAND"*"Provision the demo state"* && "${OUT}" != *"(refused:"* \
          && -z "$(list_calls sudo)" ]]; then
        pass "the operator's atr admin help lists the trusted fixture domain with its summary"
    else
        fail "the trusted fixture domain is not listed: stdout=[${OUT}] stderr=[${ERR}]"
    fi
    printf '#!/bin/sh\nexit 0\n' > "${DOMAINS}/weak"; chown root:root "${DOMAINS}/weak"; chmod 770 "${DOMAINS}/weak"
    atr_run_as_operator "${WITH_SUDO}" admin help
    if [[ "${OUT}" == *"(refused: a file there is not root's alone"* && "${ERR}" == *MSG-D3P6* ]]; then
        pass "a group-writable fragment beside it adds the refusal line and its warning"
    else
        fail "the refusal line is missing: stdout=[${OUT}] stderr=[${ERR}]"
    fi
fi

finish

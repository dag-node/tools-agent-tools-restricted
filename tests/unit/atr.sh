#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/atr.sh
# Hermetic check of the short command `atr` (src/usr/local/bin/atr.sh): `atr admin <command>` runs ai-tools-admin,
# directly as root and otherwise through sudo after one notice line on stderr, and every other invocation runs ai-tools,
# each with its arguments as given and the program's exit status as its own.
#
# A copy of the checkout's atr.sh runs with its two readonly paths rewritten to recorders in a fixture directory,
# and a recorder named `sudo` first on PATH. Each recorder appends its argv to a log of its own as NUL-terminated
# fields, the field count first, and exits with the status a file beside it names, so an argument boundary, an empty
# argument and an option-looking one are each read back as they were passed. The wrapper execs its programs,
# so the fixture directory must report a 0755 file as executable: the testdir where it does, a directory beside
# the projects user's home otherwise, the fallback tests/unit/agent-installs.sh takes. Every fixture the projects user
# reads takes its mode explicitly, since a root run inherits the umask sudo hands it. The copy's path is printed first.
# A recorder records its basename and none of the paths the wrapper names, so the fixed paths themselves are asserted
# by reading the wrapper as text. As root the direct exec is driven, and the same copy through runuser as the projects
# user takes the sudo route. No install, no real sudo.

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
    skip "atr dispatch" "no directory here reports a 0755 file as executable (a noexec mount)"
    finish; exit
fi
chmod 0755 "${FIXTURE}"
mkdir -p "${FIXTURE}/bin" "${FIXTURE}/log" "${FIXTURE}/nosudo"
# The projects user reads the recorders and the copy through runuser, and the host umask decides the mode of a directory
# this run makes, so each directory that account reads takes its mode here; set_status sets each status file's.
chmod 0755 "${FIXTURE}/bin" "${FIXTURE}/nosudo"
chmod 0777 "${FIXTURE}/log"
COPY="${FIXTURE}/atr.sh"
sed -e "s#^readonly AI_TOOLS_ATR__ADMIN=.*#readonly AI_TOOLS_ATR__ADMIN=${FIXTURE}/bin/ai-tools-admin#" \
    -e "s#^readonly AI_TOOLS_ATR__CLI=.*#readonly AI_TOOLS_ATR__CLI=${FIXTURE}/bin/ai-tools#" -- "${WRAPPER}" > "${COPY}"
chmod 0644 "${COPY}"
printf '  copy under test: %s\n' "${COPY}"
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

# atr_run <path-list> <arg>... : clear the logs, run the copy under PATH=<path-list>; sets RC, OUT and ERR.
atr_run() {
    local path_list="$1"; shift
    rm -f "${FIXTURE}/log/ai-tools" "${FIXTURE}/log/ai-tools-admin" "${FIXTURE}/log/sudo"
    RC=0
    env -i PATH="${path_list}" "${BASH}" "${COPY}" "$@" > "${FIXTURE}/out" 2> "${FIXTURE}/err" || RC=$?
    OUT="$(cat "${FIXTURE}/out")"; ERR="$(cat "${FIXTURE}/err"; printf x)"; ERR="${ERR%x}"
}
# records <name> : print each call <name>'s recorder logged as one line, fields joined by `|`; empty for no call.
records() {
    local -a fields=(); local i=0 count j line
    [[ -r "${FIXTURE}/log/$1" ]] || return 0
    mapfile -d '' -t fields < "${FIXTURE}/log/$1"
    while (( i < ${#fields[@]} )); do
        count="${fields[i]}"; line=""; i=$(( i + 1 ))
        for (( j = 0; j < count; j++ )); do line+="${line:+|}${fields[i]}"; [[ -n "${fields[i]}" ]] || line+='<empty>'; i=$(( i + 1 )); done
        printf '%s\n' "${line:-<no arguments>}"
    done
}
# set_status <name> <status|-> : the exit status <name>'s recorder takes; `-` for 0.
set_status() {
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
[[ "$(records ai-tools)" == '<no arguments>' && -z "$(records sudo)" && -z "${ERR}" ]] \
    && pass "no argument runs ai-tools with an empty argv" \
    || fail "no argument: ai-tools=[$(records ai-tools)] sudo=[$(records sudo)] stderr=[${ERR}]"
for args in "--for|op|projects|claim" "status" "--help" "--for|op|admin|x" "administer"; do
    IFS='|' read -r -a argv <<< "${args}"
    atr_run "${WITH_SUDO}" "${argv[@]}"
    if [[ "$(records ai-tools)" == "${args}" && -z "$(records sudo)" && -z "$(records ai-tools-admin)" \
          && -z "${ERR}" ]]; then
        pass "atr ${args//|/ } runs ai-tools with its argv intact and nothing on stderr"
    else
        fail "atr ${args//|/ }: ai-tools=[$(records ai-tools)] sudo=[$(records sudo)] stderr=[${ERR}]"
    fi
done
set_status ai-tools 3
atr_run "${WITH_SUDO}" status
(( RC == 3 )) && pass "ai-tools exiting 3 makes atr exit 3" || fail "ai-tools exited 3, atr exited ${RC}"
set_status ai-tools -

# ── admin through sudo, for a caller that is not root ──────────────────────────────────────────
# admin_cases <runner> : the sudo-route cases, each run through <runner> (atr_run, or atr_run_as_operator as root).
admin_cases() {
    local runner="$1" args expected
    for args in "status" "--help" "-h" "--version" ""; do
        local -a argv=()
        [[ -n "${args}" ]] && IFS='|' read -r -a argv <<< "${args}"
        "${runner}" "${WITH_SUDO}" admin "${argv[@]}"
        expected="--|${ADMIN_PATH}${args:+|${args}}"
        if [[ "$(records sudo)" == "${expected}" && -z "$(records ai-tools-admin)" && -z "$(records ai-tools)" \
              && "${ERR}" == "${NOTICE}" && -z "${OUT}" && "${RC}" == 0 ]]; then
            pass "atr admin ${args:-(bare)} asks sudo for the fixed admin path, after the one notice line"
        else
            fail "atr admin ${args:-(bare)}: sudo=[$(records sudo)] admin=[$(records ai-tools-admin)] rc=${RC} stderr=[${ERR}] stdout=[${OUT}]"
        fi
    done
    "${runner}" "${WITH_SUDO}" admin system bootstrap --agents 'a b' '' --dry-run -- x
    expected="--|${ADMIN_PATH}|system|bootstrap|--agents|a b|<empty>|--dry-run|--|x"
    [[ "$(records sudo)" == "${expected}" ]] \
        && pass "each argument reaches sudo as one field, the spaced and the empty one included" \
        || fail "argv through sudo: [$(records sudo)], expected [${expected}]"
    set_status sudo 7
    "${runner}" "${WITH_SUDO}" admin status
    (( RC == 7 )) && pass "sudo exiting 7 makes atr exit 7" || fail "sudo exited 7, atr exited ${RC}"
    set_status sudo -
    "${runner}" "${FIXTURE}/nosudo" admin status
    if (( RC == 1 )) \
          && [[ "${ERR}" == $'atr admin: runs as root, and sudo is not installed -- run the command as root: ai-tools-admin\n' ]] \
          && [[ -z "$(records sudo)$(records ai-tools-admin)$(records ai-tools)" ]]; then
        pass "with no sudo on PATH atr admin exits 1 with the one line and runs no program"
    else
        fail "no sudo: rc=${RC} stderr=[${ERR}] records=[$(records sudo)$(records ai-tools-admin)$(records ai-tools)]"
    fi
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
    admin_cases atr_run
    skip "atr admin as root" "the direct exec needs a root run"
else
    # ── as root: the program directly ─────────────────────────────────────────────────────────────
    atr_run "${WITH_SUDO}" admin status
    if [[ "$(records ai-tools-admin)" == status && -z "$(records sudo)" && -z "${ERR}" && "${RC}" == 0 ]]; then
        pass "as root, atr admin status runs the admin program directly with no notice"
    else
        fail "as root: admin=[$(records ai-tools-admin)] sudo=[$(records sudo)] rc=${RC} stderr=[${ERR}]"
    fi
    set_status ai-tools-admin 4
    atr_run "${WITH_SUDO}" admin status
    (( RC == 4 )) && pass "as root, the admin program exiting 4 makes atr exit 4" || fail "as root, atr exited ${RC}"
    set_status ai-tools-admin -
    admin_cases atr_run_as_operator
fi

finish

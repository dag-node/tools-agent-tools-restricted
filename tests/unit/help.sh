#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/help.sh
# Unit test for the help library (help.lib.sh), the command surface of ai-tools and ai-tools-admin as data, read from
# the checkout. What it pins:
#   * the rows: five fields each, a known block, a description that opens with a capital letter and ends within
#     80 columns at its program's description column;
#   * the rendered text: both top helps and every hint within 80 columns, the admin's with no domain directory,
#     with a fixture directory holding a trusted fragment and its manifest (root, since the trust predicate accepts
#     root-owned files alone), and with a group-writable fragment beside it for the refusal line;
#   * the resolver, as a table per program: one row per command line the help contract reads, its status and its
#     target, the `--` boundary, a help flag in an option's value, the prefix form, `help` as an argument, the typed
#     path of an unknown one, and the domain status over the fixture directory;
#   * the help command an unknown-command line names, and the reserved base names;
#   * a copy of the library whose conf.lib.sh is unreachable returns non-zero at source and does not define a function.
#
# Every call runs in a shell of its own, so the library's readonly rows stay out of this one. Runs unprivileged;
# the fixture-directory cases need root and skip otherwise.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/src/usr/local/lib/ai-tools/help.lib.sh"
section "help.lib.sh: the command surface and its help (unit)"
if [[ ! -r "${LIB}" ]]; then
    skip "help library" "not found at ${LIB}"; finish; exit
fi
mktestdir

# lib <code>: run <code> in a fresh bash that has sourced the library under the CLI's strict mode and IFS,
# with the integration manifests at ${MANIFESTS:-the checkout's}.
lib() {
    # shellcheck disable=SC2016  # the inner bash expands these
    env AI_TOOLS_INTEGRATIONS_DIR="${MANIFESTS:-${ROOT}/src/usr/local/lib/ai-tools/integrations.d}" \
        bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; source "$1"; eval "$2"' _ "${LIB}" "$1"
}

# ── The rows ──────────────────────────────────────────────────────────────────────────────────
for program in ai-tools ai-tools-admin; do
    case "${program}" in
        ai-tools)       array=_AI_TOOLS_HELP__ROWS_AI_TOOLS
                        blocks="Projects Reports Incident Options" ;;
        ai-tools-admin) array=_AI_TOOLS_HELP__ROWS_AI_TOOLS_ADMIN
                        blocks="Operators SELinux System Assets Health Incident Options" ;;
    esac
    rows="$(lib "for r in \"\${${array}[@]}\"; do printf '%s\n' \"\${r}\"; done")"
    column="$(lib "_ai_tools_help__label_width ${program}")"
    bad=""
    while IFS= read -r row; do
        tabs="${row//[^$'\t']/}"
        block="${row%%$'\t'*}"
        description="$(cut -f4 <<<"${row}")"
        [[ "${#tabs}" -eq 4 ]] || bad+="fields:${row} "
        [[ " ${blocks} " == *" ${block} "* ]] || bad+="block:${block} "
        [[ "${description}" =~ ^[A-Z] ]] || bad+="capital:${description} "
        (( 2 + column + ${#description} <= 80 )) || bad+="width:${description} "
    done <<<"${rows}"
    if [[ -n "${rows}" && -z "${bad}" ]]; then
        pass "${program}: every row has five fields, a known block, and a capitalised description within 80 columns"
    else
        fail "${program}: rows out of form: ${bad:-no row read}"
    fi
done

# ── The rendered text ─────────────────────────────────────────────────────────────────────────
# within80 <label> <text>: every line of <text> is 80 columns or fewer.
within80() {
    local wide
    wide="$(awk 'length($0) > 80 {print length($0) ": " $0}' <<<"$2")"
    if [[ -n "$2" && -z "${wide}" ]]; then pass "$1 is within 80 columns"
    else fail "$1 has a line past 80 columns or is empty: ${wide}"; fi
}
within80 "the ai-tools help" "$(lib 'ai_tools_help__render ai-tools')"
within80 "the ai-tools-admin help with no domain directory" "$(lib 'ai_tools_help__render ai-tools-admin /nonexistent')"
hints=""
for program in ai-tools ai-tools-admin; do
    while IFS=$'\t' read -r path argument _; do
        hints+="$(lib "ai_tools_help__render_hint ${program} '${path}'")"$'\n'
        [[ "${argument}" != "[list]" ]] || hints+="$(lib "ai_tools_help__render_hint ${program} '${path} list'")"$'\n'
    done < <(lib "ai_tools_help__list_commands ${program}")
done
for path in system selinux "system entrypoints"; do
    hints+="$(lib "ai_tools_help__render_hint ai-tools-admin '${path}'")"$'\n'
done
within80 "every hint" "${hints}"
if lib "ai_tools_help__render_hint ai-tools bogus" >/dev/null; then
    fail "a hint for a path the rows do not hold succeeded"
elif [[ -z "$(lib "ai_tools_help__render_hint ai-tools bogus" || true)" ]]; then
    pass "a hint for a path the rows do not hold returns non-zero and prints nothing"
fi
# A collection whose bare form lists takes its command as optional; a namespace with no listing requires one.
for pair in "ai-tools|projects|atr [--for OPERATOR] projects [COMMAND]" "ai-tools-admin|system layout|atr admin system layout [COMMAND]" \
        "ai-tools-admin|system entrypoints|atr admin system entrypoints COMMAND" "ai-tools-admin|system|atr admin system COMMAND"; do
    IFS='|' read -r program path want <<< "${pair}"
    out="$(lib "ai_tools_help__render_hint ${program} '${path}'")"
    if grep -qxF "  ${want} [ARGUMENT...] [OPTION...]" <<< "${out}"; then pass "${program} ${path}: the usage line is '${want} ...'"
    else fail "${program} ${path}: the usage line is not '${want} ...': ${out}"; fi
done
# The stop hint carries its consequence and the preview command under the description.
for pair in "ai-tools|atr stop --dry-run" "ai-tools-admin|atr admin stop --dry-run"; do
    out="$(lib "ai_tools_help__render_hint ${pair%%|*} stop")"
    if grep -qxF "A stopped session's session-end handback does not run." <<< "${out}" \
            && grep -qxF "To preview: ${pair#*|}" <<< "${out}"; then
        pass "${pair%%|*} stop: the hint names the skipped handback and '${pair#*|}'"
    else
        fail "${pair%%|*} stop: the hint lacks the handback line or the preview: ${out}"
    fi
done
out="$(lib "ai_tools_help__render_hint ai-tools status")"
if ! grep -q 'To preview' <<< "${out}"; then pass "a hint without notes carries none (status)"
else fail "the status hint carries a note: ${out}"; fi

top="$(lib 'ai_tools_help__render ai-tools')"
if [[ "${top}" == *"Agent Tools Restricted -- operator commands (ai-tools)"* \
        && "${top}" == *"  projects [list]                List the registered projects and sandbox clones"* \
        && "${top}" == *"      --for OPERATOR             Act on another enrolled operator's projects"* ]]; then
    pass "the ai-tools help carries its title, the [list] row and the option column the spec states"
else
    fail "the ai-tools help is not the stated text: ${top}"
fi

# The same heading with the trust predicate stubbed, so it runs unprivileged: the discovery splits rows of its own while
# the renderer is between blocks.
stubbed="${TESTDIR}/stubbed"
install -d "${stubbed}"
: > "${stubbed}/demo"; : > "${stubbed}/stop"
admin="$(lib "ai_tools_conf__is_trusted() { return 0; }; ai_tools_help__render ai-tools-admin '${stubbed}'" 2>/dev/null)"
if [[ "${admin}" == *$'  demo COMMAND'*$'\n\nOptions:\n  -h, --help'* ]]; then
    pass "with a refused base-name fragment after a domain, the block after the domains is headed Options:"
else
    fail "the heading after the domain block changed (stubbed predicate): ${admin}"
fi

if [[ "${EUID}" -eq 0 ]]; then
    fixture="${TESTDIR}/domains"
    MANIFESTS="${TESTDIR}/integrations.d"
    install -d -o root -g root -m 755 "${fixture}" "${MANIFESTS}"
    printf '#!/bin/sh\nexit 0\n' > "${fixture}/demo"; chown root:root "${fixture}/demo"; chmod 750 "${fixture}/demo"
    printf 'default_enable=no\nadmin_summary=Provision the demo state\n' > "${MANIFESTS}/demo.conf"
    chown root:root "${MANIFESTS}/demo.conf"; chmod 644 "${MANIFESTS}/demo.conf"
    admin="$(lib "ai_tools_help__render ai-tools-admin '${fixture}'" 2>/dev/null)"
    within80 "the ai-tools-admin help with a trusted domain" "${admin}"
    if [[ "${admin}" == *$'Provider commands:\n  demo COMMAND                    Provision the demo state'* ]]; then
        pass "a trusted domain is listed with its manifest summary at the admin column"
    else
        fail "the trusted domain is not listed as stated: ${admin}"
    fi
    if [[ "${admin}" != *"(refused:"* ]]; then pass "no refusal line while every fragment is trusted"
    else fail "a refusal line beside trusted fragments alone"; fi
    status=0
    out="$(lib "ai_tools_help__resolve_request ai-tools-admin '${fixture}' -- demo --help" 2>/dev/null)" || status=$?
    if [[ "${status}" -eq 3 && "${out}" == demo ]]; then pass "a help request on a discovered domain is status 3"
    else fail "a help request on a discovered domain: status ${status}, '${out}'"; fi
    # A domain named with a digit is a domain to the resolver as it is to the discovery.
    printf '#!/bin/sh\nexit 0\n' > "${fixture}/agent2"; chown root:root "${fixture}/agent2"; chmod 750 "${fixture}/agent2"
    status=0
    out="$(lib "ai_tools_help__resolve_request ai-tools-admin '${fixture}' -- agent2 --help" 2>/dev/null)" || status=$?
    if [[ "${status}" -eq 3 && "${out}" == agent2 ]]; then pass "a help request on a digit-bearing domain is status 3"
    else fail "a help request on agent2: status ${status}, '${out}'"; fi
    # A fragment carrying a base name sorts after the trusted ones and is refused; the block after the domains is still
    # headed Options:, which the discovery's own row reads must not change.
    printf '#!/bin/sh\nexit 0\n' > "${fixture}/stop"; chown root:root "${fixture}/stop"; chmod 750 "${fixture}/stop"
    admin="$(lib "ai_tools_help__render ai-tools-admin '${fixture}'" 2>/dev/null)"
    if [[ "${admin}" == *$'\n\nOptions:\n  -h, --help'* && "$(grep -c '^Incident:$' <<< "${admin}")" -eq 1 ]]; then
        pass "a refused base-name fragment leaves the Options: heading after the domain block"
    else
        fail "the heading after the domain block changed: ${admin}"
    fi
    rm -f "${fixture}/agent2" "${fixture}/stop"
    printf '#!/bin/sh\nexit 0\n' > "${fixture}/weak"; chown root:root "${fixture}/weak"; chmod 770 "${fixture}/weak"
    # The help is stdout; the discovery's warning is stderr, read apart, so the width is the help's alone.
    admin="$(lib "ai_tools_help__render ai-tools-admin '${fixture}'" 2> "${TESTDIR}/warning")"
    within80 "the ai-tools-admin help with the refusal line" "${admin}"
    if [[ "${admin}" == *"  demo COMMAND"* && "${admin}" == *"  (refused: a file there is not root's alone -- see the warning above)"* \
            && "$(cat "${TESTDIR}/warning")" == *MSG-D3P6* ]]; then
        pass "a group-writable fragment beside a trusted one adds the refusal line and its warning"
    else
        fail "the refusal line or its warning is missing: ${admin}"
    fi
    unset MANIFESTS
else
    skip "the admin help over a fixture domain directory" "the trust predicate accepts root-owned files alone; run as root"
fi

# ── The resolver ──────────────────────────────────────────────────────────────────────────────
# resolves <program> <status> <target> <arg>...: the resolver reads the command line with that status and target.
resolves() {
    local program="$1" want_status="$2" want_target="$3" status=0 out quoted
    shift 3
    quoted=""
    (( $# == 0 )) || printf -v quoted ' %q' "$@"
    out="$(lib "ai_tools_help__resolve_request ${program} /nonexistent --${quoted}")" || status=$?
    if [[ "${status}" -eq "${want_status}" && "${out}" == "${want_target}" ]]; then
        pass "${program}${quoted:- (empty)}: status ${status}, '${out}'"
    else
        fail "${program}${quoted:- (empty)}: status ${status}, '${out}', expected ${want_status}, '${want_target}'"
    fi
}
resolves ai-tools 0 -
resolves ai-tools 0 - --help
resolves ai-tools 0 - -h
resolves ai-tools 0 - help
resolves ai-tools 0 "projects claim" help projects claim
resolves ai-tools 0 projects help projects
resolves ai-tools 0 projects projects help
resolves ai-tools 0 projects projects --help
resolves ai-tools 0 "projects claim" projects claim --help
resolves ai-tools 0 "projects claim" projects claim . -h
resolves ai-tools 0 "projects claim" projects claim foo --help
resolves ai-tools 0 "projects claim" -h projects claim
resolves ai-tools 0 "projects list" projects list --help
resolves ai-tools 0 stop stop --dry-run --help
resolves ai-tools 0 "projects claim" projects claim --format --help
resolves ai-tools 1 "" projects claim help
resolves ai-tools 1 "" projects claim .
resolves ai-tools 1 "" stop -- --help
resolves ai-tools 1 "" --version
resolves ai-tools 1 "" --version --help
resolves ai-tools 1 "" --version -h
resolves ai-tools 0 - --help --version
resolves ai-tools 2 bogus1 bogus1 --help
resolves ai-tools 0 providers providers help
resolves ai-tools 0 "providers list" providers list -h
resolves ai-tools 2 "providers bogus" providers bogus --help
resolves ai-tools 0 status status foo --help
resolves ai-tools 1 "" projects bogus
resolves ai-tools 2 "projects bogus" projects bogus --help
resolves ai-tools 2 "projects bogus" help projects bogus
resolves ai-tools 2 bogus bogus --help
resolves ai-tools 2 bogus help bogus
# The claim's owner-side read is dispatched and has no help row, so a help request on it is an unknown path, and a line
# without a help flag reaches the dispatch; the claim puts `--` ahead of the path, so a path spelled `-h` stays a path.
resolves ai-tools 2 "projects inspect" projects inspect --help
resolves ai-tools 2 "projects inspect" help projects inspect
resolves ai-tools 1 "" projects inspect --verify -- /p
resolves ai-tools 1 "" projects inspect -- -h
resolves ai-tools-admin 0 -
resolves ai-tools-admin 0 "operators add" operators add --help
resolves ai-tools-admin 1 "" operators add help
resolves ai-tools-admin 0 "selinux groups" selinux groups help
resolves ai-tools-admin 0 system system help
resolves ai-tools-admin 0 "system layout" system layout help
resolves ai-tools-admin 0 "system layout" system layout --check -h
resolves ai-tools-admin 0 "system layout list" system layout list -h
resolves ai-tools-admin 0 stop help stop
resolves ai-tools-admin 2 "assets bogus" assets bogus --help
resolves ai-tools-admin 2 "assets bogus" help assets bogus
resolves ai-tools-admin 2 bogus bogus --help
resolves ai-tools-admin 2 bogus help bogus
resolves ai-tools-admin 1 "" bogus

# ── The help command an unknown command names, and the reserved names ────────────────────────
formats() {
    local out
    out="$(lib "ai_tools_help__format_help_command $1 '$2'")"
    if [[ "${out}" == "$3" ]]; then pass "$1 '$2' names '${out}'"
    else fail "$1 '$2' names '${out}', expected '$3'"; fi
}
formats ai-tools bogus "atr help"
formats ai-tools "projects bogus" "atr projects help"
formats ai-tools '/tmp/*' "atr help"
formats ai-tools-admin bogus "atr admin help"
formats ai-tools-admin "assets bogus" "atr admin assets help"
formats ai-tools-admin "system layout bogus" "atr admin system layout help"
reserved=""
for name in operators selinux system status assets stop help; do
    lib "ai_tools_help__is_base_command ${name}" || reserved+="${name} "
done
if [[ -z "${reserved}" ]]; then pass "each base first word, stop and help are reserved"
else fail "base name(s) not reserved: ${reserved}"; fi
if lib "ai_tools_help__is_base_command dotnet"; then fail "a name no row holds (dotnet) reads as reserved"
else pass "a name no row holds (dotnet) is not reserved"; fi

# ── A library whose conf.lib.sh is unreachable ───────────────────────────────────────────────
install -d "${TESTDIR}/lonely"
cp "${LIB}" "${TESTDIR}/lonely/help.lib.sh"
status=0
defined="$(bash -c 'source "$1"; rc=$?; declare -F ai_tools_help__render >/dev/null && echo defined; exit "${rc}"' \
    _ "${TESTDIR}/lonely/help.lib.sh")" || status=$?
if [[ "${status}" -ne 0 && -z "${defined}" ]]; then
    pass "a copy without conf.lib.sh beside it returns non-zero at source and defines no function"
else
    fail "a copy without conf.lib.sh loaded (status ${status}, ${defined:-nothing defined})"
fi

finish

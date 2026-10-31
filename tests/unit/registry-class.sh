#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/registry-class.sh
# The registry classifier in conf.lib.sh (ai_tools_conf__read_registry_path_class), which every `projects` verb decides
# from, driven as a table: one fixture registry per shape a host meets, one row per (fixture, path) asserting every
# field of the record and the state. The set of states the rows reach is asserted equal to the seven the classifier
# names, so a state added to the library without rows fails this file, and so does a row naming a state the library does
# not derive. `blocked` names the first line in file order, which a pair of fixtures holding the same lines in both
# orders pins. The table runs under the launch wrapper's IFS, the shell the CLI and the wrapper read the record in.
# ai_tools_conf__list_registry_entries_under closes the file.
#
# Pure: it reads the checkout's library where it runs from one, and the installed library otherwise, and runs without
# root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/src/usr/local/lib/ai-tools/conf.lib.sh"
[[ -r "${LIB}" ]] || LIB="/usr/local/lib/ai-tools/conf.lib.sh"
section "registry classifier (unit)"

# shellcheck source=/dev/null
if ! source "${LIB}" 2>/dev/null || ! declare -F ai_tools_conf__read_registry_path_class >/dev/null 2>&1; then
    fail "${LIB} does not define ai_tools_conf__read_registry_path_class"; finish; exit
fi

mktestdir
T="${TESTDIR}/tree"
mkdir -p "${T}"/A/vendor/x "${T}"/A/sub "${T}"/A/src "${T}"/B/child/y "${T}"/B/x "${T}"/C/n/z "${T}"/D/q \
         "${T}"/G/m/cache "${T}/H dir" "${T}"/I "${T}"/J/k "${T}"/K "${T}"/L/m/n "${T}"/M "${T}"/N/o "${T}/P dir#1/q" "${T}"/zzz
ln -s "${T}/K" "${T}/K-link"

# fixture <name> <line>... : write the registry <name>, the marker first.
fixture() {
    local name="$1"; shift
    printf '%s\n' "# ai-tools-project-registry-format: 1.0" "$@" > "${TESTDIR}/${name}"
}
fixture nested-carve   "${T}/A" "!${T}/A/vendor" "${T}/A/sub"
fixture parked-parent  "%${T}/B" "${T}/B/child" "!${T}/B/x"
fixture nested-park    "${T}/C" "%${T}/C/n"
fixture conflict       "${T}/D" "!${T}/D"
fixture stale-allow    "${T}/E-gone"
fixture stale-park     "%${T}/F-gone"
fixture glob           "${T}/G" "!${T}/G/*/cache"
fixture quoted         "\"${T}/H dir\""
fixture commented      "${T}/I   # a note" "# ${T}/zzz"
fixture lone-carve     "!${T}/J"
fixture symlink        "${T}/K-link"
fixture carve-first    "!${T}/L" "%${T}/L/m"
fixture park-first     "%${T}/L/m" "!${T}/L"
fixture duplicate-pair "${T}/M" "%${T}/M"
# A tab before a comment is whitespace to the grammar; in the record it would split a field, so `blocked` shows it `?`.
fixture tab-comment    "%${T}/N"$'\t'"# parked" "${T}/N/o"
# A park whose path carries a space and a '#' is quoted; blocked_path is the path the quotes hold.
fixture space-hash     "%\"${T}/P dir#1\""

# The table: fixture | path | state | own | enclosing | enclosing_state | blocked | blocked_kind | nested
# | blocked_path, with @ for the fixture tree.
TABLE="$(cat <<'ROWS'
nested-carve   | @/A          | listed       | allow       | -         | -        | -             | -     | 1 | -
nested-carve   | @/A/vendor   | carve-out    | carve       | @/A       | listed   | -             | -     | 0 | -
nested-carve   | @/A/vendor/x | inside       | none        | @/A       | listed   | !@/A/vendor   | carve | 0 | @/A/vendor
nested-carve   | @/A/sub      | listed       | allow       | @/A       | listed   | -             | -     | 0 | -
nested-carve   | @/A/src      | inside       | none        | @/A       | listed   | -             | -     | 0 | -
nested-carve   | @            | ancestor     | none        | -         | -        | -             | -     | 2 | -
nested-carve   | @/zzz        | unregistered | none        | -         | -        | -             | -     | 0 | -
parked-parent  | @/B          | parked       | park        | -         | -        | -             | -     | 1 | -
parked-parent  | @/B/child    | listed       | allow       | @/B       | parked   | %@/B          | park  | 0 | @/B
parked-parent  | @/B/x        | carve-out    | carve       | @/B       | parked   | %@/B          | park  | 0 | @/B
parked-parent  | @/B/child/y  | inside       | none        | @/B/child | listed   | %@/B          | park  | 0 | @/B
nested-park    | @/C          | listed       | allow       | -         | -        | -             | -     | 1 | -
nested-park    | @/C/n        | parked       | park        | @/C       | listed   | -             | -     | 0 | -
nested-park    | @/C/n/z      | inside       | none        | @/C/n     | parked   | %@/C/n        | park  | 0 | @/C/n
conflict       | @/D          | conflict     | allow,carve | -         | -        | -             | -     | 0 | -
conflict       | @/D/q        | inside       | none        | @/D       | conflict | !@/D          | carve | 0 | @/D
stale-allow    | @/E-gone     | listed       | allow       | -         | -        | -             | -     | 0 | -
stale-park     | @/F-gone     | parked       | park        | -         | -        | -             | -     | 0 | -
glob           | @/G/m        | inside       | none        | @/G       | listed   | -             | -     | 0 | -
glob           | @/G/m/cache  | inside       | none        | @/G       | listed   | !@/G/*/cache  | glob  | 0 | @/G/*/cache
quoted         | @/H dir      | listed       | allow       | -         | -        | -             | -     | 0 | -
commented      | @/I          | listed       | allow       | -         | -        | -             | -     | 0 | -
commented      | @/zzz        | unregistered | none        | -         | -        | -             | -     | 0 | -
lone-carve     | @/J          | carve-out    | carve       | -         | -        | -             | -     | 0 | -
lone-carve     | @/J/k        | unregistered | none        | -         | -        | !@/J          | carve | 0 | @/J
symlink        | @/K          | listed       | allow       | -         | -        | -             | -     | 0 | -
carve-first    | @/L/m/n      | inside       | none        | @/L/m     | parked   | !@/L          | carve | 0 | @/L
park-first     | @/L/m/n      | inside       | none        | @/L/m     | parked   | %@/L/m        | park  | 0 | @/L/m
duplicate-pair | @/M          | parked       | allow,park  | -         | -        | -             | -     | 0 | -
tab-comment    | @/N/o        | listed       | allow       | @/N       | parked   | %@/N?# parked | park  | 0 | @/N
space-hash     | @/P dir#1/q  | inside       | none        | @/P dir#1 | parked   | %"@/P dir#1"  | park  | 0 | @/P dir#1
ROWS
)"
readonly DECLARED_STATES="ancestor carve-out conflict inside listed parked unregistered"

# trim <text> : print <text> without leading or trailing spaces.
trim() { local t="$1"; t="${t#"${t%%[! ]*}"}"; printf '%s' "${t%"${t##*[! ]}"}"; }

declare -A seen_states=()
saved_ifs="${IFS}"; IFS=$'\n\t'
while IFS='|' read -r fx path want_state want_own want_enc want_enc_state want_blocked want_kind want_nested \
        want_blocked_path; do
    fx="$(trim "${fx}")"; path="$(trim "${path//@/${T}}")"
    want="$(trim "${want_state}")"$'\t'"$(trim "${want_own}")"$'\t'"$(trim "${want_enc//@/${T}}")"$'\t'"$(trim "${want_enc_state}")"
    want+=$'\t'"$(trim "${want_blocked//@/${T}}")"$'\t'"$(trim "${want_kind}")"$'\t'"$(trim "${want_nested}")"
    want+=$'\t'"$(trim "${want_blocked_path//@/${T}}")"
    rc=0; got="$(ai_tools_conf__read_registry_path_class "${TESTDIR}/${fx}" "${path}" 2>&1)" || rc=$?
    seen_states["$(trim "${want_state}")"]=1
    if [[ "${rc}" -eq 0 && "${got}" == "${want}" ]]; then
        pass "${fx}: ${path#"${TESTDIR}/"} reads ${got%%$'\t'*}"
    else
        fail "${fx}: ${path#"${TESTDIR}/"}: rc ${rc}, got '${got//$'\t'/|}', expected '${want//$'\t'/|}'"
    fi
done <<< "${TABLE}"
IFS="${saved_ifs}"

table_states="$(printf '%s\n' "${!seen_states[@]}" | sort | tr '\n' ' ')"
if [[ "${table_states% }" == "${DECLARED_STATES}" ]]; then
    pass "the rows reach every state the classifier names, and no other"
else
    fail "the rows reach '${table_states% }', the classifier names '${DECLARED_STATES}'"
fi
# The states the library declares are the ones its header table lists; a state added there without rows fails here.
lib_states="$(sed -n '/^# ── Registry classification/,/^# The launch DECISION/p' "${LIB}" \
    | sed -n 's/^#   \([a-z-]*\) .*/\1/p' | grep -v '^state$' | sort | tr '\n' ' ')"
if [[ "${lib_states% }" == "${DECLARED_STATES}" ]]; then
    pass "the library's state table names the seven states this file covers"
else
    fail "the library's state table names '${lib_states% }'"
fi

# A refused file and a missing one print nothing: 3 and 1.
fixture refused "${T}/A" "relative/line"
rc=0; out="$(ai_tools_conf__read_registry_path_class "${TESTDIR}/refused" "${T}/A" 2>/dev/null)" || rc=$?
if [[ "${rc}" -eq 3 && -z "${out}" ]]; then pass "a refused registry classifies no path (3)"; else fail "a refused registry: rc ${rc}, '${out}'"; fi
rc=0; out="$(ai_tools_conf__read_registry_path_class "${TESTDIR}/absent" "${T}/A" 2>/dev/null)" || rc=$?
if [[ "${rc}" -eq 1 && -z "${out}" ]]; then pass "a missing registry classifies no path (1)"; else fail "a missing registry: rc ${rc}, '${out}'"; fi

# One open per read: a `tr` standing in for the control-byte scan renames a replacement over the registry once the scan
# has opened the file. The classifier reads the inode it opened, so a replacement holding /pri<NUL>vate, which `read`
# takes as /private, is not read; the same stub with no replacement waiting is the control.
mkdir -p "${T}/private"
printf '%s\n%s\0%s\n' "# ai-tools-project-registry-format: 1.0" "${T}/pri" "vate" > "${TESTDIR}/pinned.next"
# pinned_state <path> : the state the classifier reads for <path> over the fixture `pinned`, under the renaming stub.
pinned_state() {
    fixture pinned "${T}/A"
    ( tr() { if [[ -e "${TESTDIR}/pinned.next" ]]; then mv -f -- "${TESTDIR}/pinned.next" "${TESTDIR}/pinned"; fi
             command tr "$@"; }
      ai_tools_conf__read_registry_path_class "${TESTDIR}/pinned" "$1" ) 2>/dev/null | cut -f1
}
got="$(pinned_state "${T}/private")"
if [[ -e "${TESTDIR}/pinned.next" ]] || ! grep -qaF "vate" "${TESTDIR}/pinned"; then
    fail "one open per read: the stub did not rename the replacement over the registry"
elif [[ "${got}" == unregistered ]]; then
    pass "one open per read: a replacement renamed in after the open is not classified, /private reads unregistered"
else
    fail "one open per read: /private reads '${got}' from the replacement"
fi
got="$(pinned_state "${T}/A")"
if [[ "${got}" == listed ]]; then pass "one open per read: the control, the stub renaming nothing, reads the original"; else fail "one open per read: the control reads '${got}'"; fi

# ── ai_tools_conf__list_registry_entries_under ───────────────────────────────────────────────
under_is() {   # under_is <fixture> <path> <expected, one `path<TAB>state` per line> <desc>
    local got rc=0
    got="$(ai_tools_conf__list_registry_entries_under "${TESTDIR}/$1" "$2" 2>&1)" || rc=$?
    if [[ "${rc}" -eq 0 && "${got}" == "$3" ]]; then pass "$4"; else fail "$4: rc ${rc}, got '${got//$'\n'/; }'"; fi
}
under_is nested-carve "${T}" "${T}/A"$'\t'"listed"$'\n'"${T}/A/sub"$'\t'"listed" \
    "entries under an ancestor, in file order, the carve-out left out"
under_is parked-parent "${T}/B" "${T}/B/child"$'\t'"listed" "a parked project's nested entry is listed under it"
under_is conflict "${T}" "${T}/D"$'\t'"conflict" "a conflict entry is listed with its state"
under_is duplicate-pair "${T}" "${T}/M"$'\t'"parked" "a path named by two lines is one entry"
under_is lone-carve "${T}" "" "a carve-out alone is not an entry"

finish

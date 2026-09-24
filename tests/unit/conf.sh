#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/conf.sh
# Unit test for the shared config grammar (conf.lib.sh) -- the one parser behind every key
# in /etc/ai-tools/operator.conf and every provider manifest. Two contracts are pinned here:
#
#   1. THE GRAMMAR: quotes optional, commas and whitespace both separate list items, inline
#      comments end a value, a present-but-empty key is distinguishable from an absent one. A
#      drift here silently changes what an operator's config means on every host.
#   2. IFS INDEPENDENCE: the splitter must yield the same items whatever IFS the sourcing script
#      runs under. nvm-update.sh and claude.sh legitimately set IFS=$'\n\t'; a splitter that
#      inherited it would read "a b" as ONE item, which for the provider allowlists reads as
#      "no such provider" -- a wrong verdict that disables a configured agent silently.
#   3. THE TRUST PREDICATE: the gate behind "the sandbox cannot widen its own surface". A file or
#      directory that is not root-owned, or is group/other-writable, or is a symlink, must be
#      refused -- those are exactly the states a non-root writer can create.
#   4. THE REFUSAL TEXT: a refusal reports the owner uid and mode the predicate read, and names a
#      user namespace that translates uids when that is why the owner check failed -- the state
#      in which every input is correct on disk and reads as 65534.
#
# Hermetic: /tmp fixtures with known content, no network, no daemon, no host config read.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/conf.lib.sh"
section "conf: shared KEY=value grammar + trust predicate (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "conf" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" \
        || ! declare -F ai_tools_conf_read >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_split >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_list >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_list_value >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_set_list >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_allowlist_has_entry >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_is_trusted >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the parser functions"; finish; exit
fi

mktestdir
conf="${TESTDIR}/operator.conf"

# --- Grammar: one fixture exercising every documented form -----------------------------------
cat > "${conf}" <<'EOF'
# a whole-line comment
BARE=plain
QUOTED="a b c"
SQUOTED='a b c'
SPACED   =   padded value
COMMENTED=value    # why this value
HASH_IN_QUOTES="keep # this"
HASH_INTERIOR=csharp#7
EMPTY=
LIST=a, b  c ,d
not an assignment line
REPEATED=first
REPEATED=last
EOF

check_value() {
    local desc="$1" key="$2" expected="$3"
    local got; got="$(ai_tools_conf_get "${conf}" "${key}" || true)"
    if [[ "${got}" == "${expected}" ]]; then pass "${desc}"
    else fail "${desc}: got '${got}' expected '${expected}'"; fi
}
check_value "unquoted value"                       BARE          "plain"
check_value "double quotes stripped"               QUOTED        "a b c"
check_value "single quotes stripped"               SQUOTED       "a b c"
check_value "whitespace around key and = trimmed"  SPACED        "padded value"
check_value "inline comment ends the value"        COMMENTED     "value"
check_value "# inside quotes stays literal"        HASH_IN_QUOTES "keep # this"
check_value "interior # is not a comment"          HASH_INTERIOR "csharp#7"
check_value "repeated key takes the last"          REPEATED      "last"

# Present-but-empty vs absent: the distinction the fail-closed provider gating turns on.
if ai_tools_conf_read "${conf}" EMPTY && [[ -z "${_ai_tools_conf_value}" ]]; then
    pass "present-but-empty key reads as PRESENT with an empty value"
else
    fail "present-but-empty key did not read as present"
fi
if ! ai_tools_conf_read "${conf}" NO_SUCH_KEY; then
    pass "absent key reads as ABSENT (distinct from present-and-empty)"
else
    fail "absent key reported as present"
fi
if ! ai_tools_conf_read "${conf}" "not an assignment line"; then
    pass "a line with no '=' is ignored"
else
    fail "a line with no '=' was parsed as a key"
fi
if ! ai_tools_conf_read "${TESTDIR}/does-not-exist" BARE; then
    pass "unreadable file reads as absent"
else
    fail "unreadable file reported a value"
fi

# --- Splitting: separators, runs, and IFS independence ---------------------------------------
# split_under_ifs <ifs> <value> : the items, joined by '|', from a SUBSHELL running under <ifs>, so the caller's own IFS
# cannot mask a dependency.
split_under_ifs() {
    local ifs="$1" value="$2"
    ( IFS="${ifs}"; local -a out=(); ai_tools_conf_split out "${value}"
      local joined="" item
      for item in "${out[@]}"; do joined+="${item}|"; done
      printf '%s' "${joined}" )
}
check_split() {
    local desc="$1" expected="$2" value="$3" ifs="${4-$' \t\n'}"
    local got; got="$(split_under_ifs "${ifs}" "${value}")"
    if [[ "${got}" == "${expected}" ]]; then pass "${desc}"
    else fail "${desc}: got '${got}' expected '${expected}'"; fi
}
check_split "whitespace separates"            "a|b|c|" "a b c"
check_split "commas separate"                 "a|b|c|" "a,b,c"
check_split "commas and whitespace mix"       "a|b|c|" "a, b  c"
check_split "runs collapse, empties dropped"  "a|b|c|" "  a ,,  b ,c  ,"
check_split "empty value yields no items"     ""       ""
check_split "single item"                     "a|"     "a"
# The regression: the same values under the strict-mode IFS the launcher scripts set.
check_split "whitespace splits under IFS=\$'\\n\\t'" "a|b|c|" "a b c"    $'\n\t'
check_split "commas split under IFS=\$'\\n\\t'"      "a|b|c|" "a,b,c"    $'\n\t'
check_split "mixed splits under IFS=\$'\\n\\t'"      "a|b|c|" "a, b  c"  $'\n\t'
# A value containing a glob must not be pathname-expanded into filenames.
check_split "glob in a value is not expanded"  "*|" "*"

# --- ai_tools_conf_list: a present key REPLACES, an absent key LEAVES the default ------------
declare -a target=(default-one default-two)
if ai_tools_conf_list target "${conf}" LIST && [[ "${target[*]}" == "a b c d" ]]; then
    pass "present key replaces the array"
else
    fail "present key did not replace: got '${target[*]}'"
fi
target=(default-one default-two)
if ! ai_tools_conf_list target "${conf}" NO_SUCH_KEY && [[ "${target[*]}" == "default-one default-two" ]]; then
    pass "absent key leaves the caller's default untouched"
else
    fail "absent key clobbered the default: got '${target[*]}'"
fi
target=(default-one default-two)
if ai_tools_conf_list target "${conf}" EMPTY && [[ "${#target[@]}" -eq 0 ]]; then
    pass "present-but-empty key replaces with an empty array (an explicit none)"
else
    fail "present-but-empty key did not empty the array: got '${target[*]:-}'"
fi

# --- List values read from a file: the plain form, the bracketed form, and the invalid ones --------------------------
# One row per value, `<expected items joined by |>` then the value exactly as it follows `K=` in the file, split
# on the first tab. An invalid value reads as the EMPTY list and is reported under its code, so its expected column is
# `INVALID`: empty is the less-access reading for a list that enrols or enables something, where absent would fall back
# to a default that enables more.
list_cases=(
    $'a|b|c|\ta, b c'
    $'a|b|c|\t"a, b c"'
    $'a|b|\t\'a b\''
    $'a|b|\t[a, b]'
    $'a|b|\t[a,b]'
    $'a|\t[, a]'
    $'a|\t[a,]'
    $'a|\t[ a]'
    $'a|b|\t  [a, b]   # why'
    $'\t'
    $'\t""'
    $'\t[]'
    $'\t[ ,,  , ]'
    $'INVALID\t['
    $'INVALID\ta]'
    $'INVALID\t"[a]"'
    $'INVALID\t\'[a]\''
    $'INVALID\t["a b"]'
    $'INVALID\t[a, "b"]'
    $'INVALID\t[a]]'
    $'INVALID\t[[a]'
    $'INVALID\t"[a'
)
list_conf="${TESTDIR}/list.conf"
for row in "${list_cases[@]}"; do
    expected="${row%%$'\t'*}"; value="${row#*$'\t'}"
    printf 'K=%s\n' "${value}" > "${list_conf}"
    # Driven under the strict-mode IFS the launcher scripts set, in a subshell so the caller's IFS cannot mask it.
    # shellcheck disable=SC2154  # _ai_tools_conf_list_invalid is set by conf.lib.sh, sourced at the top of this file
    said="$( IFS=$'\n\t'; target=(default); ai_tools_conf_list target "${list_conf}" K 2>&1 >/dev/null
             joined=""; for item in "${target[@]}"; do joined+="${item}|"; done
             printf '\nITEMS=%s\nINVALID=%s\n' "${joined}" "${_ai_tools_conf_list_invalid}" )"
    got="$(sed -n 's/^ITEMS=//p' <<< "${said}")"
    invalid="$(sed -n 's/^INVALID=//p' <<< "${said}")"
    if [[ "${expected}" == INVALID ]]; then
        if [[ -z "${got}" && "${invalid}" == 1 ]] && grep -qx MSG-D5N5 <<< "${said}"; then
            pass "list K=${value} is invalid: read as empty, reported"
        else
            fail "list K=${value} should read as empty with MSG-D5N5: got '${got}', invalid=${invalid}"
        fi
    elif [[ "${got}" == "${expected}" && "${invalid}" == 0 ]] && ! grep -q '^MSG-' <<< "${said}"; then
        pass "list K=${value} reads as '${expected}'"
    else
        fail "list K=${value}: got '${got}' (invalid=${invalid}) expected '${expected}'"
    fi
done

# A command-line argument keeps the plain splitter, which does not read brackets: the caller that takes an argument
# refuses one carrying a bracket by name, so the splitter reading them would hide that refusal.
check_split "the argument splitter leaves brackets in the items" "[a|b]|" "[a, b]"

# --- ai_tools_conf_kind_list: a provider list item carries its kind --------------------------------------------------
# Each key in the kind table takes items written <prefix><name> and hands its caller the bare names. An item without
# its key's prefix -- the bare name an earlier release wrote, another kind's prefix, the prefix alone, a traversal after
# it -- makes the whole list read as empty under MSG-X6F2, the less-access reading; a list the grammar refuses keeps
# its own code; an absent key returns 1 with the caller's array untouched. Rows: <KEY> <line> <expected>, where
# the expected value is the items joined by `|`, INVALID:<code>, or ABSENT.
kind_conf="${TESTDIR}/kind.conf"
while IFS=$'\t' read -r key line expected; do
    printf '%s\n' "${line}" > "${kind_conf}"
    said="$( IFS=$'\n\t'; target=(default); rc=0
             ai_tools_conf_kind_list target "${kind_conf}" "${key}" 2>&1 >/dev/null || rc=$?
             joined=""; for item in "${target[@]}"; do joined+="${item}|"; done
             printf '\nITEMS=%s\nRC=%s\nINVALID=%s\n' "${joined}" "${rc}" "${_ai_tools_conf_list_invalid}" )"
    got="$(sed -n 's/^ITEMS=//p' <<< "${said}")"; rc="$(sed -n 's/^RC=//p' <<< "${said}")"
    invalid="$(sed -n 's/^INVALID=//p' <<< "${said}")"
    case "${expected}" in
        ABSENT)    [[ "${rc}" == 1 && "${got}" == "default|" ]] ;;
        INVALID:*) [[ "${rc}" == 0 && -z "${got}" && "${invalid}" == 1 ]] && grep -qx "${expected#INVALID:}" <<< "${said}" ;;
        *)         [[ "${rc}" == 0 && "${got}" == "${expected}" && "${invalid}" == 0 ]] && ! grep -q '^MSG-' <<< "${said}" ;;
    esac && pass "kind list ${line} (${key}) reads as ${expected}" \
         || fail "kind list ${line} (${key}): expected ${expected}, got items '${got}' rc=${rc} invalid=${invalid} (${said//$'\n'/ })"
done <<'ROWS'
AI_TOOLS_AGENTS	AI_TOOLS_AGENTS=[agent-claude-code, agent-codex]	claude-code|codex|
AI_TOOLS_AGENTS	AI_TOOLS_AGENTS="agent-claude-code agent-codex"	claude-code|codex|
AI_TOOLS_INTEGRATIONS	AI_TOOLS_INTEGRATIONS=[integration-dotnet]	dotnet|
AI_TOOLS_FILTERS	AI_TOOLS_FILTERS=[filter-dotnet, filter-a.b_c]	dotnet|a.b_c|
AI_TOOLS_AGENTS	AI_TOOLS_AGENTS=[]
AI_TOOLS_AGENTS	OPERATORS=[x]	ABSENT
AI_TOOLS_AGENTS	AI_TOOLS_AGENTS=[claude-code]	INVALID:MSG-X6F2
AI_TOOLS_AGENTS	AI_TOOLS_AGENTS=[agent-claude-code, codex]	INVALID:MSG-X6F2
AI_TOOLS_AGENTS	AI_TOOLS_AGENTS=[integration-dotnet]	INVALID:MSG-X6F2
AI_TOOLS_INTEGRATIONS	AI_TOOLS_INTEGRATIONS=[filter-dotnet]	INVALID:MSG-X6F2
AI_TOOLS_FILTERS	AI_TOOLS_FILTERS=[core, dotnet]	INVALID:MSG-X6F2
AI_TOOLS_AGENTS	AI_TOOLS_AGENTS=[agent-]	INVALID:MSG-X6F2
AI_TOOLS_AGENTS	AI_TOOLS_AGENTS=agent-..	INVALID:MSG-X6F2
AI_TOOLS_AGENTS	AI_TOOLS_AGENTS=[agent-claude-code	INVALID:MSG-D5N5
ROWS
if ai_tools_conf_kind_list target "${kind_conf}" OPERATORS 2>/dev/null; then
    fail "ai_tools_conf_kind_list accepted a key outside the kind table"
else
    pass "ai_tools_conf_kind_list refuses a key outside the kind table"
fi

# ai_tools_conf_kind_item is the writer's side: a bare name gains the prefix, a prefixed one is kept, and a name that is
# not a plain name once prefixed, or a key outside the table, prints nothing. Rows: <KEY> <name> <expected|REFUSED>.
while IFS=$'\t' read -r key name expected; do
    got="$(ai_tools_conf_kind_item "${key}" "${name}")" && rc=0 || rc=$?
    if [[ "${expected}" == REFUSED ]]; then
        [[ "${rc}" != 0 && -z "${got}" ]]
    else
        [[ "${rc}" == 0 && "${got}" == "${expected}" ]]
    fi && pass "kind item ${key} ${name} -> ${expected}" || fail "kind item ${key} ${name}: got '${got}' rc=${rc}, expected ${expected}"
done <<'ROWS'
AI_TOOLS_AGENTS	codex	agent-codex
AI_TOOLS_AGENTS	agent-codex	agent-codex
AI_TOOLS_FILTERS	dotnet	filter-dotnet
AI_TOOLS_AGENTS	../x	REFUSED
AI_TOOLS_AGENTS	a b	REFUSED
OPERATORS	x	REFUSED
ROWS

# ai_tools_conf_kind_unmigrated is the one detection predicate: it prints every item without its key's prefix, keyed,
# and prints nothing for a clean file, a list the grammar refuses, or a file the trust predicate refuses. The listing
# half needs a root-owned fixture, so it is driven where this runs as root; unprivileged, the fixture is untrusted
# and prints nothing either way, which is asserted as the refusal direction.
printf '%s\n' 'AI_TOOLS_AGENTS=[claude-code, agent-codex]' 'AI_TOOLS_INTEGRATIONS=[integration-dotnet]' \
    'AI_TOOLS_FILTERS=[core, filter-dotnet]' 'OPERATORS=[x]' > "${kind_conf}"
chmod 0644 "${kind_conf}"
unmigrated="$(ai_tools_conf_kind_unmigrated "${kind_conf}")"
if ai_tools_conf_is_trusted "${kind_conf}"; then
    [[ "${unmigrated}" == $'AI_TOOLS_AGENTS\tclaude-code\nAI_TOOLS_FILTERS\tcore' ]] \
        && pass "the unmigrated items are listed by key, in table order" \
        || fail "unmigrated items: got '${unmigrated//$'\n'/|}'"
    printf '%s\n' 'AI_TOOLS_AGENTS=[agent-claude-code' 'AI_TOOLS_FILTERS=[filter-dotnet]' > "${kind_conf}"
    [[ -z "$(ai_tools_conf_kind_unmigrated "${kind_conf}")" ]] \
        && pass "a migrated file and a list the grammar refuses list no unmigrated item" \
        || fail "a migrated file listed unmigrated items: $(ai_tools_conf_kind_unmigrated "${kind_conf}")"
    chmod 0666 "${kind_conf}"
    printf 'AI_TOOLS_AGENTS=[claude-code]\n' > "${kind_conf}"
fi
[[ -z "$(ai_tools_conf_kind_unmigrated "${kind_conf}")" ]] \
    && pass "an untrusted file lists no unmigrated item (the trust refusal reports it)" \
    || fail "an untrusted file listed unmigrated items"

# --- ai_tools_conf_set_list: writes the bracketed form in place and reads it back ------------------------------------
list_conf="${TESTDIR}/set-list.conf"
printf '# header\n#K=[]\nOTHER=kept\n' > "${list_conf}"
set_list_cases=(
    $'[alpha, beta]\talpha beta'
    $'[alpha]\talpha'
    $'[]\t'
    $'[a.b_c-d, e/f]\ta.b_c-d e/f'
)
for row in "${set_list_cases[@]}"; do
    expected="${row%%$'\t'*}"; items="${row#*$'\t'}"
    read -ra item_args <<< "${items}"
    if ai_tools_conf_set_list "${list_conf}" K "${item_args[@]+"${item_args[@]}"}" \
            && [[ "$(grep -c '^#\?K=' "${list_conf}")" == 1 && "$(sed -n 2p "${list_conf}")" == "K=${expected}" ]] \
            && [[ "$(sed -n 1p "${list_conf}")" == "# header" && "$(sed -n 3p "${list_conf}")" == "OTHER=kept" ]]; then
        pass "set_list (${items:-no items}) writes K=${expected} in place of the key's line"
    else
        fail "set_list (${items:-no items}): file is now: $(tr '\n' '|' < "${list_conf}")"
    fi
done
# An item that would read back as other items, or end the list, is refused with status 2 and the file left unchanged.
before="$(cat "${list_conf}")"
for bad in 'a b' 'a,b' '[a' 'a]' '"a"' "'a'" 'a#b' '' $'a\nb' $'a\tb'; do
    status=0; ai_tools_conf_set_list "${list_conf}" K ok "${bad}" || status=$?
    if [[ "${status}" == 2 && "$(cat "${list_conf}")" == "${before}" ]]; then
        pass "set_list refuses the item $(printf '%q' "${bad}")"
    else
        fail "set_list accepted the item $(printf '%q' "${bad}") (status ${status})"
    fi
done
status=0; ai_tools_conf_set_list "${list_conf}" 'BAD KEY' a || status=$?
if [[ "${status}" == 2 ]]; then
    pass "set_list refuses a key outside the identifier charset"
else
    fail "set_list accepted a key outside the identifier charset (status ${status})"
fi

# --- Trust predicate: every state a non-root writer could create must be refused --------------
trusted="${TESTDIR}/trusted.conf"
: > "${trusted}"; chown root:root "${trusted}"; chmod 0644 "${trusted}"
check_trust() {
    local desc="$1" expect="$2" path="$3"   # expect = trusted | refused
    local verdict=refused
    ai_tools_conf_is_trusted "${path}" && verdict=trusted
    if [[ "${verdict}" == "${expect}" ]]; then pass "${desc}"
    else fail "${desc}: got ${verdict}, expected ${expect}"; fi
}
check_trust "root-owned 0644 file is trusted"        trusted "${trusted}"

gw="${TESTDIR}/group-writable.conf"
: > "${gw}"; chown root:root "${gw}"; chmod 0664 "${gw}"
check_trust "group-writable file is refused"         refused "${gw}"

ow="${TESTDIR}/other-writable.conf"
: > "${ow}"; chown root:root "${ow}"; chmod 0646 "${ow}"
check_trust "other-writable file is refused"         refused "${ow}"

notroot="${TESTDIR}/not-root.conf"
: > "${notroot}"; chown "${PROJECTS_USER}" "${notroot}"; chmod 0644 "${notroot}"
check_trust "non-root-owned file is refused"         refused "${notroot}"

ln -s "${trusted}" "${TESTDIR}/link.conf"
check_trust "symlink is refused, not followed"       refused "${TESTDIR}/link.conf"

check_trust "missing path is refused"                refused "${TESTDIR}/absent.conf"
check_trust "empty argument is refused"              refused ""

tdir="${TESTDIR}/trusted.d"; mkdir -p "${tdir}"; chown root:root "${tdir}"; chmod 0755 "${tdir}"
check_trust "root-owned 0755 directory is trusted"   trusted "${tdir}"
chmod 0775 "${tdir}"
check_trust "group-writable directory is refused"    refused "${tdir}"

# --- The refusal names what the predicate read ------------------------------------------------
# A refusal is investigated from its text, so the text carries the owner uid and the mode the predicate read
# and the requirement they failed. The failure this exists for is an owner that reads as 65534 inside a user namespace
# with no mapping for root: the file's modes, labels and ownership on disk are all correct there, and a text asserting
# a permission problem sends the investigation through every one of them first.
section "conf: ai_tools_conf_yes reads a switch the same way whichever key it is"

# The two launch switches read through this function, so a spelling an operator expects -- 1, "true", On -- has to mean
# yes, and 0, "false", off has to mean no. A value in neither set reads as no and is reported, since otherwise
# a mistyped switch changes what a launch does with no line saying so.
if declare -F ai_tools_conf_yes >/dev/null 2>&1; then
    yn="${TESTDIR}/switches.conf"
    printf '%s\n' 'A=yes' 'B="true"' 'C=1' "D='1'" 'E=On' 'F=TRUE' \
                   'G=no' 'H="false"' 'I=0' 'J="0"' 'K=off' 'L=' 'M=ture' > "${yn}"
    misread=()
    for key in A B C D E F; do ai_tools_conf_yes "${yn}" "${key}" 2>/dev/null || misread+=("${key}"); done
    for key in G H I J K L M ABSENT; do ai_tools_conf_yes "${yn}" "${key}" 2>/dev/null && misread+=("${key}"); done
    if (( ${#misread[@]} == 0 )); then
        pass "yes, true, 1, on read as yes and no, false, 0, off, empty, absent and unknown read as no, quoted or not"
    else
        fail "misread switches: ${misread[*]}"
    fi
    said="$(ai_tools_conf_yes "${yn}" M 2>&1 || true)"
    assert_msg MSG-D2F9 "${said}" "a value in neither set is reported"
    said="$(ai_tools_conf_yes "${yn}" G 2>&1 || true)"
    if [[ -z "${said}" ]]; then
        pass "a recognized no value is read silently"
    else
        fail "a recognized no value was reported: ${said}"
    fi
else
    skip "ai_tools_conf_yes" "the deployed conf.lib.sh predates it -- re-run sudo ./install.sh install"
fi

section "conf: a refusal reports the owner and mode it read"
check_reason() {
    local desc="$1" expected="$2" path="$3" got
    got="$(ai_tools_conf_untrusted_reason "${path}")"
    if [[ "${got}" == *"${expected}"* ]]; then pass "${desc}"
    else fail "${desc}: got '${got}', expected it to contain '${expected}'"; fi
}
notroot_uid="$(stat -c '%u' "${notroot}")"
check_reason "a non-root owner is reported as the uid read"    "owner=${notroot_uid} mode=644"  "${notroot}"
check_reason "a group-writable mode is reported as read"       "owner=0 mode=664"               "${gw}"
check_reason "the requirement is stated beside the reading"    "expected owner=0"               "${gw}"
check_reason "a symlink is named as the cause"                 "is a symlink"                   "${TESTDIR}/link.conf"
check_reason "a missing path is named as the cause"            "does not exist"                 "${TESTDIR}/absent.conf"
if [[ "$(ai_tools_conf_untrusted_reason "${notroot}")" != *"user namespace"* ]]; then
    pass "in the initial namespace the reason carries no namespace clause"
else
    fail "the namespace clause appeared in the initial namespace: $(ai_tools_conf_untrusted_reason "${notroot}")"
fi

# The map parser, over fixture maps. The kernel writes space-padded columns, and the libraries are sourced into scripts
# running under IFS=$'\n\t', so the identity case is also driven from a subshell under that IFS -- a parser inheriting
# it reads the whole line as one field.
map_verdict() {   # <expect: identity|translated> <desc> <map-content>
    local expect="$1" desc="$2" content="$3" got=translated
    printf '%s' "${content}" > "${TESTDIR}/uid_map"
    ai_tools_conf_uid_map_is_identity "${TESTDIR}/uid_map" && got=identity
    if [[ "${got}" == "${expect}" ]]; then pass "${desc}"; else fail "${desc}: read as ${got}"; fi
}
map_verdict identity   "the kernel's padded identity line is identity"     $'         0          0 4294967295\n'
map_verdict translated "a single-uid map is translated"                     $'         0       1000          1\n'
map_verdict translated "a map of several ranges is translated"             $'         0          0 4294967295\n      1000       1000          1\n'
map_verdict translated "an empty map is translated (fails closed)"          ''
map_verdict translated "a four-field line is translated"                    $'0 0 4294967295 0\n'
rm -f "${TESTDIR}/uid_map"
if ! ai_tools_conf_uid_map_is_identity "${TESTDIR}/uid_map"; then
    pass "a missing map file reads as translated"
else
    fail "a missing map file read as identity"
fi
printf '         0          0 4294967295\n' > "${TESTDIR}/uid_map"
if ( IFS=$'\n\t'; ai_tools_conf_uid_map_is_identity "${TESTDIR}/uid_map" ); then
    pass "the identity line parses under IFS=\$'\\n\\t' (the updater's strict mode)"
else
    fail "the identity line did not parse under IFS=\$'\\n\\t'"
fi
# The live verdict agrees with the process's own map, whichever namespace this suite runs in.
live_map="$(</proc/self/uid_map)"
if [[ "${live_map}" =~ ^[[:space:]]*0[[:space:]]+0[[:space:]]+4294967295[[:space:]]*$ ]]; then
    if ai_tools_conf_uid_map_is_identity; then pass "the live map reads as identity where /proc says so"
    else fail "the live map is the identity line yet read as translated"; fi
else
    if ! ai_tools_conf_uid_map_is_identity; then pass "the live map reads as translated where /proc says so"
    else fail "the live map is not the identity line yet read as identity"; fi
fi

# The namespace clause, driven inside a real user namespace. `unshare -Ur` maps this root process to 0 inside,
# so a root-owned fixture stays trusted there while the projects-user-owned one reads back as 65534 -- the reading this
# test exists for -- and its reason has to say so. A host whose seccomp or sysctl refuses an unprivileged user namespace
# skips rather than fakes it.
if ! command -v unshare >/dev/null 2>&1 || ! unshare -Ur true 2>/dev/null; then
    skip "the reason names a translating namespace" "unshare -Ur is not permitted on this host"
else
    # shellcheck disable=SC2016  # $1..$3 are the inner shell's positionals, passed after `_`
    ns_out="$(unshare -Ur bash -c '
        source "$1" || exit 9
        printf "trusted=%s\n" "$(ai_tools_conf_is_trusted "$2" && echo yes || echo no)"
        printf "reason=%s\n" "$(ai_tools_conf_untrusted_reason "$3")"' _ "${LIB}" "${trusted}" "${notroot}" 2>&1)" || true
    if [[ "${ns_out}" == *"trusted=yes"* ]]; then
        pass "inside the namespace a root-owned file is still trusted (root maps to root)"
    else
        fail "inside the namespace the root-owned file was refused: ${ns_out}"
    fi
    if [[ "${ns_out}" == *"owner=65534"*"user namespace"* ]]; then
        pass "inside the namespace the reason reports owner=65534 and names the translation"
    else
        fail "the namespace clause is missing: ${ns_out}"
    fi
fi

# --- Sidecar files: what an upgrade preserves when it rewrites an operator's config ------------
# Two copies with two jobs -- .bak is what the operator HAD, .shipped is what they were SUPPOSED to get --
# and the property that makes .bak worth calling a backup is that a second run in the same day cannot overwrite
# the first. An operator who ran the installer twice is exactly the one who needs the earlier copy.
stamp="$(date +%Y%m%d)"
cfg="${TESTDIR}/sidecar.conf"
printf 'ORIGINAL\n' > "${cfg}"; chown root:root "${cfg}"; chmod 640 "${cfg}"

first_bak="$(ai_tools_conf_backup "${cfg}")"
if [[ "${first_bak}" == "${cfg}.${stamp}-1.bak" && "$(cat "${first_bak}")" == ORIGINAL ]]; then
    pass "a backup is date-stamped, numbered from 1, and copies the file verbatim"
else
    fail "backup path/content wrong: ${first_bak}"
fi
if [[ "$(perm "${first_bak}")" == 640 ]]; then
    pass "a backup keeps the mode, so a restore needs no re-permissioning"
else
    fail "backup mode is $(perm "${first_bak}"), expected 640"
fi

printf 'CHANGED\n' > "${cfg}"
second_bak="$(ai_tools_conf_backup "${cfg}")"
if [[ "${second_bak}" == "${cfg}.${stamp}-2.bak" && "$(cat "${first_bak}")" == ORIGINAL ]]; then
    pass "a same-day second backup takes the next number and leaves the first intact"
else
    fail "same-day backup collided: ${second_bak}"
fi

# The reference copy takes the DEPLOYED file's owner and mode, never the source tree's, so a baseline dropped beside
# a 0640 control-plane file is not left world-readable.
baseline="${TESTDIR}/sidecar.shipped-src"
printf 'SHIPPED\n' > "${baseline}"; chmod 666 "${baseline}"
ref="$(ai_tools_conf_reference "${cfg}" "${baseline}")"
if [[ "${ref}" == "${cfg}.${stamp}-1.shipped" && "$(perm "${ref}")" == 640 ]]; then
    pass "a reference copy is date-stamped and takes the deployed file's mode"
else
    fail "reference path/mode wrong: ${ref} mode $(perm "${ref}" 2>/dev/null)"
fi
# A repeated offer of the SAME baseline resolves to the copy already there, so a host re-running the installer
# against an unchanged source tree collects one sidecar rather than one per run.
if [[ "$(ai_tools_conf_reference "${cfg}" "${baseline}")" == "${ref}" && "$(cat "${ref}")" == SHIPPED ]]; then
    pass "an unchanged baseline reuses the copy beside the file"
else
    fail "an unchanged baseline did not resolve to ${ref}"
fi

# A DIFFERENT baseline is a different answer to "what was I supposed to get?", so it takes its own dated copy and leaves
# the earlier one readable.
printf 'SHIPPED v2\n' > "${baseline}"
second_ref="$(ai_tools_conf_reference "${cfg}" "${baseline}")"
if [[ "${second_ref}" != "${ref}" && "$(cat "${ref}")" == SHIPPED && "$(perm "${second_ref}")" == 640 ]]; then
    pass "a changed baseline adds a copy rather than overwriting the first"
else
    fail "changed-baseline copy wrong: ${second_ref}"
fi

# Absent inputs produce no copy and no path -- a caller must never act on a name that was not made.
if ! ai_tools_conf_backup "${TESTDIR}/absent" >/dev/null 2>&1; then
    pass "no backup is invented for a file that is not there"
else
    fail "backed up a nonexistent file"
fi
if ! ai_tools_conf_reference "${cfg}" "${TESTDIR}/absent" >/dev/null 2>&1; then
    pass "no reference is invented for a baseline that is not there"
else
    fail "referenced a nonexistent baseline"
fi

# --- New options in a kept KEY=value config ---------------------------------------------------
# A kept config never gains a key a new version documents, so an install has to SAY which options the operator has not
# seen. It must not say it twice: a key already set, or deliberately commented out, has been seen, and re-announcing it
# every upgrade is the noise that makes an operator stop reading the install output.
shipped_conf="${TESTDIR}/shipped.conf"
cat > "${shipped_conf}" <<'CONF'
# A documented option, shipped commented-out as its own default.
#EXISTING_OPTION="a"

# The option this version introduces.
#NEW_OPTION="b"
CONF

kept_conf="${TESTDIR}/kept.conf"
printf '# older file\nEXISTING_OPTION="a"\n' > "${kept_conf}"
declare -a found=()
if ai_tools_conf_new_keys found "${kept_conf}" "${shipped_conf}" \
        && [[ "${found[*]}" == "NEW_OPTION" ]]; then
    pass "an option the kept file never mentions is reported"
else
    fail "new-option detection returned '${found[*]:-}'"
fi

declare -a same=()
if ! ai_tools_conf_new_keys same "${shipped_conf}" "${shipped_conf}"; then
    pass "a current file reports nothing"
else
    fail "a current file reported '${same[*]}'"
fi

# Both "seen" forms: a live setting and a commented-out default.
printf 'NEW_OPTION="b"\n' >> "${kept_conf}"
declare -a live=()
if ! ai_tools_conf_new_keys live "${kept_conf}" "${shipped_conf}"; then
    pass "an option the operator has set is not announced as new"
else
    fail "announced an already-set option: ${live[*]}"
fi
printf '# older file\nEXISTING_OPTION="a"\n#NEW_OPTION="b"\n' > "${kept_conf}"
declare -a commented=()
if ! ai_tools_conf_new_keys commented "${kept_conf}" "${shipped_conf}"; then
    pass "an option the operator commented out is not re-announced"
else
    fail "re-announced a commented-out option: ${commented[*]}"
fi

# A commented-out DEFAULT and an indented EXAMPLE look alike to a naive scan, and the difference decides what an upgrade
# reports. operator.conf documents its own grammar with lines like
# `#   KEY=value`, so counting those as mentions makes the minimally seeded file
# `ai-tools-admin operators add` writes look like it already knows every option there is.
example_conf="${TESTDIR}/example.conf"
cat > "${example_conf}" <<'CONF'
# Grammar, by example:
#   EXISTING_OPTION="a"
#   NEW_OPTION="b"
OPERATORS="root"
CONF
declare -a examples=()
if ai_tools_conf_new_keys examples "${example_conf}" "${shipped_conf}" \
        && [[ "${examples[*]}" == "EXISTING_OPTION NEW_OPTION" ]]; then
    pass "an indented example in a header block mentions nothing"
else
    fail "prose examples were read as mentions (reported '${examples[*]:-}')"
fi

# --- Allowlist membership: one exact-entry matcher every consumer shares -----------------------
# The launch wrapper, the CLI (reg/unreg/project_state), and the relabel helper all decide "is this path listed"
# through these predicates instead of a raw `grep -qxF` against the stored line. The property under test: an entry
# written in the documented grammar -- an end-of-line comment, quotes, or a spelling reached by a symlink or trailing
# slash -- MATCHES, where a raw grep would miss it and report the project unlisted (the divergence that duplicated
# entries on claim, left them on unclaim, and failed the post-claim launch confirm).
al_root="${TESTDIR}/al"; mkdir -p \
    "${al_root}/proj" "${al_root}/commented" "${al_root}/quoted dir" \
    "${al_root}/excluded" "${al_root}/link-target"
ln -s "${al_root}/link-target" "${al_root}/link-alias"
al="${TESTDIR}/allowed-projects"
cat > "${al}" <<EOF
# a whole-line comment, ignored
${al_root}/proj
${al_root}/commented    # main repo
"${al_root}/quoted dir"
!${al_root}/excluded
${al_root}/link-alias
${al_root}/stale-gone
EOF

check_member() {
    local desc="$1" expect="$2" path="$3"   # expect = member | absent
    local verdict=absent
    ai_tools_conf_allowlist_has_entry "${al}" "${path}" && verdict=member
    if [[ "${verdict}" == "${expect}" ]]; then pass "${desc}"
    else fail "${desc}: got ${verdict}, expected ${expect}"; fi
}
check_member "a plain entry matches"                    member "${al_root}/proj"
check_member "an end-of-line comment does not hide it"  member "${al_root}/commented"
check_member "a quoted path matches"                    member "${al_root}/quoted dir"
check_member "a trailing slash is normalized away"      member "${al_root}/proj/"
check_member "a symlinked spelling matches by realpath" member "${al_root}/link-target"
check_member "an unlisted path is absent"               absent "${al_root}/not-there"
check_member "an excluded path is not a member"         absent "${al_root}/excluded"

if ai_tools_conf_allowlist_has_exclusion "${al}" "${al_root}/excluded" \
        && ! ai_tools_conf_allowlist_has_exclusion "${al}" "${al_root}/proj"; then
    pass "has_exclusion matches only the '!' line"
else
    fail "has_exclusion did not isolate the exclusion entry"
fi

# The line-identifying variant returns the VERBATIM source line (comment and all), which is what an anchored sed deletes
# -- reconstructing it from the path would miss a commented/quoted entry and leave it behind. Two-ended
# with the boundary suite: the agent cannot write the allowlist.
declare -a matched=()
if ai_tools_conf_allowlist_matching_lines matched "${al}" "${al_root}/commented" \
        && [[ "${#matched[@]}" -eq 1 && "${matched[0]}" == "${al_root}/commented    # main repo" ]]; then
    pass "matching_lines returns the raw commented line verbatim for deletion"
else
    fail "matching_lines returned '${matched[*]:-}'"
fi
matched=()
if ai_tools_conf_allowlist_matching_lines matched "${al}" "${al_root}/quoted dir" \
        && [[ "${matched[0]}" == "\"${al_root}/quoted dir\"" ]]; then
    pass "matching_lines returns the raw quoted line verbatim"
else
    fail "matching_lines did not return the quoted line: '${matched[*]:-}'"
fi
matched=()
if ! ai_tools_conf_allowlist_matching_lines matched "${al}" "${al_root}/excluded"; then
    pass "matching_lines skips exclusion lines (never deletes an exclusion as a membership)"
else
    fail "matching_lines matched an exclusion line: '${matched[*]:-}'"
fi

# The two forms that ARE defaults stay defaults, hard against the '#' and one space in.
printf '#EXISTING_OPTION="a"\n# NEW_OPTION="b"\n' > "${kept_conf}"
declare -a spaced=()
if ! ai_tools_conf_new_keys spaced "${kept_conf}" "${shipped_conf}"; then
    pass "both commented-default forms (#KEY= and # KEY=) count as mentions"
else
    fail "a commented default was missed: ${spaced[*]}"
fi

# The scan is a reader, not a writer, and must not leave state in its caller.
seen_key="SENTINEL"
# shellcheck disable=SC2034  # the output array is deliberately unread here: this case asserts
# the scan's effect on OTHER variables, not its result
declare -a discarded=()
ai_tools_conf_new_keys discarded "${kept_conf}" "${shipped_conf}" >/dev/null 2>&1 || true
if [[ "${seen_key}" == "SENTINEL" ]]; then
    pass "the scan leaks no variable into its caller"
else
    fail "the scan overwrote a caller variable: seen_key=${seen_key}"
fi

# --- Path-list entries (allowed-projects) -----------------------------------------------------
# The launch allowlist shares this grammar, and three components parse that file -- the wrapper, the CLI, and the chown
# helper. The first block is BACKWARD COMPATIBILITY: every shape an existing allowlist already contains must parse
# exactly as before, because a line that stops resolving silently removes a project from the gate.
check_entry() {
    local desc="$1" want="$2" line="$3" rc=0
    ai_tools_conf_path_entry "${line}" || rc=$?
    if [[ "${want}" == SKIP ]]; then
        if [[ "${rc}" -ne 0 ]]; then pass "${desc}"; else fail "${desc}: yielded '${_ai_tools_conf_value}'"; fi
    elif [[ "${rc}" -eq 0 && "${_ai_tools_conf_value}" == "${want}" ]]; then
        pass "${desc}"
    else
        fail "${desc}: rc ${rc}, got '${_ai_tools_conf_value}', expected '${want}'"
    fi
}
check_entry "a plain path is unchanged"            /home/me/project         '/home/me/project'
check_entry "an exclusion keeps its !"             '!/home/me/vendor'       '!/home/me/vendor'
check_entry "a glob exclusion stays raw"           '!/home/me/*/node_mod'   '!/home/me/*/node_mod'
check_entry "surrounding whitespace is trimmed"    /home/me/project         '   /home/me/project   '
check_entry "a blank line yields no entry"         SKIP                     ''
check_entry "a whole-line comment yields no entry" SKIP                     '# a note'
check_entry "an indented comment yields no entry"  SKIP                     '   # a note'

# The grammar this file gains: end-of-line comments, and quotes for a path that must carry a space or a literal `#`.
check_entry "an end-of-line comment is removed"    /home/me/project         '/home/me/project  # why'
check_entry "quotes carry a space"                 '/home/me/my project'    '"/home/me/my project"'
check_entry "quotes make # literal"                '/home/me/proj #2'       '"/home/me/proj #2"'
check_entry "single quotes work too"               '/home/me/my project'    "'/home/me/my project'"
check_entry "an exclusion may be quoted"           '!/home/me/my project'   '!"/home/me/my project"'
check_entry "a quoted path may be commented"       '/home/me/a b'           '"/home/me/a b"   # note'
# An interior # with no preceding whitespace is part of the path, matching the KEY=value rule -- a directory literally
# named proj#2 keeps working unquoted.
check_entry "an interior # needs no quotes"        '/home/me/proj#2'        '/home/me/proj#2'
# An unmatched quote is taken verbatim rather than truncating the path at some later character, so a typo cannot
# silently shorten an allowlist entry into a broader one.
check_entry "an unmatched quote is taken as-is"    '/home/me/project'       '"/home/me/project'

# --- Allowlist editing: the one implementation of a registry change ---------------------------
# Three components write allowed-projects (the CLI on the operator's own file, ai-tools-allowlist
# on another operator's, install.sh on its own checkout), and this is what all three call. The
# file is the LAUNCH GATE, so each assertion is about a way an edit could leave the gate
# saying something other than what the caller was told:
#   * the three-state read, so a DISABLED project reads as disabled, not as absent;
#   * add refusing to append under a winning '!', which would leave an allow line the exclusion
#     beats;
#   * add opening a line of its own, so a file that runs to EOF mid-line keeps that entry;
#   * remove taking BOTH line kinds, so no '!' is left to park the next claim at that path;
#   * enable/disable preserving position, indentation and comment -- their reason to exist
#     rather than being an add+remove pair, for an operator whose allowlist is an ordered,
#     commented document;
#   * enable collapsing a duplicate pair to ONE live entry;
#   * an unwritable directory REPORTED (rc 1) rather than aborting the caller under `set -e`.
section "conf: allowlist editing (unit)"

if ! declare -F ai_tools_conf_allowlist_state >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_allowlist_add >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_allowlist_remove >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_allowlist_enable >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_allowlist_disable >/dev/null 2>&1; then
    fail "${LIB} defines no allowlist editing functions"
    finish; exit
fi

AL="${TESTDIR}/allowed-projects"
P1="${TESTDIR}/p1"; P2="${TESTDIR}/p2"; SUB="${TESTDIR}/p1/vendor"
mkdir -p "${P1}" "${P2}" "${SUB}"

# seed_al <line>... : rewrite the fixture allowlist with the given raw lines.
seed_al() { printf '%s\n' "$@" > "${AL}"; }

# state_is <expected> <path> <desc>
state_is() {
    local got; got="$(ai_tools_conf_allowlist_state "${AL}" "$2")"
    if [[ "${got}" == "$1" ]]; then pass "$3"; else fail "$3: state is '${got}', expected '$1'"; fi
}

# rc_is <expected-rc> <desc> <command...>
rc_is() {
    local want="$1" desc="$2"; shift 2
    local rc=0; "$@" || rc=$?
    if [[ "${rc}" -eq "${want}" ]]; then pass "${desc}"; else fail "${desc}: rc ${rc}, expected ${want}"; fi
}

# --- the three-state read ---
seed_al "# header" "" "${P1}   # a comment" "!${SUB}"
state_is listed   "${P1}"  "an allow line reads as listed"
state_is disabled "${SUB}" "an exclusion reads as disabled"
state_is absent   "${P2}"  "a path with no line reads as absent"
# An exclusion OUTRANKS an allow line, exactly as it does at the launch gate: with both present no session starts there,
# so 'disabled' is the only honest answer.
seed_al "${P1}" "!${P1}"
state_is disabled "${P1}" "an exclusion outranks an allow line for the same path"

# --- add ---
seed_al "# header"
rc_is 0 "add appends an absent path"            ai_tools_conf_allowlist_add "${AL}" "${P1}"
state_is listed "${P1}" "the added path reads as listed"
rc_is 0 "add is idempotent for a listed path"   ai_tools_conf_allowlist_add "${AL}" "${P1}"
if [[ "$(grep -cxF "${P1}" "${AL}")" == 1 ]]; then
    pass "add did not duplicate the line"
else
    fail "add duplicated the line ($(grep -cxF "${P1}" "${AL}") copies)"
fi
# A hand-edited registry can run to EOF part-way through its last line, and the readers keep that entry, so the append
# opens a line of its own for the new one. Written straight it would join the two paths into one that is not a project,
# taking the preceding entry off the launch gate.
printf '%s\n%s' "# header" "${P2}" > "${AL}"
rc_is 0 "add opens a line for an entry that runs to EOF" ai_tools_conf_allowlist_add "${AL}" "${P1}"
state_is listed "${P1}" "the added path reads as listed"
state_is listed "${P2}" "the entry that ran to EOF is still listed"

seed_al "# header" "!${P1}"
rc_is 2 "add REFUSES a disabled path"           ai_tools_conf_allowlist_add "${AL}" "${P1}"
state_is disabled "${P1}" "the refused add left the path disabled"
if [[ "$(grep -cF "${P1}" "${AL}")" == 1 ]]; then
    pass "the refused add wrote no second line"
else
    fail "the refused add appended over the exclusion: $(grep -c . "${AL}") lines"
fi

# --- remove: BOTH line kinds ---
seed_al "# header" "${P1}" "!${P1}" "${P2}"
rc_is 0 "remove drops a path"                   ai_tools_conf_allowlist_remove "${AL}" "${P1}"
state_is absent "${P1}" "the removed path reads as absent"
if grep -qF "${P1}" "${AL}"; then
    fail "remove left a line naming the path: $(grep -F "${P1}" "${AL}")"
else
    pass "remove took the allow line AND the exclusion"
fi
state_is listed "${P2}" "remove left the other project alone"
rc_is 0 "removing an absent path succeeds"      ai_tools_conf_allowlist_remove "${AL}" "${P1}"

# --- disable / enable: in place, keeping position and comment ---
seed_al "# header" "  ${P1}   # payments, dev stage" "${P2}"
before="$(cat "${AL}")"
rc_is 0 "disable parks a listed project"        ai_tools_conf_allowlist_disable "${AL}" "${P1}"
state_is disabled "${P1}" "the parked project reads as disabled"
if [[ "$(sed -n '2p' "${AL}")" == "  !${P1}   # payments, dev stage" ]]; then
    pass "disable kept the line's position, indentation and comment"
else
    fail "disable rewrote the line: '$(sed -n '2p' "${AL}")'"
fi
rc_is 0 "disable is idempotent"                 ai_tools_conf_allowlist_disable "${AL}" "${P1}"
rc_is 0 "enable restores a parked project"      ai_tools_conf_allowlist_enable  "${AL}" "${P1}"
state_is listed "${P1}" "the restored project reads as listed"
if [[ "$(cat "${AL}")" == "${before}" ]]; then
    pass "a park/restore round trip leaves the file byte-identical"
else
    fail "the round trip changed the file:"$'\n'"$(cat "${AL}")"
fi
rc_is 0 "enable is idempotent"                  ai_tools_conf_allowlist_enable "${AL}" "${P1}"

# Neither verb invents an entry: enabling or disabling a path the file does not name would register a project without
# claiming it (no secret scan, no ACL, no label).
seed_al "# header" "${P2}"
rc_is 2 "enable refuses an absent path"         ai_tools_conf_allowlist_enable  "${AL}" "${P1}"
rc_is 2 "disable refuses an absent path"        ai_tools_conf_allowlist_disable "${AL}" "${P1}"
if [[ "$(cat "${AL}")" == "# header"$'\n'"${P2}" ]]; then
    pass "both refusals left the file untouched"
else
    fail "a refusal wrote to the file:"$'\n'"$(cat "${AL}")"
fi

# --- enable collapses the duplicate pair to ONE live entry ---
# A '!' line and an allow line for one path, the pair an append over an exclusion would create. Un-parking the '!' line
# while an allow line already exists would leave two live entries for one path; the earliest position survives.
seed_al "# header" "!${P1}   # parked" "${P2}" "${P1}"
rc_is 0 "enable collapses a duplicate pair"     ai_tools_conf_allowlist_enable "${AL}" "${P1}"
state_is listed "${P1}" "the collapsed path reads as listed"
if [[ "$(grep -cF "${P1}" "${AL}")" == 1 && "$(sed -n '2p' "${AL}")" == "${P1}   # parked" ]]; then
    pass "one entry survives, in the earliest position, with its comment"
else
    fail "collapse left $(grep -cF "${P1}" "${AL}") line(s):"$'\n'"$(cat "${AL}")"
fi

# --- a write that cannot happen is REPORTED, not fatal ---
# The rewrite lands its temporary file in the allowlist's own directory, so an unwritable config directory fails even
# when the file itself is writable. Under `set -e` a bare I/O error would abort the caller; the function must return 1
# and leave the file as it was.
#
# Driven AS THE PROJECTS USER, which is who runs the CLI: this suite runs as root, and root ignores a directory's write
# bit, so the very write the case is about would succeed and the assertion would pass for the wrong reason. The library
# is sourced fresh in that shell, since the check is about the caller's own credentials.
if ! command -v runuser >/dev/null 2>&1; then
    skip "unwritable config directory" "runuser unavailable"
else
    ro="${TESTDIR}/ro"; mkdir -p "${ro}"
    printf '%s\n' "${P1}" > "${ro}/allowed-projects"
    chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${ro}"
    chmod 0500 "${ro}"
    rc=0
    # shellcheck disable=SC2016  # $1..$3 are the inner shell's positionals, passed after `_`
    runuser -u "${PROJECTS_USER}" -- bash -c '
        source "$1" || exit 9
        ai_tools_conf_allowlist_disable "$2" "$3"' _ "${LIB}" "${ro}/allowed-projects" "${P1}" || rc=$?
    chmod 0700 "${ro}"
    if [[ "${rc}" -eq 1 ]]; then
        pass "an unwritable config directory is reported (rc 1), not fatal"
    else
        fail "an unwritable config directory returned rc ${rc}, expected 1"
    fi
    if [[ "$(cat "${ro}/allowed-projects")" == "${P1}" ]]; then
        pass "the failed edit left the allowlist unchanged"
    else
        fail "the failed edit modified the allowlist: $(cat "${ro}/allowed-projects")"
    fi
fi

# --- the text predicate: a file whose bytes go to a program as prose -------------------------
# ai_tools_conf_is_text_file is the shared check behind an agent's system prompt: the trust predicate says who wrote
# the file, this says the bytes are text. Empty counts as text (the shipped inert default), a directory
# and a NUL-carrying blob do not.
if declare -F ai_tools_conf_is_text_file >/dev/null 2>&1; then
    tf="${TESTDIR}/textfile"
    printf 'You are a sandboxed agent.\n' > "${tf}"
    ai_tools_conf_is_text_file "${tf}" && pass "a text file is text" || fail "a text file was refused"
    : > "${tf}"
    ai_tools_conf_is_text_file "${tf}" && pass "an empty file counts as text" || fail "an empty file was refused"
    printf '\x00\x01\x02ELF\x00' > "${tf}"
    ai_tools_conf_is_text_file "${tf}" && fail "a NUL-carrying blob passed as text" || pass "a binary blob is not text"
    mkdir -p "${TESTDIR}/textdir"
    ai_tools_conf_is_text_file "${TESTDIR}/textdir" && fail "a directory passed as a text file" || pass "a directory is not a text file"
else
    fail "conf.lib.sh does not define ai_tools_conf_is_text_file"
fi

# --- the one in-place write of a KEY=value file: ai_tools_conf_set_key ------------------------
# The writer behind `operators add` and the toolchain provisioning's agent choice. What matters is WHICH line it
# replaces -- the key's own, commented default included, found by the mention rule ai_tools_conf_keys reads --
# and that every other byte survives, since the file it rewrites is the operator's, and a writer with its own idea
# of a match is one that appends a second live line under a commented default the operator then edits to no effect.
section "conf: ai_tools_conf_set_key rewrites one key in place"
if declare -F ai_tools_conf_set_key >/dev/null 2>&1; then
    sk="${TESTDIR}/set-key.conf"
    cat > "${sk}" <<'EOF'
# a header line
OPERATORS="op"

# The agents this host runs. Absent: no agent.
#   AI_TOOLS_AGENTS="example"     an indented example is prose, not the key
#AI_TOOLS_AGENTS=""

#SKIP_CACHE_DIRS="__pycache__"
EOF
    cp "${sk}" "${sk}.before"
    chmod 0640 "${sk}"
    rc=0; ai_tools_conf_set_key "${sk}" AI_TOOLS_AGENTS "acme beta" || rc=$?
    if [[ "${rc}" -eq 0 && "$(ai_tools_conf_get "${sk}" AI_TOOLS_AGENTS)" == "acme beta" ]]; then
        pass "a commented default is rewritten as the live key and reads back"
    else
        fail "set_key over a commented default: rc ${rc}, value '$(ai_tools_conf_get "${sk}" AI_TOOLS_AGENTS || true)'"
    fi
    if diff <(sed 's/^#AI_TOOLS_AGENTS=""$/AI_TOOLS_AGENTS="acme beta"/' "${sk}.before") "${sk}" >/dev/null; then
        pass "the key's own line is replaced in place and every other line is byte-identical"
    else
        fail "set_key changed more than the key's line: $(diff "${sk}.before" "${sk}" | tr '\n' '|')"
    fi
    if [[ "$(stat -c '%a' "${sk}")" == "640" ]]; then
        pass "the rewritten file keeps its mode"
    else
        fail "the rewritten file's mode changed to $(stat -c '%a' "${sk}")"
    fi
    rc=0; ai_tools_conf_set_key "${sk}" AI_TOOLS_AGENTS "gamma" || rc=$?
    if [[ "${rc}" -eq 0 && "$(grep -c 'AI_TOOLS_AGENTS=' "${sk}")" -eq 2 \
            && "$(ai_tools_conf_get "${sk}" AI_TOOLS_AGENTS)" == "gamma" ]]; then
        pass "an existing live key is replaced, not duplicated (the indented example stays prose)"
    else
        fail "set_key over a live key: rc ${rc}, $(grep -c 'AI_TOOLS_AGENTS=' "${sk}") mention(s), value '$(ai_tools_conf_get "${sk}" AI_TOOLS_AGENTS || true)'"
    fi
    # A live line an operator wrote after the template's commented default is the one a reader takes, so it is the one
    # replaced: rewriting the commented default instead would leave the later line winning the read.
    printf '%s\n' '#K=""' 'OTHER=1' 'K="old"' > "${sk}.below"
    rc=0; ai_tools_conf_set_key "${sk}.below" K "new" || rc=$?
    if [[ "${rc}" -eq 0 && "$(tr '\n' '|' < "${sk}.below")" == '#K=""|OTHER=1|K="new"|' ]]; then
        pass "a live line below a commented default is the one replaced, and the default stays commented"
    else
        fail "set_key over a live line below a commented default: rc ${rc}, file '$(tr '\n' '|' < "${sk}.below")'"
    fi
    printf '%s\n' 'K="a"' 'K="b"' > "${sk}.twice"
    rc=0; ai_tools_conf_set_key "${sk}.twice" K "c" || rc=$?
    if [[ "${rc}" -eq 0 && "$(tr '\n' '|' < "${sk}.twice")" == 'K="a"|K="c"|' ]]; then
        pass "of two live lines the last, the one a reader takes, is replaced"
    else
        fail "set_key over a repeated key: rc ${rc}, file '$(tr '\n' '|' < "${sk}.twice")'"
    fi
    rc=0; ai_tools_conf_set_key "${sk}" OPERATORS "op two" || rc=$?
    if [[ "${rc}" -eq 0 && "$(sed -n 2p "${sk}")" == 'OPERATORS="op two"' ]]; then
        pass "OPERATORS is rewritten on its own line, in its place"
    else
        fail "set_key on OPERATORS: rc ${rc}, line 2 is '$(sed -n 2p "${sk}")'"
    fi
    rc=0; ai_tools_conf_set_key "${sk}" NEW_KEY "v" || rc=$?
    if [[ "${rc}" -eq 0 && "$(tail -n 1 "${sk}")" == 'NEW_KEY="v"' ]]; then
        pass "a key the file does not mention is appended"
    else
        fail "set_key on an absent key: rc ${rc}, last line '$(tail -n 1 "${sk}")'"
    fi
    printf 'TRAIL=1' > "${sk}.noeol"
    ai_tools_conf_set_key "${sk}.noeol" NEXT "2" || true
    if [[ "$(ai_tools_conf_get "${sk}.noeol" TRAIL)" == "1" && "$(ai_tools_conf_get "${sk}.noeol" NEXT)" == "2" ]]; then
        pass "an append after an unterminated last line keeps both keys"
    else
        fail "an append joined the unterminated last line: $(tr '\n' '|' < "${sk}.noeol")"
    fi
    rc=0; ai_tools_conf_set_key "${TESTDIR}/fresh.conf" OPERATORS "op" || rc=$?
    if [[ "${rc}" -eq 0 && "$(stat -c '%a' "${TESTDIR}/fresh.conf")" == "644" \
            && "$(ai_tools_conf_get "${TESTDIR}/fresh.conf" OPERATORS)" == "op" ]]; then
        pass "a missing file is created at 644 holding the key"
    else
        fail "set_key on a missing file: rc ${rc}"
    fi
    for bad in 'bad-key' '1KEY' ''; do
        rc=0; ai_tools_conf_set_key "${sk}" "${bad}" v || rc=$?
        [[ "${rc}" -eq 2 ]] && pass "a key outside the identifier charset ('${bad}') is refused with 2" \
                             || fail "key '${bad}' returned rc ${rc}, expected 2"
    done
    for bad in $'a\nb' 'a"b'; do
        rc=0; ai_tools_conf_set_key "${sk}" AI_TOOLS_AGENTS "${bad}" || rc=$?
        [[ "${rc}" -eq 2 && "$(ai_tools_conf_get "${sk}" AI_TOOLS_AGENTS)" == "gamma" ]] \
            && pass "a value that would end the line or the quote early is refused with 2, file unchanged" \
            || fail "value '${bad//$'\n'/\\n}' returned rc ${rc} (value now '$(ai_tools_conf_get "${sk}" AI_TOOLS_AGENTS || true)')"
    done
else
    fail "conf.lib.sh does not define ai_tools_conf_set_key"
fi

finish

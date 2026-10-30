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
#      runs under. nvm-update.sh and ai-tools-launch legitimately set IFS=$'\n\t'; a splitter that
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
        || ! declare -F ai_tools_conf__read >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__split >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__read_list >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__split_list_value >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__set_list >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__has_allowlist_entry >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__is_trusted >/dev/null 2>&1; then
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
    local got; got="$(ai_tools_conf__print_value "${conf}" "${key}" || true)"
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
if ai_tools_conf__read "${conf}" EMPTY && [[ -z "${ai_tools_conf__value}" ]]; then
    pass "present-but-empty key reads as PRESENT with an empty value"
else
    fail "present-but-empty key did not read as present"
fi
if ! ai_tools_conf__read "${conf}" NO_SUCH_KEY; then
    pass "absent key reads as ABSENT (distinct from present-and-empty)"
else
    fail "absent key reported as present"
fi
if ! ai_tools_conf__read "${conf}" "not an assignment line"; then
    pass "a line with no '=' is ignored"
else
    fail "a line with no '=' was parsed as a key"
fi
if ! ai_tools_conf__read "${TESTDIR}/does-not-exist" BARE; then
    pass "unreadable file reads as absent"
else
    fail "unreadable file reported a value"
fi
# The status tells a key absent from a file read whole (1) from a file not read whole (2): a reader whose default
# for an absent key widens access turns on it, and the read builtin reports an I/O error as end of input.
read_status() { local status=0; ai_tools_conf__read "$@" >/dev/null 2>&1 || status=$?; printf '%s' "${status}"; }
[[ "$(read_status "${conf}" NO_SUCH_KEY)" == 1 ]] && pass "an absent key is status 1" || fail "an absent key: status $(read_status "${conf}" NO_SUCH_KEY)"
[[ "$(read_status "${TESTDIR}/does-not-exist" BARE)" == 2 ]] && pass "an absent file is status 2" || fail "an absent file: status $(read_status "${TESTDIR}/does-not-exist" BARE)"
mkdir "${TESTDIR}/a-directory.conf"
[[ "$(read_status "${TESTDIR}/a-directory.conf" BARE)" == 2 ]] && pass "a directory at the path is status 2" || fail "a directory: status $(read_status "${TESTDIR}/a-directory.conf" BARE)"
cat() { return 1; }
[[ "$(read_status "${conf}" BARE)" == 2 ]] && pass "a read that does not complete is status 2, with the key present" || fail "a failed read: status $(read_status "${conf}" BARE)"
unset -f cat
[[ "$(read_status "${conf}" BARE)" == 0 ]] && pass "control: the key reads at status 0 once the read completes" || fail "control: status $(read_status "${conf}" BARE)"
printf 'NOEOL=1' > "${TESTDIR}/noeol.conf"
[[ "$(ai_tools_conf__print_value "${TESTDIR}/noeol.conf" NOEOL)" == 1 ]] && pass "a file without a final newline reads its last line" || fail "a file without a final newline: '$(ai_tools_conf__print_value "${TESTDIR}/noeol.conf" NOEOL || true)'"

# --- Splitting: separators, runs, and IFS independence ---------------------------------------
# split_under_ifs <ifs> <value> : the items, joined by '|', from a SUBSHELL running under <ifs>, so the caller's own IFS
# cannot mask a dependency.
split_under_ifs() {
    local ifs="$1" value="$2"
    ( IFS="${ifs}"; local -a out=(); ai_tools_conf__split out "${value}"
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
# The output array is named by the caller, and a nameref resolves through every function on the call stack, so a name
# any reader uses for a local of its own must still reach the caller's array, through every reader that takes one.
printf 'L=[c, d]\nP=[x=on]\nAI_TOOLS_AGENTS=[agent-e]\n' > "${TESTDIR}/names.conf"
for name in tokens token raw value inner reason label out_name file key item prefix bare unprefixed pair_name \
    kept_names allowed_values_text; do
    got="$(bash -c 'source "$1"; declare -a "$2"; declare -n result="$2"; f="$3"; line=""
                    ai_tools_conf__split "$2" "a, b";            line+="${result[*]}|"
                    ai_tools_conf__split_list_value "$2" "[c, d]";     line+="${result[*]}|"
                    ai_tools_conf__read_list "$2" "${f}" L;           line+="${result[*]}|"
                    ai_tools_conf__read_pair_list "$2" "${f}" P on off; line+="${result[*]}|"
                    ai_tools_conf__read_kind_list "$2" "${f}" AI_TOOLS_AGENTS; line+="${result[*]}|"
                    printf "%s" "${line}"' _ "${LIB}" "${name}" "${TESTDIR}/names.conf" 2>&1)"
    if [[ "${got}" == "a b|c d|c d|x=on|e|" ]]; then pass "an output array named ${name} receives the items"
    else fail "an output array named ${name}: got '${got}'"; fi
done

# --- ai_tools_conf__read_list: a present key REPLACES, an absent key LEAVES the default ------------
declare -a target=(default-one default-two)
if ai_tools_conf__read_list target "${conf}" LIST && [[ "${target[*]}" == "a b c d" ]]; then
    pass "present key replaces the array"
else
    fail "present key did not replace: got '${target[*]}'"
fi
target=(default-one default-two)
if ! ai_tools_conf__read_list target "${conf}" NO_SUCH_KEY && [[ "${target[*]}" == "default-one default-two" ]]; then
    pass "absent key leaves the caller's default untouched"
else
    fail "absent key clobbered the default: got '${target[*]}'"
fi
target=(default-one default-two)
if ai_tools_conf__read_list target "${conf}" EMPTY && [[ "${#target[@]}" -eq 0 ]]; then
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
    # shellcheck disable=SC2154  # ai_tools_conf__list_invalid is set by conf.lib.sh, sourced at the top of this file
    said="$( IFS=$'\n\t'; target=(default); ai_tools_conf__read_list target "${list_conf}" K 2>&1 >/dev/null
             joined=""; for item in "${target[@]}"; do joined+="${item}|"; done
             printf '\nITEMS=%s\nINVALID=%s\n' "${joined}" "${ai_tools_conf__list_invalid}" )"
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

# --- ai_tools_conf__read_kind_list: a provider list item carries its kind
#   --------------------------------------------------
# Each key in the kind table takes items written <prefix><name> and hands its caller the bare names. An item without
# its key's prefix -- the bare name an earlier release wrote, another kind's prefix, the prefix alone, a traversal after
# it -- makes the whole list read as empty under MSG-X6F2, the less-access reading; a list the grammar refuses keeps
# its own code; an absent key returns 1 with the caller's array untouched. Rows: <KEY> <line> <expected>, where
# the expected value is the items joined by `|`, INVALID:<code>, or ABSENT.
kind_conf="${TESTDIR}/kind.conf"
while IFS=$'\t' read -r key line expected; do
    printf '%s\n' "${line}" > "${kind_conf}"
    said="$( IFS=$'\n\t'; target=(default); rc=0
             ai_tools_conf__read_kind_list target "${kind_conf}" "${key}" 2>&1 >/dev/null || rc=$?
             joined=""; for item in "${target[@]}"; do joined+="${item}|"; done
             printf '\nITEMS=%s\nRC=%s\nINVALID=%s\n' "${joined}" "${rc}" "${ai_tools_conf__list_invalid}" )"
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
if ai_tools_conf__read_kind_list target "${kind_conf}" OPERATORS 2>/dev/null; then
    fail "ai_tools_conf__read_kind_list accepted a key outside the kind table"
else
    pass "ai_tools_conf__read_kind_list refuses a key outside the kind table"
fi

# ai_tools_conf__read_pair_list reads `<name>=<value>` items against the caller's values. Rows, `;`-separated so an
#   empty
# field stays a field: <line>;<expected items, joined by spaces, or ABSENT>;<reports expected>. A malformed or repeated
# item is reported and left out; an invalid list reads empty, as every list does; an absent key leaves the target as it
# was.
if declare -F ai_tools_conf__read_pair_list >/dev/null 2>&1; then
    pair_conf="${TESTDIR}/pair.conf"
    while IFS=';' read -r pair_line pair_expected pair_reports; do
        printf '%s\n' "${pair_line}" > "${pair_conf}"
        pair_target=(untouched); pair_rc=0
        # Called in this shell, stderr to a file: a $(...) capture would run it in a subshell and lose the array.
        ai_tools_conf__read_pair_list pair_target "${pair_conf}" PAIRS on off 2>"${TESTDIR}/pair.err" || pair_rc=$?
        pair_stderr="$(<"${TESTDIR}/pair.err")"
        pair_got="${pair_target[*]+"${pair_target[*]}"}"
        [[ "${pair_rc}" -eq 1 ]] && pair_got=ABSENT
        pair_reported="$(grep -c '^MSG-' <<<"${pair_stderr}" || true)"
        # The rejected count is what a caller refuses on, so it must agree with what was reported.
        if [[ "${pair_rc}" -eq 0 && "${ai_tools_conf__pair_list_rejected_count:-}" != "${pair_reports}" \
              && "${ai_tools_conf__list_invalid:-0}" -eq 0 ]]; then
            fail "pair list ${pair_line}: ai_tools_conf__pair_list_rejected_count=${ai_tools_conf__pair_list_rejected_count:-unset}, expected ${pair_reports}"
        fi
        if [[ "${pair_got}" == "${pair_expected}" && "${pair_reported}" == "${pair_reports}" ]]; then
            pass "pair list ${pair_line} -> [${pair_got}], ${pair_reported} reported"
        else
            fail "pair list ${pair_line} -> [${pair_got}], ${pair_reported} reported; expected [${pair_expected}], ${pair_reports}"
        fi
    done <<'ROWS'
PAIRS=[a=on, b_2=off];a=on b_2=off;0
PAIRS=a=on b=off;a=on b=off;0
PAIRS=[];;0
PAIRS=[a=on, a=off];a=on;1
PAIRS=[a=yes, b, =on, c=, d=on=off];;5
PAIRS=[a.b=on, a/b=on, a*=on, A_Z9=off];A_Z9=off;3
PAIRS=[aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=on];;1
PAIRS=[a=on;;1
OTHER=x;ABSENT;0
ROWS
    # The values are the caller's: the same items read against another set.
    printf 'PAIRS=[a=on, b=low]\n' > "${pair_conf}"
    pair_target=(); ai_tools_conf__read_pair_list pair_target "${pair_conf}" PAIRS low high 2>/dev/null
    if [[ "${pair_target[*]-}" == "b=low" ]]; then pass "pair list values are the caller's: [a=on, b=low] read against low|high -> b=low"
    else fail "pair list against low|high -> [${pair_target[*]-}]; expected b=low"; fi
    # The grammar is the shell's IFS-independent split: the same read under the IFS ai-tools sets.
    printf 'PAIRS=[a=on, b=off]\n' > "${pair_conf}"
    pair_target=(); (IFS=$'\n\t'; ai_tools_conf__read_pair_list pair_target "${pair_conf}" PAIRS on off 2>/dev/null; printf '%s|' "${pair_target[@]}") > "${TESTDIR}/pair.out"
    if [[ "$(<"${TESTDIR}/pair.out")" == "a=on|b=off|" ]]; then pass "pair list reads alike under IFS=\$'\\n\\t'"
    else fail "pair list under IFS=\$'\\n\\t' -> $(<"${TESTDIR}/pair.out")"; fi
else
    skip "pair list" "the library predates ai_tools_conf__read_pair_list"
fi

# ai_tools_conf__get_kind_item is the writer's side: a bare name gains the prefix, a prefixed one is kept, and a name
# that is not a plain name once prefixed, or a key outside the table, prints nothing. Rows: <KEY> <name>
# <expected|REFUSED>.
while IFS=$'\t' read -r key name expected; do
    got="$(ai_tools_conf__get_kind_item "${key}" "${name}")" && rc=0 || rc=$?
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

# ai_tools_conf__find_unmigrated_items is the one detection predicate: it prints every item without its key's prefix,
# keyed, and prints nothing for a clean file, a list the grammar refuses, or a file the trust predicate refuses.
# The listing half needs a root-owned fixture, so it is driven where this runs as root; unprivileged, the fixture is
# untrusted and prints nothing either way, which is asserted as the refusal direction.
printf '%s\n' 'AI_TOOLS_AGENTS=[claude-code, agent-codex]' 'AI_TOOLS_INTEGRATIONS=[integration-dotnet]' \
    'AI_TOOLS_FILTERS=[core, filter-dotnet]' 'OPERATORS=[x]' > "${kind_conf}"
chmod 0644 "${kind_conf}"
unmigrated="$(ai_tools_conf__find_unmigrated_items "${kind_conf}")"
if ai_tools_conf__is_trusted "${kind_conf}"; then
    [[ "${unmigrated}" == $'AI_TOOLS_AGENTS\tclaude-code\nAI_TOOLS_FILTERS\tcore' ]] \
        && pass "the unmigrated items are listed by key, in table order" \
        || fail "unmigrated items: got '${unmigrated//$'\n'/|}'"
    printf '%s\n' 'AI_TOOLS_AGENTS=[agent-claude-code' 'AI_TOOLS_FILTERS=[filter-dotnet]' > "${kind_conf}"
    [[ -z "$(ai_tools_conf__find_unmigrated_items "${kind_conf}")" ]] \
        && pass "a migrated file and a list the grammar refuses list no unmigrated item" \
        || fail "a migrated file listed unmigrated items: $(ai_tools_conf__find_unmigrated_items "${kind_conf}")"
    chmod 0666 "${kind_conf}"
    printf 'AI_TOOLS_AGENTS=[claude-code]\n' > "${kind_conf}"
fi
[[ -z "$(ai_tools_conf__find_unmigrated_items "${kind_conf}")" ]] \
    && pass "an untrusted file lists no unmigrated item (the trust refusal reports it)" \
    || fail "an untrusted file listed unmigrated items"

# --- ai_tools_conf__set_list: writes the bracketed form in place and reads it back ------------------------------------
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
    if ai_tools_conf__set_list "${list_conf}" K "${item_args[@]+"${item_args[@]}"}" \
            && [[ "$(grep -c '^#\?K=' "${list_conf}")" == 1 && "$(sed -n 2p "${list_conf}")" == "K=${expected}" ]] \
            && [[ "$(sed -n 1p "${list_conf}")" == "# header" && "$(sed -n 3p "${list_conf}")" == "OTHER=kept" ]]; then
        pass "set_list (${items:-no items}) writes K=${expected} in place of the key's line"
    else
        fail "set_list (${items:-no items}): file is now: $(tr '\n' '|' < "${list_conf}")"
    fi
done
# The writer publishes where it wrote -- over the live line, over the commented default, or at the end of a file
# carrying neither -- so a caller tells a file that holds the key's documented slot from one written before the key.
placement_conf="${TESTDIR}/placement.conf"
printf '# header\nK=[old]\nOTHER=kept\n' > "${placement_conf}"
if ai_tools_conf__set_list "${placement_conf}" K new && [[ "${AI_TOOLS_CONF__WRITE_PLACEMENT:-}" == live ]]; then
    pass "set_list over a live line publishes the placement live"
else
    fail "set_list over a live line published '${AI_TOOLS_CONF__WRITE_PLACEMENT:-}'"
fi
printf '# header\n#K=[]\nOTHER=kept\n' > "${placement_conf}"
if ai_tools_conf__set_list "${placement_conf}" K new && [[ "${AI_TOOLS_CONF__WRITE_PLACEMENT:-}" == commented ]]; then
    pass "set_list over the commented default publishes the placement commented"
else
    fail "set_list over the commented default published '${AI_TOOLS_CONF__WRITE_PLACEMENT:-}'"
fi
printf '# header\nOTHER=kept\n' > "${placement_conf}"
if ai_tools_conf__set_list "${placement_conf}" K new && [[ "${AI_TOOLS_CONF__WRITE_PLACEMENT:-}" == appended ]] \
        && [[ "$(tail -n1 "${placement_conf}")" == 'K=[new]' ]]; then
    pass "set_list on a file without the key appends the line and publishes the placement appended"
else
    fail "set_list on a file without the key published '${AI_TOOLS_CONF__WRITE_PLACEMENT:-}': $(tr '\n' '|' < "${placement_conf}")"
fi
# An item that would read back as other items, or end the list, is refused with status 2 and the file left unchanged.
before="$(cat "${list_conf}")"
for bad in 'a b' 'a,b' '[a' 'a]' '"a"' "'a'" 'a#b' '' $'a\nb' $'a\tb'; do
    status=0; ai_tools_conf__set_list "${list_conf}" K ok "${bad}" || status=$?
    if [[ "${status}" == 2 && "$(cat "${list_conf}")" == "${before}" ]]; then
        pass "set_list refuses the item $(printf '%q' "${bad}")"
    else
        fail "set_list accepted the item $(printf '%q' "${bad}") (status ${status})"
    fi
done
status=0; ai_tools_conf__set_list "${list_conf}" 'BAD KEY' a || status=$?
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
    ai_tools_conf__is_trusted "${path}" && verdict=trusted
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
section "conf: ai_tools_conf__is_yes reads a switch the same way whichever key it is"

# The two launch switches read through this function, so a spelling an operator expects -- 1, "true", On -- has to mean
# yes, and 0, "false", off has to mean no. A value in neither set reads as no and is reported, since otherwise
# a mistyped switch changes what a launch does with no line saying so.
if declare -F ai_tools_conf__is_yes >/dev/null 2>&1; then
    yn="${TESTDIR}/switches.conf"
    printf '%s\n' 'A=yes' 'B="true"' 'C=1' "D='1'" 'E=On' 'F=TRUE' \
                   'G=no' 'H="false"' 'I=0' 'J="0"' 'K=off' 'L=' 'M=ture' > "${yn}"
    misread=()
    for key in A B C D E F; do ai_tools_conf__is_yes "${yn}" "${key}" 2>/dev/null || misread+=("${key}"); done
    for key in G H I J K L M ABSENT; do ai_tools_conf__is_yes "${yn}" "${key}" 2>/dev/null && misread+=("${key}"); done
    if (( ${#misread[@]} == 0 )); then
        pass "yes, true, 1, on read as yes and no, false, 0, off, empty, absent and unknown read as no, quoted or not"
    else
        fail "misread switches: ${misread[*]}"
    fi
    said="$(ai_tools_conf__is_yes "${yn}" M 2>&1 || true)"
    assert_msg MSG-D2F9 "${said}" "a value in neither set is reported"
    said="$(ai_tools_conf__is_yes "${yn}" G 2>&1 || true)"
    if [[ -z "${said}" ]]; then
        pass "a recognized no value is read silently"
    else
        fail "a recognized no value was reported: ${said}"
    fi
else
    skip "ai_tools_conf__is_yes" "the deployed conf.lib.sh predates it -- re-run sudo ./install.sh install"
fi

section "conf: ai_tools_conf__is_no reads a switch whose default is yes"
# The mirror for a key in force unless the file turns it off (AI_TOOLS_REQUIRE_SELINUX): only a value the grammar reads
# as no turns it off. A yes value, an absent key and a value in neither set are not no -- the last reported under its
# own code, since a mistyped line otherwise relaxes a requirement with no line saying so.
if declare -F ai_tools_conf__is_no >/dev/null 2>&1; then
    yn="${TESTDIR}/switches-no.conf"
    printf '%s\n' 'A=yes' 'B="true"' 'C=1' "D='1'" 'E=On' 'F=TRUE' \
                   'G=no' 'H="false"' 'I=0' 'J="0"' 'K=off' 'L=' 'M=ture' > "${yn}"
    misread=()
    for key in G H I J K L; do ai_tools_conf__is_no "${yn}" "${key}" 2>/dev/null || misread+=("${key}"); done
    for key in A B C D E F M ABSENT; do ai_tools_conf__is_no "${yn}" "${key}" 2>/dev/null && misread+=("${key}"); done
    if (( ${#misread[@]} == 0 )); then
        pass "no, false, 0, off and empty read as no; yes values, absent and unknown do not, quoted or not"
    else
        fail "misread switches: ${misread[*]}"
    fi
    said="$(ai_tools_conf__is_no "${yn}" M 2>&1 || true)"
    assert_msg MSG-H7N5 "${said}" "a value in neither set is reported as read as yes"
    said="$(ai_tools_conf__is_no "${yn}" A 2>&1 || true)"
    if [[ -z "${said}" ]]; then
        pass "a recognized yes value is read silently"
    else
        fail "a recognized yes value was reported: ${said}"
    fi
else
    skip "ai_tools_conf__is_no" "the deployed conf.lib.sh predates it -- re-run sudo ./install.sh install"
fi

section "conf: a refusal reports the owner and mode it read"
check_reason() {
    local desc="$1" expected="$2" path="$3" got
    got="$(ai_tools_conf__read_untrusted_reason "${path}")"
    if [[ "${got}" == *"${expected}"* ]]; then pass "${desc}"
    else fail "${desc}: got '${got}', expected it to contain '${expected}'"; fi
}
notroot_uid="$(stat -c '%u' "${notroot}")"
check_reason "a non-root owner is reported as the uid read"    "owner=${notroot_uid} mode=644"  "${notroot}"
check_reason "a group-writable mode is reported as read"       "owner=0 mode=664"               "${gw}"
check_reason "the requirement is stated beside the reading"    "expected owner=0"               "${gw}"
check_reason "a symlink is named as the cause"                 "is a symlink"                   "${TESTDIR}/link.conf"
check_reason "a missing path is named as the cause"            "does not exist"                 "${TESTDIR}/absent.conf"
# The clause is owed exactly when this process's uid map is not the identity over the whole uid space, which the kernel
# writes as the one line `0 0 4294967295` in the initial namespace (user_namespaces(7)). A rootless container runs
# the suite under a translated map, so the expectation is read here, apart from the library under test, and the line is
# matched as a regex so the reading does not depend on the IFS in force. An empty map is a namespace whose map is not
# written yet, translated like any other. A map that does not read fails the case: every process has one on a kernel
# with user namespaces, which each supported distribution's is.
uid_map_lines=()
if ! { mapfile -t uid_map_lines < /proc/self/uid_map; } 2>/dev/null; then
    fail "/proc/self/uid_map did not read, so this run's uid map is unknown and the namespace clause is not checked"
else
    identity_uid_map=0
    if (( ${#uid_map_lines[@]} == 1 )) \
            && [[ "${uid_map_lines[0]}" =~ ^[[:space:]]*0[[:space:]]+0[[:space:]]+4294967295[[:space:]]*$ ]]; then
        identity_uid_map=1
    fi
    reason="$(ai_tools_conf__read_untrusted_reason "${notroot}")" || reason="ai_tools_conf__read_untrusted_reason exited non-zero"
    if (( identity_uid_map )) && [[ "${reason}" != *"not the identity"* ]]; then
        pass "under the identity uid map the reason carries no namespace clause"
    elif (( ! identity_uid_map )) && [[ "${reason}" == *"not the identity"* ]]; then
        pass "under a uid map other than the identity the reason names the translation"
    else
        fail "the namespace clause does not follow this run's uid map (identity=${identity_uid_map}): ${reason}"
    fi
fi

# The map parser, over fixture maps. The kernel writes space-padded columns, and the libraries are sourced into scripts
# running under IFS=$'\n\t', so the identity case is also driven from a subshell under that IFS -- a parser inheriting
# it reads the whole line as one field.
map_verdict() {   # <expect: identity|translated> <desc> <map-content>
    local expect="$1" desc="$2" content="$3" got=translated
    printf '%s' "${content}" > "${TESTDIR}/uid_map"
    ai_tools_conf__is_uid_map_identity "${TESTDIR}/uid_map" && got=identity
    if [[ "${got}" == "${expect}" ]]; then pass "${desc}"; else fail "${desc}: read as ${got}"; fi
}
map_verdict identity   "the kernel's padded identity line is identity"     $'         0          0 4294967295\n'
map_verdict translated "a single-uid map is translated"                     $'         0       1000          1\n'
map_verdict translated "a map of several ranges is translated"             $'         0          0 4294967295\n      1000       1000          1\n'
map_verdict translated "an empty map is translated (fails closed)"          ''
map_verdict translated "a four-field line is translated"                    $'0 0 4294967295 0\n'
rm -f "${TESTDIR}/uid_map"
if ! ai_tools_conf__is_uid_map_identity "${TESTDIR}/uid_map"; then
    pass "a missing map file reads as translated"
else
    fail "a missing map file read as identity"
fi
printf '         0          0 4294967295\n' > "${TESTDIR}/uid_map"
if ( IFS=$'\n\t'; ai_tools_conf__is_uid_map_identity "${TESTDIR}/uid_map" ); then
    pass "the identity line parses under IFS=\$'\\n\\t' (the updater's strict mode)"
else
    fail "the identity line did not parse under IFS=\$'\\n\\t'"
fi
# The live verdict agrees with the process's own map, whichever namespace this suite runs in.
live_map="$(</proc/self/uid_map)"
if [[ "${live_map}" =~ ^[[:space:]]*0[[:space:]]+0[[:space:]]+4294967295[[:space:]]*$ ]]; then
    if ai_tools_conf__is_uid_map_identity; then pass "the live map reads as identity where /proc says so"
    else fail "the live map is the identity line yet read as translated"; fi
else
    if ! ai_tools_conf__is_uid_map_identity; then pass "the live map reads as translated where /proc says so"
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
        printf "trusted=%s\n" "$(ai_tools_conf__is_trusted "$2" && echo yes || echo no)"
        printf "reason=%s\n" "$(ai_tools_conf__read_untrusted_reason "$3")"' _ "${LIB}" "${trusted}" "${notroot}" 2>&1)" || true
    if [[ "${ns_out}" == *"trusted=yes"* ]]; then
        pass "inside the namespace a root-owned file is still trusted (root maps to root)"
    else
        fail "inside the namespace the root-owned file was refused: ${ns_out}"
    fi
    if [[ "${ns_out}" == *"owner=65534"*"not the identity"* ]]; then
        pass "inside the namespace the reason reports owner=65534 and names the translation"
    else
        fail "the namespace clause is missing: ${ns_out}"
    fi
fi

# The acceptance path (providers.rule.md, ref-section-x4z9), driven as the projects user: an unprivileged user namespace
# maps its creator to 0, so the file that account owns appears root-owned inside and the predicate accepts it. Skipped
# where that account is refused the namespace.
if ! command -v unshare >/dev/null 2>&1 || ! runuser -u "${PROJECTS_USER}" -- unshare -Ur true 2>/dev/null; then
    skip "inside a namespace an unprivileged account creates, its own file reads as root-owned" \
         "unshare -Ur is not permitted for ${PROJECTS_USER}"
else
    # shellcheck disable=SC2016  # $1..$2 are the inner shell's positionals, passed after `_`
    ns_out="$(runuser -u "${PROJECTS_USER}" -- unshare -Ur bash -c '
        source "$1" || exit 9
        printf "owner=%s trusted=%s\n" "$(stat -c %u "$2")" "$(ai_tools_conf__is_trusted "$2" && echo yes || echo no)"' \
        _ "${LIB}" "${notroot}" 2>&1)" || true
    if [[ "${ns_out}" == *"owner=0 trusted=yes"* ]]; then
        pass "inside a namespace the projects user creates, its own file reads as owner 0 and the predicate accepts it"
    else
        fail "the acceptance-side reading inside the projects user's namespace was not observed: ${ns_out}"
    fi
fi

# --- Sidecar files: what an upgrade preserves when it rewrites an operator's config ------------
# Two copies with two jobs -- .bak is what the operator HAD, .shipped is what they were SUPPOSED to get --
# and the property that makes .bak worth calling a backup is that a second run in the same day cannot overwrite
# the first: ai_tools_conf__find_sidecar_path numbers each copy one past the highest the day already holds. An operator
# who ran the installer twice is exactly the one who needs the earlier copy.
stamp="$(date +%Y%m%d)"
cfg="${TESTDIR}/sidecar.conf"
printf 'ORIGINAL\n' > "${cfg}"; chown root:root "${cfg}"; chmod 640 "${cfg}"

first_bak="$(ai_tools_conf__write_backup "${cfg}")"
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
second_bak="$(ai_tools_conf__write_backup "${cfg}")"
if [[ "${second_bak}" == "${cfg}.${stamp}-2.bak" && "$(cat "${first_bak}")" == ORIGINAL ]]; then
    pass "a same-day second backup takes the next number and leaves the first intact"
else
    fail "same-day backup collided: ${second_bak}"
fi

# The reference copy takes the DEPLOYED file's owner and mode, never the source tree's, so a baseline dropped beside
# a 0640 control-plane file is not left world-readable.
baseline="${TESTDIR}/sidecar.shipped-src"
printf 'SHIPPED\n' > "${baseline}"; chmod 666 "${baseline}"
ref="$(ai_tools_conf__ensure_reference "${cfg}" "${baseline}")"
if [[ "${ref}" == "${cfg}.${stamp}-1.shipped" && "$(perm "${ref}")" == 640 ]]; then
    pass "a reference copy is date-stamped and takes the deployed file's mode"
else
    fail "reference path/mode wrong: ${ref} mode $(perm "${ref}" 2>/dev/null)"
fi
# A repeated offer of the SAME baseline resolves to the copy already there, so a host re-running the installer
# against an unchanged source tree collects one sidecar rather than one per run.
if [[ "$(ai_tools_conf__ensure_reference "${cfg}" "${baseline}")" == "${ref}" && "$(cat "${ref}")" == SHIPPED ]]; then
    pass "an unchanged baseline reuses the copy beside the file"
else
    fail "an unchanged baseline did not resolve to ${ref}"
fi

# A DIFFERENT baseline is a different answer to "what was I supposed to get?", so it takes its own dated copy and leaves
# the earlier one readable.
printf 'SHIPPED v2\n' > "${baseline}"
second_ref="$(ai_tools_conf__ensure_reference "${cfg}" "${baseline}")"
if [[ "${second_ref}" != "${ref}" && "$(cat "${ref}")" == SHIPPED && "$(perm "${second_ref}")" == 640 ]]; then
    pass "a changed baseline adds a copy rather than overwriting the first"
else
    fail "changed-baseline copy wrong: ${second_ref}"
fi

# The copy a reconcile compares a kept file with is the NEWEST beside it, whichever route left it: a package copy
# (.rpmnew) and an installer copy (.shipped) are ordered by modification time, the package copy wins a tie, and both
# the numbered and the earlier unnumbered day forms of a .shipped are read.
lc="${TESTDIR}/latest.conf"
printf 'LIVE\n' > "${lc}"
if ! ai_tools_conf__find_latest_copy "${lc}" >/dev/null 2>&1; then
    pass "a file with no copy beside it has no latest copy"
else
    fail "a latest copy was invented where none exists"
fi
# latest_is <expected> <what>: the latest copy beside ${lc} is <expected>.
latest_is() {
    local got
    got="$(ai_tools_conf__find_latest_copy "${lc}")" || got="<none>"
    if [[ "${got}" == "$1" ]]; then pass "$2"; else fail "$2: got ${got}, expected $1"; fi
}
printf 'RPM\n' > "${lc}.rpmnew"; touch -d 2024-01-01 "${lc}.rpmnew"
latest_is "${lc}.rpmnew" "a package copy alone is the latest copy"
printf 'SRC\n' > "${lc}.20250101-1.shipped"; touch -d 2025-01-01 "${lc}.20250101-1.shipped"
latest_is "${lc}.20250101-1.shipped" "an installer copy newer than the package copy is the latest"
touch -d 2026-01-01 "${lc}.rpmnew"
latest_is "${lc}.rpmnew" "a package copy newer than the installer copy is the latest"
touch -d 2026-01-01 "${lc}.20250101-1.shipped"
latest_is "${lc}.rpmnew" "the package copy wins a tie"
printf 'SRC2\n' > "${lc}.20250102.shipped"; touch -d 2027-01-01 "${lc}.20250102.shipped"
latest_is "${lc}.20250102.shipped" "the unnumbered day form of an installer copy is read too"
rm -f "${lc}" "${lc}".*

# That order is a reading of the clock, so a file dated after now is reported as the clock being behind: printed
# with its date, the status failing, and a set of files dated in the past passes in silence. A path that is not a file
# is not read.
printf 'LIVE\n' > "${lc}"; printf 'RPM\n' > "${lc}.rpmnew"; touch -d 2024-01-01 "${lc}.rpmnew"
if ai_tools_conf__find_paths_ahead_of_clock "${lc}" "${lc}.rpmnew" "${lc}.absent" >/dev/null; then
    pass "files dated in the past do not read as a clock that is behind"
else
    fail "a past-dated file read as a clock that is behind"
fi
touch -d '+2 days' "${lc}.rpmnew"
if ! behind="$(ai_tools_conf__find_paths_ahead_of_clock "${lc}" "${lc}.rpmnew")" \
        && [[ "${behind}" == *$'\t'"${lc}.rpmnew" && "${behind}" != *"${lc}"$'\t'* ]] \
        && [[ "${behind%%$'\t'*}" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    pass "a file dated after now reads as a clock that is behind, printed with its date, and the others are not listed"
else
    fail "future-dated file: $(ai_tools_conf__find_paths_ahead_of_clock "${lc}" "${lc}.rpmnew" || true)"
fi
rm -f "${lc}" "${lc}".*

# Absent inputs produce no copy and no path -- a caller must never act on a name that was not made.
if ! ai_tools_conf__write_backup "${TESTDIR}/absent" >/dev/null 2>&1; then
    pass "no backup is invented for a file that is not there"
else
    fail "backed up a nonexistent file"
fi
if ! ai_tools_conf__ensure_reference "${cfg}" "${TESTDIR}/absent" >/dev/null 2>&1; then
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
if ai_tools_conf__find_new_keys found "${kept_conf}" "${shipped_conf}" \
        && [[ "${found[*]}" == "NEW_OPTION" ]]; then
    pass "an option the kept file never mentions is reported"
else
    fail "new-option detection returned '${found[*]:-}'"
fi

declare -a same=()
if ! ai_tools_conf__find_new_keys same "${shipped_conf}" "${shipped_conf}"; then
    pass "a current file reports nothing"
else
    fail "a current file reported '${same[*]}'"
fi

# Both "seen" forms: a live setting and a commented-out default.
printf 'NEW_OPTION="b"\n' >> "${kept_conf}"
declare -a live=()
if ! ai_tools_conf__find_new_keys live "${kept_conf}" "${shipped_conf}"; then
    pass "an option the operator has set is not announced as new"
else
    fail "announced an already-set option: ${live[*]}"
fi
printf '# older file\nEXISTING_OPTION="a"\n#NEW_OPTION="b"\n' > "${kept_conf}"
declare -a commented=()
if ! ai_tools_conf__find_new_keys commented "${kept_conf}" "${shipped_conf}"; then
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
if ai_tools_conf__find_new_keys examples "${example_conf}" "${shipped_conf}" \
        && [[ "${examples[*]}" == "EXISTING_OPTION NEW_OPTION" ]]; then
    pass "an indented example in a header block mentions nothing"
else
    fail "prose examples were read as mentions (reported '${examples[*]:-}')"
fi

# --- Allowlist membership: one exact-entry matcher every consumer shares -----------------------
# The launch wrapper, the CLI (reg/unreg/read_project_state), and the relabel helper all decide "is this path listed"
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
    ai_tools_conf__has_allowlist_entry "${al}" "${path}" && verdict=member
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

if ai_tools_conf__has_allowlist_exclusion "${al}" "${al_root}/excluded" \
        && ! ai_tools_conf__has_allowlist_exclusion "${al}" "${al_root}/proj"; then
    pass "has_exclusion matches only the '!' line"
else
    fail "has_exclusion did not isolate the exclusion entry"
fi

# --- The gate's read: ai_tools_conf__load_allowlist + ai_tools_conf__is_path_excluded ---------------
# The launch wrapper and every walking helper take their two arrays from this loader. Under test is the union rule
# for an exclusion -- the written form always, the resolved form only through a symlink the sandbox account can neither
# remove nor replace -- and that any other link refuses the whole read (the section comment in conf.lib.sh states why).
ld_root="${TESTDIR}/ld"
mkdir -p "${ld_root}/proj/sub/deep" "${ld_root}/proj/private" "${ld_root}/proj/stale"
# The owner's sub-link sits in directories only the owner writes, under a sticky /tmp, which the walk accepts.
chmod 755 "${ld_root}" "${ld_root}/proj"
ln -s "${ld_root}/proj/sub" "${ld_root}/sub-link"          # the operator's spelling of a carve-out
ld_al="${TESTDIR}/ld-allowed-projects"
cat > "${ld_al}" <<EOF
${ld_root}/proj
!${ld_root}/proj/private
!${ld_root}/sub-link/
!${ld_root}/proj/*.log
!${ld_root}/gone/../proj/stale
EOF
declare -a ld_allowed=() ld_excluded=()
if ai_tools_conf__load_allowlist "${ld_al}" ld_allowed ld_excluded \
        && [[ "${#ld_allowed[@]}" -eq 1 && "${ld_allowed[0]}" == "${ld_root}/proj" ]]; then
    pass "load resolves the allow entry and returns 0"
else
    fail "load: rc or allowed=(${ld_allowed[*]:-})"
fi
ld_has() { local e; for e in "${ld_excluded[@]}"; do [[ "${e}" == "$1" ]] && return 0; done; return 1; }
if ld_has "${ld_root}/proj/private" && ld_has "${ld_root}/sub-link/" \
        && ld_has "${ld_root}/proj/*.log" && ld_has "${ld_root}/gone/../proj/stale"; then
    pass "every exclusion is kept as written"
else
    fail "a written exclusion is missing from (${ld_excluded[*]})"
fi
if ld_has "${ld_root}/proj/sub" && ld_has "${ld_root}/proj/stale"; then
    pass "a glob-free exclusion through the owner's symlink, and one with .., gain their resolved form"
else
    fail "resolved forms missing from (${ld_excluded[*]})"
fi
ld_dupes="$(printf '%s\n' "${ld_excluded[@]}" | sort | uniq -d)"
if [[ -z "${ld_dupes}" ]] && ! ld_has "${ld_root}/proj/private/"; then
    pass "an exclusion whose resolved form is its written form is kept once"
else
    fail "duplicates or a spurious form: ${ld_dupes:-none} (${ld_excluded[*]})"
fi
ld_glob_forms="$(printf '%s\n' "${ld_excluded[@]}" | grep -c '\.log$' || true)"
if [[ "${ld_glob_forms}" == 1 ]]; then
    pass "a glob exclusion is kept as written alone"
else
    fail "the glob exclusion appears ${ld_glob_forms} time(s)"
fi
# The launch wrapper sources the library under IFS=$'\n\t', where a `read` of two space-separated `stat` fields into two
# variables puts both in the first unless the read pins its own IFS; the same file must load to the same arrays.
declare -a ld_ifs_allowed=() ld_ifs_excluded=()
ld_ifs_rc=0; ld_saved_ifs="${IFS}"; IFS=$'\n\t'
ai_tools_conf__load_allowlist "${ld_al}" ld_ifs_allowed ld_ifs_excluded 2>"${TESTDIR}/ld-ifs.err" || ld_ifs_rc=$?
IFS="${ld_saved_ifs}"
if [[ "${ld_ifs_rc}" -eq 0 && "${ld_ifs_allowed[*]}" == "${ld_allowed[*]}" \
        && "${ld_ifs_excluded[*]}" == "${ld_excluded[*]}" ]]; then
    pass "the loader reads the same arrays under the launch wrapper's IFS"
else
    fail "under the launch wrapper's IFS: rc ${ld_ifs_rc}, excluded=(${ld_ifs_excluded[*]:-}): $(cat "${TESTDIR}/ld-ifs.err")"
fi
# A link the sandbox account can change, aimed at the directory a carve-out covers: the owner's own link
# in a group-writable directory (a claimed project's shape, whoever made the link), and -- as root, where the fixture
# link can be re-owned -- a link another account holds in a directory it cannot write. Each must refuse the read whole:
# rc 2, both arrays empty, the code, the link, the reason and the remedy on stderr; the control is the same file minus
# that line, which the first load of this section reads clean.
ld_refused() {   # ld_refused <what> <allowlist> <link> <reason-fragment>
    local -a ld_fa=(x) ld_fe=(y)
    local rc=0 err
    ai_tools_conf__load_allowlist "$2" ld_fa ld_fe 2>"${TESTDIR}/ld-refused.err" || rc=$?
    err="$(cat "${TESTDIR}/ld-refused.err")"
    if [[ "${rc}" -eq 2 && "${#ld_fa[@]}" -eq 0 && "${#ld_fe[@]}" -eq 0 ]]; then
        pass "$1 refuses the read: rc 2, both arrays empty"
    else
        fail "$1 did not refuse the read: rc ${rc}, allowed=(${ld_fa[*]:-}) excluded=(${ld_fe[*]:-})"
    fi
    assert_msg MSG-Y5N6 "${err}" "$1: the refusal carries its code"
    if grep -qF -- "$3 is a symbolic link $4" <<<"${err}" && grep -qF -- "real path" <<<"${err}"; then
        pass "$1: the refusal names the link, the reason and the remedy"
    else
        fail "$1: the refusal does not name the link, the reason or the remedy: ${err}"
    fi
}
chmod 2770 "${ld_root}/proj"
ln -s "${ld_root}/proj/private" "${ld_root}/proj/alias"
cp "${ld_al}" "${ld_al}.writable"; printf '!%s\n' "${ld_root}/proj/alias" >> "${ld_al}.writable"
ld_refused "an exclusion through the owner's own link in a group-writable directory" "${ld_al}.writable" \
    "${ld_root}/proj/alias" "under ${ld_root}/proj, a directory with a group or other write bit"
# The link's own directory is closed and its parent is not: the account renames the holding directory aside, the written
# path then no longer exists, and the real directory it aimed at stays where it was.
mkdir -m 755 "${ld_root}/proj/links"; ln -s "${ld_root}/proj/private" "${ld_root}/proj/links/alias"
cp "${ld_al}" "${ld_al}.ancestor"; printf '!%s\n' "${ld_root}/proj/links/alias" >> "${ld_al}.ancestor"
ld_refused "an exclusion through the owner's link in a closed directory under a group-writable one" "${ld_al}.ancestor" \
    "${ld_root}/proj/links/alias" "under ${ld_root}/proj, a directory with a group or other write bit"
if [[ "${EUID}" -eq 0 ]] && id nobody >/dev/null 2>&1; then
    mkdir -m 755 "${ld_root}/stable"; ln -s "${ld_root}/proj/private" "${ld_root}/stable/foreign"
    chown -h nobody "${ld_root}/stable/foreign"
    cp "${ld_al}" "${ld_al}.foreign"; printf '!%s\n' "${ld_root}/stable/foreign" >> "${ld_al}.foreign"
    ld_refused "an exclusion through a link another account holds" "${ld_al}.foreign" \
        "${ld_root}/stable/foreign" "held by uid"
else
    skip "an exclusion through a link another account holds refuses the read" "needs root to re-own the fixture link"
fi
# A carve-out written as the real path keeps covering it whatever happens to an alias beside it -- the link present,
# unlinked, or a directory of its name put in its place -- since no entry depends on the link.
cp "${ld_al}" "${ld_al}.canonical"
ld_canonical_ok=true
for ld_alias_state in link removed directory; do
    case "${ld_alias_state}" in
        removed)   rm -f "${ld_root}/proj/alias" ;;
        directory) mkdir "${ld_root}/proj/alias" ;;
    esac
    # shellcheck disable=SC2034  # filled and read through their names by the loader and the matcher
    declare -a ld_ca=() ld_ce=()
    if ! ai_tools_conf__load_allowlist "${ld_al}.canonical" ld_ca ld_ce \
            || ! ai_tools_conf__is_path_excluded "${ld_root}/proj/private" ld_ce \
            || ! ai_tools_conf__is_path_excluded "${ld_root}/proj/private/k" ld_ce; then
        fail "with the alias ${ld_alias_state}, the real-path carve-out stopped covering ${ld_root}/proj/private"
        ld_canonical_ok=false
    fi
done
${ld_canonical_ok} && pass "a real-path carve-out covers its directory with the alias present, removed, and replaced by a directory"
rm -rf "${ld_root}/proj/alias" "${ld_root}/proj/links"; chmod 755 "${ld_root}/proj"
ld_ok=true
for p in "${ld_root}/proj/private" "${ld_root}/proj/private/k" "${ld_root}/proj/sub" "${ld_root}/proj/sub/deep" \
         "${ld_root}/proj/x.log" "${ld_root}/proj/stale/y"; do
    ai_tools_conf__is_path_excluded "${p}" ld_excluded || { fail "should be excluded: ${p}"; ld_ok=false; }
done
for p in "${ld_root}/proj/other" "${ld_root}/proj/x.log/y" "${ld_root}/proj/privateer"; do
    ai_tools_conf__is_path_excluded "${p}" ld_excluded && { fail "should not be excluded: ${p}"; ld_ok=false; }
done
${ld_ok} && pass "the matcher covers a written path, its contents, a resolved path and a glob, and no sibling"
# shellcheck disable=SC2034  # read through its name by the matcher
declare -a ld_none=()
if ! ai_tools_conf__is_path_excluded "${ld_root}/proj" ld_none; then
    pass "an empty exclusion array excludes no path"
else
    fail "an empty exclusion array excluded a path"
fi
declare -a ld_a2=(x) ld_e2=(y)
if ! ai_tools_conf__load_allowlist "${ld_root}" ld_a2 ld_e2 && [[ "${#ld_a2[@]}" -eq 0 && "${#ld_e2[@]}" -eq 0 ]] \
        && ! ai_tools_conf__load_allowlist "${TESTDIR}/absent-allowlist" ld_a2 ld_e2; then
    pass "a directory or an absent file returns 1 with both arrays empty"
else
    fail "load over a directory or an absent file: rc 0 or arrays (${ld_a2[*]:-}) (${ld_e2[*]:-})"
fi
glob_ok=true
for p in '/a/*.log' '/a/b?' '/a/[cd]'; do
    ai_tools_conf__has_glob_characters "${p}" || { fail "has_glob missed ${p}"; glob_ok=false; }
done
for p in '/a/plain' '/a/b]' ''; do
    ai_tools_conf__has_glob_characters "${p}" && { fail "has_glob matched '${p}'"; glob_ok=false; }
done
${glob_ok} && pass "has_glob reads *, ? and [ as glob characters and a lone ] or a plain path as none"

# The line-identifying variant returns the VERBATIM source line (comment and all), which is what an anchored sed deletes
# -- reconstructing it from the path would miss a commented/quoted entry and leave it behind. Two-ended
# with the boundary suite: the agent cannot write the allowlist.
declare -a matched=()
if ai_tools_conf__read_allowlist_matching_lines matched "${al}" "${al_root}/commented" \
        && [[ "${#matched[@]}" -eq 1 && "${matched[0]}" == "${al_root}/commented    # main repo" ]]; then
    pass "matching_lines returns the raw commented line verbatim for deletion"
else
    fail "matching_lines returned '${matched[*]:-}'"
fi
matched=()
if ai_tools_conf__read_allowlist_matching_lines matched "${al}" "${al_root}/quoted dir" \
        && [[ "${matched[0]}" == "\"${al_root}/quoted dir\"" ]]; then
    pass "matching_lines returns the raw quoted line verbatim"
else
    fail "matching_lines did not return the quoted line: '${matched[*]:-}'"
fi
matched=()
if ! ai_tools_conf__read_allowlist_matching_lines matched "${al}" "${al_root}/excluded"; then
    pass "matching_lines skips exclusion lines (never deletes an exclusion as a membership)"
else
    fail "matching_lines matched an exclusion line: '${matched[*]:-}'"
fi

# The two forms that ARE defaults stay defaults, hard against the '#' and one space in.
printf '#EXISTING_OPTION="a"\n# NEW_OPTION="b"\n' > "${kept_conf}"
declare -a spaced=()
if ! ai_tools_conf__find_new_keys spaced "${kept_conf}" "${shipped_conf}"; then
    pass "both commented-default forms (#KEY= and # KEY=) count as mentions"
else
    fail "a commented default was missed: ${spaced[*]}"
fi

# The scan is a reader, not a writer, and must not leave state in its caller.
seen_key="SENTINEL"
# shellcheck disable=SC2034  # the output array is deliberately unread here: this case asserts
# the scan's effect on OTHER variables, not its result
declare -a discarded=()
ai_tools_conf__find_new_keys discarded "${kept_conf}" "${shipped_conf}" >/dev/null 2>&1 || true
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
    ai_tools_conf__parse_path_entry "${line}" || rc=$?
    if [[ "${want}" == SKIP ]]; then
        if [[ "${rc}" -ne 0 ]]; then pass "${desc}"; else fail "${desc}: yielded '${ai_tools_conf__value}'"; fi
    elif [[ "${rc}" -eq 0 && "${ai_tools_conf__value}" == "${want}" ]]; then
        pass "${desc}"
    else
        fail "${desc}: rc ${rc}, got '${ai_tools_conf__value}', expected '${want}'"
    fi
}
check_entry "a plain path is unchanged"            /home/me/project         '/home/me/project'
check_entry "an exclusion keeps its !"             '!/home/me/vendor'       '!/home/me/vendor'
check_entry "a glob exclusion stays raw"           '!/home/me/*/node_mod'   '!/home/me/*/node_mod'
check_entry "a park keeps its %"                   '%/home/me/parked'       '%/home/me/parked'
check_entry "a park may be quoted"                 '%/home/me/my project'   '%"/home/me/my project"'
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

# --- The registry grammar: the marker, the resolver, the validator, the loader's kinds ---------
# One validator decides whether a reader may trust a registry at all, and a file it refuses does not allow any path
# for any reader. Each reason token is driven on a line of its own, with the line number and the line asserted
# on stderr, under the launch wrapper's IFS, which is the shell the gate reads the file in.
section "conf: the project registry grammar (unit)"

if ! declare -F ai_tools_conf__validate_registry >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__resolve_registry >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__read_registry_format >/dev/null 2>&1; then
    fail "${LIB} defines no registry grammar functions"
    finish; exit
fi
REG_MARKER="# ai-tools-project-registry-format: 1.0"
if [[ "$(ai_tools_conf__get_registry_marker)" == "${REG_MARKER}" ]]; then
    pass "the marker line is '${REG_MARKER}'"
else
    fail "the marker line is '$(ai_tools_conf__get_registry_marker)'"
fi

reg_dir="${TESTDIR}/reg"; mkdir -p "${reg_dir}"
printf '%s\n' "# a note" "${REG_MARKER}" "/a" > "${reg_dir}/project-registry"
printf '%s\n' "/a" > "${reg_dir}/plain"
if [[ "$(ai_tools_conf__read_registry_format "${reg_dir}/project-registry")" == 1.0 \
        && "$(ai_tools_conf__read_registry_format "${reg_dir}/plain")" == legacy ]]; then
    pass "the format reader takes the first marker wherever it sits, and reads none as legacy"
else
    fail "the format reader: '$(ai_tools_conf__read_registry_format "${reg_dir}/project-registry")' / '$(ai_tools_conf__read_registry_format "${reg_dir}/plain")'"
fi

# The resolver: `allowed-projects` decides while it exists, whether or not `projects` is beside it.
res_dir="${TESTDIR}/res"; mkdir -p "${res_dir}"
resolved_is() {
    local got; got="$(ai_tools_conf__resolve_registry "${res_dir}/")"
    if [[ "${got}" == "$1"$'\t'"${res_dir}/$2" ]]; then pass "$3"; else fail "$3: got '${got}'"; fi
}
resolved_is none project-registry "with neither file the resolver reads none, at the project-registry path"
printf '%s\n' "${REG_MARKER}" > "${res_dir}/project-registry"
resolved_is current project-registry "project-registry alone reads current"
printf '%s\n' "/a" > "${res_dir}/allowed-projects"
resolved_is legacy allowed-projects "allowed-projects beside project-registry reads legacy"
mv "${res_dir}/allowed-projects" "${res_dir}/allowed-projects.20261030-1.bak"
resolved_is current project-registry "a .bak copy is not an active name"

# The grammar a file is read under: the two registry names decide; another name reads its content.
grammar_is() {
    local got; got="$(ai_tools_conf__read_registry_grammar "$2")"
    if [[ "${got}" == "$1" ]]; then pass "$3"; else fail "$3: got '${got}'"; fi
}
grammar_is current "${reg_dir}/project-registry" "a file named project-registry is read under the current grammar"
grammar_is legacy  "${res_dir}/allowed-projects.20261030-1.bak" "a file of another name without a marker reads legacy"
printf '%s\n' "${REG_MARKER}" > "${reg_dir}/hooked"
grammar_is current "${reg_dir}/hooked" "a file of another name carrying a marker reads current"

# refused_line <reason> <grammar> <line> : a file holding the marker (current grammar) and <line> as line 2, or <line>
# alone as line 1 (legacy), is refused with status 3 and MSG-B8U2 naming the file, the line number, the reason
# and the line.
refused_line() {
    local reason="$1" grammar="$2" line="$3" file number rc=0 err saved_ifs="${IFS}"
    if [[ "${grammar}" == current ]]; then
        file="${reg_dir}/project-registry"; printf '%s\n' "${REG_MARKER}" "${line}" > "${file}"; number=2
    else
        file="${reg_dir}/allowed-projects"; printf '%s\n' "${line}" > "${file}"; number=1
    fi
    IFS=$'\n\t'
    ai_tools_conf__validate_registry "${file}" "${grammar}" 2>"${TESTDIR}/reg.err" || rc=$?
    IFS="${saved_ifs}"
    err="$(cat "${TESTDIR}/reg.err")"
    if [[ "${rc}" -eq 3 ]] && grep -qF -- "${file} line ${number}: ${reason}: ${line//[[:cntrl:]]/?}" <<<"${err}"; then
        pass "${reason}: '${line}' is refused (3), naming the file, the line number and the line"
    else
        fail "${reason}: '${line}' gave rc ${rc}: ${err}"
    fi
    assert_msg MSG-B8U2 "${err}" "${reason}: the refusal carries its code"
}
refused_line unknown-form       current 'home/op/project'
# shellcheck disable=SC2088  # the tilde is the line under test, written as an operator might type it
refused_line unknown-form       current '~/project'
refused_line relative-path      current '!vendor'
refused_line relative-path      current '%"parked"'
refused_line empty-entry        current '!'
refused_line empty-entry        current '%   # why'
refused_line empty-entry        current '""'
refused_line unmatched-quote    current '"/home/op/a b'
refused_line text-after-quote   current '!"/home/op/p/private"suffix'
refused_line text-after-quote   current "'/home/op/c d'tail"
refused_line text-after-quote   current '%"/home/op/parked" x'
refused_line text-after-quote   legacy  '"/home/op/p" !/home/op/p/private'
refused_line control-character  current $'/home/op/a\tb'
refused_line control-character  current $'!"/home/op/c\x01d"'
refused_line control-character  legacy  $'/home/op/a\tb'
refused_line glob-on-allow      current '/home/op/*'
refused_line glob-on-park       current '%/home/op/p?'
refused_line marker-repeated    current "${REG_MARKER}"
refused_line marker-unsupported current '# ai-tools-project-registry-format: 2.0'
refused_line park-in-legacy     legacy  '%/home/op/parked'
refused_line marker-in-legacy   legacy  "${REG_MARKER}"
refused_line unknown-form       current $'\x1b[31m/home/op'
# The major is compared as text, so one past 2^64 does not wrap to 1 and a zero-padded 1 is still 1.
refused_line marker-unsupported current '# ai-tools-project-registry-format: 18446744073709551617.0'
refused_line marker-unsupported current '# ai-tools-project-registry-format: 1000000000000000000000000000000000000001.0'
printf '%s\n' "# ai-tools-project-registry-format: 01.0" "/home/op/p" > "${reg_dir}/project-registry"
if ai_tools_conf__validate_registry "${reg_dir}/project-registry" current 2>"${TESTDIR}/reg.err"; then
    pass "a zero-padded major 01 reads as format 1"
else
    fail "a zero-padded major 01 was refused: $(cat "${TESTDIR}/reg.err")"
fi

# nul_refused <line-number> <desc> <printf-format> : a file printf writes from <printf-format> (the marker as its %s)
# is refused with status 3 as control-character at <line-number>. bash's `read` drops a NUL byte, so the line is
# written through printf's own `\0` escape rather than through refused_line.
nul_refused() {
    local rc=0 err
    # shellcheck disable=SC2059  # the format is the fixture: it carries the \0 escape
    printf "$3" "${REG_MARKER}" > "${reg_dir}/project-registry"
    ai_tools_conf__validate_registry "${reg_dir}/project-registry" current 2>"${TESTDIR}/reg.err" || rc=$?
    err="$(cat "${TESTDIR}/reg.err")"
    if [[ "${rc}" -eq 3 ]] && grep -qF -- "${reg_dir}/project-registry line $1: control-character" <<<"${err}"; then
        pass "control-character: $2 is refused (3) at line $1"
    else
        fail "control-character: $2 gave rc ${rc}: ${err}"
    fi
}
nul_refused 2 "a NUL in an allow line"   '%s\n/home/op/pri\0vate\n'
nul_refused 3 "a NUL in a carve-out"     '%s\n/home/op/p\n!/home/op/p/pri\0vate\n'
nul_refused 2 "a NUL in a park"          '%s\n%%/home/op/par\0ked\n'
nul_refused 2 "a NUL in a comment"       '%s\n# a no\0te\n/home/op/p\n'
nul_refused 1 "a NUL in the marker line" '# ai-tools-project-registry-\0format: 1.0\n/home/op/p\n'
if grep -qF -- "line 1: control-character: # ai-tools-project-registry-?format: 1.0" "${TESTDIR}/reg.err"; then
    pass "the refused line shows the NUL as '?'"
else
    fail "the refused line as shown: $(cat "${TESTDIR}/reg.err")"
fi
# write_padded_registry <file> <printf-format> : <printf-format> (the marker as its %s), then 1 MiB of comment lines,
# more than a pipe buffer, so a scan that stops reading at its first match leaves the writer blocked on a full pipe.
write_padded_registry() {
    # shellcheck disable=SC2059  # the format is the fixture: it carries the \0 escape
    { printf "$2" "${REG_MARKER}"; head -c 1048576 /dev/zero | tr '\0' '#' | fold -w 79; echo; } > "$1"
}
# The file runs under `set -o pipefail`, as the callers do, which is where a scan closed early read a NUL as absent.
write_padded_registry "${reg_dir}/project-registry" '%s\n/home/op/pri\0vate\n'
rc=0; ai_tools_conf__validate_registry "${reg_dir}/project-registry" current 2>"${TESTDIR}/reg.err" || rc=$?
if [[ "${rc}" -eq 3 ]] && grep -qF "project-registry line 2: control-character" "${TESTDIR}/reg.err"; then
    pass "control-character: a NUL ahead of 1 MiB of comments is refused (3) at line 2 under pipefail"
else
    fail "control-character: a NUL ahead of 1 MiB of comments gave rc ${rc}: $(cat "${TESTDIR}/reg.err")"
fi
pad_allowed=(stale); pad_excluded=(stale); rc=0
ai_tools_conf__load_allowlist "${reg_dir}/project-registry" pad_allowed pad_excluded 2>/dev/null || rc=$?
if [[ "${rc}" -eq 3 && ${#pad_allowed[@]} -eq 0 && ${#pad_excluded[@]} -eq 0 ]]; then
    pass "the loader refuses the padded NUL file (3) with both arrays empty"
else
    fail "the loader over the padded NUL file: rc ${rc}, ${#pad_allowed[@]} allowed, ${#pad_excluded[@]} excluded"
fi
write_padded_registry "${reg_dir}/project-registry" '%s\n/home/op/private\n'
if ai_tools_conf__validate_registry "${reg_dir}/project-registry" current 2>"${TESTDIR}/reg.err"; then
    pass "the control: the same padded file without the NUL validates under pipefail"
else
    fail "the padded file without a NUL was refused: $(cat "${TESTDIR}/reg.err")"
fi
# A scan that cannot run is a file that cannot be read: the library calls tr by name, so a function stands in for it.
rc=0; pad_allowed=(stale); pad_excluded=(stale)
( tr() { return 3; }
  ai_tools_conf__validate_registry "${reg_dir}/project-registry" current ) 2>"${TESTDIR}/reg.err" || rc=$?
scan_rc=0
( tr() { return 3; }
  load_rc=0; ai_tools_conf__load_allowlist "${reg_dir}/project-registry" pad_allowed pad_excluded || load_rc=$?
  (( load_rc == 1 )) || exit 8
  (( ${#pad_allowed[@]} == 0 && ${#pad_excluded[@]} == 0 )) || exit 9 ) 2>/dev/null || scan_rc=$?
if [[ "${rc}" -eq 1 && "${scan_rc}" -eq 0 ]]; then
    assert_msg MSG-C6P5 "$(cat "${TESTDIR}/reg.err")" "a tr that fails refuses the file (1), the loader's arrays empty"
else
    fail "a tr that fails: validator rc ${rc}, loader probe ${scan_rc} (8 = loader not 1, 9 = an array kept entries): $(cat "${TESTDIR}/reg.err")"
fi

# One open per read: the loader and the membership reader validate and read one inode. A `tr` standing in for the
# control-byte scan renames a replacement over the registry once the scan has opened the file, so a reader that opens
# the name again reads the replacement -- one holding /pri<NUL>vate, which `read` takes as /private, and one holding
# a relative entry naming a directory under the working directory. The pinned reader returns the original's entries
# and reads neither; the same stub with no replacement waiting is the control.
pin_dir="${TESTDIR}/pin"; mkdir -p "${pin_dir}/proj" "${pin_dir}/private" "${pin_dir}/cwd/rel"
pin_reg="${pin_dir}/project-registry"
pin_proj="$(realpath -e "${pin_dir}/proj")"
printf '%s\n%s\0%s\n' "${REG_MARKER}" "${pin_dir}/pri" "vate" > "${pin_dir}/next-nul"
printf '%s\n%s\n' "${REG_MARKER}" '"rel"' > "${pin_dir}/next-relative"
# pin_run <replacement> <command>... : write the original registry, then run <command> from ${pin_dir}/cwd
# with the renaming `tr` defined; a <replacement> that does not exist leaves the stub without a file to rename.
pin_run() {
    local next="$1"; shift
    printf '%s\n' "${REG_MARKER}" "${pin_dir}/proj" > "${pin_reg}"
    ( cd "${pin_dir}/cwd"
      tr() { if [[ -e "${next}" ]]; then mv -f -- "${next}" "${pin_reg}"; fi; command tr "$@"; }
      "$@" )
}
# pin_load_report : load ${pin_reg} and print `<status>|<allowed entries>`.
pin_load_report() {
    # shellcheck disable=SC2034  # pin_excluded is filled through its name by the loader, and not read
    local -a pin_allowed=() pin_excluded=()
    local status=0
    ai_tools_conf__load_allowlist "${pin_reg}" pin_allowed pin_excluded 2>/dev/null || status=$?
    printf '%s|%s' "${status}" "${pin_allowed[*]}"
}
for pin_case in nul relative; do
    cp -- "${pin_dir}/next-${pin_case}" "${pin_dir}/next"
    pin_got="$(pin_run "${pin_dir}/next" pin_load_report)"
    if [[ -e "${pin_dir}/next" ]] || ! cmp -s -- "${pin_reg}" "${pin_dir}/next-${pin_case}"; then
        fail "one open per read (${pin_case}): the stub did not rename the replacement over the registry"
    elif [[ "${pin_got}" == "0|${pin_proj}" ]]; then
        pass "one open per read (${pin_case}): a replacement renamed in after the open is not read, the original loads"
    else
        fail "one open per read (${pin_case}): the loader read '${pin_got}', expected '0|${pin_proj}'"
    fi
done
pin_got="$(pin_run "${pin_dir}/next" pin_load_report)"
if [[ "${pin_got}" == "0|${pin_proj}" ]]; then
    pass "one open per read: the control, the stub renaming nothing, loads the original"
else
    fail "one open per read: the control loaded '${pin_got}'"
fi
cp -- "${pin_dir}/next-nul" "${pin_dir}/next"
pin_rc=0; pin_run "${pin_dir}/next" ai_tools_conf__has_allowlist_entry "${pin_reg}" "${pin_dir}/private" 2>/dev/null || pin_rc=$?
if [[ -e "${pin_dir}/next" ]]; then
    fail "one open per read (membership): the stub did not rename the replacement over the registry"
elif [[ "${pin_rc}" -ne 0 ]]; then
    pass "one open per read (membership): a replacement renamed in after the open does not make its path a member"
else
    fail "one open per read (membership): /private read as a member of the replacement"
fi

# A directory the reader cannot search hides whether the component under it is a link: the operator's gate refuses
# the read (2) naming the directory, root, which searches every directory, reads the link it holds, and the same
# directory at 0755 is the control as either account.
if (( EUID != 0 )) || ! command -v runuser >/dev/null 2>&1; then
    skip "a directory the reader cannot search" "needs root and runuser"
else
    hid="${TESTDIR}/hid"; mkdir -p "${hid}" "${TESTDIR}/hid-target"
    ln -s "${TESTDIR}/hid-target" "${hid}/inner"
    chown root:root "${hid}" "${TESTDIR}/hid-target"; chown -h root:root "${hid}/inner"
    hid_reg_dir="${TESTDIR}/hidreg"; mkdir -p "${hid_reg_dir}"
    printf '%s\n' "${REG_MARKER}" "!${hid}/inner" > "${hid_reg_dir}/project-registry"
    chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${hid_reg_dir}"
    # hid_load_as <account> : print `<status>` and the loader's stderr for the registry read as <account>.
    # shellcheck disable=SC2016  # $1 and $2 are the inner shell's positionals, passed after `_`
    hid_load_as() {
        local -a as=()
        [[ "$1" == root ]] || as=(runuser -u "$1" --)
        "${as[@]}" bash -c 'source "$1" || exit 9; status=0
            ai_tools_conf__load_allowlist "$2" a e 2>&1 || status=$?; printf "status=%s\n" "${status}"' \
            _ "${LIB}" "${hid_reg_dir}/project-registry"
    }
    for hid_mode in 0700 0755; do
        chmod "${hid_mode}" "${hid}"
        hid_user="$(hid_load_as "${PROJECTS_USER}")"; hid_root="$(hid_load_as root)"
        if [[ "${hid_mode}" == 0700 ]]; then
            if [[ "${hid_user}" == *"status=2"* && "${hid_user}" == *"${hid} is a directory uid ${PROJECTS_UID} cannot search"* ]]; then
                assert_msg MSG-Y5N6 "${hid_user}" "a directory ${PROJECTS_USER} cannot search refuses the read (2), naming it"
            else
                fail "a directory ${PROJECTS_USER} cannot search: ${hid_user}"
            fi
        elif [[ "${hid_user}" == "status=0" ]]; then
            pass "the control: the same directory at 0755 loads as ${PROJECTS_USER} (0)"
        else
            fail "the control at 0755 as ${PROJECTS_USER}: ${hid_user}"
        fi
        if [[ "${hid_root}" == "status=0" ]]; then
            pass "root reads the link under the directory at ${hid_mode} and loads (0)"
        else
            fail "root over the directory at ${hid_mode}: ${hid_root}"
        fi
    done
fi
printf '%s\n' "/home/op/project" > "${reg_dir}/project-registry"
rc=0; ai_tools_conf__validate_registry "${reg_dir}/project-registry" current 2>"${TESTDIR}/reg.err" || rc=$?
if [[ "${rc}" -eq 3 ]] && grep -qF "line 1: marker-missing" "${TESTDIR}/reg.err"; then
    pass "marker-missing: a project-registry file without the marker is refused (3)"
else
    fail "marker-missing: rc ${rc}: $(cat "${TESTDIR}/reg.err")"
fi
# The controls: every line form the grammar accepts, under each grammar.
printf '%s\n' "${REG_MARKER}" "" "# note" "  /home/op/p   # why" "\"/home/op/a b\"" "'/home/op/c d'" \
    "!/home/op/p/vendor" "!/home/op/*/node_modules" "%/home/op/parked" "% \"/home/op/x y\"" \
    "!\"/home/op/p/a b\"   # why" "'/home/op/e f'# note" "# ai-tools-project-registry-format: 1" > "${reg_dir}/project-registry"
if ai_tools_conf__validate_registry "${reg_dir}/project-registry" current 2>"${TESTDIR}/reg.err"; then
    pass "every accepted line form validates under the current grammar"
else
    fail "an accepted line form was refused: $(cat "${TESTDIR}/reg.err")"
fi
printf '%s\n' "# ai-tools-project-registry-format: 1.7" "/home/op/p" > "${reg_dir}/project-registry"
if ai_tools_conf__validate_registry "${reg_dir}/project-registry" current 2>/dev/null; then
    pass "a 1.x minor this release does not know is read"
else
    fail "a 1.x minor was refused"
fi
printf '%s\n' "/home/op/p" "!/home/op/p/vendor" "!/home/op/*/x" > "${reg_dir}/allowed-projects"
if ai_tools_conf__validate_registry "${reg_dir}/allowed-projects" legacy 2>"${TESTDIR}/reg.err"; then
    pass "a legacy file of allow and '!' lines validates under the legacy grammar"
else
    fail "a legacy file was refused: $(cat "${TESTDIR}/reg.err")"
fi

# The loader validates first: a refused file yields every array empty and status 3, and the kinds array names each
# exclusion's line kind, parallel to the exclusion array, the resolved form of a park included.
ldk_root="${TESTDIR}/ldk"; mkdir -p "${ldk_root}/proj/vendor" "${ldk_root}/parked"
chmod 755 "${ldk_root}" "${ldk_root}/proj"
ln -s "${ldk_root}/parked" "${ldk_root}/parked-link"
printf '%s\n' "${REG_MARKER}" "${ldk_root}/proj" "!${ldk_root}/proj/vendor" "%${ldk_root}/parked-link" \
    "!${ldk_root}/proj/*.log" > "${reg_dir}/project-registry"
declare -a ldk_allowed=() ldk_excluded=() ldk_kinds=()
ldk_rc=0; ldk_saved_ifs="${IFS}"; IFS=$'\n\t'
ai_tools_conf__load_allowlist "${reg_dir}/project-registry" ldk_allowed ldk_excluded ldk_kinds 2>"${TESTDIR}/reg.err" || ldk_rc=$?
IFS="${ldk_saved_ifs}"
ldk_pairs="$(paste -d= <(printf '%s\n' "${ldk_excluded[@]}") <(printf '%s\n' "${ldk_kinds[@]}"))"
ldk_want="${ldk_root}/proj/vendor=carve"$'\n'"${ldk_root}/parked-link=park"$'\n'"${ldk_root}/parked=park"$'\n'"${ldk_root}/proj/*.log=carve"
if [[ "${ldk_rc}" -eq 0 && "${ldk_pairs}" == "${ldk_want}" && "${ldk_allowed[*]}" == "${ldk_root}/proj" ]]; then
    pass "the kinds array names each exclusion's kind, parallel to the exclusion array"
else
    fail "load rc ${ldk_rc}, pairs:"$'\n'"${ldk_pairs}"$'\n'"$(cat "${TESTDIR}/reg.err")"
fi
# shellcheck disable=SC2034  # read through its name by the matcher
declare -a ldk_kept=("${ldk_excluded[@]}")
if ai_tools_conf__is_path_excluded "${ldk_root}/parked/sub" ldk_kept && ! ai_tools_conf__is_path_excluded "${ldk_root}/proj/src" ldk_kept; then
    pass "a park excludes its project and its contents at the gate, and a sibling stays allowed"
else
    fail "the gate's match over a park"
fi
printf '%s\n' "${REG_MARKER}" "${ldk_root}/proj" "%${ldk_root}/proj/*" > "${reg_dir}/project-registry"
ldk_allowed=(x); ldk_excluded=(y); ldk_kinds=(z); ldk_rc=0
ai_tools_conf__load_allowlist "${reg_dir}/project-registry" ldk_allowed ldk_excluded ldk_kinds 2>"${TESTDIR}/reg.err" || ldk_rc=$?
if [[ "${ldk_rc}" -eq 3 && ${#ldk_allowed[@]} -eq 0 && ${#ldk_excluded[@]} -eq 0 && ${#ldk_kinds[@]} -eq 0 ]]; then
    pass "a refused file loads with status 3 and every array empty"
else
    fail "a refused file: rc ${ldk_rc}, allowed=(${ldk_allowed[*]:-}) excluded=(${ldk_excluded[*]:-})"
fi
assert_msg MSG-B8U2 "$(cat "${TESTDIR}/reg.err")" "the refused load names the line"
for ldk_member in has_allowlist_entry has_allowlist_exclusion; do
    if ! "ai_tools_conf__${ldk_member}" "${reg_dir}/project-registry" "${ldk_root}/proj" 2>/dev/null; then
        pass "${ldk_member} answers 'not a member' over a refused file"
    else
        fail "${ldk_member} read a refused file as naming the path"
    fi
done

# --- Registry editing: the one implementation of a registry change ----------------------------
# Three components write the registry (the CLI on the operator's own file, ai-tools-allowlist on another operator's,
# install.sh on its own checkout), and this is what all three call. The file is the LAUNCH GATE, so each assertion is
# about a way an edit could leave the gate saying something other than what the caller was told:
#   * the state read, so a parked project reads as disabled, a carve-out as excluded, and two kinds on one path as
#     a conflict;
#   * add refusing to append under a winning '%' or beside a '!', which would leave an allow line the park beats
#     or put two kinds on one path;
#   * add opening a line of its own, so a file that runs to EOF mid-line keeps that entry;
#   * remove taking the allow and park lines, so no '%' is left to park the next claim at that path, and leaving
#     the carve-out lines, which are the operator's own edit;
#   * enable/disable preserving position, indentation and comment -- their reason to exist rather than being an
#     add+remove pair, for an operator whose registry is an ordered, commented document -- and enable never lifting
#     a '!';
#   * enable collapsing a duplicate pair to ONE live entry;
#   * every editor refusing a legacy allowed-projects and a file with a refused line (3) without writing;
#   * an unwritable directory REPORTED (rc 1) rather than aborting the caller under `set -e`.
section "conf: registry editing (unit)"

if ! declare -F ai_tools_conf__read_allowlist_state >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__allowlist_add >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__allowlist_remove >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__allowlist_enable >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__allowlist_disable >/dev/null 2>&1; then
    fail "${LIB} defines no registry editing functions"
    finish; exit
fi

MARKER="# ai-tools-project-registry-format: 1.0"
AL="${TESTDIR}/project-registry"
P1="${TESTDIR}/p1"; P2="${TESTDIR}/p2"; SUB="${TESTDIR}/p1/vendor"
mkdir -p "${P1}" "${P2}" "${SUB}"

# seed_al <line>... : rewrite the fixture registry with the marker and the given raw lines.
seed_al() { printf '%s\n' "${MARKER}" "$@" > "${AL}"; }

# state_is <expected> <path> <desc>
state_is() {
    local got; got="$(ai_tools_conf__read_allowlist_state "${AL}" "$2")"
    if [[ "${got}" == "$1" ]]; then pass "$3"; else fail "$3: state is '${got}', expected '$1'"; fi
}

# rc_is <expected-rc> <desc> <command...>
rc_is() {
    local want="$1" desc="$2"; shift 2
    local rc=0; "$@" || rc=$?
    if [[ "${rc}" -eq "${want}" ]]; then pass "${desc}"; else fail "${desc}: rc ${rc}, expected ${want}"; fi
}

# --- the state read ---
seed_al "# header" "" "${P1}   # a comment" "!${SUB}" "%${P2}"
state_is listed   "${P1}"  "an allow line reads as listed"
state_is excluded "${SUB}" "a carve-out reads as excluded"
state_is disabled "${P2}"  "a park reads as disabled"
state_is absent   "${TESTDIR}" "a path with no line reads as absent"
# A park OUTRANKS an allow line, exactly as it does at the launch gate: with both present no session starts there,
# so 'disabled' is the only honest answer. A carve-out beside either is two kinds on one path.
seed_al "${P1}" "%${P1}"
state_is disabled "${P1}" "a park outranks an allow line for the same path"
seed_al "${P1}" "!${P1}"
state_is conflict "${P1}" "an allow line and a carve-out on one path read as a conflict"
seed_al "${P1}" "relative/entry"
state_is invalid "${P1}" "a file with a refused line reads as invalid" 2>/dev/null

# --- add ---
seed_al "# header"
rc_is 0 "add appends an absent path"            ai_tools_conf__allowlist_add "${AL}" "${P1}"
state_is listed "${P1}" "the added path reads as listed"
rc_is 0 "add is idempotent for a listed path"   ai_tools_conf__allowlist_add "${AL}" "${P1}"
if [[ "$(grep -cxF "${P1}" "${AL}")" == 1 ]]; then
    pass "add did not duplicate the line"
else
    fail "add duplicated the line ($(grep -cxF "${P1}" "${AL}") copies)"
fi
# A hand-edited registry can run to EOF part-way through its last line, and the readers keep that entry, so the append
# opens a line of its own for the new one. Written straight it would join the two paths into one that is not a project,
# taking the preceding entry off the launch gate.
printf '%s\n%s' "${MARKER}" "${P2}" > "${AL}"
rc_is 0 "add opens a line for an entry that runs to EOF" ai_tools_conf__allowlist_add "${AL}" "${P1}"
state_is listed "${P1}" "the added path reads as listed"
state_is listed "${P2}" "the entry that ran to EOF is still listed"

for kind in '%' '!'; do
    seed_al "# header" "${kind}${P1}"
    rc_is 2 "add REFUSES a path a '${kind}' line names" ai_tools_conf__allowlist_add "${AL}" "${P1}"
    if [[ "$(grep -cF "${P1}" "${AL}")" == 1 ]]; then
        pass "the refused add over a '${kind}' line wrote no second line"
    else
        fail "the refused add appended beside the '${kind}' line: $(grep -c . "${AL}") lines"
    fi
done

# add writes a line the grammar reads back as the path, or does not write: a glob character, a control byte or a `"`
# in a directory name would put a line in the file that refuses the whole registry for every reader (4, no write),
# and a space, a ` #` or a `'` is quoted, so the line reads back as the path rather than as the part before a comment.
seed_al "# header" "${P2}"
add_before="$(cat "${AL}")"
for add_name in 'odd*name' 'a?b' '[x]' 'q"q' $'c\x01d'; do
    add_dir="${TESTDIR}/names/${add_name}"; mkdir -p "${add_dir}"
    rc_is 1 "the name predicate refuses $(printf '%q' "${add_name}")" ai_tools_conf__is_registry_path_representable "${add_dir}"
    rc_is 4 "add refuses a directory named $(printf '%q' "${add_name}")" ai_tools_conf__allowlist_add "${AL}" "${add_dir}"
done
if [[ "$(cat "${AL}")" == "${add_before}" ]]; then
    pass "every refused name left the registry byte-identical"
else
    fail "a refused name wrote the registry:"$'\n'"$(cat "${AL}")"
fi
for add_name in 'a b' 'x # not a comment' "it's" 'plain'; do
    add_dir="${TESTDIR}/names/${add_name}"; mkdir -p "${add_dir}"
    rc_is 0 "the name predicate accepts '${add_name}'" ai_tools_conf__is_registry_path_representable "${add_dir}"
    rc_is 0 "add writes a directory named '${add_name}'" ai_tools_conf__allowlist_add "${AL}" "${add_dir}"
    state_is listed "${add_dir}" "the line written for '${add_name}' reads back as the path"
done
if grep -qxF "\"${TESTDIR}/names/x # not a comment\"" "${AL}" && grep -qxF "${TESTDIR}/names/plain" "${AL}" \
        && ai_tools_conf__validate_registry "${AL}" current 2>/dev/null; then
    pass "a name carrying ' #' is quoted, a plain one is not, and the file validates"
else
    fail "the written lines:"$'\n'"$(cat "${AL}")"
fi
add_saved_ifs="${IFS}"; IFS=$'\n\t'
# shellcheck disable=SC2034  # read through its name by the loader
declare -a add_allowed=() add_excluded=()
ai_tools_conf__load_allowlist "${AL}" add_allowed add_excluded 2>/dev/null || true
IFS="${add_saved_ifs}"
if printf '%s\n' "${add_allowed[@]}" | grep -qxF "${TESTDIR}/names/a b"; then
    pass "the loader resolves the quoted line to the directory"
else
    fail "the loader did not resolve the quoted line: (${add_allowed[*]:-})"
fi

# --- remove: the allow and park lines, never a carve-out ---
seed_al "# header" "${P1}" "%${P1}" "!${SUB}" "${P2}"
rc_is 0 "remove drops a path"                   ai_tools_conf__allowlist_remove "${AL}" "${P1}"
state_is absent "${P1}" "the removed path reads as absent"
if grep -qxF -e "${P1}" -e "%${P1}" "${AL}"; then
    fail "remove left a line naming the path: $(grep -xF -e "${P1}" -e "%${P1}" "${AL}")"
else
    pass "remove took the allow line AND the park"
fi
if grep -qxF "!${SUB}" "${AL}"; then
    pass "remove left the carve-out under the project"
else
    fail "remove deleted the carve-out under the project:"$'\n'"$(cat "${AL}")"
fi
state_is listed "${P2}" "remove left the other project alone"
rc_is 0 "removing an absent path succeeds"      ai_tools_conf__allowlist_remove "${AL}" "${P1}"
seed_al "!${SUB}"
rc_is 0 "remove on a carve-out's own path succeeds and writes nothing" ai_tools_conf__allowlist_remove "${AL}" "${SUB}"
state_is excluded "${SUB}" "the carve-out remove was asked about is still in force"
# A missing registry does not name the path; a directory at the registry path is not a registry, so remove reports
# that it could not edit one, as every other editor does.
rm_dir="${TESTDIR}/rm-dir"; mkdir -p "${rm_dir}/project-registry"
rc_is 0 "remove over a missing registry succeeds" ai_tools_conf__allowlist_remove "${rm_dir}/absent" "${P1}"
rc_is 1 "remove over a directory at the registry path returns 1" ai_tools_conf__allowlist_remove "${rm_dir}/project-registry" "${P1}"

# --- disable / enable: in place, keeping position and comment ---
seed_al "# header" "  ${P1}   # payments, dev stage" "${P2}"
before="$(cat "${AL}")"
rc_is 0 "disable parks a listed project"        ai_tools_conf__allowlist_disable "${AL}" "${P1}"
state_is disabled "${P1}" "the parked project reads as disabled"
if [[ "$(sed -n '3p' "${AL}")" == "  %${P1}   # payments, dev stage" ]]; then
    pass "disable wrote '%' and kept the line's position, indentation and comment"
else
    fail "disable rewrote the line: '$(sed -n '3p' "${AL}")'"
fi
rc_is 0 "disable is idempotent"                 ai_tools_conf__allowlist_disable "${AL}" "${P1}"
rc_is 0 "enable restores a parked project"      ai_tools_conf__allowlist_enable  "${AL}" "${P1}"
state_is listed "${P1}" "the restored project reads as listed"
if [[ "$(cat "${AL}")" == "${before}" ]]; then
    pass "a park/restore round trip leaves the file byte-identical"
else
    fail "the round trip changed the file:"$'\n'"$(cat "${AL}")"
fi
rc_is 0 "enable is idempotent"                  ai_tools_conf__allowlist_enable "${AL}" "${P1}"
# A nested project parks like any other.
seed_al "${P1}" "${SUB}"
rc_is 0 "disable parks a project nested in a listed one" ai_tools_conf__allowlist_disable "${AL}" "${SUB}"
state_is disabled "${SUB}" "the nested project reads as disabled"
state_is listed   "${P1}"  "the enclosing project stays listed"

# Neither verb invents an entry: enabling or disabling a path the file does not name would register a project without
# claiming it (no secret scan, no ACL, no label). A '!' line is a carve-out, never a parked project, so enable does not
# lift it and disable does not park it.
seed_al "# header" "${P2}" "!${SUB}"
rc_is 2 "enable refuses an absent path"         ai_tools_conf__allowlist_enable  "${AL}" "${P1}"
rc_is 2 "disable refuses an absent path"        ai_tools_conf__allowlist_disable "${AL}" "${P1}"
rc_is 2 "enable refuses a carve-out"            ai_tools_conf__allowlist_enable  "${AL}" "${SUB}"
rc_is 2 "disable refuses a carve-out"           ai_tools_conf__allowlist_disable "${AL}" "${SUB}"
if [[ "$(cat "${AL}")" == "${MARKER}"$'\n'"# header"$'\n'"${P2}"$'\n'"!${SUB}" ]]; then
    pass "every refusal left the file untouched"
else
    fail "a refusal wrote to the file:"$'\n'"$(cat "${AL}")"
fi

# --- enable collapses the duplicate pair to ONE live entry ---
# A '%' line and an allow line for one path. Lifting the '%' while an allow line already exists would leave two live
# entries for one path; the earliest position survives.
seed_al "# header" "%${P1}   # parked" "${P2}" "${P1}"
rc_is 0 "enable collapses a duplicate pair"     ai_tools_conf__allowlist_enable "${AL}" "${P1}"
state_is listed "${P1}" "the collapsed path reads as listed"
if [[ "$(grep -cF "${P1}" "${AL}")" == 1 && "$(sed -n '3p' "${AL}")" == "${P1}   # parked" ]]; then
    pass "one entry survives, in the earliest position, with its comment"
else
    fail "collapse left $(grep -cF "${P1}" "${AL}") line(s):"$'\n'"$(cat "${AL}")"
fi

# --- a legacy file and a refused line: status 3, no write ---
# The editors write the format they read; a legacy allowed-projects is the migration's input, and a file with a refused
# line is one no reader trusts.
legacy_dir="${TESTDIR}/legacy"; mkdir -p "${legacy_dir}"
printf '%s\n' "${P1}" "${P2}" > "${legacy_dir}/allowed-projects"
legacy_before="$(cat "${legacy_dir}/allowed-projects")"
for verb in add remove enable disable; do
    rc_is 3 "${verb} refuses a legacy allowed-projects" "ai_tools_conf__allowlist_${verb}" "${legacy_dir}/allowed-projects" "${P1}"
done
seed_al "${P1}" "${P2}" "%relative/entry"
invalid_before="$(cat "${AL}")"
for verb in add remove enable disable; do
    rc_is 3 "${verb} refuses a file with a refused line" "ai_tools_conf__allowlist_${verb}" "${AL}" "${P1}" 2>/dev/null
done
if [[ "$(cat "${legacy_dir}/allowed-projects")" == "${legacy_before}" && "$(cat "${AL}")" == "${invalid_before}" ]]; then
    pass "neither refused file was written"
else
    fail "a status-3 refusal wrote a file"
fi

# --- a write that cannot land in an unwritable directory is REPORTED, not fatal ---
# The rewrite lands its temporary file in the registry's own directory, so an unwritable config directory fails even
# when the file itself is writable. Under `set -e` a bare I/O error would abort the caller; the function must return 1
# and leave the file as it was.
#
# Driven AS THE PROJECTS USER, which is who runs the CLI: this suite runs as root, and root ignores a directory's write
# bit, so the very write the case is about would succeed and the assertion would pass for the wrong reason. The library
# is sourced fresh in that shell, since the check is about the caller's own credentials.
if (( EUID != 0 )) || ! command -v runuser >/dev/null 2>&1; then
    skip "unwritable config directory" "needs root and runuser"
else
    ro="${TESTDIR}/ro"; mkdir -p "${ro}"
    printf '%s\n' "${MARKER}" "${P1}" > "${ro}/project-registry"
    chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${ro}"
    chmod 0500 "${ro}"
    rc=0
    # The inner shell prints a marker first, so a runuser that refused to run it (status 1, the status the case expects)
    # is not read as the editor's report.
    # shellcheck disable=SC2016  # $1..$3 are the inner shell's positionals, passed after `_`
    ro_out="$(runuser -u "${PROJECTS_USER}" -- bash -c '
        printf "inner shell ran\n"
        source "$1" || exit 9
        ai_tools_conf__allowlist_disable "$2" "$3"' _ "${LIB}" "${ro}/project-registry" "${P1}")" || rc=$?
    chmod 0700 "${ro}"
    if [[ "${ro_out}" != "inner shell ran" ]]; then
        fail "runuser did not run the case as ${PROJECTS_USER} (rc ${rc}, output '${ro_out}')"
    elif [[ "${rc}" -eq 1 ]]; then
        pass "an unwritable config directory is reported (rc 1), not fatal"
    else
        fail "an unwritable config directory returned rc ${rc}, expected 1"
    fi
    if [[ "$(cat "${ro}/project-registry")" == "${MARKER}"$'\n'"${P1}" ]]; then
        pass "the failed edit left the registry unchanged"
    else
        fail "the failed edit modified the registry: $(cat "${ro}/project-registry")"
    fi
fi

# --- The migration from allowed-projects ------------------------------------------------------
# `system post-upgrade` runs it unattended, so every assertion is about a way it could lose or change a line, or leave
# the host with no registry a reader trusts: the new file is the marker followed by every line byte for byte, the old
# file becomes the dated backup only after the new one reads back, an interrupted run's `projects` is replaced
# from the source, and a source the grammar or the lstat refuses is left alone with no `projects` written.
section "conf: the migration from allowed-projects (unit)"

if ! declare -F ai_tools_conf__migrate_registry >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf__plan_registry_migration >/dev/null 2>&1; then
    fail "${LIB} defines no migration functions"
    finish; exit
fi
mig="${TESTDIR}/mig"; mkdir -p "${mig}/proj/vendor" "${mig}/parked"
# Every line shape a legacy file holds: a comment, a blank, a plain, a commented, an indented and a quoted entry,
# a carve-out inside a project, a top-level '!' (a project parked before the upgrade), a glob carve-out, and a last line
# without its newline.
mig_lines=( "# my projects" "" "${mig}/proj" "${mig}/other   # why" "   ${mig}/indented" "\"${mig}/a b\"" \
            "!${mig}/proj/vendor" "!${mig}/parked" "!${mig}/*/cache" )
mig_seed() { printf '%s\n' "${mig_lines[@]:0:${#mig_lines[@]}-1}" > "${mig}/allowed-projects"
             printf '%s' "${mig_lines[-1]}" >> "${mig}/allowed-projects"; chmod 600 "${mig}/allowed-projects"; }
mig_seed
mig_plan="$(ai_tools_conf__plan_registry_migration "${mig}/allowed-projects")"
if [[ "$(head -1 <<<"${mig_plan}")" == "marker"$'\t'"0"$'\t'"${MARKER}" \
        && "$(grep -c '^keep' <<<"${mig_plan}")" -eq $(( ${#mig_lines[@]} - 1 )) \
        && "$(grep '^note' <<<"${mig_plan}")" == "note"$'\t'"8"$'\t'"!${mig}/parked"$'\t'"a parked project is written %${mig}/parked in format 1.0" ]]; then
    pass "the plan keeps every line and notes the top-level '!' line with its '%' spelling"
else
    fail "the plan:"$'\n'"${mig_plan}"
fi
mig_out="$(ai_tools_conf__migrate_registry "${mig}/allowed-projects" "${mig}/project-registry" "$(id -u)")" || true
mig_want="${MARKER}"$'\n'"$(printf '%s\n' "${mig_lines[@]}")"
if [[ "$(cat "${mig}/project-registry")" == "${mig_want}" ]]; then
    pass "projects is the marker followed by every line unchanged"
else
    fail "project-registry reads:"$'\n'"$(cat "${mig}/project-registry")"
fi
mig_bak="${mig}/allowed-projects.$(date +%Y%m%d)-1.bak"
if [[ "${mig_out}" == "${mig_bak}" && -f "${mig_bak}" && ! -e "${mig}/allowed-projects" ]]; then
    pass "the source is renamed to its dated .bak, which the call prints"
else
    fail "the rename: printed '${mig_out}', $(ls "${mig}")"
fi
if [[ "$(stat -c '%a' "${mig}/project-registry")" == 600 ]] && ai_tools_conf__validate_registry "${mig}/project-registry" current; then
    pass "projects keeps the source's mode and validates as format 1.0"
else
    fail "project-registry: mode $(stat -c '%a' "${mig}/project-registry") or a refused line"
fi
mig_before="$(cat "${mig}/project-registry")"; rc=0
ai_tools_conf__migrate_registry "${mig}/allowed-projects" "${mig}/project-registry" >/dev/null || rc=$?
if [[ "${rc}" -eq 2 && "$(cat "${mig}/project-registry")" == "${mig_before}" \
        && "$(ai_tools_conf__resolve_registry "${mig}")" == "current"$'\t'"${mig}/project-registry" ]]; then
    pass "a rerun finds no source, writes nothing, and the registry reads current"
else
    fail "a rerun: rc ${rc}"
fi
# An interrupted run leaves a project-registry beside the source; the source is the truth, and the next run replaces it.
rm -f "${mig}"/allowed-projects.*.bak; mig_seed
printf '%s\n' "${MARKER}" "${mig}/half-writ" > "${mig}/project-registry"
ai_tools_conf__migrate_registry "${mig}/allowed-projects" "${mig}/project-registry" >/dev/null || true
if [[ "$(cat "${mig}/project-registry")" == "${mig_want}" ]]; then
    pass "an interrupted run's projects is replaced from the source"
else
    fail "the interrupted run's project-registry survived:"$'\n'"$(cat "${mig}/project-registry")"
fi
# Refusals: the source stays, no project-registry is written.
mig_refused() {   # mig_refused <expected-rc> <desc> [<owner-uid>]
    local rc=0
    rm -f "${mig}/project-registry"
    ai_tools_conf__migrate_registry "${mig}/allowed-projects" "${mig}/project-registry" "${3-}" >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq "$1" && ! -e "${mig}/project-registry" && -n "${AI_TOOLS_CONF__MIGRATION_REFUSAL}" ]]; then
        pass "$2 (${rc}, ${AI_TOOLS_CONF__MIGRATION_REFUSAL})"
    else
        fail "$2: rc ${rc}, project-registry $( [[ -e "${mig}/project-registry" ]] && echo written || echo absent)"
    fi
}
rm -f "${mig}"/allowed-projects*
printf '%s\n' "${mig}/proj" "%${mig}/parked" > "${mig}/allowed-projects"
mig_refused 3 "a source carrying a '%' line is refused"
printf '%s\n' "${mig}/proj" "!vendor" > "${mig}/allowed-projects"
mig_refused 3 "a source carrying a relative line is refused"
printf '%s\n!%s/proj/pri\0vate\n' "${mig}/proj" "${mig}" > "${mig}/allowed-projects"
mig_refused 3 "a source carrying a NUL byte is refused"
{ printf '%s\n!%s/proj/pri\0vate\n' "${mig}/proj" "${mig}"
  head -c 1048576 /dev/zero | tr '\0' '#' | fold -w 79; echo; } > "${mig}/allowed-projects"
mig_refused 3 "a source carrying a NUL byte ahead of 1 MiB of comments is refused"
printf '%s\n' "${mig}/proj" > "${mig}/allowed-projects"
rc=0; rm -f "${mig}/project-registry"
( tr() { return 3; }
  ai_tools_conf__migrate_registry "${mig}/allowed-projects" "${mig}/project-registry" >/dev/null 2>&1 ) || rc=$?
if [[ "${rc}" -eq 1 && ! -e "${mig}/project-registry" && -f "${mig}/allowed-projects" ]]; then
    pass "a source the control-byte scan cannot read is refused (1), the source left and no project-registry written"
else
    fail "a source the scan cannot read: rc ${rc}, project-registry $( [[ -e "${mig}/project-registry" ]] && echo written || echo absent)"
fi
printf '%s\n' "${mig}/proj" > "${mig}/real-source"; rm -f "${mig}/allowed-projects"
ln -s "${mig}/real-source" "${mig}/allowed-projects"
mig_refused 2 "a source that is a symbolic link is refused"
rm -f "${mig}/allowed-projects"; printf '%s\n' "${mig}/proj" > "${mig}/allowed-projects"; chmod 644 "${mig}/allowed-projects"
mig_refused 2 "a source at a mode other than 600 is refused" "$(id -u)"
chmod 600 "${mig}/allowed-projects"
mig_refused 2 "a source held by another uid is refused" "$(( $(id -u) + 1 ))"
if [[ -f "${mig}/allowed-projects" && ! -L "${mig}/allowed-projects" ]]; then
    pass "every refusal left the source under its active name"
else
    fail "a refusal moved the source"
fi

# --- the text predicate: a file whose bytes go to a program as prose -------------------------
# ai_tools_conf__is_text_file is the shared check behind an agent's system prompt: the trust predicate says who wrote
# the file, this says the bytes are text. Empty counts as text (the shipped inert default), a directory
# and a NUL-carrying blob do not.
if declare -F ai_tools_conf__is_text_file >/dev/null 2>&1; then
    tf="${TESTDIR}/textfile"
    printf 'You are a sandboxed agent.\n' > "${tf}"
    ai_tools_conf__is_text_file "${tf}" && pass "a text file is text" || fail "a text file was refused"
    : > "${tf}"
    ai_tools_conf__is_text_file "${tf}" && pass "an empty file counts as text" || fail "an empty file was refused"
    printf '\x00\x01\x02ELF\x00' > "${tf}"
    ai_tools_conf__is_text_file "${tf}" && fail "a NUL-carrying blob passed as text" || pass "a binary blob is not text"
    mkdir -p "${TESTDIR}/textdir"
    ai_tools_conf__is_text_file "${TESTDIR}/textdir" && fail "a directory passed as a text file" || pass "a directory is not a text file"
else
    fail "conf.lib.sh does not define ai_tools_conf__is_text_file"
fi

# --- the one in-place write of a KEY=value file: ai_tools_conf__set_key ------------------------
# The writer behind `operators add` and the toolchain provisioning's agent choice. What matters is WHICH line it
# replaces -- the key's own, commented default included, found by the mention rule ai_tools_conf__read_keys reads --
# and that every other byte survives, since the file it rewrites is the operator's, and a writer with its own idea
# of a match is one that appends a second live line under a commented default the operator then edits to no effect.
section "conf: ai_tools_conf__set_key rewrites one key in place"
if declare -F ai_tools_conf__set_key >/dev/null 2>&1; then
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
    rc=0; ai_tools_conf__set_key "${sk}" AI_TOOLS_AGENTS "acme beta" || rc=$?
    if [[ "${rc}" -eq 0 && "$(ai_tools_conf__print_value "${sk}" AI_TOOLS_AGENTS)" == "acme beta" ]]; then
        pass "a commented default is rewritten as the live key and reads back"
    else
        fail "set_key over a commented default: rc ${rc}, value '$(ai_tools_conf__print_value "${sk}" AI_TOOLS_AGENTS || true)'"
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
    rc=0; ai_tools_conf__set_key "${sk}" AI_TOOLS_AGENTS "gamma" || rc=$?
    if [[ "${rc}" -eq 0 && "$(grep -c 'AI_TOOLS_AGENTS=' "${sk}")" -eq 2 \
            && "$(ai_tools_conf__print_value "${sk}" AI_TOOLS_AGENTS)" == "gamma" ]]; then
        pass "an existing live key is replaced, not duplicated (the indented example stays prose)"
    else
        fail "set_key over a live key: rc ${rc}, $(grep -c 'AI_TOOLS_AGENTS=' "${sk}") mention(s), value '$(ai_tools_conf__print_value "${sk}" AI_TOOLS_AGENTS || true)'"
    fi
    # A live line an operator wrote after the template's commented default is the one a reader takes, so it is the one
    # replaced: rewriting the commented default instead would leave the later line winning the read.
    printf '%s\n' '#K=""' 'OTHER=1' 'K="old"' > "${sk}.below"
    rc=0; ai_tools_conf__set_key "${sk}.below" K "new" || rc=$?
    if [[ "${rc}" -eq 0 && "$(tr '\n' '|' < "${sk}.below")" == '#K=""|OTHER=1|K="new"|' ]]; then
        pass "a live line below a commented default is the one replaced, and the default stays commented"
    else
        fail "set_key over a live line below a commented default: rc ${rc}, file '$(tr '\n' '|' < "${sk}.below")'"
    fi
    printf '%s\n' 'K="a"' 'K="b"' > "${sk}.twice"
    rc=0; ai_tools_conf__set_key "${sk}.twice" K "c" || rc=$?
    if [[ "${rc}" -eq 0 && "$(tr '\n' '|' < "${sk}.twice")" == 'K="a"|K="c"|' ]]; then
        pass "of two live lines the last, the one a reader takes, is replaced"
    else
        fail "set_key over a repeated key: rc ${rc}, file '$(tr '\n' '|' < "${sk}.twice")'"
    fi
    rc=0; ai_tools_conf__set_key "${sk}" OPERATORS "op two" || rc=$?
    if [[ "${rc}" -eq 0 && "$(sed -n 2p "${sk}")" == 'OPERATORS="op two"' ]]; then
        pass "OPERATORS is rewritten on its own line, in its place"
    else
        fail "set_key on OPERATORS: rc ${rc}, line 2 is '$(sed -n 2p "${sk}")'"
    fi
    rc=0; ai_tools_conf__set_key "${sk}" NEW_KEY "v" || rc=$?
    if [[ "${rc}" -eq 0 && "$(tail -n 1 "${sk}")" == 'NEW_KEY="v"' ]]; then
        pass "a key the file does not mention is appended"
    else
        fail "set_key on an absent key: rc ${rc}, last line '$(tail -n 1 "${sk}")'"
    fi
    printf 'TRAIL=1' > "${sk}.noeol"
    ai_tools_conf__set_key "${sk}.noeol" NEXT "2" || true
    if [[ "$(ai_tools_conf__print_value "${sk}.noeol" TRAIL)" == "1" && "$(ai_tools_conf__print_value "${sk}.noeol" NEXT)" == "2" ]]; then
        pass "an append after an unterminated last line keeps both keys"
    else
        fail "an append joined the unterminated last line: $(tr '\n' '|' < "${sk}.noeol")"
    fi
    rc=0; ai_tools_conf__set_key "${TESTDIR}/fresh.conf" OPERATORS "op" || rc=$?
    if [[ "${rc}" -eq 0 && "$(stat -c '%a' "${TESTDIR}/fresh.conf")" == "644" \
            && "$(ai_tools_conf__print_value "${TESTDIR}/fresh.conf" OPERATORS)" == "op" ]]; then
        pass "a missing file is created at 644 holding the key"
    else
        fail "set_key on a missing file: rc ${rc}"
    fi
    for bad in 'bad-key' '1KEY' ''; do
        rc=0; ai_tools_conf__set_key "${sk}" "${bad}" v || rc=$?
        [[ "${rc}" -eq 2 ]] && pass "a key outside the identifier charset ('${bad}') is refused with 2" \
                             || fail "key '${bad}' returned rc ${rc}, expected 2"
    done
    for bad in $'a\nb' 'a"b'; do
        rc=0; ai_tools_conf__set_key "${sk}" AI_TOOLS_AGENTS "${bad}" || rc=$?
        [[ "${rc}" -eq 2 && "$(ai_tools_conf__print_value "${sk}" AI_TOOLS_AGENTS)" == "gamma" ]] \
            && pass "a value that would end the line or the quote early is refused with 2, file unchanged" \
            || fail "value '${bad//$'\n'/\\n}' returned rc ${rc} (value now '$(ai_tools_conf__print_value "${sk}" AI_TOOLS_AGENTS || true)')"
    done
else
    fail "conf.lib.sh does not define ai_tools_conf__set_key"
fi

# --- ai_tools_conf__is_portable_name_valid: one path component of the portable set -----------------
section "conf: ai_tools_conf__is_portable_name_valid accepts one path component of the portable filename set"
if declare -F ai_tools_conf__is_portable_name_valid >/dev/null 2>&1; then
    while IFS='|' read -r name want why; do
        [[ -n "${why}" ]] || continue
        got=0; ai_tools_conf__is_portable_name_valid "${name}" || got=$?
        if [[ "${got}" == "${want}" ]]; then pass "portable name: ${why}"; else fail "portable name: ${why} -> got ${got}, want ${want}"; fi
    done <<EOF
SKILL.md|0|letters, a dot
.claude-plugin|0|opening with a dot
a_b.c-d.v2|0|dots, an underscore and inner hyphens
_|0|an underscore alone
-flag|1|opening with a hyphen
.|1|the current directory
..|1|the parent directory
a/b|1|a slash
with space|1|a space
a$(printf '\t')b|1|a tab
r$(printf '\303\251')sum$(printf '\303\251')|1|a byte outside ASCII
win\\paths|1|a backslash
a*|1|a glob character
|1|the empty string
EOF
    if LC_ALL=C.UTF-8 ai_tools_conf__is_portable_name_valid "$(printf '\303\251')"; then
        fail "portable name: a non-ASCII letter accepted under a UTF-8 locale"
    else
        pass "portable name: a non-ASCII letter refused under a UTF-8 locale"
    fi
    if ai_tools_conf__is_portable_name_valid "$(printf 'a%.0s' {1..255})"; then pass "portable name: 255 bytes"; else fail "portable name: 255 bytes refused"; fi
    if ai_tools_conf__is_portable_name_valid "$(printf 'a%.0s' {1..256})"; then fail "portable name: 256 bytes accepted"; else pass "portable name: 256 bytes refused"; fi
else
    skip "portable name" "the installed conf.lib.sh predates ai_tools_conf__is_portable_name_valid"
fi

finish

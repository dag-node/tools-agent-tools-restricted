#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/conf.sh
# Unit test for the shared config grammar (conf.lib.sh) -- the one parser behind every key in
# /etc/ai-tools/operator.conf and every provider manifest. Two contracts are pinned here:
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
# split_under_ifs <ifs> <value> : the items, joined by '|', from a SUBSHELL running under <ifs>,
# so the caller's own IFS cannot mask a dependency.
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

# --- Sidecar files: what an upgrade preserves when it rewrites an operator's config ------------
# Two copies with two jobs -- .bak is what the operator HAD, .shipped is what they were SUPPOSED
# to get -- and the property that makes .bak worth calling a backup is that a second run in the
# same day cannot overwrite the first. An operator who ran the installer twice is exactly the one
# who needs the earlier copy.
stamp="$(date +%Y%m%d)"
cfg="${TESTDIR}/sidecar.conf"
printf 'ORIGINAL\n' > "${cfg}"; chown root:root "${cfg}"; chmod 640 "${cfg}"

first_bak="$(ai_tools_conf_backup "${cfg}")"
if [[ "${first_bak}" == "${cfg}.${stamp}.bak" && "$(cat "${first_bak}")" == ORIGINAL ]]; then
    pass "a backup is date-stamped and copies the file verbatim"
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
if [[ "${second_bak}" != "${first_bak}" && "$(cat "${first_bak}")" == ORIGINAL ]]; then
    pass "a same-day second backup takes a new name and leaves the first intact"
else
    fail "same-day backup collided: ${second_bak}"
fi

# The reference copy takes the DEPLOYED file's owner and mode, never the source tree's, so a
# baseline dropped beside a 0640 control-plane file is not left world-readable.
baseline="${TESTDIR}/sidecar.shipped-src"
printf 'SHIPPED\n' > "${baseline}"; chmod 666 "${baseline}"
ref="$(ai_tools_conf_reference "${cfg}" "${baseline}")"
if [[ "${ref}" == "${cfg}.${stamp}.shipped" && "$(perm "${ref}")" == 640 ]]; then
    pass "a reference copy is date-stamped and takes the deployed file's mode"
else
    fail "reference path/mode wrong: ${ref} mode $(perm "${ref}" 2>/dev/null)"
fi
# A repeated offer of the SAME baseline resolves to the copy already there, so a host re-running
# the installer against an unchanged source tree collects one sidecar rather than one per run.
if [[ "$(ai_tools_conf_reference "${cfg}" "${baseline}")" == "${ref}" && "$(cat "${ref}")" == SHIPPED ]]; then
    pass "an unchanged baseline reuses the copy beside the file"
else
    fail "an unchanged baseline did not resolve to ${ref}"
fi

# A DIFFERENT baseline is a different answer to "what was I supposed to get?", so it takes its own
# dated copy and leaves the earlier one readable.
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

# jq is a package dependency, so the JSON paths report a broken install rather than degrading.
if ai_tools_conf_require_jq >/dev/null 2>&1; then
    pass "the jq gate passes where jq is installed"
else
    fail "the jq gate rejected a host that has jq"
fi

# --- New options in a kept KEY=value config ---------------------------------------------------
# A kept config never gains a key a new version documents, so an install has to SAY which options
# the operator has not seen. It must not say it twice: a key already set, or deliberately
# commented out, has been seen, and re-announcing it every upgrade is the noise that makes an
# operator stop reading the install output.
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

# A commented-out DEFAULT and an indented EXAMPLE look alike to a naive scan, and the difference
# decides what an upgrade reports. operator.conf documents its own grammar with lines like
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
# The launch wrapper, the CLI (reg/unreg/project_state), and the relabel helper all decide "is
# this path listed" through these predicates instead of a raw `grep -qxF` against the stored line.
# The property under test: an entry written in the documented grammar -- an end-of-line comment,
# quotes, or a spelling reached by a symlink or trailing slash -- MATCHES, where a raw grep would
# miss it and report the project unlisted (the divergence that duplicated entries on claim, left
# them on unclaim, and failed the post-claim launch confirm).
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

# The line-identifying variant returns the VERBATIM source line (comment and all), which is what
# an anchored sed deletes -- reconstructing it from the path would miss a commented/quoted entry
# and leave it behind. Two-ended with the boundary suite: the agent cannot write the allowlist.
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
# The launch allowlist shares this grammar, and three components parse that file -- the wrapper,
# the CLI, and the chown helper. The first block is BACKWARD COMPATIBILITY: every shape an
# existing allowlist already contains must parse exactly as before, because a line that stops
# resolving silently removes a project from the gate.
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

# The grammar this file gains: end-of-line comments, and quotes for a path that must carry a
# space or a literal `#`.
check_entry "an end-of-line comment is removed"    /home/me/project         '/home/me/project  # why'
check_entry "quotes carry a space"                 '/home/me/my project'    '"/home/me/my project"'
check_entry "quotes make # literal"                '/home/me/proj #2'       '"/home/me/proj #2"'
check_entry "single quotes work too"               '/home/me/my project'    "'/home/me/my project'"
check_entry "an exclusion may be quoted"           '!/home/me/my project'   '!"/home/me/my project"'
check_entry "a quoted path may be commented"       '/home/me/a b'           '"/home/me/a b"   # note'
# An interior # with no preceding whitespace is part of the path, matching the KEY=value rule --
# a directory literally named proj#2 keeps working unquoted.
check_entry "an interior # needs no quotes"        '/home/me/proj#2'        '/home/me/proj#2'
# An unmatched quote is taken verbatim rather than truncating the path at some later character,
# so a typo cannot silently shorten an allowlist entry into a broader one.
check_entry "an unmatched quote is taken as-is"    '/home/me/project'       '"/home/me/project'

# --- Allowlist editing: the one implementation of a registry change ---------------------------
# Three components write allowed-projects (the CLI on the operator's own file, ai-tools-allowlist
# on another operator's, install.sh on its own checkout), and this is what all three call. The
# file is the LAUNCH GATE, so each assertion below is about a way an edit could leave the gate
# saying something other than what the caller was told:
#   * the three-state read, where a DISABLED project used to read as absent;
#   * add refusing to append under a winning '!' (the duplicate-pair bug);
#   * add opening a line of its own, so a file that runs to EOF mid-line keeps that entry;
#   * remove taking BOTH line kinds, so no '!' is left to park the next claim at that path;
#   * enable/disable preserving position, indentation and comment -- their reason to exist
#     rather than being an add+remove pair, for an operator whose allowlist is an ordered,
#     commented document;
#   * enable collapsing a duplicate pair to ONE live entry;
#   * an unwritable directory REPORTED (rc 1) rather than aborting the caller under set -e.
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
# An exclusion OUTRANKS an allow line, exactly as it does at the launch gate: with both present
# no session starts there, so 'disabled' is the only honest answer.
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
# A hand-edited registry can run to EOF part-way through its last line, and the readers keep that
# entry, so the append opens a line of its own for the new one. Written straight it would join the
# two paths into a third naming no project, taking the entry above it off the launch gate.
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

# Neither verb invents an entry: enabling or disabling a path the file does not name would
# register a project without claiming it (no secret scan, no ACL, no label).
seed_al "# header" "${P2}"
rc_is 2 "enable refuses an absent path"         ai_tools_conf_allowlist_enable  "${AL}" "${P1}"
rc_is 2 "disable refuses an absent path"        ai_tools_conf_allowlist_disable "${AL}" "${P1}"
if [[ "$(cat "${AL}")" == "# header"$'\n'"${P2}" ]]; then
    pass "both refusals left the file untouched"
else
    fail "a refusal wrote to the file:"$'\n'"$(cat "${AL}")"
fi

# --- enable collapses the duplicate pair to ONE live entry ---
# The pair the old append-over-an-exclusion bug created. Un-parking the '!' line while an allow
# line already exists would leave two live entries for one path; the earliest position survives.
seed_al "# header" "!${P1}   # parked" "${P2}" "${P1}"
rc_is 0 "enable collapses a duplicate pair"     ai_tools_conf_allowlist_enable "${AL}" "${P1}"
state_is listed "${P1}" "the collapsed path reads as listed"
if [[ "$(grep -cF "${P1}" "${AL}")" == 1 && "$(sed -n '2p' "${AL}")" == "${P1}   # parked" ]]; then
    pass "one entry survives, in the earliest position, with its comment"
else
    fail "collapse left $(grep -cF "${P1}" "${AL}") line(s):"$'\n'"$(cat "${AL}")"
fi

# --- a write that cannot happen is REPORTED, not fatal ---
# The rewrite lands its temporary file in the allowlist's own directory, so an unwritable config
# directory fails even when the file itself is writable. Under set -e that used to abort the caller
# with a bare I/O error; it must return 1 and leave the file as it was.
#
# Driven AS THE PROJECTS USER, which is who runs the CLI: this suite runs as root, and root ignores
# a directory's write bit, so the very write the case is about would succeed and the assertion
# would pass for the wrong reason -- or, as written first, fail. The library is sourced fresh in
# that shell, since the check is about the caller's own credentials.
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

finish

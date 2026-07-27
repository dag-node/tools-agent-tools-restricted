#!/usr/bin/env bash
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

finish

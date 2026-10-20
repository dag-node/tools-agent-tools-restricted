#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/layout.sh
# Unit test for the installed-layout library (layout.lib.sh), the one table `ai-tools-admin system layout` reads
# and tests/integration/perms.sh loops over. What it pins, in the order the file runs:
#   * the load: the checkout's table validates whole, with the sandbox tokens substituted into a copy as install.sh
#     substitutes them, and a declaration error makes every public reader refuse;
#   * the declaration validator over a table of good and bad rows, in both provenances -- each refusal of the entry
#     grammar, and the dynamic grammar that a static row would be refused under;
#   * the expected-ACL derivation, against a live `setfacl` of the same specification on a fixture directory
#     the invoker owns;
#   * the pure comparison, every finding token once, and the findings made before a later unreadable field kept;
#   * the entry reader over fixtures the invoker owns -- at its row, each drift, missing, an optional absence,
#     a type mismatch, a dangling link -- and the output names it refuses, since a nameref landing on the library's
#     own local would report a read that reached no caller;
#   * the content evaluator over seeded collector results: silence is not evidence, a missing report is not
#     a verified one, and a new pass forgets the last;
#   * the entry set: sentinel applicability (either sentinel, the shared endpoints directory under either owner,
#     a compressed row resolved to its `.gz`), one sort over the static and the dynamic rows, and each input
#     the enumeration cannot read as an `error` line with status 1, never an empty set;
#   * the `--check` stream held to ai-tools-records(5): columns by name off the header, the `ok` rows under `--all`,
#     a failed write reaching the caller, and the declaration-error row;
#   * lockstep with packaging/ai-tools.spec, in a checkout: every `%attr` line resolves to a row with the same owner,
#     mode and config/ghost flag, every bare line is a row or shipped data, and every `files` row is a `%files` line
#     of its package.
# Runs unprivileged: the trusted branches of the dynamic enumeration need root-owned inputs, so where the run is root
# those cases assert the rows, and otherwise the `error` line the untrusted fixture earns. The root half of
# the library's test (drift converging under the reconcile) lands with the reconcile.

# shellcheck disable=SC2015  # `check && pass || fail`: pass returns 0, so fail runs only on a failed check
# shellcheck disable=SC2034,SC2154  # an array handed to the library by name is written through its nameref, and a key
#                                   # of an associative array reads as a variable to ShellCheck
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${ROOT}/src/usr/local/lib/ai-tools"
LIB="${LIB_DIR}/layout.lib.sh"
SPEC="${ROOT}/packaging/ai-tools.spec"
printf 'layout: %s\n' "${LIB}"

section "layout: loading the checkout's library (unit)"
[[ -r "${LIB}" ]] || { fail "the checkout's layout library is not readable"; finish; exit; }
mktestdir
# A copy with the sandbox tokens substituted, as install.sh and the spec substitute them: the owner grammar refuses
# the raw token. The siblings are copied beside it, since the library sources them from its own directory.
cp -r "${LIB_DIR}" "${TESTDIR}/lib"
sed -i -e "s/@SANDBOX_USER@/${SANDBOX_USER}/g" -e "s/@SANDBOX_GROUP@/${SANDBOX_GROUP}/g" "${TESTDIR}/lib/layout.lib.sh"
FIXTURE_ROOT="${TESTDIR}/root"
AGENTS_DIR="${TESTDIR}/agents.d"
mkdir -p "${FIXTURE_ROOT}" "${AGENTS_DIR}"
printf 'config_dir=.acme\nlauncher=acme\n' > "${AGENTS_DIR}/acme.conf"
printf 'launcher=nodir\n' > "${AGENTS_DIR}/nodir.conf"
chmod 0755 "${AGENTS_DIR}"; chmod 0644 "${AGENTS_DIR}"/*.conf
printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${TESTDIR}/operator.conf"
chmod 0644 "${TESTDIR}/operator.conf"
# The two hooks the enumeration reads are readonly once the libraries load, so they are set before the source.
export AI_TOOLS_LAYOUT_ROOT="${FIXTURE_ROOT}" AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}"
export AI_TOOLS_OPERATOR_CONF="${TESTDIR}/operator.conf"
# shellcheck source=/dev/null
if ! source "${TESTDIR}/lib/layout.lib.sh" || ! declare -F ai_tools_layout__list_entries >/dev/null 2>&1; then
    fail "could not source the library copy or it does not define its functions"; finish; exit
fi
pass "the library sources with its dependencies and defines its functions"
[[ -z "${AI_TOOLS_LAYOUT__DECLARATION_ERROR}" ]] && pass "every static declaration validates" \
    || fail "a declaration was refused: ${AI_TOOLS_LAYOUT__DECLARATION_ERROR}"
(( ${#_AI_TOOLS_LAYOUT__STATIC_ENTRIES[@]} > 100 )) && pass "the table holds the static rows (${#_AI_TOOLS_LAYOUT__STATIC_ENTRIES[@]})" \
    || fail "the table holds ${#_AI_TOOLS_LAYOUT__STATIC_ENTRIES[@]} rows"
for required in /etc/ai-tools/operator.conf /opt/ai-tools/bin/ai-tools-run /usr/local/lib/ai-tools/layout.lib.sh \
        /usr/lib/sysusers.d/ai-tools.conf /usr/sbin/ai-tools; do
    found=0
    for entry in "${_AI_TOOLS_LAYOUT__STATIC_ENTRIES[@]}"; do [[ "${entry%%$'\t'*}" == "${required}" ]] && found=1; done
    (( found )) && pass "declared: ${required}" || fail "not declared: ${required}"
done

# entry <path> <type> <owner> <mode> <acl> <package> <flags> [operator] : one encoded entry line on stdout.
entry() { local line; _ai_tools_layout__encode_line line "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8-}"; printf '%s' "${line}"; }
# raw <field>... : one TAB-joined declaration, as the table holds it.
raw() { local IFS=$'\t'; printf '%s' "$*"; }

section "layout: the declaration validator"
# valid <desc> <provenance> <field>... / refused <desc> <provenance> <reason-fragment> <field>...
valid() {
    local desc="$1" provenance="$2"; shift 2
    local rc=0 out; out="$(_ai_tools_layout__is_entry_valid "$(raw "$@")" "${provenance}")" || rc=$?
    (( rc == 0 )) && pass "valid: ${desc}" || fail "valid: ${desc}: refused (${out})"
}
refused() {
    local desc="$1" provenance="$2" fragment="$3"; shift 3
    local rc=0 out; out="$(_ai_tools_layout__is_entry_valid "$(raw "$@")" "${provenance}")" || rc=$?
    if (( rc == 1 )) && [[ "${out}" == *"${fragment}"* ]]; then pass "refused: ${desc}"
    else fail "refused: ${desc}: rc ${rc}, reason '${out}'"; fi
}
valid "a file row"                          static /x file root:root 0644 - ai-tools-base files
valid "a link row at 0777 with no ACL"      static /x link root:root 0777 - ai-tools-base files
valid "a directory with access and default entries" static /x directory root:ai-tools 2770 \
    "group:ai-ops:rwx,default:group:ai-ops:rwx" ai-tools-base files
valid "a package list on a directory"       static /x directory root:root 0755 - "ai-tools-base,ai-tools-selinux" files
valid "a dynamic row with a space in its path" dynamic "/home/a b/.config/ai-tools" directory xd:xd 0700 - - boundary
refused "six fields"                static "expected 7 fields" /x file root:root 0644 - ai-tools-base
refused "a relative path"           static "absolute normalized" x file root:root 0644 - ai-tools-base files
refused "a trailing slash"          static "absolute normalized" /x/ directory root:root 0755 - ai-tools-base files
refused "a dot component"           static "absolute normalized" /x/../y file root:root 0644 - ai-tools-base files
refused "a static path with a space" static "printable ASCII" "/x y" file root:root 0644 - ai-tools-base files
refused "a static path with a glob" static "printable ASCII" "/x*" file root:root 0644 - ai-tools-base files
refused "an unknown subject-type"   static "subject-type" /x socket root:root 0644 - ai-tools-base files
refused "an owner without a group"  static "user:group" /x file root 0644 - ai-tools-base files
refused "a three-digit mode"        static "four octal digits" /x file root:root 644 - ai-tools-base files
refused "a link not at 0777"        static "0777" /x link root:root 0644 - ai-tools-base files
refused "a link with an ACL"        static "no ACL" /x link root:root 0777 "group:ai-ops:r-x" ai-tools-base files
refused "an ACL entry that is not a named entry" static "not a named entry" /x file root:root 0644 "mask::r-x" ai-tools-base files
refused "a named entry over the group bits" static "exceeds" /x directory root:root 0750 "group:ai-ops:rwx" ai-tools-base files
refused "a default entry on a file" static "directory row alone" /x file root:root 0640 "default:group:ai-ops:r--" ai-tools-base files
refused "two named group entries"   static "one named user and one named group" /x directory root:root 0750 \
    "group:ai-ops:r-x,group:ai-tools:r-x" ai-tools-base files
refused "a package with no sentinel" static "no sentinel" /x file root:root 0644 - acme files
refused "a package list on a file"  static "directory row alone" /x file root:root 0644 - "ai-tools-base,ai-tools-selinux" files
refused "package - on a static row" static "no sentinel" /x file root:root 0644 - - files
refused "a package on a dynamic row" dynamic "package -" /x file root:root 0644 - ai-tools-base files
refused "empty flags"               static "- or a list" /x file root:root 0644 - ai-tools-base ""
refused "an unknown flag"           static "not one of" /x file root:root 0644 - ai-tools-base files,shiny
refused "config without files"      static "files row alone" /x file root:root 0644 - ai-tools-base config
refused "compressed on a directory" static "file row alone" /x directory root:root 0755 - ai-tools-base files,compressed
# IFS does not decide a flag's membership: the loop compares tokens.
rc=0; IFS=$'\n\t' _ai_tools_layout__is_entry_valid "$(raw /x file root:root 0644 - ai-tools-base files,boundary)" static >/dev/null || rc=$?
(( rc == 0 )) && pass "a valid flag list validates under a newline-tab IFS" || fail "flag membership depends on IFS"

section "layout: the expected ACL text"
acl_text() { local out; _ai_tools_layout__get_expected_acl "$1" "$2" out; printf '%s' "${out}"; }
expected="$(printf 'user::rw-\ngroup::r--\nother::r--')"
[[ "$(acl_text 0644 -)" == "${expected}" ]] && pass "0644 without a named entry: base entries, no mask" \
    || fail "0644: $(acl_text 0644 - | tr '\n' '|')"
expected="$(printf 'user::rwx\ngroup::r-x\ngroup:ai-ops:r-x\nmask::r-x\nother::---')"
[[ "$(acl_text 2750 group:ai-ops:r-x)" == "${expected}" ]] && pass "2750 with a named access entry: the mask is the group bits" \
    || fail "2750 named: $(acl_text 2750 group:ai-ops:r-x | tr '\n' '|')"
expected="$(printf 'user::rwx\ngroup::rwx\ngroup:ai-ops:rwx\nmask::rwx\nother::---\ndefault:user::rwx\ndefault:group::rwx\ndefault:group:ai-ops:rwx\ndefault:mask::rwx\ndefault:other::---')"
[[ "$(acl_text 2770 group:ai-ops:rwx,default:group:ai-ops:rwx)" == "${expected}" ]] \
    && pass "2770 with a default entry: the default block carries its own base entries and mask" \
    || fail "2770 default: $(acl_text 2770 group:ai-ops:rwx,default:group:ai-ops:rwx | tr '\n' '|')"
# The live control: setfacl of the same specification on a directory the invoker owns prints the derived text.
control_dir="${TESTDIR}/acl-control"; mkdir -p "${control_dir}"; chmod 0750 "${control_dir}"
if setfacl -m "g:${PROJECTS_GROUP}:r-x" -m "d:u::rwx,d:g::r-x,d:g:${PROJECTS_GROUP}:r-x,d:o::---" "${control_dir}" 2>/dev/null; then
    live="$(LC_ALL=C getfacl --absolute-names --omit-header --no-effective -P -- "${control_dir}" | sed '/^$/d')"
    derived="$(acl_text 0750 "group:${PROJECTS_GROUP}:r-x,default:group:${PROJECTS_GROUP}:r-x")"
    [[ "${live}" == "${derived}" ]] && pass "the derived text equals getfacl's for a live setfacl of the same specification" \
        || fail "live control differs: live '$(tr '\n' '|' <<< "${live}")' derived '$(tr '\n' '|' <<< "${derived}")'"
else
    skip "live ACL control" "setfacl is refused on ${TESTDIR}"
fi

section "layout: the pure comparison"
# compare <desc> <expected-spec> <observed-spec> <wanted-tokens> : each spec is `key=value` pairs separated by `;`.
compare() {
    local desc="$1" wanted="$4" pair got="" line
    local -A cmp_expected=() cmp_observed=()
    local -a cmp_findings=() cmp_fields=()
    IFS=';' read -ra cmp_fields <<< "$2"; for pair in "${cmp_fields[@]}"; do cmp_expected["${pair%%=*}"]="${pair#*=}"; done
    IFS=';' read -ra cmp_fields <<< "$3"; for pair in "${cmp_fields[@]}"; do cmp_observed["${pair%%=*}"]="${pair#*=}"; done
    _ai_tools_layout__append_entry_findings cmp_expected cmp_observed cmp_findings
    for line in "${cmp_findings[@]}"; do got+="${got:+ }${line%%$'\t'*}"; done
    [[ "${got}" == "${wanted}" ]] && pass "${desc}" || fail "${desc}: findings '${got}', wanted '${wanted}'"
}
at_row="type=file;owner=root:root;mode=0644;acl=user::rw-;label=etc_t"
compare "at its row: no finding"       "${at_row};flags=files;package=p" "type=file;owner=root:root;mode=0644;acl=user::rw-;label=etc_t" ""
compare "owner-drift"                  "${at_row}" "type=file;owner=ai-tools:ai-tools;mode=0644;acl=user::rw-;label=etc_t" "owner-drift"
compare "mode-drift"                   "${at_row}" "type=file;owner=root:root;mode=0600;acl=user::rw-;label=etc_t" "mode-drift"
compare "acl-drift"                    "${at_row}" "type=file;owner=root:root;mode=0644;acl=user::rwx;label=etc_t" "acl-drift"
compare "label-drift"                  "${at_row}" "type=file;owner=root:root;mode=0644;acl=user::rw-;label=var_t" "label-drift"
compare "no label expectation: no finding" "type=file;owner=root:root;mode=0644;acl=user::rw-;label=" "type=file;owner=root:root;mode=0644;acl=user::rw-;label=var_t" ""
compare "label n/a: not compared"      "type=file;owner=root:root;mode=0644;acl=user::rw-;label=n/a" "type=file;owner=root:root;mode=0644;acl=user::rw-;label=n/a" ""
compare "content-drift"                "${at_row};content_checked=1;package=p" "type=file;owner=root:root;mode=0644;acl=user::rw-;label=etc_t;content=drift" "content-drift"
compare "content unreadable"           "${at_row};content_checked=1;package=p" "type=file;owner=root:root;mode=0644;acl=user::rw-;label=etc_t;content=unreadable" "unreadable"
compare "content unverified: no finding" "${at_row};content_checked=1;package=p" "type=file;owner=root:root;mode=0644;acl=user::rw-;label=etc_t;content=unverified" ""
compare "missing"                      "${at_row}" "type=absent" "missing"
compare "missing but absent_ok"        "${at_row};absent_ok=1" "type=absent" ""
compare "type-mismatch"                "${at_row}" "type=directory" "type-mismatch"
compare "unreadable type"              "${at_row}" "type=unreadable;type_error=x" "unreadable"
compare "a dangling link is missing"   "type=link;owner=root:root" "type=link;link_target=dangling;owner=root:root" "missing"
compare "a link compares its owner alone" "type=link;owner=root:root" "type=link;owner=ai-tools:ai-tools;mode=0777" "owner-drift"
compare "an unreadable field ends the comparison, the earlier finding kept" "${at_row}" \
    "type=file;owner=ai-tools:ai-tools;mode=0644;acl_error=getfacl failed;label=var_t" "owner-drift unreadable"
compare "an unreadable label expectation" "${at_row};label_error=matchpathcon is not installed" \
    "type=file;owner=root:root;mode=0644;acl=user::rw-" "unreadable"
# The remedy a refused state names, read off the detail of the finding line.
remedy_of() {
    local -A rem_expected=( [type]=file [owner]=root:root [mode]=0644 [acl]=x [flags]="$1" [package]="$2" [operator]="$3" )
    local -A rem_observed=( [type]=absent )
    local -a rem_findings=()
    _ai_tools_layout__append_entry_findings rem_expected rem_observed rem_findings
    printf '%s' "${rem_findings[0]##*$'\t'}"
}
[[ "$(remedy_of files ai-tools-base "")" == *"dnf reinstall ai-tools-base"* ]] && pass "a missing package file names dnf reinstall" \
    || fail "package remedy: $(remedy_of files ai-tools-base "")"
[[ "$(remedy_of boundary - xd)" == *"operators add xd"* ]] && pass "a missing operator file names operators add" \
    || fail "operator remedy: $(remedy_of boundary - xd)"
[[ "$(remedy_of - ai-tools-base "")" == *"system bootstrap"* ]] && pass "a missing runtime file names system bootstrap" \
    || fail "runtime remedy: $(remedy_of - ai-tools-base "")"

section "layout: the entry reader over owned fixtures"
FX="${FIXTURE_ROOT}/fx"; mkdir -p "${FX}/dir"
printf 'x\n' > "${FX}/file"; chmod 0644 "${FX}/file"; chmod 0750 "${FX}/dir"
ln -sfn /nonexistent "${FX}/dangling"; ln -sfn "${FX}/file" "${FX}/goodlink"
me="$(stat -c '%U:%G' "${FX}/file")"
ai_tools_layout__begin_pass 1
# read_tokens <entry-line> : the finding tokens of one read, space-joined, with the observed type first.
read_tokens() {
    local -A rd_state=(); local -a rd_findings=(); local line rc=0 got=""
    ai_tools_layout__read_entry_state "$1" rd_state rd_findings || rc=$?
    (( rc == 0 )) || { printf 'rc=%s' "${rc}"; return; }
    for line in "${rd_findings[@]}"; do got+=" ${line%%$'\t'*}"; done
    printf '%s%s' "${rd_state[type]}" "${got}"
}
expect_read() { local got; got="$(read_tokens "$2")"; [[ "${got}" == "$3" ]] && pass "$1" || fail "$1: got '${got}', wanted '$3'"; }
expect_read "a file at its row reads clean"      "$(entry "${FX}/file" file "${me}" 0644 - ai-tools-base -)" "file"
expect_read "a mode drift reads mode and ACL"    "$(entry "${FX}/file" file "${me}" 0600 - ai-tools-base -)" "file mode-drift acl-drift"
expect_read "an owner drift"                     "$(entry "${FX}/file" file nobody:nobody 0644 - ai-tools-base -)" "file owner-drift"
expect_read "a named entry the entry lacks"      "$(entry "${FX}/dir" directory "${me}" 0750 "group:${PROJECTS_GROUP}:r-x" ai-tools-base -)" "directory acl-drift"
expect_read "a missing file"                     "$(entry "${FX}/none" file "${me}" 0644 - ai-tools-base files)" "absent missing"
expect_read "an absent optional row"             "$(entry "${FX}/none" file "${me}" 0644 - ai-tools-base optional)" "absent"
expect_read "a directory where a file belongs"   "$(entry "${FX}/dir" file "${me}" 0644 - ai-tools-base files)" "directory type-mismatch"
expect_read "a dangling link"                    "$(entry "${FX}/dangling" link "${me}" 0777 - ai-tools-base files)" "link missing"
expect_read "a link whose target exists"         "$(entry "${FX}/goodlink" link "${me}" 0777 - ai-tools-base files)" "link"
expect_read "a payload file under a pass without rpm reads unverified, no finding" \
    "$(entry "${FX}/file" file "${me}" 0644 - ai-tools-base files)" "file"
declare -A st=(); declare -a found=()
ai_tools_layout__read_entry_state "$(entry "${FX}/file" file "${me}" 0644 - ai-tools-base files)" st found
acl_0644="$(acl_text 0644 -)"
[[ "${st[content]}" == unverified && "${st[expected_acl]}" == "${acl_0644}" && "${st[path]}" == "${FX}/file" ]] \
    && pass "the state carries the content state, the expected ACL and the path" \
    || fail "state: content='${st[content]}' path='${st[path]}'"
# Output names: each refusal returns 1 and writes neither array.
declare -A both=(); declare -a seven=()
rc=0; ai_tools_layout__read_entry_state "$(entry "${FX}/file" file "${me}" 0644 - ai-tools-base -)" both both || rc=$?
(( rc == 1 )) && pass "one name for both outputs is refused" || fail "aliased outputs: rc ${rc}"
declare -A _layout_state=()
rc=0; ai_tools_layout__read_entry_state "$(entry "${FX}/file" file "${me}" 0644 - ai-tools-base -)" _layout_state seven || rc=$?
(( rc == 1 && ${#_layout_state[@]} == 0 )) && pass "a name under the library's own prefix is refused" || fail "prefixed name: rc ${rc}"
rc=0; ai_tools_layout__read_entry_state "$(entry "${FX}/file" file "${me}" 0644 - ai-tools-base -)" undeclared_name seven || rc=$?
(( rc == 1 )) && pass "an undeclared name is refused" || fail "undeclared name: rc ${rc}"
rc=0; ai_tools_layout__read_entry_state "$(entry "${FX}/file" file "${me}" 0644 - ai-tools-base -)" seven both || rc=$?
(( rc == 1 )) && pass "a list where a map belongs is refused" || fail "wrong type: rc ${rc}"
rc=0; ai_tools_layout__read_entry_state "not	an	entry" both seven || rc=$?
(( rc == 1 )) && pass "a line that is not an entry is refused" || fail "bad entry: rc ${rc}"

section "layout: the content evaluator over seeded collector results"
ai_tools_layout__begin_pass 0
_AI_TOOLS_LAYOUT__PACKAGE_VERIFY[p]=verified
_AI_TOOLS_LAYOUT__CONTENT_FLAGS[/a]='.........'; _AI_TOOLS_LAYOUT__CONTENT_FLAGS[/b]='..5......'
_AI_TOOLS_LAYOUT__CONTENT_FLAGS[/c]='..?......'; _AI_TOOLS_LAYOUT__CONTENT_FLAGS[/d]=missing
_AI_TOOLS_LAYOUT__CONTENT_FLAGS[/f]='S.......T'
state_of() { local out; out="$(_ai_tools_layout__evaluate_content "$1" "$2")"; printf '%s' "${out%%$'\t'*}"; }
[[ "$(state_of p /a)" == verified ]]   && pass "a line of dots is verified"           || fail "/a: $(state_of p /a)"
[[ "$(state_of p /f)" == verified ]]   && pass "a difference outside the digest is verified" || fail "/f: $(state_of p /f)"
[[ "$(state_of p /b)" == drift ]]      && pass "a 5 at the digest position is drift"  || fail "/b: $(state_of p /b)"
[[ "$(state_of p /c)" == unreadable ]] && pass "a ? at the digest position is unreadable" || fail "/c: $(state_of p /c)"
[[ "$(state_of p /d)" == unreadable ]] && pass "a file rpm reported missing is unreadable, not verified" || fail "/d: $(state_of p /d)"
[[ "$(state_of p /e)" == unverified ]] && pass "a path the package prints no line for is unverified, not verified" || fail "/e: $(state_of p /e)"
_AI_TOOLS_LAYOUT__PACKAGE_VERIFY[q]=error
[[ "$(state_of q /a)" == unreadable ]] && pass "a package whose collector failed is unreadable" || fail "q: $(state_of q /a)"
[[ "$(state_of r /a)" == unverified ]] && pass "a package the pass did not verify is unverified" || fail "r: $(state_of r /a)"
ai_tools_layout__begin_pass 1
(( ${#_AI_TOOLS_LAYOUT__PACKAGE_VERIFY[@]} == 0 && ${#_AI_TOOLS_LAYOUT__CONTENT_FLAGS[@]} == 0 )) \
    && pass "a new pass forgets the last pass's results" || fail "results survived begin_pass"
[[ "$(state_of p /b)" == unverified ]] && pass "after a new pass without rpm, a drifted path reads unverified" || fail "/b after reset: $(state_of p /b)"
_ai_tools_layout__is_payload_file file files && pass "a files regular file is a payload file" || fail "payload: files"
_ai_tools_layout__is_payload_file file files,config && fail "a config file is not a payload file" || pass "a config file is not a payload file"
_ai_tools_layout__is_payload_file file files,ghost  && fail "a ghost is not a payload file"      || pass "a ghost is not a payload file"
_ai_tools_layout__is_payload_file directory files   && fail "a directory is not a payload file"  || pass "a directory is not a payload file"
_ai_tools_layout__is_payload_file file -            && fail "a runtime file is not a payload file" || pass "a runtime file is not a payload file"

section "layout: the entry set"
# entries <root> : the entry lines (no error lines) for a fixture root, their paths with the root stripped.
entries() { AI_TOOLS_LAYOUT_ROOT="$1" ai_tools_layout__list_entries | grep -v '^error' | cut -f1 | sed "s#^$1##" || true; }
errors()  { AI_TOOLS_LAYOUT_ROOT="$1" ai_tools_layout__list_entries | grep '^error' || true; }
R1="${TESTDIR}/r1"; mkdir -p "${R1}/usr/local/libexec/ai-tools"; : > "${R1}/usr/local/libexec/ai-tools/ai-tools-admin"
set1="$(entries "${R1}")"
grep -qx /etc/ai-tools/operator.conf <<< "${set1}" && pass "base's sentinel brings base's rows" || fail "base rows absent"
grep -q '^/usr/local/lib/ai-tools/typesafe' <<< "${set1}" && fail "typesafe rows present without its sentinel" || pass "an absent integration contributes no row"
grep -qx /etc/ai-tools/endpoints <<< "${set1}" && fail "the shared endpoints directory present without either owner" \
    || pass "the shared endpoints directory is absent without either owner"
R2="${TESTDIR}/r2"; mkdir -p "${R2}/usr/local/libexec/ai-tools" "${R2}/usr/local/lib/ai-tools/typesafe" "${R2}/usr/local/share/man/man5"
: > "${R2}/usr/local/libexec/ai-tools/ai-tools-admin"; : > "${R2}/usr/local/lib/ai-tools/typesafe/decide.mjs"
: > "${R2}/usr/local/share/man/man5/ai-tools-typesafe.conf.5.gz"
set2="$(entries "${R2}")"
grep -qx /etc/ai-tools/endpoints <<< "${set2}" && pass "the shared endpoints directory applies under the typesafe owner alone" \
    || fail "endpoints absent under typesafe"
grep -qx /usr/local/lib/ai-tools/typesafe/decide.mjs <<< "${set2}" && pass "the second sentinel alone brings the package's rows" \
    || fail "second sentinel did not apply"
grep -qx /usr/local/share/man/man5/ai-tools-typesafe.conf.5.gz <<< "${set2}" && pass "a compressed row resolves to the .gz where it exists" \
    || fail ".gz not resolved"
grep -qx /usr/local/share/man/man1/ai-tools.1 <<< "${set2}" && pass "a compressed row stays plain where no .gz exists" || fail "plain page absent"
sorted_ok=0; cut -f1 <<< "$(AI_TOOLS_LAYOUT_ROOT="${R2}" ai_tools_layout__list_entries | grep -v '^error')" | LC_ALL=C sort -c 2>/dev/null && sorted_ok=1
(( sorted_ok )) && pass "the entry set is sorted by path, so a parent precedes every path under it" || fail "entry set not sorted"
rc=0; AI_TOOLS_LAYOUT_ROOT="${R2}" ai_tools_layout__list_entries >/dev/null || rc=$?
errs="$(errors "${R2}")"
if (( EUID == 0 )); then
    (( rc == 0 )) && pass "root-owned inputs: discovery complete (status 0)" || fail "root run: status ${rc}, errors: ${errs}"
    grep -qx /opt/ai-tools/.acme <<< "${set2}" && pass "an installed manifest's config_dir is a dynamic row" || fail ".acme row absent"
    grep -q '/opt/ai-tools/.nodir' <<< "${set2}" && fail "a manifest without config_dir yielded a row" || pass "a manifest without config_dir yields no row"
    grep -qx "${PROJECTS_HOME}/.config/ai-tools/allowed-projects" <<< "${set2}" && pass "an enrolled operator's rows are dynamic rows" \
        || fail "operator rows absent"
else
    (( rc == 1 )) && pass "an input the invoker owns is untrusted: status 1" || fail "untrusted inputs: status ${rc}"
    grep -q "^error	directory	${AGENTS_DIR}	agents	" <<< "${errs}" && pass "the untrusted agents directory is an error line naming it" \
        || fail "agents.d error line: ${errs}"
    grep -q "^error	file	${TESTDIR}/operator.conf	operators	" <<< "${errs}" && pass "the untrusted operator.conf is an error line naming it" \
        || fail "operator.conf error line: ${errs}"
    grep -q '/opt/ai-tools/.acme' <<< "${set2}" && fail "an untrusted manifest yielded a row" || pass "an untrusted manifest yields no row"
fi
# A declaration error refuses every public reader: driven in a subshell, so the table stays valid here.
rc=0; ( AI_TOOLS_LAYOUT__DECLARATION_ERROR="x is bad"; ai_tools_layout__list_entries ) >/dev/null 2>&1 || rc=$?
(( rc == 2 )) && pass "list_entries returns 2 under a declaration error" || fail "list_entries under error: ${rc}"
rc=0; ( AI_TOOLS_LAYOUT__DECLARATION_ERROR="x is bad"; declare -A m=(); declare -a l=()
    ai_tools_layout__read_entry_state "$(entry "${FX}/file" file "${me}" 0644 - ai-tools-base -)" m l ) || rc=$?
(( rc == 2 )) && pass "read_entry_state returns 2 under a declaration error" || fail "read_entry_state under error: ${rc}"
# The framing decodes: a path carrying a TAB round-trips through the line.
declare -a decoded=()
_ai_tools_layout__parse_entry_line "$(entry $'/a\tb' file root:root 0644 - ai-tools-base files)" decoded
[[ "${decoded[0]}" == $'/a\tb' && ${#decoded[@]} -eq 8 ]] && pass "a path holding a tab is carried whole through the framing" \
    || fail "framing: '${decoded[0]}' (${#decoded[@]} fields)"

section "layout: the --check stream"
# stream <all> : the records of a --check pass over fixture root R2, stdout alone.
stream() { ai_tools_records_base__begin_report; AI_TOOLS_LAYOUT_ROOT="${R2}" ai_tools_layout__write_check_records "$1"; }
# column <name> <header> <row> : one field by column name, decoded. Split by the library's parser: `read` would collapse
# an empty field between two tabs.
column() {
    local -a names=() fields=(); local i
    _ai_tools_layout__parse_entry_line "$2" names; _ai_tools_layout__parse_entry_line "$3" fields
    for i in "${!names[@]}"; do [[ "${names[$i]}" == "$1" ]] && { printf '%s' "${fields[$i]:-}"; return 0; }; done
    return 1
}
out="$(stream 0)"; header="${out%%$'\n'*}"
[[ "${header}" == "observed-at	occurred-at	code	record-id	severity	finding	subject-type	operator	item	subject	detail" ]] \
    && pass "the header is the page's column set" || fail "header: ${header}"
row="$(grep "	missing	file		" <<< "${out}" | grep "ai-tools-admin.8" | head -n1 || true)"
[[ -n "${row}" ]] && pass "a missing manual page is one row" || fail "no missing row for the manual page"
[[ "$(column code "${header}" "${row}")" == MSG-C6Y6 && "$(column severity "${header}" "${row}")" == attention ]] \
    && pass "the missing row carries its code and severity" || fail "missing row: code $(column code "${header}" "${row}")"
[[ "$(column item "${header}" "${row}")" == $'type\tfile\tabsent' ]] && pass "its item is the type, the expected type and absent" \
    || fail "missing item: $(column item "${header}" "${row}" | tr '\t' '|')"
if (( EUID == 0 )); then
    grep -q "	error	" <<< "${out}" && fail "a root run over trusted inputs printed an error row" || pass "root run: no error row"
else
    row="$(grep "	error	directory		" <<< "${out}" | head -n1 || true)"
    [[ "$(column code "${header}" "${row}")" == MSG-U7U5 && "$(column subject "${header}" "${row}")" == "${AGENTS_DIR}" ]] \
        && pass "the untrusted agents directory is an error row under its code naming the directory" \
        || fail "agents error row: '${row}'"
    [[ "$(column item "${header}" "${row}")" == $'agents\t-\t-' ]] && pass "its item names the source" || fail "agents item: $(column item "${header}" "${row}" | tr '\t' '|')"
fi
grep -q "	ok	" <<< "${out}" && fail "an ok row without --all" || pass "no ok row without --all"
out_all="$(stream 1)"
row="$(grep "	ok	" <<< "${out_all}" | grep "/usr/share/ai-tools/audit	" | head -n1 || true)"
[[ "$(column code "${header}" "${row}")" == MSG-P7W4 && "$(column detail "${header}" "${row}")" == "absent; the row is optional" ]] \
    && pass "--all reports an absent optional row as ok, saying the absence is permitted" || fail "ok row: '${row}'"
[[ "$(column item "${header}" "${row}")" == $'all\t-\t-' ]] && pass "an ok row's item is all" || fail "ok item: $(column item "${header}" "${row}")"
rc=0; ( ai_tools_records_tsv__write_record() { return 1; }; stream 0 >/dev/null ) || rc=$?
(( rc == 1 )) && pass "a failed write reaches the caller as status 1" || fail "failed write: rc ${rc}"
out="$( AI_TOOLS_LAYOUT__DECLARATION_ERROR="x is bad"; stream 0 )"
[[ "$(grep -c . <<< "${out}")" -eq 2 ]] && pass "a declaration error writes one row" || fail "declaration error rows: $(grep -c . <<< "${out}")"
row="${out#*$'\n'}"
[[ "$(column finding "${header}" "${row}")" == error && "$(column detail "${header}" "${row}")" == "x is bad" \
    && "$(column item "${header}" "${row}")" == $'declarations\t-\t-' ]] \
    && pass "the row is an error naming the declaration refused" || fail "declaration row: '${row}'"
# `--check` is read-only: the fixture tree's modes and owners are what they were.
before="$(cd "${R2}" && find . -printf '%p %U:%G %m\n' | LC_ALL=C sort)"
stream 1 >/dev/null
after="$(cd "${R2}" && find . -printf '%p %U:%G %m\n' | LC_ALL=C sort)"
[[ "${before}" == "${after}" ]] && pass "a --check pass leaves owner and mode unchanged" || fail "the fixture tree changed under --check"

section "layout: lockstep with packaging/ai-tools.spec"
if [[ ! -r "${SPEC}" ]] || ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "spec lockstep" "outside a checkout"
else
    declare -A row_by_path=() macros=( [_sysconfdir]=/etc [_datadir]=/usr/share [_unitdir]=/usr/lib/systemd/system
        [_userunitdir]=/usr/lib/systemd/user [_presetdir]=/usr/lib/systemd/system-preset [_sbindir]=/usr/sbin
        [_sysusersdir]=/usr/lib/sysusers.d )
    declare -A spec_paths=() tree_lines=() dynamic_paths=()
    for entry in "${_AI_TOOLS_LAYOUT__STATIC_ENTRIES[@]}"; do row_by_path["${entry%%$'\t'*}"]="${entry#*$'\t'}"; done
    # expand <text> : the spec macros substituted; a macro left is a failure.
    expand() { local t="$1" m; for m in "${!macros[@]}"; do t="${t//%\{${m}\}/${macros[${m}]}}"; done; printf '%s' "${t}"; }
    list_re='^[[:space:]]*echo "(%\{[^"$]+)" >> selinux-files.list'
    while IFS= read -r line; do
        [[ "${line}" =~ ^%global\ (ai_[a-z]+)\ +(/[^ ]+) ]] && macros["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        # The SELinux package lists its files through a list %install writes: each literal path echoed into it is
        # that package's %files line.
        [[ "${line}" =~ ${list_re} ]] && spec_paths["$(expand "${BASH_REMATCH[1]}")"]=ai-tools-selinux
    done < "${SPEC}"
    # A shipped agent's config directory is a dynamic row by design (no static row names it); its %dir line is held
    # to the manifest in the closing case.
    for manifest in "${LIB_DIR}"/agents.d/*.conf; do
        config_dir="$(sed -n 's/^config_dir=//p' "${manifest}" | head -n1)"
        [[ -n "${config_dir}" ]] && dynamic_paths["/opt/ai-tools/${config_dir}"]=1
    done
    package="" lines=0 problems=0 attr_re='%attr\(([^,]+), *([^,]+), *([^)]+)\)'
    while IFS= read -r line; do
        [[ "${line}" == '%changelog' ]] && break
        if [[ "${line}" =~ ^%files(\ +-n\ +([a-z-]+))? ]]; then package="${BASH_REMATCH[2]:-ai-tools}"; continue; fi
        [[ -n "${package}" ]] || continue
        [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "${line}" =~ ^%(license|doc|exclude) ]] && continue
        line="$(expand "${line}")"
        if [[ "${line}" == *'%{'* ]]; then fail "lockstep: unresolved macro in '${line}'"; problems=$(( problems + 1 )); continue; fi
        attr_mode="" attr_owner="" is_dir=0 is_config=0 is_ghost=0
        if [[ "${line}" =~ ${attr_re} ]]; then
            attr_mode="${BASH_REMATCH[1]}" attr_owner="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
        fi
        [[ "${line}" == *'%dir'* ]] && is_dir=1
        [[ "${line}" == *'%config'* ]] && is_config=1
        [[ "${line}" == *'%ghost'* ]] && is_ghost=1
        path="${line##* }"; path="${path%\*}"
        spec_paths["${path}"]="${package}"
        lines=$(( lines + 1 ))
        [[ -n "${dynamic_paths[${path}]+x}" ]] && continue
        # A line naming a directory without %dir ships the whole tree under it.
        (( is_dir )) || [[ "${row_by_path[${path}]+x}" != x ]] || [[ "${row_by_path[${path}]%%$'\t'*}" != directory ]] \
            || tree_lines["${path}"]=1
        if [[ -z "${row_by_path[${path}]+x}" ]]; then
            if [[ -z "${attr_mode}" && "${path}" == /usr/share/ai-tools/* ]]; then continue; fi  # shipped data, rpm's defaults
            fail "lockstep: %files line has no row: ${path} (${package})"; problems=$(( problems + 1 )); continue
        fi
        IFS=$'\t' read -r r_type r_owner r_mode r_acl r_packages r_flags <<< "${row_by_path[${path}]}"
        if [[ ",${r_packages}," != *",${package},"* ]]; then
            fail "lockstep: ${path} is in ${package}'s %files, the row names ${r_packages}"; problems=$(( problems + 1 )); continue
        fi
        if [[ ",${r_flags}," != *,files,* ]]; then
            fail "lockstep: ${path} is a %files line, the row lacks files"; problems=$(( problems + 1 )); continue
        fi
        if (( is_dir )) && [[ "${r_type}" != directory ]]; then
            fail "lockstep: %dir ${path} is a ${r_type} row"; problems=$(( problems + 1 )); continue
        fi
        if [[ -n "${attr_mode}" && "${attr_mode}" != - ]]; then
            [[ "${attr_mode}" == "${r_mode}" && "${attr_owner}" == "${r_owner}" ]] \
                || { fail "lockstep: ${path} is %attr(${attr_mode}, ${attr_owner}), the row says ${r_mode} ${r_owner}"; problems=$(( problems + 1 )); continue; }
        fi
        [[ "${line}" == *'*' ]] && [[ ",${r_flags}," != *,compressed,* ]] \
            && { fail "lockstep: ${path}* is not a compressed row"; problems=$(( problems + 1 )); continue; }
        if (( is_config )) && [[ ",${r_flags}," != *,config,* ]] || { (( ! is_config )) && [[ ",${r_flags}," == *,config,* ]]; }; then
            fail "lockstep: ${path}: %config and the config flag disagree"; problems=$(( problems + 1 )); continue
        fi
        if (( is_ghost )) && [[ ",${r_flags}," != *,ghost,* ]] || { (( ! is_ghost )) && [[ ",${r_flags}," == *,ghost,* ]]; }; then
            fail "lockstep: ${path}: %ghost and the ghost flag disagree"; problems=$(( problems + 1 )); continue
        fi
    done < "${SPEC}"
    (( lines > 100 )) && pass "the spec's %files lines were read (${lines})" || fail "the spec parser read ${lines} lines"
    (( problems == 0 )) && pass "every %files line resolves to its row with the same owner, mode, package and flags"
    # The reverse: every files row of a package is a %files line of that package's section.
    reverse=0
    for entry in "${_AI_TOOLS_LAYOUT__STATIC_ENTRIES[@]}"; do
        IFS=$'\t' read -r r_path r_type r_owner r_mode r_acl r_packages r_flags <<< "${entry}"
        [[ ",${r_flags}," == *,files,* ]] || continue
        covered=0; [[ -n "${spec_paths[${r_path}]+x}" ]] && covered=1
        for tree in "${!tree_lines[@]}"; do [[ "${r_path}" == "${tree}/"* ]] && covered=1; done
        (( covered )) || { fail "lockstep: files row ${r_path} is not a %files line"; reverse=$(( reverse + 1 )); }
    done
    (( reverse == 0 )) && pass "every files row is a %files line of its package"
    # Each shipped agent's config_dir has its %dir line in that agent's package section.
    for manifest in "${LIB_DIR}"/agents.d/*.conf; do
        agent="${manifest##*/}"; agent="${agent%.conf}"
        config_dir="$(sed -n 's/^config_dir=//p' "${manifest}" | head -n1)"
        [[ -n "${config_dir}" ]] || continue
        wanted="/opt/ai-tools/${config_dir}"
        [[ -n "${row_by_path[${wanted}]+x}" ]] && fail "lockstep: ${wanted} is a static row; an agent's config directory is dynamic"
        if [[ "${spec_paths[${wanted}]:-}" == "ai-tools-agents-${agent}-restricted" ]] \
                && grep -qE "^%dir %attr\(${CP_AGENT_CONFIG_MODE}, root, ai-tools\) ${wanted}$" "${SPEC}"; then
            pass "lockstep: ${agent}'s config_dir has its %dir line at CP_AGENT_CONFIG_MODE in its package"
        else
            fail "lockstep: no %dir %attr(${CP_AGENT_CONFIG_MODE}, root, ai-tools) ${wanted} in ai-tools-agents-${agent}-restricted"
        fi
    done
fi

finish

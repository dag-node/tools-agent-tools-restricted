#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/layout.sh
# Unit test for the installed-layout library (layout.lib.sh), the one table `ai-tools-admin system layout` reads,
# `system layout reconcile` repairs, and tests/integration/perms.sh loops over. What it pins, in the order the file
# runs:
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
#   * the reconcile's pure decisions: path containment by component, the log level a change earns, which rows are
#     discovery inputs, and the ancestor a row is refused under;
#   * the reconcile lock across processes: held, released, and a lock file that cannot be created -- each a refusal,
#     since a lock the reconcile cannot take is an error line and no write;
#   * the per-entry repair over fixtures the invoker owns: a drift converged through the pinned descriptor with its
#     `changed` line and its log line at the level the rule states, a missing directory created under an existing
#     parent and refused under a missing one, a missing file, a dangling link and an entry of another type refused,
#     a package file left whole on drifted, unreadable, failed and unverified content, a leaf swapped for a symlink
#     between the read and the open and a parent swapped under the entry each refused with the outside file untouched,
#     a row under an ancestor not at its row refused unread, and a write that fails reported with its tool;
#   * the reconcile as root, over a tree built from the table itself: a converged tree does not print a line, each
#     planted drift converges in one run and a second run prints nothing, content drift beside owner, mode and ACL drift
#     leaves every field, a masked-off foreign entry is removed with no state in which it is effective, a symlink
#     at a directory row refuses the rows under it with no directory at the target, a missing directory under
#     a missing parent is refused, an untrusted discovery input and the drift in the dynamic rows it hides converge
#     in one invocation, an invalid manifest and an unresolved account stay visible at exit 5, a held lock is
#     an error with no write, the exit order 1, 5, 4 holds, and a non-root caller is refused;
#   * the boundary pair: every `boundary` row is held to a map naming its gate and the runtime and boundary test
#     files that drive it, each file holding the literal the map cites;
#   * lockstep with packaging/ai-tools.spec, in a checkout: every `%attr` line resolves to a row with the same owner,
#     mode and config/ghost flag, every bare line is a row or shipped data, and every `files` row is a `%files` line
#     of its package.
# Runs unprivileged: the trusted branches of the dynamic enumeration need root-owned inputs, so where the run is root
# those cases assert the rows, and otherwise the `error` line the untrusted fixture earns. The root half skips
# unprivileged, naming why.

# shellcheck disable=SC2015  # `check && pass || fail`: pass returns 0, so fail runs only on a failed check
# shellcheck disable=SC2034,SC2154  # an array handed to the library by name is written through its nameref, and a key
#                                   # of an associative array reads as a variable to ShellCheck
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
# The root half drives the projects user through the fixture directories `mkdir` makes, and every row's mode is set
# explicitly, so the invoker's umask decides neither.
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${ROOT}/src/usr/local/lib/ai-tools"
LIB="${LIB_DIR}/layout.lib.sh"
SPEC="${ROOT}/packaging/ai-tools.spec"
TEST_TREE="${ROOT}/tests"
printf 'layout: %s\n' "${LIB}"

section "layout: loading the checkout's library (unit)"
[[ -r "${LIB}" ]] || { fail "the checkout's layout library is not readable"; finish; exit; }
mktestdir
# A copy with the sandbox tokens substituted, as install.sh and the spec substitute them: the owner grammar refuses
# the raw token. The siblings are copied beside it, since the library sources them from its own directory. The copy
# takes the checkout's modes (a collaborative tree is 2770/660, with no other-bits), and the root half sources it
# as the projects user, so it is opened to every account here.
cp -r "${LIB_DIR}" "${TESTDIR}/lib"
chmod -R u+rwX,go+rX "${TESTDIR}/lib"
sed -i -e "s/@SANDBOX_USER@/${SANDBOX_USER}/g" -e "s/@SANDBOX_GROUP@/${SANDBOX_GROUP}/g" "${TESTDIR}/lib/layout.lib.sh"
FIXTURE_ROOT="${TESTDIR}/root"
# The two discovery inputs sit at their rows under the fixture root, so the root half converges an input and the dynamic
# rows it hides in one run; unprivileged they are the invoker's, which the trust predicate refuses.
AGENTS_DIR="${FIXTURE_ROOT}/usr/local/lib/ai-tools/agents.d"
OPERATOR_CONF="${FIXTURE_ROOT}/etc/ai-tools/operator.conf"
mkdir -p "${FIXTURE_ROOT}" "${AGENTS_DIR}" "${OPERATOR_CONF%/*}"
printf 'config_dir=.acme\nlauncher=acme\n' > "${AGENTS_DIR}/acme.conf"
printf 'launcher=nodir\n' > "${AGENTS_DIR}/nodir.conf"
chmod 0755 "${AGENTS_DIR}"; chmod 0644 "${AGENTS_DIR}"/*.conf
printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${OPERATOR_CONF}"
chmod 0644 "${OPERATOR_CONF}"
# The hooks the enumeration reads are readonly once the libraries load, so they are set before the source; the lock pair
# moves the reconcile's lock into the testdir, never /run/lock.
export AI_TOOLS_LAYOUT_ROOT="${FIXTURE_ROOT}" AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}"
export AI_TOOLS_OPERATOR_CONF="${OPERATOR_CONF}"
export AI_TOOLS_LAYOUT_LOCK="${TESTDIR}/layout.lock" AI_TOOLS_LAYOUT_LOCK_WAIT=1
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
# ai-tools-admin sources the library inside a function (layout_load), where a file-scope `declare` without -g makes
# the map that function's local: once it returns, the reconcile's reset recreates the name as an indexed array
# and a path key is read as arithmetic. A fresh shell sources it the same way and reads every file-scope declaration
# back.
scope_text="$(grep -oE '^declare -[a-zA-Z]+ _AI_TOOLS_LAYOUT__[A-Z_]+' "${TESTDIR}/lib/layout.lib.sh" || true)"
scope_names=()
[[ -z "${scope_text}" ]] || mapfile -t scope_names < <(awk '{print $3}' <<< "${scope_text}")
scope_out="$(bash -c '
    load() { source "$1" || exit 3; }
    load "$1"; shift
    for name in "$@"; do declare -p "${name}" >/dev/null 2>&1 || printf "not global: %s\n" "${name}"; done
    _ai_tools_layout__reset_reconcile_state
    _AI_TOOLS_LAYOUT__ROW_PATHS["/usr/local/libexec/ai-tools"]=row
    [[ "${_AI_TOOLS_LAYOUT__ROW_PATHS[/usr/local/libexec/ai-tools]:-}" == row ]] || printf "a path key did not read back\n"
' _ "${TESTDIR}/lib/layout.lib.sh" "${scope_names[@]}" 2>&1)" && scope_status=0 || scope_status=$?
if (( ${#scope_names[@]} == 0 )); then
    fail "the file-scope declarations were not found in the library copy"
elif (( scope_status == 0 )) && [[ -z "${scope_out}" ]]; then
    pass "sourced inside a function, every file-scope map stays global and takes a path key (${#scope_names[@]} maps)"
else
    fail "sourced inside a function (status ${scope_status}): $(tr '\n' '|' <<< "${scope_out}")"
fi

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
    grep -q "^error	file	${OPERATOR_CONF}	operators	" <<< "${errs}" && pass "the untrusted operator.conf is an error line naming it" \
        || fail "operator.conf error line: ${errs}"
    grep -q '/opt/ai-tools/.acme' <<< "${set2}" && fail "an untrusted manifest yielded a row" || pass "an untrusted manifest yields no row"
fi
# A declaration error refuses every public reader: driven in a subshell, so the table stays valid here.
rc=0; ( AI_TOOLS_LAYOUT__DECLARATION_ERROR="x is bad"; ai_tools_layout__list_entries ) >/dev/null 2>&1 || rc=$?
(( rc == 2 )) && pass "list_entries returns 2 under a declaration error" || fail "list_entries under error: ${rc}"
rc=0; ( AI_TOOLS_LAYOUT__DECLARATION_ERROR="x is bad"; declare -A m=(); declare -a l=()
    ai_tools_layout__read_entry_state "$(entry "${FX}/file" file "${me}" 0644 - ai-tools-base -)" m l ) || rc=$?
(( rc == 2 )) && pass "read_entry_state returns 2 under a declaration error" || fail "read_entry_state under error: ${rc}"
rc=0; ( AI_TOOLS_LAYOUT__DECLARATION_ERROR="x is bad"; ai_tools_layout__reconcile 0 ) >/dev/null 2>&1 || rc=$?
(( rc == 2 )) && pass "reconcile returns 2 under a declaration error" || fail "reconcile under error: ${rc}"
# The framing decodes: a path carrying a TAB round-trips through the line.
declare -a decoded=()
ai_tools_layout__parse_line "$(entry $'/a\tb' file root:root 0644 - ai-tools-base files)" decoded
[[ "${decoded[0]}" == $'/a\tb' && ${#decoded[@]} -eq 8 ]] && pass "a path holding a tab is carried whole through the framing" \
    || fail "framing: '${decoded[0]}' (${#decoded[@]} fields)"

section "layout: the --check stream"
# stream <all> : the records of a --check pass over fixture root R2, stdout alone.
stream() { ai_tools_records_base__begin_report; AI_TOOLS_LAYOUT_ROOT="${R2}" ai_tools_layout__write_check_records "$1"; }
# column <name> <header> <row> : one field by column name, decoded. Split by the library's parser: `read` would collapse
# an empty field between two tabs.
column() {
    local -a names=() fields=(); local i
    ai_tools_layout__parse_line "$2" names; ai_tools_layout__parse_line "$3" fields
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

section "layout: the entry set read as a collector"
# collected : read_entry_lines into an array; prints `status=<n>`, then each line.
collected() {
    local -a collected_lines=(); local rc=0
    ai_tools_layout__read_entry_lines collected_lines || rc=$?
    printf 'status=%s\n' "${rc}"
    (( ${#collected_lines[@]} == 0 )) || printf '%s\n' "${collected_lines[@]}"
}
# Each case replaces the enumerator inside a subshell, so the library's own stands for the rest of the file. A status
# the lines do not account for must add one `error` line; one they account for must add none.
generic_9="$(raw error host layout.lib.sh entries "the entry set exited 9")"
generic_1="$(raw error host layout.lib.sh entries "the entry set ended without reporting its incomplete discovery")"
out="$( ai_tools_layout__list_entries() { return 9; }; collected )"
[[ "${out}" == "status=9"$'\n'"${generic_9}" ]] \
    && pass "an enumerator that exits 9 without a line is one error line naming the status" || fail "exit 9: $(tr '\n\t' '| ' <<< "${out}")"
out="$( ai_tools_layout__list_entries() { return 1; }; collected )"
[[ "${out}" == "status=1"$'\n'"${generic_1}" ]] \
    && pass "an enumerator that returns 1 without its error line is one error line saying so" || fail "exit 1 bare: $(tr '\n\t' '| ' <<< "${out}")"
own_error="$(raw error file /x agents "the manifest is not root's")"
out="$( ai_tools_layout__list_entries() { printf '%s\n' "$(entry /a file root:root 0644 - ai-tools-base files)" "${own_error}"; return 1; }
    collected )"
[[ "${out}" == "status=1"$'\n'"$(entry /a file root:root 0644 - ai-tools-base files)"$'\n'"${own_error}" ]] \
    && pass "an enumerator that prints its own error line and returns 1 keeps that line alone" || fail "own error line: $(tr '\n\t' '| ' <<< "${out}")"
out="$( ai_tools_layout__list_entries() { printf '%s\n' "$(entry /a file root:root 0644 - ai-tools-base files)"; return 0; }
    collected )"
[[ "${out}" == "status=0"$'\n'"$(entry /a file root:root 0644 - ai-tools-base files)" ]] \
    && pass "a complete set reads status 0 with no line added" || fail "clean set: $(tr '\n\t' '| ' <<< "${out}")"
# The real enumerator over R2, as the control: its status and its own lines arrive, and no generic line is added.
real_rc=0; AI_TOOLS_LAYOUT_ROOT="${R2}" ai_tools_layout__list_entries >/dev/null || real_rc=$?
out="$(AI_TOOLS_LAYOUT_ROOT="${R2}" collected)"
[[ "${out%%$'\n'*}" == "status=${real_rc}" && "${out}" != *"the entry set e"* ]] \
    && pass "the real enumerator's status (${real_rc}) and lines arrive with no line added" || fail "real set: $(head -n1 <<< "${out}")"
declare -a _layout_refused=()
rc=0; ai_tools_layout__read_entry_lines _layout_refused || rc=$?
(( rc == 2 && ${#_layout_refused[@]} == 0 )) && pass "a name under the library's own prefix is refused with 2, unwritten" \
    || fail "refused name: rc ${rc}, ${#_layout_refused[@]} lines"
# The consumers the command reaches. The check stream, with the enumerator exiting 9: one error row naming the status,
# and the report exits 5 (unreadable) rather than reading as a clean empty host.
out="$( ai_tools_layout__list_entries() { return 9; }; stream 0
        report_status=0; ai_tools_records_base__get_exit_status || report_status=$?; printf 'report_status=%s\n' "${report_status}" )"
row="$(grep "	error	host	" <<< "${out}" | head -n1 || true)"
[[ "$(column detail "${header}" "${row}")" == "the entry set exited 9" && "$(grep -c "	error	" <<< "${out}")" -eq 1 ]] \
    && grep -qx 'report_status=5' <<< "${out}" \
    && pass "the check stream writes one error row for a lost entry set and reports 5" || fail "lost set in the stream: $(tr '\n\t' '| ' <<< "${out}")"
# The human table, through the admin helper sourced in a fresh shell with the library copy beside it.
# shellcheck disable=SC2016  # the inner bash expands these
out="$(bash -c 'source "$1" >/dev/null 2>&1 || exit 3; source "$2" || exit 4
    ai_tools_layout__list_entries() { return 9; }
    rc=0; layout_table || rc=$?; printf "rc=%s\n" "${rc}"' _ "${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh" \
    "${TESTDIR}/lib/layout.lib.sh" 2>&1)" || true
grep -q '^error .*layout.lib.sh (entries): the entry set exited 9$' <<< "${out}" && grep -qx 'rc=5' <<< "${out}" \
    && pass "the human table prints the lost entry set as an error line and exits 5" || fail "lost set in the table: $(tr '\n' '|' <<< "${out}")"

section "layout: the reconcile's pure decisions"
_ai_tools_layout__is_under /a/b/c /a/b && pass "a path under an ancestor is contained" || fail "/a/b/c is not under /a/b"
_ai_tools_layout__is_under /a/bc /a/b && fail "/a/bc reads as under /a/b" || pass "containment is by path component: /a/bc is not under /a/b"
_ai_tools_layout__is_under /a/b /a/b && fail "a path reads as under itself" || pass "a path is not under itself"
level() { _ai_tools_layout__evaluate_change_log_level "$@"; }
expect_level() { local got; got="$(level "$2" "$3" "$4")"; [[ "${got}" == "$5" ]] && pass "$1" || fail "$1: ${got}, wanted $5"; }
expect_level "an owner moving to root is info"            owner ai-tools:ai-tools root:root info
expect_level "a group moving to the sandbox group is notice" owner root:root root:ai-tools notice
expect_level "a user moving to root with the group kept is info" owner nobody:nobody root:nobody info
expect_level "a mode losing bits is info"                 mode 0666 0644 info
expect_level "a mode gaining a bit is notice"             mode 0600 0644 notice
expect_level "a setgid bit cleared is notice"             mode 2750 0750 notice
expect_level "a setgid bit set is notice"                 mode 0750 2750 notice
expect_level "a sticky bit cleared is notice"             mode 1777 0777 notice
expect_level "a mode outside its grammar is notice"       mode absent 0644 notice
expect_level "an ACL losing bits is info"   acl $'user::rw-\ngroup::r--\nother::r--' $'user::rw-\ngroup::---\nother::---' info
expect_level "an ACL entry gaining a bit is notice" acl $'user::rw-\ngroup::---\nother::---' $'user::rw-\ngroup::r--\nother::---' notice
expect_level "an ACL entry added is notice" acl $'user::rwx\ngroup::r-x\nother::---' $'user::rwx\ngroup::r-x\ngroup:ai-ops:r-x\nmask::r-x\nother::---' notice
expect_level "an ACL entry removed is info"  acl $'user::rwx\ngroup::r-x\ngroup:x:r-x\nmask::r-x\nother::---' $'user::rwx\ngroup::r-x\nother::---' info
expect_level "a label change is notice"                   label etc_t var_t notice
expect_level "a created entry is notice"                  type absent directory notice
_ai_tools_layout__is_discovery_input "${AGENTS_DIR}" && pass "the agents directory is a discovery input" || fail "agents.d is not a discovery input"
_ai_tools_layout__is_discovery_input "${AGENTS_DIR}/acme.conf" && pass "a manifest under it is a discovery input" || fail "a manifest is not"
_ai_tools_layout__is_discovery_input "${AGENTS_DIR}/sub/x.conf" && fail "a nested .conf reads as a discovery input" || pass "a nested .conf is not one"
_ai_tools_layout__is_discovery_input "${AGENTS_DIR}x" && fail "a sibling sharing the prefix reads as a discovery input" || pass "a sibling sharing the prefix is not one"
_ai_tools_layout__is_discovery_input "${OPERATOR_CONF}" && pass "operator.conf is a discovery input" || fail "operator.conf is not"
_ai_tools_layout__is_discovery_input "${OPERATOR_CONF%/*}" && pass "its directory is a discovery input" || fail "/etc/ai-tools is not"
_ai_tools_layout__is_discovery_input "${FIXTURE_ROOT}/usr/local/lib/ai-tools" && pass "the library directory is a discovery input, as an ancestor" || fail "the library directory is not"
_ai_tools_layout__is_discovery_input "${FIXTURE_ROOT}/usr/local/lib/ai-tools/log.lib.sh" && fail "a library beside the agents directory reads as a discovery input" || pass "a library beside it is not one"
_ai_tools_layout__reset_reconcile_state
_AI_TOOLS_LAYOUT__ROW_PATHS[/r/a]=row; _AI_TOOLS_LAYOUT__ROW_PATHS[/r/a/b]=row
_AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/a]=ok; _AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/a/b]=bad
[[ "$(_ai_tools_layout__find_refusing_ancestor /r/a/b/c)" == /r/a/b ]] && pass "a row under an ancestor not at its row names that ancestor" || fail "refusing ancestor: $(_ai_tools_layout__find_refusing_ancestor /r/a/b/c)"
_ai_tools_layout__find_refusing_ancestor /r/a/x >/dev/null && fail "a row under an ancestor at its row is refused" || pass "a row under an ancestor at its row is not refused"
_ai_tools_layout__find_refusing_ancestor /r/a/bc/x >/dev/null && fail "/r/a/bc/x is refused under /r/a/b" || pass "a refusal of /r/a/b does not reach /r/a/bc/x"
unset '_AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/a]'
[[ "$(_ai_tools_layout__find_refusing_ancestor /r/a/x)" == /r/a ]] && pass "an ancestor row the pass has not reached refuses the rows under it" || fail "unreached ancestor not refusing"
declare -A anc_state=( [path]=/r/p [expected_type]=directory [expected_owner]=root:root [expected_mode]=0755 [flags]=files [type]=directory [owner]=root:root [mode]=0755 )
_ai_tools_layout__record_ancestor_state anc_state
[[ "${_AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/p]}" == ok ]] && pass "an entry at its row records ok" || fail "at-row state: ${_AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/p]}"
anc_state[mode]=0775; _ai_tools_layout__record_ancestor_state anc_state
[[ "${_AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/p]}" == bad ]] && pass "an entry at another mode records bad" || fail "drifted state: ${_AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/p]}"
anc_state=( [path]=/r/p [expected_type]=directory [expected_owner]=root:root [expected_mode]=0755 [flags]="files,optional" [type]=absent )
_ai_tools_layout__record_ancestor_state anc_state
[[ "${_AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/p]}" == ok ]] && pass "an absent optional entry records ok" || fail "absent optional: ${_AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/p]}"
anc_state[flags]=files; _ai_tools_layout__record_ancestor_state anc_state
[[ "${_AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/p]}" == bad ]] && pass "an absent required entry records bad" || fail "absent required: ${_AI_TOOLS_LAYOUT__ANCESTOR_STATES[/r/p]}"
_ai_tools_layout__reset_reconcile_state

section "layout: the reconcile lock"
if ! command -v flock >/dev/null 2>&1; then
    skip "the reconcile lock" "flock is not installed"
else
    # take_lock <wait-seconds> <hold-seconds> : take the lock in a child process; print `held` or the reason.
    take_lock() {
        # shellcheck disable=SC2016  # the child shell expands these, not this one
        env AI_TOOLS_LAYOUT_LOCK="${AI_TOOLS_LAYOUT_LOCK}" AI_TOOLS_LAYOUT_LOCK_WAIT="$1" \
            bash -c 'source "$1" || exit 3; r=""; if _ai_tools_layout__lock r; then printf held; sleep "$2"; else printf "%s" "${r}"; fi' \
            _ "${TESTDIR}/lib/layout.lib.sh" "$2"
    }
    take_lock 5 3 >/dev/null &
    holder=$!
    sleep 0.5
    contended="$(take_lock 1 0)"
    [[ "${contended}" == "another reconcile held ${AI_TOOLS_LAYOUT_LOCK} for more than 1s" ]] \
        && pass "a lock another process holds is refused, naming the wait" || fail "contended lock: '${contended}'"
    wait "${holder}" 2>/dev/null || true
    [[ "$(take_lock 5 0)" == held ]] && pass "the lock is taken once its holder exits" || fail "the lock stayed held: $(take_lock 5 0)"
    unwritable="$(AI_TOOLS_LAYOUT_LOCK="${TESTDIR}/no-such-dir/layout.lock" take_lock 1 0 2>&1)"
    [[ "${unwritable}" == "cannot write ${TESTDIR}/no-such-dir/layout.lock" ]] \
        && pass "a lock file that cannot be created is refused" || fail "uncreatable lock: '${unwritable}'"
fi

section "layout: the per-entry repair over owned fixtures"
# shellcheck source=/dev/null
if ! source "${TESTDIR}/lib/safe-paths.lib.sh" 2>/dev/null \
        || ! declare -F ai_tools_safe_paths__is_pinned_fd_at_path >/dev/null 2>&1; then
    skip "the per-entry repair" "safe-paths.lib.sh did not load from the copy"
else
    RE="${FIXTURE_ROOT}/re"; mkdir -p "${RE}"
    LOG="${AI_TOOLS_LOG_DIR}/layout.log"
    # entry_run <entry-line> [<without-rpm>] : one entry through the reconcile, its lines on stdout.
    entry_run() {
        _ai_tools_layout__reset_reconcile_state
        ai_tools_layout__begin_pass "${2:-0}"
        _ai_tools_layout__reconcile_entry "$1"
    }
    # has_line <output> <tag> <path> <field> [<rest>] : the output carries that tagged line.
    has_line() { grep -q "^$2	$3	$4	${5:-}" <<< "$1"; }
    mode_of() { stat -c '%a' -- "$1"; }
    : > "${RE}/w"; chmod 0600 "${RE}/w"
    out="$(entry_run "$(entry "${RE}/w" file "${me}" 0644 - ai-tools-base -)")"
    has_line "${out}" changed "${RE}/w" mode "0600	0644" && [[ "$(mode_of "${RE}/w")" == 644 ]] \
        && pass "a mode drift converges through the pinned descriptor with its changed line" || fail "mode drift: ${out} / $(mode_of "${RE}/w")"
    has_line "${out}" changed "${RE}/w" acl && pass "the ACL text changed with the mode, and says so" || fail "no acl changed line: ${out}"
    grep -q "NOTICE.*${RE}/w mode 0600 -> 0644" "${LOG}" 2>/dev/null && pass "a widening is logged at notice" || fail "no notice line in ${LOG}: $(grep "${RE}/w" "${LOG}" 2>/dev/null | tr '\n' '|')"
    chmod 0666 "${RE}/w"
    out="$(entry_run "$(entry "${RE}/w" file "${me}" 0644 - ai-tools-base -)")"
    grep -q "INFO.*${RE}/w mode 0666 -> 0644" "${LOG}" 2>/dev/null && pass "a narrowing is logged at info" || fail "no info line: $(grep "${RE}/w mode 0666" "${LOG}" 2>/dev/null)"
    out="$(entry_run "$(entry "${RE}/w" file "${me}" 0644 - ai-tools-base -)")"
    [[ -z "${out}" ]] && pass "an entry at its row prints no line" || fail "converged entry printed: ${out}"
    # A foreign named entry masked off beside a group widening, and a default block where none is declared: one
    # `setfacl --set` replaces both, and the mode re-asserts the base bits.
    mkdir -p "${RE}/d"; chmod 0750 "${RE}/d"
    if setfacl -m "g:${PROJECTS_GROUP}:r-x" -d -m "u::rwx,g::r-x,o::---" "${RE}/d" 2>/dev/null && chmod g= "${RE}/d"; then
        out="$(entry_run "$(entry "${RE}/d" directory "${me}" 0750 - ai-tools-base -)")"
        live="$(getfacl --omit-header -P -- "${RE}/d" 2>/dev/null)"
        if has_line "${out}" changed "${RE}/d" acl && [[ "${live}" != *"group:${PROJECTS_GROUP}:"* && "${live}" != *default:* ]] \
                && [[ "$(mode_of "${RE}/d")" == 750 ]]; then
            pass "a masked-off foreign entry and an undeclared default block are removed as the group bits widen"
        else
            fail "foreign entry: ${out} / $(tr '\n' '|' <<< "${live}") / $(mode_of "${RE}/d")"
        fi
    else
        skip "a foreign ACL entry" "setfacl is refused on ${RE}/d"
    fi
    out="$(entry_run "$(entry "${RE}/newdir" directory "${me}" 0750 - ai-tools-base -)")"
    has_line "${out}" changed "${RE}/newdir" type "absent	directory" && [[ -d "${RE}/newdir" && "$(mode_of "${RE}/newdir")" == 750 ]] \
        && pass "a missing directory is created under an existing parent at its mode, with a changed line" || fail "create: ${out}"
    out="$(entry_run "$(entry "${RE}/acldir" directory "${me}" 0750 "group:${PROJECTS_GROUP}:r-x" ai-tools-base -)")"
    [[ -d "${RE}/acldir" ]] && getfacl --omit-header -P -- "${RE}/acldir" 2>/dev/null | grep -q "^group:${PROJECTS_GROUP}:r-x" \
        && pass "a created directory takes the row's ACL in the same run" || fail "created ACL: ${out}"
    out="$(entry_run "$(entry "${RE}/nope/x" directory "${me}" 0750 - ai-tools-base -)")"
    has_line "${out}" refused "${RE}/nope/x" type && [[ ! -e "${RE}/nope" ]] \
        && pass "a missing directory under a missing parent is refused naming it, and no component is created" || fail "missing parent: ${out}"
    out="$(entry_run "$(entry "${RE}/nofile" file "${me}" 0644 - ai-tools-base files)")"
    has_line "${out}" refused "${RE}/nofile" type && [[ "${out}" == *"dnf reinstall"* && ! -e "${RE}/nofile" ]] \
        && pass "a missing file is refused with the package remedy" || fail "missing file: ${out}"
    ln -sfn /nonexistent "${RE}/dangle"
    out="$(entry_run "$(entry "${RE}/dangle" link "${me}" 0777 - ai-tools-base files)")"
    has_line "${out}" refused "${RE}/dangle" type && [[ "${out}" == *"target does not exist"* ]] \
        && pass "a dangling link is refused" || fail "dangling: ${out}"
    out="$(entry_run "$(entry "${RE}/d" file "${me}" 0644 - ai-tools-base files)")"
    has_line "${out}" refused "${RE}/d" type && [[ -d "${RE}/d" && "${out}" == *"move it aside"* ]] \
        && pass "an entry of another type is refused and left" || fail "type mismatch: ${out}"
    # The content gate: a package file is repaired on verified content alone. The collector is a stub function, seen
    # inside the process substitution the collector reads from; its line names the path with the fixture root stripped.
    : > "${RE}/pay"; chmod 0600 "${RE}/pay"
    STUB_FLAGS='..5......' STUB_RC=0
    rpm() { case "$1" in -q) return 0 ;; esac; printf '%s    /re/pay\n' "${STUB_FLAGS}"; return "${STUB_RC}"; }
    pay="$(entry "${RE}/pay" file "${me}" 0644 - ai-tools-base files)"
    out="$(entry_run "${pay}")"
    has_line "${out}" refused "${RE}/pay" content && [[ "${out}" == *"dnf reinstall"* && "$(mode_of "${RE}/pay")" == 600 ]] \
        && pass "drifted content refuses the entry whole: the mode is left" || fail "content drift: ${out} / $(mode_of "${RE}/pay")"
    STUB_FLAGS='..?......'
    out="$(entry_run "${pay}")"
    has_line "${out}" error "${RE}/pay" content && [[ "$(mode_of "${RE}/pay")" == 600 ]] \
        && pass "an unreadable digest is an error and the entry is left whole" || fail "unreadable digest: ${out}"
    STUB_FLAGS='.........' STUB_RC=3
    out="$(entry_run "${pay}")"
    has_line "${out}" error "${RE}/pay" content && [[ "$(mode_of "${RE}/pay")" == 600 ]] \
        && pass "a failing collector is an error and the entry is left whole" || fail "failing collector: ${out}"
    STUB_RC=0
    out="$(entry_run "${pay}" 1)"
    has_line "${out}" refused "${RE}/pay" mode "left as it is: the content is unverified" && has_line "${out}" refused "${RE}/pay" acl \
        && [[ "${out}" == *"system layout reconcile"* && "$(mode_of "${RE}/pay")" == 600 ]] \
        && pass "under a pass without rpm a drifted package file is reported per field and left, naming the full pass" || fail "without rpm: ${out}"
    out="$(entry_run "${pay}")"
    has_line "${out}" changed "${RE}/pay" mode "0600	0644" && [[ "$(mode_of "${RE}/pay")" == 644 ]] \
        && pass "verified content lets the same drift converge" || fail "verified: ${out}"
    unset -f rpm
    # A leaf swapped for a symlink between the identity read and the open: the descriptor names another inode,
    # so the write is refused and the file the link points at is left as it was. The swap is made by a stat stub
    # on the identity read alone; every other stat is the real one.
    mkdir -p "${RE}/swap"; : > "${RE}/swap/target"; : > "${RE}/swap/victim"; chmod 0600 "${RE}/swap/target" "${RE}/swap/victim"
    stub_swap_kind="" stub_swap_entry="" stub_swap_victim=""
    stat() {
        if [[ -n "${stub_swap_kind}" && "$*" == *'%d:%i'* && "$*" != *-L* ]]; then
            case "${stub_swap_kind}" in
                leaf)   command stat "$@"; local r=$?
                        mv -- "${stub_swap_entry}" "${stub_swap_entry}.aside"; ln -s "${stub_swap_victim}" "${stub_swap_entry}"
                        return "${r}" ;;
                parent) mv -- "${stub_swap_entry%/*}" "${stub_swap_entry%/*}.aside"
                        ln -s "${stub_swap_victim%/*}" "${stub_swap_entry%/*}"
                        command stat "$@"; return $? ;;
            esac
        fi
        command stat "$@"
    }
    stub_swap_kind=leaf stub_swap_entry="${RE}/swap/target" stub_swap_victim="${RE}/swap/victim"
    out="$(entry_run "$(entry "${RE}/swap/target" file "${me}" 0644 - ai-tools-base -)")"
    stub_swap_kind=""
    if has_line "${out}" error "${RE}/swap/target" identity "the entry changed during the repair" \
            && [[ "$(mode_of "${RE}/swap/victim")" == 600 && "$(mode_of "${RE}/swap/target.aside")" == 600 ]]; then
        pass "a leaf swapped for a symlink after the identity read is refused, and the file it points at is left"
    else
        fail "leaf swap: ${out} / victim $(mode_of "${RE}/swap/victim") original $(mode_of "${RE}/swap/target.aside")"
    fi
    rm -f "${RE}/swap/target"; mv -- "${RE}/swap/target.aside" "${RE}/swap/target"
    out="$(entry_run "$(entry "${RE}/swap/target" file "${me}" 0644 - ai-tools-base -)")"
    has_line "${out}" changed "${RE}/swap/target" mode "0600	0644" && pass "the same entry converges once the path is stable (control)" || fail "control: ${out}"
    mkdir -p "${RE}/pswap/dir" "${RE}/pswap/victim"; : > "${RE}/pswap/dir/target"; : > "${RE}/pswap/victim/target"
    chmod 0600 "${RE}/pswap/dir/target" "${RE}/pswap/victim/target"
    stub_swap_kind=parent stub_swap_entry="${RE}/pswap/dir/target" stub_swap_victim="${RE}/pswap/victim/target"
    out="$(entry_run "$(entry "${RE}/pswap/dir/target" file "${me}" 0644 - ai-tools-base -)")"
    stub_swap_kind=""
    if has_line "${out}" error "${RE}/pswap/dir/target" identity "the entry changed during the repair" \
            && [[ "$(mode_of "${RE}/pswap/victim/target")" == 600 ]]; then
        pass "a parent swapped for a symlink under the entry is refused by the pinned-path predicate, the outside file left"
    else
        fail "parent swap: ${out} / victim $(mode_of "${RE}/pswap/victim/target")"
    fi
    unset -f stat
    rm -f "${RE}/pswap/dir"; mv -- "${RE}/pswap/dir.aside" "${RE}/pswap/dir"
    # The ancestor rule: a row under an ancestor not at its row is refused without a read.
    mkdir -p "${RE}/anc"; : > "${RE}/anc/child"; chmod 0600 "${RE}/anc/child"
    _ai_tools_layout__reset_reconcile_state; ai_tools_layout__begin_pass 0
    _AI_TOOLS_LAYOUT__ROW_PATHS["${RE}/anc"]=row; _AI_TOOLS_LAYOUT__ANCESTOR_STATES["${RE}/anc"]=bad
    out="$(_ai_tools_layout__reconcile_entry "$(entry "${RE}/anc/child" file "${me}" 0644 - ai-tools-base -)")"
    has_line "${out}" refused "${RE}/anc/child" ancestor "not read: ${RE}/anc is not at its row" && [[ "$(mode_of "${RE}/anc/child")" == 600 ]] \
        && pass "a row under an ancestor not at its row is refused unread, naming the ancestor" || fail "ancestor rule: ${out}"
    _AI_TOOLS_LAYOUT__ANCESTOR_STATES["${RE}/anc"]=ok
    out="$(_ai_tools_layout__reconcile_entry "$(entry "${RE}/anc/child" file "${me}" 0644 - ai-tools-base -)")"
    has_line "${out}" changed "${RE}/anc/child" mode && pass "the same row converges once its ancestor is at its row" || fail "ancestor ok: ${out}"
    # A write that fails names its tool and is the outcome the reconcile folds to exit 1.
    chmod 2600 "${RE}/w" 2>/dev/null || true
    chmod() { return 7; }
    out="$(_ai_tools_layout__reset_reconcile_state; ai_tools_layout__begin_pass 0
        _ai_tools_layout__reconcile_entry "$(entry "${RE}/w" file "${me}" 0644 - ai-tools-base -)"
        printf 'failed=%s\n' "${_AI_TOOLS_LAYOUT__RECONCILE_WRITE_FAILED}")"
    unset -f chmod
    has_line "${out}" error "${RE}/w" mode "chmod exited 7" && grep -qx 'failed=1' <<< "${out}" \
        && pass "a write that returns non-zero is an error naming the tool, and the write-failed outcome" || fail "failed write: ${out}"
    chmod 0644 "${RE}/w"
    # An error line of the entry set is reported as it is.
    _ai_tools_layout__encode_line errline error file "${RE}/x" agents "the manifest is not root's"
    declare -a set_lines=( "${errline}" )
    out="$(_ai_tools_layout__reset_reconcile_state; _ai_tools_layout__reconcile_lines set_lines
        printf 'incomplete=%s\n' "${_AI_TOOLS_LAYOUT__RECONCILE_INCOMPLETE}")"
    has_line "${out}" error "${RE}/x" agents "the manifest is not root's" && grep -qx 'incomplete=1' <<< "${out}" \
        && pass "an error line of the entry set is an error of the reconcile, counted as incomplete" || fail "set error: ${out}"
    if (( EUID != 0 )); then
        rc=0; ai_tools_layout__reconcile 0 >/dev/null 2>&1 || rc=$?
        (( rc == 2 )) && pass "a non-root caller is refused with status 2" || fail "non-root reconcile: ${rc}"
    fi
fi

section "layout: the reconcile as root"
if (( EUID != 0 )); then
    skip "the reconcile as root" "runs unprivileged; sudo bash tests/unit/layout.sh runs the root half"
elif ! getent passwd "${SANDBOX_USER}" >/dev/null 2>&1 || ! getent group ai-ops >/dev/null 2>&1 \
        || ! getent passwd nobody >/dev/null 2>&1; then
    skip "the reconcile as root" "the sandbox account, ai-ops or nobody is not on this host"
elif ! declare -F ai_tools_safe_paths__is_pinned_fd_at_path >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
    skip "the reconcile as root" "safe-paths.lib.sh or flock is not available"
else
    R="${FIXTURE_ROOT}"
    # The tree is built from the table itself: the sentinels of every package first, then each row the entry set yields
    # at its owner, mode and ACL, ghost rows left absent. The manifests the agents directory holds are the shipped
    # names, so their config directories become dynamic rows.
    for sentinel in /usr/local/libexec/ai-tools/ai-tools-admin /usr/local/libexec/ai-tools/ai-tools-bootstrap \
            /usr/local/lib/ai-tools/launch.d/claude-code.sh /usr/local/lib/ai-tools/session-env.d/codex.pins.env.sh \
            /usr/local/lib/ai-tools/integrations.d/dotnet.conf /usr/local/lib/ai-tools/integrations.d/typesafe.conf \
            /usr/share/selinux/devel/include/distributed/ai_tools.if; do
        mkdir -p "${R}${sentinel%/*}"; : > "${R}${sentinel}"
    done
    printf 'config_dir=.claude\nlauncher=claude\n' > "${AGENTS_DIR}/claude-code.conf"
    printf 'config_dir=.codex\nlauncher=codex\n' > "${AGENTS_DIR}/codex.conf"
    chown -R root:root "${AGENTS_DIR}" "${OPERATOR_CONF}"; chmod 0755 "${AGENTS_DIR}"; chmod 0644 "${AGENTS_DIR}"/*.conf "${OPERATOR_CONF}"
    declare -a built_lines=(); declare -a row_fields=()
    PAYLOAD_LIST="${TESTDIR}/payload-paths"; : > "${PAYLOAD_LIST}"
    build_entry() {
        local path="$1" type="$2" owner="$3" mode="$4" acl="$5" flags="$6" acl_entry
        local -a acl_entries=()
        [[ ",${flags}," == *,ghost,* ]] && return 0
        mkdir -p "${path%/*}"
        case "${type}" in
            directory) install -d -o "${owner%%:*}" -g "${owner#*:}" -m "${mode}" -- "${path}"
                       ai_tools_control_plane__apply_mode "${mode}" "${path}" ;;
            file)      [[ -e "${path}" ]] || install -o root -g root -m 0644 /dev/null "${path}"
                       chown "${owner}" "${path}"; ai_tools_control_plane__apply_mode "${mode}" "${path}" ;;
            link)      ln -sfn /dev/null "${path}"; chown --no-dereference "${owner}" "${path}" ;;
        esac
        if [[ "${acl}" != - ]]; then
            IFS=, read -ra acl_entries <<< "${acl}"
            for acl_entry in "${acl_entries[@]}"; do setfacl -m "${acl_entry}" "${path}"; done
        fi
        _ai_tools_layout__is_payload_file "${type}" "${flags}" && printf '%s\n' "${path#"${R}"}" >> "${PAYLOAD_LIST}"
        return 0
    }
    ai_tools_layout__read_entry_lines built_lines || :
    build_errors=0
    for line in "${built_lines[@]}"; do
        if [[ "${line}" == error$'\t'* ]]; then build_errors=$(( build_errors + 1 )); continue; fi
        ai_tools_layout__parse_line "${line}" row_fields
        build_entry "${row_fields[0]}" "${row_fields[1]}" "${row_fields[2]}" "${row_fields[3]}" "${row_fields[4]}" "${row_fields[6]}"
    done
    (( build_errors == 0 )) && pass "the tree is built from the entry set with no error line (${#built_lines[@]} rows)" \
        || fail "the entry set carried ${build_errors} error line(s) while building: $(grep '^error' <<< "$(printf '%s\n' "${built_lines[@]}")" | tr '\n\t' '| ')"
    [[ -d "${R}/opt/ai-tools/.claude" && -d "${R}${PROJECTS_HOME}/.config/ai-tools" ]] \
        && pass "the dynamic rows are in the tree: an agent config directory and an operator's config" || fail "dynamic rows not built"
    # The collector stub prints every payload path verified, with per-path overrides and an exit status the case sets;
    # as rpm does, it exits 1 once a line carries a difference or reads `missing`, and 0 otherwise.
    declare -A STUB_OVERRIDE=(); STUB_RC=0
    rpm() {
        local p flags status=0
        case "$1" in -q) return 0 ;; esac
        while IFS= read -r p; do
            flags="${STUB_OVERRIDE[${p}]:-.........}"
            printf '%s    %s\n' "${flags}" "${p}"
            [[ "${flags}" == missing || "${flags}" == *[^.]* ]] && status=1
        done < "${PAYLOAD_LIST}"
        (( STUB_RC != 0 )) && return "${STUB_RC}"
        return "${status}"
    }
    # reconcile_run [<without-rpm>] : the reconcile over the fixture root; prints its lines, then `rc=<status>`.
    reconcile_run() { local rc=0; ai_tools_layout__reconcile "${1:-0}" || rc=$?; printf 'rc=%s\n' "${rc}"; }
    rc_of() { grep -o '^rc=.*' <<< "$1" | tail -n1; }
    # brief <output> : a run's output for a failure line -- its first three lines, the count of the rest, and its last
    # line (the `rc=`), tabs and newlines as `| `, so a run over the whole tree does not report every row.
    brief() {
        local -a brief_lines=()
        local brief_text
        mapfile -t brief_lines <<< "$1"
        brief_text="$(printf '%s\n' "${brief_lines[@]:0:3}" | tr '\n\t' '| ')"
        (( ${#brief_lines[@]} > 4 )) && brief_text+="(+$(( ${#brief_lines[@]} - 4 )) more lines) "
        (( ${#brief_lines[@]} > 3 )) && brief_text+="${brief_lines[-1]}"
        printf '%s' "${brief_text}"
    }
    out="$(reconcile_run)"
    [[ "$(rc_of "${out}")" == rc=0 && "$(grep -vc '^rc=' <<< "${out}")" -eq 0 ]] \
        && pass "a converged tree prints no line and exits 0" || fail "first run over the built tree: $(brief "${out}")"
    out="$(reconcile_run)"
    [[ "$(rc_of "${out}")" == rc=0 && "$(grep -vc '^rc=' <<< "${out}")" -eq 0 ]] \
        && pass "a second run prints no line and exits 0" || fail "second run: $(brief "${out}")"
    LOG="${AI_TOOLS_LOG_DIR}/layout.log"
    OC="${OPERATOR_CONF}"
    chown nobody:nobody "${OC}"
    out="$(reconcile_run)"
    has_line "${out}" changed "${OC}" owner "nobody:nobody	root:root" && [[ "$(stat -c '%U:%G' "${OC}")" == root:root && "$(rc_of "${out}")" == rc=0 ]] \
        && pass "an owner drift converges with its changed line" || fail "owner drift: $(brief "${out}")"
    grep -q "INFO.*${OC} owner nobody:nobody -> root:root" "${LOG}" && pass "an owner moving to root is logged at info" || fail "owner log line: $(grep "${OC} owner" "${LOG}" | tail -n1)"
    chmod 0600 "${OC}"
    out="$(reconcile_run)"
    has_line "${out}" changed "${OC}" mode "0600	0644" && [[ "$(stat -c '%a' "${OC}")" == 644 ]] \
        && pass "a mode drift on operator.conf converges" || fail "mode drift: $(brief "${out}")"
    grep -q "NOTICE.*${OC} mode 0600 -> 0644" "${LOG}" && pass "the widening is logged at notice" || fail "mode log line: $(grep "${OC} mode" "${LOG}" | tail -n1)"
    STATE="${R}/var/opt/ai-tools/state"
    setfacl -m "g:nobody:r-x" -d -m "g:ai-ops:r-x" "${STATE}"
    out="$(reconcile_run)"
    live="$(getfacl --omit-header -P -- "${STATE}")"
    has_line "${out}" changed "${STATE}" acl && [[ "${live}" != *"group:nobody"* && "${live}" != *default:* && "${live}" == *"group:ai-ops:r-x"* ]] \
        && pass "a foreign entry and an undeclared default block are removed, the declared entry kept" || fail "acl drift: $(brief "${out}") / $(tr '\n' '|' <<< "${live}")"
    SP="${R}/var/opt/ai-tools/sandbox-projects"
    setfacl -m "g:nobody:rwx" "${SP}"; chmod g= "${SP}"
    activated="${TESTDIR}/activated"; rm -f "${activated}"
    ( while [[ ! -e "${TESTDIR}/stop-watch" ]]; do
          if getfacl -e --omit-header -P -- "${SP}" 2>/dev/null | grep "^group:nobody:rwx" | grep -qv '#effective:---'; then : > "${activated}"; fi
      done ) &
    watcher=$!
    out="$(reconcile_run)"
    : > "${TESTDIR}/stop-watch"; wait "${watcher}" 2>/dev/null || true; rm -f "${TESTDIR}/stop-watch"
    live="$(getfacl --omit-header -P -- "${SP}")"
    [[ "${live}" != *"group:nobody"* && "$(stat -c '%a' "${SP}")" == 2770 && ! -e "${activated}" ]] \
        && pass "a masked-off foreign entry is removed as the group bits widen, with no state in which it was effective" \
        || fail "masked entry: $(tr '\n' '|' <<< "${live}") mode $(stat -c '%a' "${SP}") activated=$([[ -e "${activated}" ]] && echo yes || echo no)"
    LINK="${R}/usr/sbin/ai-tools"
    chown --no-dereference nobody:nobody "${LINK}"
    out="$(reconcile_run)"
    has_line "${out}" changed "${LINK}" owner "nobody:nobody	root:root" && [[ "$(stat -c '%U' "${LINK}")" == root ]] \
        && pass "a link's owner converges by name" || fail "link owner: $(brief "${out}")"
    # Content drift beside owner, mode and ACL drift leaves every field, under each state the content gate refuses.
    CLI="${R}/usr/local/bin/ai-tools"
    chown nobody:nobody "${CLI}"; chmod 0600 "${CLI}"
    STUB_OVERRIDE[/usr/local/bin/ai-tools]='..5......'
    out="$(reconcile_run)"
    has_line "${out}" refused "${CLI}" content && [[ "$(stat -c '%U %a' "${CLI}")" == "nobody 600" && "$(rc_of "${out}")" == rc=4 ]] \
        && pass "drifted content refuses the entry whole at exit 4: owner and mode are left" || fail "content drift: $(brief "${out}") / $(stat -c '%U %a' "${CLI}")"
    STUB_OVERRIDE[/usr/local/bin/ai-tools]='..?......'
    out="$(reconcile_run)"
    has_line "${out}" error "${CLI}" content && [[ "$(stat -c '%U %a' "${CLI}")" == "nobody 600" && "$(rc_of "${out}")" == rc=5 ]] \
        && pass "an unreadable digest is an error at exit 5, the entry left whole" || fail "unreadable digest: $(brief "${out}")"
    unset 'STUB_OVERRIDE[/usr/local/bin/ai-tools]'; STUB_RC=3
    out="$(reconcile_run)"
    has_line "${out}" error "${CLI}" content && [[ "$(stat -c '%U %a' "${CLI}")" == "nobody 600" ]] \
        && pass "a failing collector leaves every package file whole" || fail "failing collector: $(brief "${out}")"
    STUB_RC=0
    out="$(reconcile_run 1)"
    has_line "${out}" refused "${CLI}" owner "left as it is: the content is unverified" && [[ "$(stat -c '%U %a' "${CLI}")" == "nobody 600" && "$(rc_of "${out}")" == rc=4 ]] \
        && pass "a pass without rpm reports the drifted package file per field and leaves it" || fail "without rpm: $(brief "${out}")"
    out="$(reconcile_run)"
    [[ "$(stat -c '%U %a' "${CLI}")" == "root 755" && "$(rc_of "${out}")" == rc=0 ]] \
        && pass "with the content verified the same drift converges" || fail "verified: $(brief "${out}")"
    # Missing entries: a directory is created, a file and a dangling link are refused with their remedies.
    PIN="${STATE}/entrypoint-pin.d"; rm -r "${PIN}"
    out="$(reconcile_run)"
    has_line "${out}" changed "${PIN}" type "absent	directory" && [[ "$(stat -c '%U:%G %a' "${PIN}")" == "root:root 755" ]] \
        && pass "a missing directory is created at its row" || fail "create: $(brief "${out}")"
    LAUNCH="${R}/usr/local/bin/ai-tools-launch"; rm "${LAUNCH}"
    out="$(reconcile_run)"
    has_line "${out}" refused "${LAUNCH}" type && [[ "${out}" == *"dnf reinstall ai-tools-base"* && ! -e "${LAUNCH}" && "$(rc_of "${out}")" == rc=4 ]] \
        && pass "a missing file is refused naming the package, at exit 4" || fail "missing file: $(brief "${out}")"
    install -o root -g root -m 0755 /dev/null "${LAUNCH}"
    ln -sfn "${R}/nonexistent" "${LINK}"
    out="$(reconcile_run)"
    has_line "${out}" refused "${LINK}" type && [[ "${out}" == *"target does not exist"* ]] \
        && pass "a dangling link is refused" || fail "dangling: $(brief "${out}")"
    ln -sfn /dev/null "${LINK}"
    # Type mismatch, both ways, and the rows under a replaced directory refused unread.
    KEYS="${R}/usr/local/lib/ai-tools/keys"; ASC="${KEYS}/dag-node-package-signing.asc"
    rm "${ASC}"; mkdir "${ASC}"
    out="$(reconcile_run)"
    has_line "${out}" refused "${ASC}" type && [[ -d "${ASC}" ]] && pass "a directory where a file belongs is refused and left" || fail "dir for file: $(brief "${out}")"
    rmdir "${ASC}"; install -o root -g root -m 0644 /dev/null "${ASC}"
    mv "${KEYS}" "${KEYS}.aside"; : > "${KEYS}"
    out="$(reconcile_run)"
    has_line "${out}" refused "${KEYS}" type && has_line "${out}" refused "${ASC}" ancestor "not read: ${KEYS} is not at its row" \
        && pass "a file where a directory belongs is refused, and the rows under it refused unread naming it" || fail "file for dir: $(brief "${out}")"
    rm "${KEYS}"; mv "${KEYS}.aside" "${KEYS}"
    ELSEWHERE="${TESTDIR}/elsewhere"; mkdir -p "${ELSEWHERE}"
    mv "${STATE}" "${STATE}.aside"; ln -s "${ELSEWHERE}" "${STATE}"
    out="$(reconcile_run)"
    has_line "${out}" refused "${STATE}" type && has_line "${out}" refused "${PIN}" ancestor && [[ ! -e "${ELSEWHERE}/entrypoint-pin.d" ]] \
        && pass "a symlink at a directory row refuses the rows under it, with no directory created at the target" \
        || fail "symlink at a directory row: $(brief "${out}") / $(ls -A "${ELSEWHERE}" | tr '\n' ' ')"
    rm "${STATE}"; mv "${STATE}.aside" "${STATE}"
    PKGS="${R}/usr/share/selinux/packages"; rm -r "${PKGS}"
    out="$(reconcile_run)"
    has_line "${out}" refused "${PKGS}/ai-tools" type && [[ "${out}" == *"${PKGS} is not a directory"* && ! -e "${PKGS}" ]] \
        && pass "a missing directory under a missing parent outside the table is refused, and no component is created" \
        || fail "missing parent: $(brief "${out}")"
    install -d -o root -g root -m 0755 "${PKGS}" "${PKGS}/ai-tools"
    # A discovery input the enumeration refuses, and the drift in the dynamic rows it hides, converge in one run.
    ACME="${R}/opt/ai-tools/.acme"
    chmod 0777 "${AGENTS_DIR}"; chmod 0700 "${ACME}"
    out="$(reconcile_run)"
    has_line "${out}" changed "${AGENTS_DIR}" mode && has_line "${out}" changed "${ACME}" mode \
        && [[ "$(stat -c '%a' "${AGENTS_DIR}")" == 755 && "$(stat -c '%a' "${ACME}")" == 3770 && "$(rc_of "${out}")" == rc=0 ]] \
        && pass "an untrusted agents directory and the drift in an agent config directory converge in one invocation" \
        || fail "agents.d then .acme: $(brief "${out}")"
    OPDIR="${R}${PROJECTS_HOME}/.config/ai-tools"
    chmod 0666 "${OC}"; chmod 0755 "${OPDIR}"
    out="$(reconcile_run)"
    has_line "${out}" changed "${OC}" mode && has_line "${out}" changed "${OPDIR}" mode \
        && [[ "$(stat -c '%a' "${OC}")" == 644 && "$(stat -c '%a' "${OPDIR}")" == 700 && "$(rc_of "${out}")" == rc=0 ]] \
        && pass "an untrusted operator.conf and the drift in an operator's config directory converge in one invocation" \
        || fail "operator.conf then the operator directory: $(brief "${out}")"
    # An input the enumeration cannot use stays visible, at exit 5, run after run.
    BAD="${AGENTS_DIR}/bad.conf"; printf 'config_dir=../x\n' > "${BAD}"; chmod 0644 "${BAD}"
    out="$(reconcile_run)"
    has_line "${out}" error "${BAD}" agents && [[ "$(rc_of "${out}")" == rc=5 ]] \
        && pass "an invalid manifest is an error at exit 5" || fail "invalid manifest: $(brief "${out}")"
    out="$(reconcile_run)"
    has_line "${out}" error "${BAD}" agents && [[ "$(rc_of "${out}")" == rc=5 ]] \
        && pass "and stays visible on the next run" || fail "invalid manifest, second run: $(brief "${out}")"
    rm "${BAD}"
    printf 'OPERATORS="%s,no-such-user-zz"\n' "${PROJECTS_USER}" > "${OC}"
    out="$(reconcile_run)"
    has_line "${out}" error no-such-user-zz operators && [[ "$(rc_of "${out}")" == rc=5 ]] \
        && pass "an account that does not resolve is an error at exit 5, the other operator's rows unaffected" || fail "unresolved account: $(brief "${out}")"
    printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${OC}"
    # The lock held by another process: an error, exit 5, and no write.
    chmod 0600 "${OC}"
    flock -x "${AI_TOOLS_LAYOUT_LOCK}" sleep 4 &
    locker=$!
    sleep 0.5
    out="$(reconcile_run)"
    has_line "${out}" error "${AI_TOOLS_LAYOUT_LOCK}" lock && [[ "$(rc_of "${out}")" == rc=5 && "$(stat -c '%a' "${OC}")" == 600 ]] \
        && pass "a lock another process holds is an error at exit 5 with no write" || fail "held lock: $(brief "${out}") / $(stat -c '%a' "${OC}")"
    wait "${locker}" 2>/dev/null || true
    # The exit order: a failed write outranks an incomplete observation, which outranks a refusal.
    printf 'config_dir=../x\n' > "${BAD}"; chmod 0644 "${BAD}"; rm "${LAUNCH}"
    chmod() { return 1; }
    out="$(reconcile_run)"
    unset -f chmod
    [[ "$(rc_of "${out}")" == rc=1 ]] && has_line "${out}" error "${OC}" mode "chmod exited 1" \
        && pass "a failed write beside an error and a refusal exits 1" || fail "exit order 1: $(brief "${out}")"
    out="$(reconcile_run)"
    [[ "$(rc_of "${out}")" == rc=5 ]] && pass "an error beside a refusal exits 5" || fail "exit order 5: $(brief "${out}")"
    rm "${BAD}"
    out="$(reconcile_run)"
    [[ "$(rc_of "${out}")" == rc=4 ]] && has_line "${out}" refused "${LAUNCH}" type && pass "a refusal alone exits 4" || fail "exit order 4: $(brief "${out}")"
    install -o root -g root -m 0755 /dev/null "${LAUNCH}"
    out="$(reconcile_run)"
    [[ "$(rc_of "${out}")" == rc=0 && "$(grep -vc '^rc=' <<< "${out}")" -eq 0 ]] && pass "the tree converges again and exits 0" || fail "final: $(brief "${out}")"
    # The union pass reads the entry set as a collector: an enumerator that exits 9 is an error line and exit 5.
    out="$(ai_tools_layout__list_entries() { return 9; }; reconcile_run)"
    has_line "${out}" error layout.lib.sh entries "the entry set exited 9" && [[ "$(rc_of "${out}")" == rc=5 ]] \
        && pass "a lost entry set in the reconcile is an error at exit 5" || fail "lost set in the reconcile: $(brief "${out}")"
    unset -f rpm
    if command -v runuser >/dev/null 2>&1; then
        chmod 0755 "${TESTDIR}"
        rc=0; err=""
        # shellcheck disable=SC2016  # the inner bash expands these
        err="$(runuser -u "${PROJECTS_USER}" -- env AI_TOOLS_LAYOUT_ROOT="${R}" AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" \
            AI_TOOLS_OPERATOR_CONF="${OC}" AI_TOOLS_LAYOUT_LOCK="${AI_TOOLS_LAYOUT_LOCK}" \
            bash -c 'source "$1" || exit 3; ai_tools_layout__reconcile 0' _ "${TESTDIR}/lib/layout.lib.sh" 2>&1 >/dev/null)" || rc=$?
        (( rc == 2 )) && pass "a non-root caller is refused with status 2" || fail "non-root reconcile: ${rc} ${err}"
    else
        skip "a non-root caller" "runuser unavailable"
    fi
    skip "a label drift converging" "every fixture is under /tmp, where the policy declares no label expectation; the label field is driven on a packaged host"
fi

section "layout: the command's option grammar"
# The admin helper is sourced rather than run (it stops before its dispatch), each case in a fresh shell since
# the helper and the harness both declare SANDBOX_USER readonly, so the grammar is driven without root and without
# an installed library: every refusal here is answered before the library loads.
ADMIN="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
# admin_layout <argument>... : dispatch `system layout` with the arguments in a fresh shell; prints both streams
# and `rc=<status>` last.
admin_layout() {
    local rc=0 out
    # shellcheck disable=SC2016  # the inner bash expands these
    out="$(bash -c 'source "$1" >/dev/null 2>&1 || exit 3; shift; system_layout_dispatch "$@"' _ "${ADMIN}" "$@" 2>&1)" || rc=$?
    printf '%s\nrc=%s\n' "${out}" "${rc}"
}
# refused_option <desc> <argument>... : the dispatch rejects the command line under the option code, exit 2.
refused_option() {
    local desc="$1" out; shift
    out="$(admin_layout "$@")"
    if grep -qx 'MSG-R7Y4' <<< "${out}" && grep -qx 'rc=2' <<< "${out}"; then pass "${desc}"
    else fail "${desc}: $(tr '\n' '|' <<< "${out}")"; fi
}
refused_option "--all without --check is refused"          --all
refused_option "--format without --check is refused"       --format tsv
refused_option "a format other than tsv is refused"        --check --format json
refused_option "--format without a value is refused"       --check --format
refused_option "--check on reconcile is refused"           reconcile --check
refused_option "--without-rpm on list is refused"          list --without-rpm
refused_option "an unknown verb is refused"                bogus
refused_option "an unknown option is refused"              --bogus
# The list is the zero-argument default: a bare `system layout` and an option-only one reach it with their arguments,
# under the helper's own `set -e` (a `shift` with no word to shift ends the command without a line).
# shellcheck disable=SC2016  # the inner bash expands these
list_reach="$(bash -c 'source "$1" >/dev/null 2>&1 || exit 3
    layout_list() { printf "list:%s\n" "$*"; }
    system_layout_dispatch; system_layout_dispatch list; system_layout_dispatch --check --all' _ "${ADMIN}" 2>&1)" \
    && list_rc=0 || list_rc=$?
[[ "${list_rc}" == 0 && "${list_reach}" == $'list:\nlist:\nlist:--check --all' ]] \
    && pass "a bare system layout, list and an option-only command line each reach the list with their arguments" \
    || fail "list default: rc ${list_rc}: $(tr '\n' '|' <<< "${list_reach}")"
if [[ -e /usr/local/lib/ai-tools/layout.lib.sh ]]; then
    skip "the library-load refusal" "the library is installed on this host, so the load does not fail"
else
    out="$(admin_layout --check)"
    grep -qx 'MSG-C6D2' <<< "${out}" && grep -qx 'rc=1' <<< "${out}" \
        && pass "a host without the library is refused under the load code, naming the recovery" \
        || fail "library-load refusal: $(tr '\n' '|' <<< "${out}")"
fi

section "layout: the boundary pair"
# Every boundary row names the gate that refuses its reader and the two test files that drive the pair: the runtime file
# drives the gate (on the deployed path, or on a fixture the literal names) and the boundary file probes the path
# as the sandbox account. A file cited here holds the literal, so the map and the files stay in lockstep; a row without
# a runtime file is a gap the planner's table holds, recorded as a note.
declare -A boundary_map=(
    [/usr/local/lib/ai-tools/keys/dag-node-package-signing.asc]="mode|0644 root:root|unit/assets-verify.sh:dag-node-package-signing|boundary/assets.sh:dag-node-package-signing.asc"
    [/usr/local/lib/ai-tools/keys/dag-node-package-signing.gpg]="predicate|ai_tools_assets_verify__read_binding|unit/assets-verify.sh:read_binding|boundary/assets.sh:dag-node-package-signing.gpg"
    [/usr/local/lib/ai-tools/assets-bindings.d/core.conf]="predicate|ai_tools_assets_verify__read_binding|unit/assets-verify.sh:assets-bindings.d|boundary/assets.sh:assets-bindings.d"
    [/usr/local/lib/ai-tools/assets-bindings.d/ai-tools.conf]="predicate|ai_tools_assets_verify__read_binding|unit/assets-verify.sh:assets-bindings.d|boundary/assets.sh:assets-bindings.d"
    [/usr/local/lib/ai-tools/agents.d]="predicate|_ai_tools_providers__is_dir_trusted|unit/providers.sh:agents.d|boundary/providers.sh:/usr/local/lib/ai-tools/agents.d"
    [/usr/local/lib/ai-tools/integrations.d]="predicate|_ai_tools_providers__is_dir_trusted|unit/providers.sh:integrations.d|boundary/providers.sh:/usr/local/lib/ai-tools/integrations.d"
    [/usr/local/lib/ai-tools/session-env.d]="predicate|ai_tools_conf__is_trusted|integration/ai-tools-run.sh:session-env.d|boundary/providers.sh:/usr/local/lib/ai-tools/session-env.d"
    [/usr/local/lib/ai-tools/launch.d]="predicate|ai_tools_launch_wrapper__append_agent_args|unit/launch-wrapper.sh:launch.d|boundary/providers.sh:/usr/local/lib/ai-tools/launch.d"
    [/usr/local/lib/ai-tools/admin-commands.d]="predicate|admin_commands_trusted|unit/admin-commands.sh:admin-commands.d|boundary/providers.sh:/usr/local/lib/ai-tools/admin-commands.d"
    [/usr/local/lib/ai-tools/filters.d]="predicate|ai_tools_filters__load_rules|unit/filters.sh:filters.d|boundary/filters.sh:/usr/local/lib/ai-tools/filters.d"
    [/usr/local/lib/ai-tools/filters.d/base.rules]="predicate|_ai_tools_filters__load_file|unit/filters.sh:base.rules|boundary/filters.sh:base.rules"
    [/opt/ai-tools/bin/ai-tools-run]="mode|0550 root:ai-tools|integration/ai-tools-run.sh:/opt/ai-tools/bin/ai-tools-run|boundary/providers.sh:/opt/ai-tools/bin/ai-tools-run"
    [/etc/sudoers.d/ai-tools]="program|visudo|integration/perms.sh:/etc/sudoers.d/ai-tools|boundary/sudo.sh:/etc/sudoers.d/ai-tools"
    [/etc/ai-tools/operator.conf]="predicate|ai_tools_conf__is_trusted|unit/providers.sh:operator.conf|boundary/providers.sh:/etc/ai-tools/operator.conf"
    [/etc/ai-tools/assets-bindings.d]="predicate|ai_tools_assets_verify__read_binding|unit/assets-verify.sh:etc-bindings.d|boundary/assets.sh:/etc/ai-tools/assets-bindings.d"
    [/var/opt/ai-tools/state/entrypoint-pin.d]="mode|0755 root:root; the pin writer refuses a non-root caller|unit/entrypoint-verify.sh:entrypoint-pin.d|boundary/access.sh:entrypoint-pin.d"
    [/var/opt/ai-tools/state/entrypoint-label.d]="mode|0755 root:root|unit/entrypoint-verify.sh:entrypoint-label.d|boundary/access.sh:entrypoint-label.d"
    [/var/opt/ai-tools/state/entrypoint-stale.d]="mode|0755 root:root|unit/entrypoint-verify.sh:entrypoint-stale.d|boundary/access.sh:entrypoint-stale.d"
    [/opt/ai-tools/bin/nvm-update.sh]="mode|0550 root:ai-tools|unit/toolchain.sh:nvm-update.sh|boundary/access.sh:nvm-update.sh"
    [/usr/local/lib/ai-tools/agents.d/claude-code.conf]="predicate|ai_tools_conf__is_trusted in the resolver|unit/providers.sh:claude-code.conf|boundary/providers.sh:claude-code.conf"
    [/usr/local/lib/ai-tools/keys/claude-code.asc]="predicate|the declared fingerprint in entrypoint-verify.lib.sh|-|boundary/access.sh:claude-code.asc"
    [/usr/local/lib/ai-tools/session-env.d/claude-code.pins.env.sh]="predicate|source_session_env_fragment|integration/ai-tools-run.sh:claude-code.pins.env.sh|boundary/providers.sh:claude-code.pins.env.sh"
    [/usr/local/lib/ai-tools/session-env.d/claude-code.env.sh]="predicate|source_session_env_fragment|integration/ai-tools-run.sh:claude-code.env.sh|boundary/providers.sh:claude-code.env.sh"
    [/usr/local/lib/ai-tools/claude-prompt.lib.sh]="loader|launch.d/claude-code.sh, fail closed with a prompt configured|unit/claude-prompt.sh:claude-prompt.lib.sh|boundary/access.sh:claude-prompt.lib.sh"
    [/usr/local/lib/ai-tools/claude-endpoint.lib.sh]="loader|session-env.d/claude-code.env.sh|unit/claude-endpoint.sh:claude-endpoint.lib.sh|boundary/access.sh:claude-endpoint.lib.sh"
    [/usr/local/lib/ai-tools/launch.d/claude-code.sh]="predicate|ai_tools_launch_wrapper__append_agent_args|unit/launch-wrapper.sh:acme.sh|boundary/providers.sh:launch.d/claude-code.sh"
    [/opt/ai-tools/.claude/post-tool-hook.sh]="mode|0750 root:ai-tools in a setgid+sticky directory|integration/hooks.sh:post-tool-hook.sh|boundary/access.sh:post-tool-hook.sh"
    [/opt/ai-tools/.claude/session-hook.sh]="mode|0750 root:ai-tools in a setgid+sticky directory|integration/hooks.sh:session-hook.sh|boundary/access.sh:session-hook.sh"
    [/opt/ai-tools/.claude/filter-hook.sh]="mode|0750 root:ai-tools in a setgid+sticky directory|integration/hooks.sh:filter-hook.sh|boundary/filters.sh:filter-hook.sh"
    [/opt/ai-tools/.claude/settings.json]="mode|0640 root:ai-tools|integration/hooks.sh:settings.json|boundary/access.sh:settings.json"
    [/opt/ai-tools/.codex/post-tool-hook.sh]="mode|0750 root:ai-tools|integration/hooks.sh:post-tool-hook.sh|boundary/access.sh:.codex"
    [/opt/ai-tools/.codex/session-hook.sh]="mode|0750 root:ai-tools|integration/hooks.sh:session-hook.sh|boundary/access.sh:.codex"
    [/usr/local/lib/ai-tools/agents.d/codex.conf]="predicate|ai_tools_conf__is_trusted in the resolver|unit/codex-package.sh:codex.conf|boundary/providers.sh:codex.conf"
    [/usr/local/lib/ai-tools/session-env.d/codex.pins.env.sh]="predicate|source_session_env_fragment|unit/codex-package.sh:codex.pins.env.sh|boundary/providers.sh:codex.pins.env.sh"
    [/usr/local/lib/ai-tools/session-env.d/dotnet.env.sh]="predicate|source_session_env_fragment|-|boundary/providers.sh:dotnet.env.sh"
    [/usr/local/lib/ai-tools/integrations.d/dotnet.conf]="predicate|ai_tools_conf__is_trusted in the resolver|unit/providers.sh:dotnet.conf|boundary/providers.sh:dotnet.conf"
    [/usr/local/lib/ai-tools/filters.d/dotnet.rules]="predicate|_ai_tools_filters__load_file|unit/filters.sh:dotnet.rules|boundary/filters.sh:dotnet.rules"
    [/usr/local/lib/ai-tools/admin-commands.d/dotnet]="predicate|admin_commands_trusted|-|boundary/providers.sh:admin-commands.d/dotnet"
    [/usr/local/lib/ai-tools/session-env.d/typesafe.env.sh]="predicate|source_session_env_fragment|unit/typesafe.sh:typesafe.env.sh|boundary/providers.sh:typesafe.env.sh"
    [/usr/local/lib/ai-tools/integrations.d/typesafe.conf]="predicate|ai_tools_conf__is_trusted in the resolver|unit/typesafe.sh:typesafe.conf|boundary/providers.sh:typesafe.conf"
    [HOME/.config/ai-tools]="mode|0700 operator|unit/launch-wrapper.sh:.config/ai-tools|boundary/access.sh:.config/ai-tools"
    [HOME/.config/ai-tools/allowed-projects]="mode|0600 operator; the gate refuses a missing or unreadable file|unit/launch-wrapper.sh:allowed-projects|boundary/access.sh:allowed-projects"
    [HOME/.config/ai-tools/secret-patterns]="mode|0600 operator; the loader refuses an unreadable file (MSG-S4T9)|unit/secret-patterns.sh:secret-patterns|boundary/access.sh:.config/ai-tools"
)
# cites <file:literal> : the named test file holds the literal; `-` is a recorded gap.
cites() {
    local file="${1%%:*}" literal="${1#*:}"
    [[ "$1" == - ]] && return 0
    [[ -r "${TEST_TREE}/${file}" ]] && grep -qF -- "${literal}" "${TEST_TREE}/${file}"
}
declare -A boundary_seen=()
map_problems=0
for entry in "${_AI_TOOLS_LAYOUT__STATIC_ENTRIES[@]}"; do
    IFS=$'\t' read -r r_path r_type r_owner r_mode r_acl r_packages r_flags <<< "${entry}"
    [[ ",${r_flags}," == *,boundary,* ]] || continue
    boundary_seen["${r_path}"]=1
    if [[ -z "${boundary_map[${r_path}]+x}" ]]; then fail "boundary pair: ${r_path} is a boundary row with no map entry"; map_problems=$(( map_problems + 1 )); continue; fi
    IFS='|' read -r kind gate runtime boundary <<< "${boundary_map[${r_path}]}"
    case "${kind}" in predicate|loader|program|mode) ;; *) fail "boundary pair: ${r_path}: kind ${kind} is not one of the four"; map_problems=$(( map_problems + 1 )); continue ;; esac
    [[ -n "${gate}" ]] || { fail "boundary pair: ${r_path} names no gate"; map_problems=$(( map_problems + 1 )); continue; }
    cites "${runtime}" || { fail "boundary pair: ${r_path}: ${runtime%%:*} does not hold '${runtime#*:}'"; map_problems=$(( map_problems + 1 )); continue; }
    cites "${boundary}" || { fail "boundary pair: ${r_path}: ${boundary%%:*} does not hold '${boundary#*:}'"; map_problems=$(( map_problems + 1 )); continue; }
    [[ "${boundary}" != - ]] || { fail "boundary pair: ${r_path} has no boundary file"; map_problems=$(( map_problems + 1 )); continue; }
    [[ "${runtime}" != - ]] || note "boundary pair: ${r_path} has no runtime file driving its gate (${gate})" "a gap the planner's table holds"
done
# The dynamic operator rows, keyed by their path under the operator's home.
for r_path in HOME/.config/ai-tools HOME/.config/ai-tools/allowed-projects HOME/.config/ai-tools/secret-patterns; do
    boundary_seen["${r_path}"]=1
    IFS='|' read -r kind gate runtime boundary <<< "${boundary_map[${r_path}]}"
    cites "${runtime}" && cites "${boundary}" || { fail "boundary pair: ${r_path}: a cited file does not hold its literal"; map_problems=$(( map_problems + 1 )); }
done
for r_path in "${!boundary_map[@]}"; do
    [[ -n "${boundary_seen[${r_path}]+x}" ]] || { fail "boundary pair: the map names ${r_path}, which no boundary row carries"; map_problems=$(( map_problems + 1 )); }
done
(( map_problems == 0 )) && pass "every boundary row names its gate and the two test files that drive the pair, each holding the cited literal (${#boundary_seen[@]} rows)"

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

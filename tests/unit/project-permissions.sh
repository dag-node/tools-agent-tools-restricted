#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/project-permissions.sh
# Unit test for project-permissions.lib.sh: the ACL specification a claim grants, which ai-tools-setfacl applies,
# and the per-path checks the claim collects its drift and verifies its repairs with. What it pins, in order:
#   * the specification: the literal `ai-tools-setfacl` applies, `user:<operator>:rwX,group:<group>:rwX,other::---`,
#     so a change to the builder is a change to every claimed tree's grant; the numeric form the checks pass;
#     and the refusals that keep an identity from adding an entry of its own (a `,` or `:` in a name);
#   * the context and record grammar, where a malformed context is refused rather than read as an empty type;
#   * label_check and label_batch over canned `restorecon` output (a shell function stands in for the binary): each
#     way the output can be incomplete -- a malformed line at exit 0 with empty stderr, a record naming a path outside
#     the list, a path recorded twice, any stderr, a non-zero exit, a final line cut before its LF -- is asserted never
#     to read as a match, while the whole records such output carried keep their drift;
#   * lstat_outcomes over real paths: absence is ENOENT or ENOTDIR alone, an unsearchable ancestor is unknown,
#     a dangling symlink and a non-UTF-8 name exist, and a run whose output cannot be read makes every path unknown;
#   * the ACL reader and group_check: the mask limits the named entries and group:: alone (acl(5)), a named entry with
#     no mask, a duplicate and an incomplete set are unknown, and each postcondition -- owner, seal, group, setgid, each
#     entry in effect, the default set -- fails on its own; a real setfacl of the specification is the live control.
#
# It loads the CHECKOUT's library by path and prints it first, so a change in the checkout is what runs; the installed
# copy is covered by tests/integration/perms.sh and by tests/unit/setfacl.sh. Runs unprivileged; as root the EACCES
# and unwritable-directory cases skip, since root reads and writes through both.

# shellcheck disable=SC2154  # the output variables are assigned by the library's `printf -v` and namerefs
# shellcheck disable=SC2034  # the arrays handed to the library by name are read through its namerefs
# shellcheck disable=SC2015  # `check && pass || fail`: pass returns 0, so fail runs only on a failed check
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/src/usr/local/lib/ai-tools/project-permissions.lib.sh"
printf 'project-permissions: %s\n' "${LIB}"

section "project-permissions: the claim's ACL specification (unit)"
if [[ ! -r "${LIB}" ]]; then
    fail "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=SCRIPTDIR/../../src/usr/local/lib/ai-tools/project-permissions.lib.sh
source "${LIB}"

spec='unset'
if ai_tools_project_permissions_build_acl_specification spec alice ai-tools \
        && [[ "${spec}" == "user:alice:rwX,group:ai-tools:rwX,other::---" ]]; then
    pass "names: the specification ai-tools-setfacl applied before the move"
else
    fail "names: got '${spec}'"
fi

spec='unset'
if ai_tools_project_permissions_build_acl_specification spec 1000 985 \
        && [[ "${spec}" == "user:1000:rwX,group:985:rwX,other::---" ]]; then
    pass "numeric ids: the form getfacl --numeric prints"
else
    fail "numeric ids: got '${spec}'"
fi

spec='unset'
if ai_tools_project_permissions_build_acl_specification spec first.last_name-2 ai-tools \
        && [[ "${spec}" == "user:first.last_name-2:rwX,group:ai-tools:rwX,other::---" ]]; then
    pass "a name with dot, underscore and hyphen is kept as given"
else
    fail "dot/underscore/hyphen name: got '${spec}'"
fi

for bad in "" "alice,user:mallory" "alice:rwx" "alice bob" "-alice" $'alice\nbob' "élise"; do
    spec='unset' rc=0
    ai_tools_project_permissions_build_acl_specification spec "${bad}" ai-tools || rc=$?
    if (( rc == 1 )) && [[ -z "${spec}" ]]; then
        pass "operator '$(printf '%q' "${bad}")' refused, variable emptied"
    else
        fail "operator '$(printf '%q' "${bad}")': rc=${rc}, spec='${spec}'"
    fi
    spec='unset' rc=0
    ai_tools_project_permissions_build_acl_specification spec alice "${bad}" || rc=$?
    if (( rc == 1 )) && [[ -z "${spec}" ]]; then
        pass "group '$(printf '%q' "${bad}")' refused, variable emptied"
    else
        fail "group '$(printf '%q' "${bad}")': rc=${rc}, spec='${spec}'"
    fi
done

rc=0
ai_tools_project_permissions_build_acl_specification 'bad-name' alice ai-tools || rc=$?
(( rc == 2 )) && pass "an invalid output-variable name returns 2" || fail "invalid variable name: rc=${rc}"

# Sourcing twice is a no-op (the include guard), so a consumer that loads it directly and transitively does not abort
# under `set -e` on the readonly guard.
# shellcheck source=/dev/null
if ( source "${LIB}" && source "${LIB}" ); then
    pass "include guard: a second source is a no-op"
else
    fail "a second source failed"
fi

mktestdir
work="${TESTDIR}/work"
mkdir -p "${work}"

# ── SELinux label ─────────────────────────────────────────────────────────────────────────────────────────────────
# A context is held to user:role:type:level, the level carrying any categories, so a malformed pair cannot give two
# empty types that compare equal -- the case where a verifier would read `match` off a line it could not parse.
section "project-permissions: the context and record grammar (unit)"

for good in "system_u:object_r:ai_tools_project_t:s0" "unconfined_u:object_r:var_t:s0:c1,c2" \
        "u:r:t:s0-s0:c0.c1023"; do
    type_out='unset'
    if ai_tools_project_permissions_context_type type_out "${good}" && [[ -n "${type_out}" ]]; then
        pass "context '${good}' reads type '${type_out}'"
    else
        fail "context '${good}' refused"
    fi
done
for bad in "" "u:r:t" "u::t:s0" "u:r::s0" "u:r:t:" "u:r:t:s0 x" "u:r:t s:s0" $'u:r:t:s0\t'; do
    type_out='unset' rc=0
    ai_tools_project_permissions_context_type type_out "${bad}" || rc=$?
    if (( rc == 1 )) && [[ -z "${type_out}" ]]; then
        pass "context '$(printf '%q' "${bad}")' refused, type empty"
    else
        fail "context '$(printf '%q' "${bad}")': rc=${rc} type='${type_out}'"
    fi
done

ctx_home="unconfined_u:object_r:user_home_t:s0"
ctx_project="system_u:object_r:ai_tools_project_t:s0"
record_path='' record_from='' record_to=''
if ai_tools_project_permissions_parse_restorecon_record "Would relabel /p/name from a to b from ${ctx_home} to ${ctx_project}" \
        record_path record_from record_to \
        && [[ "${record_path}" == "/p/name from a to b" && "${record_from}" == user_home_t \
              && "${record_to}" == ai_tools_project_t ]]; then
    pass "a record whose path holds ' from ' and ' to ' splits from the right"
else
    fail "split: path='${record_path}' from='${record_from}' to='${record_to}'"
fi
for bad in "Would relabel /p from ${ctx_home}" "relabel /p from ${ctx_home} to ${ctx_project}" \
        "Would relabel  from ${ctx_home} to ${ctx_project}" "Would relabel /p from u::t:s0 to ${ctx_project}" \
        "Would relabel /p from ${ctx_home} to u:r::s0" "/p not reset as customized by admin to ${ctx_home}"; do
    record_path='x' rc=0
    ai_tools_project_permissions_parse_restorecon_record "${bad}" record_path record_from record_to || rc=$?
    if (( rc == 1 )) && [[ -z "${record_path}${record_from}${record_to}" ]]; then
        pass "record refused: '${bad}'"
    else
        fail "record accepted: '${bad}' (path='${record_path}')"
    fi
done

# restorecon is a shell function here: the library calls it by name, so the function wins over the binary. It prints
# the canned stdout and stderr the case set and exits with the status the case set, and records its arguments.
stub_out="${work}/stub.out" stub_err="${work}/stub.err" stub_args="${work}/stub.args"
stub_status=0
restorecon() {
    printf '%s\n' "$@" > "${stub_args}"
    cat -- "${stub_out}"
    cat -- "${stub_err}" >&2
    return "${stub_status}"
}
stub() {  # stub <status> <stdout> [<stderr>]
    stub_status="$1"
    printf '%s' "$2" > "${stub_out}"
    printf '%s' "${3:-}" > "${stub_err}"
}

section "project-permissions: label_check, the per-path test (unit)"
lc_is() {  # lc_is <what> <path> <want-outcome> [<want-from> <want-to>]
    local outcome from to
    ai_tools_project_permissions_label_check "$2" "${work}" outcome from to
    if [[ "${outcome}" == "$3" && "${from}" == "${4:-}" && "${to}" == "${5:-}" ]]; then
        pass "label_check: $1 -> $3"
    else
        fail "label_check: $1 -> ${outcome} (${from} -> ${to}), want $3"
    fi
}
stub 0 ""
lc_is "complete output, no record" /p/a match
if grep -qx -- -n "${stub_args}" && grep -qx -- -F "${stub_args}" && ! grep -qx -- -R "${stub_args}"; then
    pass "label_check asks for a forced, non-recursive dry run (-n -F, no -R)"
else
    fail "label_check arguments: $(tr '\n' ' ' < "${stub_args}")"
fi
stub 0 "Would relabel /p/a from unconfined_u:object_r:ai_tools_project_t:s0 to ${ctx_project}"$'\n'
lc_is "the SELinux user alone differs" /p/a match ai_tools_project_t ai_tools_project_t
stub 0 "Would relabel /p/a from ${ctx_home} to ${ctx_project}"$'\n'
lc_is "the type differs" /p/a drift user_home_t ai_tools_project_t
stub 0 "Would relabel /p/lf"$'\n'"name from ${ctx_home} to ${ctx_project}"$'\n'
lc_is "a name holding LF, its record over two lines" $'/p/lf\nname' drift user_home_t ai_tools_project_t
stub 0 "Would relabel /p/other from ${ctx_home} to ${ctx_project}"$'\n'
lc_is "a record naming another path" /p/a unknown
stub 0 "Would relabel /p/a from ${ctx_home} to ${ctx_project}"
lc_is "a record without its LF" /p/a unknown
stub 0 "Would relabel /p/a from u::t:s0 to ${ctx_project}"$'\n'
lc_is "a malformed context" /p/a unknown
stub 0 "" "restorecon: a warning"$'\n'
lc_is "empty stdout with stderr" /p/a unknown
stub 255 "" "restorecon: lstat(/p/a) failed: No such file or directory"$'\n'
lc_is "exit 255 for a missing path" /p/a unknown
stub 1 ""
lc_is "exit 1 with empty streams" /p/a unknown
# A NUL ends a shell read, so output carrying one would read as the part before it: a NUL-prefixed capture would read
# as empty, which is a match. The capture reader refuses it whole.
stub_nul() {  # stub_nul <status> <text-before-the-NUL> <text-after-it>
    stub_status="$1"
    { printf '%s' "$2"; printf '\0'; printf '%s' "$3"; } > "${stub_out}"
    : > "${stub_err}"
}
stub_nul 0 "" "Would relabel /p/a from ${ctx_home} to ${ctx_project}"$'\n'
lc_is "a capture opening with a NUL" /p/a unknown
stub_nul 0 "Would relabel /p/a from ${ctx_home} to ${ctx_project}"$'\n' "trailing"
lc_is "a record followed by a NUL" /p/a unknown

section "project-permissions: label_batch, the collection and verification batch (unit)"
batch_list="${work}/batch.list"
printf '%s\0' /p/a /p/b /p/c /p/d > "${batch_list}"
declare -A listed=([/p/a]=1 [/p/b]=1 [/p/c]=1 [/p/d]=1)
record_a="Would relabel /p/a from ${ctx_home} to ${ctx_project}"
record_b="Would relabel /p/b from unconfined_u:object_r:ai_tools_project_t:s0 to ${ctx_project}"
record_c="Would relabel /p/c from system_u:object_r:container_file_t:s0:c1,c2 to ${ctx_project}"
lb_is() {  # lb_is <what> <want-status> <want-drift-keys> [-i]
    local rc=0 keys
    local -A drift=()
    ai_tools_project_permissions_label_batch "${batch_list}" "${work}" listed drift "${4:-}" || rc=$?
    keys=""
    (( ${#drift[@]} )) && keys="$(printf '%s\n' "${!drift[@]}" | sort | tr '\n' ' ')"
    if (( rc == $2 )) && [[ "${keys}" == "$3" ]]; then
        pass "label_batch: $1 -> status ${rc}, drift [${keys% }]"
    else
        fail "label_batch: $1 -> status ${rc}, drift [${keys% }], want status $2, drift [${3% }]"
    fi
}
stub 0 "${record_a}"$'\n'"${record_b}"$'\n'"${record_c}"$'\n'
lb_is "complete output: two drifts, one user-only difference" 0 "/p/a /p/c "
if grep -qx -- -0 "${stub_args}" && grep -qx -- -F "${stub_args}" && ! grep -qx -- -i "${stub_args}"; then
    pass "label_batch reads a NUL list with -F and passes -i only when asked"
else
    fail "label_batch arguments: $(tr '\n' ' ' < "${stub_args}")"
fi
lb_is "the same with -i" 0 "/p/a /p/c " -i
grep -qx -- -i "${stub_args}" && pass "label_batch passes -i through" || fail "label_batch dropped -i"
stub 0 "${record_a}"$'\n'"restorecon: not a record"$'\n'
lb_is "a malformed line at exit 0 with empty stderr: never complete" 1 "/p/a "
stub 0 "${record_a}"$'\n'"Would relabel /p/b from u:r::s0 to ${ctx_project}"$'\n'
lb_is "a record whose context has an empty type" 1 "/p/a "
stub 1 "${record_a}"$'\n'"${record_c}"$'\n'
lb_is "two records, then exit 1: both kept, the rest unknown" 1 "/p/a /p/c "
stub 143 "${record_a}"$'\n'"Would relabel /p/c from ${ctx_home} to system_u:obj"
lb_is "a record and a half, exit 143: the partial one is not read" 1 "/p/a "
stub 0 "${record_a}"
lb_is "a single record without its LF" 1 ""
stub 0 "${record_a}"$'\n'"Would relabel /p/elsewhere from ${ctx_home} to ${ctx_project}"$'\n'
lb_is "a record naming a path outside the listed set" 1 "/p/a "
stub 0 "${record_a}"$'\n'"${record_a}"$'\n'
lb_is "one path recorded twice" 1 "/p/a "
stub 0 "${record_a}"$'\n' "restorecon: a warning"$'\n'
lb_is "any stderr" 1 "/p/a "
stub 255 "${record_a}"$'\n' "restorecon: lstat(/p/d) failed: No such file or directory"$'\n'
lb_is "exit 255 for a path removed before the batch" 1 "/p/a "
stub 0 ""
lb_is "empty output: every listed path matches" 0 ""
stub_nul 0 "" "${record_a}"$'\n'
lb_is "a capture opening with a NUL: never complete" 1 ""

section "project-permissions: the capture reader (unit)"
capture_is() {  # capture_is <what> <file> <want-status>
    local text='unset' rc=0
    _ai_tools_project_permissions_read_capture "$2" text || rc=$?
    if (( rc == $3 )) && { (( rc == 0 )) || [[ -z "${text}" ]]; }; then
        pass "read_capture: $1 -> ${rc}"
    else
        fail "read_capture: $1 -> ${rc} (text '${text}'), want $3"
    fi
}
printf 'two\nlines\n' > "${work}/capture.text"
capture_is "a whole capture" "${work}/capture.text" 0
: > "${work}/capture.empty"
capture_is "an empty capture" "${work}/capture.empty" 0
capture_is "a missing capture" "${work}/capture.missing" 1
printf 'a\0b' > "${work}/capture.nul"
capture_is "a capture holding a NUL" "${work}/capture.nul" 1
ln -s "${work}/capture.text" "${work}/capture.link"
capture_is "a capture that is a symlink" "${work}/capture.link" 1

# ── Absence ───────────────────────────────────────────────────────────────────────────────────────────────────────
section "project-permissions: lstat_outcomes, confirmed absence (unit)"
tree="${TESTDIR}/tree"
mkdir -p "${tree}/dir" "${tree}/locked"
: > "${tree}/file"; : > "${tree}/locked/inside"; : > "${tree}/"$'\xff'"name"
ln -s "${tree}/nowhere" "${tree}/dangling"
chmod 000 "${tree}/locked"
lstat_list="${work}/lstat.list"
printf '%s\0' "${tree}/file" "${tree}/dir" "${tree}/removed" "${tree}/file/child" "${tree}/dangling" \
    "${tree}/"$'\xff'"name" "${tree}/locked/inside" > "${lstat_list}"
declare -a lstat_got=()
ai_tools_project_permissions_lstat_outcomes "${lstat_list}" "${work}" lstat_got
lstat_want=(exists exists gone gone exists exists unknown)
if (( EUID == 0 )); then lstat_want[6]=exists; fi  # root searches a mode-000 directory anyway
for lstat_i in "${!lstat_want[@]}"; do
    lstat_label=(file directory removed "under a file (ENOTDIR)" "dangling symlink" "non-UTF-8 name" \
        "under an unsearchable directory")
    if [[ "${lstat_got[lstat_i]:-}" == "${lstat_want[lstat_i]}" ]]; then
        pass "lstat_outcomes: ${lstat_label[lstat_i]} -> ${lstat_want[lstat_i]}"
    else
        fail "lstat_outcomes: ${lstat_label[lstat_i]} -> ${lstat_got[lstat_i]:-<none>}, want ${lstat_want[lstat_i]}"
    fi
done
chmod 700 "${tree}/locked"
if (( EUID == 0 )); then
    skip "lstat_outcomes: EACCES" "root searches a mode-000 directory; run unprivileged to drive it"
fi

# The interpreter's run failing -- here its output cannot be written, since the work directory is read-only -- makes
# every entry unknown, whatever it could have looked up.
readonly_work="${TESTDIR}/readonly-work"
mkdir -p "${readonly_work}"; chmod 500 "${readonly_work}"
declare -a lstat_failed=()
ai_tools_project_permissions_lstat_outcomes "${lstat_list}" "${readonly_work}" lstat_failed
lstat_joined="$(printf '%s ' "${lstat_failed[@]}")"
if (( EUID != 0 )); then
    if [[ "${lstat_joined}" == "unknown unknown unknown unknown unknown unknown unknown " ]]; then
        pass "lstat_outcomes: a run whose output cannot be read makes every path unknown"
    else
        fail "lstat_outcomes with an unwritable work directory: ${lstat_joined}"
    fi
else
    skip "lstat_outcomes: a failed run" "root writes a mode-500 directory anyway"
fi
chmod 700 "${readonly_work}"
rc=0
ai_tools_project_permissions_lstat_outcomes "${work}/no-such-list" "${work}" lstat_failed || rc=$?
(( rc == 1 && ${#lstat_failed[@]} == 0 )) && pass "lstat_outcomes: an unreadable list returns 1, no outcome" \
    || fail "lstat_outcomes with no list: rc=${rc}, ${#lstat_failed[@]} outcome(s)"

# ── Group and ACL ─────────────────────────────────────────────────────────────────────────────────────────────────
section "project-permissions: the ACL reader and the mask scope (acl(5)) (unit)"
declare -A acl_set=([user:]=rw- [user:1000]=rwx [group:]=rw- [group:985]=rwx [mask:]=-wx [other:]=r--)
effective_is() {  # effective_is <key> <want>
    local have
    ai_tools_project_permissions_acl_effective_permissions have acl_set "$1"
    [[ "${have}" == "$2" ]] && pass "effective ${1}: ${2} under mask -wx" \
        || fail "effective ${1}: ${have}, want ${2}"
}
effective_is user: rw-
effective_is other: r--
effective_is user:1000 -wx
effective_is group: -w-
effective_is group:985 -wx
effective_is user:4242 ""

acl_fixture="${work}/acl.fixture"
acl_real="$(command -v getfacl)"
getfacl() { cat -- "${acl_fixture}"; }
acl_is() {  # acl_is <what> <want-status> <fixture-lines...>
    local what="$1" want="$2" rc=0
    local -A access=() default=()
    shift 2
    printf '%s\n' "$@" > "${acl_fixture}"
    ai_tools_project_permissions_read_acl /p "${work}" access default || rc=$?
    (( rc == want )) && pass "read_acl: ${what} -> ${want}" || fail "read_acl: ${what} -> ${rc}, want ${want}"
}
acl_is "minimal set" 0 user::rw- group::r-- other::---
acl_is "named entries with a mask, and a blank separator" 0 user::rw- user:1000:rw- group::r-- mask::rw- other::--- ""
acl_is "a named entry with no mask" 1 user::rw- user:1000:rw- group::r-- other::---
acl_is "a minimal default set beside a minimal access set" 0 user::rw- group::r-- other::--- \
    default:user::rwx default:group::r-x default:other::---
acl_is "default set: a named entry with no default mask" 1 user::rw- group::r-- other::--- \
    default:user::rwx default:user:1000:rwx default:group::r-x default:other::---
acl_is "a duplicate entry" 1 user::rw- user:1000:rw- user:1000:r-- group::r-- mask::rw- other::---
acl_is "a set missing other::" 1 user::rw- group::r--
acl_is "a default set missing group::" 1 user::rw- group::r-- other::--- default:user::rwx default:other::---
acl_is "a mask with a qualifier" 1 user::rw- group::r-- mask:5:rw- other::---
acl_is "a named entry by name, not number" 1 user::rw- user:alice:rw- group::r-- mask::rw- other::---
acl_is "an #effective: comment" 1 user::rw- "user:1000:rw-	#effective:r--" group::r-- mask::r-- other::---
getfacl() { return 1; }
acl_is "getfacl failing" 1
getfacl() { printf 'user::rw-\ngroup::r--\nother::---\n'; printf 'getfacl: a warning\n' >&2; }
acl_is "getfacl writing to stderr" 1

section "project-permissions: group_check, the repair's postconditions (unit)"
# The owner, group and mode come from the real fixture; its ACL from a canned getfacl. The fixture belongs to this run's
# account and group, which stand in for the sandbox account and the sandbox group; the operator is uid 4242.
gc_file="${TESTDIR}/gc-file" gc_dir="${TESTDIR}/gc-dir"
: > "${gc_file}"; chmod 0660 "${gc_file}"
mkdir -p "${gc_dir}"; chmod 2770 "${gc_dir}"
my_uid="$(stat -c '%u' "${gc_file}")" my_gid="$(stat -c '%g' "${gc_file}")"
op_uid=4242
good_access=(user::rw- "user:${op_uid}:rw-" group::rw- "group:${my_gid}:rw-" mask::rw- other::---)
good_dir_access=(user::rwx "user:${op_uid}:rwx" group::rwx "group:${my_gid}:rwx" mask::rwx other::---)
good_default=(default:user::rwx "default:user:${op_uid}:rwx" default:group::rwx "default:group:${my_gid}:rwx"
    default:mask::rwx default:other::---)
# group_check reads through a child process, so the stub and the fixture path it reads are exported to it.
getfacl() { cat -- "${acl_fixture}"; }
export -f getfacl
export acl_fixture
gc_is() {  # gc_is <what> <path> <want-outcome> <sandbox-uid> <sandbox-gid> <fixture-lines...>
    local what="$1" path="$2" want="$3" sandbox_uid="$4" sandbox_gid="$5" outcome detail
    shift 5
    printf '%s\n' "$@" > "${acl_fixture}"
    ai_tools_project_permissions_group_check "${path}" "${work}" "${op_uid}" "${sandbox_uid}" "${sandbox_gid}" \
        outcome detail
    if [[ "${outcome}" == "${want}" ]]; then
        pass "group_check: ${what} -> ${want}${detail:+ (${detail})}"
    else
        fail "group_check: ${what} -> ${outcome} (${detail}), want ${want}"
    fi
}
gc_is "a file carrying every entry" "${gc_file}" match "${my_uid}" "${my_gid}" "${good_access[@]}"
gc_is "a directory carrying every entry, default set included" "${gc_dir}" match "${my_uid}" "${my_gid}" \
    "${good_dir_access[@]}" "${good_default[@]}"
gc_is "the operator's entry missing" "${gc_file}" drift "${my_uid}" "${my_gid}" \
    user::rw- "group:${my_gid}:rw-" group::rw- mask::rw- other::---
gc_is "the mask reduced to r--" "${gc_file}" drift "${my_uid}" "${my_gid}" \
    user::rw- "user:${op_uid}:rw-" group::rw- "group:${my_gid}:rw-" mask::r-- other::---
gc_is "other:: r-- under mask -wx (the mask does not reach other::)" "${gc_file}" drift "${my_uid}" "${my_gid}" \
    user::rw- "user:${op_uid}:rw-" group::rw- "group:${my_gid}:rw-" mask::rw- other::r--
gc_is "a named entry and no mask" "${gc_file}" unknown "${my_uid}" "${my_gid}" \
    user::rw- "user:${op_uid}:rw-" group::rw- "group:${my_gid}:rw-" other::---
gc_is "a directory with no default set" "${gc_dir}" drift "${my_uid}" "${my_gid}" "${good_dir_access[@]}"
gc_is "a directory whose default mask is r-x" "${gc_dir}" drift "${my_uid}" "${my_gid}" \
    "${good_dir_access[@]}" default:user::rwx "default:user:${op_uid}:rwx" default:group::rwx \
    "default:group:${my_gid}:rwx" default:mask::r-x default:other::---
chmod 0770 "${gc_file}"
gc_is "a file with an execute bit, its entries lacking x" "${gc_file}" drift "${my_uid}" "${my_gid}" \
    user::rwx "user:${op_uid}:rw-" group::rwx "group:${my_gid}:rw-" mask::rw- other::---
chmod 0660 "${gc_file}"
gc_is "a file without an execute bit, its entries lacking x" "${gc_file}" match "${my_uid}" "${my_gid}" \
    "${good_access[@]}"
gc_is "owned by a third account" "${gc_file}" drift 4343 "${my_gid}" "${good_access[@]}"
gc_is "in another group" "${gc_file}" drift "${my_uid}" 4343 "${good_access[@]}"
chmod g-s "${gc_dir}"  # a numeric chmod keeps a directory's setgid bit
gc_is "a directory without setgid" "${gc_dir}" drift "${my_uid}" "${my_gid}" \
    "${good_dir_access[@]}" "${good_default[@]}"
chmod 2770 "${gc_dir}"
chmod 0600 "${gc_file}"
gc_is "made owner-only" "${gc_file}" drift "${my_uid}" "${my_gid}" "${good_access[@]}"
chmod 0660 "${gc_file}"
ln -s "${gc_file}" "${TESTDIR}/gc-link"
gc_is "a symlink" "${TESTDIR}/gc-link" unknown "${my_uid}" "${my_gid}" "${good_access[@]}"
gc_is "a path that cannot be stat'ed" "${TESTDIR}/gc-missing" unknown "${my_uid}" "${my_gid}" "${good_access[@]}"
getfacl() { return 1; }
export -f getfacl
gc_is "getfacl failing" "${gc_file}" unknown "${my_uid}" "${my_gid}"

# The path swapped while it is read: getfacl here replaces the file with a symlink to another file carrying every entry
# before printing, so the owner and ACL read come from an object the path no longer names. The path's identity read
# again afterwards differs, which reads unknown.
gc_swap="${TESTDIR}/gc-swap" gc_other="${TESTDIR}/gc-other"
: > "${gc_swap}"; chmod 0660 "${gc_swap}"; : > "${gc_other}"; chmod 0660 "${gc_other}"
export gc_swap gc_other
getfacl() { rm -f -- "${gc_swap}"; ln -s -- "${gc_other}" "${gc_swap}"; cat -- "${acl_fixture}"; }
export -f getfacl
gc_is "a path swapped for a symlink while it is read" "${gc_swap}" unknown "${my_uid}" "${my_gid}" \
    "${good_access[@]}"
export -n gc_swap gc_other
if mkfifo "${TESTDIR}/gc-fifo" 2>/dev/null; then
    gc_is "a FIFO, reported without being opened" "${TESTDIR}/gc-fifo" unknown "${my_uid}" "${my_gid}" \
        "${good_access[@]}"
else
    skip "group_check over a FIFO" "mkfifo refused in ${TESTDIR}"
fi
unset -f getfacl
export -n acl_fixture

# The live control: the specification applied with the real setfacl and read back with the real getfacl.
if [[ -n "${acl_real}" ]] && command -v setfacl >/dev/null 2>&1; then
    live="${TESTDIR}/gc-live"
    : > "${live}"; chmod 0660 "${live}"
    live_spec=''
    ai_tools_project_permissions_build_acl_specification live_spec "${op_uid}" "${my_gid}"
    if setfacl -m "${live_spec//X/x}" "${live}" 2>/dev/null; then
        live_outcome='' live_detail=''
        ai_tools_project_permissions_group_check "${live}" "${work}" "${op_uid}" "${my_uid}" "${my_gid}" \
            live_outcome live_detail
        [[ "${live_outcome}" == match ]] \
            && pass "group_check over a real setfacl of the specification -> match" \
            || fail "group_check over a real setfacl -> ${live_outcome} (${live_detail})"
    else
        skip "group_check live control" "setfacl refused on ${TESTDIR}"
    fi
else
    skip "group_check live control" "setfacl or getfacl not installed"
fi

finish

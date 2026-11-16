#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/avc-denials.sh
# Unit test for the readers selinux/avc/avc-denials.sh judges an enforce-verification run by. Each is driven
# in the direction that would pass a run it should not: an attempt that did not exercise its access must not read
# as denied, a seinfo query that failed or printed an unexpected listing must not confirm enforcement, a module list
# must not yield a group name the store does not hold, and a probe trail must be bound to the root half's run, started
# inside its window, and finished before its exit status is believed. Sources the checkout's script (its dispatch is
# guarded for that), needs no SELinux host and no privilege. Its last section runs a copy of avc-analyze.sh over one
# fixture record at a time: each of the probe's deliberate attempts files as a probe with `--probe-run` and as NEW
# without it, and a record differing in its command or its permission stays NEW with the flag.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SCRIPT="${ROOT}/selinux/avc/avc-denials.sh"
section "avc-denials: attempt, enforcement, group and probe-trail readers (unit)"

if [[ ! -r "${SCRIPT}" ]]; then
    skip "avc-denials readers" "no ${SCRIPT} (not a checkout)"; finish; exit
fi
_ifs="${IFS}"
# shellcheck source=/dev/null
source "${SCRIPT}"
IFS="${_ifs}"
set -e
for fn in avc_attempt_reason avc_tcp_reason avc_dbus_reason avc_bus_name_owner avc_permissive_state avc_loaded_groups avc_probe_status; do
    declare -F "${fn}" >/dev/null || { fail "${SCRIPT} does not define ${fn}"; finish; exit; }
done

# expect <description> <expected> <actual>
expect() {
    if [[ "$3" == "$2" ]]; then pass "$1 -> $3"; else fail "$1 -> '$3'; expected '$2'"; fi
}

section "attempt reasons"
expect "status 0" allowed "$(avc_attempt_reason 0 "")"
expect "status 0 with a denial on stderr" allowed "$(avc_attempt_reason 0 "cat: x: Permission denied")"
expect "EACCES from a tool" denied "$(avc_attempt_reason 1 "cat: /etc/shadow: Permission denied")"
expect "EPERM from python" denied "$(avc_attempt_reason 1 "PermissionError: [Errno 1] Operation not permitted")"
expect "missing path" absent "$(avc_attempt_reason 1 "ls: cannot access '/x': No such file or directory")"
expect "absent tool keeps its status" "exit 127: bash: nosuch: command not found" \
    "$(avc_attempt_reason 127 "bash: nosuch: command not found")"
expect "refused connection is not a denial" "exit 1: ConnectionRefusedError: [Errno 111] Connection refused" \
    "$(avc_attempt_reason 1 "ConnectionRefusedError: [Errno 111] Connection refused")"
expect "silent failure" "exit 2: no message" "$(avc_attempt_reason 2 "")"

section "attempt reasons: a command bash's PATH search did not find"
mktestdir
# Each case puts one fixture directory ahead of the inherited PATH, which does not hold the fixture name, and reads
# the reason as an account DAC holds to a directory's mode: the projects user under root, which reads through any mode,
# and the invoker otherwise. A directory at mode 000 refuses the stat with EACCES, as the policy refuses getattr.
readonly TOOL="avc-fixture-tool-$$"
for d in refused empty present; do mkdir "${TESTDIR}/${d}"; done
ln -s "$(type -P true)" "${TESTDIR}/present/${TOOL}"
printf 'not a directory\n' > "${TESTDIR}/notdir"
[[ "${EUID}" -eq 0 ]] && chown -h -R "${PROJECTS_USER}:" "${TESTDIR}/refused" "${TESTDIR}/empty" \
    "${TESTDIR}/present" "${TESTDIR}/notdir"
chmod 000 "${TESTDIR}/refused"
# reason_with_path <directory> <status> <stderr>: avc_attempt_reason's reading of <status>/<stderr> for the fixture
# name, with <directory> first on PATH.
reason_with_path() {
    local -a as_user=()
    [[ "${EUID}" -eq 0 ]] && as_user=(runuser -u "${PROJECTS_USER}" --)
    "${as_user[@]}" bash -c 'source "$1" >/dev/null; PATH="$2:${PATH}" avc_attempt_reason "$3" "$4" "$5"' \
        _ "${SCRIPT}" "$1" "$2" "$3" "${TOOL}"
}
not_found="bash: ${TOOL}: command not found"
if ! command -v python3 >/dev/null 2>&1; then
    skip "a command bash's PATH search did not find" "python3 absent (the lookup reads the stat errno through it)"
else
    expect "the fixture directory refuses the stat" denied "$(reason_with_path "${TESTDIR}/refused" 127 "${not_found}")"
    expect "no PATH directory holds the name" absent "$(reason_with_path "${TESTDIR}/empty" 127 "${not_found}")"
    expect "a PATH entry that is a file (ENOTDIR) keeps its status" "exit 127: ${not_found}" \
        "$(reason_with_path "${TESTDIR}/notdir" 127 "${not_found}")"
    expect "a name found keeps its status" "exit 127: ${not_found}" \
        "$(reason_with_path "${TESTDIR}/present" 127 "${not_found}")"
    expect "another status keeps it" "exit 1: ${not_found}" \
        "$(reason_with_path "${TESTDIR}/refused" 1 "${not_found}")"
    # The control: the present, permitted tool runs through the same PATH.
    present_rc=0; PATH="${TESTDIR}/present:${PATH}" "${TOOL}" || present_rc=$?
    expect "the present tool runs (control)" allowed "$(avc_attempt_reason "${present_rc}" "" "${TOOL}")"
fi

section "connect reasons"
# Each input is avc_attempt_reason's own reading of the _py tcp stderr, as check_tcp receives it.
expect "refused connection (no listener) is permitted" allowed \
    "$(avc_tcp_reason "$(avc_attempt_reason 1 "ECONNREFUSED: Connection refused")")"
expect "timed-out connection is permitted" allowed "$(avc_tcp_reason "$(avc_attempt_reason 1 "ETIMEDOUT: timed out")")"
expect "EACCES stays denied" denied "$(avc_tcp_reason "$(avc_attempt_reason 1 "EACCES: Permission denied")")"
expect "another errno stays not exercised" "exit 1: EHOSTUNREACH: No route to host" \
    "$(avc_tcp_reason "$(avc_attempt_reason 1 "EHOSTUNREACH: No route to host")")"

section "D-Bus call reasons"
not_running="exit 8: Error: NetworkManager is not running."
expect "a failed call while the name has an owner" denied "$(avc_dbus_reason "${not_running}" true)"
expect "a failed call while the name has no owner" absent "$(avc_dbus_reason "${not_running}" false)"
expect "an owner that could not be read keeps the reason" "${not_running}" "$(avc_dbus_reason "${not_running}" "")"
expect "a call that succeeded stays allowed" allowed "$(avc_dbus_reason allowed true)"
expect "an errno denial stays denied with no owner" denied "$(avc_dbus_reason denied false)"
expect "a missing path stays absent with an owner" absent "$(avc_dbus_reason absent true)"
# busctl is a shell function serving each reply shape; the reader is driven through it in a subshell.
owner_with() { (busctl() { [[ "$1" == fail ]] && return 1; printf '%s\n' "${BUSCTL_REPLY}"; }
                BUSCTL_REPLY="$1"; avc_bus_name_owner org.example.Service); }
expect "busctl replies b true" true "$(owner_with "b true")"
expect "busctl replies b false" false "$(owner_with "b false")"
expect "busctl replies another shape" "" "$(owner_with "s \"yes\"")"
expect "busctl replies two lines" "" "$(owner_with "b true
b true")"
expect "busctl fails" "" "$( (busctl() { return 1; }; avc_bus_name_owner org.example.Service) )"

section "permissive state from seinfo"
nl=$'\n'
expect "query refused" unknown "$(avc_permissive_state 1 "[Errno 13] Permission denied: '/sys/fs/selinux/policy'")"
expect "status 0, empty output" unknown "$(avc_permissive_state 0 "")"
expect "status 0, no header" unknown "$(avc_permissive_state 0 "   ai_tools_t")"
expect "count above the listed types" unknown "$(avc_permissive_state 0 "${nl}Permissive Types: 2${nl}   ai_tools_t")"
expect "count below the listed types" unknown \
    "$(avc_permissive_state 0 "${nl}Permissive Types: 0${nl}   other_t")"
expect "well formed, none permissive (control)" no "$(avc_permissive_state 0 "${nl}Permissive Types: 0${nl}")"
expect "well formed, another domain" no "$(avc_permissive_state 0 "${nl}Permissive Types: 1${nl}   other_t")"
expect "a longer name sharing the prefix" no \
    "$(avc_permissive_state 0 "${nl}Permissive Types: 1${nl}   ai_tools_tmp_t")"
expect "ai_tools_t listed" yes \
    "$(avc_permissive_state 0 "${nl}Permissive Types: 2${nl}   other_t${nl}   ai_tools_t")"

section "loaded groups from semodule -l"
expect "names alone" "localipc,tmpmap" "$(avc_loaded_groups "ai_tools${nl}ai_tools_localipc${nl}ai_tools_tmpmap${nl}apache")"
expect "core alone" "" "$(avc_loaded_groups "ai_tools${nl}apache")"
expect "a name outside the charset is dropped" "tmpmap" \
    "$(avc_loaded_groups "ai_tools_tmpmap${nl}ai_tools_x;rm${nl}ai_tools_")"

section "probe trail bound to the run"
run_id=0123456789abcdef
window=1000
# trail <file> <run-id-line> <started> <exit-line>: write a probe trail; an empty argument omits that line.
trail() {
    { [[ -n "$2" ]] && printf 'Run id      : %s\n' "$2"
      [[ -n "$3" ]] && printf 'Started     : %s\n' "$3"
      printf '[A-001] some check\n  Result: PASS -- denied\n'
      [[ -n "$4" ]] && printf 'Exit status : %s\n' "$4"
      true; } > "$1"
}
# status_of <file>: the reader's answer, or `refused` when it returns non-zero.
status_of() { avc_probe_status "$1" "${run_id}" "${window}" 2>/dev/null || echo refused; }

trail "${TESTDIR}/clean.log" "${run_id}" 1005 0
expect "bound, inside the window, exit 0 (control)" 0 "$(status_of "${TESTDIR}/clean.log")"
trail "${TESTDIR}/failed.log" "${run_id}" 1005 1
expect "bound, a check failed" 1 "$(status_of "${TESTDIR}/failed.log")"
trail "${TESTDIR}/other.log" fedcba9876543210 1005 0
expect "another run's trail" refused "$(status_of "${TESTDIR}/other.log")"
trail "${TESTDIR}/unbound.log" none 1005 0
expect "a probe run without --run-id" refused "$(status_of "${TESTDIR}/unbound.log")"
trail "${TESTDIR}/twice.log" "${run_id}" 1005 0
printf 'Run id      : %s\n' "${run_id}" >> "${TESTDIR}/twice.log"
expect "run id named twice" refused "$(status_of "${TESTDIR}/twice.log")"
trail "${TESTDIR}/early.log" "${run_id}" 999 0
expect "started before the window" refused "$(status_of "${TESTDIR}/early.log")"
trail "${TESTDIR}/nostart.log" "${run_id}" "" 0
expect "no start time" refused "$(status_of "${TESTDIR}/nostart.log")"
trail "${TESTDIR}/unfinished.log" "${run_id}" 1005 ""
expect "no exit status (the probe did not finish)" refused "$(status_of "${TESTDIR}/unfinished.log")"
ln -s "${TESTDIR}/clean.log" "${TESTDIR}/link.log"
expect "a symlink to a clean trail" refused "$(status_of "${TESTDIR}/link.log")"
expect "no file" refused "$(status_of "${TESTDIR}/absent.log")"

section "analyzer: the probe's own attempts (avc-analyze.sh --probe-run)"
# avc-analyze.sh refuses a non-root caller on one line before it reads anything, so a copy without that line runs here
# unprivileged, with ausearch a shell function serving the one record a case writes as the whole window.
readonly ANALYZER="${ROOT}/selinux/avc/avc-analyze.sh"
readonly ROOT_CHECK='^\[\[ "\$\{EUID\}" -eq 0 \]\] \|\|'
analyzer="${TESTDIR}/avc-analyze.sh"
if [[ "$(grep -cE "${ROOT_CHECK}" "${ANALYZER}")" -ne 1 ]]; then
    fail "${ANALYZER} does not hold its root check on exactly one line; the unprivileged copy cannot be made"
else
    grep -vE "${ROOT_CHECK}" "${ANALYZER}" > "${analyzer}"
    export AVC_RECORD_FILE="${TESTDIR}/record"
    ausearch() { cat "${AVC_RECORD_FILE}"; }
    audit2allow() { :; }
    export -f ausearch audit2allow

    readonly SELF_CONTEXT="unconfined_u:unconfined_r:ai_tools_t:s0-s0:c0.c1023"
    # bucket_of <permission> <comm> <tcontext> <class> [<analyzer flag>]: the bucket the analyzer files one denial
    # under -- `probe` or `NEW` when that bucket alone counts it, otherwise the counts line.
    bucket_of() {
        local counts
        printf 'type=AVC msg=audit(1762637261.100:4242): avc:  denied  { %s } for  pid=4242 comm="%s" dev="dm-0"' \
            "$1" "$2" > "${AVC_RECORD_FILE}"
        printf ' ino=42 scontext=%s tcontext=%s tclass=%s permissive=0\n' "${SELF_CONTEXT}" "$3" "$4" \
            >> "${AVC_RECORD_FILE}"
        counts="$(bash "${analyzer}" ${5:+"$5"} -ts today 2>&1 | sed -n 's/^counts: //p')"
        case "${counts}" in
            *"boundary=0  group-disabled=0  probe=1  NEW=0"*) echo probe ;;
            *"boundary=0  group-disabled=0  probe=0  NEW=1"*) echo NEW ;;
            *) echo "${counts:-no counts line}" ;;
        esac
    }

    # One row per deliberate attempt: permission, command, target context, class, then another command and another
    # permission, each of which must leave the record NEW under the flag.
    while IFS='|' read -r perm comm tcontext class other_comm other_perm; do
        what="${tcontext##*:object_r:}"; what="${what%%:*}"; [[ "${tcontext}" == "${SELF_CONTEXT}" ]] && what=self
        what="${comm} { ${perm} } ${what}:${class}"
        expect "${what}, no flag (the record is read)" NEW "$(bucket_of "${perm}" "${comm}" "${tcontext}" "${class}")"
        expect "${what}, --probe-run" probe \
            "$(bucket_of "${perm}" "${comm}" "${tcontext}" "${class}" --probe-run)"
        expect "${what} as ${other_comm}, --probe-run" NEW \
            "$(bucket_of "${perm}" "${other_comm}" "${tcontext}" "${class}" --probe-run)"
        expect "${what} as { ${other_perm} }, --probe-run" NEW \
            "$(bucket_of "${other_perm}" "${comm}" "${tcontext}" "${class}" --probe-run)"
    done <<EOF
search|ls|system_u:object_r:container_var_lib_t:s0|dir|sh|read
getattr|bash|system_u:object_r:kmod_exec_t:s0|file|sh|execute
getattr|python3|system_u:object_r:kmod_exec_t:s0|file|sh|execute
prog_load|bpftool|${SELF_CONTEXT}|bpf|python3|map_create
create|python3|${SELF_CONTEXT}|rawip_socket|perl|getopt
name_bind|python3|system_u:object_r:http_port_t:s0|tcp_socket|node|name_connect
read|getenforce|system_u:object_r:security_t:s0|file|python3|write
read|cat|system_u:object_r:security_t:s0|file|head|write
EOF
fi

finish

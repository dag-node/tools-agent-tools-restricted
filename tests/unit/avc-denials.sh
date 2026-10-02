#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/avc-denials.sh
# Unit test for the readers selinux/avc/avc-denials.sh judges an enforce-verification run by. Each is driven
# in the direction that would pass a run it should not: an attempt that did not exercise its access must not read
# as denied, a seinfo query that failed or printed an unexpected listing must not confirm enforcement, a module list
# must not yield a group name the store does not hold, and a probe trail must be bound to the root half's run, started
# inside its window, and finished before its exit status is believed. Sources the checkout's script (its dispatch is
# guarded for that), needs no SELinux host and no privilege.
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
for fn in avc_attempt_reason avc_permissive_state avc_loaded_groups avc_probe_status; do
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
expect "EL9 bare names" "localipc,tmpmap" "$(avc_loaded_groups "ai_tools${nl}ai_tools_localipc${nl}ai_tools_tmpmap${nl}apache")"
expect "version column" "buildexec" "$(avc_loaded_groups "ai_tools 1.0${nl}ai_tools_buildexec 1.0${nl}zebra 1.0")"
expect "core alone" "" "$(avc_loaded_groups "ai_tools${nl}apache")"
expect "a name outside the charset is dropped" "tmpmap" \
    "$(avc_loaded_groups "ai_tools_tmpmap${nl}ai_tools_x;rm${nl}ai_tools_")"

section "probe trail bound to the run"
mktestdir
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

finish

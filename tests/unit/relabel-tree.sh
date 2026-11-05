#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/relabel-tree.sh
# Unit test for the descriptor-pinned tree relabel, src/usr/local/libexec/ai-tools/ai-tools-relabel-tree.py, read from
# the checkout so a source change is what runs. The first section runs relabel-tree-harness.py beside this file under
# `python3 -I`; it imports the walker by path and drives walk() and main() with a fake lookup and a fake xattr store:
# the lookup's inputs, the write and its read-back, <<none>>, hardlinks, symlinks, the root checks and the command line.
# The second runs the real `--dry-run --expected-context <ctx>` over a fixture tree and reads each entry's current
# context with getfattr to build the expected `<from>` column, since a host with SELinux labels the fixture and this
# one may not.
#
# The real mode writes security.selinux and needs a loaded policy, so it is not driven here.
#
# Hermetic: every tree is in the test's own /tmp testdir. Run as root via sudo (the suite's convention); no case
# needs it.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WALKER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-relabel-tree.py"
HARNESS="${ROOT}/tests/unit/relabel-tree-harness.py"
CONTEXT="system_u:object_r:ai_tools_project_t:s0"
section "relabel-tree: descriptor-pinned tree relabel (unit)"

if ! command -v python3 >/dev/null 2>&1; then
    skip "relabel-tree" "python3 not available"; finish; exit
fi
if [[ ! -r "${WALKER}" || ! -r "${HARNESS}" ]]; then
    skip "relabel-tree" "not a checkout (no ${WALKER})"; finish; exit
fi

mktestdir
TESTDIR="$(realpath -e "${TESTDIR}")"

# ── walk() and main() against fakes ──
mkdir "${TESTDIR}/harness"
rc=0
out="$(python3 -I "${HARNESS}" "${WALKER}" "${TESTDIR}/harness" 2>&1)" || rc=$?
rows=0
while IFS=$'\t' read -r verdict text; do
    case "${verdict}" in
        PASS) pass "${text}"; rows=$(( rows + 1 )) ;;
        FAIL) fail "${text}"; rows=$(( rows + 1 )) ;;
        *)    [[ -z "${verdict}" ]] || fail "harness printed a line outside the row format: ${verdict} ${text}" ;;
    esac
done <<< "${out}"
(( rc == 0 )) || fail "the harness exited ${rc}"
(( rows > 0 )) || fail "the harness reported no rows"

# ── The real `--dry-run --expected-context` over a fixture tree ──
command -v getfattr >/dev/null 2>&1 || { skip_required "real dry run" "getfattr (attr) is not installed"; finish; exit; }
tree="${TESTDIR}/tree"
mkdir -p "${tree}/sub"
printf 'a\n' > "${tree}/a.txt"
printf 'b\n' > "${tree}/sub/b.txt"
ln -s sub "${tree}/dirlink"
if [[ -f "${tree}/sub/b.txt" && -L "${tree}/dirlink" ]]; then
    pass "setup: the fixture holds a file under a directory and a symlink"
else
    fail "setup: the fixture tree was not created"
fi

# current_context <path> : the entry's own security.selinux without the trailing NUL, or `-` when it has none.
current_context() {
    local value
    value="$(getfattr -h --absolute-names --only-values -n security.selinux -- "$1" 2>/dev/null | tr -d '\0')" || true
    printf '%s' "${value:--}"
}
# snapshot_contexts : one `<path> <context>` line per fixture entry.
snapshot_contexts() {
    local entry
    for entry in "${tree}" "${tree}/a.txt" "${tree}/dirlink" "${tree}/sub" "${tree}/sub/b.txt"; do
        printf '%s %s\n' "${entry}" "$(current_context "${entry}")"
    done
}
before="$(snapshot_contexts)"
expected=""
while read -r entry from; do
    [[ "${from}" == "${CONTEXT}" ]] || expected+="${entry} ${from} ${CONTEXT}"$'\n'
done <<< "${before}"
note "real dry run" "the fixture root's current context is $(current_context "${tree}")"

rc=0
stdout="$(python3 -I "${WALKER}" --dry-run --expected-context "${CONTEXT}" -- "${tree}" 2>"${TESTDIR}/stderr")" || rc=$?
if (( rc == 0 )); then pass "the real dry run exits 0"; else fail "the real dry run exited ${rc}: $(cat "${TESTDIR}/stderr")"; fi
if [[ ! -s "${TESTDIR}/stderr" ]]; then
    pass "the real dry run prints nothing on stderr"
else
    fail "the real dry run printed on stderr: $(cat "${TESTDIR}/stderr")"
fi
if [[ "$(sort <<< "${stdout}")" == "$(sort <<< "${expected%$'\n'}")" ]]; then
    pass "the real dry run lists each entry whose current context differs, with that context as <from>"
else
    fail "the real dry run listed |${stdout}|, expected |${expected}|"
fi
if [[ "$(snapshot_contexts)" == "${before}" ]]; then
    pass "the real dry run left the fixture's labels as they were"
else
    fail "the fixture's labels differ after the dry run"
fi
if [[ "${stdout}" != *"${tree}/dirlink/"* ]]; then
    pass "the real dry run does not descend the symlinked directory"
else
    fail "the real dry run descended the symlinked directory"
fi

rc=0
python3 -I "${WALKER}" --expected-context "${CONTEXT}" -- "${tree}" >/dev/null 2>&1 || rc=$?
if (( rc == 2 )); then
    pass "the real command refuses --expected-context outside --dry-run with exit 2"
else
    fail "the real command exited ${rc} for --expected-context outside --dry-run"
fi

finish

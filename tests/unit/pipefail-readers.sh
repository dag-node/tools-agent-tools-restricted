#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/pipefail-readers.sh
# Hermetic check that no shipped script pipes a producer into a reader that exits early (ref-section-d9x2).
#
# The gap this closes: under `pipefail` such a pipeline returns non-zero on input that matched, on a schedule the host
# decides, so the shape passes review, ShellCheck and a quiet test run. tests/lib/pipefail-readers.py reads shell source
# for it, and this file holds the scripts under src/, selinux/, packaging/ and tools/, install.sh and the workflows'
# `run:` blocks to its report.
#
# Three sections. The first pins the mechanism the rule rests on, with a producer that prints more than a pipe holds,
# so the result does not depend on the host's load. The second proves the scanner on a fixture holding one instance
# of each shape it reports and each shape it must leave alone, so a clean tree is evidence about the tree. The third
# reads the tree. Pure text over the sources; runs without root and skips outside a checkout.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCANNER="${ROOT}/tests/lib/pipefail-readers.py"
section "no early-exit reader after a pipe (unit)"

if [[ ! -d "${ROOT}/src" ]]; then
    skip "early-exit readers" "not a source checkout (no ${ROOT}/src)"
    finish; exit
fi
if ! command -v python3 >/dev/null 2>&1; then
    skip "early-exit readers" "python3 not available"
    finish; exit
fi
mktestdir

# ── The mechanism ────────────────────────────────────────────────────────────
# The pipeline is held as text and run in a shell of its own, so this file does not carry the shape it reports.
# With SIGPIPE ignored the producer exits on the write error in place of the signal, so the status is asserted
# non-zero and printed: 141 where the signal is delivered.
piped='seq 1 200000 | grep -q "^1\$"'
rc=0; bash -c "set -o pipefail; ${piped}" 2>/dev/null || rc=$?
if (( rc != 0 )); then
    pass "a match read through a pipe from a producer still writing returns non-zero under pipefail (${rc})"
else
    fail "the piped search returned 0: the producer finished before the reader exited, so this row pins nothing"
fi
rc=0; bash -c 'set -o pipefail; out="$(seq 1 200000)"; grep -q "^1\$" <<<"${out}"' || rc=$?
if (( rc == 0 )); then
    pass "the same search over the captured output returns 0"
else
    fail "the captured search returned ${rc}, want 0"
fi

# ── The scanner on known input ───────────────────────────────────────────────
# One line per shape. The expected report names the line of the pipe that feeds each reader.
fixture="${TESTDIR}/fixture.sh"
cat > "${fixture}" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
producer | grep -q needle
if producer | command grep -qxF "${word}"; then :; fi
first="$(producer | head -n 1)"
producer | grep -m1 -E '^key='
producer | grep -l needle
producer | sed -n '/start/{p;q}'
producer | awk '$1 == "fpr" { print $10; exit }'
producer | read -r first_line
producer \
    | filter \
    | grep -q needle
sample="$(producer | head -n 3 | tr '\n' ';')"
bash -c 'producer | grep -q needle'
bash -c "producer | grep -q needle"
size="$(tool -dc file | head -c 4096 | wc -c)" || true
kept="$(tool -dc file | head -c 4096 | wc -c)"
grep -q needle <<<"${captured}"
producer | grep needle | sort
producer | sed -n 's/a/q/p'
producer | awk '{ print $1 }'
producer | while read -r line; do :; done
case "${word}" in grep|head) : ;; esac
printf '%s\n' 'producer | grep -q needle'
# producer | grep -q needle
cat <<EOF
producer | grep -q needle
EOF
(( flags | 4 )) || true
tool -dc file | head -c 4096 | wc -c || :
producer|grep -q needle
producer | grep "-q" needle
producer | grep -e -q
listing="$(case "${word}" in grep|head) producer | grep -q needle ;; esac)"
[[ "${word}" =~ ^(grep|head)$ ]] || true
text="${text/"  ${word} ("/"  ("}"
FIXTURE
expected="3 grep -q
4 grep -q
5 head
6 grep -m
7 grep -l
8 sed q
9 awk exit
10 read
13 grep -q
14 head
15 grep -q
16 grep -q
18 head
32 grep -q
33 grep -q
35 grep -q"
rc=0; report="$(python3 "${SCANNER}" "${fixture}")" || rc=$?
got="$(sed -n 's/^[^:]*:\([0-9]*\): \([^:]*\):.*/\1 \2/p' <<<"${report}")"
if (( rc == 1 )) && [[ "${got}" == "${expected}" ]]; then
    pass "the scanner reports each early-exit reader after a pipe: continued, unspaced, with a quoted option, in a bash -c body, in a case arm"
    pass "and leaves alone a head -c whose status is discarded, a herestring, a reader that reads to the end, a pattern after -e, case and [[ ]] alternations, quoted text"
else
    fail "the scanner's report over the fixture (rc=${rc}) is not the expected one: $(tr '\n' '|' <<<"${got}")"
fi

clean="${TESTDIR}/clean.sh"
# shellcheck disable=SC2016  # the fixture's own expansions, written as text
printf '%s\n' '#!/usr/bin/env bash' 'out="$(producer)" || out=""' 'grep -q needle <<<"${out}"' > "${clean}"
rc=0; report="$(python3 "${SCANNER}" "${clean}")" || rc=$?
if (( rc == 0 )) && [[ -z "${report}" ]]; then
    pass "a file in the capture shape is reported clean, at exit 0"
else
    fail "the capture shape: rc=${rc}, report: ${report}"
fi

# A workflow is read for its `run:` blocks alone: the apostrophe in a step's name does not open a quote, and a block's
# finding carries the workflow's own line number.
workflow="${TESTDIR}/workflow.yml"
cat > "${workflow}" <<'WORKFLOW'
jobs:
  build:
    steps:
      - name: Read the runner's listing
        run: |
          set -euo pipefail
          stamp="$(producer | sort | head -n1)"
      - name: producer | grep -q needle
        run: grep -q needle <<<"${captured}"
WORKFLOW
rc=0; report="$(python3 "${SCANNER}" "${workflow}")" || rc=$?
if (( rc == 1 )) && [[ "${report}" == "${workflow}:7: head: head -n1" ]]; then
    pass "a workflow's run block is read as shell, at the workflow's line numbers, and its other keys are not"
else
    fail "the workflow fixture: rc=${rc}, report: $(tr '\n' '|' <<<"${report}")"
fi

# A file the scanner cannot follow to its end is a finding and not a clean file.
unclosed="${TESTDIR}/unclosed.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf 'an unclosed quote" 'producer | grep -q needle' > "${unclosed}"
rc=0; report="$(python3 "${SCANNER}" "${unclosed}" "${TESTDIR}/absent.sh")" || rc=$?
if (( rc == 1 )) && [[ "$(grep -c ': unparsed: ' <<<"${report}")" == 2 ]]; then
    pass "a file with an unclosed quote and a file that does not exist are each reported as unparsed"
else
    fail "unparsed inputs: rc=${rc}, report: $(tr '\n' '|' <<<"${report}")"
fi

# ── The tree ─────────────────────────────────────────────────────────────────
# Every shell file and workflow: a `.sh` or `.yml` name, or a first line naming sh or bash. A library does not set
# pipefail and runs under its caller's, so the options a file sets do not decide whether it is read. packaging/rpmbuild
# is build output. An image's test tree holds part of these roots, so one that is absent is left out and the controls
# under the walk still have to hold.
# list_walked_files <root> : print, NUL-separated, each candidate file under the roots the walk reads, and return find's
# status: a subtree that could not be listed fails the walk, where a discarded status would leave its files unread.
list_walked_files() {
    local root="$1" name
    local -a roots=()
    for name in src selinux packaging tools install.sh .github/workflows; do
        [[ ! -e "${root}/${name}" ]] || roots+=("${name}")
    done
    (cd "${root}" && find "${roots[@]}" -name rpmbuild -prune -o \
        -type f '(' -name '*.sh' -o -name '*.yml' -o ! -name '*.*' ')' -print0)
}

# Root reads through a directory's mode, so the walk's failure is driven as an unprivileged caller alone.
if [[ "${EUID}" -ne 0 ]]; then
    mkdir -p "${TESTDIR}/partial/src/readable" "${TESTDIR}/partial/src/closed"
    : > "${TESTDIR}/partial/src/readable/a.sh"; : > "${TESTDIR}/partial/src/closed/b.sh"
    chmod 000 "${TESTDIR}/partial/src/closed"
    rc=0; list_walked_files "${TESTDIR}/partial" > "${TESTDIR}/partial.list" 2>/dev/null || rc=$?
    chmod 755 "${TESTDIR}/partial/src/closed"
    if (( rc != 0 )) && grep -qz 'readable/a.sh' "${TESTDIR}/partial.list"; then
        pass "a walk that listed one subtree and could not list another returns non-zero"
    else
        fail "the partial walk returned ${rc} (want non-zero, with readable/a.sh listed)"
    fi
else
    skip "the walk's failure on an unlistable subtree" "root lists a directory whatever its mode"
fi

rc=0; list_walked_files "${ROOT}" > "${TESTDIR}/walk.list" 2>"${TESTDIR}/walk.err" || rc=$?
if (( rc != 0 )); then
    fail "the walk over ${ROOT} exited ${rc}, so files were left unread: $(head -c 300 "${TESTDIR}/walk.err" | tr '\n' '|')"
    finish; exit 1
fi
files=()
while IFS= read -r -d '' path; do
    if [[ "${path}" != *.sh && "${path}" != *.yml ]]; then
        IFS= read -r first_line < "${ROOT}/${path}" 2>/dev/null || first_line=""
        [[ "${first_line}" =~ ^'#!'.*[/[:space:]](ba)?sh([[:space:]]|$) ]] || continue
    fi
    files+=("${path}")
done < "${TESTDIR}/walk.list"

if [[ " ${files[*]} " != *" src/usr/local/bin/ai-tools.sh "* ]]; then
    fail "the file list does not hold src/usr/local/bin/ai-tools.sh (${#files[@]} files): the tree was not read"
    finish; exit 1
fi
if [[ -d "${ROOT}/.github/workflows" && " ${files[*]} " != *" .github/workflows/"*".yml "* ]]; then
    fail "the file list does not hold a workflow although .github/workflows exists"
    finish; exit 1
fi
# Exit 1 is the findings' status and carries a report; any other pairing of status and report is the scanner failing,
# which is not a clean tree.
rc=0; report="$(cd "${ROOT}" && python3 "${SCANNER}" "${files[@]}" 2>"${TESTDIR}/scanner.err")" || rc=$?
if (( rc == 0 )) && [[ -z "${report}" ]]; then
    pass "${#files[@]} shell files and workflows: no stage after a pipe is an early-exit reader"
elif (( rc == 1 )) && [[ -n "${report}" ]]; then
    while IFS= read -r finding; do
        fail "${finding} -- capture the producer's output and search the capture"
    done <<<"${report}"
else
    fail "the scanner exited ${rc} over the tree with $(wc -l <<<"${report}") report line(s): $(head -c 300 "${TESTDIR}/scanner.err" | tr '\n' '|')"
fi

finish

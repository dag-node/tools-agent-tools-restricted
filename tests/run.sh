#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# `tests/run.sh [-j N] [unit|integration|boundary|all]`: test dispatcher. Runs the chosen category's test files
# and aggregates pass/fail by exit status. On any failure it reprints the failing files' FAIL lines as an end-of-run
# summary, so a long run does not need scrolling; an all-green run omits the summary. Run via sudo: every category needs
# root (unit/integration set arbitrary ownership and run the deployed helpers; boundary drops to the agent
# via `sudo -u`).
#
# Categories (see .claude/rules/tests.rule.md):
#   unit         hermetic helper-logic tests (/tmp testdir + dummy allowlist; no live daemon)
#   integration  full-install checks (deployed perms, sudoers, wrapper, handback daemon, systemd)
#   boundary     confinement checks run as the agent (SANDBOX_USER)
#   all          every category
#
# A green exit proves coverage only when something PASSed: a file whose run recorded zero passes (every check skipped,
# or no harness result line at all) and a category with no test files are listed in an end-of-run "no coverage" notice.
# The default stays lenient -- a partial/dev install legitimately skips -- and AI_TOOLS_TEST_STRICT=1 turns the notice
# into a failure, the mode the full-install CI gate runs.
#
# Before any category runs, the residue sweep (lib/residue.sh) removes what an earlier run left behind -- every path
# named by the harness's fixture rule in the places fixtures are born, and the one fixed-name probe -- and reports each
# removal; a leftover it cannot remove refuses the run. `run.sh residue` runs the sweep alone.
#
# `-j N` runs up to N files at once, 4 by default, the CPU count of a GitHub-hosted runner; the container selftest
# passes the CPU count it reads with `nproc`. `-j 1` runs them one after another and streams each file's output live.
# Above 1 the files run in two passes. The pool takes every file that does not carry the serial marker, largest first
# by byte count, since the slowest files are the largest; each writes its output to a transcript of its own, and one
# line reports each file as it finishes (the result word, the file, the seconds it took). The serial pass then runs one
# file at a time, in category and name order, every file carrying the line
#
#   # run.sh: serial
#
# in its header, because it touches host state another file reads -- a fixed path in the live toolchain or launcher
# directory, the live daemon, the cgroup root, the installed layout -- and after them the one file carrying
# `# run.sh: serial last`, integration/selinux.sh, whose clone label cases skip while any process of the sandbox account
# is live, as the pool's files leave one while they run. A second `serial last` file is a usage error before any file
# runs. At the end the run prints the transcript of each failed file in category and name order, then the failure
# summary and the no-coverage notice, read from the transcripts as a run of one at a time reads them. The transcripts
# are written under AI_TOOLS_TEST_TRANSCRIPTS when it is set, which is kept, and otherwise under a /tmp directory named
# by the harness's fixture rule (group `run`), which is kept when a file failed or the notice fired and removed
# on an all-green run; the next run's residue sweep removes a kept one.

set -uo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "usage: run.sh [-j N] [unit|integration|boundary|all|residue]" >&2; exit 2; }
JOBS=4
while (( $# > 0 )); do
    case "$1" in
        -j)  (( $# >= 2 )) || usage; JOBS="$2"; shift 2 ;;
        -j*) JOBS="${1#-j}"; shift ;;
        --)  shift; break ;;
        -*)  usage ;;
        *)   break ;;
    esac
done
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || usage
readonly JOBS
mode="${1:-all}"
# Per-file wall-clock budget. AI_TOOLS_TEST_FILE_TIMEOUT overrides it for a slow host.
readonly FILE_TIMEOUT="${AI_TOOLS_TEST_FILE_TIMEOUT:-600}"

[[ "${EUID}" -eq 0 ]] || { echo "error: run with sudo (tests need root)" >&2; exit 1; }
[[ -n "${SUDO_USER:-}" ]] || { echo "error: invoke via sudo, not as root directly" >&2; exit 1; }

# The pool's file list: every file of the chosen categories in category and name order, each with the pass it runs
# in (`pool`, `serial`, `last`, from its marker line). Collected before the residue sweep, so a usage error leaves
# the host as it was.
declare -a _categories=() _file_names=() _file_paths=() _file_categories=() _file_kinds=()
declare -A _category_missing=()
collect_files() {
    local category f marker kind
    for category in "${_categories[@]}"; do
        if [[ ! -d "${HERE}/${category}" ]]; then _category_missing["${category}"]=1; continue; fi
        for f in "${HERE}/${category}"/*.sh; do
            [[ -e "${f}" ]] || continue
            marker="$(grep -m1 -xE '# run\.sh: serial( last)?' "${f}" || true)"
            case "${marker}" in
                '')    kind=pool ;;
                *last) kind=last ;;
                *)     kind=serial ;;
            esac
            _file_names+=("${category}/${f##*/}"); _file_paths+=("${f}")
            _file_categories+=("${category}"); _file_kinds+=("${kind}")
        done
    done
}
if (( JOBS > 1 )); then
    case "${mode}" in
        unit|integration|boundary) _categories=("${mode}") ;;
        all)                       _categories=(unit integration boundary) ;;
        residue)                   ;;
        *)                         usage ;;
    esac
    collect_files
    _last_files=()
    for i in "${!_file_names[@]}"; do [[ "${_file_kinds[i]}" == last ]] && _last_files+=("${_file_names[i]}"); done
    if (( ${#_last_files[@]} > 1 )); then
        echo "error: more than one file carries '# run.sh: serial last': ${_last_files[*]}" >&2
        usage
    fi
fi

# shellcheck source=SCRIPTDIR/lib/residue.sh
source "${HERE}/lib/residue.sh"
_projects_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
if ! ai_test_residue_sweep "${_projects_home}"; then
    echo "error: an earlier run's residue could not be removed; not starting" >&2
    exit 1
fi
[[ "${mode}" == residue ]] && exit 0

# Each test file's stdout is a pipe here (tee, or a transcript under `-j`), so the harness's own tty test cannot see
# the terminal reading this run. Pass the verdict down instead, and colour this file's own lines from the same answer.
if [[ -t 1 ]]; then export AI_TOOLS_TEST_COLOR=1; fi
if [[ "${AI_TOOLS_TEST_COLOR:-0}" == "1" ]]; then
    _C_PASS=$'\033[32m' _C_FAIL=$'\033[31m' _C_SKIP=$'\033[33m' _C_OFF=$'\033[0m'
else
    _C_PASS='' _C_FAIL='' _C_SKIP='' _C_OFF=''
fi
# The harness prefixes the result word with a colour escape, so the summary's grep allows one before FAIL. Anchored
# without it, the summary would silently come back empty on a coloured run.
_FAIL_RE="^[[:space:]]*($(printf '\033')\[[0-9;]*m)?FAIL"
readonly _FAIL_RE

rc=0
declare -a _failed=()                 # "category/file" of each test file that failed
declare -a _nocoverage=()             # green files with zero PASSes; categories with no files
_summary="$(mktemp)"                  # accumulates the FAIL lines, grouped by file
_transcripts=""                       # the -j transcript directory
trap 'rm -f "${_summary}"' EXIT

# file_outcome <status> <transcript>: print `failed`, `passed`, or `nocoverage <reason>` for one finished file. A green
# exit proves coverage only when something PASSed: classify from the harness finish() line (the only line matching this
# shape).
file_outcome() {
    local re='^[[:space:]]*([0-9]+) passed, [0-9]+ failed, ([0-9]+) skipped$' line
    if [[ "$1" -ne 0 ]]; then printf 'failed'; return 0; fi
    line="$(grep -E "${re}" "$2" | tail -1)"
    if [[ ! "${line}" =~ ${re} ]]; then
        printf 'nocoverage no result summary'
    elif [[ "${BASH_REMATCH[1]}" -gt 0 ]]; then
        printf 'passed'
    else
        printf 'nocoverage 0 passed, %s skipped' "${BASH_REMATCH[2]}"
    fi
}

# record_result <name> <status> <transcript>: fold one finished file into the run's status, the failure summary
# and the no-coverage notice.
record_result() {
    local outcome
    outcome="$(file_outcome "$2" "$3")"
    case "${outcome}" in
        failed)
            rc=1
            _failed+=("$1")
            { printf '\n%s\n' "$1"; grep -E "${_FAIL_RE}" "$3" || true; } >> "${_summary}" ;;
        nocoverage*)
            _nocoverage+=("$1 (${outcome#nocoverage })") ;;
    esac
}

run_dir() {
    local dir="${HERE}/$1" f name out st ran=0
    if [[ ! -d "${dir}" ]]; then _nocoverage+=("$1/ (no test files)"); return 0; fi
    for f in "${dir}"/*.sh; do
        [[ -e "${f}" ]] || continue
        ran=$(( ran + 1 ))
        name="$1/$(basename "${f}")"
        printf '\n══════ %s ══════\n' "${name}"
        # Stream output live (tee) while capturing it, so a failed file's FAIL lines can be reprinted in the end-of-run
        # summary. PIPESTATUS[0] is the test's status, not tee's.
        out="$(mktemp)"
        # BOUNDED IN TIME. A test file that blocks -- on a terminal read, on a wedged daemon, on a fixture process
        # holding a pipe open -- otherwise hangs the whole run with no output and no exit, and this suite is run
        # by `install.sh` as its verification phase, so a hung file stalls an install. `timeout` makes that a FAILED
        # file with a diagnosable transcript instead. The budget is per file and generous: the slowest legitimate file
        # drives a ten-second graceful stop and waits on real processes.
        timeout --foreground "${FILE_TIMEOUT}" bash "${f}" 2>&1 | tee "${out}"
        st="${PIPESTATUS[0]}"
        if [[ "${st}" -eq 124 ]]; then
            printf '  FAIL  %s did not finish within %ss -- killed\n' "${name}" "${FILE_TIMEOUT}"
            printf '  FAIL  %s did not finish within %ss -- killed\n' "${name}" "${FILE_TIMEOUT}" \
                >> "${out}"
        fi
        record_result "${name}" "${st}" "${out}"
        rm -f "${out}"
    done
    [[ "${ran}" -gt 0 ]] || _nocoverage+=("$1/ (no test files)")
}

# ── The `-j` passes ──────────────────────────────────────────────────────────────────────────────────────────────────
declare -A _running=()                # pid of a running file's timeout -> its index
declare -a _file_status=() _file_started=()

transcript_of() { printf '%s/%s.log' "${_transcripts}" "${_file_names[$1]//\//-}"; }

# start_file <index>: run one file in the background, its output to its transcript. Without `--foreground`, `timeout`
# runs the file in a process group of its own and signals the whole group at the budget, so a fixture process the file
# left behind ends with it; the harness EXIT trap still runs on the SIGTERM.
start_file() {
    timeout "${FILE_TIMEOUT}" bash "${_file_paths[$1]}" < /dev/null > "$(transcript_of "$1")" 2>&1 &
    _running[$!]="$1"
    _file_started[$1]="${SECONDS}"
}

# reap_file: wait for the next running file to end and print its line.
reap_file() {
    local pid="" st=0 i outcome word colour detail=""
    wait -n -p pid || st=$?
    [[ -n "${pid}" && -n "${_running[${pid}]+x}" ]] || return 0
    i="${_running[${pid}]}"
    unset "_running[${pid}]"
    _file_status[i]="${st}"
    if [[ "${st}" -eq 124 ]]; then
        detail="  (did not finish within ${FILE_TIMEOUT}s -- killed)"
        printf '  FAIL  %s did not finish within %ss -- killed\n' "${_file_names[i]}" "${FILE_TIMEOUT}" \
            >> "$(transcript_of "${i}")"
    fi
    outcome="$(file_outcome "${st}" "$(transcript_of "${i}")")"
    case "${outcome}" in
        failed)      word=FAIL colour="${_C_FAIL}" ;;
        passed)      word=PASS colour="${_C_PASS}" ;;
        *)           word=SKIP colour="${_C_SKIP}"; detail="  (${outcome#nocoverage })" ;;
    esac
    printf '  %s%s%s  %s  %ss%s\n' "${colour}" "${word}" "${_C_OFF}" "${_file_names[i]}" \
        "$(( SECONDS - _file_started[i] ))" "${detail}"
}

# stop_files: on an interrupt, end every running file through its timeout, which passes the signal to the file's group.
stop_files() {
    local pid
    for pid in "${!_running[@]}"; do kill -TERM "${pid}" 2>/dev/null; done
    wait
    exit 130
}

run_passes() {
    local i category ran
    local -a pool_order=() serial_order=() last_order=()
    if [[ -n "${AI_TOOLS_TEST_TRANSCRIPTS:-}" ]]; then
        _transcripts="${AI_TOOLS_TEST_TRANSCRIPTS}"
        mkdir -p -- "${_transcripts}" || { echo "error: cannot create ${_transcripts}" >&2; exit 1; }
    else
        _transcripts="$(mktemp -d "/tmp/.ai-tools-test-run-transcripts-XXXXXX")" \
            || { echo "error: cannot create a transcript directory under /tmp" >&2; exit 1; }
    fi
    for i in "${!_file_names[@]}"; do
        case "${_file_kinds[i]}" in
            serial) serial_order+=("${i}") ;;
            last)   last_order+=("${i}") ;;
        esac
    done
    mapfile -t pool_order < <(
        for i in "${!_file_names[@]}"; do
            [[ "${_file_kinds[i]}" == pool ]] || continue
            printf '%s\t%s\t%s\n' "$(wc -c < "${_file_paths[i]}")" "${_file_names[i]}" "${i}"
        done | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 | cut -f3)
    printf '\n══════ %d files, up to %d at a time; %d serial after them ══════\n' \
        "${#pool_order[@]}" "${JOBS}" "$(( ${#serial_order[@]} + ${#last_order[@]} ))"
    trap stop_files INT TERM
    for i in "${pool_order[@]}"; do
        while (( ${#_running[@]} >= JOBS )); do reap_file; done
        start_file "${i}"
    done
    while (( ${#_running[@]} > 0 )); do reap_file; done
    for i in "${serial_order[@]}" "${last_order[@]}"; do
        start_file "${i}"
        reap_file
    done
    trap - INT TERM

    # Each failed file's transcript, in category and name order.
    for i in "${!_file_names[@]}"; do
        [[ "${_file_status[i]:-0}" -ne 0 ]] || continue
        printf '\n══════ %s ══════\n' "${_file_names[i]}"
        cat -- "$(transcript_of "${i}")"
    done
    # The results fold in the order a run of one at a time folds them.
    for category in "${_categories[@]}"; do
        ran=0
        for i in "${!_file_names[@]}"; do
            [[ "${_file_categories[i]}" == "${category}" ]] || continue
            ran=$(( ran + 1 ))
            record_result "${_file_names[i]}" "${_file_status[i]}" "$(transcript_of "${i}")"
        done
        if [[ -n "${_category_missing[${category}]:-}" || "${ran}" -eq 0 ]]; then
            _nocoverage+=("${category}/ (no test files)")
        fi
    done
}

if (( JOBS > 1 )); then
    run_passes
else
    case "${mode}" in
        unit)        run_dir unit ;;
        integration) run_dir integration ;;
        boundary)    run_dir boundary ;;
        all)         run_dir unit; run_dir integration; run_dir boundary ;;
        *) usage ;;
    esac
fi

# Failure summary: which files failed and their FAIL lines, so a long run does not have to be scrolled. Printed only
# when something failed; an all-green run stays quiet.
if [[ "${rc}" -ne 0 ]]; then
    printf '\n══════ failures (%d file%s) ══════\n' \
        "${#_failed[@]}" "$([[ "${#_failed[@]}" -eq 1 ]] || echo s)"
    cat "${_summary}"
fi

# No-coverage notice: green-by-status files with no assertion behind them, and empty categories. Lenient by default;
# AI_TOOLS_TEST_STRICT=1 (the full-install CI gate) fails the run, so a broken prerequisite cannot hide behind skips.
if [[ ${#_nocoverage[@]} -gt 0 ]]; then
    printf '\n══════ no coverage (%d) ══════\n' "${#_nocoverage[@]}"
    printf '  %s\n' "${_nocoverage[@]}"
    if [[ "${AI_TOOLS_TEST_STRICT:-0}" == "1" ]]; then
        printf '  AI_TOOLS_TEST_STRICT=1: no-coverage is a failure\n'
        rc=1
    fi
fi

if [[ -n "${_transcripts}" ]]; then
    if [[ "${rc}" -ne 0 || ${#_nocoverage[@]} -gt 0 || -n "${AI_TOOLS_TEST_TRANSCRIPTS:-}" ]]; then
        printf '\n  transcripts: %s\n' "${_transcripts}"
    else
        rm -rf -- "${_transcripts}"
    fi
fi

if [[ ${rc} -eq 0 ]]; then
    printf '\n══════ overall: %sPASS%s ══════\n' "${_C_PASS}" "${_C_OFF}"
else
    printf '\n══════ overall: %sFAIL%s ══════\n' "${_C_FAIL}" "${_C_OFF}"
fi
exit "${rc}"

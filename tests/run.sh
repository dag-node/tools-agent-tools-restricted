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
# line reports each file as it finishes (the result word, the file, its passed checks over all it ran, and the time it
# took). The serial pass then runs one file at a time, in category and name order, every file carrying the line
#
#   # run.sh: serial
#
# in its header, because it touches host state another file reads -- a fixed path in the live toolchain or launcher
# directory, the live daemon, the cgroup root, the installed layout -- and after them the one file carrying
# `# run.sh: serial last`, integration/selinux.sh, whose clone label cases skip while any process of the sandbox account
# is live, as the pool's files leave one while they run. A second `serial last` file is a usage error before any file
# runs. At the end the run prints the transcript of each failed file in category and name order.
#
# Every run then closes with the NOTE rows, the SKIP rows, the no-coverage notice and the failure summary,
# in that order, the rows grouped by file, so the failures sit beside the overall line. AI_TOOLS_TEST_TRANSCRIPTS names
# a directory the run creates, under either `-j`, and keeps: each file's transcript, results.tsv (one row per file: its
# result, its passed, failed and skipped counts, its milliseconds) and run-info.txt (when the run started and finished,
# its result and command, the host, the OS, the kernel, the checkout's commit and the installed release). A pooled run
# without it writes under a /tmp directory named by the harness's fixture rule (group `run`), kept with the same two
# files when a file failed or the notice fired and removed on an all-green run; the next run's residue sweep removes
# a kept one.

# The body is one brace group, so bash parses the whole file before it runs a line of it. A script is otherwise read
# as it runs, and a checkout rewritten under a live run -- a formatter, a commit, a branch switch -- has the running
# bash read the new file from the old offset and fail mid-run on a syntax error the file does not contain.
{
set -uo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_run_command="run.sh $*"
_run_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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

# AI_TOOLS_TEST_TRANSCRIPTS names a directory this run creates and keeps: an absolute path that does not exist
# yet, under a directory that does. The create is exclusive, so a name another account placed there first, a symlink
# included, fails it rather than taking root's writes.
_results_dir="${AI_TOOLS_TEST_TRANSCRIPTS:-}"
if [[ -n "${_results_dir}" ]] && [[ "${_results_dir}" != /* || -e "${_results_dir}" || -L "${_results_dir}" \
        || ! -d "${_results_dir%/*}/" ]]; then
    echo "error: AI_TOOLS_TEST_TRANSCRIPTS must name a directory that does not exist yet, under one that does: ${_results_dir}" >&2
    usage
fi

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
_SKIP_RE="^[[:space:]]*($(printf '\033')\[[0-9;]*m)?SKIP"
_NOTE_RE="^[[:space:]]*($(printf '\033')\[[0-9;]*m)?NOTE"
readonly _FAIL_RE _SKIP_RE _NOTE_RE

rc=0
declare -a _failed=()                 # "category/file" of each test file that failed
declare -a _nocoverage=()             # green files with zero PASSes; categories with no files
_summary="$(mktemp)"                  # accumulates the FAIL lines, grouped by file
_skipped="$(mktemp)"                  # the SKIP lines, grouped by file
_notes="$(mktemp)"                    # the NOTE lines, grouped by file
declare -i _skip_rows=0 _skip_files=0 _note_rows=0 _note_files=0
declare -a _result_rows=()            # one results.tsv row per file, in category and name order
trap 'rm -f "${_summary}" "${_skipped}" "${_notes}"' EXIT
_transcripts=""                       # the directory each file's transcript is kept in
if [[ -n "${_results_dir}" ]]; then
    mkdir -m 0755 -- "${_results_dir}" || { echo "error: cannot create ${_results_dir}" >&2; exit 1; }
    _transcripts="${_results_dir}"
elif (( JOBS > 1 )); then
    _transcripts="$(mktemp -d "/tmp/.ai-tools-test-run-transcripts-XXXXXX")" \
        || { echo "error: cannot create a transcript directory under /tmp" >&2; exit 1; }
fi
transcript_path() { printf '%s/%s.log' "${_transcripts}" "${1//\//-}"; }

# file_outcome <status> <transcript>: print `failed`, `passed`, or `nocoverage <reason>` for one finished file. A green
# exit proves coverage only when something PASSed: classify from the harness finish() line (the only line matching this
# shape).
_FINISH_RE='^[[:space:]]*([0-9]+) passed, ([0-9]+) failed, ([0-9]+) skipped$'
readonly _FINISH_RE
file_outcome() {
    local line
    if [[ "$1" -ne 0 ]]; then printf 'failed'; return 0; fi
    line="$(grep -E "${_FINISH_RE}" "$2" | tail -1)"
    if [[ ! "${line}" =~ ${_FINISH_RE} ]]; then
        printf 'nocoverage no result summary'
    elif [[ "${BASH_REMATCH[1]}" -gt 0 ]]; then
        printf 'passed'
    else
        printf 'nocoverage 0 passed, %s skipped' "${BASH_REMATCH[3]}"
    fi
}

# format_elapsed <ms>: the time a file took, as `N ms` under a second, and from a second up as two decimals
# in the largest unit it reaches -- `s`, `min`, `h` -- truncated, with the exact milliseconds after it:
# `1.22 min (73200 ms)`.
format_elapsed() {
    local ms="$1" unit_ms unit hundredths
    if (( ms < 1000 )); then printf '%d ms' "${ms}"; return 0; fi
    if (( ms < 60000 )); then unit_ms=1000 unit=s
    elif (( ms < 3600000 )); then unit_ms=60000 unit=min
    else unit_ms=3600000 unit=h
    fi
    hundredths=$(( ms * 100 / unit_ms ))
    printf '%d.%02d %s (%d ms)' "$(( hundredths / 100 ))" "$(( hundredths % 100 ))" "${unit}" "${ms}"
}

# read_counts <transcript>: print `<passed>/<total>` from the harness finish() line, the total counting the passed,
# failed and skipped checks; `?/?` for a file that did not print the line, one killed at its budget among them.
read_counts() {
    local line
    line="$(grep -E "${_FINISH_RE}" "$1" | tail -1)"
    if [[ "${line}" =~ ${_FINISH_RE} ]]; then
        printf '%s/%s' "${BASH_REMATCH[1]}" "$(( BASH_REMATCH[1] + BASH_REMATCH[2] + BASH_REMATCH[3] ))"
    else
        printf '?/?'
    fi
}

# result_word <outcome>: the word a file's line and its results.tsv row carry for a file_outcome.
result_word() {
    case "$1" in
        failed) printf 'FAIL' ;;
        passed) printf 'PASS' ;;
        *)      printf 'SKIP' ;;
    esac
}

# collect_rows <name> <transcript> <regex> <file> <rows-var> <files-var>: append the transcript's lines matching <regex>
# to <file> under the file's name, and count them.
collect_rows() {
    local -n _collect_rows_count="$5" _collect_files_count="$6"
    local rows
    rows="$(grep -E "$3" "$2" || true)"
    [[ -n "${rows}" ]] || return 0
    printf '\n%s\n%s\n' "$1" "${rows}" >> "$4"
    (( _collect_rows_count += $(grep -c '' <<< "${rows}") ))
    (( _collect_files_count += 1 ))
}

# record_result <name> <status> <transcript> <ms>: fold one finished file into the run's status, the failure summary,
# the skipped and notes blocks, the no-coverage notice and its results.tsv row.
record_result() {
    local outcome line passed="" failed="" skipped="" detail=""
    outcome="$(file_outcome "$2" "$3")"
    case "${outcome}" in
        failed)
            rc=1
            _failed+=("$1")
            { printf '\n%s\n' "$1"; grep -E "${_FAIL_RE}" "$3" || true; } >> "${_summary}" ;;
        nocoverage*)
            _nocoverage+=("$1 (${outcome#nocoverage })")
            detail="${outcome#nocoverage }" ;;
    esac
    [[ "$2" -ne 124 ]] || detail="did not finish within ${FILE_TIMEOUT}s -- killed"
    line="$(grep -E "${_FINISH_RE}" "$3" | tail -1)"
    [[ ! "${line}" =~ ${_FINISH_RE} ]] \
        || { passed="${BASH_REMATCH[1]}"; failed="${BASH_REMATCH[2]}"; skipped="${BASH_REMATCH[3]}"; }
    collect_rows "$1" "$3" "${_SKIP_RE}" "${_skipped}" _skip_rows _skip_files
    collect_rows "$1" "$3" "${_NOTE_RE}" "${_notes}" _note_rows _note_files
    _result_rows+=("$1"$'\t'"$(result_word "${outcome}")"$'\t'"${passed}"$'\t'"${failed}"$'\t'"${skipped}"$'\t'"$4"$'\t'"${detail}")
}

run_dir() {
    local dir="${HERE}/$1" f name out st ran=0 started
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
        started="${EPOCHREALTIME//[!0-9]/}"
        timeout --foreground "${FILE_TIMEOUT}" bash "${f}" 2>&1 | tee "${out}"
        st="${PIPESTATUS[0]}"
        if [[ "${st}" -eq 124 ]]; then
            printf '  FAIL  %s did not finish within %ss -- killed\n' "${name}" "${FILE_TIMEOUT}"
            printf '  FAIL  %s did not finish within %ss -- killed\n' "${name}" "${FILE_TIMEOUT}" \
                >> "${out}"
        fi
        record_result "${name}" "${st}" "${out}" "$(( (${EPOCHREALTIME//[!0-9]/} - started) / 1000 ))"
        if [[ -n "${_transcripts}" ]]; then mv -- "${out}" "$(transcript_path "${name}")"; else rm -f "${out}"; fi
    done
    [[ "${ran}" -gt 0 ]] || _nocoverage+=("$1/ (no test files)")
}

# ── The `-j` passes ──────────────────────────────────────────────────────────────────────────────────────────────────
declare -A _running=()                # pid of a running file's timeout -> its index
declare -a _file_status=() _file_started=() _file_ms=()

transcript_of() { transcript_path "${_file_names[$1]}"; }

# start_file <index>: run one file in the background, its output to its transcript. Without `--foreground`, `timeout`
# runs the file in a process group of its own and signals the whole group at the budget, so a fixture process the file
# left behind ends with it; the harness EXIT trap still runs on the SIGTERM.
start_file() {
    timeout "${FILE_TIMEOUT}" bash "${_file_paths[$1]}" < /dev/null > "$(transcript_of "$1")" 2>&1 &
    _running[$!]="$1"
    # Microseconds: EPOCHREALTIME with the locale's decimal separator removed.
    _file_started[$1]="${EPOCHREALTIME//[!0-9]/}"
}

# reap_file: wait for the next running file to end and print its line.
reap_file() {
    local pid="" st=0 i outcome colour detail="" ended
    wait -n -p pid || st=$?
    ended="${EPOCHREALTIME//[!0-9]/}"
    [[ -n "${pid}" && -n "${_running[${pid}]+x}" ]] || return 0
    i="${_running[${pid}]}"
    unset "_running[${pid}]"
    _file_status[i]="${st}"
    _file_ms[i]=$(( (ended - _file_started[i]) / 1000 ))
    if [[ "${st}" -eq 124 ]]; then
        detail="  (did not finish within ${FILE_TIMEOUT}s -- killed)"
        printf '  FAIL  %s did not finish within %ss -- killed\n' "${_file_names[i]}" "${FILE_TIMEOUT}" \
            >> "$(transcript_of "${i}")"
    fi
    outcome="$(file_outcome "${st}" "$(transcript_of "${i}")")"
    case "${outcome}" in
        failed)      colour="${_C_FAIL}" ;;
        passed)      colour="${_C_PASS}" ;;
        *)           colour="${_C_SKIP}" ;;
    esac
    printf '  %s%s%s  %s  %s in %s%s\n' "${colour}" "$(result_word "${outcome}")" "${_C_OFF}" "${_file_names[i]}" \
        "$(read_counts "$(transcript_of "${i}")")" "$(format_elapsed "${_file_ms[i]}")" "${detail}"
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
            record_result "${_file_names[i]}" "${_file_status[i]}" "$(transcript_of "${i}")" "${_file_ms[i]}"
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

# plural <count> <word>: `<count> <word>`, with an `s` past one.
plural() { printf '%d %s%s' "$1" "$2" "$([[ "$1" -eq 1 ]] || echo s)"; }

# The NOTE and the SKIP rows, grouped by file: what the run recorded beside a verdict, then what it did not check.
if (( _note_rows > 0 )); then
    printf '\n══════ notes (%s in %s) ══════\n' "$(plural "${_note_rows}" row)" "$(plural "${_note_files}" file)"
    cat "${_notes}"
fi
if (( _skip_rows > 0 )); then
    printf '\n══════ skipped (%s in %s) ══════\n' "$(plural "${_skip_rows}" row)" "$(plural "${_skip_files}" file)"
    cat "${_skipped}"
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

# Failure summary: which files failed and their FAIL lines, printed last of the blocks, beside the overall line,
# so a long run does not have to be scrolled. Printed only when a file failed; an all-green run stays quiet.
if [[ ${#_failed[@]} -gt 0 ]]; then
    printf '\n══════ failures (%d file%s) ══════\n' \
        "${#_failed[@]}" "$([[ "${#_failed[@]}" -eq 1 ]] || echo s)"
    cat "${_summary}"
fi

# read_checkout_commit: print `<commit> <ref>` for the checkout holding this runner, read from its .git as data,
# or `unknown`. The runner is root and the checkout is a tree the sandbox account co-writes, so git itself is not run
# over it: its config may name a command. A tree with uncommitted changes reads as the commit it is on.
read_checkout_commit() {
    local root="${HERE%/tests}" git_dir common head ref line f
    git_dir="${root}/.git"
    if [[ -f "${git_dir}" ]]; then
        line="$(head -n1 -- "${git_dir}")"; git_dir="${line#gitdir: }"
        [[ "${git_dir}" == /* ]] || git_dir="${root}/${git_dir}"
    fi
    [[ -r "${git_dir}/HEAD" ]] || { printf 'unknown'; return 0; }
    head="$(head -n1 -- "${git_dir}/HEAD")"
    if [[ "${head}" =~ ^[0-9a-f]{40,64}$ ]]; then printf '%s detached' "${head}"; return 0; fi
    ref="${head#ref: }"
    [[ "${ref}" =~ ^refs/[A-Za-z0-9._/-]+$ ]] || { printf 'unknown'; return 0; }
    common="${git_dir}"
    if [[ -r "${git_dir}/commondir" ]]; then
        line="$(head -n1 -- "${git_dir}/commondir")"
        if [[ "${line}" == /* ]]; then common="${line}"; else common="${git_dir}/${line}"; fi
    fi
    for f in "${git_dir}/${ref}" "${common}/${ref}"; do
        [[ -r "${f}" ]] || continue
        line="$(head -n1 -- "${f}")"
        [[ "${line}" =~ ^[0-9a-f]{40,64}$ ]] && { printf '%s %s' "${line}" "${ref}"; return 0; }
    done
    line="$(awk -v r="${ref}" '$2 == r { print $1; exit }' "${common}/packed-refs" 2>/dev/null || true)"
    if [[ "${line}" =~ ^[0-9a-f]{40,64}$ ]]; then printf '%s %s' "${line}" "${ref}"; else printf 'unknown'; fi
}

# write_run_info <file>: the run's KEY=value record, each value reduced to printable characters: when it ran,
# where, how it was invoked, and what it tested -- the checkout's commit and the installed release.
write_run_info() {
    local key value
    while IFS=$'\t' read -r key value; do
        printf '%s=%s\n' "${key}" "$(printf '%s' "${value}" | tr -cd '[:print:]')"
    done > "$1" < <(
        printf 'started\t%s\n' "${_run_started}"
        printf 'finished\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'result\t%s\n' "$([[ "${rc}" -eq 0 ]] && echo PASS || echo FAIL)"
        printf 'command\t%s\n' "${_run_command}"
        printf 'jobs\t%s\n' "${JOBS}"
        printf 'strict\t%s\n' "${AI_TOOLS_TEST_STRICT:-0}"
        printf 'file_timeout\t%s\n' "${FILE_TIMEOUT}"
        printf 'host\t%s\n' "$(uname -n)"
        printf 'os\t%s\n' "$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}") || printf unknown)"
        printf 'kernel\t%s\n' "$(uname -r)"
        printf 'checkout\t%s\n' "$(read_checkout_commit)"
        printf 'installed_cli\t%s\n' \
            "$(sed -n 's/^AI_TOOLS_VERSION="\([^"]*\)"$/\1/p' /usr/local/bin/ai-tools 2>/dev/null | head -n1)"
        printf 'installed_package\t%s\n' \
            "$(rpm -q --qf '%{VERSION}-%{RELEASE}' ai-tools-base 2>/dev/null || printf 'not installed by rpm')"
        printf 'files\t%s\n' "${#_result_rows[@]}"
        printf 'failed_files\t%s\n' "${#_failed[@]}"
    )
}

# The transcript directory: kept where AI_TOOLS_TEST_TRANSCRIPTS named it, or where a file failed or the notice fired,
# with results.tsv (one row per file) and run-info.txt beside the transcripts; otherwise removed.
if [[ -n "${_transcripts}" ]]; then
    if [[ -n "${_results_dir}" || "${rc}" -ne 0 || ${#_nocoverage[@]} -gt 0 ]]; then
        { printf 'file\tresult\tpassed\tfailed\tskipped\tms\tdetail\n'; printf '%s\n' "${_result_rows[@]}"; } \
            > "${_transcripts}/results.tsv"
        write_run_info "${_transcripts}/run-info.txt"
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
}

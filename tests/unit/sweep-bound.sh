#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/sweep-bound.sh
# Unit test for the bound the Stop sweep puts on its walk: the session sweep every agent's hook runs selects the paths
# whose status changed since the sweep marker (`find -cnewer`), so a file moved into the project -- renamed within one
# filesystem, or moved from another -- is selected though its mtime is older than the marker. The live chain runs only
# inside a claimed project (tests/manual/verify-live-flows.sh), so this file drives the bound's find shape
# over a fixture, with `-newer` as the control that misses both moves, and reads the session sweep library's source
# for the bound it
# carries.
#
# The bound narrows only which sandbox-owned paths a pass offers to ai-tools-chown; the `-user` test and the helper's
# own guard decide what is handed back, so no boundary half is owed here. A directory moved in is the bound's one blind
# spot, since its descendants keep their ctimes: the library's sweep function is run over a moved directory, and must
# offer what is inside it. A stop run through the library sets the marker to its scan start and does not leave another
# file in the state directory, and one killed mid-walk leaves the marker where it was. Runs unprivileged or as root.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "sweep bound: a file moved into the project is selected by status-change time (unit)"

mktestdir
WALKED="${TESTDIR}/project"; OUTSIDE="${TESTDIR}/outside"
mkdir -p "${WALKED}" "${OUTSIDE}"
MARKER="${TESTDIR}/.sweep-marker"

# A file another filesystem holds, for the cross-filesystem move. The projects user's home is a residue site, and is
# usually not the filesystem /tmp is.
OTHER_FS=""
if mk_fixture_dir OTHER_FS "${PROJECTS_HOME}" sweepbound 2>/dev/null \
        && [[ "$(stat -c '%d' "${OTHER_FS}")" != "$(stat -c '%d' "${TESTDIR}")" ]]; then
    :
else
    OTHER_FS=""
fi

# The moved files are written, then dated an hour back, before the marker: their mtime and the marker's order them
# the way a file written earlier elsewhere is ordered.
printf 'kept\n' > "${WALKED}/untouched.txt"
printf 'renamed\n' > "${OUTSIDE}/renamed.txt"
[[ -n "${OTHER_FS}" ]] && printf 'moved\n' > "${OTHER_FS}/moved.txt"
touch -d '-1 hour' "${WALKED}/untouched.txt" "${OUTSIDE}/renamed.txt" ${OTHER_FS:+"${OTHER_FS}/moved.txt"}
sleep 1
touch "${MARKER}"
sleep 1
mv "${OUTSIDE}/renamed.txt" "${WALKED}/"
[[ -n "${OTHER_FS}" ]] && mv "${OTHER_FS}/moved.txt" "${WALKED}/"

# select <test> : the names find selects under the walked tree with <test> against the marker, sorted.
select_by() { find "${WALKED}" -type f "$1" "${MARKER}" -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }
by_ctime="$(select_by -cnewer)"
by_mtime="$(select_by -newer)"

if [[ -f "${WALKED}/renamed.txt" && "$(stat -c '%Y' "${WALKED}/renamed.txt")" -lt "$(stat -c '%Y' "${MARKER}")" ]]; then
    pass "setup: the renamed file is in the tree and its mtime is older than the marker"
else
    fail "setup: the renamed file's state is not the one under test"
fi
if [[ "${by_mtime}" != *renamed.txt* ]]; then
    pass "control: -newer does not select a file renamed into the tree"
else
    fail "control: -newer selected the renamed file (${by_mtime}), so the case below is not evidence"
fi
if [[ "${by_ctime}" == *renamed.txt* ]]; then
    pass "-cnewer selects a file renamed into the tree"
else
    fail "-cnewer missed the renamed file: selected '${by_ctime}'"
fi
if [[ -n "${OTHER_FS}" ]]; then
    if [[ "${by_mtime}" != *moved.txt* ]]; then
        pass "control: -newer does not select a file moved in from another filesystem"
    else
        fail "control: -newer selected the moved file (${by_mtime})"
    fi
    if [[ "${by_ctime}" == *moved.txt* ]]; then
        pass "-cnewer selects a file moved in from another filesystem"
    else
        fail "-cnewer missed the moved file: selected '${by_ctime}'"
    fi
else
    skip "a move from another filesystem" "no writable directory on a filesystem other than ${TESTDIR}'s"
fi
if [[ "${by_ctime}" != *untouched.txt* ]]; then
    pass "-cnewer does not select a file untouched since before the marker"
else
    fail "-cnewer selected the untouched file: '${by_ctime}'"
fi

# ── A directory moved into the tree ──────────────────────────────────────────────────────────────────────────────────
# A directory moved in takes a new ctime and its descendants keep theirs, so the bound alone selects the directory
# and not the file inside it. The sweep walks a directory its bounded pass selects once more without the bound. Its
# function is sourced from a copy of the checkout's libraries, with the walked owner -- the invoker -- substituted
# for the sandbox account as install.sh substitutes it, and called over the fixture with the handback client replaced
# by a stub recording each path it is offered, its socket a socket the test binds, the skip expression stubbed to prune
# `node_modules`; the walked root is the invoker's here too, so its own new ctime selects it as well, which the de-dup
# answers.
section "sweep bound: a directory moved into the project is walked for its descendants"
MOVED="${OUTSIDE}/moved-dir"
mkdir -p "${MOVED}/node_modules"
printf 'inside\n' > "${MOVED}/inside.txt"; printf 'dep\n' > "${MOVED}/node_modules/dep.js"
touch -d '-1 hour' "${MOVED}/inside.txt" "${MOVED}/node_modules/dep.js" "${MOVED}/node_modules" "${MOVED}"
sleep 1; touch "${MARKER}"; sleep 1
mv "${MOVED}" "${WALKED}/"
by_ctime_dir="$(find "${WALKED}" -cnewer "${MARKER}" -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')"
if [[ "${by_ctime_dir}" == *"moved-dir "* && "${by_ctime_dir}" != *inside.txt* ]]; then
    pass "control: -cnewer selects the moved directory and not the older file inside it"
else
    fail "control: the moved directory's selection is not the state under test: '${by_ctime_dir}'"
fi
walk_owner="$(stat -c '%U' "${WALKED}")"
LIB_COPY="${TESTDIR}/lib"; mkdir -p "${LIB_COPY}"
for lib in "${ROOT}"/src/usr/local/lib/ai-tools/*.lib.sh; do
    sed -e "s/@SANDBOX_USER@/${walk_owner}/g" -e "s/@SANDBOX_GROUP@/${SANDBOX_GROUP}/g" "${lib}" > "${LIB_COPY}/${lib##*/}"
done
# The sweep checks the socket before it walks. A socket bound here answers that check; where the host refuses the bind
# (a confined session), the host's own handback socket does, since the stubbed client is what each offer reaches.
SOCKET="${TESTDIR}/handback.sock"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${SOCKET}" 2>/dev/null || true
[[ -S "${SOCKET}" ]] || SOCKET=/run/ai-tools/handback.sock
if [[ ! -S "${SOCKET}" ]]; then
    skip "the moved directory's walk" "no socket to answer the sweep's check: the bind is refused here and ${SOCKET} is down"
else
    # shellcheck disable=SC2016  # the inner bash expands these
    count="$(bash -c '
        set -euo pipefail
        source "$1"
        ai_tools_skip_dirs__build_find_expression() { AI_TOOLS_SKIP_DIRS__FIND_EXPRESSION=( "(" -name node_modules ")" -prune -o ); }
        ai_tools_log__debug() { :; }; ai_tools_log__warn() { :; }
        stub_walked="$2"
        stub_client() { printf "%s\n" "${2#"${stub_walked}/"}" >&2; }
        AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT=stub_client
        AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET="$4"
        ai_tools_session_sweep__sweep_project "$2" "$3" 0 stop
        ' _ "${LIB_COPY}/session-sweep.lib.sh" "${WALKED}" "${MARKER}" "${SOCKET}" 2>"${TESTDIR}/offered")" \
        || count="the sweep did not run"
    offered="$(LC_ALL=C sort "${TESTDIR}/offered")"
    if [[ "$(grep -cxF moved-dir <<< "${offered}")" == 1 && "$(grep -cxF moved-dir/inside.txt <<< "${offered}")" == 1 ]] \
            && ! grep -q 'node_modules' <<< "${offered}"; then
        pass "the bounded sweep offers the moved directory and the older file inside it, each once, with the skip kept"
    else
        fail "the moved directory's offers: $(_san "${offered}")"
    fi
    if [[ "${count}" == "$(grep -c . <<< "${offered}")" ]]; then
        pass "the sweep prints the count of confirmed handbacks (${count})"
    else
        fail "the sweep printed '$(_san "${count}")' for $(grep -c . <<< "${offered}") offers, each confirmed"
    fi
fi

# ── The marker a stop run leaves ─────────────────────────────────────────────────────────────────────────────────────
# A stop run sets the marker to the time its scan started and does not write another file into the state directory:
# a hook killed at its timeout cannot clean up after itself, so a file the run created would stay behind. The marker
# starts an hour back, so its time inside the run's window is evidence the run advanced it.
section "sweep bound: a stop run advances the marker to its scan start and leaves no other file"
if ! command -v jq >/dev/null 2>&1; then
    skip "the marker a stop run leaves" "jq not available (the sweep parses its event with it)"
elif [[ ! -S "${SOCKET}" ]]; then
    skip "the marker a stop run leaves" "no socket to answer the sweep's check: the bind is refused here and ${SOCKET} is down"
else
    STATE="${TESTDIR}/state"; mkdir -p "${STATE}"
    touch -d '-1 hour' "${STATE}/.sweep-marker"
    before="$(date +%s)"
    # shellcheck disable=SC2016  # the inner bash expands these
    bash -c '
        set -euo pipefail
        source "$1"
        ai_tools_log__debug() { :; }; ai_tools_log__warn() { :; }
        stub_client() { :; }
        AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT=stub_client
        AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET="$3"
        ai_tools_session_sweep__run stop "$2"
        ' _ "${LIB_COPY}/session-sweep.lib.sh" "${STATE}" "${SOCKET}" <<<"{\"cwd\":\"${WALKED}\"}" >/dev/null 2>&1 \
        && run_rc=0 || run_rc=$?
    after="$(date +%s)"
    marker_time="$(stat -c '%Y' "${STATE}/.sweep-marker" 2>/dev/null || true)"
    if [[ "${run_rc}" -eq 0 && -f "${STATE}/.sweep-marker" ]]; then
        pass "control: the stop run exits 0 and the marker exists"
    else
        fail "control: the stop run exited ${run_rc} or left no marker in ${STATE}"
    fi
    if [[ -n "${marker_time}" ]] && (( marker_time >= before && marker_time <= after )); then
        pass "the stop run sets the marker to its scan start (${marker_time} within ${before}..${after})"
    else
        fail "the marker reads '${marker_time}', outside the run's window ${before}..${after}"
    fi
    leftover="$(find "${STATE}" -mindepth 1 -name '.sweep.??????' -printf '%f ')"
    [[ -z "${leftover}" ]] \
        && pass "the stop run leaves no .sweep.?????? file in the state directory" \
        || fail "the stop run left ${leftover}in ${STATE}"

    # The run codex kills at its Stop timeout: the stubbed client sends SIGKILL to the run's shell at the first path it
    # is offered, so the run ends mid-walk with no trap.
    touch -d '-1 hour' "${STATE}/.sweep-marker"
    marker_before="$(stat -c '%Y' "${STATE}/.sweep-marker")"
    # The subshell waits on the child itself (the `exit` keeps bash from exec'ing it), so the job notice bash prints
    # for a killed child goes to the subshell's discarded stderr and the result lines stay the file's own.
    # shellcheck disable=SC2016  # the inner bash expands these
    ( bash -c '
        set -euo pipefail
        source "$1"
        ai_tools_log__debug() { :; }; ai_tools_log__warn() { :; }
        stub_client() { kill -KILL "$$"; }
        AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT=stub_client
        AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET="$3"
        ai_tools_session_sweep__run stop "$2"
        ' _ "${LIB_COPY}/session-sweep.lib.sh" "${STATE}" "${SOCKET}" <<<"{\"cwd\":\"${WALKED}\"}" >/dev/null 2>&1; exit "$?" ) 2>/dev/null \
        && killed_rc=0 || killed_rc=$?
    if [[ "${killed_rc}" -eq 137 ]]; then
        pass "control: the killed run ended on SIGKILL mid-walk"
    else
        fail "control: the killed run exited ${killed_rc}, not on SIGKILL, so it may not have reached the walk"
    fi
    [[ "$(stat -c '%Y' "${STATE}/.sweep-marker" 2>/dev/null || true)" == "${marker_before}" ]] \
        && pass "a run killed mid-walk leaves the marker where it was, so the next pass covers the same span" \
        || fail "a run killed mid-walk moved the marker"
    leftover="$(find "${STATE}" -mindepth 1 -name '.sweep.??????' -printf '%f ')"
    [[ -z "${leftover}" ]] \
        && pass "a run killed mid-walk leaves no .sweep.?????? file in the state directory" \
        || fail "a run killed mid-walk left ${leftover}in ${STATE}"
fi

# ── The bound the library carries ────────────────────────────────────────────────────────────────────────────────────
section "sweep bound: the session sweep bounds its Stop walk on ctime, and every agent's hook runs it"
SWEEP_LIB_SRC="${ROOT}/src/usr/local/lib/ai-tools/session-sweep.lib.sh"
source_text="$(<"${SWEEP_LIB_SRC}")"
if grep -qF 'expr+=( -cnewer "${marker}" )' <<<"${source_text}" \
        && ! grep -qF -- '-newer "${marker}"' <<<"${source_text//-cnewer/}"; then
    pass "session-sweep.lib.sh: the Stop sweep is bounded by -cnewer on the marker, with no -newer bound"
else
    fail "session-sweep.lib.sh does not carry the -cnewer bound alone"
fi
for hook in "${ROOT}"/src/opt/ai-tools/agents/*/session-hook.sh; do
    agent="${hook%/session-hook.sh}"; agent="${agent##*/}"
    hook_text="$(<"${hook}")"
    if grep -qxF 'readonly SWEEP_LIB="/usr/local/lib/ai-tools/session-sweep.lib.sh"' <<<"${hook_text}" \
            && grep -qxF 'ai_tools_session_sweep__run "${1:-stop}" "${HOOK_DIR}"' <<<"${hook_text}"; then
        pass "${agent}: session-hook.sh sources the installed library and runs it over its own directory"
    else
        fail "${agent}: session-hook.sh does not source the installed session sweep and run it over its own directory"
    fi
done

finish

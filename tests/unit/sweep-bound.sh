#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/sweep-bound.sh
# Unit test for the bound the Stop sweep puts on its walk: the session sweep every agent's hook runs selects the paths
# whose status changed since the sweep marker (`find -cnewer`), so a file moved into the project -- renamed within one
# filesystem, or moved from another -- is selected though its mtime is older than the marker. The live chain runs only
# inside a claimed project (tests/manual/verify-live-flows.sh), so this file drives the bound's find shape
# over a fixture, with `-newer` as the control that misses both moves, and reads the session sweep library's source
# for the bound it carries.
#
# The bound narrows only which sandbox-owned paths a pass offers to ai-tools-chown; the `-user` test and the helper's
# own guard decide what is handed back, so no boundary half is owed here. The library's functions are then driven
# over fixtures: the moved-directory walk, the marker a run leaves, the failed-call count, the interrupted-session
# notice and the leftover cleanup. Runs unprivileged or as root.
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
        _AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT=stub_client
        _AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET="$4"
        _ai_tools_session_sweep__sweep_project "$2" "$3" 0 stop
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
        _AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT=stub_client
        _AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET="$3"
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
        _AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT=stub_client
        _AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET="$3"
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

# run_library <mode> <state_dir> <socket> <client-body> : run ai_tools_session_sweep__run from the library copy
# in a shell of its own, the event on stdin. The handback client is a function whose body is <client-body>; the logger's
# warnings go to stderr as `warn: <text>` lines and its other levels are silent. Prints what the run prints on stdout.
run_library() {
    # shellcheck disable=SC2016  # the inner bash expands these
    bash -c '
        set -euo pipefail
        source "$1"
        ai_tools_log__debug() { :; }; ai_tools_log__info() { :; }
        ai_tools_log__warn() { printf "warn: %s\n" "$*" >&2; }
        eval "stub_client() { $5; }"
        _AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT=stub_client
        _AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET="$4"
        ai_tools_session_sweep__run "$2" "$3"
        ' _ "${LIB_COPY}/session-sweep.lib.sh" "$1" "$2" "$3" "$4"
}

# quote_c <path> : <path> in bash's %q encoding under the C locale, the form the library prints a command's path in.
quote_c() { local LC_ALL=C; printf '%q' "$1"; }

# ── The interrupted-session notice ───────────────────────────────────────────────────────────────────────────────────
# The notice a session-start pass emits after an interrupted session carries a command the user is asked to paste:
# the handback command, which resolves each path's owner, with the project in bash's %q encoding under the C locale.
# Each project is named with characters a shell reads as syntax inside double quotes, or with a multibyte character
# or a Unicode control, holds an agent-owned .git object (the walked owner is the invoker, as in the moved-directory
# case) and is named by a planted clean-exit marker, so the run reads it as interrupted. The runs take a UTF-8 locale,
# the one a session inherits from the operator, under which a plain %q leaves those characters raw; the command line
# must hold printable ASCII alone, and run with `printf` in place of the CLI, as a recorder, must print the path whole.
section "sweep bound: the interrupted-session notice names the handback command with the project path quoted"
locales="$(locale -a 2>/dev/null || true)"
UTF8_LOCALE=""
grep -qiE '^c\.utf-?8$' <<<"${locales}" && UTF8_LOCALE="C.UTF-8"
if ! command -v jq >/dev/null 2>&1; then
    skip "the interrupted-session notice" "jq not available (the sweep parses its event with it)"
elif [[ ! -S "${SOCKET}" ]]; then
    skip "the interrupted-session notice" "no socket to answer the sweep's check: the bind is refused here and ${SOCKET} is down"
else
    NOTICE_STATE="${TESTDIR}/notice-state"; mkdir -p "${NOTICE_STATE}"
    BIDI_NAME="bidi-$(printf '\342\200\256')abc"
    # shellcheck disable=SC2016  # literal shell syntax in the directory names, the case under test
    names=( 'notice proj-$(x)' 'tick-`x`' "single-'quote" 'double-"quote' 'dollar-$HOME' $'new\nline' )
    if [[ -n "${UTF8_LOCALE}" ]]; then
        # Control: under that locale a plain %q leaves U+202E raw, so the locale rows test the library's encoding.
        raw="$(LC_ALL="${UTF8_LOCALE}" bash -c 'printf "%q" "$1"' _ "${BIDI_NAME}")"
        [[ "${raw}" == *$'\342\200\256'* ]] \
            && pass "control: under ${UTF8_LOCALE} a plain %q leaves U+202E as its raw bytes" \
            || fail "control: under ${UTF8_LOCALE} a plain %q encoded U+202E, so the locale rows test nothing"
        names+=( "caf$(printf '\303\251')" "${BIDI_NAME}" "isolate-$(printf '\342\201\246')abc" )
    else
        skip "a project named with a multibyte character or a Unicode control" "no C.UTF-8 locale in locale -a"
    fi
    for name in "${names[@]}"; do
        project="${TESTDIR}/${name}"
        mkdir -p "${project}/.git/objects"; printf 'o\n' > "${project}/.git/objects/x"
        printf '%s\n' "${project}" > "${NOTICE_STATE}/.session-active"
        payload="$(jq -cn --arg cwd "${project}" '{cwd:$cwd, source:"startup"}')"
        label="$(quote_c "${name}")"
        context="$(LC_ALL="${UTF8_LOCALE}" run_library session-start "${NOTICE_STATE}" "${SOCKET}" ':' <<<"${payload}" \
            2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
        if [[ "${context}" == *interrupted* ]]; then
            pass "control: ${label}: the session-start run emits the interrupted-session notice"
        else
            fail "control: ${label}: no interrupted-session notice: $(_san "${context}")"
            continue
        fi
        command_line="$(grep -m1 '^  ai-tools projects handback ' <<<"${context}" || true)"
        [[ "${command_line}" == "  ai-tools projects handback $(quote_c "${project}")" && "${context}" != *chown* ]] \
            && pass "${label}: the notice names ai-tools projects handback with the %q path, and no chown" \
            || fail "${label}: the notice's command reads '$(_san "${command_line}")'"
        LC_ALL=C bash -c '[[ "$1" != *[![:print:]]* ]]' _ "${command_line}" \
            && pass "${label}: the notice's command holds printable ASCII alone" \
            || fail "${label}: the notice's command carries a byte outside printable ASCII"
        recorded="$(bash -c "printf '%s.' ${command_line#  ai-tools projects handback }" 2>/dev/null || true)"
        [[ "${recorded%.}" == "${project}" ]] \
            && pass "${label}: the pasted command passes the project path as one argument, byte for byte" \
            || fail "${label}: the pasted command passes '$(_san "${recorded%.}")'"
    done

    # The socket down: the notice names the socket's start and the same handback command. The first project's .git
    # object is still the invoker's (a stub client does not change an owner), so the pass counts it as stranded.
    project="${TESTDIR}/notice proj-\$(x)"
    printf '%s\n' "${project}" > "${NOTICE_STATE}/.session-active"
    payload="$(jq -cn --arg cwd "${project}" '{cwd:$cwd, source:"startup"}')"
    context="$(run_library session-start "${NOTICE_STATE}" "${TESTDIR}/no-socket" ':' <<<"${payload}" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
    if grep -qxF '  sudo systemctl enable --now ai-tools-handback.socket' <<<"${context}" \
            && grep -qxF "  ai-tools projects handback $(quote_c "${project}")" <<<"${context}"; then
        pass "the socket-down notice names the socket's start and the handback command with the %q path"
    else
        fail "the socket-down notice reads '$(_san "${context}")'"
    fi

    # The journal's copy of the command: both warnings a socket-down session-start logs for the U+202E project,
    # the walk's and the stranded .git paths', end in the handback command. The library's own sanitizer, which every log
    # line passes, leaves each line as written, and the command read back from the logged line names the project.
    if [[ -n "${UTF8_LOCALE}" ]]; then
        project="${TESTDIR}/${BIDI_NAME}"
        printf '%s\n' "${project}" > "${NOTICE_STATE}/.session-active"
        payload="$(jq -cn --arg cwd "${project}" '{cwd:$cwd, source:"startup"}')"
        warnings="$(LC_ALL="${UTF8_LOCALE}" run_library session-start "${NOTICE_STATE}" "${TESTDIR}/no-socket" ':' \
            <<<"${payload}" 2>&1 >/dev/null || true)"
        walk_line="$(grep -m1 'sweep skipped: handback socket' <<<"${warnings}" || true)"
        git_line="$(grep -m1 'agent-owned .git path(s)' <<<"${warnings}" || true)"
        [[ -n "${walk_line}" && -n "${git_line}" ]] \
            && pass "control: the socket-down run logged the walk's warning and the stranded .git warning" \
            || fail "control: the socket-down run's warnings: $(_san "${warnings}")"
        for logged in "${walk_line}" "${git_line}"; do
            command_word="${logged##*ai-tools projects handback }"; command_word="${command_word%)}"
            [[ "${command_word}" == "$(quote_c "${project}")" ]] \
                && pass "a socket-down warning names the handback command with the C-locale %q path" \
                || fail "a socket-down warning's command reads '$(_san "${command_word}")'"
            sanitized="$(bash -c 'source "$1"; ai_tools_log__sanitize "$2"' _ "${LIB_COPY}/log.lib.sh" "${command_word}")"
            recorded="$(bash -c "printf '%s.' ${sanitized}" 2>/dev/null || true)"
            [[ "${recorded%.}" == "${project}" ]] \
                && pass "the logged command, through the log sanitizer, still names the project byte for byte" \
                || fail "the logged command, through the log sanitizer, names '$(_san "${recorded%.}")'"
        done
    fi
fi

# ── A pass whose walk did not run, and a call that failed ────────────────────────────────────────────────────────────
# A stop run with the socket down skips its walk, so it leaves the marker where it was, and the span it skipped is
# walked once the socket is back; the stop-run case's advance is the control. A walk in which the client fails for one
# path counts it apart: the warning names one path not handed back, and the printed count is the offers less that one.
section "sweep bound: a pass whose walk did not run holds the marker, and a failed call is counted"
if ! command -v jq >/dev/null 2>&1; then
    skip "the marker and the failed call" "jq not available (the sweep parses its event with it)"
elif [[ ! -S "${SOCKET}" ]]; then
    skip "the marker and the failed call" "no socket to answer the sweep's check: the bind is refused here and ${SOCKET} is down"
else
    HOLD_STATE="${TESTDIR}/hold-state"; mkdir -p "${HOLD_STATE}"
    touch -d '-1 hour' "${HOLD_STATE}/.sweep-marker"
    marker_before="$(stat -c '%Y' "${HOLD_STATE}/.sweep-marker")"
    warnings="$(run_library stop "${HOLD_STATE}" "${TESTDIR}/no-socket" ':' <<<"{\"cwd\":\"${WALKED}\"}" 2>&1 >/dev/null || true)"
    [[ "${warnings}" == *'sweep skipped: handback socket'* ]] \
        && pass "control: the stop run read the socket as down and skipped its walk" \
        || fail "control: the stop run did not report the socket down: $(_san "${warnings}")"
    [[ "$(stat -c '%Y' "${HOLD_STATE}/.sweep-marker")" == "${marker_before}" ]] \
        && pass "a stop run whose walk did not run leaves the marker where it was" \
        || fail "a stop run with the socket down advanced the marker"

    FAIL_PROJECT="${TESTDIR}/fail-project"; mkdir -p "${FAIL_PROJECT}"
    printf 'a\n' > "${FAIL_PROJECT}/a.txt"; printf 'b\n' > "${FAIL_PROJECT}/refused.txt"
    # shellcheck disable=SC2016  # the inner bash expands these
    count="$(bash -c '
        set -euo pipefail
        source "$1"
        ai_tools_log__debug() { :; }; ai_tools_log__info() { :; }
        stub_warnings="$4" stub_offers="$5"
        ai_tools_log__warn() { printf "warn: %s\n" "$*" >> "${stub_warnings}"; }
        stub_client() { printf "%s\n" "$2" >> "${stub_offers}"; [[ "$2" != */refused.txt ]]; }
        _AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT=stub_client
        _AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET="$3"
        _ai_tools_session_sweep__sweep_project "$2" "" 1 stop
        ' _ "${LIB_COPY}/session-sweep.lib.sh" "${FAIL_PROJECT}" "${SOCKET}" "${TESTDIR}/fail.warn" "${TESTDIR}/fail.offers")" \
        || count="the sweep returned non-zero"
    offers="$(grep -c . "${TESTDIR}/fail.offers" 2>/dev/null || true)"
    if [[ "${offers}" -ge 3 ]] && grep -qxF "${FAIL_PROJECT}/refused.txt" "${TESTDIR}/fail.offers"; then
        pass "control: the walk offered the project, both files and the refused one among them (${offers} offers)"
    else
        fail "control: the walk's offers: $(_san "$(cat "${TESTDIR}/fail.offers" 2>/dev/null || true)")"
    fi
    [[ "${count}" == "$(( offers - 1 ))" ]] \
        && pass "the printed count leaves out the failed call (${count} of ${offers})" \
        || fail "the sweep printed '$(_san "${count}")' for ${offers} offers with one failed"
    grep -q '1 path(s) under .* not handed back' "${TESTDIR}/fail.warn" 2>/dev/null \
        && pass "one warning names the one path not handed back" \
        || fail "no warning named the failed call: $(_san "$(cat "${TESTDIR}/fail.warn" 2>/dev/null || true)")"
fi

# ── The temporary files earlier hooks left ───────────────────────────────────────────────────────────────────────────
# Hooks before 0.27.0 left a .sweep.?????? file in the state directory when they were killed mid-walk. The session-start
# pass, the one that reclaims what a prior session left, removes them; a stop pass does not touch them.
section "sweep bound: the session-start pass removes the temporary files earlier hooks left"
if ! command -v jq >/dev/null 2>&1; then
    skip "the temporary files earlier hooks left" "jq not available (the sweep parses its event with it)"
elif [[ ! -S "${SOCKET}" ]]; then
    skip "the temporary files earlier hooks left" "no socket to answer the sweep's check: the bind is refused here and ${SOCKET} is down"
else
    LEFT_STATE="${TESTDIR}/left-state"; mkdir -p "${LEFT_STATE}"
    : > "${LEFT_STATE}/.sweep.abcdef"
    run_library stop "${LEFT_STATE}" "${SOCKET}" ':' <<<"{\"cwd\":\"${WALKED}\"}" >/dev/null 2>&1 || true
    [[ -f "${LEFT_STATE}/.sweep-marker" ]] \
        && pass "control: the stop run wrote the marker" \
        || fail "control: the stop run left no marker in ${LEFT_STATE}"
    [[ -f "${LEFT_STATE}/.sweep.abcdef" ]] \
        && pass "a stop run leaves an earlier hook's .sweep.abcdef in place" \
        || fail "a stop run removed an earlier hook's .sweep.abcdef"
    run_library session-start "${LEFT_STATE}" "${SOCKET}" ':' \
        <<<"$(jq -cn --arg cwd "${WALKED}" '{cwd:$cwd, source:"startup"}')" >/dev/null 2>&1 || true
    [[ -f "${LEFT_STATE}/.sweep-marker" && -f "${LEFT_STATE}/.session-active" ]] \
        && pass "control: the session-start run kept the marker and wrote the clean-exit marker" \
        || fail "control: the session-start run did not leave both markers in ${LEFT_STATE}"
    [[ ! -e "${LEFT_STATE}/.sweep.abcdef" ]] \
        && pass "the session-start run removes an earlier hook's .sweep.abcdef" \
        || fail "the session-start run left .sweep.abcdef in ${LEFT_STATE}"
fi

# ── A file written during the sweep ──────────────────────────────────────────────────────────────────────────────────
# The marker takes the scan's start time so that a file written while the walk runs is offered by the next pass. Pass
# one's client writes during.txt at its first offer, then waits, so the walk ends after that write; pass two records its
# offers. A marker stamped when the walk ended would be newer than during.txt, and pass two would not offer it.
# during.txt goes into a subdirectory: the write changes that directory's ctime, so pass two selects it and walks it
# again without the bound, as it walks a directory moved in. before.txt, written ahead of pass one at the project's top
# and untouched since, is then the control pass two must not offer.
section "sweep bound: a file written during the sweep is offered by the next pass"
if ! command -v jq >/dev/null 2>&1; then
    skip "a file written during the sweep" "jq not available (the sweep parses its event with it)"
elif [[ ! -S "${SOCKET}" ]]; then
    skip "a file written during the sweep" "no socket to answer the sweep's check: the bind is refused here and ${SOCKET} is down"
else
    DURING_PROJECT="${TESTDIR}/during-project"; DURING_STATE="${TESTDIR}/during-state"
    mkdir -p "${DURING_PROJECT}/fresh" "${DURING_STATE}"
    printf 'before\n' > "${DURING_PROJECT}/before.txt"
    touch -d '-1 hour' "${DURING_STATE}/.sweep-marker"
    first_offer="${TESTDIR}/during.first"
    writer="if [[ ! -e $(printf '%q' "${first_offer}") ]]; then : > $(printf '%q' "${first_offer}");"
    writer+=" printf 'during\n' > $(printf '%q' "${DURING_PROJECT}/fresh/during.txt"); sleep 0.05; fi"
    run_library stop "${DURING_STATE}" "${SOCKET}" "${writer}" <<<"{\"cwd\":\"${DURING_PROJECT}\"}" >/dev/null 2>&1 || true
    : > "${TESTDIR}/during.offers"
    recorder="printf '%s\n' \"\$2\" >> $(printf '%q' "${TESTDIR}/during.offers")"
    run_library stop "${DURING_STATE}" "${SOCKET}" "${recorder}" <<<"{\"cwd\":\"${DURING_PROJECT}\"}" >/dev/null 2>&1 || true
    [[ -f "${DURING_PROJECT}/fresh/during.txt" ]] \
        && pass "control: pass one's client wrote during.txt while the walk ran" \
        || fail "control: pass one did not reach its client, so during.txt was not written"
    grep -qxF "${DURING_PROJECT}/fresh/during.txt" "${TESTDIR}/during.offers" \
        && pass "the next pass offers the file written during the sweep" \
        || fail "the next pass did not offer during.txt: $(_san "$(cat "${TESTDIR}/during.offers")")"
    ! grep -qxF "${DURING_PROJECT}/before.txt" "${TESTDIR}/during.offers" \
        && pass "control: the next pass does not offer a file untouched since before the sweep" \
        || fail "the next pass offered before.txt, so the bound did not hold"
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

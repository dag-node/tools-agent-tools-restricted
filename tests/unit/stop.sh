#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/stop.sh
# Unit test for the session-stop helper (ai-tools-stop), the incident ladder's stop rung. It
# pins the two things the whole guarantee rests on -- WHICH cgroups are enumerated as sessions,
# and whether a cgroup is judged LIVE -- against a synthetic cgroup tree built in TESTDIR, so
# every assertion runs on any host, with no session running, no cgroup privilege, and nothing
# signalled.
#
# WHY A FIXTURE AND NOT A LIVE SESSION. /sys/fs/cgroup is unreadable from a confined session and
# the shapes that matter (a nested init.scope, a slice holding tasks directly, a dot-named cgroup,
# a cgroup.procs that cannot be read) cannot be manufactured on a live host at all. Reading has
# repeatedly failed to find defects in this enumeration; a fixture finds them in seconds.
#
# The helper is SOURCED, which is inert by construction (it parses nothing and resolves nothing at
# file scope), and the three globals the walk is expressed against are then pointed at the fixture.
# Two things are stubbed, both non-decisions here: unit_working_directory, whose real form would
# reach the sandbox account's user manager over sudo, and -- nothing else. Liveness and enumeration
# are exercised as written.
#
# NOTHING REAL CAN BE SIGNALLED. Every fixture pid is above the host's pid_max, so it has no /proc
# entry; the helper validates a pid's start time immediately before signalling and skips one it
# cannot read, which is asserted here rather than assumed. main() is driven only in the dry run,
# which returns before the kill. The kill primitive itself is exercised against real `sleep`
# children this test spawns and reaps, and end to end in tests/integration/stop.sh.
#
# Run as root via sudo with the rest of the suite; needs no privilege of its own, so it also runs
# directly as an unprivileged user during development. Two assertions about an UNREADABLE file skip
# under root, which reads everything regardless of mode.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

section "session stop: enumeration, liveness, selection (unit)"

# The deployed helper is preferred (it is the token-substituted artifact the operator runs); the
# repo source is the fallback, so the suite covers the helper before the first install of a host.
STOP_HELPER="/usr/local/libexec/ai-tools/ai-tools-stop"
if [[ ! -r "${STOP_HELPER}" ]]; then
    STOP_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/usr/local/libexec/ai-tools/ai-tools-stop.sh"
fi
if [[ ! -r "${STOP_HELPER}" ]]; then
    skip "session stop" "helper not readable at either the installed or the source path"
    finish; exit
fi

mktestdir
# Fixture project directories only. This helper reads no allowlist and resolves no operator: it
# takes no target, so there is nothing to authorize. These paths exist purely as the working
# directories the fixture attribution map hands back for the table.
mkdir -p "${TESTDIR}/proj/alpha" "${TESTDIR}/proj/alpha-extra" "${TESTDIR}/proj/beta"

# The harness and the helper both name the sandbox account SANDBOX_USER and both declare it
# readonly, and a second `readonly` on an existing name is an error even when the value agrees --
# which it does, both being the sandbox account. So that one failure is expected here; every other
# byte on stderr is not, and is asserted to be absent rather than discarded with it.
source_errors="${TESTDIR}/source-stderr"
# shellcheck source=/dev/null
source "${STOP_HELPER}" 2>"${source_errors}" || true

# The real attribution function, saved under a second name BEFORE the fixture stub below replaces
# it. `unset -f` cannot get it back: overriding a function discards the original outright, so a
# test that stubbed first and unset later would drive nothing.
eval "helper_unit_working_directory() $(declare -f unit_working_directory 2>/dev/null | tail -n +2)" \
    2>/dev/null || true

if ! declare -F find_session_cgroups >/dev/null 2>&1; then
    fail "sourcing ${STOP_HELPER} defined nothing -- the helper is not inert on source"
    finish; exit
fi
if [[ -z "$(grep -v 'SANDBOX_USER: readonly variable' "${source_errors}" || true)" ]]; then
    pass "helper sources inertly (functions defined, nothing parsed, resolved or signalled)"
else
    fail "sourcing the helper wrote unexpected errors: $(< "${source_errors}")"
fi
if [[ "${SANDBOX_USER}" == "ai-tools" ]]; then
    pass "the sandbox account the helper acts on is the one the suite tests against"
else
    fail "sandbox account mismatch: helper/harness resolved '${SANDBOX_USER}'"
fi

# Fixture pids sit ABOVE pid_max, so no /proc entry can ever exist for one and no fixture pid can
# name a real process. This is the test's own safety property and it is asserted below.
_pid_max="$(< /proc/sys/kernel/pid_max)"
fixture_pid() { printf '%s' "$(( _pid_max + $1 ))"; }

# mkcg <dir> [pid...] -- a cgroup directory with the two interface files the helper reads, kept
# consistent with each other: cgroup.procs lists the tasks, cgroup.events reports whether the
# subtree is populated (the kernel's own recursive answer, which the liveness predicate prefers).
mkcg() {
    local dir="$1"; shift
    mkdir -p "${dir}"
    : > "${dir}/cgroup.procs"
    local pid
    for pid in "$@"; do printf '%s\n' "$(fixture_pid "${pid}")" >> "${dir}/cgroup.procs"; done
    printf 'populated 0\nfrozen 0\n' > "${dir}/cgroup.events"
}

# sync_events <root> -- recompute every cgroup.events in the tree the way the kernel reports it:
# `populated` is 1 while the cgroup OR ANY DESCENDANT holds a task. Written as its own pass rather
# than per-directory, because a parent is created before its children and a fixture that reported
# only its OWN tasks would answer "not live" for every slice -- which is precisely the mistake the
# liveness predicate must not make, so the fixture must not make it either.
sync_events() {
    local dir
    while IFS= read -r dir; do
        local populated=0 procs
        while IFS= read -r procs; do
            [[ -s "${procs}" ]] && { populated=1; break; }
        done < <(find "${dir}" -name cgroup.procs)
        printf 'populated %d\nfrozen 0\n' "${populated}" > "${dir}/cgroup.events"
    done < <(find "$1" -type d)
}

# point_at <slice-root> <uid> -- aim the helper's two walk globals at a fixture tree. They are
# readonly only once the helper's own resolve_cgroup_layout runs, which sourcing does not do -- and
# this file never calls it, which is what keeps every main() here on a fixture slice under TESTDIR
# and off the real sandbox account's. Every main() call below is preceded by a point_at.
# shellcheck disable=SC2034  # read by the sourced helper's walk, not by this file
point_at() {
    SANDBOX_SLICE="$1"
    MANAGER_SERVICE="$1/user@$2.service"
}

# emitted_set -- find_session_cgroups' output as slice-relative paths, one per line, sorted, so an
# assertion reads as a set rather than depending on walk order (which is deliberately unordered).
emitted_set() {
    local line
    while read -r line; do printf '%s\n' "${line#"${SANDBOX_SLICE}"/}"; done \
        < <(find_session_cgroups) | LC_ALL=C sort
}

# ── The tree, with every shape that has ever been got wrong ──────────────────────────────────
CG="${TESTDIR}/cgroup2/user.slice/user-4242.slice"
point_at "${CG}" 4242

mkcg "${CG}"                                                        # slice root: no own tasks
mkcg "${CG}/session-3.scope"                        501             # sibling login scope
mkcg "${CG}/user@4242.service"                                      # the manager unit itself
mkcg "${CG}/user@4242.service/init.scope"           101             # systemd --user + (sd-pam)
mkcg "${CG}/user@4242.service/app.slice"                            # a slice with no own tasks
mkcg "${CG}/user@4242.service/app.slice/ai-tools-claude-code-11.service"              201
mkcg "${CG}/user@4242.service/app.slice/ai-tools-claude-code-11.service/nested.scope" 203
mkcg "${CG}/user@4242.service/app.slice/ai-tools-claude-code-12.service"              202
mkcg "${CG}/user@4242.service/app.slice/evil"                       # no tasks, must be descended
mkcg "${CG}/user@4242.service/app.slice/evil/init.scope"            301
mkcg "${CG}/user@4242.service/app.slice/.hidden.scope"              401
mkcg "${CG}/user@4242.service/app.slice/.wrap"                      # dot-named, no tasks
mkcg "${CG}/user@4242.service/app.slice/.wrap/inner.scope"          402
mkcg "${CG}/user@4242.service/weird.slice"          601             # slice holding tasks DIRECTLY
mkcg "${CG}/user@4242.service/empty.slice"                          # nothing, anywhere below it
sync_events "${TESTDIR}/cgroup2"

expected="$(LC_ALL=C sort <<'EOF'
session-3.scope
user@4242.service/app.slice/.hidden.scope
user@4242.service/app.slice/.wrap/inner.scope
user@4242.service/app.slice/ai-tools-claude-code-11.service
user@4242.service/app.slice/ai-tools-claude-code-12.service
user@4242.service/app.slice/evil/init.scope
user@4242.service/init.scope
user@4242.service/weird.slice
EOF
)"
actual="$(emitted_set)"
if [[ "${actual}" == "${expected}" ]]; then
    pass "enumeration emits exactly the session cgroups"
else
    fail "enumeration mismatch:"
    diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") | sed 's/^/        /' || true
fi

# Each property named on its own, so a regression says which one broke rather than "the set
# changed". Every one of these has been wrong at some point in this helper's life.
assert_emitted() {
    if grep -qxF "$2" <<< "${actual}"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
assert_not_emitted() {
    if grep -qxF "$2" <<< "${actual}"; then fail "$1 (unexpectedly emitted: $2)"; else pass "$1"; fi
}
assert_not_emitted "the manager service is descended into, never emitted" "user@4242.service"
assert_not_emitted "a parent slice is never offered as a stoppable thing" "user@4242.service/app.slice"
assert_emitted "the manager's OWN init.scope is enumerated -- NOTHING is exempt, because an exemption is a cgroup a session can move into" \
    "user@4242.service/init.scope"
assert_not_emitted "a unit's nested cgroup is part of it, not a session" \
    "user@4242.service/app.slice/ai-tools-claude-code-11.service/nested.scope"
assert_emitted "a NESTED init.scope is enumerated too -- no name is treated as special anywhere" \
    "user@4242.service/app.slice/evil/init.scope"
assert_emitted "a login scope beside the manager is found"        "session-3.scope"
assert_emitted "a slice holding tasks directly is found"          "user@4242.service/weird.slice"
assert_emitted "a DOT-NAMED cgroup cannot hide from the walk" \
    "user@4242.service/app.slice/.hidden.scope"
assert_emitted "a unit inside a DOT-NAMED parent cannot hide from the walk" \
    "user@4242.service/app.slice/.wrap/inner.scope"

# A slice root that holds tasks directly is itself a session -- the "belongs to no unit at all"
# case, reported rather than skipped. Asserted on the absolute path, since its slice-relative form
# is the empty string.
printf '%s\n' "$(fixture_pid 999)" > "${CG}/cgroup.procs"
# Captured, not piped into `grep -q`: under `pipefail` grep's early exit SIGPIPEs the producer and
# the pipeline reports 141 even on a match.
slice_root_emission="$(find_session_cgroups)"
if grep -qxF "${CG}" <<< "${slice_root_emission}"; then
    pass "a slice ROOT holding tasks directly is emitted"
else
    fail "a slice ROOT holding tasks directly is not emitted"
fi
: > "${CG}/cgroup.procs"

# ── has_own_tasks: own tasks only, and fail-closed where a failure is distinguishable ─────────
section "has_own_tasks"

if has_own_tasks "${CG}/user@4242.service/app.slice"; then
    fail "a slice whose tasks all live in the units below it must have no OWN tasks"
else
    pass "a slice whose tasks live in its units has no own tasks"
fi
if has_own_tasks "${CG}/user@4242.service/weird.slice"; then
    pass "a slice holding tasks directly has own tasks"
else
    fail "a slice holding tasks directly must report own tasks"
fi
if has_own_tasks "${TESTDIR}/cgroup2/gone"; then
    fail "a removed cgroup must read as empty -- that is what a completed kill looks like"
else
    pass "a removed cgroup reads as empty"
fi

# THREADED CGROUP: cgroup.procs exists and is permission-readable, but the read itself fails
# (EOPNOTSUPP below a threaded root) while live threads sit in the cgroup. Bash cannot tell that
# failed read from a clean EOF -- verified, both give `read` status 1 and an empty value -- so the
# corroborating source is cgroup.threads, which the kernel keeps readable in every cgroup. The
# fixture reproduces the SHAPE (a read that fails on a permission-readable path) with a directory
# in place of the file, which fails the same way for root and non-root alike.
threaded="${TESTDIR}/cgroup2/threaded"
mkdir -p "${threaded}/cgroup.procs"
printf '%s\n' "$(fixture_pid 700)" > "${threaded}/cgroup.threads"
if has_own_tasks "${threaded}"; then
    pass "a threaded cgroup whose cgroup.procs cannot be read reports LIVE via cgroup.threads"
else
    fail "a threaded cgroup read as empty is a fail-open on the liveness predicate"
fi

# PERMISSION-UNREADABLE: the other distinguishable failure, and the one `-r` answers directly.
unreadable="${TESTDIR}/cgroup2/unreadable"
mkcg "${unreadable}" 702
chmod 000 "${unreadable}/cgroup.procs"
if [[ "${EUID}" -eq 0 ]]; then
    skip "an unreadable cgroup.procs reports LIVE" "root reads any mode; assertion is meaningful only unprivileged"
elif has_own_tasks "${unreadable}"; then
    pass "an unreadable cgroup.procs reports LIVE, never empty"
else
    fail "an unreadable cgroup.procs read as empty is a fail-open"
fi
chmod 644 "${unreadable}/cgroup.procs"

# ── cgroup_pids: the whole subtree, deepest first, counted once ───────────────────────────────
section "cgroup_pids"

unit11="${CG}/user@4242.service/app.slice/ai-tools-claude-code-11.service"
mapfile -t collected < <(cgroup_pids "${unit11}")
if [[ "${#collected[@]}" -eq 2 ]]; then
    pass "a unit's pid count includes its nested cgroups and counts each once"
else
    fail "expected 2 pids for the unit and its nested scope, got ${#collected[@]}: ${collected[*]}"
fi
if [[ "${collected[0]}" == "$(fixture_pid 203)" && "${collected[1]}" == "$(fixture_pid 201)" ]]; then
    pass "pids are emitted deepest-first, so children are signalled before their parents"
else
    fail "expected the nested pid first, got: ${collected[*]}"
fi
mapfile -t collected < <(cgroup_pids "${CG}/user@4242.service/app.slice")
if [[ "${#collected[@]}" -eq 6 ]]; then
    pass "a subtree's pids are collected across every descendant cgroup"
else
    fail "expected 6 pids under app.slice, got ${#collected[@]}: ${collected[*]}"
fi

# ── cgroup_is_live: the verification predicate, which must never fail open ────────────────────
section "cgroup_is_live"

if cgroup_is_live "${unit11}"; then
    pass "a populated cgroup is live"
else
    fail "a populated cgroup must be live"
fi
if cgroup_is_live "${CG}/user@4242.service/empty.slice"; then
    fail "an empty cgroup with an empty subtree must not be live"
else
    pass "an empty cgroup is not live"
fi
if cgroup_is_live "${TESTDIR}/cgroup2/gone"; then
    fail "a removed cgroup must not be live -- that is the successful outcome"
else
    pass "a removed cgroup is not live"
fi

# THE REGRESSION THIS PREDICATE EXISTS TO NOT HAVE: an earlier form was
# `[[ -n "$(cgroup_pids "$1" | head -n1)" ]]`, which answers "no tasks" when `head` is absent --
# reporting a stop complete while the session runs. It is now walked in-shell, so it must hold with
# no external command reachable at all.
# shellcheck disable=SC2123  # emptying PATH inside the subshell is the point of the assertion
if ( PATH=/nonexistent; cgroup_is_live "${unit11}" ); then
    pass "liveness holds with PATH=/nonexistent (no external command on the verification path)"
else
    fail "liveness must not depend on an external command"
fi
# shellcheck disable=SC2123  # as above
if ( PATH=/nonexistent; cgroup_is_live "${CG}/user@4242.service/empty.slice" ); then
    fail "an empty cgroup must still read empty with PATH=/nonexistent"
else
    pass "an empty cgroup still reads empty with PATH=/nonexistent"
fi

# cgroup.events is the kernel's own recursive answer and is consulted first; a cgroup whose own
# procs are empty but whose DESCENDANT holds tasks is live either way.
if cgroup_is_live "${CG}/user@4242.service/app.slice"; then
    pass "a cgroup whose descendant holds tasks is live"
else
    fail "a parent of a populated cgroup must be live"
fi
# Present but unreadable, and present without a `populated` line: unprovable, so LIVE.
events_broken="${TESTDIR}/cgroup2/events-broken"
mkcg "${events_broken}"
printf 'frozen 0\n' > "${events_broken}/cgroup.events"
if cgroup_is_live "${events_broken}"; then
    pass "a cgroup.events with no populated line reports LIVE, never empty"
else
    fail "an unprovable cgroup.events read as empty is a fail-open"
fi
# With cgroup.events absent the walk is the fallback, and must agree with it.
events_absent="${TESTDIR}/cgroup2/events-absent"
mkcg "${events_absent}/child" 703
mkcg "${events_absent}"
rm -f "${events_absent}/cgroup.events" "${events_absent}/child/cgroup.events"
if cgroup_is_live "${events_absent}"; then
    pass "with no cgroup.events the walk finds a task in a descendant"
else
    fail "the walk fallback must find a task in a descendant"
fi

# ── The kill primitive, against real processes this test owns ─────────────────────────────────
section "signalling"

# A fixture pid is above pid_max, so it has no /proc entry -- the property every assertion above
# leans on, and the reason a fixture can never name a real process.
if pid_start_time "$(fixture_pid 201)" >/dev/null 2>&1; then
    fail "a fixture pid must have no /proc entry"
else
    pass "a fixture pid has no /proc entry, so it can never be signalled"
fi

sleep 30 &
victim=$!
victim_start="$(pid_start_time "${victim}")"
if [[ -n "${victim_start}" && "${victim_start}" =~ ^[0-9]+$ ]]; then
    pass "a process' start time is read from /proc/<pid>/stat"
else
    fail "start time unreadable for a live child: '${victim_start}'"
fi

# A pid whose start time no longer matches what was collected is a RECYCLED pid, and is skipped
# rather than signalled blind. Driven with a deliberately wrong start time on a live process: it
# must survive.
signal_pids_validated TERM "${victim}:$(( victim_start + 1 ))"
sleep 0.3
if kill -0 "${victim}" 2>/dev/null; then
    pass "a pid whose start time changed is never signalled"
else
    fail "a mismatched start time must skip the pid -- a recycled pid was signalled"
fi

# And the matching pid is signalled.
signal_pids_validated TERM "${victim}:${victim_start}"
waited=0
while kill -0 "${victim}" 2>/dev/null && (( waited < 30 )); do sleep 0.1; waited=$(( waited + 1 )); done
if kill -0 "${victim}" 2>/dev/null; then
    fail "a validated pid was not signalled"
    kill -KILL "${victim}" 2>/dev/null || true
else
    pass "a pid whose start time still matches is signalled"
fi
wait "${victim}" 2>/dev/null || true

# ── Selection: which sessions a request picks, driven through main() ──────────────────────────
section "selection"

# The one stub: the real form asks the sandbox account's user manager over the machine transport
# or sudo, which is attribution and never liveness. Here it is a fixture map, so selection is
# deterministic and no bus, no sudo and no live unit are involved.
declare -A FIXTURE_WORKING_DIR=()
unit_working_directory() { printf '%s' "${FIXTURE_WORKING_DIR[$1]:-}"; }

# A tree with a mix of attributable and unattributable sessions. Attribution is DISPLAY ONLY -- it
# selects nothing -- so what these assert is that every session is selected regardless of it, and
# that an unreadable working directory costs a label rather than a target.
CG2="${TESTDIR}/cgroup2b/user.slice/user-4242.slice"
point_at "${CG2}" 4242
mkcg "${CG2}"
mkcg "${CG2}/user@4242.service"
mkcg "${CG2}/user@4242.service/init.scope"  110
mkcg "${CG2}/user@4242.service/app.slice"
mkcg "${CG2}/user@4242.service/app.slice/ai-tools-claude-code-21.service" 211 213
mkcg "${CG2}/user@4242.service/app.slice/ai-tools-claude-code-22.service" 212
mkcg "${CG2}/user@4242.service/app.slice/ai-tools-claude-code-23.service" 214
sync_events "${TESTDIR}/cgroup2b"
FIXTURE_WORKING_DIR=(
    [ai-tools-claude-code-21.service]="${TESTDIR}/proj/alpha"
    [ai-tools-claude-code-22.service]="${TESTDIR}/proj/alpha/sub/dir"
    [ai-tools-claude-code-23.service]="${TESTDIR}/proj/alpha-extra"
)

# The caller identity recorded in the trail. In production it comes from sudo; it authorizes
# nothing -- this command takes no authorization input.
# shellcheck disable=SC2034  # CALLER/SANDBOX_UID are read by the sourced helper
CALLER="${PROJECTS_USER}"
# shellcheck disable=SC2034  # as above
SANDBOX_UID=4242

# run_main <dry-run?> -- set the request the way the argument parser would and run main(),
# capturing its output and status. Only the dry run is used: it returns BEFORE the kill, and the
# kill primitive itself is exercised against real processes in tests/integration/stop.sh.
# shellcheck disable=SC2034  # the request globals are read by the sourced helper's main()
run_main() {
    DRY_RUN="$1"; ASSUME_YES=false; FORCE_KILL=false
    set +e
    MAIN_OUTPUT="$(main 2>&1)"
    MAIN_STATUS=$?
    set -e
}

run_main true
if (( MAIN_STATUS == 0 )) && grep -q '4 agent session' <<< "${MAIN_OUTPUT}"; then
    pass "a dry run reports every session in the slice and changes nothing (exit 0)"
else
    fail "dry run: status ${MAIN_STATUS}, output: ${MAIN_OUTPUT}"
fi

# THE PROPERTY THAT REPLACED SCOPING. Every one of these is selected, including the session whose
# project merely shares a path prefix with another and the manager's own init.scope. Nothing here
# is a target to be matched, so there is no prefix trap and no exemption to get wrong.
for expect_unit in ai-tools-claude-code-21.service ai-tools-claude-code-22.service \
                   ai-tools-claude-code-23.service; do
    if grep -q "${expect_unit}" <<< "${MAIN_OUTPUT}"; then
        pass "${expect_unit} is selected -- selection does not consult the project at all"
    else
        fail "${expect_unit} was not selected: ${MAIN_OUTPUT}"
    fi
done

# ATTRIBUTION CANNOT COST A SESSION ITS STOP. A unit whose working directory cannot be read is
# still selected and simply shows as `unknown`; the old behaviour refused the whole run. This is
# the assertion that a misreporting session gains nothing by lying.
FIXTURE_WORKING_DIR[ai-tools-claude-code-22.service]=""
run_main true
if (( MAIN_STATUS == 0 )) \
        && grep -q 'ai-tools-claude-code-22.service' <<< "${MAIN_OUTPUT}" \
        && grep -q 'unknown' <<< "${MAIN_OUTPUT}"; then
    pass "a session with no readable project is still selected, shown as 'unknown'"
else
    fail "unattributable session: status ${MAIN_STATUS}, output: ${MAIN_OUTPUT}"
fi
FIXTURE_WORKING_DIR[ai-tools-claude-code-22.service]="${TESTDIR}/proj/alpha/sub/dir"

# A WORKING DIRECTORY THAT IS NOT AN ABSOLUTE PATH YIELDS NOTHING. systemd renders the
# "missing is ok" flag as a `!` prefix over d-bus (`WorkingDirectory=!/opt/ai-tools`), and an
# unstripped one reached the operator inside a `--reclaim` command that will not run -- and that,
# pasted into an interactive bash, is not even inert. Driven through the real function, with the
# systemctl calls it makes stubbed out.
systemctl() { printf 'WorkingDirectory=%s\n' "${STUB_WORKING_DIR}"; }
timeout()   { shift; "$@"; }
for stub_case in "!/srv/p:/srv/p" "-/srv/p:/srv/p" "/srv/p:/srv/p" "~:" "!~:" "relative/p:" ":"; do
    STUB_WORKING_DIR="${stub_case%%:*}"
    marker_got="$(helper_unit_working_directory some.service)"
    if [[ "${marker_got}" == "${stub_case#*:}" ]]; then
        pass "WorkingDirectory '${STUB_WORKING_DIR}' resolves to '${stub_case#*:}'"
    else
        fail "WorkingDirectory '${STUB_WORKING_DIR}': expected '${stub_case#*:}', got '${marker_got}'"
    fi
done
unset -f systemctl timeout

# An empty slice is not an error: nothing running is a successful stop.
point_at "${TESTDIR}/cgroup2c/user.slice/user-4242.slice" 4242
mkcg "${SANDBOX_SLICE}"
run_main true
if (( MAIN_STATUS == 0 )) && grep -qi 'no agent session' <<< "${MAIN_OUTPUT}"; then
    pass "no session running is exit 0, not an error"
else
    fail "empty slice: status ${MAIN_STATUS}, output: ${MAIN_OUTPUT}"
fi

# ── The confirmation, which is inverted on purpose ────────────────────────────────────────────
section "confirmation"

# INVERSION 2 (see the helper's header): every other destructive verb defaults NO, because not
# acting is the safe outcome. For a stop, DECLINING is the failure -- so a piped run, a cron job,
# an absent renderer and a bare Enter all proceed, and only a deliberate `n` stops the stop. The
# assertion runs under `setsid`, which removes the controlling terminal: that is the shape of every
# unattended run, and the one a default-NO prompt would silently turn into "nothing was stopped".
consent_out="$(setsid bash -c '
    source "$1" 2>/dev/null || true
    CALLER="$2"
    confirm_stop 1 </dev/null 2>/dev/null
    printf "status=%s" "$?"' _ "${STOP_HELPER}" "${PROJECTS_USER}" </dev/null 2>&1 || true)"
if [[ "${consent_out}" == *"status=0"* ]]; then
    pass "with no terminal to ask, the confirmation PROCEEDS -- a stop that declines unattended failed"
else
    fail "unattended confirmation did not proceed: ${consent_out}"
fi

# And a deliberate decline stops the stop, at exit 4, with nothing signalled. The renderer's answer
# is stubbed because a real `n` needs a terminal to type it into; what is under test is that the
# answer is honoured, which is the wiring between the two.
point_at "${CG2}" 4242
ai_tools_msg_confirm() { return 1; }
run_main false
if (( MAIN_STATUS == 4 )) && grep -qi 'nothing was stopped' <<< "${MAIN_OUTPUT}"; then
    pass "a deliberate decline stops the stop (exit 4) and says nothing was stopped"
else
    fail "decline: expected exit 4, got ${MAIN_STATUS}: ${MAIN_OUTPUT}"
fi
unset -f ai_tools_msg_confirm

# Every one of those outcomes is in the trail. An operator ending another operator's work, and a
# stop that was asked for and did not happen, are both things the record must show -- so the file
# sink is asserted here rather than only the terminal output. (The suite redirects it away from the
# production /var/log/ai-tools.)
stop_log="${AI_TOOLS_LOG_DIR}/stop.log"
if [[ -s "${stop_log}" ]] \
        && grep -q "requested stop" "${stop_log}" \
        && grep -q "declined the stop" "${stop_log}"; then
    pass "the request, the refusals and the decline are all recorded in the trail"
else
    fail "the trail is missing one of request/refusal/decline: $(tail -5 "${stop_log}" 2>&1)"
fi

# ── Usage contract ────────────────────────────────────────────────────────────────────────────
section "usage"

# WHERE THE LINE IS, AND WHY IT IS EXACTLY HERE. A refusal is safe to drive as a command: it exits
# inside parse_command_line, before any privilege check or host resolution, at any uid. An
# ACCEPTANCE is not. Anything that parses cleanly goes on to resolve the real host and reach
# main(), which enumerates the SANDBOX ACCOUNT'S OWN SLICE -- so running the accepted forms here
# would, as root, list every live session on the machine and prompt to terminate them, defaulting
# to YES. In a suite that `install.sh` runs as its verification phase, that is an install that
# hangs on a terminal read and one keystroke away from ending every session on the host.
#
# So acceptance is asserted at the PARSER, which is the thing actually being claimed about: it
# touches no host state and needs no privilege. The live command belongs to
# tests/manual/verify-live-flows.sh, behind its opt-in drill flag, which is the only place a real
# stop is ever issued.
#
# A subshell per call, because parse_command_line exits on a refusal and marks its globals
# readonly on success.
parse_status() { ( parse_command_line "$@" ) >/dev/null 2>&1; printf '%s' "$?"; }

if [[ "$(parse_status)" == "0" ]]; then
    pass "no argument parses cleanly -- it is THE documented form, not a usage error"
else
    fail "no argument was rejected by the parser (status $(parse_status))"
fi
# --all is accepted and inert, so a script that spells the intent out is never refused for being
# explicit -- and it must not turn into a second mode by accident: it sets none of the three flags.
if [[ "$(parse_status --all)" == "0" ]]; then
    pass "--all parses cleanly and is inert"
else
    fail "--all was rejected by the parser (status $(parse_status --all))"
fi
inert_check="$( ( parse_command_line --all; printf '%s|%s|%s' "${DRY_RUN}" "${ASSUME_YES}" "${FORCE_KILL}" ) 2>/dev/null )"
if [[ "${inert_check}" == "false|false|false" ]]; then
    pass "--all sets no flag of its own, so it cannot become a second mode"
else
    fail "--all changed the request: ${inert_check}"
fi

# Refusals ARE driven as a command, end to end against the deployed artifact, because each one
# exits inside the parser and can never reach the host.
run_helper() {
    set +e
    HELPER_OUTPUT="$(bash "${STOP_HELPER}" "$@" 2>&1)"
    HELPER_STATUS=$?
    set -e
}
run_helper --bogus
if (( HELPER_STATUS == 2 )); then
    pass "an unknown option exits 2"
else
    fail "unknown option: expected exit 2, got ${HELPER_STATUS}: ${HELPER_OUTPUT}"
fi
# A PATH IS REFUSED, NOT IGNORED. Accepting it and terminating everything anyway would invert what
# the operator asked for, in the destructive direction; and refusing keeps `--stop <path>` free to
# mean something narrower later without an existing command line silently changing meaning. The
# refusal has to NAME the alternatives, or it is a dead end mid-incident.
run_helper /some/project
if (( HELPER_STATUS == 2 )) \
        && grep -q 'takes no path' <<< "${HELPER_OUTPUT}" \
        && grep -q '/exit' <<< "${HELPER_OUTPUT}"; then
    pass "a path exits 2 and the refusal names /exit as the way to end one session"
else
    fail "a path: expected exit 2 naming /exit, got ${HELPER_STATUS}: ${HELPER_OUTPUT}"
fi
run_helper --all /some/project
if (( HELPER_STATUS == 2 )); then
    pass "a path is refused even beside --all"
else
    fail "--all with a path: expected exit 2, got ${HELPER_STATUS}: ${HELPER_OUTPUT}"
fi
# The one accepted form driven as a command, and ONLY when this run is unprivileged -- the guard
# is what makes it safe. Non-root, the helper exits 5 at its root check, which is still before
# resolve_cgroup_layout and main(), so the real slice is never enumerated. Do not remove the guard
# to "also cover root": as root this exact line reaches main() and prompts to terminate every
# session on the host.
if [[ "${EUID}" -ne 0 ]]; then
    run_helper --all --dry-run
    if (( HELPER_STATUS == 5 )); then
        pass "a non-root invocation is refused with the broken-tool code (5), not a stop code"
    else
        fail "non-root: expected exit 5, got ${HELPER_STATUS}: ${HELPER_OUTPUT}"
    fi
else
    skip "a non-root invocation is refused" "this run is root"
fi

finish

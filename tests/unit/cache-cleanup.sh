#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/cache-cleanup.sh
# Unit test for cache-cleanup.lib.sh: the one removal every path that empties a cache under the sandbox home goes
# through, the launch decision, and the state record both status reports read.
#
# What gives it teeth is the direction a removal must fail in. A sandbox process can rename an entry inside its own
# caches while a removal runs, and the remover runs outside the confined domain, so a walk that followed a link would
# delete whatever the account may unlink and a session may not -- the toolchain first. Every case therefore keeps
# a canary directory outside the fixture home, owned by the account, and asserts it intact: a link as the target,
# links inside the tree, and the swap race, where a loop running as the account flips a deep directory for a link
# to the canary while the remover walks. The same loop against a removal that walks by path is run as a control and
# its outcome recorded with `note`: it shows the race is reachable on this host, and a race that did not fire there
# does not fail the file. Each refusal is driven -- root and the projects user as the caller, an untrusted home,
# a symlinked parent, an undeclared group, a non-directory -- and asserted to leave the tree as it was.
#
# The pure half -- the launch decision, the state round trip through the defensive reader, the status verdict, the size
# format, and the guard and tool paths read as source -- runs unprivileged. The removals need root, which builds
# the root-owned fixture home the trust predicate accepts and runs each removal as the sandbox account through
# the harness's as_sandbox. The library names the account the installer substituted, so against a source-tree copy
# the removals skip with the reason named.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
umask 022

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="/usr/local/lib/ai-tools/cache-cleanup.lib.sh"
[[ -r "${LIB}" ]] || LIB="${REPO_ROOT}/src/usr/local/lib/ai-tools/cache-cleanup.lib.sh"

section "cache-cleanup: the launch decision and the state record (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "cache-cleanup" "library not found at ${LIB}"; finish; exit
fi
mktestdir
# shellcheck source=../../src/usr/local/lib/ai-tools/cache-cleanup.lib.sh
if ! source "${LIB}" || ! declare -F ai_tools_cache_cleanup__remove_group >/dev/null 2>&1; then
    fail "${LIB} did not load: a library it requires (conf, sandbox-exec, services) is missing beside it"
    finish; exit
fi

# ── The launch decision ───────────────────────────────────────────────────────────────────────
now=2000000000
day=86400
while IFS='|' read -r cleaned sessions want what; do
    [[ -n "${what}" ]] || continue
    got="$(ai_tools_cache_cleanup__evaluate_launch "${now}" "${cleaned}" "${sessions}")"
    [[ "${got}" == "${want}" ]] && pass "launch: ${what} -> ${want}" || fail "launch: ${what}: got '${got}', want '${want}'"
done <<ROWS
-|0|run|never cleaned, no other session
$(( now - 6 * day ))|0|not-due|cleaned 6 days ago
$(( now - 8 * day ))|0|run|cleaned 8 days ago, no other session
$(( now - 8 * day ))|2|sessions|cleaned 8 days ago, two other sessions
$(( now - 8 * day ))|unknown|unknown|cleaned 8 days ago, the session count unread
$(( now - 6 * day ))|unknown|not-due|not due reads no session count
$(( now + day ))|0|run|a cleaning dated after now is not evidence of a recent one
garbage|0|run|a value that is not an epoch reads as never cleaned
ROWS

# ── The state record, through the reader both status reports use ──────────────────────────────
state="${TESTDIR}/cache-cleanup.status"
: > "${state}"
ai_tools_cache_cleanup__write_state_locked "${state}" $'npm-cache\tremoved\t4617089024\t0\t-' $'npx\tpartial\t12\t3\ttimeout' \
    && pass "write_state_locked rewrites an existing file" || fail "write_state_locked refused an existing writable file"
[[ "$(ai_tools_services__read_stamp_field "${state}" NPM_CACHE_RESULT)" == removed \
   && "$(ai_tools_services__read_stamp_field "${state}" NPM_CACHE_BYTES)" == 4617089024 \
   && -n "$(ai_tools_services__read_stamp_field "${state}" NPM_CACHE_CLEANED)" \
   && "$(ai_tools_services__read_stamp_field "${state}" NPX_REASON)" == timeout \
   && -z "$(ai_tools_services__read_stamp_field "${state}" NPX_CLEANED)" ]] \
    && pass "a removal records CLEANED, a partial one records its reason and no CLEANED" \
    || fail "state: $(tr '\n' '|' <"${state}")"
cleaned_before="$(ai_tools_services__read_stamp_field "${state}" NPM_CACHE_CLEANED)"
ai_tools_cache_cleanup__write_state_locked "${state}" $'npm-cache\tfailed\t0\t0\twalk-error'
[[ "$(ai_tools_services__read_stamp_field "${state}" NPM_CACHE_CLEANED)" == "${cleaned_before}" \
   && "$(ai_tools_services__read_stamp_field "${state}" NPX_REASON)" == timeout ]] \
    && pass "a failure keeps the previous CLEANED, and a group the call does not name keeps its values" \
    || fail "state after a failure: $(tr '\n' '|' <"${state}")"
ai_tools_cache_cleanup__write_state_locked "${state}" $'npm-cache\tremoved\t1\t0\t-' $'npx\tremoved\tnot-a-number\t0\t-' \
    $'other\tremoved\t1\t0\t-'
[[ "$(ai_tools_services__read_stamp_field "${state}" NPX_RESULT)" == partial ]] && ! grep -q '^OTHER' "${state}" \
    && pass "a record outside its shape, or naming an undeclared group, is not written" \
    || fail "state after malformed records: $(tr '\n' '|' <"${state}")"
printf 'NPX_RESULT=removed\033[2J\nNODE_COMPILE_RESULT=failed\n' > "${state}"
[[ -z "$(ai_tools_services__read_stamp_field "${state}" NPX_RESULT)" ]] \
    && pass "a forged value carrying a control byte reads as no value" || fail "a forged value with an escape was read"
[[ "$(ai_tools_cache_cleanup__read_cleaned_epoch "${state}" npx)" == - ]] \
    && pass "a group with no CLEANED reads as never cleaned" || fail "an absent CLEANED read as an epoch"
ln -s "${state}" "${TESTDIR}/state-link"
ai_tools_cache_cleanup__write_state_locked "${TESTDIR}/state-link" $'npx\tremoved\t1\t0\t-' \
    && fail "write_state_locked wrote through a symlink" || pass "write_state_locked refuses a symlink"
ai_tools_cache_cleanup__write_state_locked "${TESTDIR}/absent" $'npx\tremoved\t1\t0\t-' \
    && fail "write_state_locked created a file" || pass "write_state_locked refuses a file that does not exist, and creates none"
[[ ! -e "${TESTDIR}/absent" ]] || fail "write_state_locked left a file at the absent path"
# FIRST_CHECKED is written once and kept, so a group never removed has an age the reports judge it by.
stamp_days_ago() { date -u -d "@$(( $(date -u +%s) - $1 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ; }
printf 'NPX_RESULT=skipped\nNPX_FIRST_CHECKED=2026-01-01T00:00:00Z\n' > "${state}"
ai_tools_cache_cleanup__write_state_locked "${state}" $'npx\tskipped\t0\t0\tsessions'
[[ "$(ai_tools_services__read_stamp_field "${state}" NPX_FIRST_CHECKED)" == 2026-01-01T00:00:00Z \
   && -n "$(ai_tools_services__read_stamp_field "${state}" NPX_CHECKED)" ]] \
    && pass "FIRST_CHECKED is kept across later records while CHECKED moves" || fail "state: $(tr '\n' '|' <"${state}")"
printf 'NPX_RESULT=skipped\nNPX_CHECKED=%s\nNPX_FIRST_CHECKED=%s\nNPX_REASON=sessions\nNODE_COMPILE_RESULT=skipped\nNODE_COMPILE_CHECKED=%s\nNODE_COMPILE_FIRST_CHECKED=%s\nNODE_COMPILE_CLEANED=%s\nNODE_COMPILE_REASON=sessions\n' \
    "$(stamp_days_ago 0)" "$(stamp_days_ago 15)" "$(stamp_days_ago 0)" "$(stamp_days_ago 15)" "$(stamp_days_ago 1)" > "${state}"
[[ "$(ai_tools_cache_cleanup__list_group_statuses "${state}" | awk -F'\t' '$1 == "npx" {print $3}')" == overdue \
   && "$(ai_tools_cache_cleanup__list_group_statuses "${state}" | awk -F'\t' '$1 == "node-compile" {print $3}')" == ok ]] \
    && pass "a launch group never removed is judged by its first record's age, one removed by its last removal's" \
    || fail "statuses: $(ai_tools_cache_cleanup__list_group_statuses "${state}" | tr '\n\t' '|>')"

# ── The status verdict and the size format ────────────────────────────────────────────────────
while IFS='|' read -r timing policy result links age reason want what; do
    [[ -n "${what}" ]] || continue
    got="$(ai_tools_cache_cleanup__evaluate_state "${timing}" "${policy}" "${result}" "${links}" "${age}" "${reason}")"
    [[ "${got}" == "${want}" ]] && pass "verdict: ${what} -> ${want}" || fail "verdict: ${what}: got '${got}', want '${want}'"
done <<ROWS
nightly|none||0|-|-|unknown|no result recorded
nightly|none|refused|0|10|home-untrusted|failed|a refusal counts
launch|expected|failed|0|10|walk-error|failed|a failure counts
nightly|none|partial|0|10|timeout|ok|a removal the bound cut short is continued by the next run, not counted
nightly|none|partial|0|10|eacces|failed|a partial removal by any other error counts
nightly|none|removed|2|10|-|links|links where the producer writes none count
launch|expected|removed|2|10|-|ok|links npm writes do not
launch|expected|skipped|0|$(( 15 * day ))|sessions|overdue|a launch group last cleaned 15 days ago counts
launch|expected|removed|0|$(( 13 * day ))|-|ok|one cleaned 13 days ago does not
nightly|none|removed|0|$(( 30 * day ))|-|ok|the nightly group is not judged by age
launch|none|skipped|0|-|sessions|ok|an unknown age does not make a group overdue
ROWS
while IFS='|' read -r bytes want; do
    [[ -n "${bytes}" ]] || continue
    got="$(ai_tools_cache_cleanup__format_bytes "${bytes}")"
    [[ "${got}" == "${want}" ]] && pass "size ${bytes} -> '${want}'" || fail "size ${bytes}: got '${got}', want '${want}'"
done <<'ROWS'
512|512 B
23068672|22 MiB
4617089024|4.2 GiB
abc|
ROWS

# ── The launch step: the admission, which groups it removes, and the bound ─────────────────────
# Driven over a fixture state file and a fixture admission lock with the removal stubbed as a shell function after
# the library loaded, so no tree is walked; both locks are the real flock. Each call runs in its own subshell, so a stub
# a case sets does not reach the next, and the subshell's exit releases the admission the call keeps.
section "cache-cleanup: the launch step (unit)"
launch_state="${TESTDIR}/launch.status"
launch_lock="${TESTDIR}/launch.lock"
launch_calls="${TESTDIR}/launch-calls"
# launch_step [removal-seconds] [hold-seconds] [partial-group] [session-count] : run remove_due_groups
#   with the removal stubbed to take <removal-seconds> and to report <partial-group> as `partial timeout`,
#   and the manager's listing stubbed to <session-count> (0 by default). The removals it asks for are appended
#   to launch_calls; stdout carries the records it collected, one per line, then the admission the subshell holds,
#   probed from another process (`admission held shared|held exclusive|unheld`), which it keeps for <hold-seconds>.
launch_step() {
    (
        stub_seconds="${1:-0}" stub_hold="${2:-0}" stub_partial="${3:-}" stub_sessions="${4:-0}"
        ai_tools_cache_cleanup__read_active_session_count() { printf 'listing %s\n' "$1" >> "${launch_calls}"; printf '%s' "${stub_sessions}"; }
        ai_tools_cache_cleanup__remove_group() {
            printf 'remove %s %s\n' "$2" "$3" >> "${launch_calls}"; sleep "${stub_seconds}"
            if [[ "$2" == "${stub_partial}" ]]; then printf '%s\tpartial\t0\t0\ttimeout\n' "$2"
            else printf '%s\tremoved\t1048576\t0\t-\n' "$2"; fi
        }
        declare -a records=()
        ai_tools_cache_cleanup__remove_due_groups "${TESTDIR}" "${launch_state}" "${launch_lock}" 'acct-*-*.service' records
        (( ${#records[@]} == 0 )) || printf '%s\n' "${records[@]}"
        if /usr/bin/flock -n -x "${launch_lock}" -c true 2>/dev/null; then printf 'admission unheld\n'
        elif /usr/bin/flock -n -s "${launch_lock}" -c true 2>/dev/null; then printf 'admission held shared\n'
        else printf 'admission held exclusive\n'; fi
        sleep "${stub_hold}"
    )
}
reset_lock() { rm -f "${launch_lock}"; : > "${launch_lock}"; chmod 0440 "${launch_lock}"; }
: > "${launch_state}"; : > "${launch_calls}"; reset_lock
out="$(launch_step)"
[[ "$(grep -c '^remove ' "${launch_calls}")" == 2 && "$(grep -c '^remove npm-cache' "${launch_calls}")" == 0 \
   && "$(grep -c $'\tremoved\t' <<<"${out}")" == 2 && "$(grep -c '^listing acct-\*-\*.service$' "${launch_calls}")" == 1 ]] \
    && pass "never cleaned, no session held or listed: the launch is the cleaner, both launch groups are removed and the nightly group is not" \
    || fail "first launch: calls '$(tr '\n' '|' <"${launch_calls}")', records '$(tr '\n\t' '|>' <<<"${out}")'"
grep -qx 'admission held shared' <<<"${out}" \
    && pass "the cleaner holds the admission shared once its records are written" \
    || fail "admission after the cleaner's run: $(grep admission <<<"${out}" || true)"
grep -qE '^remove (npx|node-compile) (29|30)$' "${launch_calls}" \
    && pass "a removal is given the time left of the step's bound" || fail "bound passed: $(tr '\n' '|' <"${launch_calls}")"
[[ -n "$(ai_tools_services__read_stamp_field "${launch_state}" NPX_CLEANED)" \
   && -n "$(ai_tools_services__read_stamp_field "${launch_state}" NODE_COMPILE_CLEANED)" \
   && -n "$(ai_tools_services__read_stamp_field "${launch_state}" NPX_FIRST_CHECKED)" ]] \
    && pass "the removals are recorded with CLEANED and FIRST_CHECKED" || fail "state after a launch: $(tr '\n' '|' <"${launch_state}")"
: > "${launch_calls}"
out="$(launch_step)"
[[ "${out}" == 'admission held shared' && "$(grep -c '^remove ' "${launch_calls}")" == 0 ]] \
    && pass "a launch with no group due takes its admission and reads the state alone: no removal, no record" \
    || fail "second launch: calls '$(tr '\n' '|' <"${launch_calls}")', output '$(tr '\n\t' '|>' <<<"${out}")'"
# The lock is free and the manager lists a session the lock does not represent -- an older shim's, or one whose launch
# was not admitted -- so the exclusive holder is not the cleaner: nothing removed, each due group skipped sessions,
# and the admission still held shared for the session this launch starts. A listing that could not be read reads
# the same way under `unknown`.
for listed_case in 2 unknown; do
    : > "${launch_state}"; : > "${launch_calls}"
    out="$(launch_step 0 0 '' "${listed_case}")"
    want_reason=sessions; [[ "${listed_case}" == unknown ]] && want_reason=unknown
    [[ "$(grep -c '^remove ' "${launch_calls}")" == 0 && "$(grep -c $'\tskipped\t0\t0\t'"${want_reason}"'$' <<<"${out}")" == 2 ]] \
       && grep -qx 'admission held shared' <<<"${out}" \
        && pass "a listing of ${listed_case} with the lock free skips both groups as ${want_reason}, and the launch keeps its admission" \
        || fail "listing ${listed_case}: calls '$(tr '\n' '|' <"${launch_calls}")', output '$(tr '\n\t' '|>' <<<"${out}")'"
done
# The due test reads the state under its lock: a writer holding it -- the nightly updater mid-rewrite, whose write
# truncates the file first -- makes the cleaner wait, and the fresh CLEANED values it then reads are not due.
: > "${launch_state}"; : > "${launch_calls}"
ai_tools_cache_cleanup__write_state_locked "${launch_state}" $'npx\tremoved\t1\t0\t-' $'node-compile\tremoved\t1\t0\t-'
/usr/bin/flock -x "${launch_state}" sleep 1.5 &
writer_holder=$!
sleep 0.2
started=${SECONDS}
out="$(launch_step)"
waited=$(( SECONDS - started ))
wait "${writer_holder}" || true
[[ "$(grep -c '^remove ' "${launch_calls}")" == 0 ]] && (( waited >= 1 )) && ! grep -q $'\t' <<<"${out}" \
   && grep -qx 'admission held shared' <<<"${out}" \
    && pass "the due test waits for the state lock a writer holds (waited ${waited}s) and reads the fresh cleanup rather than an empty file" \
    || fail "state locked by a writer: waited ${waited}s, calls '$(tr '\n' '|' <"${launch_calls}")', output '$(tr '\n\t' '|>' <<<"${out}")'"
# A session holds the admission shared: the launch is admitted beside it at once and removes nothing, each due group
# recorded skipped sessions.
: > "${launch_state}"; : > "${launch_calls}"
/usr/bin/flock -s "${launch_lock}" sleep 3 &
session_holder=$!
sleep 0.3
out="$(launch_step)"
[[ "$(grep -c '^remove ' "${launch_calls}")" == 0 && "$(grep -c $'\tskipped\t0\t0\tsessions$' <<<"${out}")" == 2 \
   && "$(ai_tools_services__read_stamp_field "${launch_state}" NPX_RESULT)" == skipped \
   && -z "$(ai_tools_services__read_stamp_field "${launch_state}" NPX_CLEANED)" \
   && -n "$(ai_tools_services__read_stamp_field "${launch_state}" NPX_FIRST_CHECKED)" ]] && grep -qx 'admission held shared' <<<"${out}" \
    && pass "a session holding the admission skips both groups, recorded skipped sessions with FIRST_CHECKED, and the launch is admitted beside it" \
    || fail "session holding the lock: calls '$(tr '\n' '|' <"${launch_calls}")', output '$(tr '\n\t' '|>' <<<"${out}")'"
wait "${session_holder}" || true
# No lock file: the launch is unadmitted, removes nothing, and records each due group skipped unknown.
: > "${launch_state}"; : > "${launch_calls}"; rm -f "${launch_lock}"
out="$(launch_step)"
[[ "$(grep -c '^remove ' "${launch_calls}")" == 0 && "$(grep -c $'\tskipped\t0\t0\tunknown$' <<<"${out}")" == 2 ]] \
   && grep -qx 'admission unheld' <<<"${out}" \
    && pass "a lock file that cannot be opened leaves the launch unadmitted: nothing removed, each group skipped unknown" \
    || fail "absent lock: calls '$(tr '\n' '|' <"${launch_calls}")', output '$(tr '\n\t' '|>' <<<"${out}")'"
# A launch arriving while the cleaner removes is admitted only once the cleaner has written its records and shared
# the lock, so the removal and the session do not overlap, and it finds the groups not due.
: > "${launch_state}"; : > "${launch_calls}"; reset_lock
launch_step 1 > "${TESTDIR}/cleaner.out" &
cleaner=$!
sleep 0.3
started=${SECONDS}
out="$(launch_step)"
waited=$(( SECONDS - started ))
wait "${cleaner}" || true
[[ "$(grep -c '^remove ' "${launch_calls}")" == 2 ]] && (( waited >= 1 )) && ! grep -q $'\t' <<<"${out}" \
   && grep -qx 'admission held shared' <<<"${out}" \
    && pass "a launch arriving while the cleaner removes is admitted after it (waited ${waited}s) and removes nothing it cleaned" \
    || fail "contended launch: waited ${waited}s, calls '$(tr '\n' '|' <"${launch_calls}")', output '$(tr '\n\t' '|>' <<<"${out}")'"
# A group the cleaner's partial removal left due is not retried while that cleaner's session holds the admission.
: > "${launch_state}"; : > "${launch_calls}"; reset_lock
launch_step 0 3 npx > "${TESTDIR}/partial.out" &
partial_holder=$!
sleep 1
out="$(launch_step)"
wait "${partial_holder}" || true
[[ "$(grep -c '^remove npx' "${launch_calls}")" == 1 ]] && grep -q $'^npx\tskipped\t0\t0\tsessions$' <<<"${out}" \
   && ! grep -q 'node-compile' <<<"${out}" \
    && pass "a group a partial removal left due is skipped, not retried, while the cleaner's session holds the admission" \
    || fail "partial then a launch: calls '$(tr '\n' '|' <"${launch_calls}")', output '$(tr '\n\t' '|>' <<<"${out}")'"

while IFS='|' read -r records want what; do
    [[ -n "${what}" ]] || continue
    mapfile -t record_list < <(printf '%b' "${records}")
    got="$(ai_tools_cache_cleanup__format_cleaned_line "${record_list[@]}")"
    [[ "${got}" == "${want}" ]] && pass "line: ${what}" || fail "line: ${what}: got '${got}', want '${want}'"
done <<'ROWS'
npx\tremoved\t23068672\t0\t-\nnode-compile\tremoved\t16777216\t0\t-|cleaned .npm/_npx (22 MiB), .cache/node-compile-cache (16 MiB)|two removals in one line
npx\tskipped\t0\t0\tsessions\nnode-compile\tabsent\t0\t0\t-||a skip and an absent group print no line
npx\tpartial\t5\t0\ttimeout\nnode-compile\tremoved\t512\t0\t-|cleaned .cache/node-compile-cache (512 B)|a partial removal is not named as cleaned
ROWS

# ── The guard and the tool paths, read as source ──────────────────────────────────────────────
# The walk refuses where Python does not report the fd-based rmtree, and every tool is named by absolute path, since
# the bootstrap's step runs with PATH=/usr/bin:/bin and a launch's environment is the shim's allowlist.
grep -q 'getattr(shutil.rmtree, "avoids_symlink_attacks", False)' "${LIB}" \
    && grep -q 'finish("refused", reason="unsafe-rmtree")' "${LIB}" \
    && pass "the walk refuses where shutil.rmtree does not avoid symlink attacks" \
    || fail "the avoids_symlink_attacks guard is no longer where this reads it"
# A tool's name as a value -- the reason token `timeout` compared with `==` -- is not a command, so a comparison operand
# is left out of the reading.
bare_tools="$(grep -nE '(^|[ ;(|&])(python3|timeout|flock|date|stat)( |$)' "${LIB}" | grep -vE '^\s*[0-9]+:\s*#' \
    | grep -vE '/usr/bin/(python3|timeout|flock|date|stat)|[=!]= (python3|timeout|flock|date|stat) ' || true)"
[[ -z "${bare_tools}" ]] && pass "every tool the library runs is named by absolute path" \
    || fail "a tool named by its bare name: $(tr '\n' '|' <<<"${bare_tools}")"
[[ "$(/usr/bin/python3 -I -c 'import shutil; print(shutil.rmtree.avoids_symlink_attacks)')" == True ]] \
    && pass "this host's /usr/bin/python3 reports a symlink-safe rmtree" \
    || fail "this host's /usr/bin/python3 does not report a symlink-safe rmtree, so no cache is removed here"

# ── Removals: as the sandbox account over a fixture home ──────────────────────────────────────
section "cache-cleanup: removals as the sandbox account (unit)"
if [[ "${EUID}" -ne 0 ]]; then
    skip "the removals" "needs root to build the root-owned fixture home and run each removal as ${SANDBOX_USER}"
    finish; exit
fi
if [[ -z "$(ai_tools_sandbox_exec__read_sandbox_uid)" ]]; then
    if [[ "${LIB}" == /usr/local/lib/ai-tools/* ]]; then
        fail "the installed sandbox-exec.lib.sh names no account this host has -- the account token was not substituted at install"
    else
        skip "the removals" "the library at ${LIB} names no account this host has (a source-tree copy)"
    fi
    finish; exit
fi

HOME_DIR="${TESTDIR}/home"; CANARY="${TESTDIR}/canary"; ERR="${TESTDIR}/err"
# fixture : a root-owned 0755 home holding account-owned .npm and .cache, and the canary beside it, account-owned.
fixture() {
    rm -rf "${HOME_DIR}" "${CANARY}"
    mkdir -m 0755 "${HOME_DIR}"
    mkdir -p "${HOME_DIR}/.npm" "${HOME_DIR}/.cache" "${CANARY}/dir"
    printf 'keep\n' > "${CANARY}/file"; printf 'keep\n' > "${CANARY}/dir/inner"
}
own() { chown -R "${SANDBOX_USER}:${SANDBOX_GROUP}" "${HOME_DIR}/.npm" "${HOME_DIR}/.cache" "${CANARY}"; }
canary_intact() { [[ "$(<"${CANARY}/file")" == keep && "$(<"${CANARY}/dir/inner")" == keep ]]; }
# remove_as_sandbox <home> <group> [seconds] : the removal as the sandbox account; the record on stdout, stderr in ERR.
remove_as_sandbox() {
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    as_sandbox bash -c 'source "$1" || exit 99; shift; ai_tools_cache_cleanup__remove_group "$@"' _ "${LIB}" "$@" 2>"${ERR}"
}
record_is() {  # <record> <want> <what>
    [[ "$1" == "$2" ]] && pass "$3" || fail "$3: got '$(tr '\t' '>' <<<"$1")', want '$(tr '\t' '>' <<<"$2")'"
}

# 1. The identity: root and the projects user are refused, and the tree is left.
fixture; mkdir -p "${HOME_DIR}/.npm/_cacache/a"; own
rc=0; out="$(ai_tools_cache_cleanup__remove_group "${HOME_DIR}" npm-cache 2>/dev/null)" || rc=$?
record_is "${out}" $'npm-cache\trefused\t0\t0\tnot-sandbox' "root as the caller is refused"
(( rc == 1 )) && [[ -d "${HOME_DIR}/.npm/_cacache/a" ]] && pass "root's refusal returns 1 and removes nothing" \
    || fail "root's refusal: rc ${rc}, tree $( [[ -d "${HOME_DIR}/.npm/_cacache/a" ]] && echo left || echo gone)"
# shellcheck disable=SC2016  # the inner shell expands these, not this one
out="$(runuser -u "${PROJECTS_USER}" -- bash -c 'source "$1"; ai_tools_cache_cleanup__remove_group "$2" npm-cache' \
    _ "${LIB}" "${HOME_DIR}" 2>/dev/null || true)"
record_is "${out}" $'npm-cache\trefused\t0\t0\tnot-sandbox' "the projects user as the caller is refused"
[[ -d "${HOME_DIR}/.npm/_cacache/a" ]] && pass "the projects user's refusal removes nothing" || fail "the projects user removed the tree"

# 2. The home, the parent, the group, the target's type.
chmod 0775 "${HOME_DIR}"
record_is "$(remove_as_sandbox "${HOME_DIR}" npm-cache || true)" $'npm-cache\trefused\t0\t0\thome-untrusted' \
    "a group-writable home is refused"
chmod 0755 "${HOME_DIR}"
ln -s "${HOME_DIR}" "${TESTDIR}/home-link"
record_is "$(remove_as_sandbox "${TESTDIR}/home-link" npm-cache || true)" $'npm-cache\trefused\t0\t0\thome-untrusted' \
    "a symlinked home is refused"
assert_msg MSG-G5U7 "$(<"${ERR}")" "a refusal is reported under its code"
mv "${HOME_DIR}/.npm" "${CANARY}/npm"; ln -s "${CANARY}/npm" "${HOME_DIR}/.npm"
record_is "$(remove_as_sandbox "${HOME_DIR}" npm-cache || true)" $'npm-cache\trefused\t0\t0\tparent-untrusted' \
    "a parent that is a link to a directory outside the home is refused"
[[ -d "${CANARY}/npm/_cacache/a" ]] && pass "the link's target is left as it was" || fail "the parent link's target was entered"
rm "${HOME_DIR}/.npm"; mv "${CANARY}/npm" "${HOME_DIR}/.npm"
record_is "$(remove_as_sandbox "${HOME_DIR}" '../../canary' || true)" $'-\trefused\t0\t0\tunknown-group' \
    "an undeclared group is refused, and its name is not echoed"
printf 'x\n' > "${HOME_DIR}/.npm/_npx"; own
record_is "$(remove_as_sandbox "${HOME_DIR}" npx || true)" $'npx\trefused\t0\t0\tnot-a-directory' \
    "a target that is not a directory is refused"
[[ -f "${HOME_DIR}/.npm/_npx" ]] && pass "the non-directory is left" || fail "the non-directory was removed"

# 3. A removal, with its bytes and links counted once per inode; then absent.
fixture; mkdir -p "${HOME_DIR}/.npm/_cacache/a/b"
head -c 5000 /dev/zero > "${HOME_DIR}/.npm/_cacache/a/b/blob"; head -c 100 /dev/zero > "${HOME_DIR}/.npm/_cacache/x"
ln "${HOME_DIR}/.npm/_cacache/x" "${HOME_DIR}/.npm/_cacache/a/x-hardlink"; own
record_is "$(remove_as_sandbox "${HOME_DIR}" npm-cache || true)" $'npm-cache\tremoved\t5100\t0\t-' \
    "a removal reports the bytes it removed, a hardlinked file once"
[[ ! -e "${HOME_DIR}/.npm/_cacache" && -d "${HOME_DIR}/.npm" ]] && pass "the group's directory is gone and its parent stays" \
    || fail "after the removal: $(ls -A "${HOME_DIR}/.npm" | tr '\n' ' ')"
rc=0; out="$(remove_as_sandbox "${HOME_DIR}" npm-cache)" || rc=$?
record_is "${out}" $'npm-cache\tabsent\t0\t0\t-' "a group already gone is absent"
(( rc == 0 )) && pass "absent returns 0" || fail "absent returned ${rc}"

# 4. A link as the target, pointing at the canary: the link goes, the canary stays.
fixture; ln -s "${CANARY}" "${HOME_DIR}/.npm/_cacache"; own; chown -h "${SANDBOX_USER}:${SANDBOX_GROUP}" "${HOME_DIR}/.npm/_cacache"
record_is "$(remove_as_sandbox "${HOME_DIR}" npm-cache || true)" $'npm-cache\tremoved\t0\t1\t-' \
    "a link as the target is unlinked and counted as one link"
[[ ! -L "${HOME_DIR}/.npm/_cacache" ]] && canary_intact && pass "the link is gone and the canary intact" \
    || fail "after a link as the target: canary $(canary_intact && echo intact || echo damaged)"
assert_msg MSG-J4Y8 "$(<"${ERR}")" "a link where npm's cache holds none is reported under its code"

# 5. Links inside, to a file and to a directory in the canary: unlinked, targets intact, counted; npx records them
#    without a finding.
fixture; mkdir -p "${HOME_DIR}/.npm/_npx/n/node_modules/.bin"
ln -s "${CANARY}/file" "${HOME_DIR}/.npm/_npx/n/node_modules/.bin/tool"
ln -s "${CANARY}/dir" "${HOME_DIR}/.npm/_npx/n/to-dir"; own
record_is "$(remove_as_sandbox "${HOME_DIR}" npx || true)" $'npx\tremoved\t0\t2\t-' "links inside the tree are counted"
canary_intact && pass "each link's target is intact" || fail "a link inside the tree was followed into the canary"
grep -qx MSG-J4Y8 "${ERR}" && fail "links npm writes under _npx were reported as a finding" \
    || pass "links under _npx are not a finding"

# The journal records the removal before and after, through log.lib.sh: driven with the structured writer stubbed
# to stderr, after the library loaded.
fixture; mkdir -p "${HOME_DIR}/.cache/node-compile-cache/x"; own
# shellcheck disable=SC2016  # the inner shell expands these, not this one
as_sandbox bash -c 'source "$1"; ai_tools_log__structured() { printf "JOURNAL %s %s\n" "$1" "$2" >&2; }
    ai_tools_cache_cleanup__remove_group "$2" node-compile' _ "${LIB}" "${HOME_DIR}" >/dev/null 2>"${ERR}" || true
journal="$(grep '^JOURNAL' "${ERR}" || true)"
[[ "$(sed -n 1p <<<"${journal}")" == "JOURNAL debug removing ${HOME_DIR}/.cache/node-compile-cache" \
   && "$(sed -n 2p <<<"${journal}")" == "JOURNAL info removed ${HOME_DIR}/.cache/node-compile-cache"* ]] \
    && pass "the removal is journalled before it starts and after it ends" \
    || fail "journal lines: $(tr '\n' '|' <<<"${journal}")"

# 6. The swap race. A loop running as the account flips every d*/deep/x for a link to the canary and back with direct
#    renames while the remover walks; 20 repetitions, the canary intact after each. The control is the same loop against
#    a removal that checks for a link and then lists the directory by path: the race is the window between the two.
section "cache-cleanup: the swap race (unit)"
readonly SWAP_PROGRAM=$'import os, sys\nroot, canary = sys.argv[1], sys.argv[2]\nxs = ["%s/d%d/deep/x" % (root, i) for i in range(1, 31)]\nwhile True:\n    for x in xs:\n        try:\n            os.rename(x, x + ".real"); os.symlink(canary, x); os.unlink(x); os.rename(x + ".real", x)\n        except OSError:\n            pass'
readonly PATH_WALK_PROGRAM=$'import os, sys\ndef remove(p):\n    for name in os.listdir(p):\n        full = os.path.join(p, name)\n        if os.path.isdir(full) and not os.path.islink(full):\n            remove(full)\n        else:\n            try:\n                os.unlink(full)\n            except OSError:\n                pass\n    try:\n        os.rmdir(p)\n    except OSError:\n        pass\ntry:\n    remove(sys.argv[1])\nexcept OSError:\n    pass'
race_tree() {
    fixture
    local i j
    for i in $(seq 1 30); do
        mkdir -p "${HOME_DIR}/.cache/node-compile-cache/d${i}/deep/x"
        for j in $(seq 1 40); do : > "${HOME_DIR}/.cache/node-compile-cache/d${i}/deep/x/f${j}"; done
    done
    for j in $(seq 1 40); do : > "${CANARY}/f${j}"; done
    own
}
# The numbered files alone: the fixture's `file` beside them is canary_intact's, and a glob that took it would read 41.
canary_count() { find "${CANARY}" -maxdepth 1 -name 'f[0-9]*' | wc -l; }
# race <remover> : run the swap loop beside <remover> as the account; `lib` runs the library's removal.
race() {
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    as_sandbox bash -c 'source "$1"; tree="$2/.cache/node-compile-cache"
        /usr/bin/python3 -I -c "$4" "${tree}" "$3" & swapper=$!
        if [[ "$6" == lib ]]; then ai_tools_cache_cleanup__remove_group "$2" node-compile 60 >/dev/null 2>&1 || true
        else /usr/bin/python3 -I -c "$5" "${tree}" 2>/dev/null || true; fi
        kill "${swapper}" 2>/dev/null; wait "${swapper}" 2>/dev/null; exit 0' \
        _ "${LIB}" "${HOME_DIR}" "${CANARY}" "${SWAP_PROGRAM}" "${PATH_WALK_PROGRAM}" "$1" >/dev/null 2>&1 || true
}
# The measurement proves its setup first: a fixture that does not read as intact before any removal would report
# the remover on every run below.
race_tree
if (( $(canary_count) == 40 )) && canary_intact; then
    pass "the race fixture reads as intact before any removal"
else
    fail "the race fixture does not read as intact before any removal: $(canary_count) numbered files, canary $(canary_intact && echo intact || echo damaged)"
fi
remover_damaged=0; control_damaged=0
for _ in $(seq 1 20); do
    race_tree; race lib
    (( $(canary_count) == 40 )) && canary_intact || remover_damaged=$(( remover_damaged + 1 ))
    race_tree; race control
    (( $(canary_count) == 40 )) && canary_intact || control_damaged=$(( control_damaged + 1 ))
done
(( remover_damaged == 0 )) && pass "the canary is intact after each of 20 removals under the swap loop" \
    || fail "the remover deleted inside the canary in ${remover_damaged} of 20 runs"
note "the path-walking control" "it deleted inside the canary in ${control_damaged} of 20 runs on this host"

# 7. The bound: a tree large enough to outlast one second ends partial, part removed, at status 1.
section "cache-cleanup: the bound (unit)"
fixture
/usr/bin/python3 -I -c 'import os, sys
root = sys.argv[1]
for d in range(400):
    os.makedirs("%s/d%d" % (root, d))
    for f in range(500):
        os.close(os.open("%s/d%d/f%d" % (root, d, f), os.O_CREAT | os.O_WRONLY, 0o644))' "${HOME_DIR}/.npm/_npx"
own
rc=0; out="$(remove_as_sandbox "${HOME_DIR}" npx 1)" || rc=$?
IFS=$'\t' read -r _ result _ _ reason <<<"${out}"
if [[ "${result}" == removed ]]; then
    skip "the bound" "this host removed 200000 files inside one second, so the bound did not cut the walk short"
elif [[ "${result}" == partial && "${reason}" == timeout ]] && (( rc == 1 )) && [[ -d "${HOME_DIR}/.npm/_npx" ]]; then
    pass "a walk past its bound is partial timeout, returns 1 and leaves the rest of the tree"
else
    fail "bounded walk: rc ${rc}, record '$(tr '\t' '>' <<<"${out}")'"
fi

finish

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

# ── The status verdict and the size format ────────────────────────────────────────────────────
while IFS='|' read -r timing policy result links age want what; do
    [[ -n "${what}" ]] || continue
    got="$(ai_tools_cache_cleanup__evaluate_state "${timing}" "${policy}" "${result}" "${links}" "${age}")"
    [[ "${got}" == "${want}" ]] && pass "verdict: ${what} -> ${want}" || fail "verdict: ${what}: got '${got}', want '${want}'"
done <<ROWS
nightly|none||0|-|unknown|no result recorded
nightly|none|refused|0|10|failed|a refusal counts
launch|expected|failed|0|10|failed|a failure counts
nightly|none|removed|2|10|links|links where the producer writes none count
launch|expected|removed|2|10|ok|links npm writes do not
launch|expected|skipped|0|$(( 15 * day ))|overdue|a launch group last cleaned 15 days ago counts
launch|expected|removed|0|$(( 13 * day ))|ok|one cleaned 13 days ago does not
nightly|none|removed|0|$(( 30 * day ))|ok|the nightly group is not judged by age
launch|none|skipped|0|-|ok|an unknown age does not make a group overdue
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

# ── The launch step: which groups it removes, under the lock and the bound ─────────────────────
# Driven over a fixture state file with the removal and the session count stubbed as shell functions after the library
# loaded, so no tree is walked and no manager is asked; the lock is the real flock. Each call runs in its own subshell,
# so a stub a case sets does not reach the next.
section "cache-cleanup: the launch step (unit)"
launch_state="${TESTDIR}/launch.status"
launch_calls="${TESTDIR}/launch-calls"
# launch_step <session-count> : run remove_due_groups with the session count stubbed; the removals it asks for are
#   appended to launch_calls, the records it prints are stdout.
launch_step() {
    (
        stub_session_count="$1"
        ai_tools_cache_cleanup__read_active_session_count() { printf 'session-count %s\n' "$1" >> "${launch_calls}"; printf '%s' "${stub_session_count}"; }
        ai_tools_cache_cleanup__remove_group() { printf 'remove %s %s\n' "$2" "$3" >> "${launch_calls}"; printf '%s\tremoved\t1048576\t0\t-\n' "$2"; }
        ai_tools_cache_cleanup__remove_due_groups "${TESTDIR}" "${launch_state}" 'acct-*-*.service'
    )
}
: > "${launch_state}"; : > "${launch_calls}"
out="$(launch_step 0)"
[[ "$(grep -c '^remove ' "${launch_calls}")" == 2 && "$(grep -c '^remove npm-cache' "${launch_calls}")" == 0 \
   && "$(grep -c $'\tremoved\t' <<<"${out}")" == 2 && "$(grep -c '^session-count acct-\*-\*.service$' "${launch_calls}")" == 1 ]] \
    && pass "never cleaned, no other session: both launch groups are removed and the nightly group is not" \
    || fail "first launch: calls '$(tr '\n' '|' <"${launch_calls}")', records '$(tr '\n\t' '|>' <<<"${out}")'"
grep -qE '^remove (npx|node-compile) (29|30)$' "${launch_calls}" \
    && pass "a removal is given the time left of the step's bound" || fail "bound passed: $(tr '\n' '|' <"${launch_calls}")"
[[ -n "$(ai_tools_services__read_stamp_field "${launch_state}" NPX_CLEANED)" \
   && -n "$(ai_tools_services__read_stamp_field "${launch_state}" NODE_COMPILE_CLEANED)" ]] \
    && pass "the removals are recorded with CLEANED" || fail "state after a launch: $(tr '\n' '|' <"${launch_state}")"
: > "${launch_calls}"
out="$(launch_step 0)"
[[ -z "${out}" && ! -s "${launch_calls}" ]] \
    && pass "a launch with no group due reads the state alone: no session count, no removal, no record" \
    || fail "second launch: calls '$(tr '\n' '|' <"${launch_calls}")', records '$(tr '\n\t' '|>' <<<"${out}")'"
for sessions_case in 3 unknown; do
    : > "${launch_state}"; : > "${launch_calls}"
    out="$(launch_step "${sessions_case}")"
    want_reason=sessions; [[ "${sessions_case}" == unknown ]] && want_reason=unknown
    [[ "$(grep -c '^remove ' "${launch_calls}")" == 0 && "$(grep -c $'\tskipped\t0\t0\t'"${want_reason}"'$' <<<"${out}")" == 2 \
       && "$(ai_tools_services__read_stamp_field "${launch_state}" NPX_RESULT)" == skipped \
       && -z "$(ai_tools_services__read_stamp_field "${launch_state}" NPX_CLEANED)" ]] \
        && pass "a session count of ${sessions_case} skips both groups, recorded as skipped ${want_reason}" \
        || fail "session count ${sessions_case}: calls '$(tr '\n' '|' <"${launch_calls}")', records '$(tr '\n\t' '|>' <<<"${out}")'"
done
# Serialized: a launch holding the lock makes the next one wait, and the waiter re-reads the due test under the lock,
# so a group the holder cleaned while it waited is not removed twice. The holder takes the lock with both groups due,
# writes CLEANED for both once the second launch has read them as due and is waiting, and releases.
: > "${launch_state}"; : > "${launch_calls}"
(
    ai_tools_cache_cleanup__lock "${launch_state}" 5 || exit 1
    sleep 1
    ai_tools_cache_cleanup__write_state_locked "${launch_state}" $'npx\tremoved\t1\t0\t-' $'node-compile\tremoved\t1\t0\t-'
    sleep 1
    ai_tools_cache_cleanup__unlock
) &
lock_holder=$!
sleep 0.5
started=${SECONDS}
out="$(launch_step 0)"
waited=$(( SECONDS - started ))
wait "${lock_holder}" || true
[[ -z "${out}" && "$(grep -c '^remove ' "${launch_calls}")" == 0 ]] && (( waited >= 1 )) \
    && pass "a second launch waits for the lock and does not remove what the first just cleaned (waited ${waited}s)" \
    || fail "contended launch: waited ${waited}s, calls '$(tr '\n' '|' <"${launch_calls}")', records '$(tr '\n\t' '|>' <<<"${out}")'"

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
bare_tools="$(grep -nE '(^|[ ;(|&])(python3|timeout|flock|date|stat)( |$)' "${LIB}" | grep -vE '^\s*[0-9]+:\s*#' \
    | grep -vE '/usr/bin/(python3|timeout|flock|date|stat)' || true)"
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

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/relabel.sh
# Unit test for the entrypoint file-context predicate (relabel.lib.sh): the pure
# ai_tools_entrypoint_fcontext_valid that gates every pattern an agent manifest declares before
# it becomes a `semanage fcontext` rule mapping files to ai_tools_exec_t -- the exec entrypoint of
# the confined domain.
#
# The property under test is containment: a declared pattern may only ever match inside the
# sandbox's own Node toolchain. A manifest is root-owned, so this is defense in depth rather than
# the only guard, but the failure it prevents is severe and silent -- a pattern with an
# alternation, a traversal, or a foreign prefix would hand ai_tools_exec_t to a file outside the
# toolchain, making it an entrypoint into the agent's domain. The type itself is never
# manifest-supplied, which this file also pins.
#
# Sources the deployed library; no SELinux host, no privilege of its own. Run as root via sudo
# (suite contract).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/relabel.lib.sh"
section "relabel: agent entrypoint file-context validation (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "entrypoint fcontext validation" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" || ! declare -F ai_tools_entrypoint_fcontext_valid >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define ai_tools_entrypoint_fcontext_valid"
    finish; exit
fi

# accepts/rejects <pattern> [why]
accepts() {
    if ai_tools_entrypoint_fcontext_valid "$1"; then pass "accepts ${1:-<empty>}"
    else fail "rejected a valid entrypoint pattern: $1"; fi
}
rejects() {
    if ai_tools_entrypoint_fcontext_valid "$1"; then fail "ACCEPTED ${2}: ${1:-<empty>}"
    else pass "rejects ${2}"; fi
}

# The shipped shape, and the same path written without the SELinux backslash escapes.
accepts '/opt/ai-tools/\.nvm/versions/node/[^/]+/lib/node_modules/@anthropic-ai/claude-code/bin/claude\.exe'
accepts '/opt/ai-tools/.nvm/versions/node/[^/]+/bin/some-agent'

# Containment: every way a pattern could name something outside the toolchain root.
rejects ''                                              "an empty pattern"
rejects '/etc/shadow'                                   "a path outside the toolchain root"
rejects '/usr/bin/sudo'                                 "a host binary"
rejects '/opt/ai-tools/.nvm/versions/node/../../../usr/bin/sudo' "a parent-directory traversal"
rejects '/opt/ai-tools/.nvm/versions/node/x|/usr/bin/sudo'       "an alternation escaping the root"
rejects '(/usr/bin/sudo|/opt/ai-tools/.nvm/versions/node/x)'     "a group whose first branch is foreign"
rejects '.*'                                            "a match-anything pattern"
# shellcheck disable=SC2016  # the literal $(...) is the input under test, not an expansion
rejects '/opt/ai-tools/.nvm/versions/node/$(id)/bin/x'  "a shell-substitution character"
rejects '/opt/ai-tools/.nvm/versions/node/a b/bin/x'    "whitespace in the pattern"

# The entrypoint TYPE is the library's, never a manifest's: an agent declares which file is its
# entrypoint, not what label a file gets. A manifest that could name the type could name any
# type -- the reason this constant lives here.
if [[ "${AI_TOOLS_ENTRYPOINT_TYPE:-}" == "ai_tools_exec_t" ]]; then
    pass "the entrypoint type is pinned by the library (ai_tools_exec_t)"
else
    fail "AI_TOOLS_ENTRYPOINT_TYPE is '${AI_TOOLS_ENTRYPOINT_TYPE:-unset}', not the pinned ai_tools_exec_t"
fi

# ── Reconciling the declared rule against the INSTALLED entrypoint ────────────────────────────
# The label is applied from the manifest's declared pattern, but the SELinux transition fires on
# the inode the launcher symlink resolves to -- so the two can disagree, and did nothing about it
# the relabel would report success while every launch fail-closed on an unlabelled entrypoint.
# ai_tools_entrypoint_reconcile_verdict is the pure decision that closes that: `stale` is the
# verdict that must make a relabel FAIL, because it is the one cause a rerun cannot clear. Pinned
# here over the whole truth table; the resolution it consumes needs a provisioned host and lives
# in integration/selinux.sh.
section "relabel: declared-vs-installed entrypoint reconciliation (unit)"

readonly INSTALLED='/opt/ai-tools/.nvm/versions/node/v22.23.2/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe'

# verdict_is <expected> <installed> <covered> <matched> <why>
verdict_is() {
    local expected="$1" got
    got="$(ai_tools_entrypoint_reconcile_verdict "$2" "$3" "$4")"
    if [[ "${got}" == "${expected}" ]]; then pass "${5} -> ${expected}"
    else fail "${5}: expected ${expected}, got '${got}'"; fi
}

if declare -F ai_tools_entrypoint_reconcile_verdict >/dev/null 2>&1; then
    verdict_is ok    "${INSTALLED}" yes yes "an installed entrypoint the declared rule covers"
    verdict_is stale "${INSTALLED}" no  no  "an installed entrypoint the rule matches nothing for"
    verdict_is stale "${INSTALLED}" no  yes "the rule matched some OTHER file, not the installed one"
    verdict_is none  ""            no  no  "no entrypoint installed and no match (not provisioned)"
    verdict_is ok    ""            no  yes "no launcher resolves but the rule matched a copy"
    # Unknown flags must not read as "covered": an input this function cannot interpret errs
    # toward reporting a divergence, which fails a relabel loudly rather than blessing one.
    verdict_is stale "${INSTALLED}" ""      "" "an empty covered flag"
    verdict_is stale "${INSTALLED}" YES     no "a flag that is not the exact literal yes"
    verdict_is none  ""             yes     "" "covered claimed with nothing installed"
else
    skip "entrypoint reconciliation" "ai_tools_entrypoint_reconcile_verdict not defined by ${LIB}"
fi

# ── Reporting an agent-influenced path ────────────────────────────────────────────────────────
# The resolved entrypoint is reached through an npm symlink the SANDBOX account owns, and it is
# printed into a status line that a root helper splits on whitespace and renders to an operator's
# terminal. So the name is carried only while it is drawn from the same character set a declared
# pattern is -- an allowlist, matching ai_tools_entrypoint_fcontext_valid's posture.
section "relabel: reportability of an agent-influenced entrypoint path (unit)"

# reportable/unreportable <path> [why]
reportable() {
    if _ai_tools_entrypoint_path_reportable "$1"; then pass "reports ${1}"
    else fail "refused a legitimate entrypoint path: $1"; fi
}
unreportable() {
    if _ai_tools_entrypoint_path_reportable "$1"; then fail "REPORTED ${2}: ${1:-<empty>}"
    else pass "refuses ${2}"; fi
}

if declare -F _ai_tools_entrypoint_path_reportable >/dev/null 2>&1; then
    reportable "${INSTALLED}"
    reportable '/opt/ai-tools/.nvm/versions/node/v22.23.2/bin/some-agent'
    unreportable ''                              "an empty path"
    unreportable 'relative/claude.exe'           "a relative path"
    unreportable '/opt/ai-tools/../etc/shadow'   "a parent-directory traversal"
    unreportable '/opt/ai-tools/bin/a b'         "whitespace, which would split the status line"
    unreportable "/opt/ai-tools/bin/$(printf 'a\tb')" "a tab, which would split the status line"
    unreportable "/opt/ai-tools/bin/$(printf 'a\033[2Kb')" "an ANSI escape aimed at the terminal"
    # shellcheck disable=SC2016  # the literal $(...) is the input under test, not an expansion
    unreportable '/opt/ai-tools/bin/$(id)'       "shell-substitution characters"
else
    skip "entrypoint path reportability" "_ai_tools_entrypoint_path_reportable not defined by ${LIB}"
fi

# ── The project-label verification predicate (relabel.lib.sh) ─────────────────────────────────
# ai_tools_label_project trusts the ACHIEVED label, not restorecon's exit status: after the
# relabel it calls ai_tools_project_labelled to confirm the tree actually carries
# ai_tools_project_t, so a silent mislabel -- an fcontext rule made unreachable by a path alias
# (file_contexts.subs_dist `/var/opt /opt`), or a module not loaded -- is a hard failure instead
# of a false success. This pins the predicate that gate rests on. A genuinely-labelled path needs
# an enforcing SELinux host, so the positive case (label applies AND verifies) lives in
# integration/selinux.sh; here the negative is hermetic -- a plain /tmp dir carries no project
# type on any host, SELinux or not, so the predicate must report false for it.
section "relabel: project-label verification predicate (unit)"
if declare -F ai_tools_project_labelled >/dev/null 2>&1; then
    mktestdir
    mkdir -p "${TESTDIR}/plain"
    if ai_tools_project_labelled "${TESTDIR}/plain"; then
        fail "ai_tools_project_labelled reported a plain dir as ai_tools_project_t"
    else
        pass "ai_tools_project_labelled rejects a path that is not ai_tools_project_t"
    fi
    if ai_tools_project_labelled "${TESTDIR}/does-not-exist"; then
        fail "ai_tools_project_labelled reported a missing path as labelled"
    else
        pass "ai_tools_project_labelled returns false for a missing path"
    fi
else
    skip "project-label verification" "ai_tools_project_labelled not defined by ${LIB}"
fi

# ── Reporting WHY a file-context rule was refused ─────────────────────────────────────────────
# semanage's stderr is the only account of why a rule did not land, and "could not register its
# entrypoint file-context rule" names no cause on its own -- an operator reading it has nothing to
# act on, and the condition (a policy store another transaction holds, a type the loaded policy
# does not define) needs different remedies. So the reason is collected for the caller to log.
# The stream split is the load-bearing part: the caller parses this library's STDOUT as verdict
# lines, so semanage's own stdout must never reach it while its stderr must survive. semanage is
# stubbed as a shell function -- no policy store is touched.
section "relabel: a refused file-context rule reports semanage's reason (unit)"
if declare -F _ai_tools_fcontext >/dev/null 2>&1 \
        && declare -F _ai_tools_label_agent_entrypoint >/dev/null 2>&1; then
    semanage() {
        case "${2:-}" in
            -a) printf 'libsemanage: Could not get direct lock\nOSError: Resource unavailable\n' >&2; return 1 ;;
            -m) printf 'ValueError: File context for /opt/ai-tools/x is not defined\n' >&2; return 1 ;;
            *)  return 0 ;;
        esac
    }
    _ai_tools_fcontext add f ai_tools_exec_t '/opt/ai-tools/x' >/dev/null && fcontext_rc=0 || fcontext_rc=$?
    if [[ "${fcontext_rc}" -ne 0 ]]; then pass "a refused rule returns non-zero"
    else fail "a refused rule returned 0"; fi
    # The ADD's message names the cause; the modify's reports the consequence ("not defined"), so
    # reporting the modify's would send an operator after the wrong condition.
    if [[ "${AI_TOOLS_FCONTEXT_ERROR:-}" == *"Could not get direct lock"* ]]; then
        pass "the reason carries the add's stderr"
    else fail "the reason does not carry the add's stderr: ${AI_TOOLS_FCONTEXT_ERROR:-<none>}"; fi
    # The reason lands on a status line whose reader splits the report per line, so a multi-line
    # semanage message must not read as extra verdicts.
    if [[ "${AI_TOOLS_FCONTEXT_ERROR:-}" != *$'\n'* ]]; then
        pass "the reason is collapsed to a single line"
    else fail "the reason spans lines: ${AI_TOOLS_FCONTEXT_ERROR:-<none>}"; fi

    # The reason has to reach the caller through the REPORT, not through the variable:
    # ai-tools-relabel-agent runs the labelling inside a `$(...)`, and a variable set in that
    # subshell is gone by the time the renderer reads it. So the capture below is the production
    # call shape, and the assertion is that the status line itself carries the cause.
    ai_tools_agent_manifest_field() {
        if [[ "$2" == entrypoint_fcontext ]]; then
            printf '/opt/ai-tools/\\.nvm/versions/node/[^/]+/bin/some-agent'
        fi
        return 0
    }
    ai_tools_agent_entrypoint_path() { return 1; }
    AI_TOOLS_FCONTEXT_ERROR=""
    skip_line="$(_ai_tools_label_agent_entrypoint some-agent)" || true
    if [[ "${skip_line}" == skip* && "${skip_line}" == *"Could not get direct lock"* ]]; then
        pass "the reason survives the report's subshell on the status line"
    else fail "the status line does not carry the cause: ${skip_line:-<empty>}"; fi
    if [[ "$(printf '%s' "${skip_line}" | wc -l)" -eq 0 ]]; then
        pass "the refusal stays one status line"
    else fail "the refusal spans several report lines: ${skip_line}"; fi

    # semanage announces "already defined, modifying instead" on STDOUT, which the caller reads as
    # a verdict line -- so a rule that registers must leave that stream empty.
    semanage() { echo "File context already defined, modifying instead"; return 0; }
    fcontext_stdout="$(_ai_tools_fcontext add a ai_tools_home_t '/opt/ai-tools/\.claude(/.*)?')" \
        && fcontext_rc=0 || fcontext_rc=$?
    if [[ "${fcontext_rc}" -eq 0 ]]; then pass "a rule that registers returns 0"
    else fail "a successful add returned ${fcontext_rc}"; fi
    if [[ -z "${fcontext_stdout}" ]]; then
        pass "semanage's stdout never reaches the caller's verdict stream"
    else fail "semanage stdout leaked into the report: ${fcontext_stdout}"; fi
    unset -f semanage ai_tools_agent_manifest_field ai_tools_agent_entrypoint_path
else
    skip "file-context refusal reporting" "the fcontext helpers are not defined by ${LIB}"
fi

# ── Serializing writes to the policy store ────────────────────────────────────────────────────
# semanage reports an error to whichever process finds the policy store held, rather than waiting,
# so two root helpers that overlap -- an agent package's %post relabel and the
# ai-tools-relabel.path watcher triggered by the same upgrade -- both fail on a store neither of
# them broke. ai_tools_relabel_lock makes the second wait. Each case runs in its own process
# (the lock is an open file descriptor, so it cannot be exercised in one shell), against a lock
# file in this test's own directory via the root-only AI_TOOLS_RELABEL_LOCK hook.
section "relabel: relabels serialize on the policy store (unit)"
if ! declare -F ai_tools_relabel_lock >/dev/null 2>&1; then
    skip "relabel serialization" "ai_tools_relabel_lock not defined by ${LIB}"
elif ! command -v flock >/dev/null 2>&1; then
    skip "relabel serialization" "flock is not installed"
else
    mktestdir
    LOCK="${TESTDIR}/relabel.lock"

    # take_lock <wait-seconds> <hold-seconds> -- acquire in a child process and print the note.
    take_lock() {
        # shellcheck disable=SC2016  # the child shell expands these, not this one
        env AI_TOOLS_RELABEL_LOCK="${LOCK}" AI_TOOLS_RELABEL_LOCK_WAIT="$1" \
            bash -c 'source "$1"; ai_tools_relabel_lock; printf "%s" "${AI_TOOLS_RELABEL_LOCK_NOTE}"; sleep "$2"' \
            _ "${LIB}" "$2"
    }

    take_lock 5 3 >/dev/null &
    holder=$!
    sleep 0.5   # let the holder acquire before the contender starts waiting

    # A wait shorter than the hold proves the lock is genuinely held across processes.
    contended="$(take_lock 1 0)"
    if [[ "${contended}" == *"held the policy store"* ]]; then
        pass "a concurrent relabel reports the store as held"
    else fail "expected a held-store note while another process held the lock, got '${contended:-<empty>}'"; fi

    # And it proceeds anyway: labelling is idempotent and every refusal is reported, so a lock
    # this helper cannot take costs a repeat run rather than a wrong label.
    if take_lock 1 0 >/dev/null; then pass "a contended relabel proceeds rather than aborting"
    else fail "ai_tools_relabel_lock returned non-zero under contention"; fi

    wait "${holder}" 2>/dev/null || true
    uncontended="$(take_lock 5 0)"
    if [[ -z "${uncontended}" ]]; then pass "the lock is released when the holder exits"
    else fail "the lock was still held after its holder exited: ${uncontended}"; fi

    # A lock file that cannot be created is reported, not fatal: a host where /run/lock is
    # unwritable still relabels.
    # shellcheck disable=SC2016  # the child shell expands these, not this one
    unwritable="$(env AI_TOOLS_RELABEL_LOCK="${TESTDIR}/no-such-dir/relabel.lock" \
        bash -c 'source "$1"; ai_tools_relabel_lock || echo RETURNED-NONZERO; printf "%s" "${AI_TOOLS_RELABEL_LOCK_NOTE}"' \
        _ "${LIB}" 2>&1)"
    if [[ "${unwritable}" == "cannot write ${TESTDIR}/no-such-dir/relabel.lock" ]]; then
        pass "an uncreatable lock file is reported and the relabel proceeds"
    else fail "expected a single cannot-write note, got '${unwritable}'"; fi
fi

finish

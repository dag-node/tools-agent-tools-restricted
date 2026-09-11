#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/relabel.sh
# Unit test for the file-context predicates (relabel.lib.sh): the pure
# ai_tools_entrypoint_fcontext_valid that gates every pattern an agent manifest declares before
# it becomes a `semanage fcontext` rule mapping files to ai_tools_exec_t -- the exec entrypoint of
# the confined domain -- and ai_tools_operator_conf_valid, which gates the path that becomes an
# ai_tools_conf_t rule for one operator's config subtree.
#
# The property under test is containment: a declared pattern may only ever match inside the
# sandbox's own Node toolchain, and a config rule may only ever name one account's
# ~/.config/ai-tools. Both inputs are root-owned or read from a passwd entry, so this is defense in
# depth rather than the only guard, but the failure it prevents is severe and silent -- a pattern
# with an alternation, a traversal, or a foreign prefix would hand ai_tools_exec_t to a file
# outside the toolchain, making it an entrypoint into the agent's domain. The entrypoint type is
# never manifest-supplied and the config type never caller-supplied, which this file also pins.
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
# the inode the launcher symlink resolves to -- so the two can disagree, and this file covered neither side of it
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
# integration/selinux.sh; here the negative is hermetic -- a plain /tmp dir does not carry a project
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

# ── The build-output rule beside the project rule ─────────────────────────────────────────────
# A claim labels a project's build-output directories ai_tools_project_build_t, the type the
# buildexec policy group may grant execute on, from the names each installed integration manifest
# declares (build_output_dirs). Three properties carry the weight. The NAMES come from the
# manifests and are validated to one plain component each, since they are spliced into a
# file-context regex and a `/`, `|` or `(` would let a manifest widen the rule past the
# directories it names. The label writes the project rule FIRST and the build rule second, in
# that order, because among rules sharing a stem the later one is the match. And the unlabel
# drops the build rule by LISTING the local rules under the project rule, so a rule written under
# an earlier name set is removed with the claim rather than left on a subtree the confined domain
# manages. semanage, restorecon and the availability probe are stubbed; no policy store is touched.
section "relabel: the build-output rule (unit)"
if declare -F ai_tools_project_build_pattern >/dev/null 2>&1 \
        && declare -F ai_tools_label_project >/dev/null 2>&1; then
    # The manifest reader is stubbed at the seam relabel.lib.sh consumes it through.
    ai_tools_installed_integrations_declaring() {
        [[ "$1" == build_output_dirs ]] || return 0
        printf 'dotnet\tbin obj artifacts\n'
        printf 'evil\tbin/../etc x|y (z) .hidden\n'   # every name but .hidden must be refused
    }
    # C-locale order: `.` sorts before a letter, and the order is part of the pattern a claim writes.
    got="$(ai_tools_project_build_pattern /home/op/proj)"
    if [[ "${got}" == '/home/op/proj(/.*)?/(\.hidden|artifacts|bin|obj)(/.*)?' ]]; then
        pass "the build pattern unions the declared names in C order, refuses a path or a metacharacter, and escapes a dot"
    else
        fail "build pattern: '${got}'"
    fi
    ai_tools_installed_integrations_declaring() { :; }
    if ai_tools_project_build_pattern /home/op/proj >/dev/null; then
        fail "a host with no declared build-output names still produced a build pattern"
    else
        pass "with no declared names the build pattern is empty and the caller writes no rule"
    fi

    # Order and content of the semanage calls a label makes.
    ai_tools_installed_integrations_declaring() { printf 'dotnet\tbin obj\n'; }
    ai_tools_relabel_available() { return 0; }
    ai_tools_project_labelled()  { return 0; }
    restorecon() { :; }
    CALLS=""
    semanage() { CALLS+="$*"$'\n'; return 0; }
    ai_tools_label_project /home/op/proj
    if [[ "${CALLS}" == "fcontext -a -t ai_tools_project_t /home/op/proj(/.*)?"$'\n'"fcontext -a -t ai_tools_project_build_t -- /home/op/proj(/.*)?/(bin|obj)(/.*)?"$'\n' ]]; then
        pass "a label registers the project rule, then the build rule"
    else
        fail "label calls: ${CALLS//$'\n'/ | }"
    fi
    # A build rule the store refuses (a policy older than the library) fails the label, so the
    # claim reports it rather than leaving output on a type the group cannot run.
    semanage() { [[ "$*" == *ai_tools_project_build_t* ]] && return 1; return 0; }
    if ai_tools_label_project /home/op/proj; then
        fail "a refused build rule did not fail the label"
    else
        pass "a refused build rule fails the label (reported, not silently skipped)"
    fi
    # Sandbox clones take neither rule: the static rules cover them.
    CALLS=""; semanage() { CALLS+="$*"$'\n'; return 0; }
    ai_tools_label_project /var/opt/ai-tools/sandbox-projects/clone
    if [[ -z "${CALLS}" ]]; then
        pass "a sandbox clone registers no per-project rule"
    else
        fail "a sandbox clone registered rules: ${CALLS//$'\n'/ | }"
    fi

    # The unlabel finds the build rule by listing, whatever name set wrote it, and parses the
    # row format semanage prints (pattern, file-type words, context).
    semanage() {
        case "$*" in
            "fcontext -l -C -n")
                printf '%-50s %-18s %s\n' '/home/op/proj(/.*)?' 'all files' 'system_u:object_r:ai_tools_project_t:s0'
                printf '%-50s %-18s %s\n' '/home/op/proj(/.*)?/(bin|target)(/.*)?' 'all files' 'system_u:object_r:ai_tools_project_build_t:s0'
                printf '%-50s %-18s %s\n' '/home/op/proj-two(/.*)?/(bin)(/.*)?' 'all files' 'system_u:object_r:ai_tools_project_build_t:s0'
                printf '%-50s %-18s %s\n' '/home/op/other space(/.*)?/(bin)(/.*)?' 'all files' 'system_u:object_r:ai_tools_project_build_t:s0'
                return 0 ;;
            *) CALLS+="$*"$'\n'; return 0 ;;
        esac
    }
    CALLS=""
    ai_tools_unlabel_project /home/op/proj
    if [[ "${CALLS}" == "fcontext -d -- /home/op/proj(/.*)?/(bin|target)(/.*)?"$'\n'"fcontext -d /home/op/proj(/.*)?"$'\n' ]]; then
        pass "an unlabel drops the build rule found by listing (an older name set included), then the project rule, and leaves a sibling project's rule alone"
    else
        fail "unlabel calls: ${CALLS//$'\n'/ | }"
    fi
    got="$(_ai_tools_local_rules_under '/home/op/other space')"
    if [[ "${got}" == '/home/op/other space(/.*)?/(bin)(/.*)?' ]]; then
        pass "a pattern carrying a space survives the row parse"
    else
        fail "row parse of a pattern with a space: '${got}'"
    fi
    unset -f ai_tools_installed_integrations_declaring ai_tools_relabel_available \
             ai_tools_project_labelled restorecon semanage
    unset CALLS
else
    skip "build-output rule" "ai_tools_project_build_pattern not defined by ${LIB}"
fi

# ── Reporting WHY a file-context rule was refused ─────────────────────────────────────────────
# semanage's stderr is the only account of why a rule did not land, and "could not register its
# entrypoint file-context rule" does not name a cause on its own -- an operator reading it has no next step to
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
    # subshell is gone by the time the renderer reads it. So the capture is the production
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

# ── The per-agent outcome the report closes with ──────────────────────────────────────────────
# ai-tools-relabel-agent records this per agent so `ai-tools --status` can report the labelling
# half of a reconciliation; the operator cannot inspect the labels themselves, the entrypoint
# living in a toolchain they cannot traverse. Two properties matter beyond the mapping. A path that
# is not installed YET (rc 3 -- the ordinary pre-bootstrap state) must not read as labels applied,
# or a host that has never provisioned reports green for work that did not happen; and it must not
# fail the relabel either, which would make every fresh install exit non-zero. Both halves are
# stubbed, so this drives the decision without a policy store.
section "relabel: the per-agent outcome closing the report (unit)"
if declare -F ai_tools_label_agent_paths >/dev/null 2>&1; then
    _ai_tools_entrypoint_policy_active() { return 0; }
    ai_tools_enabled_agents() { printf 'some-agent\t\t\n'; }

    # outcome_is <expected-outcome> <expected-run-status> <entrypoint-rc> <config-rc> <why>
    outcome_is() {
        local expected="$1" expected_status="$2" entry_rc="$3" config_rc="$4" why="$5" line got status=0
        eval "_ai_tools_label_agent_entrypoint() { return ${entry_rc}; }"
        eval "_ai_tools_label_agent_config_dir()  { return ${config_rc}; }"
        line="$(ai_tools_label_agent_paths)" || status=$?
        got="$(printf '%s\n' "${line}" | sed -n 's/^agent some-agent //p')"
        if [[ "${got}" == "${expected}" && "${status}" -eq "${expected_status}" ]]; then
            pass "${why} -> ${expected} (run status ${expected_status})"
        else
            fail "${why}: expected ${expected}/${expected_status}, got '${got:-<none>}'/${status}"
        fi
    }

    outcome_is ok     0 0 0 "both halves applied their labels"
    outcome_is failed 1 1 0 "the entrypoint half failed"
    outcome_is failed 1 0 1 "the config-directory half failed"
    outcome_is failed 1 1 1 "both halves failed"
    outcome_is none   0 3 3 "neither path is installed yet (not provisioned)"
    outcome_is ok     0 3 0 "the entrypoint is not installed but the config directory took its type"
    outcome_is ok     0 0 3 "the config directory is absent but the entrypoint took its type"
    outcome_is failed 1 1 3 "a real failure outranks a path that is not installed"

    unset -f _ai_tools_entrypoint_policy_active ai_tools_enabled_agents \
             _ai_tools_label_agent_entrypoint _ai_tools_label_agent_config_dir
else
    skip "per-agent labelling outcome" "ai_tools_label_agent_paths not defined by ${LIB}"
fi

# ── The read-only live-label report ──────────────────────────────────────────────────────────
# `ai-tools-admin status` reports the type each agent path carries RIGHT NOW, which is a different
# claim from the one the relabel records: that says what the last run achieved, an event that may be
# hours old, while this says what is true at the moment it is asked. Two properties carry the
# weight. It must be READ-ONLY -- a status command that relabelled the host it is reporting on would
# change the state it is describing, and would need a policy-store lock to do it -- so both writers
# are stubbed to fail the test loudly if they are ever reached. And its FIELD ORDER is a contract:
# the consumer reads each line with a plain `read`, so a path arriving one field out would be
# rendered as a type and a type as a path, in a report whose whole job is to be believed.
section "relabel: the read-only live-label report (unit)"
if ! declare -F ai_tools_agent_label_report >/dev/null 2>&1; then
    skip "live-label report" "ai_tools_agent_label_report not defined by ${LIB}"
else
    mktestdir
    # CP_HOME is a readonly constant, so the config directory cannot be moved into the testdir.
    # `.some-agent` is a name no package ships, so `${CP_HOME}/.some-agent` is absent on every host
    # and that half reports deterministically as not installed -- which is a case worth asserting
    # anyway, and leaves the entrypoint half to carry the type comparisons.
    _ai_tools_entrypoint_policy_active() { return 0; }
    ai_tools_enabled_agents() { printf 'some-agent\t\t\n'; }
    ai_tools_agent_manifest_field() { [[ "$2" == config_dir ]] && printf '.some-agent'; return 0; }
    ai_tools_agent_config_dir_valid() { return 0; }
    # A write is what this report must never make, and both writers run in a `$(...)` subshell
    # where a failed assertion would not survive -- so each leaves a marker on disk instead, and
    # the whole section is judged on the markers still being absent at the end.
    WROTE="${TESTDIR}/a-writer-ran"
    restorecon() { printf 'restorecon %s\n' "$*" >> "${WROTE}"; }
    semanage()   { printf 'semanage %s\n'   "$*" >> "${WROTE}"; }

    # report_has <expected-line> <why> ; entrypoint path and live types come from the stubs.
    report_has() {
        local expected="$1" why="$2" got
        got="$(ai_tools_agent_label_report || true)"
        if grep -qxF -- "${expected}" <<<"${got}"; then
            pass "${why}"
        else
            fail "${why}: no line '${expected}' in '${got//$'\n'/ | }'"
        fi
    }

    ai_tools_agent_entrypoint_path() { printf '/opt/toolchain/claude\n'; }
    _ai_tools_live_type() { printf 'ai_tools_exec_t'; }
    report_has 'ok some-agent entrypoint /opt/toolchain/claude ai_tools_exec_t' \
        "a path carrying its pinned type reports ok, in the order agent, what, path, type"
    report_has 'none some-agent config-directory' \
        "a config directory that is not installed reports 'none' with no path to render"

    _ai_tools_live_type() {
        case "$1" in /opt/toolchain/claude) printf 'usr_t' ;; *) printf 'ai_tools_home_t' ;; esac
    }
    rc=0; out="$(ai_tools_agent_label_report)" || rc=$?
    if [[ "${rc}" -eq 1 ]] \
            && grep -qx 'bad some-agent entrypoint /opt/toolchain/claude usr_t ai_tools_exec_t' <<<"${out}"; then
        pass "an entrypoint carrying the wrong type reports bad, with the type it has and the one it needs"
    else
        fail "a mislabelled entrypoint was not reported (rc=${rc}): ${out//$'\n'/ | }"
    fi

    # A label the read does not resolve prints as 'unknown', keeping the field count: an empty
    # field would shift every later field left in a line the consumer splits on whitespace.
    # Captured before matching, never piped: the report exits non-zero on a mislabelled path and
    # `pipefail` would fail the whole pipeline whatever grep found.
    _ai_tools_live_type() { return 0; }
    out="$(ai_tools_agent_label_report || true)"
    if grep -qx 'bad some-agent entrypoint /opt/toolchain/claude unknown ai_tools_exec_t' <<<"${out}"; then
        pass "an unreadable label reports 'unknown' rather than an empty field"
    else
        fail "an unreadable label did not keep the field count: ${out//$'\n'/ | }"
    fi

    # Not provisioned: ai_tools_agent_entrypoint_path returns non-zero because the launcher symlink
    # does not resolve. It is the ordinary pre-bootstrap state and must not read as a fault, or
    # every host reports a problem before it is set up.
    ai_tools_agent_entrypoint_path() { return 1; }
    _ai_tools_live_type() { printf 'ai_tools_home_t'; }
    rc=0; out="$(ai_tools_agent_label_report)" || rc=$?
    if [[ "${rc}" -eq 0 ]] && grep -qx 'none some-agent entrypoint' <<<"${out}"; then
        pass "an entrypoint that is not installed reports 'none' and is not a fault"
    else
        fail "an uninstalled entrypoint was misreported (rc=${rc}): ${out//$'\n'/ | }"
    fi

    _ai_tools_entrypoint_policy_active() { return 1; }
    rc=0; out="$(ai_tools_agent_label_report)" || rc=$?
    if [[ "${rc}" -eq 2 && -z "${out}" ]]; then
        pass "an inactive SELinux layer returns 2 with no report, not a wall of failures"
    else
        fail "an inactive SELinux layer was misreported (rc=${rc}): ${out//$'\n'/ | }"
    fi

    if [[ ! -e "${WROTE}" ]]; then
        pass "the whole report ran read-only -- no restorecon, no semanage, no policy-store lock"
    else
        fail "the report wrote to the host: $(tr '\n' '|' < "${WROTE}")"
    fi

    unset -f _ai_tools_entrypoint_policy_active ai_tools_enabled_agents \
             ai_tools_agent_manifest_field ai_tools_agent_config_dir_valid \
             ai_tools_agent_entrypoint_path _ai_tools_live_type restorecon semanage
fi

# ── The deployed helper's allowlist gate ─────────────────────────────────────────────────────
# ai-tools-relabel grants a project the type the confined domain may work in, so the gate deciding
# WHICH paths get it is the one thing here worth driving through the real helper. Only the REFUSAL
# is: the accepting branch registers a semanage fcontext rule, and this suite does not mutate the
# host's policy store to test a helper (the same line integration/selinux.sh draws). The accepting
# branch on a MULTI-OPERATOR host -- the case that matters, since the entry authorizing a label may
# live in any operator's registry -- is covered live in tests/manual/verify-live-flows.sh, which
# has a second enrolled operator to act for.
section "relabel: the deployed helper refuses a path no allowlist covers (unit)"
RELABEL_BIN=/usr/local/libexec/ai-tools/ai-tools-relabel
if [[ ! -x "${RELABEL_BIN}" ]]; then
    skip "relabel allowlist gate" "${RELABEL_BIN} not installed"
elif [[ "${EUID}" -ne 0 ]]; then
    skip "relabel allowlist gate" "needs root (the helper refuses a non-root caller first)"
elif ! command -v getenforce >/dev/null 2>&1 || [[ "$(getenforce 2>/dev/null)" == Disabled ]]; then
    # The helper reports "SELinux inactive" and exits 0 BEFORE the gate, so there is no state to
    # assert here on a DAC-only host.
    skip "relabel allowlist gate" "SELinux inactive -- the helper exits before the gate"
else
    mktestdir
    unlisted="${TESTDIR}/unlisted-project"; mkdir -p "${unlisted}"
    : > "${TESTDIR}/empty-allowlist"
    out="$(AI_TOOLS_ALLOWLIST="${TESTDIR}/empty-allowlist" "${RELABEL_BIN}" "${unlisted}" 2>&1)" && rc=0 || rc=$?
    if [[ "${rc}" -ne 0 ]] && grep -qi 'not in the allowed-projects allowlist' <<<"${out}"; then
        pass "a path no allowlist covers is refused, before any policy write"
    else
        fail "the helper did not refuse an unlisted path (rc=${rc}): ${out}"
    fi
fi

# ── The operator config subtree predicate ────────────────────────────────────────────────────
# ai_tools_operator_conf_valid gates what becomes a `semanage fcontext` rule for ai_tools_conf_t,
# the type the root helpers read an operator's allowlist through. Its input is a home path from a
# passwd entry, so the property under test is the containment
# ai_tools_entrypoint_fcontext_valid holds for a toolchain path: the rule may name one account's
# ~/.config/ai-tools and no other path. A regex metacharacter reaching the pattern would widen it
# to homes nobody enrolled, and refusing costs that one operator's label, which the caller
# reports -- so every ambiguous shape must be refused.
# Pure: no filesystem, no privilege, no SELinux host.
section "relabel: the operator config subtree predicate (unit)"

if ! declare -F ai_tools_operator_conf_valid >/dev/null 2>&1; then
    skip "operator conf predicate" "${LIB} does not define ai_tools_operator_conf_valid"
else
    conf_accepts() {
        if ai_tools_operator_conf_valid "$1"; then pass "accepts ${1:-<empty>}"
        else fail "rejected a valid operator config dir: $1"; fi
    }
    conf_rejects() {
        if ai_tools_operator_conf_valid "$1"; then fail "ACCEPTED ${2}: ${1:-<empty>}"
        else pass "rejects ${2}"; fi
    }

    conf_accepts '/home/op/.config/ai-tools'
    conf_accepts '/home/some.user/.config/ai-tools'      # a dotted account name is ordinary
    conf_accepts '/var/lib/svc-account/.config/ai-tools' # a service account's home need not be /home

    conf_rejects ''                                  "an empty path"
    conf_rejects 'home/op/.config/ai-tools'          "a relative path"
    conf_rejects '/home/op/.config'                  "the parent, which would cover every ~/.config file"
    conf_rejects '/home/op'                          "a whole home"
    conf_rejects '/home/op/.config/ai-tools/sub'     "a path below the config dir"
    conf_rejects '/home/../etc/.config/ai-tools'     "a parent-directory traversal"
    conf_rejects '/.config/ai-tools'                 "a home of / -- the filesystem root"
    conf_rejects '/home/a|b/.config/ai-tools'        "an alternation in the home"
    conf_rejects '/home/*/.config/ai-tools'          "a wildcard matching every home"
    conf_rejects '/home/[ab]/.config/ai-tools'       "a bracket expression in the home"
    conf_rejects '/home/a b/.config/ai-tools'        "whitespace in the home"
    # shellcheck disable=SC2016  # the literal $(...) is the input under test, not an expansion
    conf_rejects '/home/$(id)/.config/ai-tools'      "a shell-substitution character"

    # The TYPE is the library's, never a caller's -- the same rule the entrypoint type follows.
    if [[ "${AI_TOOLS_OPERATOR_CONF_TYPE:-}" == ai_tools_conf_t ]]; then
        pass "the operator config type is pinned in the library (ai_tools_conf_t)"
    else
        fail "AI_TOOLS_OPERATOR_CONF_TYPE is '${AI_TOOLS_OPERATOR_CONF_TYPE:-unset}', expected ai_tools_conf_t"
    fi

    # A dot in the pattern must be escaped, or the rule matches homes the operator does not own.
    pattern="$(_ai_tools_operator_conf_pattern '/home/some.user/.config/ai-tools')"
    if [[ "${pattern}" == '/home/some\.user/\.config/ai-tools(/.*)?' ]]; then
        pass "the pattern escapes every dot and covers the subtree"
    else
        fail "pattern is '${pattern}', expected every dot escaped and a (/.*)? tail"
    fi
fi

finish

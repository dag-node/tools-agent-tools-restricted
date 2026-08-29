#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/cli.sh
# Integration: the ai-tools management CLI. The CLI edits the allowlist as the PROJECTS user (and
# registers git safe.directory through the ai-tools-safedir root helper); it must refuse to run as
# the sandbox account for every verb (the agent must not manage its own allowlist), and as root for
# every verb that WRITES OPERATOR-OWNED STATE (it would write the registries with the wrong owner)
# while accepting the ones that write none -- the four reports, which root reaches because
# --audit's trail is 700 root:root, and --stop, whose helper requires root. Asserts that
# split in both directions, that the projects user passes the guard, the operator preflight and the
# per-verb "not a claimed project" refusals, and -- over a
# FIXTURE allowlist + gitconfig (the AI_TOOLS_ALLOWLIST / AI_TOOLS_GITCONFIG root-only test hooks,
# so it never reads the operator's real registry) -- the full --list reconciliation render: every
# entry class, every Suggested-cleanup class, and that the loop reaches its Maintenance footer past
# an early stale/protected entry. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly CLI="/usr/local/bin/ai-tools"
section "CLI principal guard (root reads only; the sandbox account is refused outright)"

if [[ ! -x "${CLI}" ]]; then
    skip "CLI principal guard" "not installed at ${CLI}"; finish; exit
fi

# (1a) Every verb that WRITES OPERATOR-OWNED STATE must refuse root before the first write. One
# per family, since the guard keys on the verb: a claim, a clone, a per-project helper verb, and
# the host-wide relabel.
for verb in --project-claim --project-unclaim --sandbox-create --lockdown --reclaim --relabel; do
    out="$("${CLI}" "${verb}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'do not run as root' <<<"${out}"; then
        pass "CLI refuses root on ${verb} (would write registries with the wrong owner)"
    else
        fail "CLI did not refuse root on ${verb} (rc=${rc}): ${out}"
    fi
done

# (1b) The verbs that write no operator state are the carve-out: --audit needs root by
# construction (its trail is 700 root:root), and refusing it left the verb unreachable from BOTH
# sides on a host whose only operator holds no general sudo grant. Asserted on the refusal text
# rather than the exit status: --audit and --status both exit non-zero to REPORT something, which
# is not a refusal.
for verb in --audit --status --list --providers; do
    out="$("${CLI}" "${verb}" 2>&1)" || true
    if ! grep -qi 'do not run as root' <<<"${out}"; then
        pass "CLI accepts root on the read-only report ${verb}"
    else
        fail "CLI wrongly refused root on the read-only report ${verb}: ${out}"
    fi
done

# --stop is in that set too and is the one member that ACTS, so it is asserted through a REFUSAL
# it reaches only past the principal guard: an unknown option, which cmd_stop's argument loop
# rejects with the documented usage code BEFORE the sudo that would reach the root helper. Driving
# the bare command here would terminate every session on the host -- including the one running
# this suite -- so the assertion is that root got as far as the option loop, not that a stop ran.
out="$("${CLI}" --stop --bogus 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -eq 2 ]] && grep -qi 'unknown --stop option' <<<"${out}"; then
    pass "CLI accepts root on --stop (reached the option loop, no session signalled)"
else
    fail "CLI did not admit root to --stop's option loop (rc=${rc}): ${out}"
fi

# (1c) --for stays refused for root in EITHER argument order: root is not in OPERATORS, so an
# entry written for it names an owner no ownership helper can resolve. The trailing form is the
# one a $1-keyed guard would miss, which is why the check runs after --for is separated out.
for form in "--for ${PROJECTS_USER} --list" "--list --for ${PROJECTS_USER}"; do
    # shellcheck disable=SC2086  # deliberate word-splitting: each form is a command line
    out="$("${CLI}" ${form} 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'do not run as root' <<<"${out}"; then
        pass "CLI refuses root on '${form}' (--for needs an enrolled invoker)"
    else
        fail "CLI did not refuse root on '${form}' (rc=${rc}): ${out}"
    fi
done

# (2) Running as the sandbox account must be refused -- the agent must not manage its own
# allowlist. The CLI is 755 root:root, so the agent can exec it; the guard, not the perms,
# is what stops it.
if ! command -v runuser >/dev/null 2>&1; then
    skip "CLI sandbox-account guard" "runuser unavailable"
else
    out="$(runuser -u "${SANDBOX_USER}" -- "${CLI}" --list 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'refusing to run as the sandbox account' <<<"${out}"; then
        pass "CLI refuses to run as the sandbox account ${SANDBOX_USER}"
    else
        fail "CLI did not refuse the sandbox account (rc=${rc}): ${out}"
    fi

    # (3) The legitimate principal (the projects user) clears the guard -- the refusal is
    # scoped to root and the agent, not a blanket block. HOME is set explicitly so the CLI
    # finds the allowlist under the projects user's config regardless of runuser's env.
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" "${CLI}" --list 2>&1)" || true
    if ! grep -qiE 'do not run as root|refusing to run as the sandbox account' <<<"${out}"; then
        pass "the projects user (${PROJECTS_USER}) passes the principal guard"
    else
        fail "the projects user was wrongly blocked by the principal guard: ${out}"
    fi
fi

# (4) Operator preflight: a user NOT in OPERATORS is refused on an operator-acting command,
# BEFORE any registry write. Point the CLI at a temp operator.conf listing a bogus operator (not
# the projects user) and run --project-claim as the projects user -- require_operator must refuse.
if command -v runuser >/dev/null 2>&1; then
    section "CLI operator preflight (OPERATORS membership)"
    mktestdir
    chmod 755 "${TESTDIR}"
    tconf="${TESTDIR}/operator.conf"
    printf 'OPERATORS="nobody-operator"\n' > "${tconf}"; chmod 644 "${tconf}"
    proj="${TESTDIR}/proj"; mkdir -p "${proj}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${proj}"
    # An empty FIXTURE allowlist (AI_TOOLS_ALLOWLIST test hook) so the mutating-verb refusals
    # below classify against it, never the operator's real registry -- and a regression that
    # wrote past a refusal would touch this throwaway file, which the next assertion inspects.
    emptyal="${TESTDIR}/empty-allowlist"; : > "${emptyal}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${emptyal}"

    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${tconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
            "${CLI}" --project-claim "${proj}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not a configured ai-tools operator' <<<"${out}"; then
        pass "operator-acting command refused for a non-OPERATORS user, up front"
    else
        fail "non-operator was not cleanly refused (rc=${rc}): ${out}"
    fi
    if [[ -s "${emptyal}" ]] || grep -qi 'allowed-projects: added' <<<"${out}"; then
        fail "refused claim still wrote to the allowlist: ${out}"
    else
        pass "refused claim wrote no registry state (gate precedes registry writes)"
    fi

    # (5) The informational commands stay open to that same non-operator user.
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${tconf}" "${CLI}" --help 2>&1)" || true
    if grep -qi 'manage Claude Code sandbox projects' <<<"${out}"; then
        pass "--help stays open to a non-operator user"
    else
        fail "--help was blocked for a non-operator: ${out}"
    fi

    # (6) --project-unclaim classifies its target against allowed-projects: a directory that no
    # entry covers AND that carries no ai-tools ownership or group is REFUSED, before any
    # registry/filesystem change. The testdir path is not in the (real) allowlist and is freshly
    # created, so it classifies as unrelated-and-clean -- the one outcome with nothing to offer
    # (a tree carrying the fingerprint is instead pointed at --force).
    # Runs as an OPERATOR (conf lists the projects user) so classification runs past the operator
    # gate; under setsid so any prompt takes its non-interactive default rather than blocking.
    oconf="${TESTDIR}/op-self.conf"
    printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${oconf}"; chmod 644 "${oconf}"
    lone="${TESTDIR}/not-a-project"; mkdir -p "${lone}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lone}"
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
            setsid "${CLI}" --project-unclaim "${lone}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'nothing to unclaim here' <<<"${out}"; then
        pass "--project-unclaim refuses a directory that is neither a claimed project nor an ancestor of one"
    else
        fail "--project-unclaim did not refuse a non-project (rc=${rc}): ${out}"
    fi

    # (6b) A project root owned by a third party is REFUSED, not claimed. The claim's setgid and
    # ACL helpers act only on paths held by the resolved operator or the sandbox account, so such
    # a tree takes neither grant while the registries and the label still apply -- a claim that
    # reports ✓ having given the agent no way into the project. The refusal has to precede the
    # first registry write, so the fixture allowlist is inspected afterwards as well.
    if id nobody >/dev/null 2>&1; then
        : > "${emptyal}"
        foreignproj="${TESTDIR}/foreign-proj"; mkdir -p "${foreignproj}"
        chown nobody:nobody "${foreignproj}"
        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
                setsid "${CLI}" --project-claim "${foreignproj}" 2>&1)" && rc=0 || rc=$?
        if [[ ${rc} -ne 0 ]] && grep -qi 'owned by nobody' <<<"${out}"; then
            pass "--project-claim refuses a project root owned by a third party"
        else
            fail "--project-claim did not refuse a third-party-owned root (rc=${rc}): ${out}"
        fi
        if grep -q "chown -R ${PROJECTS_USER} ${foreignproj}" <<<"${out}"; then
            pass "the refusal names the chown that makes the tree claimable"
        else
            fail "the refusal did not name the chown remedy: ${out}"
        fi
        if [[ -s "${emptyal}" ]]; then
            fail "refused claim still wrote to the allowlist: $(cat "${emptyal}")"
        else
            pass "the owner refusal precedes every registry write"
        fi
    else
        skip "third-party-owned claim root" "user 'nobody' not present"
    fi

    # (7) --list renders the reconciliation view deterministically over a FIXTURE allowlist +
    # gitconfig (AI_TOOLS_ALLOWLIST / AI_TOOLS_GITCONFIG), so it never reads the operator's real
    # registry. Every entry class and every Suggested-cleanup class is asserted. The stale and
    # protected entries sit EARLY, so a passing Maintenance/orphan assertion also proves the
    # reconcile loop no longer aborts mid-list under set -e when a trailing conditional returns 1.
    lst="${TESTDIR}/list"; mkdir -p \
        "${lst}/partial" "${lst}/eol-comment" "${lst}/quoted dir" \
        "${lst}/glob-parent" "${lst}/excluded-live" "${lst}/orphan"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${lst}"
    lal="${TESTDIR}/list-allowlist"
    cat > "${lal}" <<EOF
# a header comment, ignored
${lst}/stale-gone
/etc
${lst}/partial
${lst}/eol-comment    # main repo
"${lst}/quoted dir"
${lst}/glob-parent/*
!${lst}/excluded-live
!${lst}/excluded-stale-gone
EOF
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lal}"
    lgc="${TESTDIR}/list-gitconfig"
    cat > "${lgc}" <<EOF
[safe]
	directory = ${lst}/partial
	directory = ${lst}/orphan
	directory = /opt/ai-tools
EOF
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lgc}"

    lout="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${lal}" \
            AI_TOOLS_GITCONFIG="${lgc}" "${CLI}" --list 2>&1)" || true

    list_has()   { if grep -qF "$1" <<<"${lout}"; then pass "$2"; else fail "$2 -- missing from --list output"; fi; }
    list_lacks() { if grep -qF "$1" <<<"${lout}"; then fail "$2 -- unexpectedly present in --list output"; else pass "$2"; fi; }

    list_has "Maintenance"            "--list reaches its footer past an early stale+protected entry (no set -e truncation)"
    list_has "stale entry"            "--list flags a stale allow entry"
    list_has "protected system path"  "--list flags a protected system path (/etc)"
    list_has "listed but not fully claimed" "--list flags a listed-but-unclaimed project"
    list_has "glob in allow line"     "--list flags a glob in an allow line as unusable"
    list_has "unusable"               "--list renders the 'unusable' kind for a glob allow entry"
    list_has "safe.dir:yes"           "--list shows safe.dir:yes for an entry present in git safe.directory"
    list_has "${lst}/eol-comment"     "--list renders an entry carrying an end-of-line comment"
    list_has "${lst}/quoted dir"      "--list renders a quoted entry"
    # Only the gone exclusion is reconciled as stale; the live one is left alone.
    n_stale_excl="$(grep -cF 'stale exclusion' <<<"${lout}" || true)"
    if [[ "${n_stale_excl}" -eq 1 ]] && grep -qF "!${lst}/excluded-stale-gone" <<<"${lout}"; then
        pass "--list reconciles only the stale ! exclusion, leaving the live one alone"
    else
        fail "stale-exclusion count is ${n_stale_excl}, expected exactly 1 (the gone path)"
    fi

    # Reverse reconciliation: exactly one orphaned safe.directory -- the listed entry (partial)
    # and the control-plane entry (/opt/ai-tools, a protected path) must NOT be flagged.
    list_has "git safe.directory with no allowlist entry" "--list flags an orphaned safe.directory"
    list_has "${lst}/orphan"          "--list names the orphaned safedir path"
    list_lacks "/opt/ai-tools"        "--list skips the control-plane safe.directory (protected, registered deliberately)"
    n_orphan="$(grep -cF 'git safe.directory with no allowlist entry' <<<"${lout}" || true)"
    if [[ "${n_orphan}" -eq 1 ]]; then
        pass "exactly one orphaned safedir (a listed entry and the control-plane entry are not flagged)"
    else
        fail "orphaned-safedir count is ${n_orphan}, expected 1"
    fi

    # (8) --reclaim and --lockdown refuse a path outside every claimed project, up front (before
    # the sudo prompt / any change) -- covered_by_project. ${lone} is not in the fixture allowlist.
    for verb in --reclaim --lockdown; do
        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
                setsid "${CLI}" "${verb}" "${lone}" 2>&1)" && rc=0 || rc=$?
        if [[ ${rc} -ne 0 ]] && grep -qi 'not a claimed project' <<<"${out}"; then
            pass "${verb} refuses a path outside every claimed project"
        else
            fail "${verb} did not refuse a non-project (rc=${rc}): ${out}"
        fi
    done

    # (9) --sandbox-remove refuses a target that is not a real clone, BEFORE any rm -rf:
    # the shared clone-area root itself (require_sandbox_clone: not a direct-child clone) and a
    # path outside SANDBOX_ROOT. The refusal precedes the removal, so nothing is deleted.
    sroot="/var/opt/ai-tools/sandbox-projects"
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" setsid "${CLI}" --sandbox-remove "${sroot}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not a sandbox clone' <<<"${out}" && [[ -d "${sroot}" ]]; then
        pass "--sandbox-remove refuses the shared clone-area root (not a direct-child clone)"
    elif [[ ! -d "${sroot}" ]]; then
        skip "--sandbox-remove root guard" "sandbox area ${sroot} not present"
    else
        fail "--sandbox-remove did not refuse the clone-area root (rc=${rc}): ${out}"
    fi
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" setsid "${CLI}" --sandbox-remove "${lone}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not a sandbox clone' <<<"${out}"; then
        pass "--sandbox-remove refuses a path outside SANDBOX_ROOT"
    else
        fail "--sandbox-remove did not refuse a non-sandbox path (rc=${rc}): ${out}"
    fi
fi

# --stop: the CLI half only -- the option grammar and the two forms not being combinable. Both
# refusals land in the argument loop, BEFORE the sudo that reaches the root helper, so neither
# reaches a password prompt or signals anything. The helper's own enumeration and kill are covered
# in tests/unit/stop.sh and tests/integration/stop.sh; what this asserts is that the verb is
# dispatched at all and that a mistyped one is refused rather than passed through.
#
# THE EXACT CODE IS ASSERTED, not merely non-zero. cmd_stop propagates the helper's exit status, so
# these codes are a published contract (ai-tools(1), docs/session-stop.md): 2 is usage, and 1
# already means "a process survived SIGKILL" -- a caller told 1 for a typo reads it as a failed
# kill. A `-ne 0` assertion cannot see that difference, and did not: the CLI refused through its
# own die (1) against a documented 2, and only the live drill, which pins the code, caught it.
if command -v runuser >/dev/null 2>&1; then
    section "CLI --stop (argument grammar)"
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" setsid \
            "${CLI}" --stop --bogus 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -eq 2 ]] && grep -qi 'unknown --stop option' <<<"${out}"; then
        pass "--stop refuses an unknown option with the documented usage code (2)"
    else
        fail "--stop did not refuse an unknown option with rc=2 (rc=${rc}): ${out}"
    fi
    # A path is refused BY THE CLI, before sudo. Accepting it would invert the operator's intent
    # in the destructive direction -- they typed a path to narrow the command, which terminates
    # every session -- and the refusal must name the alternative rather than dead-end them.
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" setsid \
            "${CLI}" --stop /some/project 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -eq 2 ]] && grep -qi 'takes no path' <<<"${out}" && grep -q '/exit' <<<"${out}"; then
        pass "--stop refuses a path (rc=2) and names /exit as the way to end one session"
    else
        fail "--stop accepted a path, or refused it without rc=2/guidance (rc=${rc}): ${out}"
    fi
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" setsid \
            "${CLI}" --stop --all /some/project 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -eq 2 ]] && grep -qi 'takes no path' <<<"${out}"; then
        pass "a path is refused (rc=2) even beside --all"
    else
        fail "--stop --all accepted a path or refused it without rc=2 (rc=${rc}): ${out}"
    fi
fi

# --for <operator>: acting on another enrolled operator's registry. Every refusal here precedes the
# root helper entirely, so none of these reach a sudo prompt. The helper's own gates are asserted
# in tests/unit/allowlist-helper.sh; what this covers is the CLI deciding, up front, that a run
# must not proceed at all.
if command -v runuser >/dev/null 2>&1; then
    section "CLI --for (acting for another operator)"
    mktestdir
    chmod 755 "${TESTDIR}"
    fconf="${TESTDIR}/operator.conf"
    printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${fconf}"; chmod 644 "${fconf}"
    fproj="${TESTDIR}/forproj"; mkdir -p "${fproj}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${fproj}"
    fal="${TESTDIR}/for-allowlist"; : > "${fal}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${fal}"

    # setsid: every assertion below expects a refusal, and each must land BEFORE the gate's
    # snapshot step, which is a --for run's only sudo. Without a controlling terminal sudo cannot
    # open /dev/tty to prompt (a stdin redirect does not stop it) and fails at once, so a
    # regression that let a refusal fall past the snapshot FAILS here instead of hanging on a
    # developer's password prompt -- the asymmetry being that a container with no tty would fail
    # while an interactive run stalls indefinitely. -w because setsid FORKS when it is already a
    # process-group leader, and the bare form then returns 0 rather than the command's status,
    # which would quietly pass every rc-based assertion below.
    run_for() {
        runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${fconf}" AI_TOOLS_ALLOWLIST="${fal}" \
            setsid -w "${CLI}" "$@" 2>&1
    }

    # (1) An unenrolled target is refused, naming the enrolment command. Nothing may be written for
    # a name the ownership helpers cannot later resolve to an owner.
    out="$(run_for --project-claim --for definitely-not-an-operator "${fproj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not a configured ai-tools operator' <<<"${out}"; then
        pass "--for refuses an unenrolled target operator"
    else
        fail "--for accepted an unenrolled target (rc=${rc}): ${out}"
    fi
    if [[ -s "${fal}" ]]; then
        fail "refused --for run still wrote to a registry: $(cat "${fal}")"
    else
        pass "refused --for run wrote no registry state"
    fi

    # (2) The sandbox account can never be a --for target: it would be the agent owning projects.
    out="$(run_for --project-claim --for "${SANDBOX_USER}" "${fproj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not an operator' <<<"${out}"; then
        pass "--for refuses the sandbox account as the target"
    else
        fail "--for accepted the sandbox account (rc=${rc}): ${out}"
    fi

    # (3) Refused, not ignored, on a verb it does not apply to -- a --sandbox-create that silently
    # cloned as the invoker would leave the tree owned by the wrong operator with nothing to show.
    out="$(run_for --sandbox-create --for "${PROJECTS_USER}" "${fproj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'for is not accepted on' <<<"${out}"; then
        pass "--for is refused on a verb that does not accept it (not silently ignored)"
    else
        fail "--for was not refused on --sandbox-create (rc=${rc}): ${out}"
    fi

    # (4) --force binds an unlisted tree to the INVOKING uid inside ai-tools-unclaim, so honouring
    # --for there would have the CLI name one operator while the helper acted as another.
    out="$(run_for --project-unclaim --force --for "${PROJECTS_USER}" "${fproj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'cannot be combined with --force' <<<"${out}"; then
        pass "--for refuses to combine with --project-unclaim --force"
    else
        fail "--for was accepted alongside --force (rc=${rc}): ${out}"
    fi

    # (5) A bare --for with no name is a parse error, not an empty operator silently meaning "me".
    out="$(run_for --project-claim --for)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'for needs an operator name' <<<"${out}"; then
        pass "--for with no operator name is refused"
    else
        fail "--for with no name was not refused (rc=${rc}): ${out}"
    fi
fi

# ── --audit: the reader for the refusal trails ───────────────────────────────────────────────
# Driven against the deployed helper directly rather than through `ai-tools --audit`, because the
# CLI reaches it via sudo with no NOPASSWD rule and would prompt for a password. The helper is
# where every decision lives (the CLI is a pass-through that propagates its exit status), and
# AI_TOOLS_LOG_DIR -- the same root-only hook the harness already uses -- points it at a seeded
# throwaway trail instead of the production one. Root-only, so this needs the suite's root.
section "ai-tools --audit reads the refusal trails"
audit_bin=/usr/local/libexec/ai-tools/ai-tools-audit
if [[ ! -x "${audit_bin}" ]]; then
    skip "--audit" "${audit_bin} not installed"
else
    audit_dir="${TESTDIR}/audit-trail"
    mkdir -p "${audit_dir}"
    audit_now="$(date -Is)"
    audit_old="$(date -Is -d '30 days ago')"
    # One finding per level that counts, one INFO that must not, and one line older than any
    # window this test asks for.
    {
        printf '%s INFO    [1] restored ownership of /tmp/x (routine, must NOT be reported)\n' "${audit_now}"
        printf '%s NOTICE  [1] NOTICE: secret-named file written by agent considered breached: /p/.env\n' "${audit_now}"
        printf '%s ERROR   [1] AUDIT-OLD-MARKER outside every window under test\n' "${audit_old}"
    } > "${audit_dir}/chown.log"
    printf '%s WARNING [2] rejected peer uid=1234 (not the sandbox account)\n' "${audit_now}" \
        > "${audit_dir}/handback.log"

    # (1) Findings present -> reported, and the exit status is non-zero so cron//etc/profile.d
    #     can act on it without parsing the output.
    out="$(AI_TOOLS_LOG_DIR="${audit_dir}" "${audit_bin}" --since '2 days ago' 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -q 'breached' <<<"${out}" && grep -q 'rejected peer' <<<"${out}"; then
        pass "--audit reports findings from every root-only log and exits non-zero"
    else
        fail "--audit did not report the seeded findings (rc=${rc}): ${out}"
    fi

    # (2) Severity is the selector, so routine INFO churn must not surface. An audit command
    #     that reports every ownership restore is one an operator stops reading.
    if grep -q 'must NOT be reported' <<<"${out}"; then
        fail "--audit reported an INFO line -- the severity floor is not being applied"
    else
        pass "--audit reports NOTICE and above only (routine INFO churn stays out)"
    fi

    # (3) The window is honoured: a finding older than --since is out of scope.
    if grep -q 'AUDIT-OLD-MARKER' <<<"${out}"; then
        fail "--audit reported a finding older than --since -- the window is not applied"
    else
        pass "--audit honours --since (an older finding is out of the window)"
    fi

    # (3b) Repeats collapse, and severity leads. This is what makes the command usable rather
    #      than merely correct: a recurring condition writes one line per occurrence -- the
    #      handback daemon's refusals run to hundreds over a week on a host that exercises them
    #      -- and an uncollapsed report buries the one ERROR that needs acting on. Seed a
    #      recurring warning that differs only in its pid, alongside a single ERROR, and assert
    #      the report folds the first and leads with the second.
    for audit_pid in 111 222 333 444; do
        printf '%s WARNING [%d] rejected malformed arg for CHOWN (pid %d)\n' \
            "${audit_now}" "${audit_pid}" "${audit_pid}" >> "${audit_dir}/handback.log"
    done
    printf '%s ERROR   [9] AUDIT-REAL-FINDING that must not be buried\n' "${audit_now}" \
        > "${audit_dir}/relabel.log"
    out="$(AI_TOOLS_LOG_DIR="${audit_dir}" "${audit_bin}" --since '2 days ago' 2>&1)" || true

    if [[ "$(grep -c 'rejected malformed arg' <<<"${out}")" == 1 ]] \
            && grep -qE '4x +rejected malformed arg' <<<"${out}"; then
        pass "--audit collapses a repeated finding into one line carrying its count"
    else
        fail "--audit did not collapse the four repeats of one finding: ${out}"
    fi

    # The ERROR must be the first finding printed -- an operator reads the top of a report.
    if [[ "$(grep -E '^\s+(ERROR|WARNING|NOTICE)\s' <<<"${out}" | head -1)" == *AUDIT-REAL-FINDING* ]]; then
        pass "--audit leads with the most severe finding, ahead of recurring noise"
    else
        fail "--audit did not lead with the ERROR: $(grep -E '^\s+(ERROR|WARNING|NOTICE)\s' <<<"${out}" | head -3)"
    fi

    # (4) A clean window exits zero, so a healthy host does not alarm every night.
    out="$(AI_TOOLS_LOG_DIR="${audit_dir}" "${audit_bin}" --since '+1 hour' 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && grep -qi 'nothing refused' <<<"${out}"; then
        pass "--audit exits zero and says so when the window holds no findings"
    else
        fail "--audit did not report a clean window (rc=${rc}): ${out}"
    fi

    # (5) An unparseable --since is REFUSED, never widened to "everything": a typo that silently
    #     reported all of history would read as a catastrophe, and one that silently reported
    #     nothing would read as all-clear. Both are worse than an error.
    out="$(AI_TOOLS_LOG_DIR="${audit_dir}" "${audit_bin}" --since 'not a date' 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not understood' <<<"${out}"; then
        pass "--audit refuses a --since value date(1) cannot parse"
    else
        fail "--audit accepted an unparseable --since (rc=${rc}): ${out}"
    fi

    # (6) The DEPLOYED CLI reaches the helper. (1)-(5) drive the helper directly, so nothing so
    #     far would notice a verb that was never wired into the dispatch. Asserted through the
    #     help text rather than by running the verb, which sudo-prompts (no NOPASSWD rule).
    #     The usage()/man-page pairing itself is covered from source in unit/man.sh; what this
    #     adds is that the copy actually installed on this host carries it -- which is why it
    #     SKIPS rather than fails when the deployed CLI predates the verb. That is the normal
    #     state between building this branch and installing it, and it is not a defect.
    if ! command -v ai-tools >/dev/null 2>&1; then
        skip "--audit is wired into the CLI" "ai-tools is not on PATH"
    elif ai-tools --help 2>&1 | grep -q -- '--audit'; then
        pass "the deployed ai-tools dispatches --audit"
    else
        skip "--audit is wired into the CLI" "the deployed ai-tools predates the verb (install this version to cover it)"
    fi
fi

finish

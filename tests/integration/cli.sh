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
# sides on a host whose only operator does not hold a general sudo grant. Asserted on the refusal text
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
    if grep -qi 'manage the projects a sandboxed coding agent may work in' <<<"${out}"; then
        pass "--help stays open to a non-operator user"
    else
        fail "--help was blocked for a non-operator: ${out}"
    fi

    # (6) --project-unclaim classifies its target against allowed-projects: a directory that no
    # entry covers AND that has no ai-tools ownership or group is REFUSED, before any
    # registry/filesystem change. The testdir path is not in the (real) allowlist and is freshly
    # created, so it classifies as unrelated-and-clean -- the one outcome with no remedy to offer
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
            fail "--project-claim did not refuse a third-party-owned root (rc=${rc}): $(brief "${out}")"
        fi
        if grep -q "chown -R ${PROJECTS_USER} ${foreignproj}" <<<"${out}"; then
            pass "the refusal names the chown that makes the tree claimable"
        else
            fail "the refusal did not name the chown remedy: $(brief "${out}" 'chown')"
        fi
        if [[ -s "${emptyal}" ]]; then
            fail "refused claim still wrote to the allowlist: $(cat "${emptyal}")"
        else
            pass "the owner refusal precedes every registry write"
        fi
    else
        skip "third-party-owned claim root" "user 'nobody' not present"
    fi

    # brief <captured-output> [pattern]  -- a SHORT diagnostic for a FAIL message. The flows below
    # print thirty-odd lines of headline blocks and per-step results, and interpolating all of
    # that into a failure line buries the one thing that explains it -- especially in the runner's
    # end-of-run summary, which reprints FAIL lines and is unreadable if each is a screenful.
    # With a <pattern> it shows the lines the assertion is actually about; without one, the last
    # three non-empty lines, which is where a refusal or a die() lands. Joined with " ~ " so the
    # message stays a single line.
    brief() {
        local text="$1" pat="${2:-}" sel=""
        [[ -n "${pat}" ]] && sel="$(grep -iE -- "${pat}" <<<"${text}" | head -n 3)"
        [[ -n "${sel}" ]] || sel="$(awk 'NF' <<<"${text}" | tail -n 3)"
        awk '{printf "%s%s", sep, $0; sep=" ~ "}' <<<"${sel}"
    }

    # (6c) --project-create is a real verb, not an alias, so its refusals are asserted where the
    # old alias had none. Every one of them must leave NO RESIDUE behind -- no directory, no registry
    # entry -- which is what makes "recover with --project-claim" the only recovery path it needs.
    : > "${emptyal}"
    create_cli() {
        runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
            setsid "${CLI}" --project-create "$@" 2>&1
    }

    # A path is REQUIRED: the cwd always exists, so a defaulted create could only ever refuse.
    out="$(create_cli)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'needs a path' <<<"${out}"; then
        pass "--project-create refuses to run without a path"
    else
        fail "--project-create did not refuse a missing path (rc=${rc}): $(brief "${out}")"
    fi

    # An EXISTING directory is refused, naming the verb that does claim one. This is the line
    # between the two verbs: a create that quietly claimed what was already there would make them
    # interchangeable, and only one of them grants an agent access to an existing tree.
    exists="${TESTDIR}/already-here"; mkdir -p "${exists}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${exists}"
    out="$(create_cli "${exists}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'already exists' <<<"${out}" \
            && grep -q -- '--project-claim' <<<"${out}"; then
        pass "--project-create refuses an existing directory, naming --project-claim"
    else
        fail "--project-create did not refuse an existing directory (rc=${rc}): $(brief "${out}")"
    fi

    # ONE directory is created, never a path of them: a parent that does not exist is refused
    # rather than built. This is what keeps a mistyped path from becoming a silently manufactured
    # tree with a claimed project inside it.
    out="$(create_cli "${TESTDIR}/no/such/parent/proj")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'parent directory does not exist' <<<"${out}" \
            && [[ ! -e "${TESTDIR}/no" ]]; then
        pass "--project-create refuses a missing parent and creates none of it"
    else
        fail "--project-create did not refuse a missing parent (rc=${rc}): $(brief "${out}")"
    fi

    # The protected-paths backstop on the target: a create must not be able to MANUFACTURE a
    # protected directory. Exits 3, the backstop's own code. Driven against a protected path this
    # host does not have; if it has all of them there is no path to assert and the case skips.
    protected=""
    for p in /efi /lost+found /libx32 /lib32 /srv /media; do
        [[ -e "${p}" ]] || { protected="${p}"; break; }
    done
    if [[ -n "${protected}" ]]; then
        out="$(create_cli "${protected}")" && rc=0 || rc=$?
        if [[ ${rc} -eq 3 ]] && [[ ! -e "${protected}" ]]; then
            pass "--project-create refuses a protected target (exit 3, nothing created)"
        else
            fail "--project-create did not refuse protected ${protected} with exit 3 (rc=${rc}): $(brief "${out}")"
        fi
    else
        skip "--project-create protected-target refusal" "this host has every protected path already"
    fi

    # Atomic on refusal: none of the above may have written a registry entry. The fixture
    # allowlist is the one a regression would touch.
    if [[ -s "${emptyal}" ]]; then
        fail "a refused --project-create wrote to the allowlist: $(cat "${emptyal}")"
    else
        pass "every refused --project-create left the allowlist untouched"
    fi

    # THE HAPPY PATH. Every assertion above is a refusal, which together can be satisfied by a
    # verb that acts on no path at all -- so the one run that has to actually work is asserted too,
    # end to end and unattended. It runs under setsid with NO -y (the verb has none): a create
    # that still asked something would block here and be killed by the file timeout, which is the
    # regression this also guards.
    crwork="${TESTDIR}/create-work"; mkdir -p "${crwork}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${crwork}"; chmod 755 "${crwork}"
    : > "${emptyal}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${emptyal}"
    newproj="${crwork}/newproject"
    # The exit status depends on whether this environment can authenticate for the claim's root
    # helpers. Under setsid there is no terminal to type a password at, so the claim reports that
    # it could not finish and exits 1; where the suite's sudo does not require a password it exits 0. Both
    # are correct, and both are asserted -- what must never happen is the third outcome this
    # replaced, where every root step failed and the flow still closed on a success mark.
    out="$(create_cli "${newproj}")" && rc=0 || rc=$?
    if [[ -d "${newproj}" ]] && { [[ ${rc} -eq 0 ]] \
            || { [[ ${rc} -eq 1 ]] && grep -qi 'the claim did not complete' <<<"${out}"; }; }; then
        pass "--project-create creates the project and reports the claim outcome honestly"
    else
        fail "--project-create neither completed nor reported why (rc=${rc}): $(brief "${out}")"
    fi
    # The two must not co-occur: a claim that reports steps it could not apply has not claimed.
    if grep -qi 'did not complete' <<<"${out}" && grep -q '✓ claimed' <<<"${out}"; then
        fail "the claim reported both an incomplete state and success: $(brief "${out}" 'did not complete|claimed')"
    else
        pass "the claim never reports success alongside steps it could not apply"
    fi
    if [[ -d "${newproj}/.git" ]] && [[ -f "${newproj}/README.md" ]] \
            && grep -qxF '# newproject' "${newproj}/README.md"; then
        pass "--project-create initializes git and writes a README naming the directory"
    else
        fail "--project-create left an incomplete tree: $(ls -A "${newproj}" 2>&1)"
    fi
    if grep -qxF "${newproj}" "${emptyal}"; then
        pass "--project-create registers the new project in allowed-projects"
    else
        fail "--project-create did not register the project: $(cat "${emptyal}")"
    fi
    # The tree it makes is owned by the operator, which is what the claim's own owner guard
    # requires -- a create that produced a root-owned tree would claim no path and say so.
    if [[ "$(stat -c '%U' "${newproj}")" == "${PROJECTS_USER}" ]]; then
        pass "--project-create leaves the tree owned by the operator it acts for"
    else
        fail "the created tree is owned by $(stat -c '%U' "${newproj}"), not ${PROJECTS_USER}"
    fi
    # The secret scan is skipped on an empty tree, so a create must never reach
    # ai-tools-lockdown. Asserted on that helper specifically, NOT on the absence of any password
    # prompt: the claim legitimately sudo's for safedir, setgid, setfacl and relabel, since group
    # ownership cannot be changed to a group the operator is not in without root.
    if ! grep -q 'ai-tools-lockdown' <<<"${out}" \
            && ! grep -qi 'scan for secret-named files' <<<"${out}"; then
        pass "--project-create never reaches the secret scan (nothing in the tree to scan)"
    else
        fail "--project-create ran the secret scan on a tree it had just created: $(brief "${out}" 'lockdown|secret-named')"
    fi

    # No path it seeds may be owner-only. Under a umask of 077 the directory would be born 0700,
    # README.md 0600, and .git 0700/0600 -- and an owner-only path is one the claim's helpers
    # honour as a seal and skip, so the verb would produce a registered project whose README the
    # agent cannot read and whose git it cannot use, having reported that it normalized both.
    # This is the assertion that fails on a umask-077 host if any of those modes is inherited.
    _sealed=""
    for _p in "${newproj}" "${newproj}/README.md" "${newproj}/.git" "${newproj}/.git/config"; do
        [[ -e "${_p}" ]] || continue
        (( (8#$(stat -c '%a' "${_p}") & 077) == 0 )) && _sealed+=" ${_p}($(stat -c '%a' "${_p}"))"
    done
    if [[ -z "${_sealed}" ]]; then
        pass "--project-create seeds nothing owner-only (reachable whatever the host umask)"
    else
        fail "--project-create seeded owner-only path(s) the claim will skip:${_sealed}"
    fi
    # Matched on the NOTICE's own title, not on the phrase "owner-only": the create prints that
    # phrase itself when it explains the modes it set on a umask-077 host, so a looser grep
    # asserts the opposite of what it means on exactly the hosts this case exists for.
    if ! grep -qi 'this project directory is owner-only' <<<"${out}"; then
        pass "the claim does not report the new project as out of the agent's reach"
    else
        fail "the created project was claimed as owner-only: $(brief "${out}" 'owner-only')"
    fi

    # (6d) --project-remove deletes, so every assertion here is that it did NOT. Its authorization
    # is an exact allowlist entry alone: there is no --force, and an unattended run
    # never reaches the deletion because both the default-NO confirm and the typed-name challenge
    # decline with no terminal (these run under setsid, so that is the path being driven).
    remove_cli() {
        runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${rmal}" \
            setsid "${CLI}" --project-remove "$@" 2>&1
    }
    # The fixture registry lives in a directory the PROJECTS user owns, not in TESTDIR itself
    # (root-owned): unreg_allow rewrites the allowlist with `sed -i`, which writes its temporary
    # file into the file's own DIRECTORY, so a root-owned parent fails the removal even though the
    # file is writable. That is the same shape as the real layout, where the allowlist sits in the
    # operator's own 0700 ~/.config/ai-tools.
    regdir="${TESTDIR}/registries"; mkdir -p "${regdir}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${regdir}"; chmod 700 "${regdir}"
    rmal="${regdir}/remove-allowlist"
    # The project fixtures live under a directory the PROJECTS user OWNS, because removing a
    # project ends by unlinking it from its parent -- which needs write permission there, not on
    # the project. Root-owned TESTDIR would fail that, which is a real refusal (asserted on its
    # own below) rather than the case these are for.
    rmwork="${TESTDIR}/work"; mkdir -p "${rmwork}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${rmwork}"; chmod 755 "${rmwork}"
    rmproj="${rmwork}/rm-proj"; mkdir -p "${rmproj}/sub"
    rmnested="${rmproj}/inner"; mkdir -p "${rmnested}"
    rmother="${rmwork}/rm-other"; mkdir -p "${rmother}"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmproj}" "${rmother}"

    # An unregistered path is refused: the registry entry is the authorization, so a tree no registry names
    # claimed is not this verb's to delete.
    printf '%s\n' "${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli "${rmother}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmother}" ]] && grep -qi 'not a claimed project' <<<"${out}"; then
        pass "--project-remove refuses an unregistered path, deleting nothing"
    else
        fail "--project-remove did not refuse an unregistered path (rc=${rc}): $(brief "${out}")"
    fi

    # A path INSIDE a claimed project is refused, naming the project that is the real target.
    out="$(remove_cli "${rmproj}/sub")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmproj}/sub" ]] && grep -qF "${rmproj}" <<<"${out}"; then
        pass "--project-remove refuses a path inside a project, naming the project"
    else
        fail "--project-remove did not refuse a descendant (rc=${rc}): $(brief "${out}")"
    fi

    # An ancestor of claimed projects is refused and pointed at --project-unclaim: this verb
    # removes one registered project, never a directory that merely contains some.
    out="$(remove_cli "${rmwork}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmproj}" ]] && grep -q -- '--project-unclaim' <<<"${out}"; then
        pass "--project-remove refuses an ancestor of claimed projects"
    else
        fail "--project-remove did not refuse an ancestor (rc=${rc}): $(brief "${out}")"
    fi

    # An exact entry that CONTAINS another claimed project is refused. Deleting it would take the
    # nested one with it and leave that project registered, git-trusted and labelled at a path
    # that no longer exists.
    printf '%s\n%s\n' "${rmproj}" "${rmnested}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli "${rmproj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmnested}" ]] && grep -qF "${rmnested}" <<<"${out}"; then
        pass "--project-remove refuses a project containing another claimed project, naming it"
    else
        fail "--project-remove did not refuse a project with a nested claim (rc=${rc}): $(brief "${out}")"
    fi

    # There is no --force: the flag that reaches an unregistered tree on unclaim must not become
    # a way to delete one here.
    printf '%s\n' "${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli --force "${rmother}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmother}" ]] && grep -qi 'no --force' <<<"${out}"; then
        pass "--project-remove has no --force (an unregistered tree stays undeletable by it)"
    else
        fail "--project-remove accepted or mishandled --force (rc=${rc}): $(brief "${out}")"
    fi

    # -y requires an explicit path, so an unattended run can never delete whatever directory it
    # started in.
    out="$(cd "${rmproj}" && remove_cli -y)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmproj}" ]] && grep -qi 'needs a path' <<<"${out}"; then
        pass "--project-remove -y refuses to inherit the current directory"
    else
        fail "--project-remove -y did not require an explicit path (rc=${rc}): $(brief "${out}")"
    fi

    # And the property the whole gate exists for: a registered project, correctly targeted, is
    # still NOT deleted without a terminal -- the confirm takes its No default and the challenge
    # has no default to take. The allowlist entry must survive too, since the registries are torn
    # down before the deletion.
    out="$(remove_cli "${rmproj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmproj}" ]] && grep -qF "${rmproj}" "${rmal}"; then
        pass "--project-remove deletes nothing with no terminal (confirm and challenge both decline)"
    else
        fail "--project-remove acted without a terminal (rc=${rc}, dir gone or de-registered): $(brief "${out}")"
    fi

    # The deletability pre-flight, which is what keeps a removal from stopping partway. A
    # directory the acting owner can neither write nor enter is the realistic blocker (a
    # sandbox-owned 0700 left by a session), and it must refuse the WHOLE removal up front with
    # the tree still intact -- not delete as far as it can and report a failure.
    if id nobody >/dev/null 2>&1; then
        rmblocked="${rmwork}/rm-blocked"; mkdir -p "${rmblocked}/locked"
        chown "${PROJECTS_USER}:${PROJECTS_USER}" "${rmblocked}"
        chown nobody:nobody "${rmblocked}/locked"; chmod 0700 "${rmblocked}/locked"
        printf '%s\n' "${rmblocked}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
        out="$(remove_cli -y "${rmblocked}")" && rc=0 || rc=$?
        if [[ ${rc} -ne 0 ]] && [[ -d "${rmblocked}/locked" ]] \
                && grep -q -- '--reclaim --full' <<<"${out}" \
                && grep -qF "${rmblocked}" "${rmal}"; then
            pass "--project-remove refuses an undeletable tree up front, intact and still registered"
        else
            fail "--project-remove did not stop on the deletability pre-flight (rc=${rc}): $(brief "${out}")"
        fi
    else
        skip "--project-remove deletability pre-flight" "user 'nobody' not present"
    fi

    # AI_TOOLS_ASSUME_YES MUST NOT DELETE ANYTHING. This is the highest-consequence property the
    # verb has and the easiest to regress: the variable is a legitimate thing for an operator to
    # export for unattended runs of every other command, and if it reached either of this verb's
    # two questions it would silently delete whole projects on a host where nobody typed -y. It
    # cannot: the confirm's default is NO (the lib only fast-tracks default-YES questions) and the
    # challenge has no default at all. Asserted with the variable set AND a terminal absent, which
    # is exactly how an unattended run arrives.
    printf '%s\n' "${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${rmal}" \
            AI_TOOLS_ASSUME_YES=1 \
            setsid "${CLI}" --project-remove "${rmproj}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmproj}" ]] && grep -qF "${rmproj}" "${rmal}"; then
        pass "AI_TOOLS_ASSUME_YES does not delete a project (neither prompt is fast-trackable)"
    else
        fail "AI_TOOLS_ASSUME_YES deleted or deregistered a project (rc=${rc}): $(brief "${out}")"
    fi

    # A protected path as the removal target: exit 3, whatever the allowlist says. The scenario is
    # an operator (or a script) reaching for a home root or a system directory -- the allowlist is
    # hand-editable, so the backstop has to stand on its own. Both are driven with -y, the only
    # mode that can reach a deletion unattended, and the entry is planted deliberately so the
    # classification would otherwise ACCEPT the target.
    # The home case is included only in the /home/<user> shape the home-root rule covers by
    # construction. Elsewhere it is skipped rather than assumed: this drives -y against a planted
    # entry, so a host where the assumption did not hold would be pointing a real removal at a
    # real home. /etc is on the protected list unconditionally.
    _protected_targets=(/etc)
    [[ "${PROJECTS_HOME}" =~ ^/home/[^/]+$ ]] && _protected_targets+=("${PROJECTS_HOME}")
    for _bad in "${_protected_targets[@]}"; do
        printf '%s\n' "${_bad}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
        out="$(remove_cli -y "${_bad}")" && rc=0 || rc=$?
        if [[ ${rc} -eq 3 ]] && [[ -d "${_bad}" ]]; then
            pass "--project-remove refuses the protected path ${_bad} (exit 3) even when listed"
        else
            fail "--project-remove did not refuse protected ${_bad} with exit 3 (rc=${rc}): $(brief "${out}")"
        fi
    done

    # -y must not bypass the classification. The scripted-removal mistake is a -y run pointed at a
    # path that is not a claimed project; the flag pre-answers the two prompts alone.
    printf '%s\n' "${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli -y "${rmother}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmother}" ]]; then
        pass "-y does not bypass the registry check (an unlisted path is still refused)"
    else
        fail "-y deleted an unregistered path (rc=${rc}): $(brief "${out}")"
    fi

    # A parent the acting owner cannot write must REFUSE, and this is the case with the worst
    # failure mode if it is missed: `rm -rf` needs write permission on the directory it unlinks
    # the project FROM, not on the project, so rm descends, deletes every file successfully, and
    # fails only on the top directory -- leaving an empty husk that is already deregistered. The
    # fixture is a project owned by the operator directly inside the root-owned testdir, which is
    # exactly that shape. Both the tree AND its contents must survive.
    rmpar="${TESTDIR}/rm-parent"; mkdir -p "${rmpar}/sub"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmpar}"
    printf '%s\n' "${rmpar}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli -y "${rmpar}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmpar}/sub" ]] \
            && grep -qi 'parent directory is not writable' <<<"${out}" \
            && grep -qF "${rmpar}" "${rmal}"; then
        pass "--project-remove refuses an unwritable parent before deleting any of the tree"
    else
        fail "--project-remove did not refuse an unwritable parent (rc=${rc}, contents gone: $([[ -d "${rmpar}/sub" ]] && echo no || echo yes)): $(brief "${out}" 'parent directory')"
    fi

    # A registry the removal cannot rewrite must REFUSE, not delete. The allowlist entry is the
    # agent's launch gate, so deleting the tree past a failed de-registration would strand a
    # registration that is still standing -- exactly what this verb's teardown order exists to
    # prevent. The fixture puts the allowlist in the ROOT-owned testdir: `sed -i` writes its
    # temporary file into the file's own directory, so the rewrite fails while the file itself
    # stays writable, which is also how this fails on a real host.
    rmstuck="${rmwork}/rm-stuck"; mkdir -p "${rmstuck}"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmstuck}"
    stuckal="${TESTDIR}/stuck-allowlist"
    printf '%s\n' "${rmstuck}" > "${stuckal}"; chown "${PROJECTS_USER}" "${stuckal}"
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${stuckal}" \
            setsid "${CLI}" --project-remove -y "${rmstuck}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmstuck}" ]] && grep -qi 'still registered' <<<"${out}"; then
        pass "--project-remove refuses to delete when the allowlist entry cannot be removed"
    else
        fail "--project-remove acted past a failed de-registration (rc=${rc}): $(brief "${out}")"
    fi

    # Teardown order: registries before the tree. Driven with -y, which is the one path that
    # reaches the deletion without a terminal, over a project that IS fully deletable. Both
    # halves are asserted -- the tree is gone AND the allowlist entry with it -- because the
    # ordering guarantee is only meaningful if the deletion actually ran.
    rmgo="${rmwork}/rm-go"; mkdir -p "${rmgo}/sub"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmgo}"
    printf '%s\n' "${rmgo}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    # The tree must be gone and deregistered. The exit status depends on the environment: on an
    # enforcing host the SELinux label removal needs a password this run cannot supply, so a
    # cleanup step fails and the verb exits 1 while still having removed the project. Both are
    # correct; what is asserted is that a run with failures does NOT close on a success mark.
    out="$(remove_cli -y "${rmgo}")" && rc=0 || rc=$?
    if [[ ! -e "${rmgo}" ]] && ! grep -qF "${rmgo}" "${rmal}" \
            && { [[ ${rc} -eq 0 ]] \
                 || { [[ ${rc} -eq 1 ]] && grep -qi 'cleanup step(s) did not run' <<<"${out}"; }; }; then
        pass "--project-remove -y deregisters and then deletes (registries first, tree last)"
    else
        fail "--project-remove -y did not complete (rc=${rc}, dir exists: $([[ -e "${rmgo}" ]] && echo yes || echo no)): $(brief "${out}")"
    fi
    if grep -q '✓ removed' <<<"${out}" && grep -qi 'cleanup step(s) did not run' <<<"${out}"; then
        fail "the removal showed a success mark alongside failed cleanup: $(brief "${out}" 'removed|cleanup')"
    else
        pass "the removal reserves its success mark for a run with no failures"
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
    # path outside SANDBOX_ROOT. The refusal precedes the removal, so no path is deleted.
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

    # (1) An unenrolled target is refused, naming the enrolment command. No entry may be written for
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
    # cloned as the invoker would leave the tree owned by the wrong operator with no output to show.
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

# ── --project-disable / --project-enable: parking a project in place ─────────────────────────
# The pair edits ONE line of the operator's own allowlist and does not reach a root helper, so the whole
# lifecycle is drivable here as the projects user over the fixture registry. What is asserted is
# what the flat-file model rests on (the three entry states, in cli.rule.md): the line is edited IN
# PLACE, a parked project is not an unlisted one, and neither verb ever invents or lifts a line it
# cannot attribute -- since lifting the wrong '!' hands the agent a subtree its operator withheld.
section "ai-tools --project-disable / --project-enable"

if ! command -v runuser >/dev/null 2>&1; then
    skip "--project-disable/--project-enable" "runuser unavailable"
else
    mktestdir
    chmod 755 "${TESTDIR}"
    pd_conf="${TESTDIR}/op.conf"
    printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${pd_conf}"; chmod 644 "${pd_conf}"
    pd_al="${TESTDIR}/allowed-projects"
    pd_proj="${TESTDIR}/api"; pd_other="${TESTDIR}/web"
    pd_nested="${pd_proj}/service-a"; pd_carve="${pd_proj}/secrets"
    mkdir -p "${pd_proj}" "${pd_other}" "${pd_nested}" "${pd_carve}"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${TESTDIR}"

    # pd_cli <args...> : run the CLI as the operator against the fixture registry, under setsid so
    # every prompt takes its non-interactive default (the re-enable confirm defaults NO).
    pd_cli() {
        runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${pd_conf}" AI_TOOLS_ALLOWLIST="${pd_al}" \
            setsid "${CLI}" "$@" 2>&1
    }
    pd_seed() { printf '%s\n' "$@" > "${pd_al}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${pd_al}"; }

    # (1) Park a listed project: the line keeps its position, indentation and comment. That is the
    # whole reason these verbs exist rather than being an unclaim/claim pair -- an operator whose
    # allowed-projects is an ordered, commented document gets it back unchanged.
    pd_seed "# projects" "  ${pd_proj}   # payments, dev stage" "${pd_other}"
    pd_before="$(cat "${pd_al}")"
    out="$(pd_cli --project-disable "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && [[ "$(sed -n '2p' "${pd_al}")" == "  !${pd_proj}   # payments, dev stage" ]]; then
        pass "--project-disable parks the entry in place, keeping position and comment"
    else
        fail "--project-disable did not park the entry (rc=${rc}): $(brief "${out}")"
    fi
    if grep -qi 'handback' <<<"${out}"; then
        pass "the disable states the consequence an operator has to know (the handback stops)"
    else
        fail "the disable did not mention the ownership handback: $(brief "${out}")"
    fi

    # (2) A parked project is NOT an unlisted one. The claim must not append a second, positive
    # line that the '!' would go on winning over -- it offers the re-enable, which with no
    # terminal takes its default NO, and refuses.
    out="$(pd_cli --project-claim "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'disabled' <<<"${out}"; then
        pass "--project-claim over a parked project refuses instead of claiming"
    else
        fail "--project-claim did not refuse over a parked project (rc=${rc}): $(brief "${out}")"
    fi
    if [[ "$(grep -cF "${pd_proj}" "${pd_al}")" == 1 ]]; then
        pass "the refused claim appended no duplicate line"
    else
        fail "the refused claim duplicated the entry:"$'\n'"$(cat "${pd_al}")"
    fi

    # (3) --list calls it what it is, and names the verb that restores it.
    out="$(pd_cli --list)" || true
    if grep -qE "disabled[[:space:]]+${pd_proj}" <<<"${out}" \
            && grep -qF -- "--project-enable ${pd_proj}" <<<"${out}"; then
        pass "--list reports a parked project as disabled, with the re-enable command"
    else
        fail "--list did not report the parked project: $(brief "${out}" 'disabl|exclude')"
    fi

    # (4) Restore it: the file comes back byte-identical to before the park.
    out="$(pd_cli --project-enable "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && [[ "$(cat "${pd_al}")" == "${pd_before}" ]]; then
        pass "--project-enable restores the file byte-identically (a lossless round trip)"
    else
        fail "--project-enable did not restore the file (rc=${rc}): $(brief "${out}")"$'\n'"$(cat "${pd_al}")"
    fi

    # (5) Neither verb invents an entry. Registering a project is a claim -- it scans for secrets
    # before granting access -- so a path the file does not name is refused by both, pointing there.
    for verb in --project-disable --project-enable; do
        out="$(pd_cli "${verb}" "${TESTDIR}")" && rc=0 || rc=$?
        if [[ ${rc} -ne 0 ]] && grep -qi 'not a claimed project' <<<"${out}" \
                && grep -qF -- '--project-claim' <<<"${out}"; then
            pass "${verb} refuses an unregistered path and names --project-claim"
        else
            fail "${verb} did not refuse an unregistered path (rc=${rc}): $(brief "${out}")"
        fi
    done
    if [[ "$(cat "${pd_al}")" == "${pd_before}" ]]; then
        pass "both refusals left the registry untouched"
    else
        fail "a refusal wrote to the registry:"$'\n'"$(cat "${pd_al}")"
    fi

    # (6) A CARVE-OUT is not a parked project, and lifting one is the only edit here that would
    # WIDEN what the agent reaches -- a subtree its operator withheld from a claimed project. It is
    # refused, and the refusal names the project it belongs to.
    pd_seed "# projects" "${pd_proj}" "!${pd_carve}"
    out="$(pd_cli --project-enable "${pd_carve}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'inside a claimed project' <<<"${out}"; then
        pass "--project-enable refuses a carve-out rather than handing over the subtree"
    else
        fail "--project-enable did not refuse a carve-out (rc=${rc}): $(brief "${out}")"
    fi
    if grep -qF "!${pd_carve}" "${pd_al}"; then
        pass "the carve-out line survived the refusal"
    else
        fail "the refused enable deleted the carve-out:"$'\n'"$(cat "${pd_al}")"
    fi

    # (7) The other half of keeping a '!' unambiguous: parking a NESTED project would write a line
    # no reader could later tell apart from that carve-out, so no verb writes one.
    pd_seed "# projects" "${pd_proj}" "${pd_nested}"
    out="$(pd_cli --project-disable "${pd_nested}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'nested inside another claimed project' <<<"${out}"; then
        pass "--project-disable refuses to park a project nested inside another"
    else
        fail "--project-disable parked a nested project (rc=${rc}): $(brief "${out}")"
    fi
    if ! grep -qF "!${pd_nested}" "${pd_al}"; then
        pass "the refused park wrote no exclusion"
    else
        fail "the refused park wrote a line:"$'\n'"$(cat "${pd_al}")"
    fi

    # (8) The per-project verbs must not call a parked project unclaimed: on an excluded path the
    # root helpers resolve no owner and act on NO PATH, so a run that got that far would report steps
    # it never applied. (A host may also refuse earlier for a missing sudo grant -- that is a
    # different, correct refusal; what must not appear is "not a claimed project".)
    pd_seed "# projects" "!${pd_proj}"
    for verb in --reclaim --lockdown --project-unclaim; do
        out="$(pd_cli "${verb}" "${pd_proj}")" && rc=0 || rc=$?
        if [[ ${rc} -ne 0 ]] && ! grep -qi 'not a claimed project' <<<"${out}"; then
            pass "${verb} over a parked project does not report it as unclaimed"
        else
            fail "${verb} called a parked project unclaimed (rc=${rc}): $(brief "${out}")"
        fi
    done

    # (9) --project-remove's AUTHORIZATION is the exact entry, and a parked one counts: the '!'
    # records "not right now", not "not mine", and making the operator re-enable a tree they mean
    # to delete would make it launchable on the way out. So the verb must get past classification
    # -- reaching its own disabled confirm -- rather than refusing as unregistered. It must also
    # delete NO PATH here: with no terminal the confirm and the typed-name challenge both decline,
    # which is the property that keeps a destructive verb out of an unattended run.
    out="$(pd_cli --project-remove "${pd_proj}")" && rc=0 || rc=$?
    if grep -qi 'not a claimed project' <<<"${out}"; then
        fail "--project-remove refused a parked project as unregistered: $(brief "${out}")"
    elif grep -qi 'holds no sudo grant' <<<"${out}"; then
        # A host whose operator does not hold a general sudo grant refuses ahead of classification. That
        # is a different, correct refusal, and it is not what this case is about.
        skip "--project-remove over a parked project" "no sudo grant for the removal helper here"
    elif [[ ${rc} -ne 0 ]] && grep -qi 'disabled' <<<"${out}"; then
        pass "--project-remove accepts a parked entry as authorization and names the parked state"
    else
        fail "--project-remove did not recognise the parked entry (rc=${rc}): $(brief "${out}")"
    fi
    if [[ -d "${pd_proj}" ]]; then
        pass "the declined removal deleted nothing (no terminal answers both prompts NO)"
    else
        fail "--project-remove deleted a project with no terminal to confirm at"
    fi

    # (10) --keep-entry is about what becomes of an ENTRY, so it is refused where there is none to
    # keep: --force is the mode that reaches a tree the allowlist does not name. Refused rather
    # than ignored, since a flag that silently skips its work is how an operator learns the wrong model.
    out="$(pd_cli --project-unclaim --keep-entry --force "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'keep-entry cannot be combined with --force' <<<"${out}"; then
        pass "--keep-entry with --force is refused (there is no entry to keep)"
    elif grep -qi 'holds no sudo grant' <<<"${out}"; then
        skip "--keep-entry with --force" "no sudo grant for the unclaim helper here"
    else
        fail "--keep-entry --force was not refused (rc=${rc}): $(brief "${out}")"
    fi

    # (10b) --keep-entry belongs to the unclaim ALONE. A removal deletes the tree, so an entry
    # kept for it would park a path that no longer exists -- and the flag reads as though it might
    # spare something, which is the worst thing a flag can suggest on a destructive verb. Refused
    # as an unknown option rather than silently ignored.
    out="$(pd_cli --project-remove --keep-entry "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'unknown --project-remove option' <<<"${out}"; then
        pass "--project-remove refuses --keep-entry (it belongs to the unclaim)"
    else
        fail "--project-remove accepted --keep-entry (rc=${rc}): $(brief "${out}")"
    fi
    if [[ -d "${pd_proj}" ]]; then
        pass "the refused option deleted nothing"
    else
        fail "--project-remove deleted the project while refusing an option"
    fi

    # (11) An entry can be clean and the project still unreachable, because an ANCESTOR is parked
    # or a glob matches. Entry state and reachability are different questions, and reporting the
    # first as though it answered the second sends an operator hunting through their own file for
    # a refusal the CLI already knew about.
    pd_seed "# projects" "${pd_proj}" "!${TESTDIR}"
    out="$(pd_cli --project-enable "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && grep -qi 'already enabled' <<<"${out}" \
            && grep -qF "!${TESTDIR}" <<<"${out}"; then
        pass "--project-enable reports the OTHER exclusion that still parks a listed project"
    else
        fail "--project-enable did not name the blocking ancestor exclusion (rc=${rc}): $(brief "${out}" 'enabled|exclusion')"
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
    #     an empty result would read as all-clear. Both are worse than an error.
    out="$(AI_TOOLS_LOG_DIR="${audit_dir}" "${audit_bin}" --since 'not a date' 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not understood' <<<"${out}"; then
        pass "--audit refuses a --since value date(1) cannot parse"
    else
        fail "--audit accepted an unparseable --since (rc=${rc}): ${out}"
    fi

    # (6) The DEPLOYED CLI reaches the helper. (1)-(5) drive the helper directly, so no case so
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

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/cli.sh
# Integration: the ai-tools management CLI principal guard. The CLI edits the allowlist as the
# PROJECTS user (and registers git safe.directory through the ai-tools-safedir root helper); it
# must refuse to run as root (it would write the registries with the wrong owner) and as the
# sandbox account (the agent must not manage its own allowlist). Asserts both refusals fire, and
# that the projects user passes the guard. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly CLI="/usr/local/bin/ai-tools"
section "CLI principal guard (refuses root and the sandbox account)"

if [[ ! -x "${CLI}" ]]; then
    skip "CLI principal guard" "not installed at ${CLI}"; finish; exit
fi

# (1) Running as root must be refused before any registry write.
out="$("${CLI}" --list 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]] && grep -qi 'do not run as root' <<<"${out}"; then
    pass "CLI refuses to run as root (would write registries with the wrong owner)"
else
    fail "CLI did not refuse root (rc=${rc}): ${out}"
fi

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

    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${tconf}" "${CLI}" --project-claim "${proj}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not a configured ai-tools operator' <<<"${out}"; then
        pass "operator-acting command refused for a non-OPERATORS user, up front"
    else
        fail "non-operator was not cleanly refused (rc=${rc}): ${out}"
    fi
    if grep -qi 'allowed-projects: added' <<<"${out}"; then
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

    # (6) --project-unclaim classifies its target against allowed-projects: a directory that is
    # neither a claimed project nor an ancestor of one is REFUSED, before any registry/filesystem
    # change. The testdir path is not in the (real) allowlist, so it classifies as "neither".
    # Runs as an OPERATOR (conf lists the projects user) so classification runs past the operator
    # gate; under setsid so any prompt takes its non-interactive default rather than blocking.
    oconf="${TESTDIR}/op-self.conf"
    printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${oconf}"; chmod 644 "${oconf}"
    lone="${TESTDIR}/not-a-project"; mkdir -p "${lone}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lone}"
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" setsid "${CLI}" --project-unclaim "${lone}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not a claimed project' <<<"${out}"; then
        pass "--project-unclaim refuses a directory that is neither a claimed project nor an ancestor of one"
    else
        fail "--project-unclaim did not refuse a non-project (rc=${rc}): ${out}"
    fi

    # (7) --list renders the maintenance/reconciliation view (read-only smoke on the real
    # allowlist -- like the principal-guard --list runs above, it writes nothing).
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" "${CLI}" --list 2>&1)" || true
    if grep -qi 'Maintenance' <<<"${out}"; then
        pass "--list shows the Maintenance section"
    else
        fail "--list is missing the Maintenance section: ${out}"
    fi

    # (8) --reclaim and --lockdown refuse a path outside every claimed project, up front (before
    # the sudo prompt / any change) -- covered_by_project. ${lone} is not in the allowlist.
    for verb in --reclaim --lockdown; do
        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" setsid "${CLI}" "${verb}" "${lone}" 2>&1)" && rc=0 || rc=$?
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

finish

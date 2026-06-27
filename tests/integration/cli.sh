#!/usr/bin/env bash
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

finish

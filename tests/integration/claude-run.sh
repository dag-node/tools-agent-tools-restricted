#!/usr/bin/env bash
# tests/integration/claude-run.sh
# Integration: claude-run re-validates CLAUDE_EXEC and CLAUDE_PROJECT_DIR before launching a
# session -- defense in depth, so a tampered env_keep value that survived sudo cannot redirect
# execution to an arbitrary binary or start the agent in the wrong directory (the wrapper is
# not a single point of trust). Drives the deployed shim AS the agent with crafted env and
# asserts it refuses at validation, BEFORE systemd-run. Every case carries an invalid input so
# the shim always exits early and never spawns a session; a timeout backstops that. Run as root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly CRUN="/opt/ai-tools/bin/claude-run"
section "claude-run: CLAUDE_EXEC / CLAUDE_PROJECT_DIR re-validation (integration)"

if [[ ! -x "${CRUN}" ]]; then
    skip "claude-run revalidation" "not installed at ${CRUN}"; finish; exit
fi
if ! command -v runuser >/dev/null 2>&1; then
    skip "claude-run revalidation" "runuser unavailable"; finish; exit
fi

# Run claude-run AS the agent with a clean, explicitly-set CLAUDE_EXEC/CLAUDE_PROJECT_DIR
# (env -u clears any inherited value first, so the case is deterministic). timeout backstops
# the design guarantee that every case below exits at validation, never reaching the launch.
run_crun() {  # VAR=VAL ...
    timeout 10 runuser -u "${SANDBOX_USER}" -- \
        env -u CLAUDE_EXEC -u CLAUDE_PROJECT_DIR "$@" "${CRUN}" < /dev/null 2>&1
}

# (1) A CLAUDE_EXEC outside the versioned-claude shape is refused.
out="$(run_crun CLAUDE_EXEC=/bin/sh)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]] && grep -qi 'invalid or absent CLAUDE_EXEC' <<<"${out}"; then
    pass "claude-run refuses a CLAUDE_EXEC outside the versioned-claude path"
else
    fail "non-versioned CLAUDE_EXEC not refused (rc=${rc}): ${out}"
fi

# (2) A correctly-shaped CLAUDE_EXEC carrying '/../' is refused by the traversal guard.
out="$(run_crun CLAUDE_EXEC=/opt/ai-tools/.nvm/versions/node/v1.2.3/../bin/claude)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]] && grep -qi 'parent-directory references' <<<"${out}"; then
    pass "claude-run refuses a CLAUDE_EXEC with parent-directory references"
else
    fail "CLAUDE_EXEC with /../ not refused (rc=${rc}): ${out}"
fi

# (3)/(4) With a VALID CLAUDE_EXEC, a bad CLAUDE_PROJECT_DIR is refused before launch. Needs
# the real versioned target (so CLAUDE_EXEC passes); skip if it cannot be resolved.
real="$(readlink -- /opt/ai-tools/bin/claude 2>/dev/null || true)"
if [[ -z "${real}" || "${real}" != /opt/ai-tools/.nvm/versions/node/*/bin/claude ]]; then
    skip "claude-run project-dir revalidation" "cannot resolve a valid CLAUDE_EXEC target"
else
    # (3) A relative CLAUDE_PROJECT_DIR is refused.
    out="$(run_crun CLAUDE_EXEC="${real}" CLAUDE_PROJECT_DIR=relative/dir)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'must be an absolute path' <<<"${out}"; then
        pass "claude-run refuses a relative CLAUDE_PROJECT_DIR"
    else
        fail "relative CLAUDE_PROJECT_DIR not refused (rc=${rc}): ${out}"
    fi

    # (4) A non-existent CLAUDE_PROJECT_DIR is refused.
    out="$(run_crun CLAUDE_EXEC="${real}" CLAUDE_PROJECT_DIR=/nonexistent/ai-tools-test-xyz)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not an existing directory' <<<"${out}"; then
        pass "claude-run refuses a non-existent CLAUDE_PROJECT_DIR"
    else
        fail "non-existent CLAUDE_PROJECT_DIR not refused (rc=${rc}): ${out}"
    fi
fi

finish

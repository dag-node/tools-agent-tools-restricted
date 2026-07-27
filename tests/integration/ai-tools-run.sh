#!/usr/bin/env bash
# tests/integration/ai-tools-run.sh
# Integration: ai-tools-run re-validates its whole wrapper contract before launching a session --
# defense in depth, so a tampered env_keep value that survived sudo cannot redirect execution to
# an arbitrary binary or start the agent in the wrong directory (the wrapper is not a single
# point of trust). Drives the deployed shim AS the agent with crafted env and asserts it refuses
# at validation, BEFORE systemd-run.
#
# The executable is accepted only at an exact semver version directory inside the sandbox's own
# Node toolchain AND only when its launcher belongs to an ENABLED agent manifest -- an allowlist
# built from root-owned data, so an executable no manifest claims cannot start a session even
# when it sits in the toolchain. Both halves are asserted here.
#
# Every case carries an invalid input so the shim always exits early and never spawns a session;
# a timeout backstops that. Run as root.
#
# The SELinux fail-closed launch refusal (a mislabelled entrypoint under enforcing) is NOT
# exercised here: the gate keys on matchpathcon of the real /opt/ai-tools/.nvm path, so any
# end-to-end check must write a deliberately mislabelled file into the production toolchain tree,
# which this suite runs against on enforcing hosts -- an interrupted run could leave that leftover
# behind. The pure decision is covered hermetically in tests/unit/confinement.sh instead.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly CRUN="/opt/ai-tools/bin/ai-tools-run"
section "ai-tools-run: AI_TOOLS_AGENT_EXEC / AI_TOOLS_PROJECT_DIR re-validation (integration)"

if [[ ! -x "${CRUN}" ]]; then
    skip "ai-tools-run revalidation" "not installed at ${CRUN}"; finish; exit
fi
if ! command -v runuser >/dev/null 2>&1; then
    skip "ai-tools-run revalidation" "runuser unavailable"; finish; exit
fi

# Run ai-tools-run AS the agent with a clean, explicitly-set AI_TOOLS_AGENT_EXEC/AI_TOOLS_PROJECT_DIR
# (env -u clears any inherited value first, so the case is deterministic). timeout backstops
# the design guarantee that every case below exits at validation, never reaching the launch.
run_crun() {  # VAR=VAL ...
    timeout 10 runuser -u "${SANDBOX_USER}" -- \
        env -u AI_TOOLS_AGENT_EXEC -u AI_TOOLS_PROJECT_DIR "$@" "${CRUN}" < /dev/null 2>&1
}

# (1) A AI_TOOLS_AGENT_EXEC outside the versioned-claude shape is refused.
out="$(run_crun AI_TOOLS_AGENT_EXEC=/bin/sh)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]] && grep -qi 'invalid or absent AI_TOOLS_AGENT_EXEC' <<<"${out}"; then
    pass "ai-tools-run refuses a AI_TOOLS_AGENT_EXEC outside the versioned-claude path"
else
    fail "non-versioned AI_TOOLS_AGENT_EXEC not refused (rc=${rc}): ${out}"
fi

# (2) A correctly-shaped AI_TOOLS_AGENT_EXEC carrying '/../' is refused by the traversal guard.
out="$(run_crun AI_TOOLS_AGENT_EXEC=/opt/ai-tools/.nvm/versions/node/v1.2.3/../bin/claude)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]] && grep -qi 'parent-directory references' <<<"${out}"; then
    pass "ai-tools-run refuses a AI_TOOLS_AGENT_EXEC with parent-directory references"
else
    fail "AI_TOOLS_AGENT_EXEC with /../ not refused (rc=${rc}): ${out}"
fi

# (3)/(4) With a VALID AI_TOOLS_AGENT_EXEC, a bad AI_TOOLS_PROJECT_DIR is refused before launch. Needs
# the real versioned target (so AI_TOOLS_AGENT_EXEC passes); skip if it cannot be resolved.
real="$(readlink -- /opt/ai-tools/bin/claude 2>/dev/null || true)"
if [[ -z "${real}" || "${real}" != /opt/ai-tools/.nvm/versions/node/*/bin/claude ]]; then
    skip "ai-tools-run project-dir revalidation" "cannot resolve a valid AI_TOOLS_AGENT_EXEC target"
else
    # (3) A relative AI_TOOLS_PROJECT_DIR is refused.
    out="$(run_crun AI_TOOLS_AGENT_EXEC="${real}" AI_TOOLS_PROJECT_DIR=relative/dir)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'must be an absolute path' <<<"${out}"; then
        pass "ai-tools-run refuses a relative AI_TOOLS_PROJECT_DIR"
    else
        fail "relative AI_TOOLS_PROJECT_DIR not refused (rc=${rc}): ${out}"
    fi

    # (4) A non-existent AI_TOOLS_PROJECT_DIR is refused.
    out="$(run_crun AI_TOOLS_AGENT_EXEC="${real}" AI_TOOLS_PROJECT_DIR=/nonexistent/ai-tools-test-xyz)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'not an existing directory' <<<"${out}"; then
        pass "ai-tools-run refuses a non-existent AI_TOOLS_PROJECT_DIR"
    else
        fail "non-existent AI_TOOLS_PROJECT_DIR not refused (rc=${rc}): ${out}"
    fi

    # (5) A real, executable binary sitting in the SAME versioned bin directory is refused
    # because no enabled agent manifest claims that launcher. This is the agent allowlist doing
    # the work the old hardcoded path pattern used to: without it, anything the sandbox account
    # can drop beside the launcher would start a confined session under the sudo grant.
    node_bin="${real%/*}/node"
    if [[ ! -x "${node_bin}" ]]; then
        skip "ai-tools-run unclaimed-launcher refusal" "no sibling binary to probe at ${node_bin}"
    else
        out="$(run_crun AI_TOOLS_AGENT_EXEC="${node_bin}")" && rc=0 || rc=$?
        if [[ ${rc} -ne 0 ]] && grep -qi 'no enabled agent provides the launcher' <<<"${out}"; then
            pass "ai-tools-run refuses a launcher no enabled agent manifest claims"
        else
            fail "unclaimed launcher not refused (rc=${rc}): ${out}"
        fi
    fi

    # (6) The version component must be an exact semver directory, not any directory name.
    out="$(run_crun AI_TOOLS_AGENT_EXEC=/opt/ai-tools/.nvm/versions/node/evil/bin/claude)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'invalid or absent AI_TOOLS_AGENT_EXEC' <<<"${out}"; then
        pass "ai-tools-run refuses a non-semver version directory"
    else
        fail "non-semver version directory not refused (rc=${rc}): ${out}"
    fi
fi

finish

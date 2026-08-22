#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/ai-tools-run.sh
# Integration: the session's confinement properties, the agent's session env, and ai-tools-run's
# re-validation of its whole wrapper contract -- every guarantee the shim itself makes, in the
# file beside it.
#
# Re-validation is defense in depth:
# a tampered env_keep value that survived sudo cannot redirect execution to an arbitrary binary
# or start the agent in the wrong directory (the wrapper is not a single point of trust). Those
# cases drive the deployed shim AS the agent with crafted env and assert it refuses at validation,
# BEFORE systemd-run.
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
section "ai-tools-run: session confinement properties + agent session env"

if [[ ! -x "${CRUN}" ]]; then
    skip "ai-tools-run" "not installed at ${CRUN}"; finish; exit
fi

# The claude-code session env. These pins are agent-specific, so they live in that agent's
# session-env fragment rather than in the agent-agnostic shim; ai-tools-run sources it last,
# after every enabled integration, so nothing can override them. Each one is load-bearing:
#   DISABLE_AUTOUPDATER  the node tree is read-only to the agent, so the in-session auto-updater
#                        would fail every launch (+ AVC); updates are the timer's job
#   CLAUDE_CONFIG_DIR    unpinned, the state file lands under the 2751 home root where the agent
#                        cannot create it, and every session demands a fresh login
#   NODE_COMPILE_CACHE   unpinned, the cache lands on the shared /tmp where a stale user_tmp_t
#                        entry denies node's own open() and the session dies at startup
# The fragment is SOURCED into the two arrays it is contracted to append to, rather than grepped
# for strings: that exercises the real contract, so a fragment that stops appending -- or appends
# to a renamed array -- fails here instead of silently costing the session its environment.
agent_env="/usr/local/lib/ai-tools/session-env.d/claude-code.env.sh"
if [[ ! -r "${agent_env}" ]]; then
    skip "claude-code session env" "${agent_env} unreadable"
else
    agent_setenv="$(
        declare -a session_environment_options=() session_path_entries=()
        # shellcheck source=/dev/null
        source "${agent_env}" 2>/dev/null || true
        printf '%s\n' "${session_environment_options[@]:-}"
    )"
    for pin in DISABLE_AUTOUPDATER=1 \
               CLAUDE_CONFIG_DIR=/opt/ai-tools/.claude \
               NODE_COMPILE_CACHE=/opt/ai-tools/.cache/node-compile-cache; do
        if grep -qxF -- "--setenv=${pin}" <<<"${agent_setenv}"; then
            pass "claude-code session env pins ${pin}"
        else
            fail "claude-code session env does not pin ${pin} (${agent_env})"
        fi
    done
fi

# ai-tools-run pins the session's kernel-confinement properties on the transient unit:
# RestrictNamespaces=yes (the seccomp filter that blocks clone(CLONE_NEWUSER) and forces
# PR_SET_NO_NEW_PRIVS) and NoNewPrivileges=yes. These are trust-chain step 4; a revert here would
# launch sessions without namespace isolation or with SUID escalation reachable, and the only
# other signal is an on-box AVC. Pin them statically alongside DISABLE_AUTOUPDATER (the sibling
# self-update pin above) so a regression fails the suite, not just enforcing bring-up. The
# properties reach systemd-run as `--property=NAME=yes`.
for prop in RestrictNamespaces NoNewPrivileges; do
    if grep -qE -- "--property=${prop}=yes" "${CRUN}"; then
        pass "ai-tools-run pins ${prop}=yes on the session unit"
    else
        fail "ai-tools-run does not pin ${prop}=yes -- session confinement (trust-chain step 4) weakened"
    fi
done
# UMask=0007 keeps agent-written files 660/770 (world stripped, operator+agent co-writers).
if grep -qE -- '--property=UMask=0007' "${CRUN}"; then
    pass "ai-tools-run pins UMask=0007 on the session unit"
else
    fail "ai-tools-run does not pin UMask=0007 -- agent files may be born world-accessible"
fi

# Ownership handback needs exactly one driver. The shim sweeps the project at session end for
# every agent EXCEPT one whose manifest declares handback=hooks, and the deployed claude-code
# manifest must be that one: its own PostToolUse/Stop hooks already converge the tree per turn,
# so a lost declaration would add a full-tree walk to the end of every Claude session. Read
# through the resolver, the same accessor the shim uses.
agent_manifest="/usr/local/lib/ai-tools/agents.d/claude-code.conf"
providers_lib="/usr/local/lib/ai-tools/providers.lib.sh"
# shellcheck source=/dev/null
if [[ ! -r "${agent_manifest}" ]] || ! source "${providers_lib}" 2>/dev/null \
        || ! declare -F ai_tools_agent_sweeps_at_exit >/dev/null 2>&1; then
    skip "claude-code handback declaration" "manifest or provider resolver not deployed"
elif ai_tools_agent_sweeps_at_exit "$(ai_tools_agent_manifest_field claude-code handback || true)"; then
    fail "claude-code does not declare handback=hooks (${agent_manifest}) -- every session would end with a redundant full-tree sweep"
else
    pass "claude-code declares handback=hooks, so the shim adds no session-end sweep"
fi

section "ai-tools-run: AI_TOOLS_AGENT_EXEC / AI_TOOLS_PROJECT_DIR re-validation"

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

    # (7) Containment across the symlink. Shape validation matches the launcher PATH; what execve
    # transitions on is what that path RESOLVES to, and a string match cannot follow a link. A
    # launcher that is correctly shaped and claimed by an enabled manifest, but whose target lands
    # outside its own version directory, must be refused -- otherwise a repointed link starts a
    # session on a binary the toolchain never installed.
    #
    # Probed in a THROWAWAY version directory (v0.0.1), never the live one: the shim only needs the
    # path to be semver-shaped, and writing into the active tree is what this file's header rules
    # out. Removed on exit whichever way this test ends.
    fake_version_dir="/opt/ai-tools/.nvm/versions/node/v0.0.1"
    if [[ -e "${fake_version_dir}" ]]; then
        skip "ai-tools-run entrypoint containment" "${fake_version_dir} already exists -- not overwriting"
    else
        _cleanup+=("${fake_version_dir}")
        mkdir -p "${fake_version_dir}/bin"
        # Escapes the version root: a real, executable target the shim must still refuse.
        ln -sfn /bin/sh "${fake_version_dir}/bin/claude"
        chown -R "${SANDBOX_USER}" "${fake_version_dir}" 2>/dev/null || true
        out="$(run_crun AI_TOOLS_AGENT_EXEC="${fake_version_dir}/bin/claude")" && rc=0 || rc=$?
        if [[ ${rc} -ne 0 ]] && grep -qi 'does not resolve to an executable inside' <<<"${out}"; then
            pass "ai-tools-run refuses a launcher resolving outside its own version directory"
        else
            fail "escaping launcher symlink not refused (rc=${rc}): ${out}"
        fi
        rm -rf "${fake_version_dir}"
    fi
fi

section "ai-tools-run: the verified entrypoint is the one exec'd"

# The shim checks the RESOLVED entrypoint (label preflight, and the re-check below) and must hand
# systemd that same path. Naming the launcher symlink in ExecStart instead would leave the manager
# re-resolving it after every check has run, so a repoint in that window would go unobserved on a
# DAC-only host. Asserted against the deployed script, the same way the unit properties above are.
if grep -qE -- '-- "\$\{session_exec_path\}" "\$@"' "${CRUN}"; then
    pass "ai-tools-run execs the resolved entrypoint, not the launcher symlink"
else
    fail "ai-tools-run does not ExecStart \${session_exec_path} -- the file checked is not the file exec'd"
fi

# The re-check must sit AFTER the session-env fragments, not with the earlier validation -- its
# whole value is the width of the window it leaves (launch.rule.md). Asserted by line order,
# because nothing about the code's behaviour reveals where it runs.
crun_recheck_line="$(grep -n 'entrypoint_identity' "${CRUN}" | tail -n1 | cut -d: -f1)"
crun_launch_line="$(grep -n '^systemd-run --user --pty --quiet' "${CRUN}" | head -n1 | cut -d: -f1)"
if [[ -z "${crun_recheck_line}" || -z "${crun_launch_line}" ]]; then
    fail "ai-tools-run has no last-moment entrypoint re-check before systemd-run"
elif (( crun_recheck_line < crun_launch_line )) && (( crun_launch_line - crun_recheck_line < 20 )); then
    pass "ai-tools-run re-checks the entrypoint identity immediately before the launch"
else
    fail "the entrypoint re-check is not immediately before systemd-run (re-check line ${crun_recheck_line}, launch line ${crun_launch_line}) -- the window it narrows is back"
fi

finish

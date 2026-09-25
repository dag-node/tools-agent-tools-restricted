#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/ai-tools-run.sh
# Integration: the session's confinement properties, the agent's session env, and ai-tools-run's re-validation of its
# whole wrapper contract -- every guarantee the shim itself makes, in the file beside it.
#
# Re-validation is defense in depth: a tampered env_keep value that survived sudo cannot redirect execution
# to an arbitrary binary or start the agent in the wrong directory (the wrapper is not a single point of trust). Those
# cases drive the deployed shim AS the agent with crafted env and assert it refuses at validation, BEFORE systemd-run.
#
# The executable is accepted only at an exact semver version directory inside the sandbox's own Node toolchain AND only
# when its launcher belongs to an ENABLED agent manifest -- an allowlist built from root-owned data, so an executable no
# manifest claims cannot start a session even when it sits in the toolchain. Both halves are asserted here.
#
# Every case carries an invalid input so the shim always exits early and never spawns a session; a timeout backstops
# that. Run as root.
#
# The SELinux fail-closed launch refusal (a mislabelled entrypoint under enforcing) is NOT exercised here: the gate keys
# on matchpathcon of the real /opt/ai-tools/.nvm path, so any end-to-end check must write a deliberately mislabelled
# file into the production toolchain tree, which this suite runs against on enforcing hosts -- an interrupted run could
# leave that leftover behind. The pure decision is covered hermetically in tests/unit/confinement.sh instead.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly CRUN="/opt/ai-tools/bin/ai-tools-run"
section "ai-tools-run: session confinement properties + agent session env"

if [[ ! -x "${CRUN}" ]]; then
    skip "ai-tools-run" "not installed at ${CRUN}"; finish; exit
fi

# Every enabled agent's session pins. An agent's pins are agent-specific, so they live in that agent's
# session-env.d/<name>.pins.env.sh, and the agent-agnostic shim sources EVERY enabled agent's pins into every session --
# after the integrations, so no integration overrides them, and before the launching agent's own fragment -- so an agent
# entrypoint started from inside another agent's session finds its state directory (launch.rule.md). The deployed files
# are read through the deployed resolver, so this does not name an agent: each enabled agent must ship a pins file
# that passes the trust predicate the shim applies, and each is SOURCED into the two arrays it is contracted to append
# to rather than grepped for strings, so a pins file that stops appending -- or appends to a renamed array -- fails here
# instead of silently costing every session that agent's environment. What a pin may be is the allowlist
# unit/session-env.sh holds every shipped pins file to; here the deployed set is held to its shape alone:
# `--setenv=NAME=value` lines, no name-only import and no PATH tail.
session_env_dir="/usr/local/lib/ai-tools/session-env.d"
# source_session_env <file>: print what sourcing <file> appends, one array entry per line, PATH entries prefixed.
source_session_env() {
    (
        declare -a session_environment_options=() session_path_entries=()
        # shellcheck source=/dev/null
        source "$1" 2>/dev/null || true
        printf '%s\n' "${session_environment_options[@]+"${session_environment_options[@]}"}"
        printf 'PATH:%s\n' "${session_path_entries[@]+"${session_path_entries[@]}"}"
    )
}
# shellcheck source=/dev/null
if ! source /usr/local/lib/ai-tools/conf.lib.sh 2>/dev/null \
        || ! source /usr/local/lib/ai-tools/providers.lib.sh 2>/dev/null \
        || ! declare -F ai_tools_enabled_agents >/dev/null 2>&1; then
    skip "session pins" "the provider resolver is not deployed"
else
    enabled_agent_names="$(ai_tools_enabled_agents 2>/dev/null | cut -f1)"
    [[ -n "${enabled_agent_names}" ]] || skip "session pins" "no agent is enabled on this host"
    while IFS= read -r enabled_agent; do
        [[ -n "${enabled_agent}" ]] || continue
        pins="${session_env_dir}/${enabled_agent}.pins.env.sh"
        if [[ ! -r "${pins}" ]]; then
            fail "enabled agent ${enabled_agent} ships no session pins at ${pins} -- a child of it started inside another agent's session runs without its state directory"
            continue
        fi
        if ai_tools_conf_is_trusted "${pins}"; then
            pass "${enabled_agent}'s session pins pass the trust predicate the shim applies"
        else
            fail "${enabled_agent}'s session pins would be skipped by the shim: ${pins} $(ai_tools_conf_untrusted_reason "${pins}")"
        fi
        pins_out="$(source_session_env "${pins}")"
        if [[ "$(grep -c '^--setenv=[A-Z][A-Z0-9_]*=.' <<<"${pins_out}")" -gt 0 ]] \
                && ! grep -qvE '^(--setenv=[A-Z][A-Z0-9_]*=.|PATH:$)' <<<"${pins_out}"; then
            pass "${enabled_agent}'s session pins append --setenv=NAME=value lines alone: $(grep '^--setenv' <<<"${pins_out}" | sed 's/^--setenv=//; s/=.*//' | tr '\n' ' ')"
        else
            fail "${enabled_agent}'s session pins append something other than --setenv=NAME=value lines: $(tr '\n' '|' <<<"${pins_out}")"
        fi
    done <<<"${enabled_agent_names}"
fi

# The claude-code pins by name -- each one is load-bearing and its loss is silent until a session dies or demands
# a fresh login -- and the claude-code fragment asserted to carry none of them: the fragment reaches claude-code
# sessions alone (the custom endpoint's token is in it), so a pin that slid back into it would be missing from every
# other agent's session while still passing a read of the pins file.
#   DISABLE_AUTOUPDATER  the node tree is read-only to the agent, so the in-session auto-updater
#                        would fail every launch (+ AVC); updates are the timer's job
#   CLAUDE_CONFIG_DIR    unpinned, the state file lands under the 2751 home root where the agent
#                        cannot create it, and every session demands a fresh login
#   NODE_COMPILE_CACHE   unpinned, the cache lands on the shared /tmp where a stale user_tmp_t
#                        entry denies node's own open() and the session dies at startup
claude_pins="${session_env_dir}/claude-code.pins.env.sh"
claude_fragment="${session_env_dir}/claude-code.env.sh"
if [[ ! -r "${claude_pins}" || ! -r "${claude_fragment}" ]]; then
    skip "claude-code session pins" "${claude_pins} or ${claude_fragment} unreadable"
else
    claude_pins_out="$(source_session_env "${claude_pins}")"
    claude_fragment_out="$(source_session_env "${claude_fragment}")"
    for pin in DISABLE_AUTOUPDATER=1 \
               CLAUDE_CONFIG_DIR=/opt/ai-tools/.claude \
               NODE_COMPILE_CACHE=/opt/ai-tools/.cache/node-compile-cache; do
        if grep -qxF -- "--setenv=${pin}" <<<"${claude_pins_out}"; then
            pass "claude-code's session pins carry ${pin}"
        else
            fail "claude-code's session pins do not carry ${pin} (${claude_pins})"
        fi
        if grep -q -- "--setenv=${pin%%=*}=" <<<"${claude_fragment_out}"; then
            fail "claude-code's fragment carries ${pin%%=*}, which reaches claude-code sessions alone -- it belongs in ${claude_pins}"
        else
            pass "claude-code's fragment leaves ${pin%%=*} to the pins"
        fi
    done
fi

# The shim's order, read as source: the integrations' fragments, then every enabled agent's pins, then the launching
# agent's fragment. No refusal the shim can be driven to reveals the order (the one gate past the fragments needs
# a valid launch), so the three calls are held to their line order, the way the entrypoint re-check is.
crun_integrations_line="$(grep -n 'ai_tools_enabled_integrations' "${CRUN}" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016  # grep patterns over the shim's own text
crun_pins_line="$(grep -n 'source_session_env_fragment "\${enabled_agent_name}" pins' "${CRUN}" | head -n1 | cut -d: -f1)"
crun_agent_line="$(grep -n '^    source_session_env_fragment "\${agent_name}"$' "${CRUN}" | head -n1 | cut -d: -f1)"
if [[ -z "${crun_integrations_line}" || -z "${crun_pins_line}" || -z "${crun_agent_line}" ]]; then
    fail "ai-tools-run does not source the integrations, every enabled agent's pins, and the launching agent's fragment (integrations '${crun_integrations_line}', pins '${crun_pins_line}', agent '${crun_agent_line}')"
elif (( crun_integrations_line < crun_pins_line && crun_pins_line < crun_agent_line )); then
    pass "ai-tools-run sources the integrations, then every enabled agent's pins, then the launching agent's fragment"
else
    fail "ai-tools-run sources the session env out of order (integrations line ${crun_integrations_line}, pins line ${crun_pins_line}, agent line ${crun_agent_line})"
fi

# ai-tools-run pins the session's kernel-confinement properties on the transient unit:
# RestrictNamespaces=yes (the seccomp filter that blocks clone(CLONE_NEWUSER) and forces
# PR_SET_NO_NEW_PRIVS) and NoNewPrivileges=yes. These are trust-chain step 4; a revert here would launch sessions
# without namespace isolation or with SUID escalation reachable, and the only other signal is an on-box AVC. Pin them
# statically alongside DISABLE_AUTOUPDATER (the sibling self-update pin) so a regression fails the suite, not just
# enforcing bring-up. The properties reach systemd-run as `--property=NAME=yes`.
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
# The shim turns systemd-run's background tint off on the invocation itself (launch.rule.md); asserted on the line
# before the command, where sudo's reset environment cannot supply it.
if grep -qE -- '^SYSTEMD_TINT_BACKGROUND=0 \\$' "${CRUN}"; then
    pass "ai-tools-run turns systemd-run's terminal tint off"
else
    fail "ai-tools-run does not set SYSTEMD_TINT_BACKGROUND=0 on systemd-run -- the tint and its terminal query are back"
fi

# Ownership handback needs exactly one driver. The shim sweeps the project at session end for every agent EXCEPT one
# whose manifest declares handback=hooks, and the deployed claude-code manifest must be that one: its own
# PostToolUse/Stop hooks already converge the tree per turn, so a lost declaration would add a full-tree walk to the end
# of every Claude session. Read through the resolver, the same accessor the shim uses.
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

# Run ai-tools-run AS the agent with a clean, explicitly-set AI_TOOLS_AGENT_EXEC/AI_TOOLS_PROJECT_DIR (`env -u` clears
# any inherited value first, so the case is deterministic). timeout backstops the design guarantee that every case exits
# at validation, never reaching the launch.
run_crun() {  # VAR=VAL ...
    timeout 10 runuser -u "${SANDBOX_USER}" -- \
        env -u AI_TOOLS_AGENT_EXEC -u AI_TOOLS_PROJECT_DIR "$@" "${CRUN}" < /dev/null 2>&1
}

# refused <label> <code> <rc> <output>: the shim must exit non-zero AND name the situation with <code>. The exit status
# is asserted beside the code because a run that printed the refusal and still returned 0 would have gone on to launch
# the session. The label comes FIRST so the code sits in a later argument, which the reference index reads as a citation
# rather than as a second definition of it (messaging.rule.md).
refused() {
    local label="$1" code="$2" rc="$3" out="$4"
    if (( rc == 0 )); then
        fail "${label}: the shim exited 0 where it must refuse: ${out}"
    else
        assert_msg "${code}" "${out}" "${label}"
    fi
}

# (1) A AI_TOOLS_AGENT_EXEC outside the versioned-claude shape is refused.
out="$(run_crun AI_TOOLS_AGENT_EXEC=/bin/sh)" && rc=0 || rc=$?
refused "ai-tools-run refuses a AI_TOOLS_AGENT_EXEC outside the versioned-claude path" MSG-Z2J9 "${rc}" "${out}"

# (2) A correctly-shaped AI_TOOLS_AGENT_EXEC carrying '/../' is refused by the traversal guard.
out="$(run_crun AI_TOOLS_AGENT_EXEC=/opt/ai-tools/.nvm/versions/node/v1.2.3/../bin/claude)" && rc=0 || rc=$?
# By code: the traversal refusal must be the executable's, not the project directory's.
refused "ai-tools-run refuses a AI_TOOLS_AGENT_EXEC with parent-directory references" MSG-N4P3 "${rc}" "${out}"

# (3)/(4) With a VALID AI_TOOLS_AGENT_EXEC, a bad AI_TOOLS_PROJECT_DIR is refused before launch. Needs the real
# versioned target (so AI_TOOLS_AGENT_EXEC passes); skip if it cannot be resolved.
real="$(readlink -- /opt/ai-tools/bin/claude 2>/dev/null || true)"
if [[ -z "${real}" || "${real}" != /opt/ai-tools/.nvm/versions/node/*/bin/claude ]]; then
    skip "ai-tools-run project-dir revalidation" "cannot resolve a valid AI_TOOLS_AGENT_EXEC target"
else
    # (3) A relative AI_TOOLS_PROJECT_DIR is refused.
    out="$(run_crun AI_TOOLS_AGENT_EXEC="${real}" AI_TOOLS_PROJECT_DIR=relative/dir)" && rc=0 || rc=$?
    refused "ai-tools-run refuses a relative AI_TOOLS_PROJECT_DIR" MSG-D2A4 "${rc}" "${out}"

    # (4) A non-existent AI_TOOLS_PROJECT_DIR is refused.
    out="$(run_crun AI_TOOLS_AGENT_EXEC="${real}" AI_TOOLS_PROJECT_DIR=/nonexistent/ai-tools-test-xyz)" && rc=0 || rc=$?
    refused "ai-tools-run refuses a non-existent AI_TOOLS_PROJECT_DIR" MSG-F8V8 "${rc}" "${out}"

    # (5) A real, executable binary sitting in the SAME versioned bin directory is refused because no enabled agent
    # manifest claims that launcher. The manifest allowlist is what carries that: a path-shape check alone admits
    # anything the sandbox account can drop beside the launcher, which would start a confined session under the sudo
    # grant.
    node_bin="${real%/*}/node"
    if [[ ! -x "${node_bin}" ]]; then
        skip "ai-tools-run unclaimed-launcher refusal" "no sibling binary to probe at ${node_bin}"
    else
        out="$(run_crun AI_TOOLS_AGENT_EXEC="${node_bin}")" && rc=0 || rc=$?
        refused "ai-tools-run refuses a launcher no enabled agent manifest claims" MSG-A3H6 "${rc}" "${out}"
    fi

    # (6) The version component must be an exact semver directory, not any directory name.
    out="$(run_crun AI_TOOLS_AGENT_EXEC=/opt/ai-tools/.nvm/versions/node/evil/bin/claude)" && rc=0 || rc=$?
    refused "ai-tools-run refuses a non-semver version directory (the same shape refusal)" MSG-Z2J9 "${rc}" "${out}"

    # (7) Containment across the symlink. Shape validation matches the launcher PATH; what execve transitions on is
    # what that path RESOLVES to, and a string match cannot follow a link. A launcher that is correctly shaped
    # and claimed by an enabled manifest, but whose target lands outside its own version directory, must be refused --
    # otherwise a repointed link starts a session on a binary the toolchain never installed.
    #
    # Probed in a THROWAWAY version directory (v0.0.1), never the live one: the shim only needs the path to be
    # semver-shaped, and writing into the active tree is what this file's header rules out. Removed on exit whichever
    # way this test ends.
    #
    # This is the one fixture that cannot carry the harness's `.ai-tools-test-*` name: the shim accepts an entrypoint
    # only at a bare `v<major>.<minor>.<patch>` directory, so the residue sweep (tests/lib/residue.sh) lists this exact
    # path by name instead. Node shipped no such version, so only this test creates it -- which is why one already
    # present is a FAILURE (a teardown that did not run, on a host the sweep has not cleaned) and not a case to skip:
    # skipping would let residue silently cost the coverage.
    fake_version_dir="/opt/ai-tools/.nvm/versions/node/v0.0.1"
    if [[ -e "${fake_version_dir}" ]]; then
        fail "${fake_version_dir} already exists -- residue of an earlier run; run \`tests/run.sh residue\` (the sweep removes it) and rerun"
    else
        _cleanup+=("${fake_version_dir}")
        mkdir -p "${fake_version_dir}/bin"
        # Escapes the version root: a real, executable target the shim must still refuse.
        ln -sfn /bin/sh "${fake_version_dir}/bin/claude"
        chown -R "${SANDBOX_USER}" "${fake_version_dir}" 2>/dev/null || true
        out="$(run_crun AI_TOOLS_AGENT_EXEC="${fake_version_dir}/bin/claude")" && rc=0 || rc=$?
        refused "ai-tools-run refuses a launcher resolving outside its own version directory" MSG-D7A7 "${rc}" "${out}"
        rm -rf "${fake_version_dir}"
    fi

    # (8) The entrypoint pin. This is the feature's actual security guarantee -- a binary that does not match
    # the checksum its vendor signed must not start a session -- and it is the last gate the shim runs, so reaching it
    # needs a VALID executable: every earlier case exits before here.
    #
    # Driven against a THROWAWAY pin directory (AI_TOOLS_ENTRYPOINT_PIN_DIR, a root-only test hook like
    # AI_TOOLS_ALLOWLIST: sudo strips it and the handback daemon execs with its own environment, so only a root caller
    # that sets it and execs the shim directly can redirect it). The production pin is never read, written,
    # or invalidated -- which matters more here than elsewhere, since corrupting the real one would refuse every launch
    # on this host. mktemp, not a fixed name under /tmp: this runs as root in a world-writable directory,
    # where a predictable path is one another user can pre-create or symlink. 0755 because the shim reads the pin
    # AS the sandbox account, which must traverse in.
    pin_dir="$(mktemp -d)"
    _cleanup+=("${pin_dir}")
    chmod 0755 "${pin_dir}"
    # A well-formed pin for a checksum this entrypoint cannot have: the shape is valid, so the refusal comes
    # from the COMPARISON rather than from the reader rejecting a malformed record.
    printf 'AGENT=claude-code\nVERSION=0.0.0\nSHA256=%064d\nVERIFIED=1970-01-01T00:00:00Z\n' 0 \
        > "${pin_dir}/claude-code"
    chmod 0644 "${pin_dir}/claude-code"
    out="$(run_crun AI_TOOLS_AGENT_EXEC="${real}" AI_TOOLS_ENTRYPOINT_PIN_DIR="${pin_dir}")" && rc=0 || rc=$?
    refused "ai-tools-run refuses an entrypoint that does not match its pin" MSG-H7S2 "${rc}" "${out}"

    # The same refusal against an OBSERVED pin. The tier decides what the pin CLAIMS, never whether a mismatch refuses:
    # a host whose agent has no vendor manifest is covered against a change to its binary, which is the whole reason
    # the weaker tier is worth writing. The pin this case starts from carries no KIND (the shape every pin had
    # before the tier existed), so this case is the one that would regress if the launch gate ever started reading
    # the tier.
    printf 'AGENT=claude-code\nVERSION=0.0.0\nSHA256=%064d\nKIND=observed\nVERIFIED=1970-01-01T00:00:00Z\n' 0 \
        > "${pin_dir}/claude-code"
    out="$(run_crun AI_TOOLS_AGENT_EXEC="${real}" AI_TOOLS_ENTRYPOINT_PIN_DIR="${pin_dir}")" && rc=0 || rc=$?
    refused "ai-tools-run refuses a mismatch against an observed pin too" MSG-H7S2 "${rc}" "${out}"
    # And the refusal names the tier it read, so an operator is not sent looking for a vendor signature behind a pin
    # root recorded by hashing what was installed.
    if grep -q 'root recorded' <<<"${out}"; then
        pass "the refusal names the observed tier's claim rather than a vendor signature"
    else
        fail "the refusal over an observed pin still claims a vendor signed the checksum: ${out}"
    fi

    # The complementary property -- an UNPINNED entrypoint must NOT be refused, or an air-gapped host would stop
    # launching -- is deliberately NOT driven here. No other part of that run is invalid, so the shim would go
    # on to start a real session, which this file's design forbids. It is covered where it does not cost a session:
    # the pure verdict returns `unpinned` rather than `mismatch` (tests/unit/entrypoint-verify.sh), and only `mismatch`
    # reaches the refusal.
fi

section "ai-tools-run: a disabled agent's package in the toolchain refuses every launch"

# The shim reads the tree itself (toolchain.lib.sh) for the package of an agent that is installed and not enabled,
# and refuses before it validates the executable, under the code the wrapper defines for the same situation. Driven
# with a fixture manifest directory -- the deployed manifests copied beside one synthetic agent no operator.conf names,
# read through the root-only AI_TOOLS_AGENTS_DIR hook -- and that agent's package planted in the throwaway v0.0.1
# version directory the containment case (7) uses and removes (the residue sweep lists it by name). The control runs
# the same command with the package gone and asserts the NEXT refusal, so a refusal that never read the tree cannot pass
# as this one.
if [[ -e "${fake_version_dir:-/opt/ai-tools/.nvm/versions/node/v0.0.1}" ]]; then
    fail "/opt/ai-tools/.nvm/versions/node/v0.0.1 already exists -- residue of an earlier case; run \`tests/run.sh residue\` and rerun"
else
    mktestdir
    residue_agents="${TESTDIR}/agents.d"
    mkdir -m 0755 "${residue_agents}"
    cp /usr/local/lib/ai-tools/agents.d/*.conf "${residue_agents}/" 2>/dev/null || true
    # A plain basename, not the harness's fixture name: the manifest lives in the testdir, and the resolver's `*.conf`
    # glob does not match a dotfile.
    residue_agent="residue-agent"
    residue_package="@ai-tools-test/${residue_agent}"
    printf 'npm_package=%s\nlauncher=%s\ndefault_enable=no\n' "${residue_package}" "${residue_agent}" \
        > "${residue_agents}/${residue_agent}.conf"
    chmod 0644 "${residue_agents}"/*.conf
    residue_version_dir="/opt/ai-tools/.nvm/versions/node/v0.0.1"
    _cleanup+=("${residue_version_dir}")
    mkdir -p "${residue_version_dir}/lib/node_modules/${residue_package}"
    chown -R "${SANDBOX_USER}" "${residue_version_dir}" 2>/dev/null || true
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    read_back="$(env AI_TOOLS_AGENTS_DIR="${residue_agents}" bash -c \
        'source /usr/local/lib/ai-tools/providers.lib.sh && ai_tools_installed_agents' 2>/dev/null | cut -f1 | grep -cx "${residue_agent}" || true)"
    if [[ "${read_back}" != 1 ]]; then
        fail "the fixture manifest does not read back through the resolver, so the residue case cannot be driven"
    else
        out="$(run_crun AI_TOOLS_AGENTS_DIR="${residue_agents}" AI_TOOLS_AGENT_EXEC=/bin/sh)" && rc=0 || rc=$?
        refused "ai-tools-run refuses every launch while a disabled agent's package is in the toolchain" MSG-H4E2 "${rc}" "${out}"
        if grep -q "${residue_agent}" <<<"${out}" && grep -q 'system bootstrap' <<<"${out}"; then
            pass "the refusal names the agent and the provisioning run that removes its package"
        else
            fail "the refusal does not name the agent and the bootstrap command: $(head -c 300 <<<"${out}" | tr '\n' '|')"
        fi
        rm -rf "${residue_version_dir}"
        out="$(run_crun AI_TOOLS_AGENTS_DIR="${residue_agents}" AI_TOOLS_AGENT_EXEC=/bin/sh)" && rc=0 || rc=$?
        refused "with the package gone the same launch reaches the executable check instead" MSG-Z2J9 "${rc}" "${out}"
    fi
    rm -rf "${residue_version_dir}"
fi

section "ai-tools-run: a provider name written without its kind prefix refuses every launch"

# The list reader reads a list holding a bare name as empty, so the shim refuses on the item itself, under the code
# the wrapper defines, before it resolves the enabled agents. Driven with a fixture operator.conf through the root-only
# AI_TOOLS_OPERATOR_CONF hook; the control names this host's enabled agents with the prefix and asserts the NEXT
# refusal, so a refusal that never read the lists cannot pass as this one.
[[ -n "${TESTDIR:-}" ]] || mktestdir
lists_conf="${TESTDIR}/lists-operator.conf"
printf 'AI_TOOLS_AGENTS=[claude-code]\nAI_TOOLS_FILTERS=[core]\n' > "${lists_conf}"
chmod 0644 "${lists_conf}"
out="$(run_crun AI_TOOLS_OPERATOR_CONF="${lists_conf}" AI_TOOLS_AGENT_EXEC=/bin/sh)" && rc=0 || rc=$?
refused "ai-tools-run refuses every launch while operator.conf names a provider without its kind prefix" MSG-V3Q5 "${rc}" "${out}"
if grep -q 'AI_TOOLS_AGENTS claude-code' <<<"${out}" && grep -q 'system post-upgrade' <<<"${out}"; then
    pass "the refusal names the bare item and the command that rewrites it"
else
    fail "the refusal does not name the item and post-upgrade: $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi
enabled_items=""
while IFS=$'\t' read -r enabled_name _; do
    [[ -n "${enabled_name}" ]] && enabled_items+="${enabled_items:+, }agent-${enabled_name}"
done < <(bash -c 'source /usr/local/lib/ai-tools/providers.lib.sh && ai_tools_enabled_agents' 2>/dev/null)
if [[ -z "${enabled_items}" ]]; then
    skip "the migrated control" "no agent is enabled on this host"
else
    printf 'AI_TOOLS_AGENTS=[%s]\n' "${enabled_items}" > "${lists_conf}"
    out="$(run_crun AI_TOOLS_OPERATOR_CONF="${lists_conf}" AI_TOOLS_AGENT_EXEC=/bin/sh)" && rc=0 || rc=$?
    refused "with the list migrated the same launch reaches the executable check instead" MSG-Z2J9 "${rc}" "${out}"
fi

section "ai-tools-run: the verified entrypoint is the one exec'd"

# The shim checks the RESOLVED entrypoint (label preflight, and the identity re-check) and must hand systemd that same
# path. Naming the launcher symlink in ExecStart instead would leave the manager re-resolving it after every check has
# run, so a repoint in that window would go unobserved on a DAC-only host. Asserted against the deployed script,
# the same way the unit properties are.
if grep -qE -- '-- "\$\{session_exec_path\}" "\$@"' "${CRUN}"; then
    pass "ai-tools-run execs the resolved entrypoint, not the launcher symlink"
else
    fail "ai-tools-run does not ExecStart \${session_exec_path} -- the file checked is not the file exec'd"
fi

# The re-check must sit AFTER the session-env fragments, not with the earlier validation -- its whole value is the width
# of the window it leaves (launch.rule.md). Asserted by line order, because no behaviour of the code reveals where it
# runs. The distance counts CODE lines only: a comment or a blank between the two runs nothing, so it does not widen
# the window, and the launch invocation carries a comment block of its own that would otherwise trip this.
crun_recheck_line="$(grep -n 'entrypoint_identity' "${CRUN}" | tail -n1 | cut -d: -f1)"
crun_launch_line="$(grep -n '^systemd-run --user --pty --quiet' "${CRUN}" | head -n1 | cut -d: -f1)"
if [[ -z "${crun_recheck_line}" || -z "${crun_launch_line}" ]]; then
    fail "ai-tools-run has no last-moment entrypoint re-check before systemd-run"
elif (( crun_recheck_line >= crun_launch_line )); then
    fail "the entrypoint re-check follows systemd-run (re-check line ${crun_recheck_line}, launch line ${crun_launch_line}) -- it observes nothing"
else
    crun_lines_between="$(sed -n "$(( crun_recheck_line + 1 )),$(( crun_launch_line - 1 ))p" "${CRUN}" \
        | grep -cvE '^[[:space:]]*(#|$)' || true)"
    if (( crun_lines_between < 20 )); then
        pass "ai-tools-run re-checks the entrypoint identity immediately before the launch"
    else
        fail "the entrypoint re-check is not immediately before systemd-run (${crun_lines_between} code lines between line ${crun_recheck_line} and line ${crun_launch_line}) -- the window it narrows is back"
    fi
fi

finish

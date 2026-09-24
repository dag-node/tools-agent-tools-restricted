#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/providers.sh
# Unit test for the provider resolver (providers.lib.sh). Drives the PURE verdict ai_tools_provider_is_enabled over its
# enablement truth table, then ai_tools_enabled_agents and ai_tools_enabled_integrations over /tmp fixture manifest dirs
# + operator.conf via the root-only AI_TOOLS_{AGENTS,INTEGRATIONS}_DIR / AI_TOOLS_OPERATOR_CONF hooks (the same
# hermetic-override pattern skip-dirs.lib.sh uses). This is the FAIL-CLOSED enablement contract the toolchain layer
# (ai-tools-bootstrap, nvm-update) and the launcher (ai-tools-run) provision from, so a regression -- a surface-widening
# provider enabled without an explicit opt-in, an absent/unreadable config read as "enable all",
# a requested-but-uninstalled name silently guessed instead of skipped -- fails
# here.
#
# Two properties get their own sections because a break in either is silent in production:
#   * IFS INDEPENDENCE -- the resolver runs inside scripts that set IFS=$'\n\t' (nvm-update.sh).
#     A splitter inheriting that reads a multi-name allowlist as one bogus name, disabling every
#     configured agent with only a warning. The IFS section drives the resolver under that IFS.
#   * TAMPER REFUSAL -- every input that decides what a session gets (operator.conf, the manifest
#     directories, each manifest) is honored only while root-owned and not group/other-writable.
#     This is the mechanism behind "the sandbox cannot widen its own surface", so each untrusted
#     state is asserted to fall back to less access, never more.
#
# No npm, no network, no root risk.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/providers.lib.sh"
section "providers: agent enablement verdict + resolver (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "providers" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" \
        || ! declare -F ai_tools_provider_is_enabled >/dev/null 2>&1 \
        || ! declare -F ai_tools_agent_sweeps_at_exit >/dev/null 2>&1 \
        || ! declare -F ai_tools_enabled_agents >/dev/null 2>&1 \
        || ! declare -F ai_tools_agents_empty_verdict >/dev/null 2>&1 \
        || ! declare -F ai_tools_enabled_integrations >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the resolver functions"; finish; exit
fi

# --- Pure verdict: ai_tools_provider_is_enabled <name> <default_enable> <allowlist_active> <list> ---
verdict() {
    local desc="$1" exp_rc="$2"; shift 2
    local rc=0; ai_tools_provider_is_enabled "$@" || rc=$?
    if [[ "${rc}" -eq "${exp_rc}" ]]; then pass "${desc}"; else fail "${desc}: rc ${rc}, expected ${exp_rc}"; fi
}
# Baseline (no allowlist): default_enable governs.
verdict "baseline default_enable=yes -> enabled"   0 claude-code yes no  ""
verdict "baseline default_enable=no  -> disabled"  1 dotnet      no  no  ""
# Allowlist active: exactly the listed names, default_enable ignored.
verdict "allowlist names it -> enabled"            0 claude-code yes yes "claude-code other"
verdict "allowlist omits it -> disabled"           1 claude-code no  yes "other"
verdict "allowlist empty -> disabled (none)"       1 claude-code yes yes ""
# A default_enable=no (surface-widening) agent is enabled only when explicitly opted in.
verdict "allowlist opts in a default=no agent"     0 dotnet      no  yes "dotnet"
# Separators are interchangeable in the shared grammar (conf.lib.sh).
verdict "comma-separated allowlist names it"       0 claude-code no  yes "claude-code,other"
verdict "mixed separators name it"                 0 other       no  yes "claude-code, other  third"

# --- Pure verdict: ai_tools_agent_sweeps_at_exit <handback-declaration> -----------------------
# Which side converges ownership. Only the exact literal "hooks" may switch the launcher's session-end sweep
# OFF, so an unknown or absent declaration errs toward sweeping -- the safe direction (a redundant walk, never a project
# tree left sandbox-owned).
sweeps() {
    local desc="$1" exp_rc="$2" declared="${3-}"
    local rc=0; ai_tools_agent_sweeps_at_exit "${declared}" || rc=$?
    if [[ "${rc}" -eq "${exp_rc}" ]]; then pass "${desc}"; else fail "${desc}: rc ${rc}, expected ${exp_rc}"; fi
}
sweeps "handback=hooks -> the agent's own hooks converge, no sweep" 1 hooks
sweeps "handback=none  -> the launcher sweeps at session end"       0 none
sweeps "absent handback -> sweeps (no declaration, no driver)"      0
sweeps "unrecognized value -> sweeps (allowlist, not blocklist)"    0 Hooks

# --- Resolver over a /tmp fixture tree (name<TAB>npm_package<TAB>launcher per enabled agent) ---
# The fixtures are created by this root-run suite, so they are root-owned and non-group-writable: the trusted state.
# The tamper section deliberately breaks that per case and restores it.
mktestdir
agents_dir="${TESTDIR}/agents.d"; mkdir -p "${agents_dir}"
printf 'npm_package=@anthropic-ai/claude-code\nlauncher=claude\ndefault_enable=yes\n' > "${agents_dir}/claude-code.conf"
printf 'npm_package=@acme/experimental\nlauncher=acme\ndefault_enable=no\n'           > "${agents_dir}/experimental.conf"
export AI_TOOLS_AGENTS_DIR="${agents_dir}"
conf="${TESTDIR}/operator.conf"

# resolve <conf-path> : enabled agents' stdout. The prefix assignment is visible to the function and reverts
# after the call, so each case runs against its own operator.conf with no leak.
resolve() { AI_TOOLS_OPERATOR_CONF="$1" ai_tools_enabled_agents 2>/dev/null; }
assert_names() {
    local desc="$1" expected="$2" conf_path="$3" got
    got="$(resolve "${conf_path}" | cut -f1 | sort | tr '\n' ' ')"
    if [[ "${got}" == "${expected}" ]]; then pass "${desc}"; else fail "${desc}: got '${got}' expected '${expected}'"; fi
}

# Absent/unreadable config -> baseline -> only the default_enable=yes agent.
assert_names "no config -> baseline (claude-code only)"   "claude-code " /nonexistent
printf 'OPERATORS="x"\n' > "${conf}"
assert_names "config without AI_TOOLS_AGENTS -> baseline" "claude-code " "${conf}"
printf 'AI_TOOLS_AGENTS="agent-claude-code agent-experimental"\n' > "${conf}"
assert_names "allowlist both -> both provisioned"        "claude-code experimental " "${conf}"
printf 'AI_TOOLS_AGENTS=""\n' > "${conf}"
assert_names "explicit empty allowlist -> no agents"     "" "${conf}"

# The shared grammar applies to the gating keys too: quotes optional, commas or whitespace between names, an inline
# comment ending the value.
printf 'AI_TOOLS_AGENTS=agent-claude-code, agent-experimental\n' > "${conf}"
assert_names "unquoted, comma-separated allowlist"       "claude-code experimental " "${conf}"
printf 'AI_TOOLS_AGENTS = agent-claude-code  agent-experimental   # both agents\n' > "${conf}"
assert_names "padded value with an inline comment"       "claude-code experimental " "${conf}"

# The bracketed list form reads as the same allowlist, and an invalid list enables NO agent: it reads as the empty
# allowlist, never as an absent key, which would fall back to the default-enabled baseline. One row per value,
# the expected names then the value as it follows `AI_TOOLS_AGENTS=`, split on the first tab.
gating_cases=(
    $'claude-code experimental \t[agent-claude-code, agent-experimental]'
    $'claude-code experimental \t[agent-experimental,agent-claude-code]   # both'
    $'claude-code \t[, agent-claude-code]'
    $'\t[]'
    $'\t[agent-claude-code'
    $'\tagent-claude-code]'
    $'\t"[agent-claude-code]"'
    $'\t[agent-claude-code, "agent-experimental"]'
    $'\t[claude-code, agent-experimental]'
    $'\t[integration-claude-code]'
    $'\t[agent-]'
    $'\tagent-../claude-code'
)
for row in "${gating_cases[@]}"; do
    printf 'AI_TOOLS_AGENTS=%s\n' "${row#*$'\t'}" > "${conf}"
    assert_names "AI_TOOLS_AGENTS=${row#*$'\t'} enables '${row%%$'\t'*}'" "${row%%$'\t'*}" "${conf}"
done
printf 'AI_TOOLS_AGENTS=[agent-claude-code\n' > "${conf}"
assert_msg MSG-D5N5 "$(AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>&1 >/dev/null)" \
    "an invalid AI_TOOLS_AGENTS list is reported"
# A name without its kind prefix, the spelling an earlier release wrote, is reported under its own code, which names
# the command that rewrites it.
printf 'AI_TOOLS_AGENTS=[claude-code]\n' > "${conf}"
unprefixed_err="$(AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>&1 >/dev/null)"
assert_msg MSG-X6F2 "${unprefixed_err}" "an unprefixed AI_TOOLS_AGENTS item is reported"
[[ "${unprefixed_err}" == *"system post-upgrade"* ]] \
    && pass "the unprefixed-item report names system post-upgrade" \
    || fail "the unprefixed-item report does not name system post-upgrade: ${unprefixed_err}"

# A requested-but-uninstalled agent is skipped from stdout AND reported on stderr (never guessed).
printf 'AI_TOOLS_AGENTS="agent-missing"\n' > "${conf}"
warn_out="$(AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>&1 >/dev/null)"
out_names="$(resolve "${conf}" | cut -f1 | tr '\n' ' ')"
if [[ -z "${out_names}" ]]; then
    pass "requested-but-uninstalled agent skipped from stdout"
else
    fail "uninstalled agent reached stdout: names='${out_names}'"
fi
assert_msg MSG-X8P4 "${warn_out}" "the uninstalled agent is reported on stderr, never guessed"
# The report names the item as the operator wrote it and the package that ships it, derived from the key's kind; one row
# per kind, the integration read through its own resolver.
while IFS='|' read -r key item package resolver; do
    printf '%s=[%s]\n' "${key}" "${item}" > "${conf}"
    warn_out="$(AI_TOOLS_OPERATOR_CONF="${conf}" "${resolver}" 2>&1 >/dev/null)"
    if [[ "${warn_out}" == *"${item} is enabled"* && "${warn_out}" == *"sudo dnf install ${package},"* ]]; then
        pass "an uninstalled ${item} is reported with the package to install, ${package}"
    else
        fail "the report for an uninstalled ${item} does not name ${package}: ${warn_out}"
    fi
done <<'ROWS'
AI_TOOLS_AGENTS|agent-missing|ai-tools-agents-missing-restricted|ai_tools_enabled_agents
AI_TOOLS_INTEGRATIONS|integration-missing|ai-tools-integration-missing|ai_tools_enabled_integrations
ROWS

# --- Manifest field accessor: what ai-tools-run reads once it has resolved an agent -----------
# The name becomes a path, so it is allowlisted to plain identifiers: anything else must resolve an empty result rather
# than address a file outside the manifest directory.
printf 'npm_package=@anthropic-ai/claude-code\nlauncher=claude\ndisplay_name=Claude Code\ndefault_enable=yes\n' \
    > "${agents_dir}/claude-code.conf"
if [[ "$(ai_tools_agent_manifest_field claude-code display_name || true)" == "Claude Code" ]]; then
    pass "manifest field read from a trusted manifest"
else
    fail "manifest field: got '$(ai_tools_agent_manifest_field claude-code display_name || true)'"
fi
for bogus_name in '../../etc/passwd' 'a/b' '..' 'no-such-agent'; do
    if [[ -z "$(ai_tools_agent_manifest_field "${bogus_name}" display_name || true)" ]]; then
        pass "manifest field refuses '${bogus_name}'"
    else
        fail "manifest field resolved something for '${bogus_name}'"
    fi
done
chmod 0666 "${agents_dir}/claude-code.conf"
if [[ -z "$(ai_tools_agent_manifest_field claude-code display_name || true)" ]]; then
    pass "manifest field refuses a world-writable manifest"
else
    fail "manifest field read a world-writable manifest"
fi
chmod 0644 "${agents_dir}/claude-code.conf"

# --- IFS independence: the resolver runs inside scripts that set the strict-mode IFS ----------
section "providers: resolution is independent of the caller's IFS"
printf 'AI_TOOLS_AGENTS="agent-claude-code agent-experimental"\n' > "${conf}"
# A SUBSHELL with IFS=$'\n\t' -- exactly what nvm-update.sh sets -- so the assertion cannot be masked by this file's own
# IFS. Without a locally-pinned IFS in the splitter the whole value reads as one name and BOTH agents drop out with only
# a stderr warning.
ifs_names="$( IFS=$'\n\t'; AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>/dev/null \
              | cut -f1 | sort | tr '\n' ' ' )"
if [[ "${ifs_names}" == "claude-code experimental " ]]; then
    pass "multi-name allowlist resolves under IFS=\$'\\n\\t' (nvm-update's strict mode)"
else
    fail "IFS-dependent split: under IFS=\$'\\n\\t' got '${ifs_names}' expected 'claude-code experimental '"
fi
printf 'AI_TOOLS_AGENTS=agent-claude-code,agent-experimental\n' > "${conf}"
ifs_names="$( IFS=$'\n\t'; AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>/dev/null \
              | cut -f1 | sort | tr '\n' ' ' )"
if [[ "${ifs_names}" == "claude-code experimental " ]]; then
    pass "comma-separated allowlist resolves under IFS=\$'\\n\\t'"
else
    fail "IFS-dependent split (commas): got '${ifs_names}' expected 'claude-code experimental '"
fi

# --- Tamper refusal: the sandbox must not be able to widen its own surface --------------------
# Each case makes ONE input untrusted (the states a non-root writer can create) and asserts the resolver moves to LESS
# access, never more. Restored after each case so the next starts trusted.
section "providers: untrusted inputs fail closed"

# An operator.conf the agent could have written must not be able to opt a default_enable=no provider in: it is ignored
# entirely, falling back to the baseline.
printf 'AI_TOOLS_AGENTS="agent-claude-code agent-experimental"\n' > "${conf}"
chown "${PROJECTS_USER}" "${conf}"
assert_names "non-root-owned operator.conf ignored -> baseline only" "claude-code " "${conf}"
chown root:root "${conf}"
chmod 0664 "${conf}"
assert_names "group-writable operator.conf ignored -> baseline only" "claude-code " "${conf}"
chmod 0644 "${conf}"
assert_names "restored operator.conf honored again"                  "claude-code experimental " "${conf}"

# A manifest the agent could have written cannot introduce or enable a provider: that ONE provider drops
# out, the trusted sibling survives, and the refusal is reported.
chmod 0666 "${agents_dir}/experimental.conf"
tamper_warn="$(AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>&1 >/dev/null)"
assert_names "world-writable manifest skipped, sibling survives" "claude-code " "${conf}"
assert_msg MSG-M3A5 "${tamper_warn}" "untrusted manifest refusal is reported, not silent"
chmod 0644 "${agents_dir}/experimental.conf"

# A manifest DIRECTORY a non-root writer can modify lets them unlink and replace any manifest in it, so the whole kind
# is refused -- no agent is resolved at all.
chmod 0777 "${agents_dir}"
dir_warn="$(AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>&1 >/dev/null)"
assert_names "world-writable manifest dir -> no agents at all" "" "${conf}"
assert_msg MSG-W3Q3 "${dir_warn}" "untrusted manifest dir refusal is reported, not silent"
chmod 0755 "${agents_dir}"
assert_names "restored manifest dir honored again" "claude-code experimental " "${conf}"

# --- Empty-set classification: what nvm-update asks once the resolver returned an empty set ----
# The resolver reports a refused input on stderr and does not print a line for it, so a caller reading stdout sees
# an empty set for a tampered manifest directory and for a host with no agent package alike. nvm-update.sh ends
# the first as a fault (exit 1, RESULT=failed) and logs the second, so the verdict is driven over both classes
# and over the shape its caller parses: one line, a TAB between verdict and reason, every refused path named.
section "providers: an empty agent set is classified as fault or none"
assert_empty() {   # <desc> <expected verdict> <reason substring> <conf path>
    local desc="$1" want="$2" needle="$3" conf_path="$4" line verdict reason
    line="$(AI_TOOLS_OPERATOR_CONF="${conf_path}" ai_tools_agents_empty_verdict)"
    IFS=$'\t' read -r verdict reason <<< "${line}"
    if [[ "${verdict}" == "${want}" && "${reason}" == *"${needle}"* && "${line}" != *$'\n'* ]]; then
        pass "${desc}"
    else
        fail "${desc}: got '${line}'"
    fi
}
# The configuration asks for an empty set: three states, each read as none and logged.
printf 'AI_TOOLS_AGENTS=""\n' > "${conf}"
assert_empty "an explicit empty allowlist is none"        none  "set and empty"              "${conf}"
empty_dir="${TESTDIR}/empty.d"; mkdir -p "${empty_dir}"; chmod 0755 "${empty_dir}"
AI_TOOLS_AGENTS_DIR="${empty_dir}" assert_empty \
             "no installed manifest is none"               none  "no agent manifest is installed" /nonexistent
printf 'npm_package=@anthropic-ai/claude-code\nlauncher=claude\ndefault_enable=no\n' > "${agents_dir}/claude-code.conf"
assert_empty "every manifest default_enable=no is none"   none  "AI_TOOLS_AGENTS unset, so no agent is enabled"  /nonexistent
printf 'npm_package=@anthropic-ai/claude-code\nlauncher=claude\ndisplay_name=Claude Code\ndefault_enable=yes\n' \
    > "${agents_dir}/claude-code.conf"

# An allowlist that is not a valid list does not enable any agent, and the operator asked for something: a fault.
printf 'AI_TOOLS_AGENTS=[agent-claude-code\n' > "${conf}"
assert_empty "an invalid allowlist is a fault"            fault "is not a valid list"          "${conf}"
printf 'AI_TOOLS_AGENTS=[claude-code, codex]\n' > "${conf}"
assert_empty "an unprefixed allowlist is a fault naming post-upgrade" fault "system post-upgrade" "${conf}"
printf 'AI_TOOLS_AGENTS=[]\n' > "${conf}"
assert_empty "an empty bracketed allowlist is none"       none  "set and empty"                "${conf}"

# The operator asked for agents that did not resolve: a fault, naming what was asked for.
printf 'AI_TOOLS_AGENTS="agent-missing agent-other"\n' > "${conf}"
assert_empty "an allowlist that resolved nothing is a fault" fault "names missing other but no agent resolved" "${conf}"

# A refused input is a fault whatever the configuration says, and the reason names the path and what the predicate read
# -- the line an operator investigates from.
chmod 0777 "${agents_dir}"
assert_empty "an untrusted manifest dir is a fault"       fault "${agents_dir}: owner=0 mode=777" /nonexistent
chmod 0666 "${agents_dir}/claude-code.conf"
assert_empty "two refused inputs are both named on one line" fault "2 input(s) failed the trust check" /nonexistent
chmod 0755 "${agents_dir}"
assert_empty "an untrusted manifest is a fault"           fault "${agents_dir}/claude-code.conf: owner=0 mode=666" /nonexistent
chmod 0644 "${agents_dir}/claude-code.conf"
printf 'AI_TOOLS_AGENTS="agent-claude-code"\n' > "${conf}"; chmod 0666 "${conf}"
assert_empty "an untrusted operator.conf is a fault"      fault "${conf}: owner=0 mode=666"    "${conf}"
chmod 0644 "${conf}"
# The caller parses this under IFS=$'\n\t'; the TAB is what keeps verdict and reason apart there.
ifs_line="$( IFS=$'\n\t'; AI_TOOLS_OPERATOR_CONF=/nonexistent AI_TOOLS_AGENTS_DIR="${empty_dir}" ai_tools_agents_empty_verdict )"
if [[ "${ifs_line}" == none$'\t'* ]]; then
    pass "the verdict line parses under IFS=\$'\\n\\t' (nvm-update's strict mode)"
else
    fail "verdict line under IFS=\$'\\n\\t': '${ifs_line}'"
fi

# --- Integrations resolver (one name per line; integrations carry only default_enable) ---------
section "providers: integration enablement"
integrations_dir="${TESTDIR}/integrations.d"; mkdir -p "${integrations_dir}"
printf 'default_enable=no\n'  > "${integrations_dir}/dotnet.conf"    # surface-widening: opt-in only
printf 'default_enable=yes\n' > "${integrations_dir}/baseline.conf" # a hypothetical safe-default integration
export AI_TOOLS_INTEGRATIONS_DIR="${integrations_dir}"
resolve_ints() { AI_TOOLS_OPERATOR_CONF="$1" ai_tools_enabled_integrations 2>/dev/null | sort | tr '\n' ' '; }
assert_ints() {
    local desc="$1" expected="$2" conf_path="$3" got; got="$(resolve_ints "${conf_path}")"
    if [[ "${got}" == "${expected}" ]]; then pass "${desc}"; else fail "${desc}: got '${got}' expected '${expected}'"; fi
}
# Baseline: only default_enable=yes; dotnet (surface-widening, default_enable=no) stays OFF.
assert_ints "integrations baseline -> only default_enable=yes" "baseline " /nonexistent
printf 'AI_TOOLS_INTEGRATIONS="integration-dotnet"\n' > "${conf}"
assert_ints "integrations allowlist opts dotnet in"           "dotnet "   "${conf}"
printf 'AI_TOOLS_INTEGRATIONS=""\n' > "${conf}"
assert_ints "integrations explicit empty -> none"             ""          "${conf}"
printf 'AI_TOOLS_INTEGRATIONS=integration-dotnet, integration-baseline  # both\n' > "${conf}"
assert_ints "integrations comma list with a comment"          "baseline dotnet " "${conf}"
printf 'AI_TOOLS_INTEGRATIONS=[integration-dotnet, integration-baseline]\n' > "${conf}"
assert_ints "integrations bracketed list"                     "baseline dotnet " "${conf}"
# An invalid list reads as the empty allowlist: not even the default-enabled baseline, which absent would enable.
printf 'AI_TOOLS_INTEGRATIONS=[integration-dotnet\n' > "${conf}"
assert_ints "integrations invalid list -> none, not the baseline" "" "${conf}"

# The surface-widening case that matters most: an untrusted operator.conf must not be able to turn dotnet
# (default_enable=no) on.
printf 'AI_TOOLS_INTEGRATIONS="integration-dotnet"\n' > "${conf}"; chmod 0666 "${conf}"
assert_ints "untrusted conf cannot enable a default=no integration" "baseline " "${conf}"
chmod 0644 "${conf}"

# --- The installed-manifest reader (enabled or not) ---------------------------------------------
# relabel.lib.sh reads build_output_dirs from every INSTALLED integration, because a project's label is applied at claim
# time and must not depend on which integrations a later session enables. The read keeps the resolver's trust rules:
# an untrusted manifest is skipped and an untrusted directory yields an empty set, never a name from a file the sandbox
# could write.
section "providers: the installed-manifest field reader"
if declare -F ai_tools_installed_integrations_declaring >/dev/null 2>&1; then
    printf 'default_enable=no\nbuild_output_dirs=bin obj artifacts\n' > "${integrations_dir}/dotnet.conf"
    printf 'default_enable=yes\n' > "${integrations_dir}/baseline.conf"
    printf 'AI_TOOLS_INTEGRATIONS=""\n' > "${conf}"   # dotnet is NOT enabled
    got="$(AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_installed_integrations_declaring build_output_dirs 2>/dev/null | tr '\t' '=' | tr '\n' ' ')"
    if [[ "${got}" == "dotnet=bin obj artifacts " ]]; then
        pass "declaring reads the key from an installed integration whether or not it is enabled"
    else
        fail "declaring read '${got}' (expected 'dotnet=bin obj artifacts ')"
    fi
    chmod 0666 "${integrations_dir}/dotnet.conf"
    got="$(ai_tools_installed_integrations_declaring build_output_dirs 2>/dev/null | tr '\n' ' ')"
    if [[ -z "${got}" ]]; then
        pass "an untrusted (group/other-writable) manifest is skipped by the reader"
    else
        fail "the reader returned a value from an untrusted manifest: '${got}'"
    fi
    chmod 0644 "${integrations_dir}/dotnet.conf"
    chmod 0777 "${integrations_dir}"
    got="$(ai_tools_installed_integrations_declaring build_output_dirs 2>/dev/null | tr '\n' ' ')"
    if [[ -z "${got}" ]]; then
        pass "an untrusted manifest directory yields an empty set"
    else
        fail "the reader returned '${got}' from an untrusted directory"
    fi
    chmod 0755 "${integrations_dir}"
else
    skip "installed-manifest reader" "ai_tools_installed_integrations_declaring not defined"
fi

# --- Managed files: the state of a kept-across-upgrade file against its shipped copy ---------------------------------
# The status reports say when an agent's managed file (codex's /etc/codex/*.toml) is not the shipped one. The verdict is
# pure -- two paths in, one token out -- and every way the comparison cannot be made reads as `unknown` rather than
# as either answer, since a report that guessed "shipped" over a file it could not read would hide the one edit it
# exists to surface. The manifest reader beside it turns the declared list into (live, reference) pairs and refuses
# a path that is not absolute, because the reference is composed from the basename and a relative or dotted path could
# name a file outside the package's datadir.
section "providers: managed files against their shipped copies"
if ! declare -F ai_tools_managed_file_state >/dev/null 2>&1 \
        || ! declare -F ai_tools_agent_managed_files >/dev/null 2>&1; then
    skip "managed files" "ai_tools_managed_file_state / ai_tools_agent_managed_files not defined"
else
    mf="${TESTDIR}/managed"; mkdir -p "${mf}/live" "${mf}/ref"
    printf 'a = 1\n' > "${mf}/ref/f.toml"
    printf 'a = 1\n' > "${mf}/live/same.toml"
    printf 'a = 2\n' > "${mf}/live/edited.toml"
    ln -s "${mf}/ref/f.toml" "${mf}/live/link.toml"
    mkdir -p "${mf}/live/dir.toml"
    mf_state() {
        local desc="$1" expected="$2" got
        got="$(ai_tools_managed_file_state "$3" "$4")"
        if [[ "${got}" == "${expected}" ]]; then pass "${desc}"; else fail "${desc}: got '${got}', expected '${expected}'"; fi
    }
    mf_state "byte-identical -> shipped"                shipped "${mf}/live/same.toml"   "${mf}/ref/f.toml"
    mf_state "differing content -> edited"              edited  "${mf}/live/edited.toml" "${mf}/ref/f.toml"
    mf_state "absent live file -> missing"              missing "${mf}/live/absent.toml" "${mf}/ref/f.toml"
    mf_state "absent reference -> unknown, never a verdict" unknown "${mf}/live/same.toml" "${mf}/ref/absent.toml"
    mf_state "a symlinked live file -> unknown"         unknown "${mf}/live/link.toml"   "${mf}/ref/f.toml"
    mf_state "a directory as the live path -> unknown"  unknown "${mf}/live/dir.toml"    "${mf}/ref/f.toml"
    mf_state "a directory as the reference -> unknown"  unknown "${mf}/live/same.toml"   "${mf}/live/dir.toml"

    # The manifest reader, over a fixture manifest in the root-owned fixture directory the resolver already trusts.
    # The live path is held to a plain name directly under /etc/<agent>/, since the reference is composed
    # from that name: every other shape -- relative, nested, a traversal, another package's directory -- is refused,
    # and so is a second entry repeating a name, which would compare two live paths against one reference copy.
    printf 'npm_package=@acme/managed\nlauncher=managed\nmanaged_files=/etc/managed/one.toml, /etc/managed/two.toml relative.toml /etc/../x.toml /etc/managed/sub/three.toml /etc/other/four.toml /etc/managed/one.toml /etc/managed/..\n' \
        > "${agents_dir}/managed.conf"
    mf_pairs="$(AI_TOOLS_MANAGED_REFERENCE_DIR="${mf}/ref" ai_tools_agent_managed_files managed 2>"${mf}/warn")"
    expected_pairs="$(printf '/etc/managed/one.toml\t%s/ref/managed/one.toml\n/etc/managed/two.toml\t%s/ref/managed/two.toml' "${mf}" "${mf}")"
    if [[ "${mf_pairs}" == "${expected_pairs}" ]]; then
        pass "managed_files yields one (live, reference) pair per name under /etc/<agent>/, the reference under <dir>/<agent>/<name>"
    else
        fail "managed_files pairs: got '${mf_pairs}'"
    fi
    assert_msg MSG-N4W6 "$(cat "${mf}/warn")" "an entry outside /etc/<agent>/ and a repeated name are each refused on stderr"
    if [[ "$(grep -c 'MSG-N4W6' "${mf}/warn")" -eq 6 ]]; then
        pass "each of the six refused entries is reported, one refusal each"
    else
        fail "expected six refusals, got: $(cat "${mf}/warn")"
    fi
    if grep -q 'already paired with a reference copy' "${mf}/warn"; then
        pass "the repeated name is refused as a collision, not as a shape"
    else
        fail "the repeated name was not reported as already paired: $(cat "${mf}/warn")"
    fi
    [[ -z "$(ai_tools_agent_managed_files claude-code 2>/dev/null)" ]] \
        && pass "an agent declaring no managed_files yields empty output" \
        || fail "claude-code's fixture manifest yielded managed files"
    rm -f "${agents_dir}/managed.conf"

    # Retiring one, the step an uninstall takes over each pair. The live file may be the only copy of what the host
    # configured, so what every case here is about is which file is destroyed: one proven byte-identical to its
    # reference, and no other. Everything else -- an edit, a comparison that cannot be made -- is moved aside
    # under the dated sidecar name, which is the treatment rpm gives an edited %config(noreplace) file on erase.
    if ! declare -F ai_tools_managed_file_retire >/dev/null 2>&1; then
        skip "retiring a managed file" "ai_tools_managed_file_retire not defined"
    else
        rt="${mf}/retire"; mkdir -p "${rt}"
        printf 'a = 1\n' > "${rt}/ref.toml"

        printf 'a = 1\n' > "${rt}/shipped.toml"
        mf_out="$(ai_tools_managed_file_retire "${rt}/shipped.toml" "${rt}/ref.toml")"
        [[ "${mf_out}" == removed && ! -e "${rt}/shipped.toml" ]] \
            && pass "retire: a file matching the shipped copy is removed" \
            || fail "retire: a shipped file read '${mf_out}' and is $([[ -e "${rt}/shipped.toml" ]] && echo present || echo gone)"

        printf 'a = 99  # the host\n' > "${rt}/edited.toml"
        mf_out="$(ai_tools_managed_file_retire "${rt}/edited.toml" "${rt}/ref.toml")"
        mf_sidecar="${mf_out#* }"
        if [[ "${mf_out}" == "kept "* && ! -e "${rt}/edited.toml" ]] \
                && [[ -f "${mf_sidecar}" ]] && grep -q 'the host' "${mf_sidecar}"; then
            pass "retire: an edited file is moved aside, the sidecar carrying what the host wrote"
        else
            fail "retire: an edited file read '${mf_out}', ${rt} holds $(ls "${rt}" | tr '\n' ' ')"
        fi
        [[ "${mf_sidecar}" == "${rt}/edited.toml."*.retired ]] \
            && pass "retire: the sidecar is the dated .retired name beside the file it moved" \
            || fail "retire: the sidecar is named '${mf_sidecar}'"

        mf_out="$(ai_tools_managed_file_retire "${rt}/absent.toml" "${rt}/ref.toml")"
        [[ "${mf_out}" == absent && ! -e "${rt}/absent.toml" ]] \
            && pass "retire: nothing at the live path reads absent and writes nothing" \
            || fail "retire: an absent file read '${mf_out}'"

        printf 'a = 1\n' > "${rt}/noref.toml"
        mf_out="$(ai_tools_managed_file_retire "${rt}/noref.toml" "${rt}/no-such-reference.toml")"
        [[ "${mf_out}" == "kept "* && ! -e "${rt}/noref.toml" ]] \
            && pass "retire: a file that cannot be compared is kept, never removed" \
            || fail "retire: an uncomparable file read '${mf_out}'"

        # The write refusal, driven AS THE PROJECTS USER: root ignores a directory's write bit, so root would complete
        # the very move this case is about. That is a vantage rather than a state the host is in, so it is a `runuser`
        # and not a skip. The fixture is opened for reading first, since it was built by root under a 0700 testdir.
        if ! command -v runuser >/dev/null 2>&1; then
            skip "retire: an unwritable directory" "runuser unavailable"
        else
            mkdir -p "${rt}/locked"
            printf 'a = 2\n' > "${rt}/locked/f.toml"
            chmod a+rx "${TESTDIR}" "${mf}"
            chmod -R a+rX "${rt}"
            chmod 0555 "${rt}/locked"
            mf_rc=0
            mf_out="$(runuser -u "${PROJECTS_USER}" -- bash -c '
                source "$1" || exit 9
                ai_tools_managed_file_retire "$2" "$3"' _ \
                "${LIB}" "${rt}/locked/f.toml" "${rt}/ref.toml" 2>"${rt}/err")" || mf_rc=$?
            chmod 0755 "${rt}/locked"
            if [[ "${mf_rc}" -ne 0 && "${mf_rc}" -ne 9 && -z "${mf_out}" && -f "${rt}/locked/f.toml" ]]; then
                pass "retire: a move that cannot be made leaves the file where it is, printing nothing"
            else
                fail "retire: an unwritable directory gave rc ${mf_rc}, stdout '${mf_out}', file $([[ -e "${rt}/locked/f.toml" ]] && echo present || echo GONE)"
            fi
            assert_msg MSG-X7C4 "$(cat "${rt}/err")" "the refusal to move a managed file aside is reported"
        fi
    fi
fi

# --- The installed set: what the toolchain provisioning offers, and checks a name against ------
# ai_tools_installed_agents lists every trusted manifest naming an npm_package whatever operator.conf says, since
# the agent choice is made BEFORE the key exists. The same trust rules as the enabled-set reader, driven
# over the synthetic manifests: a manifest without a package is not an agent, an untrusted one is skipped and reported.
section "providers: the installed agent set"
if declare -F ai_tools_installed_agents >/dev/null 2>&1; then
    inst_dir="${TESTDIR}/installed.d"; mkdir -p "${inst_dir}"; chmod 0755 "${inst_dir}"
    printf 'npm_package=@acme/experimental\nlauncher=acme\ndefault_enable=no\n' > "${inst_dir}/acme.conf"
    printf 'npm_package=@acme/beta\nlauncher=beta\ndefault_enable=no\n'         > "${inst_dir}/beta.conf"
    printf 'launcher=nopkg\ndefault_enable=no\n'                                 > "${inst_dir}/nopkg.conf"
    printf 'AI_TOOLS_AGENTS=""\n' > "${conf}"
    inst_names="$(AI_TOOLS_AGENTS_DIR="${inst_dir}" AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_installed_agents 2>/dev/null | cut -f1 | tr '\n' ' ')"
    if [[ "${inst_names}" == "acme beta " ]]; then
        pass "every trusted manifest naming a package is installed, enabled or not; one naming none is not"
    else
        fail "installed set: got '${inst_names}' expected 'acme beta '"
    fi
    # Captured whole and cut in the shell: a `| head -n 1` would let head exit on the first line and leave the reader's
    # second printf to die of SIGPIPE, which pipefail reports as 141 into this assignment and `set -e` turns
    # into an aborted file -- the race tests.rule.md records for `semodule -l`.
    inst_line="$(AI_TOOLS_AGENTS_DIR="${inst_dir}" ai_tools_installed_agents 2>/dev/null)"
    inst_line="${inst_line%%$'\n'*}"
    [[ "${inst_line}" == $'acme\t@acme/experimental\tacme' ]] \
        && pass "the line carries name, npm_package and launcher, TAB-separated" \
        || fail "installed line is '${inst_line}'"
    chmod 0666 "${inst_dir}/beta.conf"
    inst_err="$(AI_TOOLS_AGENTS_DIR="${inst_dir}" ai_tools_installed_agents 2>&1 >/dev/null)"
    inst_names="$(AI_TOOLS_AGENTS_DIR="${inst_dir}" ai_tools_installed_agents 2>/dev/null | cut -f1 | tr '\n' ' ')"
    [[ "${inst_names}" == "acme " ]] && pass "a group/other-writable manifest is not an installed agent" \
                                     || fail "untrusted manifest reached the installed set: '${inst_names}'"
    assert_msg MSG-M3A5 "${inst_err}" "the skipped manifest is reported under the enabled-set reader's code"
    chmod 0644 "${inst_dir}/beta.conf"
    chmod 0777 "${inst_dir}"
    inst_names="$(AI_TOOLS_AGENTS_DIR="${inst_dir}" ai_tools_installed_agents 2>/dev/null | cut -f1 | tr '\n' ' ')"
    [[ -z "${inst_names}" ]] && pass "a group/other-writable manifest directory yields an empty installed set" \
                             || fail "untrusted directory still listed '${inst_names}'"
    chmod 0755 "${inst_dir}"
else
    fail "providers.lib.sh does not define ai_tools_installed_agents"
fi

# --- No agent ships enabled: the shipped manifests under an absent key resolve to the empty set --------------
# The enabled set is the operator's declaration, written by the toolchain provisioning; a manifest that shipped
# default_enable=yes would enable its agent on every host with no such line, which is the state this pins against.
# Read from the checkout, over every agent manifest the tree ships, so a third agent is held to it on arrival.
section "providers: the shipped agent manifests ship disabled"
shipped_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/usr/local/lib/ai-tools/agents.d"
if [[ -d "${shipped_dir}" ]]; then
    shipped_copy="${TESTDIR}/shipped.d"; mkdir -p "${shipped_copy}"; chmod 0755 "${shipped_copy}"
    cp "${shipped_dir}"/*.conf "${shipped_copy}/"
    chmod 0644 "${shipped_copy}"/*.conf
    for manifest in "${shipped_copy}"/*.conf; do
        if [[ "$(ai_tools_conf_get "${manifest}" default_enable || true)" == "no" ]]; then
            pass "$(basename "${manifest}") ships default_enable=no"
        else
            fail "$(basename "${manifest}") ships default_enable='$(ai_tools_conf_get "${manifest}" default_enable || true)', expected no"
        fi
    done
    shipped_names="$(AI_TOOLS_AGENTS_DIR="${shipped_copy}" AI_TOOLS_OPERATOR_CONF=/nonexistent ai_tools_enabled_agents 2>/dev/null | cut -f1 | tr '\n' ' ')"
    shipped_verdict="$(AI_TOOLS_AGENTS_DIR="${shipped_copy}" AI_TOOLS_OPERATOR_CONF=/nonexistent ai_tools_agents_empty_verdict | cut -f1)"
    if [[ -z "${shipped_names}" && "${shipped_verdict}" == none ]]; then
        pass "the shipped manifests under an absent AI_TOOLS_AGENTS resolve to the empty set, verdict none"
    else
        fail "shipped manifests under an absent key: enabled '${shipped_names}', verdict '${shipped_verdict}'"
    fi
else
    skip "shipped manifests" "not a source checkout (no ${shipped_dir})"
fi

# --- The kind-prefix migration: the one rewrite of an earlier release's list values -------------------------------
# `system post-upgrade` and `system bootstrap` rewrite a list an earlier release wrote with bare names. What matters is
# which lines it touches: a key is rewritten only when every item maps onto a name this host installs, so a rewritten
# line reads back whole, and a key holding any other name stays byte-identical and is named. One .bak is taken
# before the first write, and every line but the rewritten ones survives. Rows: <operator.conf line> <line afterwards>
# <outcome words, in order>.
section "providers: the kind-prefix migration rewrites whole keys only"
mig_root="${TESTDIR}/migration"
mkdir -p "${mig_root}/agents.d" "${mig_root}/integrations.d" "${mig_root}/filters.d"
touch "${mig_root}/agents.d/claude-code.conf" "${mig_root}/agents.d/codex.conf" \
      "${mig_root}/integrations.d/dotnet.conf" "${mig_root}/filters.d/base.rules" "${mig_root}/filters.d/dotnet.rules"
mig_conf="${mig_root}/operator.conf"
migrate() {
    AI_TOOLS_AGENTS_DIR="${mig_root}/agents.d" AI_TOOLS_INTEGRATIONS_DIR="${mig_root}/integrations.d" \
        AI_TOOLS_FILTERS_DIR="${mig_root}/filters.d" ai_tools_conf_kind_migrate "$1" 2>/dev/null || true
}
while IFS='|' read -r before after outcomes; do
    rm -f "${mig_root}"/operator.conf*
    printf '%s\n' '# header' 'OPERATORS=[op]' "${before}" 'SKIP_CACHE_DIRS=[x]' > "${mig_conf}"; chmod 0644 "${mig_conf}"
    out="$(migrate "${mig_conf}")"
    got_outcomes="$(cut -f1 <<< "${out}" | tr '\n' ' ')"; got_outcomes="${got_outcomes% }"
    got_line="$(sed -n 3p "${mig_conf}")"
    others="$(sed -n '1p;2p;4p' "${mig_conf}" | tr '\n' '|')"
    if [[ "${got_line}" == "${after}" && "${got_outcomes}" == "${outcomes}" && "${others}" == '# header|OPERATORS=[op]|SKIP_CACHE_DIRS=[x]|' ]]; then
        pass "migration of '${before}' leaves '${after}' (${outcomes:-no outcome})"
    else
        fail "migration of '${before}': line '${got_line}' (expected '${after}'), outcomes '${got_outcomes}' (expected '${outcomes}'), other lines '${others}'"
    fi
done <<'ROWS'
AI_TOOLS_AGENTS=[claude-code, codex]|AI_TOOLS_AGENTS=[agent-claude-code, agent-codex]|backup rewritten
AI_TOOLS_AGENTS="claude-code agent-codex"|AI_TOOLS_AGENTS=[agent-claude-code, agent-codex]|backup rewritten
AI_TOOLS_INTEGRATIONS=dotnet|AI_TOOLS_INTEGRATIONS=[integration-dotnet]|backup rewritten
AI_TOOLS_FILTERS=[core, dotnet]|AI_TOOLS_FILTERS=[filter-base, filter-dotnet]|backup rewritten
AI_TOOLS_AGENTS=[claude-code, missing]|AI_TOOLS_AGENTS=[claude-code, missing]|blocked
AI_TOOLS_AGENTS=[integration-dotnet]|AI_TOOLS_AGENTS=[integration-dotnet]|blocked
AI_TOOLS_AGENTS=[agent-claude-code]|AI_TOOLS_AGENTS=[agent-claude-code]|
AI_TOOLS_AGENTS=[claude-code|AI_TOOLS_AGENTS=[claude-code|
ROWS

# Every key in one file: one backup, taken before the first write and holding the file as it was; a blocked key beside
# rewritten ones stays as written; the plan the check reports matches what the run did.
rm -f "${mig_root}"/operator.conf*
printf '%s\n' 'AI_TOOLS_AGENTS=[claude-code]' 'AI_TOOLS_INTEGRATIONS=[typesafe]' 'AI_TOOLS_FILTERS=[core]' > "${mig_conf}"
chmod 0644 "${mig_conf}"; cp "${mig_conf}" "${mig_root}/as-it-was"
plan="$(AI_TOOLS_AGENTS_DIR="${mig_root}/agents.d" AI_TOOLS_INTEGRATIONS_DIR="${mig_root}/integrations.d" \
        AI_TOOLS_FILTERS_DIR="${mig_root}/filters.d" ai_tools_conf_kind_plan "${mig_conf}" | cut -f1,2 | tr '\t\n' ' |')"
out="$(migrate "${mig_conf}")"
backups=( "${mig_root}"/operator.conf.*.bak )
if [[ ${#backups[@]} -eq 1 && -f "${backups[0]}" ]] && cmp -s "${backups[0]}" "${mig_root}/as-it-was"; then
    pass "one .bak holds the file as it was, for a run that rewrote two keys"
else
    fail "backups after a two-key rewrite: ${backups[*]}"
fi
if [[ "$(tr '\n' '|' < "${mig_conf}")" == 'AI_TOOLS_AGENTS=[agent-claude-code]|AI_TOOLS_INTEGRATIONS=[typesafe]|AI_TOOLS_FILTERS=[filter-base]|' ]]; then
    pass "a blocked key beside rewritten ones stays as written"
else
    fail "mixed rewrite left '$(tr '\n' '|' < "${mig_conf}")'"
fi
if [[ "${plan}" == 'migrate AI_TOOLS_AGENTS|blocked AI_TOOLS_INTEGRATIONS|migrate AI_TOOLS_FILTERS|' ]]; then
    pass "the plan the check reports names each key the run rewrote or left"
else
    fail "plan: '${plan}'"
fi
# A second run finds only the blocked key, and does not take a second backup.
out="$(migrate "${mig_conf}")"
backups=( "${mig_root}"/operator.conf.*.bak )
if [[ "$(cut -f1 <<< "${out}" | tr '\n' ' ')" == "blocked " && ${#backups[@]} -eq 1 ]]; then
    pass "a second run is idempotent: the blocked key is named again, and no second backup is taken"
else
    fail "second run: outcomes '$(cut -f1 <<< "${out}" | tr '\n' ' ')', ${#backups[@]} backup(s)"
fi
# An untrusted file is not rewritten.
printf 'AI_TOOLS_AGENTS=[claude-code]\n' > "${mig_conf}"; chmod 0666 "${mig_conf}"
out="$(migrate "${mig_conf}")"
if [[ -z "${out}" && "$(cat "${mig_conf}")" == 'AI_TOOLS_AGENTS=[claude-code]' ]]; then
    pass "an untrusted operator.conf is not rewritten"
else
    fail "an untrusted operator.conf was touched: '${out}' / '$(cat "${mig_conf}")'"
fi

finish

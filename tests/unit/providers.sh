#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/providers.sh
# Unit test for the provider resolver (providers.lib.sh). Drives the PURE verdict
# ai_tools_provider_is_enabled over its enablement truth table, then ai_tools_enabled_agents and
# ai_tools_enabled_integrations over /tmp fixture manifest dirs + operator.conf via the root-only
# AI_TOOLS_{AGENTS,INTEGRATIONS}_DIR / AI_TOOLS_OPERATOR_CONF hooks (the same hermetic-override
# pattern skip-dirs.lib.sh uses). This is the FAIL-CLOSED enablement contract the toolchain layer
# (ai-tools-bootstrap, nvm-update) and the launcher (ai-tools-run) provision from, so a regression --
# a surface-widening provider enabled without an explicit opt-in, an absent/unreadable config read
# as "enable all", a requested-but-uninstalled name silently guessed instead of skipped -- fails
# here.
#
# Two properties get their own sections because a break in either is silent in production:
#   * IFS INDEPENDENCE -- the resolver runs inside scripts that set IFS=$'\n\t' (nvm-update.sh).
#     A splitter inheriting that reads a multi-name allowlist as one bogus name, disabling every
#     configured agent with only a warning. The section below drives the resolver under that IFS.
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
# Which side converges ownership. Only the exact literal "hooks" may switch the launcher's
# session-end sweep OFF, so an unknown or absent declaration errs toward sweeping -- the safe
# direction (a redundant walk, never a project tree left sandbox-owned).
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
# The fixtures are created by this root-run suite, so they are root-owned and non-group-writable:
# the trusted state. The tamper section below deliberately breaks that per case and restores it.
mktestdir
agents_dir="${TESTDIR}/agents.d"; mkdir -p "${agents_dir}"
printf 'npm_package=@anthropic-ai/claude-code\nlauncher=claude\ndefault_enable=yes\n' > "${agents_dir}/claude-code.conf"
printf 'npm_package=@acme/experimental\nlauncher=acme\ndefault_enable=no\n'           > "${agents_dir}/experimental.conf"
export AI_TOOLS_AGENTS_DIR="${agents_dir}"
conf="${TESTDIR}/operator.conf"

# resolve <conf-path> : enabled agents' stdout. The prefix assignment is visible to the function
# and reverts after the call, so each case runs against its own operator.conf with no leak.
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
printf 'AI_TOOLS_AGENTS="claude-code experimental"\n' > "${conf}"
assert_names "allowlist both -> both provisioned"        "claude-code experimental " "${conf}"
printf 'AI_TOOLS_AGENTS=""\n' > "${conf}"
assert_names "explicit empty allowlist -> no agents"     "" "${conf}"

# The shared grammar applies to the gating keys too: quotes optional, commas or whitespace
# between names, an inline comment ending the value.
printf 'AI_TOOLS_AGENTS=claude-code, experimental\n' > "${conf}"
assert_names "unquoted, comma-separated allowlist"       "claude-code experimental " "${conf}"
printf 'AI_TOOLS_AGENTS = claude-code  experimental   # both agents\n' > "${conf}"
assert_names "padded value with an inline comment"       "claude-code experimental " "${conf}"

# A requested-but-uninstalled agent is skipped from stdout AND reported on stderr (never guessed).
printf 'AI_TOOLS_AGENTS="missing"\n' > "${conf}"
warn_out="$(AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>&1 >/dev/null)"
out_names="$(resolve "${conf}" | cut -f1 | tr '\n' ' ')"
if [[ -z "${out_names}" && "${warn_out}" == *missing*"no manifest is installed"* ]]; then
    pass "requested-but-uninstalled agent skipped + warned"
else
    fail "uninstalled agent: names='${out_names}' warn='${warn_out}'"
fi

# --- Manifest field accessor: what ai-tools-run reads once it has resolved an agent -----------
# The name becomes a path, so it is allowlisted to plain identifiers: anything else must resolve
# nothing rather than address a file outside the manifest directory.
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
printf 'AI_TOOLS_AGENTS="claude-code experimental"\n' > "${conf}"
# A SUBSHELL with IFS=$'\n\t' -- exactly what nvm-update.sh sets -- so the assertion cannot be
# masked by this file's own IFS. Without a locally-pinned IFS in the splitter the whole value
# reads as one name and BOTH agents drop out with only a stderr warning.
ifs_names="$( IFS=$'\n\t'; AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>/dev/null \
              | cut -f1 | sort | tr '\n' ' ' )"
if [[ "${ifs_names}" == "claude-code experimental " ]]; then
    pass "multi-name allowlist resolves under IFS=\$'\\n\\t' (nvm-update's strict mode)"
else
    fail "IFS-dependent split: under IFS=\$'\\n\\t' got '${ifs_names}' expected 'claude-code experimental '"
fi
printf 'AI_TOOLS_AGENTS=claude-code,experimental\n' > "${conf}"
ifs_names="$( IFS=$'\n\t'; AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>/dev/null \
              | cut -f1 | sort | tr '\n' ' ' )"
if [[ "${ifs_names}" == "claude-code experimental " ]]; then
    pass "comma-separated allowlist resolves under IFS=\$'\\n\\t'"
else
    fail "IFS-dependent split (commas): got '${ifs_names}' expected 'claude-code experimental '"
fi

# --- Tamper refusal: the sandbox must not be able to widen its own surface --------------------
# Each case makes ONE input untrusted (the states a non-root writer can create) and asserts the
# resolver moves to LESS access, never more. Restored after each case so the next starts trusted.
section "providers: untrusted inputs fail closed"

# An operator.conf the agent could have written must not be able to opt a default_enable=no
# provider in: it is ignored entirely, falling back to the baseline.
printf 'AI_TOOLS_AGENTS="claude-code experimental"\n' > "${conf}"
chown "${PROJECTS_USER}" "${conf}"
assert_names "non-root-owned operator.conf ignored -> baseline only" "claude-code " "${conf}"
chown root:root "${conf}"
chmod 0664 "${conf}"
assert_names "group-writable operator.conf ignored -> baseline only" "claude-code " "${conf}"
chmod 0644 "${conf}"
assert_names "restored operator.conf honored again"                  "claude-code experimental " "${conf}"

# A manifest the agent could have written cannot introduce or enable a provider: that ONE
# provider drops out, the trusted sibling survives, and the refusal is reported.
chmod 0666 "${agents_dir}/experimental.conf"
tamper_warn="$(AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>&1 >/dev/null)"
assert_names "world-writable manifest skipped, sibling survives" "claude-code " "${conf}"
if [[ "${tamper_warn}" == *"skipping agent experimental"* ]]; then
    pass "untrusted manifest refusal is reported, not silent"
else
    fail "untrusted manifest refusal not reported: '${tamper_warn}'"
fi
chmod 0644 "${agents_dir}/experimental.conf"

# A manifest DIRECTORY a non-root writer can modify lets them unlink and replace any manifest in
# it, so the whole kind is refused -- no agent is resolved at all.
chmod 0777 "${agents_dir}"
dir_warn="$(AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>&1 >/dev/null)"
assert_names "world-writable manifest dir -> no agents at all" "" "${conf}"
if [[ "${dir_warn}" == *"refusing every AI_TOOLS_AGENTS provider"* ]]; then
    pass "untrusted manifest dir refusal is reported, not silent"
else
    fail "untrusted manifest dir refusal not reported: '${dir_warn}'"
fi
chmod 0755 "${agents_dir}"
assert_names "restored manifest dir honored again" "claude-code experimental " "${conf}"

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
printf 'AI_TOOLS_INTEGRATIONS="dotnet"\n' > "${conf}"
assert_ints "integrations allowlist opts dotnet in"           "dotnet "   "${conf}"
printf 'AI_TOOLS_INTEGRATIONS=""\n' > "${conf}"
assert_ints "integrations explicit empty -> none"             ""          "${conf}"
printf 'AI_TOOLS_INTEGRATIONS=dotnet, baseline  # both\n' > "${conf}"
assert_ints "integrations comma list with a comment"          "baseline dotnet " "${conf}"

# The surface-widening case that matters most: an untrusted operator.conf must not be able to
# turn dotnet (default_enable=no) on.
printf 'AI_TOOLS_INTEGRATIONS="dotnet"\n' > "${conf}"; chmod 0666 "${conf}"
assert_ints "untrusted conf cannot enable a default=no integration" "baseline " "${conf}"
chmod 0644 "${conf}"

finish

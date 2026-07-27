#!/usr/bin/env bash
# tests/unit/providers.sh
# Unit test for the provider resolver (providers.lib.sh). Drives the PURE verdict
# ai_tools_provider_is_enabled over its enablement truth table, then ai_tools_enabled_agents and
# ai_tools_enabled_integrations over /tmp fixture manifest dirs + operator.conf via the root-only
# AI_TOOLS_{AGENTS,INTEGRATIONS}_DIR / AI_TOOLS_OPERATOR_CONF hooks (the same hermetic-override
# pattern skip-dirs.lib.sh uses). This is the FAIL-CLOSED enablement contract the toolchain layer
# (ai-tools-bootstrap, nvm-update) and the launcher (claude-run) provision from, so a regression --
# a surface-widening provider enabled without an explicit opt-in, an absent/unreadable config read
# as "enable all", a requested-but-uninstalled name silently guessed instead of skipped -- fails
# here. No npm, no network, no root risk.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/providers.lib.sh"
section "providers: agent enablement verdict + resolver (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "providers" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" \
        || ! declare -F ai_tools_provider_is_enabled >/dev/null 2>&1 \
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

# --- Resolver over a /tmp fixture tree (name<TAB>npm_pkg<TAB>launcher per enabled agent) ---
mktestdir
agents_dir="${TESTDIR}/agents.d"; mkdir -p "${agents_dir}"
printf 'npm_pkg=@anthropic-ai/claude-code\nlauncher=claude\ndefault_enable=yes\n' > "${agents_dir}/claude-code.conf"
printf 'npm_pkg=@acme/experimental\nlauncher=acme\ndefault_enable=no\n'           > "${agents_dir}/experimental.conf"
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

# A requested-but-uninstalled agent is skipped from stdout AND reported on stderr (never guessed).
printf 'AI_TOOLS_AGENTS="missing"\n' > "${conf}"
warn_out="$(AI_TOOLS_OPERATOR_CONF="${conf}" ai_tools_enabled_agents 2>&1 >/dev/null)"
out_names="$(resolve "${conf}" | cut -f1 | tr '\n' ' ')"
if [[ -z "${out_names}" && "${warn_out}" == *missing*"no manifest is installed"* ]]; then
    pass "requested-but-uninstalled agent skipped + warned"
else
    fail "uninstalled agent: names='${out_names}' warn='${warn_out}'"
fi

# --- Integrations resolver (one name per line; integrations carry only default_enable) ---------
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

finish

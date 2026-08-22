#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/selinux.sh
# Integration: the SELinux confinement layer is actually ENFORCING, not silently disabled. The
# whole trust chain past DAC (steps 4-5 in CLAUDE.md) rests on ai_tools_t / ai_tools_handback_t
# type enforcement; a `setenforce 0` or a stray `semanage permissive -a ai_tools_t` -- the kind
# of "temporary debug" that never gets reverted -- would drop that boundary while every DAC test
# stays green. This asserts the missing signal: when the ai_tools module is loaded the system is
# Enforcing and neither domain is marked permissive. The confinement module is an OPTIONAL layer
# (permissive-first bring-up, stock-box installs without it), so when it is not loaded the whole
# file SKIPS -- it never demands SELinux on a host that does not ship the policy. Run as root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "SELinux confinement is enforcing (integration)"

# selinux_note: printed with the layer-absent skips so a DAC-only run states its posture
# and the recommendation once: DAC is the enforced boundary either way; the SELinux layer
# is the recommended second one on hosts that support it. A container (e.g. podman) has
# no policy of its own -- the layer belongs to the host running it.
selinux_note() {
    printf '  NOTE  running on DAC alone -- the filesystem boundary holds; the optional SELinux layer is not active\n'
    printf '        recommended on SELinux-capable hosts:  sudo %s install\n' \
        "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/selinux/install-selinux.sh"
    printf '        (inside a container, e.g. podman, the layer is provided by the host)\n'
}

# (0) SELinux must be present and not globally disabled, or the confinement layer is moot.
if ! command -v getenforce >/dev/null 2>&1; then
    skip "SELinux enforcing" "getenforce not installed (SELinux userspace absent)"
    selinux_note; finish; exit
fi
mode="$(getenforce 2>/dev/null || true)"
if [[ -z "${mode}" || "${mode}" == "Disabled" ]]; then
    skip "SELinux enforcing" "SELinux is ${mode:-unavailable} (no policy loaded on this host)"
    selinux_note; finish; exit
fi

# (1) Is the ai_tools confinement module loaded? Prefer semodule; fall back to seinfo (setools).
# When neither tool is present we cannot tell, so the whole check skips rather than guess.
module_loaded() {
    if command -v semodule >/dev/null 2>&1; then
        semodule -l 2>/dev/null | grep -qx 'ai_tools'
    elif command -v seinfo >/dev/null 2>&1; then
        seinfo -t ai_tools_t >/dev/null 2>&1
    else
        return 2
    fi
}
module_loaded; ml=$?
if [[ ${ml} -eq 2 ]]; then
    skip "SELinux enforcing" "neither semodule nor seinfo available to detect the ai_tools module"; finish; exit
elif [[ ${ml} -ne 0 ]]; then
    skip "SELinux enforcing" "ai_tools SELinux module not loaded (confinement layer not installed on this host)"
    selinux_note; finish; exit
fi

# (2) Module IS loaded: global mode must be Enforcing. Permissive here means the confined
# session runs with type enforcement disabled -- a full confinement bypass this test exists to
# catch. (A deliberate permissive bring-up is expected to fail this; that is the signal.)
if [[ "${mode}" == "Enforcing" ]]; then
    pass "global SELinux mode is Enforcing (ai_tools module loaded)"
else
    fail "ai_tools module is loaded but SELinux is ${mode} -- the session runs unconfined. Fix: setenforce 1 (and check /etc/selinux/config)"
fi

# (3) Neither confinement domain may be individually marked permissive -- that exempts the
# domain from enforcement even while the system is globally Enforcing (same bypass, narrower
# blast radius). Prefer `semanage permissive -l`; fall back to `seinfo --permissive`.
list_permissive() {
    if command -v semanage >/dev/null 2>&1; then
        semanage permissive -l 2>/dev/null
    elif command -v seinfo >/dev/null 2>&1; then
        seinfo --permissive 2>/dev/null
    else
        return 2
    fi
}
perm_list="$(list_permissive)"; pl=$?
if [[ ${pl} -eq 2 ]]; then
    skip "confinement domains not permissive" "neither semanage nor seinfo available to list permissive types"
else
    perm_hit="$(printf '%s\n' "${perm_list}" | grep -Ew 'ai_tools_t|ai_tools_handback_t' || true)"
    if [[ -z "${perm_hit}" ]]; then
        pass "neither ai_tools_t nor ai_tools_handback_t is marked permissive"
    else
        fail "a confinement domain is permissive (exempt from enforcement): ${perm_hit//$'\n'/ }. Fix: semanage permissive -d <domain>"
    fi
fi

# (4) The module-presence probe ai-tools-run relies on. The shim runs as the SANDBOX account, which
# cannot read the root-only module store, so it derives the `module` verdict input from matchpathcon
# on a CORE-owned path. With the module loaded here, that path MUST resolve to an ai_tools_* type --
# otherwise the probe would read module=no and the fail-closed "unverifiable" refusal would silently
# downgrade to a DAC-only launch (the fail-open this fix closes). This is the runtime end of that
# guarantee; the agent cannot forge it (file-contexts + the shim are root-owned -- boundary/access.sh).
if ! command -v matchpathcon >/dev/null 2>&1; then
    skip "module-presence probe" "matchpathcon not available"
else
    probe_type="$(matchpathcon -n /opt/ai-tools/.config 2>/dev/null | awk -F: '{print $3}' || true)"
    if [[ "${probe_type}" == ai_tools_* ]]; then
        pass "module-presence probe: matchpathcon /opt/ai-tools/.config -> ${probe_type} (module seen without the root-only store)"
        # Tie the real input to the deployed classifier, when it is present (skips on a pre-fix install).
        lib=/usr/local/lib/ai-tools/confinement.lib.sh
        if [[ -r "${lib}" ]] && source "${lib}" 2>/dev/null \
                && declare -F ai_tools_confinement_module_present >/dev/null 2>&1; then
            if [[ "$(ai_tools_confinement_module_present "${probe_type}")" == yes ]]; then
                pass "ai_tools_confinement_module_present(${probe_type}) -> yes"
            else
                fail "classifier rejected a live core type ${probe_type}"
            fi
        fi
    else
        fail "module loaded but matchpathcon /opt/ai-tools/.config -> ${probe_type:-none} (not ai_tools_*) -- the sandbox-side probe would read module=no and fail OPEN"
    fi
fi

# (5) Sandbox clones must LABEL as ai_tools_project_t. Their on-disk path is under
# /var/opt/ai-tools/sandbox-projects, which the base file_contexts.subs_dist alias `/var/opt /opt`
# canonicalizes to /opt/... BEFORE file-context matching, so the clone rule is authored under /opt
# (ai_tools.fc). This asserts the rule is actually REACHABLE through that alias: a synthetic clone
# path resolves to ai_tools_project_t. A rule keyed on the aliased /var/opt prefix resolves to
# usr_t here instead -- the exact regression this catches. matchpathcon reads the loaded policy,
# so the path need not exist.
readonly SANDBOX_ROOT="/var/opt/ai-tools/sandbox-projects"
if ! command -v matchpathcon >/dev/null 2>&1; then
    skip "sandbox clone label" "matchpathcon not available"
else
    sbx_type="$(matchpathcon -n "${SANDBOX_ROOT}/_probe-$$" 2>/dev/null | awk -F: '{print $3}' || true)"
    if [[ "${sbx_type}" == "ai_tools_project_t" ]]; then
        pass "sandbox clone path resolves to ai_tools_project_t (subs_dist /var/opt->/opt alias honoured)"
    else
        fail "sandbox clone path -> ${sbx_type:-none}, not ai_tools_project_t -- the clone fcontext rule is unreachable (authored on the aliased /var/opt prefix instead of /opt?)"
    fi
fi

# (6) The label primitives on a sandbox clone, the branch that mutates no policy.
# relabel.lib.sh splits on _ai_tools_is_sandbox: a clone is covered by the STATIC ai_tools.fc
# rule, so the helper adds no per-path `semanage fcontext` entry and has none to remove.
# ai_tools_label_project still verifies the achieved label rather than trusting restorecon's exit
# status, so a mislabel is a hard failure -- the regression that let a usr_t clone report success.
# After an unlabel a clone is still labelled, which is what keeps it reachable by the confined
# agent: the way to un-label a clone is to delete it (`ai-tools --sandbox-remove`).
#
# The other branch -- a claimed project, where the helper adds and then removes a per-path
# fcontext rule -- is deliberately NOT exercised. Driving it would mutate the host's local SELinux
# policy to test a helper, which no test here does, and a teardown that can leave a policy entry
# behind is worse than the coverage it buys. That leaves ai_tools_unlabel_project's revert path
# (the one --project-unclaim drives) uncovered: a known gap, recorded rather than papered over.
RELABEL_LIB=/usr/local/lib/ai-tools/relabel.lib.sh
if [[ ! -d "${SANDBOX_ROOT}" ]]; then
    skip "sandbox clone label" "sandbox area ${SANDBOX_ROOT} not present"
elif [[ ! -r "${RELABEL_LIB}" ]] || ! source "${RELABEL_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_label_project >/dev/null 2>&1; then
    skip "sandbox clone label" "relabel.lib.sh not available at ${RELABEL_LIB}"
else
    sprobe="${SANDBOX_ROOT}/_selftest-relabel-$$"
    mkdir -p "${sprobe}"
    if ai_tools_label_project "${sprobe}" && ai_tools_project_labelled "${sprobe}"; then
        pass "ai_tools_label_project applies AND verifies ai_tools_project_t on a sandbox clone"
    else
        fail "sandbox clone ${sprobe} is not ai_tools_project_t ($(ls -Zd "${sprobe}" 2>/dev/null))"
    fi
    ai_tools_unlabel_project "${sprobe}" >/dev/null 2>&1 || true
    if ai_tools_project_labelled "${sprobe}"; then
        pass "an unlabel leaves a sandbox clone labelled (the static rule is authoritative)"
    else
        fail "unlabel stripped ai_tools_project_t from a sandbox clone -- the agent loses access to every clone"
    fi
    rmdir "${sprobe}" 2>/dev/null || true
fi

# (7) The declared entrypoint rule still describes where each enabled agent's package installs its
# executable. This is the live half of unit/relabel.sh's pure reconciliation: the resolution needs a
# provisioned toolchain (and root, to traverse the 0750 nvm tree), so only a real host can drive it.
#
# What it catches is upstream repackaging. The agent's executable is delivered through a nested,
# platform-specific optional dependency and hardlinked into the path the manifest declares -- so the
# declaration holds only while that postinstall hardlink does. A release that stops creating it
# leaves the entrypoint installed, unlabelled, and every launch fail-closing. This assertion turns
# that into a test failure at the next suite run instead of a refused launch for an operator.
#
# Read-only: it resolves and compares, and mutates no policy.
section "SELinux: each enabled agent's declared entrypoint rule matches what is installed"

if ! declare -F ai_tools_entrypoint_reconcile_verdict >/dev/null 2>&1 \
        || ! declare -F ai_tools_enabled_agents >/dev/null 2>&1; then
    skip "entrypoint declaration reconciliation" "relabel.lib.sh/providers.lib.sh not loaded"
else
    agents_seen=0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        agents_seen=$(( agents_seen + 1 ))
        installed="$(_ai_tools_launcher_target "${agent}" || true)"
        if [[ -z "${installed}" ]]; then
            skip "${agent} entrypoint declaration" "its launcher does not resolve (not provisioned)"
            continue
        fi
        pattern="$(ai_tools_agent_manifest_field "${agent}" entrypoint_fcontext || true)"
        covered=no matched=no
        while IFS= read -r p; do
            matched=yes
            [[ "${p}" == "${installed}" ]] && covered=yes
        done < <(_ai_tools_entrypoint_paths "${pattern}")
        case "$(ai_tools_entrypoint_reconcile_verdict "${installed}" "${covered}" "${matched}")" in
            ok) pass "${agent}: its declared entrypoint rule covers ${installed}" ;;
            *)  fail "${agent}: installed at ${installed}, which its declared entrypoint_fcontext does not cover -- every launch will fail closed; the manifest is stale" ;;
        esac
    done < <(ai_tools_enabled_agents 2>/dev/null)
    (( agents_seen > 0 )) || skip "entrypoint declaration reconciliation" "no enabled agent resolved"
fi

finish

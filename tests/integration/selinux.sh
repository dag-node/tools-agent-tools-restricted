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

# (6) The label/RELABEL primitives applied end-to-end, with the achieved label VERIFIED rather than
# restorecon's exit status trusted: ai_tools_label_project self-verifies, so a mislabel is a hard
# failure (the regression that let a usr_t clone report success).
#
# relabel.lib.sh splits on _ai_tools_is_sandbox, and the two branches are asserted separately
# because only one of them can revert. This is the CLAIMED-PROJECT branch, the one
# --project-claim/--project-unclaim drive: a per-path `semanage fcontext` rule is added, restorecon
# applies it, and the unlabel removes both -- so it round-trips. It runs in the /tmp testdir
# precisely because that is OUTSIDE the sandbox root; the label is reachable there through the
# per-path rule the helper adds, not through any static rule.
RELABEL_LIB=/usr/local/lib/ai-tools/relabel.lib.sh
if [[ ! -r "${RELABEL_LIB}" ]] || ! source "${RELABEL_LIB}" 2>/dev/null \
        || ! declare -F ai_tools_label_project >/dev/null 2>&1; then
    skip "label/relabel round-trip" "relabel.lib.sh not available at ${RELABEL_LIB}"
else
    mktestdir
    probe="${TESTDIR}/claimed"
    mkdir -p "${probe}"
    if ai_tools_label_project "${probe}" && ai_tools_project_labelled "${probe}"; then
        pass "ai_tools_label_project applies AND verifies ai_tools_project_t on a claimed path"
    else
        fail "ai_tools_label_project did not leave ${probe} on ai_tools_project_t ($(ls -Zd "${probe}" 2>/dev/null))"
    fi
    # Remove the per-path rule whatever the assertion above did, so a failed run leaves no
    # semanage entry behind for a /tmp path that is about to be deleted.
    if ai_tools_unlabel_project "${probe}" && ! ai_tools_project_labelled "${probe}"; then
        pass "ai_tools_unlabel_project reverts a claimed path off ai_tools_project_t"
    else
        fail "ai_tools_unlabel_project left ${probe} on ai_tools_project_t ($(ls -Zd "${probe}" 2>/dev/null))"
    fi
fi

# (7) The SANDBOX-CLONE branch of that same split. A clone is covered by the STATIC ai_tools.fc
# rule, so the helper adds no per-path rule -- and therefore cannot remove one: after an unlabel a
# clone is still ai_tools_project_t, which is what keeps it reachable by the confined agent. This
# is the designed asymmetry, so assert it rather than leave it to be rediscovered as a bug: the
# way to un-label a clone is to delete it (`ai-tools --sandbox-remove`), not to relabel it.
if [[ ! -d "${SANDBOX_ROOT}" ]]; then
    skip "sandbox clone label is static" "sandbox area ${SANDBOX_ROOT} not present"
elif ! declare -F ai_tools_unlabel_project >/dev/null 2>&1; then
    skip "sandbox clone label is static" "relabel.lib.sh not available at ${RELABEL_LIB}"
else
    sprobe="${SANDBOX_ROOT}/_selftest-relabel-$$"
    mkdir -p "${sprobe}"
    if ai_tools_label_project "${sprobe}" && ai_tools_project_labelled "${sprobe}"; then
        pass "a sandbox clone labels ai_tools_project_t from the static rule"
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

finish

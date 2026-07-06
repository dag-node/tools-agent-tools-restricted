#!/usr/bin/env bash
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

# (0) SELinux must be present and not globally disabled, or the confinement layer is moot.
if ! command -v getenforce >/dev/null 2>&1; then
    skip "SELinux enforcing" "getenforce not installed (SELinux userspace absent)"; finish; exit
fi
mode="$(getenforce 2>/dev/null || true)"
if [[ -z "${mode}" || "${mode}" == "Disabled" ]]; then
    skip "SELinux enforcing" "SELinux is ${mode:-unavailable} (no policy loaded on this host)"; finish; exit
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
    finish; exit
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

finish

#!/usr/bin/env bash
# tests/unit/selinux-groups.sh
# Unit test for the optional SELinux policy-group registry (selinux-groups.lib.sh), the single
# source shared by ai-tools-admin (loads a prebuilt group) and selinux/install-selinux.sh
# (compiles one). Pins two things:
#   * the pure accessors + validity predicate -- ai-tools-admin's enable/disable-group gate on
#     ai_tools_selinux_group_valid, so an unknown name must be rejected;
#   * registry <-> filesystem lockstep -- because the groups ship PREBUILT, a registry name with
#     no policy source or no committed .pp (or a policy module absent from the registry) means
#     enable-group either has no package to load or silently cannot be reached. That drift is the
#     cost of shipping binaries, so it is asserted here against the checkout.
#
# Sources the deployed lib; the lockstep half additionally needs the repo policy sources, so it
# runs only in a checkout. No root risk, no SELinux dependency (semodule is never called).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
# Read-only (sources a world-readable lib, reads repo files); no root needed, like man.sh.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Installed copy first, then the source tree (the lib carries no token substitution, so the two
# are identical); the lockstep half needs the checkout regardless.
LIB="/usr/local/lib/ai-tools/selinux-groups.lib.sh"
[[ -r "${LIB}" ]] || LIB="${ROOT}/src/usr/local/lib/ai-tools/selinux-groups.lib.sh"
section "selinux-groups: registry accessors + filesystem lockstep (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "selinux-groups" "library not readable (neither installed nor in a checkout)"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" \
        || ! declare -F ai_tools_selinux_group_valid >/dev/null 2>&1 \
        || ! declare -F ai_tools_selinux_group_name  >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the accessors"; finish; exit
fi

# --- The package-dir constant is the canonical location both the RPM and install.sh populate ---
if [[ "${AI_TOOLS_SELINUX_PACKAGE_DIR}" == "/usr/share/selinux/packages/ai-tools" ]]; then
    pass "package dir constant is ${AI_TOOLS_SELINUX_PACKAGE_DIR}"
else
    fail "package dir constant is '${AI_TOOLS_SELINUX_PACKAGE_DIR}', expected /usr/share/selinux/packages/ai-tools"
fi

# --- Every record parses into a well-formed name and non-empty description + reason ---
if (( ${#AI_TOOLS_SELINUX_GROUPS[@]} > 0 )); then
    pass "registry is non-empty (${#AI_TOOLS_SELINUX_GROUPS[@]} groups)"
else
    fail "registry AI_TOOLS_SELINUX_GROUPS is empty"
fi

names=()
for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
    n="$(ai_tools_selinux_group_name "${entry}")"
    d="$(ai_tools_selinux_group_desc "${entry}")"
    r="$(ai_tools_selinux_group_reason "${entry}")"
    stability="$(ai_tools_selinux_group_stability "${entry}")"
    names+=( "${n}" )
    # Every field parses, and stability is exactly one of the two known values (a fourth pipe
    # field must not bleed into the reason -- the accessor-shift regression this guards).
    if [[ "${n}" =~ ^[a-z][a-z0-9]*$ && -n "${d}" && -n "${r}" \
          && ( "${stability}" == experimental || "${stability}" == stable ) \
          && "${r}" != experimental && "${r}" != stable ]]; then
        pass "group '${n}': well-formed name/desc/reason and stability='${stability}'"
    else
        fail "group record malformed: name='${n}' desc='${d}' reason='${r}' stability='${stability}'"
    fi
    # The experimental predicate the enable-group confirmation gate keys on must agree with the
    # field: 'stable' groups skip the gate, everything else warns and confirms.
    if [[ "${stability}" == stable ]]; then
        ai_tools_selinux_group_is_experimental "${n}" \
            && fail "group '${n}' is stable but is_experimental returned true"
    else
        ai_tools_selinux_group_is_experimental "${n}" \
            || fail "group '${n}' is '${stability}' but is_experimental returned false"
    fi
done

# --- validity predicate: known names accepted, an unknown name rejected (the enable-group gate) ---
for n in "${names[@]}"; do
    ai_tools_selinux_group_valid "${n}" || fail "ai_tools_selinux_group_valid rejected known group '${n}'"
done
if ai_tools_selinux_group_valid "definitely-not-a-group"; then
    fail "ai_tools_selinux_group_valid accepted an unknown group"
else
    pass "ai_tools_selinux_group_valid rejects an unknown group"
fi

# --- Lockstep with the shipped artifacts (checkout only) ---
POL="${ROOT}/selinux/policy"
if [[ ! -d "${POL}" ]]; then
    skip "registry<->filesystem lockstep" "not a source checkout (no ${POL})"
    finish; exit
fi

# Forward: each registry name has a .te source AND a committed prebuilt .pp.
for n in "${names[@]}"; do
    [[ -f "${POL}/ai_tools_${n}.te" ]] \
        || fail "group '${n}' in registry but ${POL}/ai_tools_${n}.te is missing"
    if [[ -f "${POL}/ai_tools_${n}.pp" ]]; then
        pass "group '${n}': .te source and prebuilt .pp both present"
    else
        fail "group '${n}' ships prebuilt but ${POL}/ai_tools_${n}.pp is missing (build it: make -C ${POL} -f /usr/share/selinux/devel/Makefile ai_tools_${n}.pp)"
    fi
done

# Reverse: every optional-group .te on disk (any ai_tools_*.te, excluding the core ai_tools.te)
# is in the registry -- a policy module nobody can reach via enable-group is a mistake.
for te in "${POL}"/ai_tools_*.te; do
    [[ -f "${te}" ]] || continue
    base="$(basename "${te}" .te)"; gname="${base#ai_tools_}"
    if ai_tools_selinux_group_valid "${gname}"; then
        pass "policy module '${base}' is registered"
    else
        fail "policy module '${base}' exists but is not in AI_TOOLS_SELINUX_GROUPS (add it to selinux-groups.lib.sh)"
    fi
done

finish

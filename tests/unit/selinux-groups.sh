#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/selinux-groups.sh
# Unit test for the optional SELinux policy-group registry (selinux-groups.lib.sh), the single
# source shared by ai-tools-admin (loads a shipped group) and selinux/install-selinux.sh
# (compiles one). Pins three things:
#   * the pure accessors + validity predicate -- ai-tools-admin's `selinux groups enable|disable` gate on
#     ai_tools_selinux_group_valid, so an unknown name must be rejected;
#   * registry <-> shipped-set lockstep -- the RPM build and install.sh compile the modules
#     selinux/policy/shipped-modules.sh derives, so a group is shipped exactly when the registry marks
#     it stable, every name on that list has a .te source, every policy source on disk is
#     reachable through the registry or an integration manifest, and no compiled .pp is tracked
#     (the modules are compiled per distribution at build time; a tracked binary is one built on
#     some other host's headers). Asserted against the checkout;
#   * the loaded probe against a full-size module listing -- the one impure accessor, driven over
#     a stubbed `semodule` because its failure mode is a race rather than a wrong answer.
#
# Sources the deployed lib; the lockstep half additionally needs the repo policy sources, so it
# runs only in a checkout. No root risk and no SELinux dependency: the real semodule is never
# called -- the probe section shadows it with a shell function.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
# Read-only (sources a world-readable lib, reads repo files); no root needed, like man.sh.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Installed copy first, then the source tree (the lib does not carry a token substitution, so the two
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

# --- A renamed group's former module name resolves, and only for a renamed group ---
# Both front doors and the selinux %post replace a loaded former module with the group's current
# one; a former name that is itself a current group's module, or is malformed, would make that
# swap unload a live group or pass a bad token to semodule.
if declare -F ai_tools_selinux_group_former_module >/dev/null 2>&1; then
    for g in localipc buildexec; do
        if [[ "$(ai_tools_selinux_group_former_module "${g}")" == "ai_tools_netcore" ]]; then
            pass "the ${g} group records ai_tools_netcore as its former module"
        else
            fail "ai_tools_selinux_group_former_module ${g} -> '$(ai_tools_selinux_group_former_module "${g}")'"
        fi
    done
    # The reverse read is what a swap loads in the old module's place: both groups, in one
    # transaction, or a host loses the half it did not ask for.
    if [[ "$(ai_tools_selinux_groups_from_former_module ai_tools_netcore | sort | tr '\n' ' ')" == "buildexec localipc " ]]; then
        pass "ai_tools_netcore maps back to both localipc and buildexec"
    else
        fail "ai_tools_selinux_groups_from_former_module ai_tools_netcore -> '$(ai_tools_selinux_groups_from_former_module ai_tools_netcore | tr '\n' ' ')'"
    fi
    if ai_tools_selinux_group_former_module tmpmap >/dev/null; then
        fail "tmpmap reports a former module though it was never renamed"
    else
        pass "a group that was never renamed reports no former module"
    fi
    for entry in "${AI_TOOLS_SELINUX_GROUP_FORMER_MODULES[@]}"; do
        fn="${entry%%|*}"; fm="${entry#*|}"
        if ! ai_tools_selinux_group_valid "${fn}"; then
            fail "former-module entry names an unknown group '${fn}'"
        elif [[ ! "${fm}" =~ ^ai_tools_[a-z][a-z0-9]*$ ]]; then
            fail "former module name '${fm}' is not a plain ai_tools_<name> token"
        elif ai_tools_selinux_group_valid "${fm#ai_tools_}"; then
            fail "former module '${fm}' is a CURRENT group's module -- the swap would unload a live group"
        else
            pass "former module '${fm}' -> group '${fn}' is well-formed and does not collide"
        fi
    done
else
    skip "former module accessor" "ai_tools_selinux_group_former_module not defined"
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
    # The experimental predicate the `selinux groups enable` gate keys on must agree with the
    # field: 'stable' groups skip the gate, everything else warns and confirms.
    if [[ "${stability}" == stable ]]; then
        ai_tools_selinux_group_is_experimental "${n}" \
            && fail "group '${n}' is stable but is_experimental returned true"
    else
        ai_tools_selinux_group_is_experimental "${n}" \
            || fail "group '${n}' is '${stability}' but is_experimental returned false"
    fi
done

# --- validity predicate: known names accepted, an unknown name rejected (the `selinux groups enable` gate) ---
for n in "${names[@]}"; do
    ai_tools_selinux_group_valid "${n}" || fail "ai_tools_selinux_group_valid rejected known group '${n}'"
done
if ai_tools_selinux_group_valid "definitely-not-a-group"; then
    fail "ai_tools_selinux_group_valid accepted an unknown group"
else
    pass "ai_tools_selinux_group_valid rejects an unknown group"
fi

# --- The loaded probe survives a full-size module listing (SIGPIPE regression) ---
# ai_tools_selinux_group_loaded reads `semodule -l`, which on a real host is several hundred lines
# -- past a stdio buffer, so the command needs more than one write to deliver it. Written as
# `semodule -l | grep -qx`, grep exits on the match, the still-writing semodule dies of SIGPIPE, and
# the `set -o pipefail` every consumer of this library runs under turns that into 141: the probe
# reports NOT LOADED for a module that IS. An ai_tools* name sorts early, so the match lands in the
# first buffer and the race is lost about half the time -- which is what makes it worth pinning
# rather than reasoning about. `semodule` is stubbed as a shell function (like `systemctl` in
# services.sh and `semanage` in relabel.sh), emitting one printf per line the way a C program with
# a 4 KiB stdio buffer does -- a single-write listing would deliver everything before any reader
# could exit and hide the regression. The probe is driven repeatedly because one passing run
# is no evidence about a race.
semodule() {
    [[ "${1:-}" == -l ]] || return 1
    printf '%s\n' abrt accountsd acct afs aiccu aide ajaxterm ai_tools ai_tools_tmpmap
    local i
    for i in $(seq 1 600); do printf 'filler_module_%s\n' "${i}"; done
}

probe_failures=0
for _ in $(seq 1 25); do
    ai_tools_selinux_group_loaded tmpmap || probe_failures=$(( probe_failures + 1 ))
done
if (( probe_failures == 0 )); then
    pass "group_loaded reports a loaded module every time against a 600-line listing"
else
    fail "group_loaded reported a LOADED module as absent in ${probe_failures}/25 runs (SIGPIPE under pipefail?)"
fi
if ai_tools_selinux_group_loaded definitelynotloaded; then
    fail "group_loaded reported an absent module as loaded"
else
    pass "group_loaded reports an absent module as absent"
fi

# --- Lockstep with the shipped set + the source tree + git (real checkout only) ---
# This half needs the .te SOURCES, the derivation script, and git track-state, all present only
# in a source checkout. A partial deployment skips it: the RPM selftest container copies the
# policy sources without .git, so gate on the git work tree, not the dir. The accessor and
# validity checks above already ran and carry this file's coverage.
POL="${ROOT}/selinux/policy"
SHIPPED="${ROOT}/selinux/policy/shipped-modules.sh"
if ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "registry<->shipped-set lockstep" "not a git work tree (installed or partial deployment)"
    finish; exit
fi

# The derived shipped set, as the spec's %build and install.sh read it. One failing derivation is
# one failing build, so it is a FAIL here rather than a skip.
shipped=()
if [[ -f "${SHIPPED}" ]] && mapfile -t shipped < <(bash "${SHIPPED}") && (( ${#shipped[@]} )); then
    pass "shipped-modules.sh derives a non-empty set: ${shipped[*]}"
else
    fail "shipped-modules.sh did not derive a module set"
fi
is_shipped() { printf '%s\n' "${shipped[@]}" | grep -qx "$1"; }

# The core is on the list unconditionally, and every name on it has the .te source the build
# compiles from -- a derived name with no source is a build that fails at make.
if is_shipped ai_tools; then
    pass "the core ai_tools is on the shipped set"
else
    fail "the core ai_tools is missing from the shipped set"
fi
for m in "${shipped[@]}"; do
    [[ "${m}" =~ ^ai_tools(_[a-z][a-z0-9_]*)?$ ]] || fail "shipped-set entry '${m}' is not an ai_tools_<name> module name"
    [[ -f "${POL}/${m}.te" ]] || fail "shipped module '${m}' has no source ${POL}/${m}.te"
done

# Forward: each registry group has a .te source, and it is on the shipped set exactly when the
# registry marks it stable. An EXPERIMENTAL group is compiled and verified from source on demand
# and must stay off the list, or an unaudited module ships; a STABLE group left off it has no
# module for `selinux groups enable` to load.
for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
    n="$(ai_tools_selinux_group_name "${entry}")"
    [[ -f "${POL}/ai_tools_${n}.te" ]] \
        || fail "group '${n}' in registry but ${POL}/ai_tools_${n}.te is missing"
    if ai_tools_selinux_group_is_experimental "${n}"; then
        if is_shipped "ai_tools_${n}"; then
            fail "experimental group '${n}' is on the shipped set -- an experimental group is source-only"
        else
            pass "experimental group '${n}': .te present, not shipped (source-only)"
        fi
    else
        if is_shipped "ai_tools_${n}"; then
            pass "stable group '${n}': .te source, on the shipped set"
        else
            fail "stable group '${n}' is not on the shipped set -- shipped-modules.sh does not follow the registry"
        fi
    fi
done

# Reverse: every optional .te on disk (any ai_tools_*.te, excluding the core ai_tools.te) is either
# a group in the registry or a LAYOUT MODULE some shipped integration manifest declares
# (selinux_layout_module) -- a policy module nobody can reach through `selinux groups enable` or
# an integration's bootstrap is a mistake. A layout module is on the shipped set like a stable
# group, since the selinux %post loads it for every installed integration that declares it.
layout_modules=()
for manifest in "${ROOT}"/src/usr/local/lib/ai-tools/integrations.d/*.conf; do
    [[ -f "${manifest}" ]] || continue
    m="$(sed -n 's/^[[:space:]]*selinux_layout_module[[:space:]]*=[[:space:]]*\([A-Za-z0-9_]*\).*/\1/p' "${manifest}" | tail -1)"
    [[ -n "${m}" ]] && layout_modules+=( "${m}" )
done
for te in "${POL}"/ai_tools_*.te; do
    [[ -f "${te}" ]] || continue
    base="$(basename "${te}" .te)"; gname="${base#ai_tools_}"
    if ai_tools_selinux_group_valid "${gname}"; then
        pass "policy module '${base}' is registered"
    elif printf '%s\n' "${layout_modules[@]}" | grep -qx "${base}"; then
        if is_shipped "${base}"; then
            pass "layout module '${base}' is declared by an integration manifest and is on the shipped set"
        else
            fail "layout module '${base}' is declared by an integration manifest but is not on the shipped set"
        fi
    else
        fail "policy module '${base}' exists but is neither in AI_TOOLS_SELINUX_GROUPS nor a layout module an integration manifest declares"
    fi
done

# No compiled module is tracked, anywhere in the tree: each is compiled per distribution at
# build time, and a tracked .pp is a binary built on some other host's headers that no review
# can read. A local build leaves them in the working tree, gitignored.
tracked="$(git -C "${ROOT}" ls-files -- '*.pp' 2>/dev/null || true)"
if [[ -z "${tracked}" ]]; then
    pass "no compiled .pp is tracked"
else
    fail "compiled policy modules are tracked -- the build compiles them, git rm: $(tr '\n' ' ' <<<"${tracked}")"
fi

finish

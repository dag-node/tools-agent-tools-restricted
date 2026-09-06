#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/selinux-groups.sh
# Unit test for the optional SELinux policy-group registry (selinux-groups.lib.sh), the single
# source shared by ai-tools-admin (loads a prebuilt group) and selinux/install-selinux.sh
# (compiles one). Pins two things:
#   * the pure accessors + validity predicate -- ai-tools-admin's `selinux groups enable|disable` gate on
#     ai_tools_selinux_group_valid, so an unknown name must be rejected;
#   * registry <-> filesystem lockstep -- because the groups ship PREBUILT, a registry name with
#     no policy source or no committed .pp (or a policy module absent from the registry) means
#     `selinux groups enable` either has no package to load or silently cannot be reached. That drift is the
#     cost of shipping binaries, so it is asserted here against the checkout;
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

# --- Lockstep with the source tree + git (real checkout only) ---
# This half needs the .te SOURCES and git track-state, both present only in a source checkout. A
# partial deployment skips it: the RPM selftest container copies just the prebuilt .pp (not the
# .te/.fc sources, and no .git), so the policy dir exists but the sources do not -- gate on the git
# work tree, not the dir. The accessor and validity checks above already ran and carry this file's
# coverage.
POL="${ROOT}/selinux/policy"
if ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "registry<->filesystem lockstep" "not a git work tree (installed or partial deployment)"
    finish; exit
fi
tracked_pp() { git -C "${ROOT}" ls-files --error-unmatch "selinux/policy/ai_tools_${1}.pp" >/dev/null 2>&1; }

# Forward: each registry group has a .te source. STABLE groups additionally ship a COMMITTED
# prebuilt .pp; EXPERIMENTAL groups must NOT commit one -- they are compiled and verified from
# source on demand, so a committed experimental .pp (or a compiled-but-untracked dev copy) is not
# what ships. Track-state comes from git, so a stray on-disk .pp in a dev tree is not mistaken for
# a shipped one.
for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
    n="$(ai_tools_selinux_group_name "${entry}")"
    [[ -f "${POL}/ai_tools_${n}.te" ]] \
        || fail "group '${n}' in registry but ${POL}/ai_tools_${n}.te is missing"
    if ai_tools_selinux_group_is_experimental "${n}"; then
        if tracked_pp "${n}"; then
            fail "experimental group '${n}' has a committed .pp -- experimental groups are source-only; do not commit ai_tools_${n}.pp"
        else
            pass "experimental group '${n}': .te present, .pp not committed (source-only)"
        fi
    else
        if tracked_pp "${n}"; then
            pass "stable group '${n}': .te source and committed prebuilt .pp"
        else
            fail "stable group '${n}' ships prebuilt but ai_tools_${n}.pp is not committed (build it and git add it)"
        fi
    fi
done

# Reverse: every optional-group .te on disk (any ai_tools_*.te, excluding the core ai_tools.te)
# is in the registry -- a policy module nobody can reach via `selinux groups enable` is a mistake.
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

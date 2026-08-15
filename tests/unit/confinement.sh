#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/confinement.sh
# Unit test for the SELinux launch-gate decision (confinement.lib.sh): the pure
# ai_tools_confinement_verdict that ai-tools-run's fail-closed preflight dispatches on. Drives the
# truth table over the four probed inputs -- getenforce, the matchpathcon-expected label, the
# live label, the manager domain -- with no SELinux host required, so a regression in the gate
# (an inverted condition, a swallowed refusal) fails here rather than reaching production as an
# UNCONFINED launch. Sources the deployed library; needs no privilege of its own. Run as root via
# sudo (suite contract).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/confinement.lib.sh"
section "confinement: SELinux launch-gate verdict truth table (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "confinement verdict" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" || ! declare -F ai_tools_confinement_verdict >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define ai_tools_confinement_verdict"; finish; exit
fi

# expect <token> <rc> <enforce> <module> <want> <have> <mgrdom>: drive the verdict and assert
# BOTH the echoed token and the 0=launch/1=refuse return. The '|| rc=$?' keeps a refusal (rc 1)
# non-fatal under set -e and captures the status.
expect() {
    local exp_tok="$1" exp_rc="$2" enf="$3" mod="$4" want="$5" have="$6" mgr="$7" tok rc
    tok="$(ai_tools_confinement_verdict "${enf}" "${mod}" "${want}" "${have}" "${mgr}")" && rc=0 || rc=$?
    local desc="enf=${enf} mod=${mod} want=${want:-∅} have=${have:-∅} mgr=${mgr:-∅}"
    if [[ "${tok}" == "${exp_tok}" && "${rc}" -eq "${exp_rc}" ]]; then
        pass "${desc} -> ${tok} (rc ${rc})"
    else
        fail "${desc} -> ${tok} (rc ${rc}); expected ${exp_tok} (rc ${exp_rc})"
    fi
}

# ── Gate ENGAGED: enforcing AND the module's file-contexts are active (want=ai_tools_exec_t) ──
# Happy path: correctly labelled entrypoint, a covered manager domain -> launch confined.
expect ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t
expect ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t unconfined_t
# The regression this test exists to catch: entrypoint mislabelled -> no transition -> refuse.
expect mislabel 1 Enforcing yes ai_tools_exec_t lib_t init_t
# An unreadable live label ("") is not ai_tools_exec_t -> refuse (fail closed, not skip).
expect mislabel 1 Enforcing yes ai_tools_exec_t "" init_t
# Manager runs in a domain no domtrans_pattern covers -> transition would not fire -> refuse.
expect manager-domain 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t some_other_t
# The manager-domain signal is ADVISORY: an unreadable ("") domain does not block the launch.
expect ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t ""

# ── Half-installed ENFORCING host: label unresolved but the module IS present -> fail closed ──
# The prod-safety case: module staged/loaded but its file-contexts are not active (a Node
# upgrade before relabel, or matchpathcon missing), so the transition cannot be verified. Refuse
# rather than launch DAC-only. Module presence is what distinguishes this from a DAC-only host.
expect unverifiable 1 Enforcing yes ""      lib_t init_t
expect unverifiable 1 Enforcing yes bin_t   ""    init_t

# ── Gate a DELIBERATE no-op: the SELinux layer is not in force here, so launches proceed ──
# Not enforcing -> gate off, even with a mislabelled entrypoint (permissive / DAC-only boxes).
expect ok 0 Permissive yes ai_tools_exec_t lib_t init_t
expect ok 0 Disabled   yes ai_tools_exec_t lib_t init_t
expect ok 0 unknown    yes ai_tools_exec_t lib_t init_t
# Enforcing, label unresolved, and the module is ABSENT -> the SELinux layer was never installed
# on this host (intentional DAC-only deployment), so launch. This is the sole remaining fail-open,
# gated on the module being absent -- asserted, not incidental.
expect ok 0 Enforcing no "" lib_t init_t

# ── The module-presence probe classifier (ai_tools_confinement_module_present) ──
# ai-tools-run derives the `module` verdict input from `matchpathcon` on a CORE-owned path, because
# it runs as the sandbox account and cannot read the root-only module store (semodule -l). A
# core-owned path resolves to an ai_tools_* type ONLY when the core module's file-contexts are live,
# so this classifier turns that probed type into the yes/no the verdict consumes. The false "no" this
# replaces was the fail-open: on the unresolved-label branch it would launch DAC-only where the
# module is actually loaded.
mp() {  # <expected> <probed-type>
    local got; got="$(ai_tools_confinement_module_present "$2")"
    if [[ "${got}" == "$1" ]]; then pass "module-present(${2:-∅}) -> ${got}"
    else fail "module-present(${2:-∅}) -> ${got}; expected $1"; fi
}
mp yes ai_tools_home_t     # /opt/ai-tools/.config when the core module is loaded
mp yes ai_tools_run_t      # any core-owned ai_tools_* type confirms live file-contexts
mp no  user_home_t         # module absent -> the path keeps its default home type
mp no  bin_t               # any non-ai_tools type -> not present
mp no  ""                  # matchpathcon unavailable / no match -> not present (stays fail-closed via the verdict)

finish

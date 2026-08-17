#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/confinement.lib.sh
# The pure decision behind ai-tools-run's fail-closed SELinux launch preflight: a session that does
# not transition into ai_tools_t runs UNCONFINED, so ai-tools-run checks the transition's inputs
# BEFORE launch (a wrapper cannot observe its successor's post-exec domain). ai-tools-run probes the
# host and calls ai_tools_confinement_verdict; the decision lives here, free of I/O, so it is
# unit-tested apart from the probing (tests/unit/confinement.sh, no SELinux host needed). See
# confinement.rule.md.
#
# Sourced, not executed. Deployed 644 root:root -- no secrets; sourced by ai-tools-run (as the
# sandbox account) and the unit test (as root).
#
# Deploy: install -o root -g root -m 644 \
#     src/usr/local/lib/ai-tools/confinement.lib.sh /usr/local/lib/ai-tools/confinement.lib.sh

[[ -n "${_AI_TOOLS_CONFINEMENT_LIB_LOADED:-}" ]] && return 0
# shellcheck disable=SC2034  # include guard, read on the next source of this lib
_AI_TOOLS_CONFINEMENT_LIB_LOADED=1

# ai_tools_confinement_verdict <enforce> <module> <want> <have> <mgrdom> [require]
# Echo a verdict token and return 0 (launch) or 1 (refuse) from five probed inputs and one
# operator-declared switch:
#   enforce  getenforce output ("Enforcing" when type enforcement is active)
#   module   "yes" when the core module's file-contexts are live (matchpathcon on a core-owned
#            path resolves to an ai_tools_* type), else "no" -- ai-tools-run runs as the sandbox
#            account, which cannot read the root-only module store, so semodule -l is not used
#            (ai_tools_confinement_module_present classifies the probed type; see below)
#   want     label matchpathcon maps the entrypoint to -- "ai_tools_exec_t" once the module's
#            file-contexts are live in the running policy, "" or another type otherwise
#   have     the entrypoint's live label ("" when unreadable)
#   mgrdom   the systemd --user manager's domain ("" when unreadable)
#   require  "yes" when operator.conf's AI_TOOLS_REQUIRE_SELINUX is set -- turns the two DAC-only
#            LAUNCH exits into refusals so an operator who declares confinement mandatory cannot
#            silently start a session unconfined. Default "no" (a 5-arg caller) preserves the
#            DAC-capable behaviour, so intentional DAC-only hosts are untouched.
#
#   enf | mod | want    | have    | mgrdom          | req | verdict              | result
#   ----+-----+---------+---------+-----------------+-----+----------------------+-------
#   no  |  -  |    -    |    -    |        -        | no  | ok                   | launch
#   no  |  -  |    -    |    -    |        -        | yes | require-not-enforcing | REFUSE
#   yes |  -  | exec_t  | exec_t  | init/unconf/""  |  -  | ok                   | launch
#   yes |  -  | exec_t  | exec_t  | other           |  -  | manager-domain       | REFUSE
#   yes |  -  | exec_t  | !exec_t |        -        |  -  | mislabel             | REFUSE
#   yes | yes | !exec_t |    -    |        -        |  -  | unverifiable         | REFUSE
#   yes | no  | !exec_t |    -    |        -        | no  | ok                   | launch
#   yes | no  | !exec_t |    -    |        -        | yes | require-inactive     | REFUSE
#   (a "-" cell is don't-care; "" is empty/unreadable)
#
# Fail-closed once confinement is EXPECTED (enforcing with the module installed). Refusals:
#   - mislabel: the entrypoint is not ai_tools_exec_t, so no transition fires -- relabel it
#     (ai-tools --relabel), usually after a Node upgrade.
#   - manager-domain: the --user manager runs in a domain no ai_tools.te domtrans_pattern covers.
#     Advisory -- an unreadable ("") manager domain does not block. Unchanged under require.
#   - unverifiable: the module is installed but its file-contexts are not live (staged and not
#     reloaded, or matchpathcon missing), so the transition is unconfirmable -- bring SELinux up
#     (install-selinux.sh install), or drop to DAC-only (semodule -r ai_tools / permissive).
#   - require-not-enforcing / require-inactive: only when require=yes -- the host is not enforcing,
#     or enforcing with the module inactive, so a session would launch DAC-only; the operator
#     declared that unacceptable, so it refuses instead. Both are DAC-only LAUNCH exits with
#     require unset.
# An "ok" launches: confined when the transition is verified (enforcing, correct label, covered
# manager); DAC-only when the kernel is not enforcing or the module is absent -- nothing to verify,
# and require is unset (with require=yes those two DAC-only launches become refusals).
# ai_tools_confinement_module_present <matchpathcon-type>
# Classify the `module` verdict input from a probe of a CORE-module-owned path (e.g.
# `matchpathcon /opt/ai-tools/.config` -> ai_tools_home_t): print "yes" when <type> is an
# ai_tools_* type, else "no". A core-owned path resolves to an ai_tools_* type ONLY when the core
# module's file-contexts are live in the running policy, so this is the sandbox-account-readable
# stand-in for reading the root-only module store -- matchpathcon reads the world-readable
# file-contexts and computes from the path string, needing no privilege. An empty or foreign type
# (module absent, or matchpathcon unavailable) -> "no". Pure, like the verdict, so it is unit-tested.
ai_tools_confinement_module_present() {
    if [[ "$1" == ai_tools_* ]]; then printf 'yes'; else printf 'no'; fi
}

ai_tools_confinement_verdict() {
    local enforce="$1" module="$2" want="$3" have="$4" mgrdom="$5" require="${6:-no}"

    if [[ "${enforce}" != "Enforcing" ]]; then
        # DAC-only launch: nothing to verify -- unless the operator declared SELinux mandatory.
        [[ "${require}" == "yes" ]] && { printf 'require-not-enforcing'; return 1; }
        printf 'ok'; return 0
    fi

    if [[ "${want}" == "ai_tools_exec_t" ]]; then
        if [[ "${have}" != "ai_tools_exec_t" ]]; then
            printf 'mislabel'; return 1
        fi
        if [[ -n "${mgrdom}" && "${mgrdom}" != "init_t" && "${mgrdom}" != "unconfined_t" ]]; then
            printf 'manager-domain'; return 1
        fi
        printf 'ok'; return 0
    fi

    # Label unresolved: distinguish a half-installed host (module present -> fail closed) from an
    # intentional DAC-only deployment (module absent -> launch, unless the operator requires SELinux).
    if [[ "${module}" == "yes" ]]; then
        printf 'unverifiable'; return 1
    fi
    [[ "${require}" == "yes" ]] && { printf 'require-inactive'; return 1; }
    printf 'ok'; return 0
}

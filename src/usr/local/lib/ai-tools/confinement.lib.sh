#!/usr/bin/env bash
# /usr/local/lib/ai-tools/confinement.lib.sh
# The pure decision behind claude-run's fail-closed SELinux launch preflight. A session that
# does not transition into ai_tools_t runs UNCONFINED, so claude-run verifies the transition's
# inputs BEFORE launch (a wrapper cannot observe its successor's post-exec domain). It probes the
# inputs from the host -- getenforce, whether the ai_tools module is in the policy store, the
# matchpathcon-expected and live labels of the entrypoint, and the systemd --user manager's
# domain -- and calls ai_tools_confinement_verdict to decide launch vs refuse. The decision is
# kept here, pure and free of I/O, so the probing and the policy are testable apart:
# tests/unit/confinement.sh drives the truth table directly, with no SELinux host required. See
# confinement.rule.md.
#
# Sourced, not executed. Deployed 644 root:root -- it carries no secrets and both principals
# source it: claude-run (as the sandbox account) and the unit test (as root).
#
# Deploy: install -o root -g root -m 644 \
#     src/usr/local/lib/ai-tools/confinement.lib.sh /usr/local/lib/ai-tools/confinement.lib.sh

[[ -n "${_AI_TOOLS_CONFINEMENT_LIB_LOADED:-}" ]] && return 0
# shellcheck disable=SC2034  # include guard, read on the next source of this lib
_AI_TOOLS_CONFINEMENT_LIB_LOADED=1

# ai_tools_confinement_verdict <enforce> <module> <want> <have> <mgrdom>
# Echo a verdict token and return 0 (launch) or 1 (refuse) from five probed inputs:
#   enforce  getenforce output -- "Enforcing" when type enforcement is active
#   module   "yes" when the ai_tools module is in the policy store (semodule -l), else "no"
#   want     label matchpathcon maps the entrypoint to -- "ai_tools_exec_t" once the
#            module's file-contexts are active in the running policy (the module is LIVE); ""
#            or another type otherwise (staged-not-reloaded, or matchpathcon missing)
#   have     the entrypoint's live label -- "" when unreadable
#   mgrdom   the systemd --user manager's SELinux domain -- "" when unreadable
#
# Decision matrix (a "-" cell is don't-care; "" is empty/unreadable):
#
#   enf | mod | want    | have    | mgrdom          | verdict        | result
#   ----+-----+---------+---------+-----------------+----------------+-------
#   no  |  -  |    -    |    -    |        -        | ok             | launch
#   yes |  -  | exec_t  | exec_t  | init/unconf/""  | ok             | launch
#   yes |  -  | exec_t  | exec_t  | other           | manager-domain | REFUSE
#   yes |  -  | exec_t  | !exec_t |        -        | mislabel       | REFUSE
#   yes | yes | !exec_t |    -    |        -        | unverifiable   | REFUSE
#   yes | no  | !exec_t |    -    |        -        | ok             | launch
#
# The verdict is fail-closed once confinement is EXPECTED, i.e. the kernel is enforcing and the
# module is installed on this host:
#   - Not enforcing            -> "ok": the kernel enforces no type policy (permissive/Disabled,
#                                 or no SELinux userspace); DAC is the enforced boundary.
#   - Enforcing, label resolves (want == ai_tools_exec_t, so the module is ACTIVE) -> verify fully:
#       * live label != ai_tools_exec_t         -> "mislabel": no transition fires; the session
#         would run UNCONFINED (the entrypoint needs a relabel after a Node upgrade).
#       * manager domain set and not init_t /
#         unconfined_t (the covered domtrans sources) -> "manager-domain": the transition would
#         not fire. ADVISORY: an unreadable ("") domain does not block (the caller logs it).
#       * otherwise                              -> "ok".
#   - Enforcing, label does NOT resolve, module PRESENT -> "unverifiable": confinement is installed
#     but not active (module staged and not reloaded, or matchpathcon missing), so the transition
#     cannot be confirmed. Refuse rather than launch DAC-only -- a half-installed prod host must
#     not silently drop confinement. Cleared by bringing SELinux up (install-selinux.sh install/
#     relabel, or reboot); an operator who wants DAC-only removes the module (semodule -r ai_tools)
#     or runs permissive, which flips this to "ok".
#   - Enforcing, label does NOT resolve, module ABSENT -> "ok": the SELinux layer is not installed
#     on this host (an intentional DAC-only deployment); nothing to verify.
ai_tools_confinement_verdict() {
    local enforce="$1" module="$2" want="$3" have="$4" mgrdom="$5"

    [[ "${enforce}" != "Enforcing" ]] && { printf 'ok'; return 0; }

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
    # intentional DAC-only deployment (module absent -> launch).
    if [[ "${module}" == "yes" ]]; then
        printf 'unverifiable'; return 1
    fi
    printf 'ok'; return 0
}

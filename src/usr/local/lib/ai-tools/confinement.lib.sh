#!/usr/bin/env bash
# /usr/local/lib/ai-tools/confinement.lib.sh
# The pure decision behind claude-run's fail-closed SELinux launch preflight: a session that does
# not transition into ai_tools_t runs UNCONFINED, so claude-run checks the transition's inputs
# BEFORE launch (a wrapper cannot observe its successor's post-exec domain). claude-run probes the
# host and calls ai_tools_confinement_verdict; the decision lives here, free of I/O, so it is
# unit-tested apart from the probing (tests/unit/confinement.sh, no SELinux host needed). See
# confinement.rule.md.
#
# Sourced, not executed. Deployed 644 root:root -- no secrets; sourced by claude-run (as the
# sandbox account) and the unit test (as root).
#
# Deploy: install -o root -g root -m 644 \
#     src/usr/local/lib/ai-tools/confinement.lib.sh /usr/local/lib/ai-tools/confinement.lib.sh

[[ -n "${_AI_TOOLS_CONFINEMENT_LIB_LOADED:-}" ]] && return 0
# shellcheck disable=SC2034  # include guard, read on the next source of this lib
_AI_TOOLS_CONFINEMENT_LIB_LOADED=1

# ai_tools_confinement_verdict <enforce> <module> <want> <have> <mgrdom>
# Echo a verdict token and return 0 (launch) or 1 (refuse) from five probed inputs:
#   enforce  getenforce output ("Enforcing" when type enforcement is active)
#   module   "yes" when the ai_tools module is in the policy store (semodule -l), else "no"
#   want     label matchpathcon maps the entrypoint to -- "ai_tools_exec_t" once the module's
#            file-contexts are live in the running policy, "" or another type otherwise
#   have     the entrypoint's live label ("" when unreadable)
#   mgrdom   the systemd --user manager's domain ("" when unreadable)
#
#   enf | mod | want    | have    | mgrdom          | verdict        | result
#   ----+-----+---------+---------+-----------------+----------------+-------
#   no  |  -  |    -    |    -    |        -        | ok             | launch
#   yes |  -  | exec_t  | exec_t  | init/unconf/""  | ok             | launch
#   yes |  -  | exec_t  | exec_t  | other           | manager-domain | REFUSE
#   yes |  -  | exec_t  | !exec_t |        -        | mislabel       | REFUSE
#   yes | yes | !exec_t |    -    |        -        | unverifiable   | REFUSE
#   yes | no  | !exec_t |    -    |        -        | ok             | launch
#   (a "-" cell is don't-care; "" is empty/unreadable)
#
# Fail-closed once confinement is EXPECTED (enforcing with the module installed). Refusals:
#   - mislabel: the entrypoint is not ai_tools_exec_t, so no transition fires -- relabel it
#     (ai-tools --relabel), usually after a Node upgrade.
#   - manager-domain: the --user manager runs in a domain no ai_tools.te domtrans_pattern covers.
#     Advisory -- an unreadable ("") manager domain does not block.
#   - unverifiable: the module is installed but its file-contexts are not live (staged and not
#     reloaded, or matchpathcon missing), so the transition is unconfirmable -- bring SELinux up
#     (install-selinux.sh install), or drop to DAC-only (semodule -r ai_tools / permissive).
# An "ok" launches: confined when the transition is verified (enforcing, correct label, covered
# manager); DAC-only when the kernel is not enforcing or the module is absent -- nothing to verify.
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

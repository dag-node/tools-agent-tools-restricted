#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/confinement.lib.sh
# The pure decision behind ai-tools-run's fail-closed SELinux launch preflight: a session that does not transition
# into ai_tools_t runs UNCONFINED, so ai-tools-run checks the transition's inputs BEFORE launch (a wrapper cannot
# observe its successor's post-exec domain). ai-tools-run probes the host and calls ai_tools_confinement_verdict;
# the decision lives here, free of I/O, so it is unit-tested apart from the probing (tests/unit/confinement.sh, no
# SELinux host needed). The one impure function, ai_tools_confinement_read_attestation_records, is the selinuxfs read
# the shim and both status reports share, so the three read the per-domain mode and the Booleans one way. See
# confinement.rule.md.
#
# Sourced, not executed. Deployed 644 root:root -- no secrets; sourced by ai-tools-run (as the sandbox account), the two
# status reports, and the unit test (as root).
#
# Deploy:
#   ```bash
#   install -o root -g root -m 644 \
#       src/usr/local/lib/ai-tools/confinement.lib.sh /usr/local/lib/ai-tools/confinement.lib.sh
#   ```

[[ -n "${_AI_TOOLS_CONFINEMENT_LIB_LOADED:-}" ]] && return 0
# shellcheck disable=SC2034  # include guard, read on the next source of this lib
_AI_TOOLS_CONFINEMENT_LIB_LOADED=1

# The Booleans that widen ai_tools_t through a conditional rule in the base policy, one row per Boolean:
# <name>|<refused|reported>|<what it grants the domain while on>. A refused Boolean on, or unreadable, refuses a launch
# under AI_TOOLS_REQUIRE_SELINUX; a reported one is shown by the status reports and does not gate.
# shellcheck disable=SC2034  # read by ai-tools-run and the two status reports
readonly -a AI_TOOLS_CONFINEMENT_BOOLEANS=(
    "nis_enabled|refused|bind and connect on most port types"
    "domain_can_mmap_files|refused|map on every file type, the access the tmpmap group exists to add"
    "kerberos_enabled|reported|Kerberos and OCSP connects, and connectto on pcscd"
    "authlogin_nsswitch_use_ldap|reported|LDAP connects and connectto on the directory server"
    "fips_mode|reported|execute on prelink_exec_t, and a fifo_file rule on the domain itself"
)

# ai_tools_confinement_list_refused_booleans -- print the refused Boolean names, one per line, in table order.
ai_tools_confinement_list_refused_booleans() {
    local boolean_row
    for boolean_row in "${AI_TOOLS_CONFINEMENT_BOOLEANS[@]}"; do
        [[ "${boolean_row}" == *"|refused|"* ]] && printf '%s\n' "${boolean_row%%|*}"
    done
    return 0
}

# ai_tools_confinement_attestation_verdict <domain-permissive> <boolean-states> Echo ok | permissive | boolean | unknown
# for the attestation inputs a launch under AI_TOOLS_REQUIRE_SELINUX needs beyond the transition: <domain-permissive> is
# "no" when ai_tools_t is enforced per domain, "yes" when it is a permissive domain, "" when unread; <boolean-states> is
# space-separated <name>=on|off pairs. A refused Boolean missing from <boolean-states>, or carrying another value, is
# unread. A definite fault outranks an unread input. Returns 0 for ok, 1 otherwise.
ai_tools_confinement_attestation_verdict() {
    local domain_permissive="$1" boolean_states=" $2 " boolean_name
    local any_input_unread=no any_refused_boolean_on=no
    [[ "${domain_permissive}" == yes ]] && { printf 'permissive'; return 1; }
    [[ "${domain_permissive}" == no ]] || any_input_unread=yes
    while IFS= read -r boolean_name; do
        [[ -n "${boolean_name}" ]] || continue
        if [[ "${boolean_states}" == *" ${boolean_name}=on "* ]]; then
            any_refused_boolean_on=yes
        elif [[ "${boolean_states}" != *" ${boolean_name}=off "* ]]; then
            any_input_unread=yes
        fi
    done < <(ai_tools_confinement_list_refused_booleans)
    [[ "${any_refused_boolean_on}" == yes ]] && { printf 'boolean'; return 1; }
    [[ "${any_input_unread}" == yes ]] && { printf 'unknown'; return 1; }
    printf 'ok'; return 0
}

# ai_tools_confinement_parse_access_decision <kernel-answer> -- print "yes" or "no" for the permissive bit of an answer
# read back from selinuxfs' access transaction file, and nothing for an answer outside its grammar. The kernel writes
# `<allowed> <decided> <auditallow> <auditdeny> <seqno> <flags>`, every field hex but the decimal seqno; bit 0x1
# of <flags> is AVD_FLAGS_PERMISSIVE, which the kernel sets from the source domain's type alone.
ai_tools_confinement_parse_access_decision() {
    local hex_field='[0-9a-fA-F]+'
    local answer_pattern="^${hex_field} ${hex_field} ${hex_field} ${hex_field} [0-9]+ (${hex_field})$"
    [[ "$1" =~ ${answer_pattern} ]] || return 0
    if (( 16#${BASH_REMATCH[1]} & 1 )); then printf 'yes\n'; else printf 'no\n'; fi
}

# ai_tools_confinement_read_attestation_records [selinuxfs-root] Print what selinuxfs reports for ai_tools_t
# and the table's Booleans, as tab-separated records: `permissive<TAB>yes|no`, then `boolean<TAB><name><TAB>on|off`
# per Boolean. Returns 0. <selinuxfs-root> defaults to /sys/fs/selinux; a test passes a fixture tree. Reads the kernel
# interfaces libselinux wraps, so it does not run an interpreter or a library: each Boolean's first field
# in booleans/<name>, and the per-domain mode as the access decision for ai_tools_t signalling itself through the access
# transaction file (a write of `<scon> <tcon> <class> <mask>`, then a read of the answer on the same descriptor).
# A value it cannot read is left out, which the verdict reads as unread, so a missing selinuxfs, a policy without
# the type, or a caller denied the query each narrow toward refusal. Run unconfined (the shim before its transition,
# an operator, root); ai_tools_t is denied every one of these reads.
ai_tools_confinement_read_attestation_records() {
    local selinuxfs_root="${1:-/sys/fs/selinux}"
    local ai_tools_context="unconfined_u:unconfined_r:ai_tools_t:s0"
    local process_class_index="" signal_permission_index="" access_descriptor="" kernel_answer="" domain_permissive
    local boolean_row boolean_name boolean_active_value

    # Each read is grouped so 2>/dev/null also covers the redirection that opens the file, which fails first.
    { read -r process_class_index < "${selinuxfs_root}/class/process/index"; } 2>/dev/null || true
    { read -r signal_permission_index < "${selinuxfs_root}/class/process/perms/signal"; } 2>/dev/null || true
    if [[ "${process_class_index}" =~ ^[0-9]+$ && "${signal_permission_index}" =~ ^[0-9]+$ ]] \
            && (( signal_permission_index >= 1 && signal_permission_index <= 32 )) \
            && { exec {access_descriptor}<>"${selinuxfs_root}/access"; } 2>/dev/null; then
        if { printf '%s %s %u %x' "${ai_tools_context}" "${ai_tools_context}" "${process_class_index}" \
                    "$(( 1 << (signal_permission_index - 1) ))" >&"${access_descriptor}"; } 2>/dev/null; then
            # The answer does not end in a newline, so read reports end of file after assigning it.
            IFS= read -r kernel_answer <&"${access_descriptor}" 2>/dev/null || true
        fi
        exec {access_descriptor}>&-
    fi
    domain_permissive="$(ai_tools_confinement_parse_access_decision "${kernel_answer}")"
    [[ -n "${domain_permissive}" ]] && printf 'permissive\t%s\n' "${domain_permissive}"

    for boolean_row in "${AI_TOOLS_CONFINEMENT_BOOLEANS[@]}"; do
        boolean_name="${boolean_row%%|*}"
        boolean_active_value=""
        { read -r boolean_active_value _ < "${selinuxfs_root}/booleans/${boolean_name}"; } \
            2>/dev/null || true
        case "${boolean_active_value}" in
            1) printf 'boolean\t%s\ton\n'  "${boolean_name}" ;;
            0) printf 'boolean\t%s\toff\n' "${boolean_name}" ;;
        esac
    done
    return 0
}

# ai_tools_confinement_parse_attestation_records -- read ai_tools_confinement_read_attestation_records' output on stdin
# and print the two verdict inputs as `<domain-permissive>|<boolean-states>`. The separator is `|` because `read`
# collapses a leading empty field split on a tab, which would move the Booleans into the permissive slot. A record
# outside that grammar is dropped, so it reads as unread rather than as a value.
ai_tools_confinement_parse_attestation_records() {
    local record_kind record_first_field record_second_field domain_permissive="" boolean_states=""
    while IFS=$'\t' read -r record_kind record_first_field record_second_field; do
        case "${record_kind}" in
            permissive)
                [[ "${record_first_field}" == yes || "${record_first_field}" == no ]] \
                    && domain_permissive="${record_first_field}" ;;
            boolean)
                [[ "${record_first_field}" =~ ^[a-z0-9_]+$ \
                   && ( "${record_second_field}" == on || "${record_second_field}" == off ) ]] \
                    && boolean_states+="${boolean_states:+ }${record_first_field}=${record_second_field}" ;;
        esac
    done
    printf '%s|%s\n' "${domain_permissive}" "${boolean_states}"
}

# ai_tools_confinement_verdict <selinux-mode> <module-present> <expected-label> <actual-label> <manager-domain>
#                              [require-selinux] [domain-permissive] [boolean-states]
# Echo a verdict token and return 0 (launch) or 1 (refuse) from the probed inputs and one operator-declared switch:
#   selinux-mode       getenforce output ("Enforcing" when type enforcement is active; "" when getenforce did not run)
#   module-present     "yes" when the core module's file-contexts are live, as classified by
#                      ai_tools_confinement_module_present, "no" when they are not, "" when matchpathcon did not run
#   expected-label     label matchpathcon maps the entrypoint to -- "ai_tools_exec_t" once the module's
#                      file-contexts are live in the running policy, "" or another type otherwise
#   actual-label       the entrypoint's live label ("" when unreadable)
#   manager-domain     the systemd --user manager's domain ("" when unreadable)
#   require-selinux    "yes" when operator.conf's AI_TOOLS_REQUIRE_SELINUX is set. Default "no" leaves intentional
#                      DAC-only hosts untouched, and the two inputs after it are read only under "yes".
#   domain-permissive  the per-domain mode, as ai_tools_confinement_attestation_verdict takes it
#   boolean-states     the refused Booleans, as ai_tools_confinement_attestation_verdict takes them
#
#   mode | module | expected | actual  |    manager     | req | attestation |        verdict        | result
#   -----+--------+----------+---------+----------------+-----+-------------+-----------------------+--------
#   ""   |   -    |    -     |    -    |       -        | yes |      -      | require-unattested    | refuse
#   no   |   -    |    -     |    -    |       -        | no  |      -      | ok                    | launch
#   no   |   -    |    -     |    -    |       -        | yes |      -      | require-not-enforcing | refuse
#   yes  |   -    |  exec_t  | exec_t  | init/unconf/"" | no  |      -      | ok                    | launch
#   yes  |   -    |  exec_t  | exec_t  | other          |  -  |      -      | manager-domain        | refuse
#   yes  |   -    |  exec_t  | exec_t  | init/unconf    | yes | ok          | ok                    | launch
#   yes  |   -    |  exec_t  | exec_t  | init/unconf/"" | yes | permissive  | require-permissive    | refuse
#   yes  |   -    |  exec_t  | exec_t  | init/unconf/"" | yes | boolean     | require-boolean       | refuse
#   yes  |   -    |  exec_t  | exec_t  | ""             | yes | ok/unknown  | require-unattested    | refuse
#   yes  |   -    |  exec_t  | exec_t  | init/unconf    | yes | unknown     | require-unattested    | refuse
#   yes  |   -    |  exec_t  | !exec_t |       -        |  -  |      -      | mislabel              | refuse
#   yes  |  yes   | !exec_t  |    -    |       -        |  -  |      -      | unverifiable          | refuse
#   yes  | no/""  | !exec_t  |    -    |       -        | no  |      -      | ok                    | launch
#   yes  |  no    | !exec_t  |    -    |       -        | yes |      -      | require-inactive      | refuse
#   yes  |  ""    | !exec_t  |    -    |       -        | yes |      -      | require-unattested    | refuse
#   (a "-" cell is don't-care; "" is empty/unreadable; mode "no" is any value other than Enforcing and "")
#
# Fail-closed once confinement is EXPECTED (enforcing with the module installed). What each refusal means,
# and the remedy each one prints, are in confinement.rule.md and in ai-tools-run's refusal text. Two properties
# of the table are easy to miss reading it: manager-domain is ADVISORY without require, so an unreadable ("") domain
# does not block there; and every require-* token replaces a launch the same inputs take without require.
#
# ai_tools_confinement_module_present <matchpathcon-type> Classify the `module-present` verdict input from a probe
# of a CORE-module-owned path (e.g. `matchpathcon /opt/ai-tools/.config` -> ai_tools_home_t): print "yes" when <type> is
# an ai_tools_* type, else "no". A core-owned path resolves to an ai_tools_* type ONLY when the core module's
# file-contexts are live in the running policy, so this is the sandbox-account-readable stand-in for reading
# the root-only module store, which ai-tools-run cannot read from the sandbox account -- matchpathcon reads
# the world-readable file-contexts and computes from the path string, needing no privilege. An empty or foreign type
# (module absent, or matchpathcon unavailable) -> "no". Pure, like the verdict, so it is unit-tested.
ai_tools_confinement_module_present() {
    if [[ "$1" == ai_tools_* ]]; then printf 'yes'; else printf 'no'; fi
}

ai_tools_confinement_verdict() {
    local selinux_mode="$1" module_present="$2" expected_label="$3" actual_label="$4" manager_domain="$5"
    local require_selinux="${6:-no}" domain_permissive="${7:-}" boolean_states="${8:-}" attestation_verdict

    if [[ "${selinux_mode}" != "Enforcing" ]]; then
        # DAC-only launch: no transition to verify -- unless the operator declared SELinux mandatory.
        if [[ "${require_selinux}" == "yes" ]]; then
            [[ -z "${selinux_mode}" ]] && { printf 'require-unattested'; return 1; }
            printf 'require-not-enforcing'; return 1
        fi
        printf 'ok'; return 0
    fi

    if [[ "${expected_label}" == "ai_tools_exec_t" ]]; then
        if [[ "${actual_label}" != "ai_tools_exec_t" ]]; then
            printf 'mislabel'; return 1
        fi
        if [[ -n "${manager_domain}" && "${manager_domain}" != "init_t" && "${manager_domain}" != "unconfined_t" ]]; then
            printf 'manager-domain'; return 1
        fi
        [[ "${require_selinux}" == "yes" ]] || { printf 'ok'; return 0; }
        attestation_verdict="$(ai_tools_confinement_attestation_verdict "${domain_permissive}" "${boolean_states}")" \
            || true
        case "${attestation_verdict}" in
            permissive) printf 'require-permissive'; return 1 ;;
            boolean)    printf 'require-boolean'; return 1 ;;
            ok)         [[ -n "${manager_domain}" ]] && { printf 'ok'; return 0; } ;;
        esac
        printf 'require-unattested'; return 1
    fi

    # Label unresolved: distinguish a half-installed host (module present -> fail closed) from an intentional DAC-only
    # deployment (module absent -> launch, unless the operator requires SELinux).
    if [[ "${module_present}" == "yes" ]]; then
        printf 'unverifiable'; return 1
    fi
    if [[ "${require_selinux}" == "yes" ]]; then
        [[ -z "${module_present}" ]] && { printf 'require-unattested'; return 1; }
        printf 'require-inactive'; return 1
    fi
    printf 'ok'; return 0
}

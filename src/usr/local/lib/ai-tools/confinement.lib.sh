#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/confinement.lib.sh
# The decision behind ai-tools-run's fail-closed SELinux launch preflight: a session that does not transition
# into ai_tools_t runs UNCONFINED, so ai-tools-run checks the transition's inputs BEFORE launch (a wrapper cannot
# observe its successor's post-exec domain). ai-tools-run probes the host and calls ai_tools_confinement_verdict;
# the decision is free of I/O, so it is unit-tested apart from the probing (tests/unit/confinement.sh, no SELinux host
# needed). The functions that read -- the operator.conf readers and the selinuxfs reader -- are shared by the shim
# and the status reports through ai_tools_confinement_read_attestation_inputs, so every consumer reads one set of inputs
# one way. See confinement.rule.md.
#
# Sourced, not executed. Deployed 644 root:root -- no secrets; sourced by ai-tools-run (as the sandbox account),
# the status reports, and the unit test (as root).
#
# Deploy:
#   ```bash
#   install -o root -g root -m 644 \
#       src/usr/local/lib/ai-tools/confinement.lib.sh /usr/local/lib/ai-tools/confinement.lib.sh
#   ```

[[ -n "${_AI_TOOLS_CONFINEMENT_LIB_LOADED:-}" ]] && return 0
# shellcheck disable=SC2034  # include guard, read on the next source of this lib
_AI_TOOLS_CONFINEMENT_LIB_LOADED=1

# The Booleans that gate rules for ai_tools_t in the base policy, one row per Boolean, as `sesearch -A -s ai_tools_t`
# lists them on the supported policy: <name>|<gating|advisory>|<opening value>|<what the open rules grant>. The opening
# value is the one under which the conditional rules apply: `on` for a true branch, `off` for a false one. A gating row
# is one the stock policy keeps closed, so opening it is a change on the host: by default a launch
# under AI_TOOLS_REQUIRE_SELINUX requires it at its other value. An advisory row is open by default or supported by this
# project, and the status reports show it. AI_TOOLS_SELINUX_BOOLEANS replaces a default requirement or adds one
# (ai_tools_confinement_resolve_required_boolean_values).
# shellcheck disable=SC2034  # read by ai-tools-run and the two status reports
readonly -a AI_TOOLS_CONFINEMENT_BOOLEANS=(
    "nis_enabled|gating|on|bind and connect on most port types"
    "domain_can_mmap_files|gating|on|map on every file type, the access the tmpmap group exists to add"
    "domain_can_write_kmsg|gating|on|writes to the kernel log device, kmsg"
    "kerberos_enabled|advisory|on|Kerberos and OCSP connects, and connectto on pcscd"
    "authlogin_nsswitch_use_ldap|advisory|on|LDAP connects and connectto on the directory server"
    "fips_mode|advisory|on|execute on prelink_exec_t, and a fifo_file rule on the domain itself"
    "domain_kernel_load_modules|advisory|on|a request that the kernel load a module"
    "nscd_use_shm|advisory|on|use of the nscd shared memory"
    "domain_fd_use|advisory|on|use of file descriptors other domains hold"
    "deny_ptrace|advisory|off|ptrace, which this Boolean denies while on"
)

# ai_tools_confinement_list_known_booleans -- print the registry as tab-separated rows,
# `<name><TAB><gating|advisory><TAB><on|off><TAB><grants>`, in registry order.
ai_tools_confinement_list_known_booleans() {
    local boolean_row boolean_name boolean_class opening_value boolean_grants
    for boolean_row in "${AI_TOOLS_CONFINEMENT_BOOLEANS[@]}"; do
        IFS='|' read -r boolean_name boolean_class opening_value boolean_grants <<< "${boolean_row}"
        printf '%s\t%s\t%s\t%s\n' "${boolean_name}" "${boolean_class}" "${opening_value}" "${boolean_grants}"
    done
}

# ai_tools_confinement_read_declared_boolean_values <operator-conf> -- print the Boolean values <operator-conf> declares
# in AI_TOOLS_SELINUX_BOOLEANS as one space-separated `<name>=<on|off>` list, in the order written, read
# through ai_tools_conf_pair_list and only while the file passes ai_tools_conf_is_trusted, so the session can neither
# write nor remove a declaration. Returns 0 when the key is present and every entry was read, 1 when the declaration
# does not apply (an absent key, an untrusted file, or conf.lib.sh not loaded), and 2 when the key is present
# and an entry was malformed or the list invalid, printing the entries it could read.
ai_tools_confinement_read_declared_boolean_values() {
    local IFS=$' \t\n'   # the list below joins on a space whatever IFS the caller set (ai-tools: newline, tab)
    local operator_conf="$1" declared_boolean_values=""
    local -a declared_entries=()
    if ! declare -F ai_tools_conf_is_trusted >/dev/null 2>&1 || ! declare -F ai_tools_conf_pair_list >/dev/null 2>&1
    then
        return 1
    fi
    ai_tools_conf_is_trusted "${operator_conf}" 2>/dev/null || return 1
    ai_tools_conf_pair_list declared_entries "${operator_conf}" AI_TOOLS_SELINUX_BOOLEANS on off || return 1
    declared_boolean_values="${declared_entries[*]+"${declared_entries[*]}"}"
    printf '%s\n' "${declared_boolean_values}"
    (( ${_ai_tools_conf_pair_list_rejected_count:-0} == 0 && ${_ai_tools_conf_list_invalid:-0} == 0 )) || return 2
    return 0
}

# ai_tools_confinement_resolve_required_boolean_values [declaration-state] [declared-boolean-values] -- print
# the Boolean values a launch under AI_TOOLS_REQUIRE_SELINUX requires, as one space-separated `<name>=<value>` list.
# A present declaration (<declaration-state> `present`) is the whole requirement, exactly as AI_TOOLS_SELINUX_BOOLEANS
# lists it, as every list in operator.conf replaces its default. With no declaration (`absent`, or no argument)
# the requirement is each gating registry row at the value that keeps its rules closed. A malformed declaration
# (`malformed`) requires the defaults and the entries read, plus `AI_TOOLS_SELINUX_BOOLEANS=malformed`, which no reading
# satisfies, so the launch refuses until the entry is fixed: a wrong entry costs a launch, never a requirement.
ai_tools_confinement_resolve_required_boolean_values() {
    local IFS=$' \t\n'   # the lists below split on spaces whatever IFS the caller set (ai-tools: newline, tab)
    local declaration_state="${1:-absent}" declared_boolean_values=" ${2:-} " boolean_name boolean_class opening_value
    local declared_entry required_boolean_values=""
    if [[ "${declaration_state}" == present ]]; then
        for declared_entry in ${declared_boolean_values}; do
            required_boolean_values+="${required_boolean_values:+ }${declared_entry}"
        done
        printf '%s\n' "${required_boolean_values}"
        return 0
    fi
    while IFS=$'\t' read -r boolean_name boolean_class opening_value _; do
        [[ "${boolean_class}" == gating && "${declared_boolean_values}" != *" ${boolean_name}="* ]] || continue
        if [[ "${opening_value}" == on ]]; then
            required_boolean_values+="${required_boolean_values:+ }${boolean_name}=off"
        else
            required_boolean_values+="${required_boolean_values:+ }${boolean_name}=on"
        fi
    done < <(ai_tools_confinement_list_known_booleans)
    if [[ "${declaration_state}" == malformed ]]; then
        for declared_entry in ${declared_boolean_values}; do
            required_boolean_values+="${required_boolean_values:+ }${declared_entry}"
        done
        required_boolean_values+="${required_boolean_values:+ }AI_TOOLS_SELINUX_BOOLEANS=malformed"
    fi
    printf '%s\n' "${required_boolean_values}"
}

# ai_tools_confinement_read_boolean_requirement <operator-conf> -- print, on three lines, the declaration state
# (`present`, `absent` or `malformed`), the required values ai_tools_confinement_resolve_required_boolean_values gives
# for <operator-conf>'s AI_TOOLS_SELINUX_BOOLEANS, and the declared values that list holds (empty when absent).
ai_tools_confinement_read_boolean_requirement() {
    local declared_boolean_values declaration_status=0 declaration_state
    declared_boolean_values="$(ai_tools_confinement_read_declared_boolean_values "$1")" || declaration_status=$?
    case "${declaration_status}" in
        0) declaration_state=present ;;
        2) declaration_state=malformed ;;
        *) declaration_state=absent; declared_boolean_values="" ;;
    esac
    printf '%s\n' "${declaration_state}"
    ai_tools_confinement_resolve_required_boolean_values "${declaration_state}" "${declared_boolean_values}"
    printf '%s\n' "${declared_boolean_values}"
}

# ai_tools_confinement_attestation_verdict <domain-permissive> <current-boolean-values> [required-boolean-values] Echo
# ok | permissive | boolean | unknown for the attestation inputs a launch under AI_TOOLS_REQUIRE_SELINUX needs beyond
# the transition: <domain-permissive> is "no" when ai_tools_t is enforced per domain, "yes" when it is a permissive
# domain, "" when unread; <current-boolean-values> is space-separated <name>=on|off pairs; <required-boolean-values> is
# the `<name>=<on|off>` set a launch requires (ai_tools_confinement_resolve_required_boolean_values), the table's
# defaults when absent. A Boolean at another value than the one required is a fault; one missing
# from <current-boolean-values>, or carrying another value, is unread. A definite fault outranks an unread input.
# Returns 0 for ok, 1 otherwise.
ai_tools_confinement_attestation_verdict() {
    local IFS=$' \t\n'   # the lists below split on spaces whatever IFS the caller set (ai-tools: newline, tab)
    local domain_permissive="$1" current_boolean_values=" $2 " required_boolean_values="${3-}"
    local required_entry boolean_name required_value other_value any_input_unread=no any_boolean_differs=no
    [[ $# -ge 3 ]] || required_boolean_values="$(ai_tools_confinement_resolve_required_boolean_values "")"
    [[ "${domain_permissive}" == yes ]] && { printf 'permissive'; return 1; }
    [[ "${domain_permissive}" == no ]] || any_input_unread=yes
    for required_entry in ${required_boolean_values}; do
        boolean_name="${required_entry%%=*}"; required_value="${required_entry#*=}"
        if [[ "${required_value}" != on && "${required_value}" != off ]]; then any_input_unread=yes; continue; fi
        if [[ "${required_value}" == on ]]; then other_value=off; else other_value=on; fi
        if [[ "${current_boolean_values}" == *" ${boolean_name}=${other_value} "* ]]; then
            any_boolean_differs=yes
        elif [[ "${current_boolean_values}" != *" ${boolean_name}=${required_value} "* ]]; then
            any_input_unread=yes
        fi
    done
    [[ "${any_boolean_differs}" == yes ]] && { printf 'boolean'; return 1; }
    [[ "${any_input_unread}" == yes ]] && { printf 'unknown'; return 1; }
    printf 'ok'; return 0
}

# ai_tools_confinement_parse_access_decision <kernel-answer> -- print "yes" or "no" for the permissive bit of an answer
# read back from selinuxfs' access transaction file, and prints nothing for an answer outside its grammar. The kernel
# writes `<allowed> <decided> <auditallow> <auditdeny> <seqno> <flags>`, every field hex but the decimal seqno; bit 0x1
# of <flags> is AVD_FLAGS_PERMISSIVE, which the kernel sets from the source domain's type alone.
ai_tools_confinement_parse_access_decision() {
    local hex_field='[0-9a-fA-F]+'
    local answer_pattern="^${hex_field} ${hex_field} ${hex_field} ${hex_field} [0-9]+ (${hex_field})$"
    [[ "$1" =~ ${answer_pattern} ]] || return 0
    if (( 16#${BASH_REMATCH[1]} & 1 )); then printf 'yes\n'; else printf 'no\n'; fi
}

# ai_tools_confinement_read_attestation_records [selinuxfs-root] [boolean-name...] Print what selinuxfs reports
# for ai_tools_t, the table's Booleans and each further <boolean-name>, as tab-separated records:
# `permissive<TAB>yes|no`, then `boolean<TAB><name><TAB>on|off` per Boolean. Returns 0. <selinuxfs-root> defaults
# to /sys/fs/selinux; a test passes a fixture tree. Reads the kernel interfaces libselinux wraps, so it does not run
# an interpreter or a library: each Boolean's first field in booleans/<name>, and the per-domain mode as the access
# decision for ai_tools_t signalling itself through the access transaction file (a write
# of `<scon> <tcon> <class> <mask>`, then a read of the answer on the same descriptor). A value it cannot read is left
# out, which the verdict reads as unread, so a missing selinuxfs, a policy without the type, or a caller denied
# the query each narrow toward refusal. Run unconfined (the shim before its transition, an operator, root); ai_tools_t
# is denied every one of these reads.
ai_tools_confinement_read_attestation_records() {
    local IFS=$' \t\n'   # the name list below joins on a space whatever IFS the caller set (ai-tools: newline, tab)
    local selinuxfs_root="${1:-/sys/fs/selinux}"
    local ai_tools_context="unconfined_u:unconfined_r:ai_tools_t:s0"
    local process_class_index="" signal_permission_index="" access_descriptor="" kernel_answer="" domain_permissive
    local boolean_name boolean_active_value
    local -a boolean_names=()
    [[ $# -gt 0 ]] && shift
    while IFS=$'\t' read -r boolean_name _; do boolean_names+=( "${boolean_name}" ); done \
        < <(ai_tools_confinement_list_known_booleans)
    for boolean_name in "$@"; do
        # A further name becomes a path component under selinuxfs, so it is read only as a name the pair grammar admits
        # -- and not at all where conf.lib.sh is not loaded -- and a name the table holds is read once.
        declare -F ai_tools_conf_pair_name_valid >/dev/null 2>&1 && ai_tools_conf_pair_name_valid "${boolean_name}" \
            && [[ " ${boolean_names[*]} " != *" ${boolean_name} "* ]] && boolean_names+=( "${boolean_name}" )
    done

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

    for boolean_name in "${boolean_names[@]}"; do
        boolean_active_value=""
        # IFS is pinned: the file holds `<active> <pending>`, and a caller sourcing this with IFS=$'\n\t' (ai-tools)
        # would otherwise read both fields as one value.
        { IFS=' ' read -r boolean_active_value _ < "${selinuxfs_root}/booleans/${boolean_name}"; } \
            2>/dev/null || true
        case "${boolean_active_value}" in
            1) printf 'boolean\t%s\ton\n'  "${boolean_name}" ;;
            0) printf 'boolean\t%s\toff\n' "${boolean_name}" ;;
        esac
    done
    return 0
}

# ai_tools_confinement_parse_attestation_records -- read ai_tools_confinement_read_attestation_records' output on stdin
# and print the two verdict inputs as `<domain-permissive>|<current-boolean-values>`. The separator is `|` because
# `read` collapses a leading empty field split on a tab, which would move the Booleans into the permissive slot.
# A record outside that grammar is dropped, so it reads as unread rather than as a value.
ai_tools_confinement_parse_attestation_records() {
    local record_kind record_first_field record_second_field domain_permissive="" current_boolean_values=""
    while IFS=$'\t' read -r record_kind record_first_field record_second_field; do
        case "${record_kind}" in
            permissive)
                [[ "${record_first_field}" == yes || "${record_first_field}" == no ]] \
                    && domain_permissive="${record_first_field}" ;;
            boolean)
                [[ "${record_first_field}" =~ ^[a-z0-9_]+$ \
                   && ( "${record_second_field}" == on || "${record_second_field}" == off ) ]] \
                    && current_boolean_values+="${current_boolean_values:+ }${record_first_field}=${record_second_field}" ;;
        esac
    done
    printf '%s|%s\n' "${domain_permissive}" "${current_boolean_values}"
}

# ai_tools_confinement_is_selinux_required <operator-conf> -- return 1 when <operator-conf> passes
# ai_tools_conf_is_trusted and sets AI_TOOLS_REQUIRE_SELINUX to a no value (ai_tools_conf_no), 0 otherwise:
# the requirement is the default, so an absent key, a yes value, a value in neither set (reported), an untrusted
# or absent file, and conf.lib.sh not loaded each leave it in force. Every way the read can fail therefore resolves
# to the requirement, the direction every other launch predicate takes (confinement.rule.md).
ai_tools_confinement_is_selinux_required() {
    if ! declare -F ai_tools_conf_is_trusted >/dev/null 2>&1 || ! declare -F ai_tools_conf_no >/dev/null 2>&1; then
        return 0
    fi
    ai_tools_conf_is_trusted "$1" 2>/dev/null || return 0
    ! ai_tools_conf_no "$1" AI_TOOLS_REQUIRE_SELINUX
}

# ai_tools_confinement_read_attestation_inputs <operator-conf> [selinuxfs-root] -- print, on one `|`-separated line,
# every input the attestation verdict and the status reports take for <operator-conf>:
#   <declaration-state>|<required-boolean-values>|<declared-boolean-values>|<domain-permissive>|<current-boolean-values>
# The first three are ai_tools_confinement_read_boolean_requirement's record; the last two are
# ai_tools_confinement_read_attestation_records' reading of <selinuxfs-root>, which reads each declared Boolean beside
# the registry's. The shim and both status reports read through this one function, so the three cannot read a different
# set. `|` is the separator because `read` collapses an empty field split on a tab.
ai_tools_confinement_read_attestation_inputs() {
    local IFS=$' \t\n'   # the name list below splits on spaces whatever IFS the caller set (ai-tools: newline, tab)
    local operator_conf="$1" selinuxfs_root="${2:-/sys/fs/selinux}"
    local declaration_state required_boolean_values declared_boolean_values domain_permissive current_boolean_values
    local declared_entry
    local -a declared_boolean_names=()
    { read -r declaration_state; IFS= read -r required_boolean_values; IFS= read -r declared_boolean_values; } \
        < <(ai_tools_confinement_read_boolean_requirement "${operator_conf}")
    for declared_entry in ${declared_boolean_values}; do declared_boolean_names+=( "${declared_entry%%=*}" ); done
    IFS='|' read -r domain_permissive current_boolean_values \
        < <(ai_tools_confinement_read_attestation_records "${selinuxfs_root}" \
                "${declared_boolean_names[@]+"${declared_boolean_names[@]}"}" \
            | ai_tools_confinement_parse_attestation_records) || true
    printf '%s|%s|%s|%s|%s\n' "${declaration_state}" "${required_boolean_values}" "${declared_boolean_values}" \
        "${domain_permissive}" "${current_boolean_values}"
}

# ai_tools_confinement_list_unread_inputs <required-boolean-values> <current-boolean-values> <domain-permissive> --
# print one `<kind><TAB><description>` row per attestation input the verdict reads as unread, so a refusal names each
# and prints the remedy its kind takes: `selinuxfs` for the per-domain mode, `boolean` for a required Boolean
# the reading lacks, `declaration` for the malformed marker. Prints nothing when every input was read.
ai_tools_confinement_list_unread_inputs() {
    local IFS=$' \t\n'   # the list below splits on spaces whatever IFS the caller set (ai-tools: newline, tab)
    local required_boolean_values="$1" current_boolean_values=" $2 " domain_permissive="$3" required_entry
    [[ "${domain_permissive}" == yes || "${domain_permissive}" == no ]] \
        || printf 'selinuxfs\twhether ai_tools_t is a permissive domain (/sys/fs/selinux/access)\n'
    for required_entry in ${required_boolean_values}; do
        if [[ "${required_entry}" == AI_TOOLS_SELINUX_BOOLEANS=malformed ]]; then
            printf 'declaration\tAI_TOOLS_SELINUX_BOOLEANS in operator.conf (an entry is not <boolean>=on or <boolean>=off)\n'
        elif [[ "${current_boolean_values}" != *" ${required_entry%%=*}="* ]]; then
            printf 'boolean\tthe %s Boolean\n' "${required_entry%%=*}"
        fi
    done
}

# ai_tools_confinement_list_attestation_rows <domain-permissive> <current-boolean-values> <required-boolean-values>
#                                            <declared-boolean-values>
# Print one tab-separated row per reading the status reports render: the per-domain mode, then every registry Boolean,
# then each required Boolean the registry does not hold. A value the reader could not read is `unread`, a column with no
# value `-`:
#   domain<TAB><yes|no|unread><TAB><remedy|->
#   boolean<TAB><name><TAB><classification><TAB><on|off|unread><TAB><required value|->
#          <TAB><built-in|operator.conf|-><TAB><opening value|-><TAB><grants><TAB><remedy|->
# The classification is ai_tools_confinement_classify_boolean_row's; the remedy is the command that puts a `differs` row
# or a permissive domain right, so every report prints the same one.
ai_tools_confinement_list_attestation_rows() {
    local IFS=$' \t\n'   # the lists below split on spaces whatever IFS the caller set (ai-tools: newline, tab)
    local domain_permissive="$1" current_boolean_values="$2" required_boolean_values=" $3 "
    local declared_boolean_values=" $4 " boolean_name opening_value boolean_grants required_entry
    local registry_boolean_names=" " domain_remedy=-
    [[ "${domain_permissive}" == yes ]] && domain_remedy="sudo semanage permissive -d ai_tools_t"
    printf 'domain\t%s\t%s\n' "${domain_permissive:-unread}" "${domain_remedy}"
    while IFS=$'\t' read -r boolean_name _ opening_value boolean_grants; do
        registry_boolean_names+="${boolean_name} "
        _ai_tools_confinement_print_boolean_row "${boolean_name}" "${opening_value}" "${boolean_grants}" \
            "${current_boolean_values}" "${required_boolean_values}" "${declared_boolean_values}"
    done < <(ai_tools_confinement_list_known_booleans)
    for required_entry in ${required_boolean_values}; do
        boolean_name="${required_entry%%=*}"
        [[ "${registry_boolean_names}" == *" ${boolean_name} "* ]] && continue
        if [[ "${required_entry#*=}" == malformed ]]; then
            _ai_tools_confinement_print_boolean_row "${boolean_name}" - "an entry that is not <boolean>=on or <boolean>=off" \
                "${current_boolean_values}" "${required_boolean_values}" " ${boolean_name}=malformed "
        else
            _ai_tools_confinement_print_boolean_row "${boolean_name}" - "declared in AI_TOOLS_SELINUX_BOOLEANS" \
                "${current_boolean_values}" "${required_boolean_values}" "${declared_boolean_values}"
        fi
    done
}

# _ai_tools_confinement_print_boolean_row <name> <opening value|-> <grants> <current> <required> <declared> -- print one
# `boolean` row of ai_tools_confinement_list_attestation_rows.
_ai_tools_confinement_print_boolean_row() {
    local boolean_name="$1" opening_value="$2" boolean_grants="$3" current_boolean_values=" $4 "
    local required_boolean_values=" $5 " declared_boolean_values=" $6 " boolean_state required_value=- origin=-
    local classification remedy=-
    case "${current_boolean_values}" in
        *" ${boolean_name}=on "*)  boolean_state=on ;;
        *" ${boolean_name}=off "*) boolean_state=off ;;
        *)                         boolean_state=unread ;;
    esac
    case "${required_boolean_values}" in
        *" ${boolean_name}=on "*)        required_value=on ;;
        *" ${boolean_name}=off "*)       required_value=off ;;
        *" ${boolean_name}=malformed "*) required_value=malformed ;;
    esac
    if [[ "${required_value}" != - ]]; then
        origin=built-in
        [[ "${declared_boolean_values}" == *" ${boolean_name}="* ]] && origin=operator.conf
    fi
    classification="$(ai_tools_confinement_classify_boolean_row "${boolean_state}" "${required_value}" "${opening_value}")"
    [[ "${classification}" == differs ]] && remedy="sudo setsebool -P ${boolean_name}=${required_value}"
    printf 'boolean\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${boolean_name}" "${classification}" "${boolean_state}" \
        "${required_value}" "${origin}" "${opening_value}" "${boolean_grants}" "${remedy}"
}

# ai_tools_confinement_list_attestation_report <operator-conf> [selinuxfs-root] -- print the whole reading a status
# report renders: ai_tools_confinement_list_attestation_rows over ai_tools_confinement_read_attestation_inputs, then one
# closing row, `verdict<TAB><ok|permissive|boolean|unknown><TAB><yes|no>`: ai_tools_confinement_attestation_verdict's
# token, and whether AI_TOOLS_REQUIRE_SELINUX makes a token other than `ok` refuse every launch. A report renders
# the rows in its own form and reads the exit status it owes off the verdict row, so the reports and the shim agree
# on every value.
ai_tools_confinement_list_attestation_report() {
    local operator_conf="$1" selinuxfs_root="${2:-/sys/fs/selinux}" selinux_required=no attestation_verdict
    local declaration_state required_boolean_values declared_boolean_values domain_permissive current_boolean_values
    IFS='|' read -r declaration_state required_boolean_values declared_boolean_values domain_permissive \
            current_boolean_values \
        < <(ai_tools_confinement_read_attestation_inputs "${operator_conf}" "${selinuxfs_root}") || true
    ai_tools_confinement_list_attestation_rows "${domain_permissive}" "${current_boolean_values}" \
        "${required_boolean_values}" "${declared_boolean_values}"
    attestation_verdict="$(ai_tools_confinement_attestation_verdict "${domain_permissive}" "${current_boolean_values}" \
        "${required_boolean_values}")" || true
    ai_tools_confinement_is_selinux_required "${operator_conf}" && selinux_required=yes
    printf 'verdict\t%s\t%s\n' "${attestation_verdict}" "${selinux_required}"
}

# ai_tools_confinement_classify_boolean_row <state> <required value|-> <opening value|-> -- print the reading a status
# report renders for one `boolean` row of ai_tools_confinement_list_attestation_rows: `unread`, `matches` (at
# the required value), `differs` (at the other value, which refuses a launch under AI_TOOLS_REQUIRE_SELINUX), `open`
# (not required, and at the value that opens its rules), `closed` (not required, rules shut), or `malformed` (the
# AI_TOOLS_SELINUX_BOOLEANS row of a declaration with an entry it could not read, which refuses a launch).
ai_tools_confinement_classify_boolean_row() {
    local boolean_state="$1" required_value="$2" opening_value="$3"
    if [[ "${required_value}" == malformed ]]; then printf 'malformed\n'
    elif [[ "${boolean_state}" != on && "${boolean_state}" != off ]]; then printf 'unread\n'
    elif [[ "${required_value}" == "${boolean_state}" ]]; then printf 'matches\n'
    elif [[ "${required_value}" != - ]]; then printf 'differs\n'
    elif [[ "${boolean_state}" == "${opening_value}" ]]; then printf 'open\n'
    else printf 'closed\n'
    fi
}

# ai_tools_confinement_verdict <selinux-mode> <module-present> <expected-label> <actual-label> <manager-domain>
#                              [require-selinux] [domain-permissive] [current-boolean-values]
#                              [required-boolean-values] [policy-shipped]
# Echo a verdict token and return 0 (launch) or 1 (refuse) from the probed inputs and one operator-declared switch:
#   selinux-mode            getenforce output ("Enforcing" when type enforcement is active; "" when getenforce did
#                           not run)
#   module-present          "yes" when the core module's file-contexts are live, as classified by
#                           ai_tools_confinement_module_present, "no" when they are not, "" when matchpathcon did
#                           not run
#   expected-label          label matchpathcon maps the entrypoint to -- "ai_tools_exec_t" once the module's
#                           file-contexts are live in the running policy, "" or another type otherwise
#   actual-label            the entrypoint's live label ("" when unreadable)
#   manager-domain          the systemd --user manager's domain ("" when unreadable)
#   require-selinux         "yes" when operator.conf's AI_TOOLS_REQUIRE_SELINUX is set. Default "no" leaves
#                           intentional DAC-only hosts untouched, and the inputs after it are read only under "yes".
#   domain-permissive       the per-domain mode, as ai_tools_confinement_attestation_verdict takes it
#   current-boolean-values  the Booleans' current values, as ai_tools_confinement_attestation_verdict takes them
#   required-boolean-values the `<name>=<on|off>` set a launch requires, as ai_tools_confinement_attestation_verdict
#                           takes it; the table's defaults when absent
#   policy-shipped          "yes" when the compiled core module is on the host, "no" when it is not, as
#                           ai_tools_confinement_read_policy_shipped reads it; "" when not read
#
#     mode   | module | expected | actual  |    manager     | req | pp  | attestation |        verdict        | result
#   ---------+--------+----------+---------+----------------+-----+-----+-------------+-----------------------+---------
#   !Enf     |   -    |    -     |    -    |       -        | no  |  -  |      -      | ok                    | LAUNCH
#   Enf      |   -    |  exec_t  | exec_t  | init/unconf/"" | no  |  -  |      -      | ok                    | LAUNCH
#   Enf      | no/""  | !exec_t  |    -    |       -        | no  |  -  |      -      | ok                    | LAUNCH
#   Enf      |   -    |  exec_t  | exec_t  | init/unconf    | yes |  -  | ok          | ok                    | LAUNCH
#   Dis      |   -    |    -     |    -    |       -        | yes |  -  |      -      | ok-dac-only           | LAUNCH*
#   Enf/Perm |   no   | !exec_t  |    -    |       -        | yes | no  |      -      | ok-dac-only           | LAUNCH*
#   ""       |   -    |    -     |    -    |       -        | yes |  -  |      -      | require-unattested    | refuse
#   !Enf""   |   -    |    -     |    -    |       -        | yes |  -  |      -      | require-not-enforcing | refuse
#   Enf      |   -    |  exec_t  | !exec_t |       -        |  -  |  -  |      -      | mislabel              | refuse
#   Enf      |   -    |  exec_t  | exec_t  | other          |  -  |  -  |      -      | manager-domain        | refuse
#   Enf      |   -    |  exec_t  | exec_t  | init/unconf/"" | yes |  -  | permissive  | require-permissive    | refuse
#   Enf      |   -    |  exec_t  | exec_t  | init/unconf/"" | yes |  -  | boolean     | require-boolean       | refuse
#   Enf      |   -    |  exec_t  | exec_t  | init/unconf    | yes |  -  | unknown     | require-unattested    | refuse
#   Enf      |   -    |  exec_t  | exec_t  | ""             | yes |  -  | ok/unknown  | require-unattested    | refuse
#   Enf      |  yes   | !exec_t  |    -    |       -        |  -  |  -  |      -      | unverifiable          | refuse
#   Enf      |   no   | !exec_t  |    -    |       -        | yes | yes |      -      | require-inactive      | refuse
#   Enf      |   no   | !exec_t  |    -    |       -        | yes | ""  |      -      | require-unattested    | refuse
#   Enf      |   ""   | !exec_t  |    -    |       -        | yes |  -  |      -      | require-unattested    | refuse
#   (Enf is "Enforcing", Perm "Permissive", Dis "Disabled"; !Enf any other value, "" included; !Enf"" any other
#   non-empty value. A "-" cell is don't-care; "" is empty/unreadable; req "no" is any value other than "yes";
#   pp is policy-shipped; attestation is ai_tools_confinement_attestation_verdict's token over the required
#   Boolean values; LAUNCH* launches and the shim warns, MSG-K6W6)
#
# The LAUNCH rows are the only states that launch, each checked whole before any refusal is classified, so a state
# the table does not list refuses as unclassified rather than launching. Fail-closed once confinement is EXPECTED
# (enforcing with the module installed). The two `ok-dac-only` rows are the states ai_tools_confinement_dac_only_state
# names, where the host runs without SELinux confinement by its own configuration: a launch there proceeds,
# and ai-tools-run prints MSG-K6W6 naming the key to set, since the requirement is shipped on and a refusal would stop
# every launch on a host that never had a transition to verify. What each refusal means, and the remedy each one prints,
# are in confinement.rule.md and in ai-tools-run's refusal text. Two properties of the table are easy to miss reading
# it: manager-domain is ADVISORY without require, so an unreadable ("") domain does not block there; and every require-*
# token replaces a launch the same inputs take without require.
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

# The two paths the module readers take on a host: a core-owned path whose type says whether the core module's file
# contexts are live, and the compiled core module where the ai-tools-selinux package and a source install both stage it
# (AI_TOOLS_SELINUX_PACKAGE_DIR in selinux-groups.lib.sh names the directory). A caller passes them, so a test passes
# a fixture.
# shellcheck disable=SC2034  # read by ai-tools-run and the two status reports
readonly AI_TOOLS_CONFINEMENT_MODULE_PROBE_PATH="/opt/ai-tools/.config"
# shellcheck disable=SC2034  # read by ai-tools-run and the two status reports
readonly AI_TOOLS_CONFINEMENT_CORE_MODULE_FILE="/usr/share/selinux/packages/ai-tools/ai_tools.pp"

# ai_tools_confinement_read_module_present <probe-path> -- print "yes" or "no" for the `module-present` verdict input:
# matchpathcon over <probe-path> (AI_TOOLS_CONFINEMENT_MODULE_PROBE_PATH on a host), classified
# by ai_tools_confinement_module_present. Returns 1 and prints nothing where matchpathcon is not installed,
# which a caller records as an unread input. The shim and both status reports read module presence through this one
# function, so a report describes the state the launch decides on.
ai_tools_confinement_read_module_present() {
    local probe_path="$1"
    command -v matchpathcon >/dev/null 2>&1 || return 1
    ai_tools_confinement_module_present "$(matchpathcon -n "${probe_path}" 2>/dev/null | awk -F: '{print $3}' || true)"
}

# ai_tools_confinement_read_policy_shipped <module-file> -- print "yes" when the compiled core policy module is on this
# host at <module-file> (AI_TOOLS_CONFINEMENT_CORE_MODULE_FILE on a host) and "no" when it is not. The file is tested
# for presence alone, so the sandbox account, which cannot read the module store, tells a host that never installed
# the policy from one whose module is installed and not loaded.
ai_tools_confinement_read_policy_shipped() {
    if [[ -e "$1" ]]; then printf 'yes'; else printf 'no'; fi
}

# ai_tools_confinement_dac_only_state <selinux-mode> <module-present> <policy-shipped> -- print why a host runs without
# SELinux confinement by its own configuration, with no fault to repair: `disabled` when SELinux is Disabled,
# `module-absent` when SELinux is Enforcing or Permissive and neither the core module's file contexts nor its compiled
# module are on the host. Prints nothing and returns 1 for every other state -- a permissive mode with the module
# present, a module whose file is on disk and not loaded, and an unread input among them. Under AI_TOOLS_REQUIRE_SELINUX
# a launch in this state proceeds and warns (MSG-K6W6) where every other unmet requirement refuses, so the status
# reports read it through this one predicate and describe the same launch.
ai_tools_confinement_dac_only_state() {
    local selinux_mode="$1" module_present="$2" policy_shipped="$3"
    if [[ "${selinux_mode}" == Disabled ]]; then printf 'disabled\n'; return 0; fi
    if [[ ( "${selinux_mode}" == Enforcing || "${selinux_mode}" == Permissive ) \
            && "${module_present}" == no && "${policy_shipped}" == no ]]; then
        printf 'module-absent\n'; return 0
    fi
    return 1
}

ai_tools_confinement_verdict() {
    local selinux_mode="$1" module_present="$2" expected_label="$3" actual_label="$4" manager_domain="$5"
    local require_selinux="${6:-no}" domain_permissive="${7:-}" current_boolean_values="${8:-}" required_boolean_values
    local policy_shipped="${10:-}"
    if [[ $# -ge 9 ]]; then
        required_boolean_values="$9"
    else
        required_boolean_values="$(ai_tools_confinement_resolve_required_boolean_values "")"
    fi
    local manager_domain_covered=no entrypoint_labelled=no attestation_verdict dac_only_state=""
    [[ "${manager_domain}" == "init_t" || "${manager_domain}" == "unconfined_t" ]] && manager_domain_covered=yes
    [[ "${expected_label}" == "ai_tools_exec_t" && "${actual_label}" == "ai_tools_exec_t" ]] && entrypoint_labelled=yes
    attestation_verdict="$(ai_tools_confinement_attestation_verdict "${domain_permissive}" "${current_boolean_values}" \
                               "${required_boolean_values}")" || true
    dac_only_state="$(ai_tools_confinement_dac_only_state "${selinux_mode}" "${module_present}" "${policy_shipped}")" \
        || true

    # ── Launch: the known good states, each stated whole ──
    if [[ "${require_selinux}" != "yes" ]]; then
        # DAC-only by the operator's default: no transition to verify.
        if [[ "${selinux_mode}" != "Enforcing" ]]; then
            printf 'ok'; return 0
        fi
        # Confined: the transition's inputs verified; an unreadable manager domain is advisory here.
        if [[ "${entrypoint_labelled}" == yes && ( "${manager_domain_covered}" == yes || -z "${manager_domain}" ) ]]; then
            printf 'ok'; return 0
        fi
        # The SELinux layer was never installed on this host: an intentional DAC-only deployment.
        if [[ "${expected_label}" != "ai_tools_exec_t" && ( "${module_present}" == "no" || -z "${module_present}" ) ]]
        then
            printf 'ok'; return 0
        fi
    elif [[ "${selinux_mode}" == "Enforcing" && "${entrypoint_labelled}" == yes \
            && "${manager_domain_covered}" == yes && "${attestation_verdict}" == ok ]]; then
        # Confined and attested.
        printf 'ok'; return 0
    elif [[ "${dac_only_state}" == disabled ]] \
            || [[ "${dac_only_state}" == module-absent && "${expected_label}" != "ai_tools_exec_t" ]]; then
        # The host runs without SELinux confinement by its own configuration -- SELinux disabled, or the policy never
        # installed -- which no repair of a fault changes, so the launch proceeds DAC-only and the shim warns.
        printf 'ok-dac-only'; return 0
    fi

    # ── Refuse: name the reason, in the order the inputs are checked ──
    if [[ "${selinux_mode}" != "Enforcing" ]]; then
        if [[ -z "${selinux_mode}" ]]; then printf 'require-unattested'; else printf 'require-not-enforcing'; fi
        return 1
    fi
    if [[ "${expected_label}" == "ai_tools_exec_t" ]]; then
        [[ "${actual_label}" != "ai_tools_exec_t" ]] && { printf 'mislabel'; return 1; }
        [[ -n "${manager_domain}" && "${manager_domain_covered}" == no ]] && { printf 'manager-domain'; return 1; }
        [[ "${attestation_verdict}" == permissive ]] && { printf 'require-permissive'; return 1; }
        [[ "${attestation_verdict}" == boolean ]] && { printf 'require-boolean'; return 1; }
        if [[ -z "${manager_domain}" || "${attestation_verdict}" == unknown ]]; then
            printf 'require-unattested'; return 1
        fi
    else
        [[ "${module_present}" == "yes" ]] && { printf 'unverifiable'; return 1; }
        if [[ "${module_present}" == "no" ]]; then
            # The compiled module is on the host and its file contexts are not live: installed and not loaded.
            if [[ "${policy_shipped}" == "yes" ]]; then printf 'require-inactive'; else printf 'require-unattested'; fi
            return 1
        fi
        [[ -z "${module_present}" ]] && { printf 'require-unattested'; return 1; }
    fi
    printf 'unclassified'; return 1
}

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/confinement.sh
# Unit test for the SELinux launch-gate decision (confinement.lib.sh): the pure ai_tools_confinement_verdict
# that ai-tools-run's fail-closed preflight dispatches on. Drives the truth table over the probed inputs -- getenforce,
# module presence, the matchpathcon-expected label, the live label, the manager domain, the per-domain mode
# and the gating Booleans -- and the operator's AI_TOOLS_REQUIRE_SELINUX switch, with no SELinux host required,
# so a regression in the gate (an inverted condition, a swallowed refusal, an unread input read as a clean one) fails
# here rather than reaching production as an UNCONFINED launch. The attestation reader's record parser is driven too;
# the live libselinux query is not, since the confined domain is denied it. Sources the deployed library; does not need
# privilege of its own. Run as root via sudo (suite contract).

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

# expect_verdict <token> <rc> <selinux-mode> <module-present> <expected-label> <actual-label> <manager-domain>
#                [require-selinux] [domain-permissive] [current-boolean-values] [required-boolean-values]
#                [policy-shipped]
# Drive the verdict and assert BOTH the echoed token and the 0=launch/1=refuse return. The '|| verdict_status=$?' keeps
# a refusal (rc 1) non-fatal under `set -e` and captures the status. Each optional input is passed only when given,
# so a 5-argument call exercises the default a caller without the switch gets.
expect_verdict() {
    local expected_token="$1" expected_status="$2"; shift 2
    local verdict_token verdict_status
    verdict_token="$(ai_tools_confinement_verdict "$@")" && verdict_status=0 || verdict_status=$?
    local case_description="mode=${1:-∅} module=${2:-∅} expected=${3:-∅} actual=${4:-∅} manager=${5:-∅}"
    case_description+=" require=${6-unset} permissive=${7-unset} booleans=${8-unset} policy=${10-unset}"
    if [[ "${verdict_token}" == "${expected_token}" && "${verdict_status}" -eq "${expected_status}" ]]; then
        pass "${case_description} -> ${verdict_token} (rc ${verdict_status})"
    else
        fail "${case_description} -> ${verdict_token} (rc ${verdict_status}); expected ${expected_token} (rc ${expected_status})"
    fi
}

# ── Gate ENGAGED: enforcing AND the module's file-contexts are active (want=ai_tools_exec_t) ── Happy path: correctly
# labelled entrypoint, a covered manager domain -> launch confined.
expect_verdict ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t
expect_verdict ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t unconfined_t
# The regression this test exists to catch: entrypoint mislabelled -> no transition -> refuse.
expect_verdict mislabel 1 Enforcing yes ai_tools_exec_t lib_t init_t
# An unreadable live label ("") is not ai_tools_exec_t -> refuse (fail closed, not skip).
expect_verdict mislabel 1 Enforcing yes ai_tools_exec_t "" init_t
# Manager runs in a domain no domtrans_pattern covers -> transition would not fire -> refuse.
expect_verdict manager-domain 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t some_other_t
# The manager-domain signal is ADVISORY: an unreadable ("") domain does not block the launch.
expect_verdict ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t ""

# ── Half-installed ENFORCING host: label unresolved but the module IS present -> fail closed ── The prod-safety case:
# module staged/loaded but its file-contexts are not active (a Node upgrade before relabel, or matchpathcon missing),
# so the transition cannot be verified. Refuse rather than launch DAC-only. Module presence is what distinguishes this
# from a DAC-only host.
expect_verdict unverifiable 1 Enforcing yes ""      lib_t init_t
expect_verdict unverifiable 1 Enforcing yes bin_t   ""    init_t

# ── Gate a DELIBERATE no-op: the SELinux layer is not in force here, so launches proceed ── Not enforcing -> gate
# off, even with a mislabelled entrypoint (permissive / DAC-only boxes).
expect_verdict ok 0 Permissive yes ai_tools_exec_t lib_t init_t
expect_verdict ok 0 Disabled   yes ai_tools_exec_t lib_t init_t
expect_verdict ok 0 unknown    yes ai_tools_exec_t lib_t init_t
# Enforcing, label unresolved, and the module is ABSENT -> the SELinux layer was never installed on this host
# (intentional DAC-only deployment), so launch. This is the sole remaining fail-open, gated on the module being absent
# -- asserted, not incidental.
expect_verdict ok 0 Enforcing no "" lib_t init_t

# ── The module-presence probe classifier (ai_tools_confinement_module_present) ── ai-tools-run derives
# the `module-present` verdict input from `matchpathcon` on a CORE-owned path, because it runs as the sandbox account
# and cannot read the root-only module store (`semodule -l`). A core-owned path resolves to an ai_tools_* type ONLY
# when the core module's file-contexts are live, so this classifier turns that probed type into the yes/no the verdict
# consumes. The false "no" this replaces was the fail-open: on the unresolved-label branch it would launch DAC-only
# where the module is actually loaded.
expect_module_present() {  # <expected-answer> <probed-type>
    local classified_answer; classified_answer="$(ai_tools_confinement_module_present "$2")"
    if [[ "${classified_answer}" == "$1" ]]; then pass "module-present(${2:-∅}) -> ${classified_answer}"
    else fail "module-present(${2:-∅}) -> ${classified_answer}; expected $1"; fi
}
expect_module_present yes ai_tools_home_t     # /opt/ai-tools/.config when the core module is loaded
expect_module_present yes ai_tools_run_t      # any core-owned ai_tools_* type confirms live file-contexts
expect_module_present no  user_home_t         # module absent -> the path keeps its default home type
expect_module_present no  bin_t               # any non-ai_tools type -> not present
expect_module_present no  ""                  # no match -> not present (stays fail-closed via the verdict)

# ── AI_TOOLS_REQUIRE_SELINUX: the operator's declaration, shipped on. It turns launches into refusals, or into a warned
# DAC-only launch where the host has no SELinux confinement by its own configuration, and does not turn any refusal
# into a launch; every verdict without it is identical to the require=no path. ──
section "confinement: AI_TOOLS_REQUIRE_SELINUX fail-closed (unit)"
readonly CLEAN_BOOLEANS="nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off"
# require=no reproduces the DAC-capable behaviour exactly (the explicit default is a no-op), and does not read
# the attestation inputs: a permissive domain or an enabled Boolean launches there, as global permissive does.
expect_verdict ok 0 Permissive yes ai_tools_exec_t lib_t init_t no
expect_verdict ok 0 Enforcing no "" lib_t init_t no
expect_verdict ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t no yes "nis_enabled=on"
# A degraded host becomes a refusal under require=yes: permissive with the module present, or its file contexts unread;
# a module installed on the host and not loaded; a module not live whose file was not read.
expect_verdict require-not-enforcing 1 Permissive yes ai_tools_exec_t lib_t init_t yes                 # not enforcing
expect_verdict require-not-enforcing 1 Permissive ""  ""              lib_t init_t yes no "" "" no     # file contexts unread
expect_verdict require-not-enforcing 1 Permissive no  ""              lib_t init_t yes no "" "" yes    # installed, not loaded
expect_verdict require-inactive      1 Enforcing  no  ""              lib_t init_t yes no "" "" yes    # installed, not loaded
expect_verdict require-unattested    1 Enforcing  no  ""              lib_t init_t yes no "" "" ""     # module file unread
expect_verdict require-unattested    1 Enforcing  no  ""              lib_t init_t yes                 # a 6-argument caller
# A host without SELinux confinement by its own configuration launches DAC-only under require=yes, and the shim warns:
# SELinux disabled whatever else was read, or the policy neither live nor on disk. The label fault still outranks it.
expect_verdict ok-dac-only 0 Disabled   yes ai_tools_exec_t lib_t init_t yes                           # SELinux off
expect_verdict ok-dac-only 0 Disabled   ""  ""              ""    ""     yes                           # off, probes empty
expect_verdict ok-dac-only 0 Enforcing  no  ""              lib_t init_t yes no "" "" no               # never installed
expect_verdict ok-dac-only 0 Permissive no  ""              lib_t init_t yes no "" "" no               # never installed
expect_verdict mislabel    1 Enforcing  no  ai_tools_exec_t lib_t init_t yes no "" "" no               # a label the module maps
# require does NOT loosen or alter any already-fail-closed refusal: a mislabel/unverifiable still refuses whatever
# the attestation says.
expect_verdict mislabel       1 Enforcing yes ai_tools_exec_t lib_t           init_t       yes no "${CLEAN_BOOLEANS}"
expect_verdict unverifiable   1 Enforcing yes ""              lib_t           init_t       yes no "${CLEAN_BOOLEANS}"
expect_verdict manager-domain 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t some_other_t yes no "${CLEAN_BOOLEANS}"
# A verified transition with an enforced domain and the gating Booleans off launches.
expect_verdict ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t       yes no "${CLEAN_BOOLEANS}"
expect_verdict ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t unconfined_t yes no \
    "${CLEAN_BOOLEANS} kerberos_enabled=on fips_mode=on"   # an advisory Boolean does not gate

section "confinement: attestation under AI_TOOLS_REQUIRE_SELINUX (unit)"
# A definite fault: a permissive domain, or a gating Boolean on.
expect_verdict require-permissive 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes yes "${CLEAN_BOOLEANS}"
expect_verdict require-boolean    1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no \
    "nis_enabled=on domain_can_mmap_files=off"
expect_verdict require-boolean    1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no \
    "nis_enabled=off domain_can_mmap_files=on"
# A definite fault outranks an unread input, so the refusal names what to turn off.
expect_verdict require-permissive 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t ""     yes yes ""
expect_verdict require-boolean    1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes ""  "nis_enabled=on"
# Every input that could not be read refuses: the unread is never read as the clean answer.
expect_verdict require-unattested 1 ""        yes ai_tools_exec_t ai_tools_exec_t init_t yes no "${CLEAN_BOOLEANS}"  # no getenforce
expect_verdict require-unattested 1 Enforcing ""  ""              lib_t           init_t yes no "${CLEAN_BOOLEANS}"  # no matchpathcon
expect_verdict require-unattested 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t ""     yes no "${CLEAN_BOOLEANS}"  # manager domain
expect_verdict require-unattested 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes "" "${CLEAN_BOOLEANS}"  # domain mode
expect_verdict require-unattested 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no "nis_enabled=off"    # one Boolean
expect_verdict require-unattested 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no ""                   # no Boolean
expect_verdict require-unattested 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no \
    "nis_enabled=maybe domain_can_mmap_files=off"                                                                    # bad value
expect_verdict require-unattested 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes unknown "${CLEAN_BOOLEANS}"
expect_verdict require-unattested 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes   # a 6-argument caller
# Without require, an absent getenforce or matchpathcon keeps today's launch.
expect_verdict ok 0 ""        yes ai_tools_exec_t ai_tools_exec_t init_t no
expect_verdict ok 0 Enforcing ""  ""              lib_t           init_t no

section "confinement: only the listed states launch (unit)"
# The verdict checks each LAUNCH row whole before it classifies a refusal, so an input outside its documented values
# reaches the default row and refuses instead of falling through to a launch.
expect_verdict unclassified 1 Enforcing maybe ""              lib_t           init_t yes no "${CLEAN_BOOLEANS}"
expect_verdict unverifiable 1 Enforcing yes   bin_t           ""              init_t no   # a foreign expected label
expect_verdict ok           0 ""        yes   ai_tools_exec_t lib_t           init_t no   # no getenforce, no requirement
expect_verdict unclassified 1 Enforcing maybe ""              lib_t           init_t no   # not a documented value
expect_verdict require-not-enforcing 1 unknown no ""          lib_t           init_t yes no "" "" no  # not a documented mode

section "confinement: the requirement is in force unless operator.conf turns it off (unit)"
# ai_tools_confinement_is_selinux_required is the one read of AI_TOOLS_REQUIRE_SELINUX, and every way it can fail
# resolves to the requirement: an untrusted file (one this account owns), an absent key, a yes value and a mistyped
# value each require; only a value the grammar reads as no does not. A trusted file is root-owned, so those cases run
# as root.
mktestdir
expect_required() {  # <description> <expected 0|1> <operator-conf>
    local status=0
    ai_tools_confinement_is_selinux_required "$3" 2>/dev/null || status=$?
    if [[ "${status}" -eq "$2" ]]; then pass "$1 -> rc ${status}"; else fail "$1 -> rc ${status}; expected $2"; fi
}
# The reader needs the grammar beside the lib (ai_tools_conf_no); without it the requirement stands whatever the file
# says, which is the fail direction and not what these cases are about, so the grammar is loaded first.
CONF_LIB_FOR_REQUIREMENT="$(dirname "${LIB}")/conf.lib.sh"
if [[ -r "${CONF_LIB_FOR_REQUIREMENT}" ]] && source "${CONF_LIB_FOR_REQUIREMENT}" \
        && declare -F ai_tools_conf_no >/dev/null 2>&1; then
    printf 'AI_TOOLS_REQUIRE_SELINUX=no\n' > "${TESTDIR}/untrusted.conf"; chmod 0666 "${TESTDIR}/untrusted.conf"
    expect_required "an untrusted operator.conf setting no still requires" 0 "${TESTDIR}/untrusted.conf"
    expect_required "an absent operator.conf requires" 0 "${TESTDIR}/missing.conf"
    if [[ "${EUID}" -eq 0 ]]; then
        for value in "" "yes" "no" "ture"; do
            case "${value}" in
                "")   : > "${TESTDIR}/trusted-absent.conf"; conf="${TESTDIR}/trusted-absent.conf" ;;
                *)    printf 'AI_TOOLS_REQUIRE_SELINUX=%s\n' "${value}" > "${TESTDIR}/trusted-${value}.conf"
                      conf="${TESTDIR}/trusted-${value}.conf" ;;
            esac
            chmod 0644 "${conf}"; chown root:root "${conf}"
        done
        expect_required "a trusted file without the key requires" 0 "${TESTDIR}/trusted-absent.conf"
        expect_required "a trusted file setting yes requires"     0 "${TESTDIR}/trusted-yes.conf"
        expect_required "a trusted file setting no does not"      1 "${TESTDIR}/trusted-no.conf"
        expect_required "a trusted file with a mistyped value requires" 0 "${TESTDIR}/trusted-ture.conf"
        said="$(ai_tools_confinement_is_selinux_required "${TESTDIR}/trusted-ture.conf" 2>&1 || true)"
        assert_msg MSG-H7N5 "${said}" "the mistyped value is reported as read as yes"
    else
        skip "the requirement's trusted-file cases" "a trusted operator.conf is root-owned; run as root"
    fi
else
    skip "the requirement's reader" "conf.lib.sh beside ${LIB} is not readable, or it predates ai_tools_conf_no"
fi

section "confinement: the DAC-only state and its readers (unit)"
# ai_tools_confinement_dac_only_state is the one predicate the verdict and both status reports read a host's want
# of confinement by, so it is driven in both directions: the two states it names, and every near miss that is a fault
# or an unread input rather than the host's own configuration.
expect_dac_only_state() {  # <expected|none> <selinux-mode> <module-present> <policy-shipped>
    local expected="$1"; shift
    local state status=0
    state="$(ai_tools_confinement_dac_only_state "$@")" || status=$?
    if [[ "${expected}" == none && -z "${state}" && "${status}" -eq 1 ]] \
            || [[ "${expected}" != none && "${state}" == "${expected}" && "${status}" -eq 0 ]]; then
        pass "dac-only(mode=${1:-∅} module=${2:-∅} policy=${3:-∅}) -> ${state:-none}"
    else
        fail "dac-only(mode=${1:-∅} module=${2:-∅} policy=${3:-∅}) -> ${state:-none} (rc ${status}); expected ${expected}"
    fi
}
expect_dac_only_state disabled      Disabled   yes yes
expect_dac_only_state disabled      Disabled   ""  ""
expect_dac_only_state module-absent Enforcing  no  no
expect_dac_only_state module-absent Permissive no  no
expect_dac_only_state none          Enforcing  no  yes    # installed and not loaded: a fault
expect_dac_only_state none          Enforcing  no  ""     # the module file unread
expect_dac_only_state none          Enforcing  ""  no     # the file contexts unread
expect_dac_only_state none          Enforcing  yes no     # live: confined
expect_dac_only_state none          Permissive yes no     # permissive with the module present: a fault
expect_dac_only_state none          ""         no  no     # the mode unread
expect_dac_only_state none          unknown    no  no     # not a documented mode

# The policy-shipped reader answers from the module file's presence alone, and the module-present reader
# from matchpathcon, so each is driven against a fixture: a file that exists, one that does not, a type the core module
# maps and one it does not, and a host without matchpathcon, which reads as unread rather than as absent.
: > "${TESTDIR}/ai_tools.pp"
expect_reader() {  # <description> <expected> <command...>
    local description="$1" expected="$2"; shift 2
    local answer status=0
    answer="$("$@")" || status=$?
    if [[ "${answer}" == "${expected}" ]]; then pass "${description} -> ${answer:-∅} (rc ${status})"
    else fail "${description} -> ${answer:-∅} (rc ${status}); expected ${expected:-∅}"; fi
}
expect_reader "policy shipped: the module file present" yes ai_tools_confinement_read_policy_shipped "${TESTDIR}/ai_tools.pp"
expect_reader "policy shipped: the module file absent"  no  ai_tools_confinement_read_policy_shipped "${TESTDIR}/missing.pp"
matchpathcon() { printf 'system_u:object_r:%s:s0\n' "${stub_probe_type}"; }
stub_probe_type=ai_tools_home_t
expect_reader "module present: the core path maps to its type" yes \
    ai_tools_confinement_read_module_present "${AI_TOOLS_CONFINEMENT_MODULE_PROBE_PATH}"
stub_probe_type=user_home_t
expect_reader "module present: the core path keeps its default type" no \
    ai_tools_confinement_read_module_present "${AI_TOOLS_CONFINEMENT_MODULE_PROBE_PATH}"
unset -f matchpathcon
if answer="$(PATH=/nonexistent ai_tools_confinement_read_module_present "${AI_TOOLS_CONFINEMENT_MODULE_PROBE_PATH}" 2>/dev/null)"; then
    fail "module present without matchpathcon read as a value: ${answer}"
elif [[ -z "${answer}" ]]; then
    pass "module present without matchpathcon -> unread (rc 1, prints nothing)"
else
    fail "module present without matchpathcon printed ${answer}"
fi

section "confinement: attestation record parser (unit)"
# expect_parsed_inputs <description> <expected-line> <records>: the parser is what turns the reader's output
# into the verdict's two inputs, so a record it misreads is an unread input or a wrong one.
expect_parsed_inputs() {
    local case_description="$1" expected_line="$2" parsed_line
    parsed_line="$(printf '%b' "$3" | ai_tools_confinement_parse_attestation_records)"
    if [[ "${parsed_line}" == "${expected_line}" ]]; then pass "parse: ${case_description} -> ${parsed_line}"
    else fail "parse: ${case_description} -> ${parsed_line}; expected ${expected_line}"; fi
}
expect_parsed_inputs "a full reading" "no|nis_enabled=off domain_can_mmap_files=on" \
    'permissive\tno\nboolean\tnis_enabled\toff\nboolean\tdomain_can_mmap_files\ton\n'
expect_parsed_inputs "no reading at all" "|" ''
expect_parsed_inputs "the domain mode alone" "yes|" 'permissive\tyes\n'
expect_parsed_inputs "Booleans with the domain mode unread" "|nis_enabled=off" 'boolean\tnis_enabled\toff\n'
expect_parsed_inputs "a value outside the grammar is dropped" "|domain_can_mmap_files=off" \
    'permissive\tmaybe\nboolean\tnis_enabled\t1\nboolean\tdomain_can_mmap_files\toff\njunk\n'
expect_parsed_inputs "a name outside the charset is dropped" "no|" 'permissive\tno\nboolean\tnis enabled=on x\ton\n'
# The parser's separator survives the empty first field the shim reads it with.
IFS='|' read -r parsed_domain_permissive parsed_current_boolean_values \
    < <(printf 'boolean\tnis_enabled\ton\n' | ai_tools_confinement_parse_attestation_records)
if [[ -z "${parsed_domain_permissive}" && "${parsed_current_boolean_values}" == "nis_enabled=on" ]]; then
    pass "the shim's read keeps an empty domain mode empty"
else
    fail "the shim's read moved fields: permissive=[${parsed_domain_permissive}] booleans=[${parsed_current_boolean_values}]"
fi

section "confinement: selinuxfs reader (unit)"
# expect_access_decision <expected-answer> <kernel-answer>: the permissive bit of the access transaction's answer.
# An answer outside the kernel's grammar prints nothing, which the verdict reads as unread.
expect_access_decision() {
    local parsed_answer; parsed_answer="$(ai_tools_confinement_parse_access_decision "$2")"
    if [[ "${parsed_answer}" == "$1" ]]; then pass "access decision '${2}' -> ${parsed_answer:-unread}"
    else fail "access decision '${2}' -> ${parsed_answer:-unread}; expected ${1:-unread}"; fi
}
expect_access_decision no  "ffffffff ffffffff 0 ffffffff 12 0"
expect_access_decision yes "ffffffff ffffffff 0 ffffffff 12 1"
expect_access_decision yes "ffffffff ffffffff 0 ffffffff 12 3"     # another flag beside the permissive bit
expect_access_decision ""  "ffffffff ffffffff 0 ffffffff 12"       # a kernel without the flags field
expect_access_decision ""  ""
expect_access_decision ""  "ffffffff ffffffff 0 ffffffff 12 1 extra"
expect_access_decision ""  "ffffffff ffffffff 0 ffffffff 12 0x1"

# The reader over a fixture selinuxfs tree. A regular file cannot answer the access transaction (the read
# after the write meets end of file), so the per-domain mode reads as unread here, which is the direction a host
# that refuses the query takes; the live answer is the host's to give, since ai_tools_t is denied the query.
fixture_selinuxfs="${TESTDIR}/selinuxfs"
mkdir -p "${fixture_selinuxfs}/class/process/perms" "${fixture_selinuxfs}/booleans"
printf '2\n'  > "${fixture_selinuxfs}/class/process/index"
printf '5\n'  > "${fixture_selinuxfs}/class/process/perms/signal"
: > "${fixture_selinuxfs}/access"
printf '0 0' > "${fixture_selinuxfs}/booleans/nis_enabled"
printf '1 1' > "${fixture_selinuxfs}/booleans/domain_can_mmap_files"
printf '1 0' > "${fixture_selinuxfs}/booleans/kerberos_enabled"
printf 'x 0' > "${fixture_selinuxfs}/booleans/fips_mode"            # outside the grammar: left out
fixture_records="$(ai_tools_confinement_read_attestation_records "${fixture_selinuxfs}")"
expected_records=$'boolean\tnis_enabled\toff\nboolean\tdomain_can_mmap_files\ton\nboolean\tkerberos_enabled\ton'
if [[ "${fixture_records}" == "${expected_records}" ]]; then
    pass "reader: each Boolean's active value, an unreadable one and the unanswered access query left out"
else
    fail "reader over the fixture printed: ${fixture_records//$'\n'/ | }"
fi
# The same reading under the IFS ai-tools sets (newline and tab only): a reader that split on the caller's IFS would
# read `0 0` as one value and report every Boolean unread.
fixture_records_cli_ifs="$(IFS=$'\n\t'; ai_tools_confinement_read_attestation_records "${fixture_selinuxfs}")"
if [[ "${fixture_records_cli_ifs}" == "${expected_records}" ]]; then
    pass "reader: the Boolean values read alike under ai-tools' IFS=\$'\\n\\t'"
else
    fail "reader under IFS=\$'\\n\\t' printed: ${fixture_records_cli_ifs//$'\n'/ | }"
fi
if [[ -z "$(ai_tools_confinement_read_attestation_records "${TESTDIR}/absent")" ]]; then
    pass "reader: a missing selinuxfs prints no record, so every input reads as unread"
else
    fail "reader: a missing selinuxfs printed a record"
fi

# A further name becomes a path component under selinuxfs, so the reader opens one only in the pair grammar
# (ai_tools_conf_pair_name_valid, conf.lib.sh beside the lib) and reads a registry name once however often it is passed.
# The traversal fixture exists and holds a value, so this asserts the name was refused, not that it was absent.
mkdir -p "${TESTDIR}/etc"; printf '1 0' > "${TESTDIR}/etc/shadow"
printf '1 0' > "${fixture_selinuxfs}/booleans/ai_tools_test_extra"
CONF_LIB_FOR_READER="$(dirname "${LIB}")/conf.lib.sh"
if [[ -r "${CONF_LIB_FOR_READER}" ]] && source "${CONF_LIB_FOR_READER}" \
        && declare -F ai_tools_conf_pair_name_valid >/dev/null 2>&1; then
    further_records="$(ai_tools_confinement_read_attestation_records "${fixture_selinuxfs}" \
        '../../etc/shadow' 'nis enabled' nis_enabled ai_tools_test_extra ai_tools_test_extra)"
    if [[ "${further_records}" == "${expected_records}"$'\nboolean\tai_tools_test_extra\ton' ]]; then
        pass "reader: a further name is read once and in the pair grammar alone -- a path and a name with a space are not opened"
    else
        fail "reader with further names printed: ${further_records//$'\n'/ | }"
    fi
else
    skip "reader further names" "conf.lib.sh beside ${LIB} is not readable, or it predates ai_tools_conf_pair_name_valid"
fi

section "confinement: the Boolean values a launch requires (unit)"
# A required value refuses at the other value, whichever way that runs: deny_ptrace declared on refuses while off.
expect_verdict require-boolean 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no \
    "${CLEAN_BOOLEANS} deny_ptrace=off" "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off deny_ptrace=on"
expect_verdict ok              0 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no \
    "${CLEAN_BOOLEANS} deny_ptrace=on"  "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off deny_ptrace=on"
# A host that declares nis_enabled on launches while it is on, and refuses once it drifts off.
expect_verdict ok              0 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no \
    "nis_enabled=on domain_can_mmap_files=off domain_can_write_kmsg=off" \
    "nis_enabled=on domain_can_mmap_files=off domain_can_write_kmsg=off"
expect_verdict require-boolean 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no \
    "${CLEAN_BOOLEANS}" "nis_enabled=on domain_can_mmap_files=off domain_can_write_kmsg=off"
# A declared Boolean the kernel does not have reads as unread.
expect_verdict require-unattested 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no \
    "${CLEAN_BOOLEANS}" "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off no_such_boolean=on"

# The required set: absent is the built-in requirement, a present declaration is exactly its pairs, as every list
# in operator.conf replaces its default, and a malformed one keeps the built-in pairs, adds those it read, and carries
# the marker no reading satisfies.
expect_required_values() {  # <description> <expected> <declaration-state> <declared-boolean-values>
    local required_values; required_values="$(ai_tools_confinement_resolve_required_boolean_values "$3" "$4")"
    if [[ "${required_values}" == "$2" ]]; then pass "required values, $1 -> [${required_values}]"
    else fail "required values, $1 -> [${required_values}]; expected [$2]"; fi
}
expect_required_values "no declaration" "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off" absent ""
expect_required_values "no argument" "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off" "" ""
expect_required_values "a declaration replaces the built-in pairs" "nis_enabled=on deny_ptrace=on" present \
    "nis_enabled=on deny_ptrace=on"
expect_required_values "an empty declaration requires none" "" present ""
expect_required_values "a malformed declaration keeps the built-in pairs and refuses" \
    "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off deny_ptrace=on AI_TOOLS_SELINUX_BOOLEANS=malformed" \
    malformed "deny_ptrace=on"
required_values_cli_ifs="$(IFS=$'\n\t'; ai_tools_confinement_resolve_required_boolean_values present "nis_enabled=on deny_ptrace=on")"
if [[ "${required_values_cli_ifs}" == "nis_enabled=on deny_ptrace=on" ]]; then
    pass "required values read alike under ai-tools' IFS=\$'\\n\\t'"
else
    fail "required values under IFS=\$'\\n\\t' -> ${required_values_cli_ifs}"
fi
# The marker refuses as an input that could not be read, whatever the Booleans read.
expect_verdict require-unattested 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t yes no \
    "${CLEAN_BOOLEANS} deny_ptrace=on" \
    "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off deny_ptrace=on AI_TOOLS_SELINUX_BOOLEANS=malformed"

section "confinement: unread inputs and report rows (unit)"
# Each unread input is listed with its kind, so the shim prints the remedy that kind takes and not a package install
# for a misspelled Boolean.
unread_rows="$(ai_tools_confinement_list_unread_inputs \
    "nis_enabled=off no_such_boolean=on AI_TOOLS_SELINUX_BOOLEANS=malformed" "nis_enabled=off" "")"
expected_unread=$'selinuxfs\twhether ai_tools_t is a permissive domain (/sys/fs/selinux/access)\nboolean\tthe no_such_boolean Boolean\ndeclaration\tAI_TOOLS_SELINUX_BOOLEANS in operator.conf (an entry is not <boolean>=on or <boolean>=off)'
if [[ "${unread_rows}" == "${expected_unread}" ]]; then
    pass "unread inputs: the domain mode, a Boolean the reading lacks and the marker, each with its kind"
else
    fail "unread inputs -> ${unread_rows//$'\n'/ | }"
fi
full_reading_unread="$(ai_tools_confinement_list_unread_inputs "${CLEAN_BOOLEANS}" "${CLEAN_BOOLEANS}" no)"
if [[ -z "${full_reading_unread}" ]]; then pass "unread inputs: a full reading lists none"
else fail "unread inputs over a full reading: ${full_reading_unread//$'\n'/ | }"; fi

# The report rows: the domain row and a differing Boolean carry the command that puts each right, a required Boolean
# the registry does not hold is listed from the declaration, and the malformed marker is a row of its own.
report_rows="$(ai_tools_confinement_list_attestation_rows yes "nis_enabled=on deny_ptrace=on" \
    "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off my_extra=on AI_TOOLS_SELINUX_BOOLEANS=malformed" \
    "my_extra=on")"
expect_row() {  # <description> <expected row>
    if grep -qxF -- "$2" <<<"${report_rows}"; then pass "report row: $1"
    else fail "report row: $1 -- not in: ${report_rows//$'\n'/ | }"; fi
}
expect_row "a permissive domain carries its remedy" $'domain\tyes\tsudo semanage permissive -d ai_tools_t'
expect_row "a differing Boolean carries its remedy" \
    $'boolean\tnis_enabled\tdiffers\ton\toff\tbuilt-in\ton\tbind and connect on most port types\tsudo setsebool -P nis_enabled=off'
expect_row "an unread required Boolean has no remedy" \
    $'boolean\tdomain_can_mmap_files\tunread\tunread\toff\tbuilt-in\ton\tmap on every file type, the access the tmpmap group exists to add\t-'
expect_row "an advisory false-branch Boolean read on is closed" \
    $'boolean\tdeny_ptrace\tclosed\ton\t-\t-\toff\tptrace, which this Boolean denies while on\t-'
expect_row "a declared Boolean outside the registry is listed from the declaration" \
    $'boolean\tmy_extra\tunread\tunread\ton\toperator.conf\t-\tdeclared in AI_TOOLS_SELINUX_BOOLEANS\t-'
expect_row "the malformed marker is a row of its own" \
    $'boolean\tAI_TOOLS_SELINUX_BOOLEANS\tmalformed\tunread\tmalformed\toperator.conf\t-\tan entry that is not <boolean>=on or <boolean>=off\t-'

# The declaration readers, over fixture files. The trust predicate has its own tests (conf.sh), so here it is stubbed
# per path: the trusted fixtures pass and the untrusted one does not, which keeps the fail direction in view.
CONF_LIB_FOR_READERS="$(dirname "${LIB}")/conf.lib.sh"
if [[ -r "${CONF_LIB_FOR_READERS}" ]] && source "${CONF_LIB_FOR_READERS}" \
        && declare -F ai_tools_confinement_read_boolean_requirement >/dev/null 2>&1; then
    valid_operator_conf="${TESTDIR}/operator-valid.conf"; malformed_operator_conf="${TESTDIR}/operator-malformed.conf"
    empty_operator_conf="${TESTDIR}/operator-empty.conf"; absent_operator_conf="${TESTDIR}/operator-absent.conf"
    untrusted_operator_conf="${TESTDIR}/operator-untrusted.conf"
    printf 'AI_TOOLS_REQUIRE_SELINUX=no\nAI_TOOLS_SELINUX_BOOLEANS=[nis_enabled=on, deny_ptrace=on]\n' > "${valid_operator_conf}"
    printf 'AI_TOOLS_SELINUX_BOOLEANS=[deny_ptrace=on, nis_enabled=of, deny_ptrace=off]\n' > "${malformed_operator_conf}"
    printf 'AI_TOOLS_SELINUX_BOOLEANS=[]\n' > "${empty_operator_conf}"
    printf 'AI_TOOLS_REQUIRE_SELINUX=yes\n' > "${absent_operator_conf}"
    cp "${valid_operator_conf}" "${untrusted_operator_conf}"
    ai_tools_conf_is_trusted() { [[ "$1" != "${untrusted_operator_conf}" ]]; }
    expect_required_reading() {  # <description> <operator-conf> <state> <required> <declared>
        local reading; reading="$(ai_tools_confinement_read_boolean_requirement "$2" 2>/dev/null)"
        # Built the way the reading is captured, so the trailing empty lines $(...) strips go from both.
        local expected_reading; expected_reading="$(printf '%s\n%s\n%s\n' "$3" "$4" "$5")"
        if [[ "${reading}" == "${expected_reading}" ]]; then pass "declaration, $1 -> ${reading//$'\n'/ | }"
        else fail "declaration, $1 -> ${reading//$'\n'/ | }; expected ${expected_reading//$'\n'/ | }"; fi
    }
    expect_required_reading "valid: exactly its pairs" "${valid_operator_conf}" present \
        "nis_enabled=on deny_ptrace=on" "nis_enabled=on deny_ptrace=on"
    expect_required_reading "an entry malformed and a Boolean repeated: built-in pairs, the pair read, the marker" \
        "${malformed_operator_conf}" malformed \
        "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off deny_ptrace=on AI_TOOLS_SELINUX_BOOLEANS=malformed" \
        "deny_ptrace=on"
    expect_required_reading "empty: requires none" "${empty_operator_conf}" present "" ""
    expect_required_reading "absent: the built-in pairs" "${absent_operator_conf}" absent \
        "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off" ""
    expect_required_reading "untrusted: the built-in pairs" "${untrusted_operator_conf}" absent \
        "nis_enabled=off domain_can_mmap_files=off domain_can_write_kmsg=off" ""
    # The one reading the shim and both reports share, over the valid declaration and the fixture selinuxfs: its five
    # fields, then the report's closing verdict row, which says whether a token other than ok refuses a launch.
    printf '1 0' > "${fixture_selinuxfs}/booleans/deny_ptrace"
    attestation_inputs="$(ai_tools_confinement_read_attestation_inputs "${valid_operator_conf}" "${fixture_selinuxfs}")"
    expected_inputs="present|nis_enabled=on deny_ptrace=on|nis_enabled=on deny_ptrace=on||nis_enabled=off domain_can_mmap_files=on kerberos_enabled=on deny_ptrace=on"
    if [[ "${attestation_inputs}" == "${expected_inputs}" ]]; then
        pass "attestation inputs: the declaration, every Boolean it names read beside the registry's, the domain mode unread"
    else
        fail "attestation inputs -> ${attestation_inputs}; expected ${expected_inputs}"
    fi
    expect_report_verdict() {  # <description> <operator-conf> <expected verdict row>
        local report_tail; report_tail="$(ai_tools_confinement_list_attestation_report "$2" "${fixture_selinuxfs}" | tail -n1)"
        if [[ "${report_tail}" == "$3" ]]; then pass "attestation report, $1 -> ${report_tail//$'\t'/ }"
        else fail "attestation report, $1 -> ${report_tail//$'\t'/ }; expected ${3//$'\t'/ }"; fi
    }
    expect_report_verdict "a declaration a Boolean drifted from, declared not required" "${valid_operator_conf}" $'verdict\tboolean\tno'
    expect_report_verdict "the built-in pairs with one open, required" "${absent_operator_conf}" $'verdict\tboolean\tyes'
    # The no is read only from a trusted file: the same declaration in an untrusted one leaves the requirement in force.
    expect_report_verdict "the same declaration in an untrusted file, required" "${untrusted_operator_conf}" $'verdict\tboolean\tyes'
    unset -f ai_tools_conf_is_trusted
else
    skip "operator.conf readers" "conf.lib.sh beside ${LIB} is not readable, or the library predates the readers"
fi

# The reading a status row renders, over its whole table.
expect_row_reading() {  # <expected> <state> <required value|-> <opening value|->
    local row_reading; row_reading="$(ai_tools_confinement_classify_boolean_row "$2" "$3" "$4")"
    if [[ "${row_reading}" == "$1" ]]; then pass "row reading $2/$3/$4 -> ${row_reading}"
    else fail "row reading $2/$3/$4 -> ${row_reading}; expected $1"; fi
}
expect_row_reading matches off    off on
expect_row_reading differs on     off on
expect_row_reading differs off    on  off     # deny_ptrace declared on, found off
expect_row_reading open    on     -   on
expect_row_reading closed  on     -   off
expect_row_reading open    off    -   off     # a false-branch Boolean is open while off
expect_row_reading unread  unread off on
expect_row_reading malformed unread malformed -   # the marker row of a malformed declaration

finish

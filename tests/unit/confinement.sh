#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/confinement.sh
# Unit test for the SELinux launch-gate decision (confinement.lib.sh): the pure ai_tools_confinement_verdict
# that ai-tools-run's fail-closed preflight dispatches on. Drives the truth table over the probed inputs -- getenforce,
# module presence, the matchpathcon-expected label, the live label, the manager domain, the per-domain mode
# and the refused Booleans -- and the operator's AI_TOOLS_REQUIRE_SELINUX switch, with no SELinux host required,
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
#                [require-selinux] [domain-permissive] [boolean-states]
# Drive the verdict and assert BOTH the echoed token and the 0=launch/1=refuse return. The '|| verdict_status=$?' keeps
# a refusal (rc 1) non-fatal under `set -e` and captures the status. Each optional input is passed only when given, so
# a 5-argument call exercises the default a caller without the switch gets.
expect_verdict() {
    local expected_token="$1" expected_status="$2"; shift 2
    local verdict_token verdict_status
    verdict_token="$(ai_tools_confinement_verdict "$@")" && verdict_status=0 || verdict_status=$?
    local case_description="mode=${1:-∅} module=${2:-∅} expected=${3:-∅} actual=${4:-∅} manager=${5:-∅}"
    case_description+=" require=${6-unset} permissive=${7-unset} booleans=${8-unset}"
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

# ── AI_TOOLS_REQUIRE_SELINUX: the operator's opt-in. It turns launches into refusals and does not turn any refusal
# into a launch; every verdict without it is identical to the require=no path. ──
section "confinement: AI_TOOLS_REQUIRE_SELINUX opt-in fail-closed (unit)"
readonly CLEAN_BOOLEANS="nis_enabled=off domain_can_mmap_files=off"
# require=no reproduces the DAC-capable behaviour exactly (the explicit default is a no-op), and does not read
# the attestation inputs: a permissive domain or an enabled Boolean launches there, as global permissive does.
expect_verdict ok 0 Permissive yes ai_tools_exec_t lib_t init_t no
expect_verdict ok 0 Enforcing no "" lib_t init_t no
expect_verdict ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t no yes "nis_enabled=on"
# The DAC-only launches become refusals under require=yes.
expect_verdict require-not-enforcing 1 Permissive yes ai_tools_exec_t lib_t init_t yes  # not enforcing
expect_verdict require-not-enforcing 1 Disabled   yes ai_tools_exec_t lib_t init_t yes  # SELinux off
expect_verdict require-inactive      1 Enforcing  no  ""              lib_t init_t yes  # module absent on an enforcing host
# require does NOT loosen or alter any already-fail-closed refusal: a mislabel/unverifiable still refuses whatever
# the attestation says.
expect_verdict mislabel       1 Enforcing yes ai_tools_exec_t lib_t           init_t       yes no "${CLEAN_BOOLEANS}"
expect_verdict unverifiable   1 Enforcing yes ""              lib_t           init_t       yes no "${CLEAN_BOOLEANS}"
expect_verdict manager-domain 1 Enforcing yes ai_tools_exec_t ai_tools_exec_t some_other_t yes no "${CLEAN_BOOLEANS}"
# A verified transition with an enforced domain and the refused Booleans off launches.
expect_verdict ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t init_t       yes no "${CLEAN_BOOLEANS}"
expect_verdict ok 0 Enforcing yes ai_tools_exec_t ai_tools_exec_t unconfined_t yes no \
    "${CLEAN_BOOLEANS} kerberos_enabled=on fips_mode=on"   # a reported Boolean does not gate

section "confinement: attestation under AI_TOOLS_REQUIRE_SELINUX (unit)"
# A definite fault: a permissive domain, or a refused Boolean on.
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
IFS='|' read -r parsed_domain_permissive parsed_boolean_states \
    < <(printf 'boolean\tnis_enabled\ton\n' | ai_tools_confinement_parse_attestation_records)
if [[ -z "${parsed_domain_permissive}" && "${parsed_boolean_states}" == "nis_enabled=on" ]]; then
    pass "the shim's read keeps an empty domain mode empty"
else
    fail "the shim's read moved fields: permissive=[${parsed_domain_permissive}] booleans=[${parsed_boolean_states}]"
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
mktestdir
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

finish

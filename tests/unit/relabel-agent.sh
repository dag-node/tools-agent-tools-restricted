#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/relabel-agent.sh
# Unit test for how ai-tools-relabel-agent closes a run over the labelling library's status lines: what it files
# per agent for ai-tools status, which code it prints, and its exit status. The helper runs as root and labels the host,
# so its closing functions (render_label_report, record_label_outcomes, report_agent_unlabel_outcome) and its emitters
# are read out of it as text (extract_function) and driven in a fresh bash per case, with record_label_outcome stubbed
# to print what would be filed.
#
# The case that carries the file is a config directory that did not take its type: the run files the agent failed
# and exits 1 under the mislabel code, so ai-tools-relabel.service reads failed, beside a run where every path took its
# type as the control. A config directory whose walk left hardlinked files is said and filed as the agent's verdict,
# and the `--remove` form's rendering of each status the library returns is driven through report_agent_unlabel_outcome:
# a package erase completes over a walk that left entries, could not label one, or could not start.
#
# The deployed helper is preferred where this account can read it and it defines the functions, the checkout's
# otherwise; a non-root run reads the checkout, since the deployed helper is 750 root:root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

section "relabel-agent: closing a run over the library's status lines (unit)"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="/usr/local/libexec/ai-tools/ai-tools-relabel-agent"
# The deployed helper is current when it defines report_agent_unlabel_outcome, the last of the closing functions
# to arrive.
if [[ ! -r "${HELPER}" ]] || ! command grep -q '^report_agent_unlabel_outcome() {' "${HELPER}"; then
    HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-relabel-agent.sh"
fi
note "the closing functions" "read from ${HELPER}"

mktestdir

# The functions a case runs, in the order the helper defines them; every one must come out of the helper non-empty.
functions=(say warn die report_agent_unlabel_outcome render_label_report record_label_outcomes)
extracted="${TESTDIR}/closing.sh"
: > "${extracted}"
missing=()
for name in "${functions[@]}"; do
    body="$(extract_function "${HELPER}" "${name}")"
    if [[ -z "${body}" ]]; then missing+=("${name}"); continue; fi
    printf '%s\n' "${body}" >> "${extracted}"
done
if (( ${#missing[@]} )); then
    fail "${HELPER} does not define ${missing[*]}, so the run's close cannot be driven"
    finish; exit
fi
pass "the helper defines each function the cases drive (control)"

# The probe sources the extracted functions with the logger and the record writer stubbed, then closes a run
# over the status lines it is given, and fails over a mislabelled path as the helper's top level does. Both streams
# on stdout, the exit status last.
probe="${TESTDIR}/probe.sh"
cat > "${probe}" <<'PROBE'
set -euo pipefail
source "$1"
ai_tools_log__info() { :; }; ai_tools_log__warn() { :; }; ai_tools_log__error() { :; }
record_label_outcome() { printf 'record %s %s %s\n' "$1" "$2" "${3:-}"; }
render_label_report "$2"
record_label_outcomes
(( mislabelled == 0 )) || die MSG-A3B5 "the relabel did not take"  # ref-index: ignore (the helper defines the code)
PROBE

# close_run <status-lines> : sets OUT (both streams) and RC.
close_run() {
    RC=0; OUT="$(bash "${probe}" "${extracted}" "$1" 2>&1)" || RC=$?
}
has_line() {
    if command grep -qxF -- "$2" <<< "${OUT}"; then pass "$1"; else fail "$1: '$2' absent: ${OUT//$'\n'/ | }"; fi
}

# ── A config directory that did not take its type ────────────────────────────────────────────
section "a path that did not take its type fails the run, and every path labelled is the control"
close_run $'ok /opt/ai-tools/.acme\nagent acme ok'
has_line "control: the agent is filed ok" "record acme ok "
if [[ "${RC}" -eq 0 ]]; then pass "control: the run exits 0"; else fail "control: the run exits ${RC}"; fi
close_run $'bad /opt/ai-tools/.acme usr_t ai_tools_home_t\nagent acme failed'
has_line "the agent is filed failed with the reason a mislabel takes" "record acme failed did-not-take-its-type"
assert_msg MSG-G7C7 "${OUT}" "the run names the path and the type it carries"
if command grep -qF "wrong type on /opt/ai-tools/.acme: it is 'usr_t', NOT ai_tools_home_t" <<< "${OUT}"; then
    pass "the warning names the path, its type and the type it wanted"
else
    fail "the warning does not name the path and both types: ${OUT//$'\n'/ | }"
fi
assert_msg MSG-A3B5 "${OUT}" "the run fails over the mislabelled path"
if [[ "${RC}" -eq 1 ]]; then pass "the run exits 1"; else fail "the run exits ${RC} over a mislabelled path"; fi

# ── A config directory whose walk left hardlinked files ──────────────────────────────────────
section "a walk that left hardlinked files is said, and the agent is filed by its verdict"
close_run $'ok /opt/ai-tools/.acme
partial acme 2
agent acme ok'
has_line "the left files are said with their count" "ai-tools-relabel-agent: acme: 2 hardlinked path(s) in its config directory kept their current type"
has_line "the agent is filed as its verdict reads" "record acme ok "
if [[ "${RC}" -eq 0 ]]; then pass "the run exits 0"; else fail "the run exits ${RC} over a walk that left hardlinked files"; fi

# ── A config directory the walker could not reach ────────────────────────────────────────────
# The library's skip line for it reads `skip <agent> could not walk its config directory -- <why>`; the run files
# a reason of its own, apart from a rule that did not register, whose skip line is the control.
section "a walk that could not start is filed apart from a rule that did not register"
close_run $'skip acme could not walk its config directory -- libselinux.so.1 did not load\nagent acme failed'
has_line "the agent is filed failed as walker-unavailable" "record acme failed walker-unavailable"
close_run $'skip acme no entrypoint_fcontext declared\nagent acme failed'
has_line "control: a refused declaration is filed as rule-not-registered" "record acme failed rule-not-registered"

# ── A name of an entrypoint no declared rule covers ──────────────────────────────────────────
# The entrypoint carries its type, so the run exits 0; the finding is warned about under its code and the agent is filed
# ok with the reason `atr status` counts. The first finding an agent has is the reason its record carries.
section "a name of an entrypoint no declared rule covers is warned about and filed ok with its reason"
close_run $'ok /fixture/bin/acme\nunmapped acme /fixture/bin/acme-third\nagent acme ok'
assert_msg MSG-N4T2 "${OUT}" "an unmapped name is warned about under its code"
has_line "the agent is filed ok with the unmapped reason" "record acme ok unmapped-entrypoint-name"
if command grep -qF 'unmapped name for acme: /fixture/bin/acme-third' <<< "${OUT}"; then
    pass "the warning names the agent and the name"
else
    fail "the warning does not name the agent and the name: ${OUT//$'\n'/ | }"
fi
if [[ "${RC}" -eq 0 ]]; then pass "the run exits 0 over an unmapped name"; else fail "the run exits ${RC} over an unmapped name"; fi
close_run $'ok /fixture/bin/acme\noutside acme /fixture/bin/acme 2\nagent acme ok'
assert_msg MSG-P5G9 "${OUT}" "a name outside the toolchain is warned about under its code"
has_line "the agent is filed ok with the outside reason" "record acme ok entrypoint-name-outside-toolchain"
if command grep -qF 'its entrypoint /fixture/bin/acme has 2 name(s) outside the sandbox toolchain' <<< "${OUT}"; then
    pass "the warning carries the entrypoint and the count"
else
    fail "the warning does not carry the entrypoint and the count: ${OUT//$'\n'/ | }"
fi
close_run $'ok /fixture/bin/acme\nunread acme /fixture/bin/acme\nagent acme ok'
assert_msg MSG-T7K7 "${OUT}" "names that could not be read are warned about under their code"
has_line "the agent is filed ok with the unread reason" "record acme ok entrypoint-names-unread"
close_run $'ok /fixture/bin/acme\nunmapped acme /fixture/bin/acme-third\noutside acme /fixture/bin/acme 1\nagent acme ok'
has_line "the first finding is the reason the record carries" "record acme ok unmapped-entrypoint-name"
# A names finding beside a failure: the failure's reason is the record's, and the names reason is not written over it.
close_run $'bad /fixture/bin/acme lib_t ai_tools_exec_t\nunmapped acme /fixture/bin/acme-third\nagent acme failed'
has_line "a failed agent keeps the failure's reason" "record acme failed did-not-take-its-type"

# ── `--remove`: each status ai_tools_relabel__unlabel_agent_paths returns ────────────────────
section "--remove renders each status of the agent unlabel, and an erase completes over a walk left"
unlabel_probe="${TESTDIR}/unlabel-probe.sh"
cat > "${unlabel_probe}" <<'PROBE'
set -euo pipefail
source "$1"
ai_tools_log__info() { :; }; ai_tools_log__warn() { :; }; ai_tools_log__error() { :; }
ai_tools_providers__read_agent_manifest_field() { [[ "$2" == config_dir ]] && printf '.acme\n'; }
CP_HOME=/opt/ai-tools
AI_TOOLS_RELABEL__TREE_DIAGNOSTICS="$3"
report_agent_unlabel_outcome acme "$2"
PROBE
# unlabel_run <status> [diagnostics] : sets OUT (both streams) and RC.
unlabel_run() {
    RC=0; OUT="$(bash "${unlabel_probe}" "${extracted}" "$1" "${2:-}" 2>&1)" || RC=$?
}
unlabel_run 0
has_line "control: status 0 reports the rules dropped" "ai-tools-relabel-agent: dropped the file-context rules for acme"
if [[ "${RC}" -eq 0 ]]; then pass "control: status 0 exits 0"; else fail "control: status 0 exits ${RC}"; fi
unlabel_run 4 "skipped hardlinked path /opt/ai-tools/.acme/x (link count 2)"
assert_msg MSG-R5M2 "${OUT}" "status 4 warns that the config directory's walk left entries"
if command grep -qF 'skipped hardlinked path /opt/ai-tools/.acme/x (link count 2)' <<< "${OUT}"; then
    pass "status 4 carries the walker's diagnostics"
else
    fail "status 4 does not carry the walker's diagnostics: ${OUT//$'\n'/ | }"
fi
if [[ "${RC}" -eq 0 ]]; then pass "status 4 exits 0, so the erase completes"; else fail "status 4 exits ${RC}"; fi
unlabel_run 6 "ai-tools-relabel-tree: libselinux.so.1 does not load"
assert_msg MSG-M5X4 "${OUT}" "status 6 warns that the walk could not start"
if command grep -qF 'libselinux.so.1 does not load' <<< "${OUT}" && command grep -qF 'ai-tools-relabel-tree -- /opt/ai-tools/.acme' <<< "${OUT}"; then
    pass "status 6 carries the walker's reason and names the walk to run over the config directory"
else
    fail "status 6 does not carry the walker's reason and the walk: ${OUT//$'\n'/ | }"
fi
if [[ "${RC}" -eq 0 ]]; then pass "status 6 exits 0, so the erase completes"; else fail "status 6 exits ${RC}"; fi
unlabel_run 1
assert_msg MSG-S6C5 "${OUT}" "status 1 refuses: no usable rule"
if [[ "${RC}" -eq 1 ]]; then pass "status 1 exits 1"; else fail "status 1 exits ${RC}"; fi
unlabel_run 1 "failed to restore the file context of /opt/ai-tools/.acme/x: Permission denied; 1 entries not labelled"
assert_msg MSG-S6C5 "${OUT}" "status 1 refuses as no usable rule whatever the diagnostics hold"
unlabel_run 5 "failed to restore the file context of /opt/ai-tools/.acme/x: Permission denied; 1 entries not labelled"
assert_msg MSG-V4H3 "${OUT}" "status 5 warns that a path the dropped rules covered keeps its type"
if command grep -qF 'ai-tools-relabel-tree -- /opt/ai-tools/.acme' <<< "${OUT}"; then
    pass "status 5 names the config directory's walk as the remedy for an entry it left"
else
    fail "status 5 does not name the config directory's walk: ${OUT//$'\n'/ | }"
fi
# The same status from the entrypoint half: the diagnostic names the path left at its type.
unlabel_run 5 "/opt/ai-tools/.nvm/versions/node/v22.0.0/lib/node_modules/@acme/cli/bin/claude.exe keeps ai_tools_exec_t after its revert"
assert_msg MSG-V4H3 "${OUT}" "status 5 from an entrypoint left at its type warns under the same code"
if command grep -qF 'bin/claude.exe keeps ai_tools_exec_t after its revert' <<< "${OUT}"; then
    pass "status 5 carries the entrypoint path the revert left"
else
    fail "status 5 does not carry the entrypoint path: ${OUT//$'\n'/ | }"
fi
if command grep -qxF MSG-S6C5 <<< "${OUT}"; then
    fail "status 5 is reported as no usable rule"
else
    pass "status 5 is not reported as no usable rule"
fi
if [[ "${RC}" -eq 0 ]]; then pass "status 5 exits 0, so the erase completes"; else fail "status 5 exits ${RC}"; fi
unlabel_run 5 "the walker exited 137 without a diagnostic"
assert_msg MSG-V4H3 "${OUT}" "status 5 from a walker that printed nothing still warns that the walk failed"

finish

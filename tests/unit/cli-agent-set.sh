#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/cli-agent-set.sh
# Unit test for the ai-tools CLI's provisioning gate and the report beside it (require_bootstrap, status_provisioning).
# Both read the ENABLED agents through providers.lib.sh and key on each agent's stable launcher symlink, so the CLI does
# not name an agent of its own. Each read is asserted in its fail direction: any enabled agent's link passes the gate;
# an enabled set with no link refuses, naming the bootstrap command; an empty enabled set refuses with the resolver's
# reason -- a configuration asking for no agent, an allowlisted name with no manifest, an input the trust predicate
# refused -- with a link present, since the gate reads the set before the link; the report says per agent what the gate
# decided; and a link left for an agent that is installed and not enabled is reported as residue and counted, being
# the state every launch is refused in.
#
# Its last section drives the entrypoint half of the same report, where the failure is silent in the other direction:
# a reconciliation that REFUSED to re-record a pin leaves that pin exactly as it was, so it reads on its own
# as a verification that succeeded, beside an agent whose every launch is already refused. The mark the refusal writes
# is what tells the report otherwise, and the cases are the control (a pin alone renders its tier line), the mark
# replacing that line and counting toward the exit status, and a mark saying anything but `stale` leaving it alone.
#
# The CLI carries a sourced-guard, so this loads it as the projects user (it refuses root and the sandbox account)
# with six hooks pointed at fixtures in the testdir: AI_TOOLS_AGENTS_DIR and AI_TOOLS_OPERATOR_CONF (the resolver's,
# the pattern unit/providers.sh uses), AI_TOOLS_LAUNCHER_DIR (the link directory, the hook relabel.lib.sh reads
# for the same directory), and the three record directories the entrypoint report reads -- the pin, the stale mark
# and the label record -- so no case reads or writes the host's own records. Fixtures are root-owned, 0644 and 0755 --
# anything else the trust predicate refuses, which one case drives on purpose. Run as root via sudo (suite contract); no
# agent package needs to be installed.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root
umask 022

readonly CLI="/usr/local/bin/ai-tools"
section "cli: the provisioning gate reads the enabled agents (unit)"

if [[ ! -x "${CLI}" ]]; then skip "cli agent set" "CLI not installed at ${CLI}"; finish; exit; fi
if ! command -v runuser >/dev/null 2>&1; then skip "cli agent set" "runuser unavailable"; finish; exit; fi
# The CLI reads its command from the positional parameters, so the inner shell copies its arguments aside and clears
# them before the source -- cleared first, `$1` is gone before it is read.
# shellcheck disable=SC2016  # the $1 is for the inner `bash -c`, not this shell -- do not expand here
if ! runuser -u "${PROJECTS_USER}" -- bash -c \
        'cli="$1"; set --; source "${cli}" >/dev/null 2>&1; declare -F require_bootstrap >/dev/null 2>&1 \
            && declare -F status_provisioning >/dev/null 2>&1' _ "${CLI}"; then
    skip "cli agent set" "CLI not sourceable or the gate absent (partial install?)"; finish; exit
fi

mktestdir
AGENTS_DIR="${TESTDIR}/agents.d"; CONF="${TESTDIR}/operator.conf"; LINKS="${TESTDIR}/bin"
PINS="${TESTDIR}/entrypoint-pin.d"; STALES="${TESTDIR}/entrypoint-stale.d"; LABELS="${TESTDIR}/entrypoint-label.d"
mkdir -m 0755 "${AGENTS_DIR}" "${LINKS}" "${PINS}" "${STALES}" "${LABELS}"

# manifest <name> <launcher> <default_enable> : one agent manifest, root-owned 0644, so the trust predicate admits it.
manifest() {
    printf 'npm_package=@fixture/%s\nlauncher=%s\ndefault_enable=%s\n' "$1" "$2" "$3" > "${AGENTS_DIR}/$1.conf"
    chmod 0644 "${AGENTS_DIR}/$1.conf"
}
# operator_conf [line] : the operator.conf fixture -- OPERATORS naming the projects user, as mk_operator writes it, plus
# one optional line (an AI_TOOLS_AGENTS allowlist).
operator_conf() {
    { printf 'OPERATORS="%s"\n' "${PROJECTS_USER}"; [[ $# -gt 0 ]] && printf '%s\n' "$1"; } > "${CONF}"
    chmod 0644 "${CONF}"
}
# link <launcher> : the stable launcher symlink bootstrap writes last. Dangling on purpose: the gate reads it with `-L`.
link() { ln -s "/nonexistent/${1}" "${LINKS}/${1}"; }
reset_fixtures() { rm -f "${AGENTS_DIR}"/*.conf "${LINKS}"/*; chmod 0755 "${AGENTS_DIR}"; operator_conf; }

# call <function> : source the CLI as the projects user with the six hooks set and run one of its functions; both
# streams on stdout, the function's exit status returned. AI_TOOLS_MSG_PLAIN keeps a refusal's code on its own line.
# shellcheck disable=SC2016  # the $1/$2 are for the inner `bash -c`, not this shell -- do not expand here
call() {
    runuser -u "${PROJECTS_USER}" -- env \
        AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" AI_TOOLS_OPERATOR_CONF="${CONF}" AI_TOOLS_LAUNCHER_DIR="${LINKS}" \
        AI_TOOLS_ENTRYPOINT_PIN_DIR="${PINS}" AI_TOOLS_ENTRYPOINT_STALE_DIR="${STALES}" \
        AI_TOOLS_ENTRYPOINT_LABEL_DIR="${LABELS}" \
        AI_TOOLS_MSG_PLAIN=1 \
        bash -c 'cli="$1"; fn="$2"; set --; source "${cli}" >/dev/null 2>&1 || exit 99; "${fn}"' _ "${CLI}" "$1" 2>&1
}
# refused <what> <code> <rc> <output> : a refusal is its code AND a non-zero status -- a refusal printed at exit 0 is
# one the dispatch would read as a pass.
refused() {
    local what="$1" code="$2" rc="$3" out="$4"
    if [[ "${rc}" -eq 0 ]]; then fail "${what}: exit 0 (the gate passed): $(head -c 200 <<<"${out}" | tr '\n' '|')"
    else assert_msg "${code}" "${out}" "${what}"; fi
}
# passed <what> <rc> <output>
passed() {
    if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1: rc $2: $(head -c 200 <<<"$3" | tr '\n' '|')"; fi
}
# says <what> <pattern> <output> : the output carries the content a refusal or a report owes the reader.
says() {
    if grep -q -- "$2" <<<"$3"; then pass "$1"; else fail "$1: '$2' absent: $(head -c 300 <<<"$3" | tr '\n' '|')"; fi
}

# ── (1) Any enabled agent's launcher symlink passes ─────────────────────────────
reset_fixtures; manifest alpha la yes; link la
rc=0; out="$(call require_bootstrap)" || rc=$?
passed "one enabled agent with its launcher symlink passes the gate" "${rc}" "${out}"

reset_fixtures; manifest alpha la yes; manifest beta lb yes; link lb
rc=0; out="$(call require_bootstrap)" || rc=$?
passed "a link for either of two enabled agents passes the gate (the CLI names no agent)" "${rc}" "${out}"

# ── (2) An enabled set with no link refuses, naming the agents and the bootstrap command ──
reset_fixtures; manifest alpha la yes; manifest beta lb yes
rc=0; out="$(call require_bootstrap)" || rc=$?
refused "two enabled agents with no launcher symlink are refused" MSG-X9H7 "${rc}" "${out}"
if grep -q 'alpha' <<<"${out}" && grep -q 'beta' <<<"${out}" && grep -q 'system bootstrap' <<<"${out}"; then
    pass "the refusal names each unprovisioned agent and the bootstrap command"
else
    fail "the refusal does not name both agents and the bootstrap command: $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

# ── (3) An empty enabled set refuses with the resolver's reason, a link present notwithstanding ──

# The allowlist is exact: the gate reads the enabled set before any link, so a link for an agent the operator did not
# enable does not pass it.
reset_fixtures; manifest alpha la yes; link la; operator_conf 'AI_TOOLS_AGENTS='
rc=0; out="$(call require_bootstrap)" || rc=$?
refused "an empty AI_TOOLS_AGENTS refuses with a link present" MSG-K7A6 "${rc}" "${out}"
says "the empty-allowlist refusal carries the resolver's reason" 'set and empty' "${out}"

reset_fixtures; manifest alpha la yes; link la; operator_conf 'AI_TOOLS_AGENTS=agent-ghost'
rc=0; out="$(call require_bootstrap)" || rc=$?
refused "an allowlisted name with no manifest refuses with a link present" MSG-K7A6 "${rc}" "${out}"
says "the uninstalled-name refusal names the name" 'ghost' "${out}"

# A manifest directory a non-root writer could plant in does not yield an agent, so the gate refuses -- less access,
# reported -- where a reader of the link alone would have passed.
reset_fixtures; manifest alpha la yes; link la; chmod 0777 "${AGENTS_DIR}"
rc=0; out="$(call require_bootstrap)" || rc=$?
refused "a group-writable manifest directory refuses with a link present" MSG-K7A6 "${rc}" "${out}"
says "the untrusted-directory refusal names the trust check" 'trust check' "${out}"

# ── (4) `status` reports the same read, per agent ───────────────────────────────
reset_fixtures; manifest alpha la yes; manifest beta lb yes; link la
rc=0; out="$(call status_provisioning)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -qF 'alpha provisioned (la)' <<<"${out}" && grep -qF 'beta not provisioned' <<<"${out}"; then
    pass "status reports each enabled agent as provisioned or not, by its own link"
else
    fail "status provisioning lines (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi
says "the unprovisioned line names the bootstrap command" 'system bootstrap' "${out}"

reset_fixtures; operator_conf 'AI_TOOLS_AGENTS='
rc=0; out="$(call status_provisioning)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q 'no agent enabled' <<<"${out}"; then
    pass "status reports an empty enabled set as such, without counting it as a fault"
else
    fail "status on an empty enabled set (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

# ── (4b) An installed, not enabled agent whose link exists is residue: reported and counted ── The link is
# the operator-side read of a package still in the toolchain, the state every launch is refused in (the wrapper reads
# the same link, the shim the tree), so the line is counted and names the provisioning run. The control: the same set
# with that agent's link gone is not reported.
reset_fixtures; manifest alpha la yes; manifest beta lb no; link la; link lb
rc=0; out="$(call status_provisioning)" || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q 'beta is installed but not enabled' <<<"${out}"; then
    pass "status reports a disabled agent's remaining link as residue and counts it"
else
    fail "status residue line (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi
says "the residue line names the provisioning run" 'system bootstrap' "${out}"
reset_fixtures; manifest alpha la yes; manifest beta lb no; link la
rc=0; out="$(call status_provisioning)" || rc=$?
if [[ "${rc}" -eq 0 ]] && ! grep -q 'not enabled' <<<"${out}"; then
    pass "a disabled agent with no link is not residue"
else
    fail "status without residue (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

# ── (5) A pin a reconciliation refused to re-record is never rendered as a good one ── The refusal leaves the pin
# exactly as it was -- that staleness is what makes the next launch refuse -- so the pin still carries a VERSION
# and a VERIFIED date and reads, on its own, as a verification that succeeded. What tells the reports otherwise is
# the mark written beside it, and the failure this section exists for is silent: a green UNCHANGED beside an agent every
# launch of which is already refused. Both records are fixtures here, written in the grammar the root writer uses,
# and read through the deployed library's own hooks. The label record rendered under each tier line is redirected
# the same way, at an empty fixture directory, so it reads as never recorded and never as the host's own.
#
# `status_entrypoint_pins` is what renders the pin and the mark, so it is what is driven: the pin alone first,
# as the control that the tier line is reached at all, then the same pin with the mark.
pin_record() {
    printf '# fixture pin\nAGENT=%s\nVERSION=%s\nSHA256=%s\nKIND=%s\nVERIFIED=%s\n' \
        "$1" "$2" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" "$3" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${PINS}/$1"
    chmod 0644 "${PINS}/$1"
}
# stale_record <agent> <version> <reason> [state] : the mark a refused re-record leaves. <state> defaults to `stale`,
# the one value that means a refusal.
stale_record() {
    printf '# fixture stale mark\nAGENT=%s\nSTATE=%s\nVERSION=%s\nREASON=%s\nDETECTED=%s\n' \
        "$1" "${4:-stale}" "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${STALES}/$1"
    chmod 0644 "${STALES}/$1"
}

reset_fixtures; rm -f "${PINS}"/* "${STALES}"/*
manifest alpha la yes; link la; pin_record alpha 1.2.3 observed
rc=0; out="$(call status_entrypoint_pins)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q 'UNCHANGED' <<<"${out}"; then
    pass "an observed pin with no mark renders its tier line (the control for the case below)"
else
    fail "an observed pin did not render UNCHANGED (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

stale_record alpha 1.2.4 tamper
rc=0; out="$(call status_entrypoint_pins)" || rc=$?
if grep -q 'PIN STALE' <<<"${out}" && ! grep -q 'UNCHANGED' <<<"${out}"; then
    pass "a stale mark replaces the tier line: the refused pin is never rendered as UNCHANGED"
else
    fail "a stale observed pin still rendered its tier line: $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi
[[ "${rc}" -ne 0 ]] \
    && pass "a stale pin counts toward the report's exit status, the state in which every launch is refused" \
    || fail "status_entrypoint_pins exited 0 over a stale pin"
says "the stale line names the installed version the refusal was about" '1\.2\.4' "${out}"
says "the stale line names the reconcile command" 'entrypoints relabel' "${out}"

# A mark whose STATE is anything else is not a refusal, and must not turn the tier line red: the reader is a record
# grammar, so an unrecognised value reads as "no mark" rather than as one.
stale_record alpha 1.2.4 tamper cleared
rc=0; out="$(call status_entrypoint_pins)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q 'UNCHANGED' <<<"${out}" && ! grep -q 'PIN STALE' <<<"${out}"; then
    pass "a mark that does not say stale leaves the tier line as it was"
else
    fail "a non-stale mark changed the rendering (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

finish

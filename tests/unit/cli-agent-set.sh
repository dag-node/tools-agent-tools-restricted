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

# manifest <name> <launcher> <default_enable> : one agent manifest, root-owned 0644, so the trust predicate accepts it.
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

# ── (6) The Version section's Node line reads the launcher link, not the updater's record ── The link is repointed
# by every path that changes Node, so the line is right after a bootstrap as after an update, and it is the read
# the launch banner makes; the updater's stamp is the host's real one here and is read alongside, so what is asserted is
# the link's version being the one named, and the absence of any version where no link names one.
# shellcheck disable=SC2016  # the $1 is for the inner `bash -c`, not this shell -- do not expand here
if runuser -u "${PROJECTS_USER}" -- bash -c \
        'cli="$1"; set --; source "${cli}" >/dev/null 2>&1; declare -F status_node_version >/dev/null 2>&1' _ "${CLI}"; then
    # vlink <launcher> <version> : a stable link in the shape ai-tools-launcher-symlink writes, dangling on purpose.
    vlink() { ln -sfn "/nonexistent/.nvm/versions/node/${2}/bin/${1}" "${LINKS}/${1}"; }
    reset_fixtures; rm -f "${PINS}"/* "${STALES}"/* "${LABELS}"/*; manifest alpha la yes; vlink la v9.9.9
    rc=0; out="$(call status_node_version)" || rc=$?
    if [[ "${rc}" -eq 0 ]] && grep -qF 'node v9.9.9' <<<"${out}"; then
        pass "the Node line names the version the enabled agent's launcher link points into"
    else
        fail "Node line from one link (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
    fi

    reset_fixtures; manifest alpha la yes; manifest beta lb yes; vlink la v9.9.9; vlink lb v9.9.8
    rc=0; out="$(call status_node_version)" || rc=$?
    if [[ "${rc}" -eq 0 ]] && grep -qF 'alpha=v9.9.9 beta=v9.9.8' <<<"${out}" \
            && grep -q 'different Node versions' <<<"${out}"; then
        pass "links naming different versions are reported as such, each agent named"
    else
        fail "Node line from disagreeing links (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
    fi

    reset_fixtures; manifest alpha la yes; link la
    rc=0; out="$(call status_node_version)" || rc=$?
    if [[ "${rc}" -eq 0 ]] && ! grep -q 'node v9' <<<"${out}" && ! grep -q 'active' <<<"${out}"; then
        pass "a link outside the versioned shape names no version, and the line does not claim one"
    else
        fail "Node line from an unversioned link (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
    fi
else
    skip "status node line" "status_node_version absent from ${CLI} (older CLI)"
fi

# ── (7) The exit status of `status` follows ai-tools-records(5): 4 for a fault a section read, 5 for a reading
# a section could not make ── cmd_status is driven whole, with the sections that read this host stubbed to a known
# answer (no unit in the registry, a clean PATH ordering, no pins), so each case changes one reading. The registry's
# readers are removed after the CLI loaded them, which is the shape a half-upgraded install takes; the later sections
# still print, so the page carries every reading it could make beside the one it could not.
# shellcheck disable=SC2016  # the $1 is for the inner `bash -c`, not this shell -- do not expand here
if runuser -u "${PROJECTS_USER}" -- bash -c \
        'cli="$1"; set --; source "${cli}" >/dev/null 2>&1; declare -F status_fold >/dev/null 2>&1' _ "${CLI}"; then
    # call_status <pre> : as call, running <pre> in the sourced shell before cmd_status; the CLI's own `set -e` ends
    # the shell with cmd_status's return, which is the status under test.
    # shellcheck disable=SC2016  # the $1/$2 are for the inner `bash -c`, not this shell -- do not expand here
    call_status() {
        runuser -u "${PROJECTS_USER}" -- env \
            AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" AI_TOOLS_OPERATOR_CONF="${CONF}" AI_TOOLS_LAUNCHER_DIR="${LINKS}" \
            AI_TOOLS_ENTRYPOINT_PIN_DIR="${PINS}" AI_TOOLS_ENTRYPOINT_STALE_DIR="${STALES}" \
            AI_TOOLS_ENTRYPOINT_LABEL_DIR="${LABELS}" \
            AI_TOOLS_MSG_PLAIN=1 \
            bash -c 'cli="$1"; pre="$2"; set --; source "${cli}" >/dev/null 2>&1 || exit 99
                     ai_tools_service_records() { :; }; status_path_order() { return 0; }
                     status_entrypoint_pins() { return 0; }; status_selinux_attestation() { return 0; }
                     eval "${pre}"; cmd_status' _ "${CLI}" "$1" 2>&1
    }
    reset_fixtures; rm -f "${PINS}"/* "${STALES}"/* "${LABELS}"/*; manifest alpha la yes; link la
    rc=0; out="$(call_status ':')" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        pass "a report whose every section read clean exits 0"
    else
        fail "clean status exited ${rc}: $(tail -c 300 <<<"${out}" | tr '\n' '|')"
    fi
    rc=0; out="$(call_status 'status_path_order() { return 1; }')" || rc=$?
    if [[ "${rc}" -eq 4 ]]; then
        pass "a section that read a fault makes status exit 4"
    else
        fail "a counted fault exited ${rc}, expected 4: $(tail -c 300 <<<"${out}" | tr '\n' '|')"
    fi
    rc=0; out="$(call_status 'unset -f ai_tools_service_records')" || rc=$?
    if [[ "${rc}" -eq 5 ]] && grep -qx 'MSG-X5Z8' <<<"${out}" && grep -qF 'ai-tools providers' <<<"${out}"; then
        pass "a service registry that did not load exits 5, is named under its code, and the later sections still print"
    else
        fail "a missing registry exited ${rc}, expected 5 with MSG-X5Z8 and the rest of the page: $(tail -c 400 <<<"${out}" | tr '\n' '|')"
    fi
    rc=0; out="$(call_status 'status_provisioning() { return "${STATUS_UNREADABLE}"; }')" || rc=$?
    if [[ "${rc}" -eq 5 ]]; then
        pass "a section reporting a reading it could not make (its unreadable return) exits 5"
    else
        fail "an unreadable section exited ${rc}, expected 5: $(tail -c 300 <<<"${out}" | tr '\n' '|')"
    fi
    rc=0; out="$(call_status 'status_path_order() { return 1; }; unset -f ai_tools_service_records')" || rc=$?
    if [[ "${rc}" -eq 5 ]]; then
        pass "a fault read beside a reading that could not be made exits 5: unreadable wins the fold"
    else
        fail "fault plus unreadable exited ${rc}, expected 5"
    fi
else
    skip "status exit" "status_fold absent from ${CLI} (older CLI)"
fi

# ── The SELinux attestation section returns a fault only where AI_TOOLS_REQUIRE_SELINUX makes it refuse a launch ──
# `getenforce` and the selinuxfs reader are stubbed after the library is loaded, so its include guard keeps
# the section's own re-source from restoring the reader. The `operator.conf` fixtures are root-owned, as the trust
# predicate requires. The stub reads a `stub_*` name: bash scopes dynamically, so a stub reading `attestation_records`
# would see the section's own unset local of that name rather than the value set here.
section "status: the SELinux status section (unit)"
REQUIRED_CONF="${TESTDIR}/operator-required.conf"; NOT_REQUIRED_CONF="${TESTDIR}/operator-not-required.conf"
printf 'AI_TOOLS_REQUIRE_SELINUX=yes\n' > "${REQUIRED_CONF}"; printf 'AI_TOOLS_REQUIRE_SELINUX=no\n' > "${NOT_REQUIRED_CONF}"
chmod 0644 "${REQUIRED_CONF}" "${NOT_REQUIRED_CONF}"
# call_attestation_section <records> <operator-conf> [selinux-mode] [module-present] [policy-shipped] : print
# the section, then `section-status=<n>`. The mode and the two module readers default to a confined host (Enforcing,
# live, shipped); a case about a host without confinement by its own configuration sets them.
# shellcheck disable=SC2016  # the $1..$7 are for the inner `bash -c`, not this shell -- do not expand here
call_attestation_section() {
    runuser -u "${PROJECTS_USER}" -- env AI_TOOLS_MSG_PLAIN=1 \
        bash -c 'cli="$1"; lib="$2"; stub_attestation_records="$3"; operator_conf="$4"
                 stub_selinux_mode="$5"; stub_module_present="$6"; stub_policy_shipped="$7"; set --
                 source "${cli}" >/dev/null 2>&1 || exit 99
                 declare -F status_selinux_attestation >/dev/null || exit 98
                 source "${lib}" 2>/dev/null; declare -F ai_tools_confinement_list_attestation_report >/dev/null || exit 97
                 declare -F ai_tools_confinement_dac_only_state >/dev/null || exit 97
                 getenforce() { printf "%s\n" "${stub_selinux_mode}"; }
                 ai_tools_confinement_read_attestation_records() { printf "%s\n" "${stub_attestation_records}"; }
                 ai_tools_confinement_read_module_present() { printf "%s" "${stub_module_present}"; }
                 ai_tools_confinement_read_policy_shipped() { printf "%s" "${stub_policy_shipped}"; }
                 section_status=0; status_selinux_attestation "${operator_conf}" || section_status=$?
                 printf "section-status=%s\n" "${section_status}"' \
        _ "${CLI}" /usr/local/lib/ai-tools/confinement.lib.sh "$1" "$2" "${3:-Enforcing}" "${4:-yes}" "${5:-yes}" 2>&1
}
rc=0; out="$(call_attestation_section $'permissive\tyes' "${REQUIRED_CONF}")" || rc=$?
if [[ "${rc}" -ge 97 ]]; then
    skip "status attestation" "the installed CLI or confinement library predates the section (rc ${rc})"
else
    if grep -qx 'section-status=1' <<<"${out}" && grep -qF 'PERMISSIVE' <<<"${out}"; then
        pass "a permissive domain under the requirement is a fault, named with its remedy"
    else
        fail "permissive under the requirement: $(tr '\n' '|' <<<"${out}")"
    fi
    out="$(call_attestation_section $'permissive\tyes\nboolean\tnis_enabled\ton' "${NOT_REQUIRED_CONF}")" || true
    if grep -qx 'section-status=0' <<<"${out}" && grep -qF 'launches are not refused' <<<"${out}" \
            && grep -qF '(required: off, built in, not enforced -- when on, allows bind' <<<"${out}"; then
        pass "the same reading without the requirement is reported and not a fault"
    else
        fail "permissive without the requirement: $(tr '\n' '|' <<<"${out}")"
    fi
    out="$(call_attestation_section $'permissive\tno\nboolean\tnis_enabled\toff\nboolean\tdomain_can_mmap_files\toff\nboolean\tdomain_can_write_kmsg\toff' \
               "${REQUIRED_CONF}")" || true
    if grep -qx 'section-status=0' <<<"${out}"; then
        pass "an attested host under the requirement is not a fault"
    else
        fail "attested host under the requirement: $(tr '\n' '|' <<<"${out}")"
    fi
    # A Boolean whose rules are shut names what it would allow once opened, so its row does not read as a failed one.
    out="$(call_attestation_section $'permissive\tno\nboolean\tauthlogin_nsswitch_use_ldap\toff\nboolean\tdeny_ptrace\ton' \
               "${NOT_REQUIRED_CONF}")" || true
    if grep -qF 'off (when on, would allow LDAP connects' <<<"${out}" \
            && grep -qF 'on (when off, would allow ptrace)' <<<"${out}"; then
        pass "a Boolean with its rules shut names what it would allow, whichever value opens it"
    else
        fail "closed Boolean rows: $(tr '\n' '|' <<<"${out}")"
    fi
    # A declaration renders its origin, a Boolean outside the registry, and the malformed row, which is a fault under
    # the requirement.
    DECLARED_CONF="${TESTDIR}/operator-declared.conf"
    printf 'AI_TOOLS_REQUIRE_SELINUX=yes\nAI_TOOLS_SELINUX_BOOLEANS=[nis_enabled=on, ai_tools_test_extra=on, bad]\n' > "${DECLARED_CONF}"
    out="$(call_attestation_section $'permissive\tno\nboolean\tnis_enabled\ton\nboolean\tai_tools_test_extra\ton' \
               "${DECLARED_CONF}")" || true
    if grep -qx 'section-status=1' <<<"${out}" && grep -qF '(required: on, operator.conf' <<<"${out}" \
            && grep -qF 'ai_tools_test_extra' <<<"${out}" && grep -qF 'MALFORMED' <<<"${out}"; then
        pass "a declaration renders its origin, a Boolean outside the registry, and the malformed row as a fault"
    else
        fail "declaration rendering: $(tr '\n' '|' <<<"${out}")"
    fi
    # A host without SELinux confinement by its own configuration has no domain to attest; under the requirement every
    # launch runs DAC-only with a warning, which is a fault naming the line that declares the host so.
    out="$(call_attestation_section '' "${REQUIRED_CONF}" Disabled)" || true
    if grep -qx 'section-status=1' <<<"${out}" && grep -qF 'SELinux is disabled' <<<"${out}" \
            && grep -qF 'AI_TOOLS_REQUIRE_SELINUX=no' <<<"${out}"; then
        pass "SELinux disabled under the requirement is a fault naming AI_TOOLS_REQUIRE_SELINUX=no"
    else
        fail "SELinux disabled under the requirement: $(tr '\n' '|' <<<"${out}")"
    fi
    out="$(call_attestation_section '' "${REQUIRED_CONF}" Enforcing no no)" || true
    if grep -qx 'section-status=1' <<<"${out}" && grep -qF 'not installed' <<<"${out}" \
            && ! grep -qF 'could not be read' <<<"${out}"; then
        pass "a policy never installed under the requirement is a fault, with no unread rows"
    else
        fail "policy never installed under the requirement: $(tr '\n' '|' <<<"${out}")"
    fi
    out="$(call_attestation_section '' "${NOT_REQUIRED_CONF}" Enforcing no no)" || true
    if grep -qx 'section-status=0' <<<"${out}" && grep -qF 'without a warning' <<<"${out}"; then
        pass "the same host without the requirement is reported and not a fault"
    else
        fail "policy never installed without the requirement: $(tr '\n' '|' <<<"${out}")"
    fi
fi

finish

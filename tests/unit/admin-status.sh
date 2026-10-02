#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/admin-status.sh
# Unit test for the Version section of `ai-tools-admin status`: its Node line reads the enabled agents' stable launcher
# links through the same verdict `ai-tools status` renders (ai_tools_node_version_verdict, toolchain.lib.sh), so the two
# reports name one version for one host. What is asserted is the root report's rendering of that verdict against fixture
# links -- the version a link points into, the split line where two links disagree, and no claimed version where no link
# names one -- with the updater's stamp being the host's own and read alongside. The Provisioning section is read
# the same way, per enabled agent's link, beside a base file that makes the launcher directory non-empty on every host.
#
# The helper is SOURCED rather than run (its root check and its dispatch are guarded for that), in a fresh shell
# per case because the helper and the harness both declare SANDBOX_USER readonly, with the resolver's two hooks
# and AI_TOOLS_LAUNCHER_DIR pointed at fixtures in the testdir. Fixtures are root-owned 0644 in a 0755 directory,
# which the trust predicate admits, so this runs as root via sudo (suite contract); no agent package needs to be
# installed.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="/usr/local/libexec/ai-tools/ai-tools-admin"
[[ -r "${HELPER}" ]] || HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
SERVICES_LIB="/usr/local/lib/ai-tools/services.lib.sh"

section "ai-tools-admin status: the Node line reads the launcher links (unit)"

if [[ ! -r "${HELPER}" ]]; then
    skip "admin status node line" "helper not readable (neither installed nor in a checkout)"; finish; exit
fi
# shellcheck disable=SC2016  # the $1 is for the inner `bash -c`, not this shell -- do not expand here
if ! bash -c 'helper="$1"; set --; source "${helper}" >/dev/null 2>&1; declare -F status_node_version >/dev/null 2>&1' \
        _ "${HELPER}"; then
    skip "admin status node line" "helper not sourceable or status_node_version absent (older helper?)"; finish; exit
fi

mktestdir
AGENTS_DIR="${TESTDIR}/agents.d"; CONF="${TESTDIR}/operator.conf"; LINKS="${TESTDIR}/bin"
mkdir -m 0755 "${AGENTS_DIR}" "${LINKS}"

# manifest <name> <launcher> : one agent manifest, root-owned 0644, enabled by default.
manifest() {
    printf 'npm_package=@fixture/%s\nlauncher=%s\ndefault_enable=yes\n' "$1" "$2" > "${AGENTS_DIR}/$1.conf"
    chmod 0644 "${AGENTS_DIR}/$1.conf"
}
printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${CONF}"; chmod 0644 "${CONF}"
# vlink <launcher> <version> : a stable link in the shape ai-tools-launcher-symlink writes, dangling on purpose.
vlink() { ln -sfn "/nonexistent/.nvm/versions/node/${2}/bin/${1}" "${LINKS}/${1}"; }
reset_fixtures() { rm -f "${AGENTS_DIR}"/*.conf "${LINKS}"/*; }

# call : source the helper with the hooks set and run status_node_version; both streams on stdout. The services library
# is sourced beside it, as status() does before the section runs, so the stamp branch is exercised too.
# shellcheck disable=SC2016  # the $1/$2 are for the inner `bash -c`, not this shell -- do not expand here
call() {
    env AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" AI_TOOLS_OPERATOR_CONF="${CONF}" AI_TOOLS_LAUNCHER_DIR="${LINKS}" \
        bash -c 'helper="$1"; lib="$2"; set --; source "${helper}" >/dev/null 2>&1 || exit 99
                 source "${lib}" 2>/dev/null || true; status_node_version' _ "${HELPER}" "${SERVICES_LIB}" 2>&1
}

reset_fixtures; manifest alpha la; vlink la v9.9.9
rc=0; out="$(call)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -qE '^ +node +v9\.9\.9' <<<"${out}"; then
    pass "the Node line names the version the enabled agent's launcher link points into"
else
    fail "Node line from one link (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

reset_fixtures; manifest alpha la; manifest beta lb; vlink la v9.9.9; vlink lb v9.9.8
rc=0; out="$(call)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -qF 'alpha=v9.9.9 beta=v9.9.8' <<<"${out}" && grep -q 'different Node versions' <<<"${out}"; then
    pass "links naming different versions are reported as such, each agent named"
else
    fail "Node line from disagreeing links (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

reset_fixtures; manifest alpha la; ln -s /nonexistent/la "${LINKS}/la"
rc=0; out="$(call)" || rc=$?
if [[ "${rc}" -eq 0 ]] && ! grep -q 'v9' <<<"${out}" && ! grep -q 'active' <<<"${out}"; then
    pass "a link outside the versioned shape names no version, and the line does not claim one"
else
    fail "Node line from an unversioned link (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

section "ai-tools-admin status: Provisioning reads each enabled agent's launcher link (unit)"

# call_provisioning : as call, running status_provisioning and printing the count it leaves in STATUS_PROBLEMS.
# shellcheck disable=SC2016  # the $1 is for the inner `bash -c`, not this shell -- do not expand here
call_provisioning() {
    env AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" AI_TOOLS_OPERATOR_CONF="${CONF}" AI_TOOLS_LAUNCHER_DIR="${LINKS}" \
        bash -c 'helper="$1"; set --; source "${helper}" >/dev/null 2>&1 || exit 99
                 declare -F status_provisioning >/dev/null || exit 98
                 status_provisioning; printf "problems=%s\n" "${STATUS_PROBLEMS}"' _ "${HELPER}" 2>&1
}

# The base package installs its own files in the launcher directory, so a directory that is not empty says nothing
# about any agent: the fixture holds such a file and no agent link.
reset_fixtures; manifest alpha la; : > "${LINKS}/ai-tools-run"
rc=0; out="$(call_provisioning)" || rc=$?
if [[ "${rc}" -eq 98 ]]; then
    skip "admin status provisioning" "status_provisioning absent (older helper?)"
elif grep -qE '^ +\[MISSING\] +alpha has no launcher' <<<"${out}" && ! grep -qF '[OK]' <<<"${out}" \
        && grep -qx 'problems=0' <<<"${out}"; then
    pass "an enabled agent without its link is reported missing, beside base files, and not counted"
else
    fail "provisioning with base files and no agent link (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

reset_fixtures; manifest alpha la; : > "${LINKS}/ai-tools-run"; vlink la v9.9.9
rc=0; out="$(call_provisioning)" || rc=$?
if [[ "${rc}" -eq 98 ]]; then
    skip "admin status provisioning" "status_provisioning absent (older helper?)"
elif grep -qE '^ +\[OK\] +alpha provisioned \(la\)' <<<"${out}" && grep -qx 'problems=0' <<<"${out}"; then
    pass "an enabled agent whose launcher link exists is reported provisioned"
else
    fail "provisioning with the agent link (rc ${rc}): $(head -c 300 <<<"${out}" | tr '\n' '|')"
fi

# ── The exit status: 0 clean, 4 for a fault a section read, 5 for a reading a section could not make ──────────────
# `status` is driven whole, with the sections that read this host stubbed to a known answer (no unit in the registry, no
# entrypoint section), so each case changes one reading: a section that counts a fault, and the service registry's
# readers removed after the library was loaded -- its include guard keeps status()'s own re-source from restoring them,
# which is the shape a half-upgraded install takes. A `?` line stays uncounted, which the Provisioning cases already
# pin.
section "ai-tools-admin status: the exit status follows ai-tools-records(5) (unit)"

# call_status <pre> : source the helper with the hooks set, run <pre> in that shell, then `status`; the exit status is
# the function's, since the sourced helper's `set -e` ends the shell on a non-zero return.
# shellcheck disable=SC2016  # the $1/$2/$3 are for the inner `bash -c`, not this shell -- do not expand here
call_status() {
    env AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" AI_TOOLS_OPERATOR_CONF="${CONF}" AI_TOOLS_LAUNCHER_DIR="${LINKS}" \
        bash -c 'helper="$1"; lib="$2"; pre="$3"; set --; source "${helper}" >/dev/null 2>&1 || exit 99
                 declare -F status >/dev/null || exit 98
                 source "${lib}" 2>/dev/null || true
                 status_entrypoints() { :; }; ai_tools_service_records() { :; }
                 status_selinux_attestation() { :; }
                 eval "${pre}"; status' _ "${HELPER}" "${SERVICES_LIB}" "$1" 2>&1
}
reset_fixtures; manifest alpha la; vlink la v9.9.9
rc=0; out="$(call_status ':')" || rc=$?
if [[ "${rc}" -eq 98 ]]; then
    skip "admin status exit" "status absent (older helper?)"
elif [[ "${rc}" -eq 0 ]]; then
    pass "a report whose every section read clean exits 0"
else
    fail "clean report exited ${rc}: $(tail -c 300 <<<"${out}" | tr '\n' '|')"
fi
rc=0; out="$(call_status 'status_services() { heading Services; STATUS_PROBLEMS=$(( STATUS_PROBLEMS + 1 )); }')" || rc=$?
if [[ "${rc}" -eq 4 ]]; then
    pass "a section that read a fault makes the report exit 4"
else
    fail "a counted fault exited ${rc}, expected 4: $(tail -c 300 <<<"${out}" | tr '\n' '|')"
fi
rc=0; out="$(call_status 'unset -f ai_tools_service_records')" || rc=$?
if [[ "${rc}" -eq 5 ]] && grep -qx 'MSG-V6N9' <<<"${out}" && grep -qF '[UNREADABLE]' <<<"${out}" \
        && grep -qF 'ai-tools providers' <<<"${out}"; then
    pass "a service registry that did not load exits 5, is named under its code, and the later sections still print"
else
    fail "a missing registry exited ${rc}, expected 5 with MSG-V6N9 and the rest of the page: $(tail -c 400 <<<"${out}" | tr '\n' '|')"
fi
rc=0; out="$(call_status 'unset -f ai_tools_service_records; status_provisioning() { heading Provisioning; STATUS_PROBLEMS=1; }')" || rc=$?
if [[ "${rc}" -eq 5 ]]; then
    pass "a fault read beside a reading that could not be made exits 5: unreadable wins the fold"
else
    fail "fault plus unreadable exited ${rc}, expected 5"
fi

# ── The SELinux attestation section counts a finding only where AI_TOOLS_REQUIRE_SELINUX makes it refuse a launch ──
# `getenforce` and the selinuxfs reader are stubbed as shell functions, after the library is loaded, so its include
# guard keeps the section's own re-source from restoring the reader. Each case prints the section and the problem count.
# The stubs read `stub_*` names: bash scopes dynamically, so a stub reading `selinux_mode` would see the section's own
# unset local of that name rather than the value set here.
section "ai-tools-admin status: the SELinux attestation section (unit)"
CONFINEMENT_LIB_INSTALLED="/usr/local/lib/ai-tools/confinement.lib.sh"
REQUIRED_CONF="${TESTDIR}/operator-required.conf"; NOT_REQUIRED_CONF="${TESTDIR}/operator-not-required.conf"
printf 'AI_TOOLS_REQUIRE_SELINUX=yes\n' > "${REQUIRED_CONF}"
printf 'AI_TOOLS_REQUIRE_SELINUX=no\n'  > "${NOT_REQUIRED_CONF}"
readonly CLEAN_ATTESTATION=$'permissive\tno\nboolean\tnis_enabled\toff\nboolean\tdomain_can_mmap_files\toff\nboolean\tdomain_can_write_kmsg\toff'

# call_attestation_section <selinux-mode> <records> <operator-conf> : print the section, then `problems=<n>`.
# shellcheck disable=SC2016  # the $1..$5 are for the inner `bash -c`, not this shell -- do not expand here
call_attestation_section() {
    bash -c 'helper="$1"; lib="$2"; stub_selinux_mode="$3"; stub_attestation_records="$4"; operator_conf="$5"; set --
             source "${helper}" >/dev/null 2>&1 || exit 99
             declare -F status_selinux_attestation >/dev/null || exit 98
             source "${lib}" 2>/dev/null || exit 97
             declare -F ai_tools_confinement_list_attestation_report >/dev/null || exit 97
             getenforce() { printf "%s\n" "${stub_selinux_mode}"; }
             ai_tools_confinement_read_attestation_records() { printf "%s\n" "${stub_attestation_records}"; }
             STATUS_PROBLEMS=0; STATUS_UNREADABLE=0
             status_selinux_attestation "${operator_conf}"
             printf "problems=%s\n" "${STATUS_PROBLEMS}"' \
        _ "${HELPER}" "${CONFINEMENT_LIB_INSTALLED}" "$1" "$2" "$3" 2>&1
}
rc=0; out="$(call_attestation_section Enforcing "${CLEAN_ATTESTATION}" "${REQUIRED_CONF}")" || rc=$?
if [[ "${rc}" -ge 97 ]]; then
    skip "admin status attestation" "the installed helper or confinement library predates the section (rc ${rc})"
else
    if grep -qx 'problems=0' <<<"${out}" && grep -qF '[enforcing]' <<<"${out}"; then
        pass "an enforced domain with the gating Booleans off is not counted, under the requirement"
    else
        fail "clean attestation under the requirement: $(tr '\n' '|' <<<"${out}")"
    fi
    out="$(call_attestation_section Enforcing $'permissive\tyes\nboolean\tnis_enabled\toff\nboolean\tdomain_can_mmap_files\ton' \
               "${REQUIRED_CONF}")" || true
    if grep -qx 'problems=1' <<<"${out}" && grep -qF '[PERMISSIVE]' <<<"${out}" && grep -qF '[ON]' <<<"${out}" \
            && grep -qF 'every launch refuses' <<<"${out}"; then
        pass "a permissive domain and a gating Boolean on count once under the requirement, each named with its remedy"
    else
        fail "faults under the requirement: $(tr '\n' '|' <<<"${out}")"
    fi
    out="$(call_attestation_section Enforcing $'permissive\tyes' "${NOT_REQUIRED_CONF}")" || true
    if grep -qx 'problems=0' <<<"${out}" && grep -qF 'launches are not refused' <<<"${out}"; then
        pass "the same fault without the requirement is reported and not counted"
    else
        fail "fault without the requirement: $(tr '\n' '|' <<<"${out}")"
    fi
    out="$(call_attestation_section Enforcing '' "${REQUIRED_CONF}")" || true
    if grep -qx 'problems=1' <<<"${out}" && [[ "$(grep -c '\[?\]' <<<"${out}")" -ge 3 ]]; then
        pass "nothing readable is reported per reading and counted under the requirement, since it refuses every launch"
    else
        fail "unread attestation under the requirement: $(tr '\n' '|' <<<"${out}")"
    fi
    out="$(call_attestation_section Disabled "${CLEAN_ATTESTATION}" "${REQUIRED_CONF}")" || true
    if grep -qx 'problems=0' <<<"${out}" && grep -qF '[n/a]' <<<"${out}"; then
        pass "SELinux disabled reads n/a here; the launch refusal for it is the preflight's to report"
    else
        fail "SELinux disabled: $(tr '\n' '|' <<<"${out}")"
    fi
fi

finish

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/entrypoint-pin.sh
# Integration: the observed tier's reconciliation, driven through the deployed ai-tools-relabel-agent. The pure decision
# behind it is covered in tests/unit/entrypoint-verify.sh; what has no coverage without this file is the I/O around it
# -- which pin lands on disk, which one is deliberately left standing, and what the run tells the operator when it
# refuses.
#
# Three runs over one fixture agent, in the order a host meets them:
#
#   fresh                       -> a pin is written, KIND=observed
#   the same version, new bytes -> REFUSED: the pin is left byte-identical, a stale mark is filed beside it,
#                                  and the output names the two commands that replace the binary
#   a new version, new bytes    -> re-pinned, and the stale mark is cleared
#
# The third is the observed tier's stated LIMIT rather than a guarantee (updater.rule.md): both versions come
# from a package.json inside the toolchain, which the sandbox account owns, so on a DAC-only host this tier detects
# a rewrite that leaves the declared version alone, and no other change. It is asserted here so that changing it is
# a decision someone makes deliberately.
#
# Everything is a fixture: the manifest directory, the operator config, the launcher directory, and all three record
# directories are redirected through the root-only test hooks, so the host's own pins are never read or written --
# which matters more here than in most files, since corrupting a real pin refuses every launch on this host until
# the next reconcile. The SELinux half is switched off at its own probe (a `selinuxenabled` stub that exits non-zero),
# so the labelling this helper would otherwise perform cannot reach the policy store; the semanage stub beside it is
# the assertion that it did not. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-relabel-agent"
readonly VERIFY_LIB="/usr/local/lib/ai-tools/entrypoint-verify.lib.sh"
section "entrypoint pin: the observed tier's reconciliation (integration)"

if [[ ! -x "${HELPER}" ]]; then
    skip "observed-pin reconciliation" "not installed at ${HELPER}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${VERIFY_LIB}" 2>/dev/null || ! declare -F ai_tools_entrypoint_stale_path >/dev/null 2>&1; then
    skip "observed-pin reconciliation" "the installed ${VERIFY_LIB} carries no stale-mark reader -- reinstall to cover it"
    finish; exit
fi

mktestdir

# ── The fixture host ─────────────────────────────────────────────────────────────────────────
# Every input the resolver reads must be root-owned and not group- or other-writable, or it refuses it and does not
# resolve any agent at all -- so the modes here are part of the fixture rather than housekeeping.
agents_dir="${TESTDIR}/agents.d"
launcher_dir="${TESTDIR}/bin"
pin_dir="${TESTDIR}/pins"
label_dir="${TESTDIR}/labels"
stale_dir="${TESTDIR}/stale"
stub_bin="${TESTDIR}/stub-bin"
package_dir="${TESTDIR}/toolchain/lib/node_modules/@test/pinprobe"
mkdir -p "${agents_dir}" "${launcher_dir}" "${pin_dir}" "${label_dir}" "${stale_dir}" \
         "${stub_bin}" "${package_dir}/bin"
chmod 0755 "${agents_dir}" "${launcher_dir}" "${pin_dir}" "${label_dir}" "${stale_dir}"

# The agent: no release_manifest_url, so the reconciliation takes the observed tier. Laid
# out under `lib/node_modules/<package>` because that is what the refusal's remedy is composed from -- the directory
# a forced reinstall has to remove.
printf '#!/bin/sh\nexit 0\n' > "${package_dir}/bin/pinprobe"
chmod 0755 "${package_dir}/bin/pinprobe"
printf '{"version":"1.2.3"}\n' > "${package_dir}/package.json"
ln -sfn "${package_dir}/bin/pinprobe" "${launcher_dir}/pinprobe"

cat > "${agents_dir}/pinprobe.conf" <<EOF
npm_package=@test/pinprobe
launcher=pinprobe
display_name=Pin Probe
entrypoint_fcontext=/opt/ai-tools/\\.nvm/versions/node/[^/]+/lib/node_modules/@test/pinprobe/bin/pinprobe
default_enable=yes
EOF
printf 'AI_TOOLS_AGENTS=pinprobe\n' > "${TESTDIR}/operator.conf"
chmod 0644 "${agents_dir}/pinprobe.conf" "${TESTDIR}/operator.conf"

# The SELinux half, switched off at the one probe that decides it, so the labelling cannot reach the policy store
# on an enforcing host. `semanage` is stubbed beside it as the assertion rather than the mechanism: a run that reaches
# it records a line, and the file fails.
printf '#!/bin/sh\nexit 1\n' > "${stub_bin}/selinuxenabled"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/semanage.log"\nexit 0\n' "${TESTDIR}" > "${stub_bin}/semanage"
chmod 0755 "${stub_bin}/selinuxenabled" "${stub_bin}/semanage"

# run_reconcile : run the deployed helper over the fixture host, printing its combined output. Its exit status is
# the caller's to read.
run_reconcile() {
    env PATH="${stub_bin}:${PATH}" \
        AI_TOOLS_AGENTS_DIR="${agents_dir}" \
        AI_TOOLS_OPERATOR_CONF="${TESTDIR}/operator.conf" \
        AI_TOOLS_LAUNCHER_DIR="${launcher_dir}" \
        AI_TOOLS_ENTRYPOINT_PIN_DIR="${pin_dir}" \
        AI_TOOLS_ENTRYPOINT_LABEL_DIR="${label_dir}" \
        AI_TOOLS_ENTRYPOINT_STALE_DIR="${stale_dir}" \
        AI_TOOLS_RELABEL_LOCK="${TESTDIR}/relabel.lock" \
        "${HELPER}" 2>&1
}

# ── (1) A fresh host records what is installed ───────────────────────────────────────────────
out="$(run_reconcile)" && rc=0 || rc=$?
if (( rc != 0 )); then
    fail "the first reconciliation over a fresh fixture failed (exit ${rc}): ${out}"
elif [[ ! -f "${pin_dir}/pinprobe" ]]; then
    fail "the first reconciliation wrote no pin"
else
    pass "a fresh entrypoint is pinned"
fi
if grep -q '^KIND=observed$' "${pin_dir}/pinprobe" 2>/dev/null \
   && grep -q '^VERSION=1\.2\.3$' "${pin_dir}/pinprobe" 2>/dev/null; then
    pass "the pin records the observed tier and the installed version"
else
    fail "the pin does not carry KIND=observed at the installed version: $(cat "${pin_dir}/pinprobe" 2>/dev/null)"
fi
first_pin="$(cat "${pin_dir}/pinprobe")"
if [[ -e "${stale_dir}/pinprobe" ]]; then
    fail "a clean reconciliation filed a stale mark"
else
    pass "a clean reconciliation files no stale mark"
fi

# ── (2) The same version, different bytes: the one state no update explains ──────────────────
printf '#!/bin/sh\nexit 1\n' > "${package_dir}/bin/pinprobe"
out="$(run_reconcile)" && rc=0 || rc=$?
if (( rc == 0 )); then
    fail "a binary that changed under an unchanged version was accepted"
else
    pass "a binary that changed under an unchanged version fails the reconciliation"
fi
assert_msg MSG-U6H8 "${out}" "the refusal names the entrypoint that changed under its version"
assert_msg MSG-W6V4 "${out}" "the run ends by naming the toolchain as tampered"

# The pin is left EXACTLY as it was: that staleness is the gate. Re-recording here would bless the one change the tier
# exists to catch, and rewriting it in any other way would refuse a launch for the wrong reason.
if [[ "$(cat "${pin_dir}/pinprobe")" == "${first_pin}" ]]; then
    pass "the refused reconciliation left the pin byte-identical"
else
    fail "the pin was rewritten by a reconciliation that refused to re-record it"
fi

# And the refusal is now READABLE: without the mark beside it, both status reports render that untouched pin from its
# own VERSION and VERIFIED, green, while every launch of the agent is already failing.
if [[ -f "${stale_dir}/pinprobe" ]] \
   && grep -q '^STATE=stale$' "${stale_dir}/pinprobe" \
   && grep -q '^REASON=changed-under-same-version$' "${stale_dir}/pinprobe"; then
    pass "the refusal files a stale mark the status reports can read"
else
    fail "no stale mark was filed for a refused re-record: $(cat "${stale_dir}/pinprobe" 2>/dev/null)"
fi

# The remedy names the package directory, because the provisioning command alone is a no-op at a version that is already
# installed -- the failure mode of the remedy this replaced.
if grep -q "rm -rf ${package_dir}$" <<<"${out}" && grep -q 'system bootstrap' <<<"${out}"; then
    pass "the refusal names the package directory to remove before reprovisioning"
else
    fail "the refusal does not name the forced-reinstall commands: ${out}"
fi

# ── (3) A new version with new bytes reads as an update ──────────────────────────────────────
# The tier's stated limit, asserted so that changing it takes a decision someone makes deliberately.
printf '{"version":"1.2.4"}\n' > "${package_dir}/package.json"
out="$(run_reconcile)" && rc=0 || rc=$?
if (( rc != 0 )); then
    fail "a version change with new bytes did not reconcile (exit ${rc}): ${out}"
elif grep -q '^VERSION=1\.2\.4$' "${pin_dir}/pinprobe"; then
    pass "a new version carrying new bytes is re-pinned -- the observed tier's stated limit"
else
    fail "the pin was not re-recorded at the new version: $(cat "${pin_dir}/pinprobe")"
fi
if [[ -e "${stale_dir}/pinprobe" ]]; then
    fail "the stale mark survived a reconciliation that re-recorded the pin -- status would report a healthy host as refusing"
else
    pass "re-recording the pin clears the stale mark"
fi

# ── The policy store was never touched ───────────────────────────────────────────────────────
# The point of the stubs: this file drives a helper whose second half writes SELinux file-context rules, and a suite
# that registered one against a fixture path could strand it in the host's policy on a failed run.
if [[ -s "${TESTDIR}/semanage.log" ]]; then
    fail "the reconciliation called semanage: $(cat "${TESTDIR}/semanage.log")"
else
    pass "no reconciliation in this file reached the policy store"
fi

finish

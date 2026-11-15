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
# A fourth case switches the agent to the verified tier with a release manifest it cannot fetch: the pin stays,
# and the installed bytes against it decide the report -- the release-unverified mark the launch words its refusal
# from, its clear, or a changed binary under the pinned release.
#
# The third is the observed tier's stated LIMIT rather than a guarantee (updater.rule.md): both versions come
# from a package.json inside the toolchain, which the sandbox account owns, so on a DAC-only host this tier detects
# a rewrite that leaves the declared version alone, and no other change. It is asserted here so that changing it is
# a decision someone makes deliberately.
#
# Everything is a fixture: the manifest directory, the operator config, the launcher directory, and all three record
# directories are redirected through the root-only test hooks, so the host's own pins are never read or written --
# which matters more here than in most files, since corrupting a real pin refuses every launch on this host until
# the next reconcile. The SELinux half is switched off at the probe the labelling library reads (a `getenforce` stub
# answering `Disabled`), so the labelling this helper would otherwise perform cannot reach the policy store;
# the semanage stub beside it is the assertion that it did not. The stubs need a directory where a 0755 file is VISIBLE
# as executable: bash's PATH search asks access(2), which a noexec mount answers false, so a stub under such a /tmp is
# passed over and the real command runs in its place -- a fixture rule in the host's policy store. The testdir is used
# when it qualifies and a directory beside the operator's home otherwise. The runs go through a copy of the deployed
# file whose PATH line names the stub directory first; the switch is asserted to have taken before the first run
# and read back from the helper's own line after it. Run as root via sudo.

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
if ! source "${VERIFY_LIB}" 2>/dev/null || ! declare -F ai_tools_entrypoint_verify__get_stale_path >/dev/null 2>&1; then
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
package_dir="${TESTDIR}/toolchain/lib/node_modules/@test/pinprobe"
mkdir -p "${agents_dir}" "${launcher_dir}" "${pin_dir}" "${label_dir}" "${stale_dir}" "${package_dir}/bin"
chmod 0755 "${agents_dir}" "${launcher_dir}" "${pin_dir}" "${label_dir}" "${stale_dir}"

# can_mark_file_executable <dir> : succeed when a 0755 file created in <dir> answers `-x`, which is what bash's PATH
# search asks.
can_mark_file_executable() {
    local probe="$1/.x-probe.$$" ok=1
    printf '' > "${probe}" 2>/dev/null || return 1
    chmod 0755 "${probe}" 2>/dev/null || { rm -f "${probe}"; return 1; }
    [[ -x "${probe}" ]] && ok=0
    rm -f "${probe}"
    return "${ok}"
}
stub_bin="${TESTDIR}/stub-bin"
mkdir -p "${stub_bin}"
if ! can_mark_file_executable "${stub_bin}"; then
    mk_fixture_dir stub_bin "${PROJECTS_HOME}" pinstubs 2>/dev/null || stub_bin=""
fi
if [[ -z "${stub_bin}" ]] || ! can_mark_file_executable "${stub_bin}"; then
    skip "observed-pin reconciliation" "no directory here reports a 0755 file as executable (a noexec mount), so the SELinux half cannot be stubbed off"
    finish; exit
fi
chmod 0755 "${stub_bin}"

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
printf 'AI_TOOLS_AGENTS=agent-pinprobe\n' > "${TESTDIR}/operator.conf"
chmod 0644 "${agents_dir}/pinprobe.conf" "${TESTDIR}/operator.conf"

# The SELinux half, switched off at the probe that decides it: relabel.lib.sh reads `getenforce`, and `Disabled` is
# the answer that returns the library before its first `semanage` call, so the labelling cannot reach the policy store.
# `semanage` is stubbed beside it as the assertion rather than the mechanism: a run that reaches it records a line,
# and the file fails.
printf '#!/bin/sh\necho Disabled\n' > "${stub_bin}/getenforce"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/semanage.log"\nexit 0\n' "${TESTDIR}" > "${stub_bin}/semanage"
chmod 0755 "${stub_bin}/getenforce" "${stub_bin}/semanage"

# The helper sets its own PATH as it starts (cli.rule.md, ref-section-g7c8), so the runs go through a copy
# of the deployed helper whose PATH line names the stub directory first, run as `bash <copy>` since the copy sits
# in the testdir.
readonly HELPER_PATH_LINE='PATH=/usr/sbin:/usr/bin:/sbin:/bin'
helper_copy="${TESTDIR}/ai-tools-relabel-agent"
sed "s|^${HELPER_PATH_LINE}\$|PATH=${stub_bin}:${HELPER_PATH_LINE#PATH=}|" -- "${HELPER}" > "${helper_copy}"

# run_reconcile [VAR=VAL ...] : run the copy of the deployed helper over the fixture host, with any further assignments
# in its environment, printing its combined output. Its exit status is the caller's to read.
run_reconcile() {
    env AI_TOOLS_AGENTS_DIR="${agents_dir}" \
        AI_TOOLS_OPERATOR_CONF="${TESTDIR}/operator.conf" \
        AI_TOOLS_LAUNCHER_DIR="${launcher_dir}" \
        AI_TOOLS_ENTRYPOINT_PIN_DIR="${pin_dir}" \
        AI_TOOLS_ENTRYPOINT_LABEL_DIR="${label_dir}" \
        AI_TOOLS_ENTRYPOINT_STALE_DIR="${stale_dir}" \
        AI_TOOLS_RELABEL_LOCK="${TESTDIR}/relabel.lock" \
        "$@" bash "${helper_copy}" 2>&1
}

# The switch is asserted BEFORE the first run, and the file stops here when it did not take: a run whose PATH search
# passes over the stubs registers the fixture's rule in the host's policy store, which no teardown here removes. Three
# readings, each of which stops the file: the copy differs from the deployed helper in its PATH line alone,
# so the helper's own text is what runs; the copy holds one PATH line, the rewritten one; and a shell given that line's
# value resolves both commands to the stubs.
copy_changes="$(diff -- "${HELPER}" "${helper_copy}" | grep '^[<>]' || true)"
copy_path="$(sed -n 's/^PATH=//p' -- "${helper_copy}")"
if [[ "${copy_changes}" != "< ${HELPER_PATH_LINE}"$'\n'"> PATH=${stub_bin}:${HELPER_PATH_LINE#PATH=}" \
   || "${copy_path}" != "${stub_bin}:${HELPER_PATH_LINE#PATH=}" ]]; then
    skip_required "observed-pin reconciliation" \
        "the installed ${HELPER} does not hold the line ${HELPER_PATH_LINE}, so no copy can name the stubs -- reinstall to cover it"
    finish; exit
fi
resolved_stubs="$(env -i PATH="${copy_path}" /usr/bin/bash -c 'command -v getenforce semanage' 2>/dev/null || true)"
if [[ "${resolved_stubs}" != "${stub_bin}/getenforce"$'\n'"${stub_bin}/semanage" \
   || "$("${stub_bin}/getenforce" 2>/dev/null)" != Disabled ]]; then
    fail "the stubs are not what the helper's PATH resolves (got: ${resolved_stubs}) -- no reconciliation run"
    finish; exit
fi

# ── (1) A fresh host records what is installed ───────────────────────────────────────────────
out="$(run_reconcile)" && rc=0 || rc=$?
if (( rc != 0 )); then
    fail "the first reconciliation over a fresh fixture failed (exit ${rc}): ${out}"
elif [[ ! -f "${pin_dir}/pinprobe" ]]; then
    fail "the first reconciliation wrote no pin"
else
    pass "a fresh entrypoint is pinned"
fi
# Read back from the helper's own report: the line it prints when the labelling library found no type to assign.
if grep -qF 'SELinux confinement inactive' <<<"${out}"; then
    pass "the labelling half read the stubbed probe and did not run"
else
    fail "the labelling half ran despite the stubbed probe -- inspect the host's policy store for a pinprobe rule: ${out}"
    finish; exit
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
# Every session ends before root removes files in the sandbox account's tree: the refusal says so, leaving the operator
# to let a session finish, and `ai-tools stop` is the first command.
stop_line="$(grep -n -m1 '^ *atr stop$' <<<"${out}" | cut -d: -f1)"
remove_line="$(grep -n -m1 "rm -rf ${package_dir}$" <<<"${out}" | cut -d: -f1)"
if [[ -n "${stop_line}" && -n "${remove_line}" ]] && (( stop_line < remove_line )) \
        && grep -qF 'let each finish, or stop them all' <<<"${out}"; then
    pass "the forced-reinstall remedy stops every session before the removal"
else
    fail "the remedy does not name ai-tools stop ahead of the removal: ${out}"
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

# ── (4) The verified tier, a release that cannot be verified ─────────────────────────────────
# The fixture agent declares a release manifest at an address that refuses the connection, so the reconcile reaches
# its unable-to-verify branch and leaves the pin as it was. What it then reports is decided by the installed bytes
# against that pin, as the launch decides: another release with other bytes files the release-unverified mark bound
# to those bytes, at exit 0 (an rpm %post runs it offline); the pinned bytes launch, and clear that mark; the pinned
# release with other bytes is the change no update explains, refused as the observed tier refuses it.
if ! declare -F ai_tools_entrypoint_verify__evaluate_unverified_release_stale_mark >/dev/null 2>&1; then
    skip "unverified release" "the installed ${VERIFY_LIB} carries no unverified-release decision -- reinstall to cover it"
else
    printf 'fixture key, never read: the manifest fetch fails first\n' > "${TESTDIR}/release-key.asc"
    chmod 0644 "${TESTDIR}/release-key.asc"
    cat >> "${agents_dir}/pinprobe.conf" <<EOF
release_manifest_url=https://127.0.0.1:9/{version}/manifest.json
release_key=${TESTDIR}/release-key.asc
release_fingerprint=0123456789ABCDEF0123456789ABCDEF01234567
EOF
    installed_sha256="$(sha256sum -- "${package_dir}/bin/pinprobe")"
    installed_sha256="${installed_sha256%% *}"
    other_sha256="$(printf '%064d' 0)"
    # pin_fixture <version> <sha256> : a verified-tier pin.
    pin_fixture() {
        printf 'AGENT=pinprobe\nVERSION=%s\nSHA256=%s\nKIND=verified\nVERIFIED=1970-01-01T00:00:00Z\n' "$1" "$2" \
            > "${pin_dir}/pinprobe"
        chmod 0644 "${pin_dir}/pinprobe"
    }

    # (4a) Another release, other bytes.
    pin_fixture 1.2.3 "${other_sha256}"
    rm -f -- "${stale_dir}/pinprobe"
    unverified_pin="$(cat "${pin_dir}/pinprobe")"
    out="$(run_reconcile)" && rc=0 || rc=$?
    if (( rc == 0 )); then
        pass "a release that cannot be verified leaves the run at exit 0"
    else
        fail "the reconcile failed on a release it could not verify (exit ${rc}): ${out}"
    fi
    assert_msg MSG-B6H9 "${out}" "the run names the release it could not verify"
    assert_msg MSG-E9R7 "${out}" "the run says the pin holds another release and launches refuse"
    if [[ "$(cat "${pin_dir}/pinprobe")" == "${unverified_pin}" ]]; then
        pass "the previous release's pin is left byte-identical"
    else
        fail "the pin was rewritten by a reconcile that could not verify the release"
    fi
    if grep -q '^STATE=stale$' "${stale_dir}/pinprobe" 2>/dev/null \
       && grep -q '^REASON=release-unverified$' "${stale_dir}/pinprobe" \
       && grep -q '^VERSION=1\.2\.4$' "${stale_dir}/pinprobe" \
       && grep -q "^SHA256=${installed_sha256}$" "${stale_dir}/pinprobe"; then
        pass "the run files a release-unverified mark for the installed release, bound to the bytes it read"
    else
        fail "no release-unverified mark bound to the installed bytes was filed: $(cat "${stale_dir}/pinprobe" 2>/dev/null)"
    fi

    # (4b) A mark of a changed binary stays: the installed version is the sandbox account's to write, so an unverified
    # release must not reword the refusal that mark carries.
    printf 'AGENT=pinprobe\nSTATE=stale\nVERSION=1.2.4\nREASON=signature-mismatch\nDETECTED=1970-01-01T00:00:00Z\n' \
        > "${stale_dir}/pinprobe"
    tamper_mark="$(cat "${stale_dir}/pinprobe")"
    out="$(run_reconcile)" && rc=0 || rc=$?
    if (( rc == 0 )) && [[ "$(cat "${stale_dir}/pinprobe" 2>/dev/null)" == "${tamper_mark}" ]] \
            && ! grep -q 'MSG-E9R7' <<<"${out}"; then
        pass "an unverified release leaves a signature-mismatch mark as it is, at exit 0"
    else
        fail "an unverified release replaced a signature-mismatch mark (exit ${rc}): $(cat "${stale_dir}/pinprobe" 2>/dev/null)"
    fi
    assert_msg MSG-Y9F4 "${out}" "the run names the mark of a changed binary it kept"
    if grep -q "rm -rf ${package_dir}$" <<<"${out}"; then
        pass "the kept mark is named with the commands that replace the binary"
    else
        fail "the kept mark is not named with the reinstall remedy: ${out}"
    fi

    # (4c) Another release carrying the pinned bytes launches, so an unverified-release mark no longer describes it.
    pin_fixture 1.2.3 "${installed_sha256}"
    printf 'AGENT=pinprobe\nSTATE=stale\nVERSION=1.2.4\nREASON=release-unverified\nDETECTED=1970-01-01T00:00:00Z\n' \
        > "${stale_dir}/pinprobe"
    out="$(run_reconcile)" && rc=0 || rc=$?
    if (( rc == 0 )) && [[ ! -e "${stale_dir}/pinprobe" ]] && ! grep -q 'MSG-E9R7' <<<"${out}"; then
        pass "the pinned bytes under another release clear the release-unverified mark"
    else
        fail "the pinned bytes left the release-unverified mark (exit ${rc}): $(cat "${stale_dir}/pinprobe" 2>/dev/null) ${out}"
    fi
    # A binary restored to the pinned bytes launches, and resolves a mark about bytes against the pin.
    printf 'AGENT=pinprobe\nSTATE=stale\nVERSION=1.2.4\nREASON=changed-under-same-version\nDETECTED=1970-01-01T00:00:00Z\n' \
        > "${stale_dir}/pinprobe"
    out="$(run_reconcile)" && rc=0 || rc=$?
    if (( rc == 0 )) && [[ ! -e "${stale_dir}/pinprobe" ]] && grep -qF 'matches its pin' <<<"${out}"; then
        pass "restored pinned bytes clear a changed-under-same-version mark, and the run says the binary matches its pin"
    else
        fail "restored pinned bytes left a changed-under-same-version mark (exit ${rc}): $(cat "${stale_dir}/pinprobe" 2>/dev/null) ${out}"
    fi
    # A signature failure is a finding about the vendor's manifest, which matching bytes do not resolve: an offline run
    # leaves it and names it, beside the line saying the binary matches its pin.
    printf 'AGENT=pinprobe\nSTATE=stale\nVERSION=1.2.4\nREASON=signature-mismatch\nDETECTED=1970-01-01T00:00:00Z\n' \
        > "${stale_dir}/pinprobe"
    signature_mark="$(cat "${stale_dir}/pinprobe")"
    out="$(run_reconcile)" && rc=0 || rc=$?
    if (( rc == 0 )) && [[ "$(cat "${stale_dir}/pinprobe" 2>/dev/null)" == "${signature_mark}" ]] \
            && grep -qF 'matches its pin' <<<"${out}"; then
        pass "matching bytes leave a signature-mismatch mark as it is, and the run says the binary matches its pin"
    else
        fail "matching bytes changed or cleared a signature-mismatch mark (exit ${rc}): $(cat "${stale_dir}/pinprobe" 2>/dev/null) ${out}"
    fi
    assert_msg MSG-E9Y2 "${out}" "the run names the signature failure that stands"
    rm -f -- "${stale_dir}/pinprobe"

    # (4d) The pinned release with the pinned bytes: the launch starts it, and no mark is filed.
    pin_fixture 1.2.4 "${installed_sha256}"
    out="$(run_reconcile)" && rc=0 || rc=$?
    if (( rc == 0 )) && [[ ! -e "${stale_dir}/pinprobe" ]]; then
        pass "the pinned release with the pinned bytes takes no mark"
    else
        fail "the pinned release with the pinned bytes took a mark (exit ${rc}): $(cat "${stale_dir}/pinprobe" 2>/dev/null) ${out}"
    fi

    # (4e) The pinned release with other bytes: the launch refuses, so the run says why and prints the remedy. It
    # still exits 0 and goes on to the labelling: the release could not be verified, and an rpm %post runs this offline.
    pin_fixture 1.2.4 "${other_sha256}"
    changed_pin="$(cat "${pin_dir}/pinprobe")"
    out="$(run_reconcile)" && rc=0 || rc=$?
    if (( rc == 0 )) && grep -qF 'SELinux confinement inactive' <<<"${out}"; then
        pass "a changed binary found while the release could not be verified leaves exit 0, and the labelling half runs"
    else
        fail "a changed binary found without verification stopped the run before its labelling (exit ${rc}): ${out}"
    fi
    assert_msg MSG-U6H8 "${out}" "the unverified run names the entrypoint that changed under its version"
    if [[ "$(cat "${pin_dir}/pinprobe")" == "${changed_pin}" ]] \
       && grep -q '^REASON=changed-under-same-version$' "${stale_dir}/pinprobe" 2>/dev/null \
       && grep -q "rm -rf ${package_dir}$" <<<"${out}"; then
        pass "the pin is left as it is, the mark names the change, and the remedy names the package directory"
    else
        fail "the changed binary was not reported as the observed tier reports it: $(cat "${stale_dir}/pinprobe" 2>/dev/null) ${out}"
    fi

    # (4f) No pin: the launch starts the binary unpinned unless verification is required, and the run says so.
    rm -f -- "${pin_dir}/pinprobe" "${stale_dir}/pinprobe"
    out="$(run_reconcile)" && rc=0 || rc=$?
    if (( rc == 0 )) && [[ ! -e "${stale_dir}/pinprobe" ]] && grep -qF 'no pin is recorded' <<<"${out}"; then
        pass "an unverified release with no pin files no mark and says the sessions start unpinned"
    else
        fail "an unverified release with no pin was not reported as unpinned (exit ${rc}): ${out}"
    fi
    # No pin, and a signature failure an earlier run recorded: the finding stands and is named.
    printf 'AGENT=pinprobe\nSTATE=stale\nVERSION=1.2.4\nREASON=signature-mismatch\nDETECTED=1970-01-01T00:00:00Z\n' \
        > "${stale_dir}/pinprobe"
    out="$(run_reconcile)" && rc=0 || rc=$?
    if (( rc == 0 )) && grep -q '^REASON=signature-mismatch$' "${stale_dir}/pinprobe" 2>/dev/null \
            && grep -qF 'no pin is recorded' <<<"${out}"; then
        pass "with no pin, a signature failure stands and the run says the sessions start unpinned"
    else
        fail "with no pin, the signature failure was not kept beside the unpinned line (exit ${rc}): ${out}"
    fi
    assert_msg MSG-E9Y2 "${out}" "the run names the finding that stands with no pin"

    # (4g) Pin reuse, the unattended callers' path: a pin that answers the question is reused without a manifest fetch,
    # and a mark beside it is a finding no reuse settles, so the run takes the full verification instead and the mark
    # stays. The control is the same reusable pin with no mark, which must take the reuse path, so a run that never
    # reached it cannot pass as the refusal to reuse.
    reuse_inputs="$(ai_tools_entrypoint_verify__calculate_inputs_digest 'https://127.0.0.1:9/{version}/manifest.json' \
                        "${TESTDIR}/release-key.asc" 0123456789ABCDEF0123456789ABCDEF01234567 2>/dev/null || true)"
    printf 'AGENT=pinprobe\nVERSION=1.2.4\nSHA256=%s\nKIND=verified\nVERIFIED=1970-01-01T00:00:00Z\nINPUTS=%s\n' \
        "${installed_sha256}" "${reuse_inputs}" > "${pin_dir}/pinprobe"
    chmod 0644 "${pin_dir}/pinprobe"
    rm -f -- "${stale_dir}/pinprobe"
    out="$(run_reconcile AI_TOOLS_ENTRYPOINT_PIN_REUSE=1)" && rc=0 || rc=$?
    if [[ ! "${reuse_inputs}" =~ ^[0-9a-f]{64}$ ]]; then
        fail "control: the fixture's inputs digest could not be computed, so the reuse case proves nothing"
    elif (( rc == 0 )) && grep -qF 'signature not re-checked' <<<"${out}"; then
        pass "control: a reusable pin with no mark is reused without a manifest fetch"
    else
        fail "control: a reusable pin with no mark was not reused (exit ${rc}): ${out}"
    fi
    printf 'AGENT=pinprobe\nSTATE=stale\nVERSION=1.2.4\nREASON=signature-mismatch\nDETECTED=1970-01-01T00:00:00Z\n' \
        > "${stale_dir}/pinprobe"
    signature_mark="$(cat "${stale_dir}/pinprobe")"
    out="$(run_reconcile AI_TOOLS_ENTRYPOINT_PIN_REUSE=1)" && rc=0 || rc=$?
    if (( rc == 0 )) && ! grep -qF 'signature not re-checked' <<<"${out}" \
            && [[ "$(cat "${stale_dir}/pinprobe" 2>/dev/null)" == "${signature_mark}" ]]; then
        pass "a pin with a signature-mismatch mark beside it is not reused, and the mark stays"
    else
        fail "a reusable pin cleared or bypassed a signature-mismatch mark (exit ${rc}): $(cat "${stale_dir}/pinprobe" 2>/dev/null) ${out}"
    fi
    assert_msg MSG-B6H9 "${out}" "the run with a mark standing took the verification instead of the reuse"
fi

# ── No write reached the policy store ────────────────────────────────────────────────────────
# The point of the stubs: this file drives a helper whose second half writes SELinux file-context rules, and a suite
# that registered one against a fixture path could strand it in the host's policy on a failed run.
if [[ -s "${TESTDIR}/semanage.log" ]]; then
    fail "the reconciliation called semanage: $(cat "${TESTDIR}/semanage.log")"
else
    pass "no reconciliation in this file reached the policy store"
fi

finish

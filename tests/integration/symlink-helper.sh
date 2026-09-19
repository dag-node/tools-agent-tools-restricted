#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/symlink-helper.sh
# Integration: the ai-tools-launcher-symlink root helper -- the only writer of the locked /opt/ai-tools/bin. It must
# repoint a stable launcher symlink ONLY at a path of the versioned shape whose launcher an ENABLED agent manifest
# claims, and refuse everything else. Two properties carry the security here, and this suite asserts both: the path
# shape (the helper cannot trust its caller -- the sandbox account reaches it through the handback socket),
# and the manifest allowlist (without it, any binary sitting in a versioned bin/ could be given a stable link
# in the control-plane directory).
#
# Refusal cases touch no path; the happy path targets the symlink's CURRENT target, so it is idempotent -- and when no
# relabel is pending it skips the repoint entirely (reporting "already current") rather than churning the link. Run
# as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly helper="/usr/local/libexec/ai-tools/ai-tools-launcher-symlink"
readonly bin_dir="/opt/ai-tools/bin"
section "ai-tools-launcher-symlink: validation + idempotent repoint (integration)"

if [[ ! -x "${helper}" ]]; then
    skip "launcher symlink helper" "not installed at ${helper}"; finish; exit
fi

# (A) Refuse paths outside the versioned-launcher shape (no write, exit != 0).
for bogus in \
    "/etc/passwd" \
    "/opt/ai-tools/.nvm/versions/node/v22.0.0/../../../../bin/sh" \
    "/opt/ai-tools/.nvm/versions/node/notaversion/bin/claude" \
    "/opt/ai-tools/.nvm/versions/node/v22.0.0/lib/claude"
do
    if out="$("${helper}" "${bogus}" 2>&1)"; then
        fail "helper accepted a target outside the versioned-launcher shape: ${bogus}"
    else
        assert_msg MSG-W5K8 "${out}" \
            "helper refuses a target outside the versioned-launcher shape: ${bogus}"
    fi
done

# (B) Refuse a correctly-shaped but non-existent version, for a launcher that IS claimed.
if out="$("${helper}" "/opt/ai-tools/.nvm/versions/node/v0.0.0/bin/claude" 2>&1)"; then
    fail "helper accepted a versioned path that does not exist (v0.0.0)"
else
    assert_msg MSG-T8B9 "${out}" "helper refuses a versioned path that does not exist"
fi

# (C) Refuse a correctly-shaped path whose launcher NO enabled agent manifest claims -- the allowlist half. `node` is
# a real binary in that same directory, which makes it the case that matters: shape alone would accept it, and accepting
# it would put a stable control-plane link on a binary no agent package declared.
cur="$(readlink "${bin_dir}/claude" 2>/dev/null || true)"
if [[ ! "${cur}" =~ ^/opt/ai-tools/\.nvm/versions/node/v[0-9]+\.[0-9]+\.[0-9]+/bin/claude$ ]]; then
    skip "unclaimed-launcher refusal" "no resolvable versioned launcher symlink to derive a sibling from"
else
    sibling="${cur%/*}/node"
    if [[ ! -x "${sibling}" ]]; then
        skip "unclaimed-launcher refusal" "no sibling binary to probe at ${sibling}"
    elif out="$("${helper}" "${sibling}" 2>&1)"; then
        fail "helper linked ${bin_dir}/node -- a launcher no enabled agent manifest claims"
    elif [[ -e "${bin_dir}/node" ]]; then
        fail "helper refused but ${bin_dir}/node exists -- the refusal wrote to the locked dir"
    else
        # By code, not by exit status: the sibling passes the shape check, so only the code says the allowlist half is
        # what refused it.
        assert_msg MSG-G4F4 "${out}" "helper refuses a launcher no enabled agent manifest claims"
    fi
fi

# (E) Containment across the symlink, and the declared-entrypoint match. The path's SHAPE says where the link sits;
# what a session executes is what that path RESOLVES to, and a string match cannot follow a link. Each case here is
# correctly shaped and claimed by an enabled manifest, so shape and allowlist alone would accept them and put a stable
# control-plane link on a file the toolchain never installed.
#
# Probed in a THROWAWAY version directory (v0.0.2), never the live one -- the helper only needs the path to be
# semver-shaped. Like integration/ai-tools-run.sh's v0.0.1, this fixture cannot carry the harness's name rule,
# so the residue sweep lists it by name and one already present is a FAILURE rather than a skip: skipping would let
# residue silently cost the coverage.
#
# The target deliberately does NOT sit where claude-code's entrypoint_fcontext would match ([^/]+ spans the version
# directory, so a fixture under `lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe` would be ACCEPTED and would
# repoint the live link at it).
fake_version_dir="/opt/ai-tools/.nvm/versions/node/v0.0.2"
before="$(readlink "${bin_dir}/claude" 2>/dev/null || true)"
if [[ -e "${fake_version_dir}" ]]; then
    fail "${fake_version_dir} already exists -- residue of an earlier run; run \`tests/run.sh residue\` and rerun"
else
    _cleanup+=("${fake_version_dir}")
    mkdir -p "${fake_version_dir}/bin" "${fake_version_dir}/opt"
    printf '#!/bin/sh\nexit 0\n' > "${fake_version_dir}/opt/claude.exe"
    chmod 0755 "${fake_version_dir}/opt/claude.exe"

    # (E1) Inside the version directory, so containment holds -- but at a path no declared entrypoint rule covers. Such
    # a file does not take ai_tools_exec_t, so a link to it fails every launch closed at the label preflight.
    ln -sfn "${fake_version_dir}/opt/claude.exe" "${fake_version_dir}/bin/claude"
    if out="$("${helper}" "${fake_version_dir}/bin/claude" 2>&1)"; then
        fail "helper accepted a target the declared entrypoint_fcontext does not cover"
    else
        assert_msg MSG-D4X6 "${out}" \
            "helper refuses a target no enabled manifest's entrypoint_fcontext covers"
    fi

    # (E2) Escapes the version directory: a real, executable target in a version directory the toolchain did not
    # installed is what a repointed link would look like.
    ln -sfn /bin/sh "${fake_version_dir}/bin/claude"
    if out="$("${helper}" "${fake_version_dir}/bin/claude" 2>&1)"; then
        fail "helper accepted a target resolving outside its own version directory"
    else
        assert_msg MSG-P2R8 "${out}" \
            "helper refuses a target resolving outside its own version directory"
    fi

    # (E3) Covered by the declared pattern as a raw regex, yet by a pattern the relabel would refuse: an alternation
    # whose first branch names the fixture. The helper holds the pattern to the relabel's containment before it matches,
    # so the link is refused here rather than at the label preflight one launch later. The manifest is a fixture copy
    # of the shipped one, read through the root-only AI_TOOLS_AGENTS_DIR hook; the resolver refuses a directory
    # or a copy that is not root-owned and unwritable by others, so the copy is read back through it first, or a refused
    # fixture would pass as the refusal under test.
    mktestdir
    fixture_agents="${TESTDIR}/agents.d"
    mkdir -m 0755 "${fixture_agents}"
    alternation='/opt/ai-tools/\.nvm/versions/node/[^/]+/opt/claude\.exe|/nowhere'
    # The line is replaced in bash, not through a sed replacement: sed reads the pattern's `\.` as an escaped dot
    # and writes a bare one, so the copy would declare a pattern the shipped manifest does not.
    while IFS= read -r manifest_line; do
        [[ "${manifest_line}" == entrypoint_fcontext=* ]] && manifest_line="entrypoint_fcontext=${alternation}"
        printf '%s\n' "${manifest_line}"
    done < /usr/local/lib/ai-tools/agents.d/claude-code.conf > "${fixture_agents}/claude-code.conf"
    chmod 0644 "${fixture_agents}/claude-code.conf"
    ln -sfn "${fake_version_dir}/opt/claude.exe" "${fake_version_dir}/bin/claude"
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    read_back="$(env AI_TOOLS_AGENTS_DIR="${fixture_agents}" bash -c \
        'source /usr/local/lib/ai-tools/providers.lib.sh && ai_tools_agent_manifest_field claude-code entrypoint_fcontext' \
        2>/dev/null || true)"
    if [[ "${read_back}" != "${alternation}" ]]; then
        fail "the fixture manifest does not read back through the resolver (got '${read_back}'), so the case cannot be driven"
    elif out="$(env AI_TOOLS_AGENTS_DIR="${fixture_agents}" "${helper}" "${fake_version_dir}/bin/claude" 2>&1)"; then
        fail "helper accepted a target under an entrypoint_fcontext carrying an alternation"
    else
        assert_msg MSG-D4X6 "${out}" \
            "helper refuses a pattern the relabel's containment refuses, although it covers the target as a raw regex"
        if [[ "${out}" == *"not a plain path pattern under"* ]]; then
            pass "the refusal names the containment, not a missing match"
        else
            fail "the refusal does not name the containment: ${out}"
        fi
    fi

    # No refusal may have touched the locked directory -- not the live link, and not a link of its own.
    if [[ "$(readlink "${bin_dir}/claude" 2>/dev/null || true)" == "${before}" ]]; then
        pass "the refusals left ${bin_dir}/claude exactly as it was"
    else
        fail "${bin_dir}/claude changed across the refused repoints"
    fi
    rm -rf -- "${fake_version_dir}"
fi

# (D) Idempotent happy path: target the link's current versioned target. The end state is invariant -- exit 0, link
# unchanged -- whether the helper repoints (relabel pending) or skips (entrypoint already labelled).
if [[ "${cur}" =~ ^/opt/ai-tools/\.nvm/versions/node/v[0-9]+\.[0-9]+\.[0-9]+/bin/claude$ && -e "${cur}" ]]; then
    if out="$("${helper}" "${cur}" 2>&1)" && [[ "$(readlink "${bin_dir}/claude")" == "${cur}" ]]; then
        pass "helper leaves the symlink at its current valid target (idempotent)"
    else
        fail "helper failed on its current valid target ${cur}"
    fi

    # Without SELinux no entrypoint can need relabelling, so the helper MUST skip the repoint and say
    # so; under enforcing either branch (skip or repoint-to-relabel) is correct, so only the end state is asserted.
    if ! { command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; }; then
        if [[ "${out}" == *"already current"* ]]; then
            pass "helper skips the repoint when nothing changed (no SELinux)"
        else
            fail "helper did not report an idempotent skip off SELinux: ${out}"
        fi
    fi
else
    skip "helper happy path" "current symlink target is not a resolvable versioned launcher path"
fi

# (E) The removal form. `--remove` takes the stable link's own path and removes it only for a launcher an INSTALLED
# manifest claims whose agent is NOT enabled -- the link of a package the updater removed as residue. The refusals touch
# no link: a path outside the locked directory, an enabled agent's link (the one every launch of that agent resolves
# through), and a name no manifest claims. The accepted case needs a launcher no operator.conf names, so it is
# a synthetic manifest read through the root-only AI_TOOLS_AGENTS_DIR hook beside copies of the deployed ones, and its
# link carries the harness's fixture name in the live launcher directory (the residue sweep lists that directory),
# registered for teardown.
section "ai-tools-launcher-symlink: the removal form"

for bogus in "/etc/passwd" "/opt/ai-tools/bin/../bin/claude" "/opt/ai-tools/.nvm/versions/node/v22.0.0/bin/claude"; do
    if out="$("${helper}" --remove "${bogus}" 2>&1)"; then
        fail "helper --remove accepted a path that is not a stable launcher path: ${bogus}"
    else
        assert_msg MSG-D9K2 "${out}" "helper --remove refuses a path that is not a stable launcher path: ${bogus}"
    fi
done

# An enabled agent's link: read through the resolver, so no agent is named here.
enabled_launcher=""
while IFS=$'\t' read -r _ _ manifest_launcher; do
    [[ -n "${manifest_launcher}" && -L "${bin_dir}/${manifest_launcher}" ]] || continue
    enabled_launcher="${manifest_launcher}"; break
done < <(bash -c 'source /usr/local/lib/ai-tools/providers.lib.sh && ai_tools_enabled_agents' 2>/dev/null)
if [[ -z "${enabled_launcher}" ]]; then
    skip "removal of an enabled agent's link is refused" "no enabled agent has a stable link on this host"
else
    before="$(readlink "${bin_dir}/${enabled_launcher}")"
    if out="$("${helper}" --remove "${bin_dir}/${enabled_launcher}" 2>&1)"; then
        fail "helper --remove accepted an ENABLED agent's launcher link"
    else
        assert_msg MSG-U2A7 "${out}" "helper --remove refuses an enabled agent's launcher link"
    fi
    if [[ -L "${bin_dir}/${enabled_launcher}" && "$(readlink "${bin_dir}/${enabled_launcher}")" == "${before}" ]]; then
        pass "the refusal left ${bin_dir}/${enabled_launcher} exactly as it was"
    else
        fail "${bin_dir}/${enabled_launcher} changed across a refused removal"
    fi
fi

if out="$("${helper}" --remove "${bin_dir}/$(ai_test_name unclaimed)" 2>&1)"; then
    fail "helper --remove accepted a launcher no manifest claims"
else
    assert_msg MSG-U2A7 "${out}" "helper --remove refuses a launcher no installed manifest claims"
fi

# The accepted case: a synthetic installed agent, not enabled, whose link exists; removed, then already absent.
mktestdir
remove_agents="${TESTDIR}/agents.d"
mkdir -m 0755 "${remove_agents}"
cp /usr/local/lib/ai-tools/agents.d/*.conf "${remove_agents}/" 2>/dev/null || true
# The manifest takes a plain basename (the resolver's `*.conf` glob does not match a dotfile, and it lives
# in the testdir); the LAUNCHER carries the fixture name, since its link lands in the live launcher directory the sweep
# reads.
fixture_agent="residue-agent"
fixture_launcher="$(ai_test_name launcher)"
printf 'npm_package=@ai-tools-test/%s\nlauncher=%s\ndefault_enable=no\n' "${fixture_agent}" "${fixture_launcher}" \
    > "${remove_agents}/${fixture_agent}.conf"
chmod 0644 "${remove_agents}"/*.conf
fixture_link="${bin_dir}/${fixture_launcher}"
_cleanup+=("${fixture_link}")
ln -s "/opt/ai-tools/.nvm/versions/node/v0.0.2/bin/${fixture_launcher}" "${fixture_link}"
# shellcheck disable=SC2016  # the inner shell expands these, not this one
read_back="$(env AI_TOOLS_AGENTS_DIR="${remove_agents}" bash -c \
    'source /usr/local/lib/ai-tools/providers.lib.sh && ai_tools_installed_agents' 2>/dev/null | cut -f1 | grep -cx "${fixture_agent}" || true)"
if [[ "${read_back}" != 1 ]]; then
    fail "the fixture manifest does not read back through the resolver, so the removal case cannot be driven"
elif ! out="$(env AI_TOOLS_AGENTS_DIR="${remove_agents}" "${helper}" --remove "${fixture_link}" 2>&1)"; then
    fail "helper --remove refused the link of an installed, not enabled agent: ${out}"
elif [[ -L "${fixture_link}" || -e "${fixture_link}" ]]; then
    fail "helper --remove exited 0 and left ${fixture_link} in place"
else
    pass "helper --remove removes the link of an installed, not enabled agent"
    if out="$(env AI_TOOLS_AGENTS_DIR="${remove_agents}" "${helper}" --remove "${fixture_link}" 2>&1)" \
            && [[ "${out}" == *"already absent"* ]]; then
        pass "a second removal reports the link already absent, at exit 0"
    else
        fail "a second removal did not report already absent at exit 0: ${out}"
    fi
fi

finish

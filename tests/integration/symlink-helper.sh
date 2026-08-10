#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/symlink-helper.sh
# Integration: the ai-tools-launcher-symlink root helper -- the only writer of the locked
# /opt/ai-tools/bin. It must repoint a stable launcher symlink ONLY at a path of the versioned
# shape whose launcher an ENABLED agent manifest claims, and refuse everything else. Two
# properties carry the security here, and both are asserted below: the path shape (the helper
# cannot trust its caller -- the sandbox account reaches it through the handback socket), and the
# manifest allowlist (without it, any binary sitting in a versioned bin/ could be given a stable
# link in the control-plane directory).
#
# Refusal cases touch nothing; the happy path targets the symlink's CURRENT target, so it is
# idempotent -- and when no relabel is pending it skips the repoint entirely (reporting "already
# current") rather than churning the link. Run as root via sudo.

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
    if "${helper}" "${bogus}" >/dev/null 2>&1; then
        fail "helper accepted a target outside the versioned-launcher shape: ${bogus}"
    else
        pass "helper refuses a target outside the versioned-launcher shape: ${bogus}"
    fi
done

# (B) Refuse a correctly-shaped but non-existent version, for a launcher that IS claimed.
if "${helper}" "/opt/ai-tools/.nvm/versions/node/v0.0.0/bin/claude" >/dev/null 2>&1; then
    fail "helper accepted a versioned path that does not exist (v0.0.0)"
else
    pass "helper refuses a versioned path that does not exist"
fi

# (C) Refuse a correctly-shaped path whose launcher NO enabled agent manifest claims -- the
# allowlist half. `node` is a real binary in that same directory, which makes it the case that
# matters: shape alone would accept it, and accepting it would put a stable control-plane link
# on a binary no agent package declared.
cur="$(readlink "${bin_dir}/claude" 2>/dev/null || true)"
if [[ ! "${cur}" =~ ^/opt/ai-tools/\.nvm/versions/node/v[0-9]+\.[0-9]+\.[0-9]+/bin/claude$ ]]; then
    skip "unclaimed-launcher refusal" "no resolvable versioned launcher symlink to derive a sibling from"
else
    sibling="${cur%/*}/node"
    if [[ ! -x "${sibling}" ]]; then
        skip "unclaimed-launcher refusal" "no sibling binary to probe at ${sibling}"
    elif "${helper}" "${sibling}" >/dev/null 2>&1; then
        fail "helper linked ${bin_dir}/node -- a launcher no enabled agent manifest claims"
    elif [[ -e "${bin_dir}/node" ]]; then
        fail "helper refused but ${bin_dir}/node exists -- the refusal wrote to the locked dir"
    else
        pass "helper refuses a launcher no enabled agent manifest claims"
    fi
fi

# (D) Idempotent happy path: target the link's current versioned target. The end state is
# invariant -- exit 0, link unchanged -- whether the helper repoints (relabel pending) or
# skips (entrypoint already labelled).
if [[ "${cur}" =~ ^/opt/ai-tools/\.nvm/versions/node/v[0-9]+\.[0-9]+\.[0-9]+/bin/claude$ && -e "${cur}" ]]; then
    if out="$("${helper}" "${cur}" 2>&1)" && [[ "$(readlink "${bin_dir}/claude")" == "${cur}" ]]; then
        pass "helper leaves the symlink at its current valid target (idempotent)"
    else
        fail "helper failed on its current valid target ${cur}"
    fi

    # Without SELinux no entrypoint can need relabelling, so the helper MUST skip the
    # repoint and say so; under enforcing either branch (skip or repoint-to-relabel) is
    # correct, so only the end state above is asserted.
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

finish

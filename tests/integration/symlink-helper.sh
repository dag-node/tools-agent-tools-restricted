#!/usr/bin/env bash
# tests/integration/symlink-helper.sh
# Integration: the ai-tools-claude-symlink root helper -- the only writer of the locked
# /opt/ai-tools/bin. It must repoint the stable symlink ONLY at a path matching the
# versioned-claude shape (it cannot trust the sudoers glob, whose wildcard can match '/'),
# and refuse anything else. Refusal cases touch nothing; the happy path targets the
# symlink's CURRENT target, so it is idempotent -- and when no relabel is pending it skips
# the repoint entirely (reporting "already current") rather than churning the link. Run as
# root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly helper="/usr/local/sbin/ai-tools/ai-tools-claude-symlink"
section "ai-tools-claude-symlink: validation + idempotent repoint (integration)"

if [[ ! -x "${helper}" ]]; then
    skip "symlink helper" "not installed at ${helper}"; finish; exit
fi

# (A) Refuse paths outside the versioned-claude shape (no write, exit != 0).
for bogus in \
    "/etc/passwd" \
    "/opt/ai-tools/.nvm/versions/node/v22.0.0/../../../../bin/sh" \
    "/opt/ai-tools/.nvm/versions/node/v22.0.0/bin/node"
do
    if "${helper}" "${bogus}" >/dev/null 2>&1; then
        fail "helper accepted a non-versioned-claude target: ${bogus}"
    else
        pass "helper refuses non-versioned-claude target: ${bogus}"
    fi
done

# (B) Refuse a correctly-shaped but non-existent version.
if "${helper}" "/opt/ai-tools/.nvm/versions/node/v0.0.0/bin/claude" >/dev/null 2>&1; then
    fail "helper accepted a versioned path that does not exist (v0.0.0)"
else
    pass "helper refuses a versioned path that does not exist"
fi

# (C) Idempotent happy path: target the link's current versioned target. The end state is
# invariant -- exit 0, link unchanged -- whether the helper repoints (relabel pending) or
# skips (entrypoint already labelled).
cur="$(readlink /opt/ai-tools/bin/claude 2>/dev/null || true)"
if [[ "${cur}" =~ ^/opt/ai-tools/\.nvm/versions/node/v[0-9]+\.[0-9]+\.[0-9]+/bin/claude$ && -e "${cur}" ]]; then
    if out="$("${helper}" "${cur}" 2>&1)" && [[ "$(readlink /opt/ai-tools/bin/claude)" == "${cur}" ]]; then
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
    skip "helper happy path" "current symlink target is not a resolvable versioned claude path"
fi

finish

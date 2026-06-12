#!/usr/bin/env bash
# tests/integration/symlink-helper.sh
# Integration: the ai-tools-claude-symlink root helper -- the only writer of the locked
# /opt/ai-tools/bin. It must repoint the stable symlink ONLY at a path matching the
# versioned-claude shape (it cannot trust the sudoers glob, whose wildcard can match '/'),
# and refuse anything else. Refusal cases touch nothing; the happy path repoints to the
# symlink's CURRENT target, so it is idempotent. Run as root via sudo.

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

# (C) Idempotent happy path: repoint to the link's current versioned target.
cur="$(readlink /opt/ai-tools/bin/claude 2>/dev/null || true)"
if [[ "${cur}" =~ ^/opt/ai-tools/\.nvm/versions/node/v[0-9]+\.[0-9]+\.[0-9]+/bin/claude$ && -e "${cur}" ]]; then
    if "${helper}" "${cur}" >/dev/null 2>&1 \
       && [[ "$(readlink /opt/ai-tools/bin/claude)" == "${cur}" ]]; then
        pass "helper repoints the symlink at a valid versioned target (idempotent)"
    else
        fail "helper failed to repoint the symlink at its current valid target ${cur}"
    fi
else
    skip "helper happy path" "current symlink target is not a resolvable versioned claude path"
fi

finish

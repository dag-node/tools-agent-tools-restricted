#!/usr/bin/env bash
# tests/unit/safedir.sh
# Hermetic unit tests for the deployed ai-tools-safedir helper: the git safe.directory entry it
# adds at project claim and removes at unclaim, its idempotency, the allowlist gate on add, and
# the root:SANDBOX_GROUP 644 it leaves behind. Runs the installed helper against a /tmp testdir
# with a dummy allowlist (AI_TOOLS_ALLOWLIST) and a fixture gitconfig (AI_TOOLS_GITCONFIG); reads
# and writes nothing outside the testdir.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/sbin/ai-tools/ai-tools-safedir"
section "ai-tools-safedir: git safe.directory registration (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-safedir" "not installed at ${HELPER}"; finish; exit
fi

mktestdir
proj="$(realpath "${TESTDIR}")/proj"
outside="$(realpath "${TESTDIR}")/outside"
mkdir -p "${proj}" "${outside}"
mk_allowlist "${proj}"                            # proj is allowed; outside is not
gc="${TESTDIR}/gitconfig"; : > "${gc}"            # fixture the helper writes into

run() { AI_TOOLS_GITCONFIG="${gc}" setsid "${HELPER}" "$@" < /dev/null > /dev/null 2>&1; }
listed() { git config --file "${gc}" --get-all safe.directory 2>/dev/null | grep -qxF "$1"; }
count()  { git config --file "${gc}" --get-all safe.directory 2>/dev/null | grep -cxF "$1"; }

# (A) add registers the allowlisted project.
run "${proj}" || true
if listed "${proj}"; then pass "add registers an allowlisted project in safe.directory"
else fail "add did not register ${proj}"; fi

# (B) the helper leaves the gitconfig root:SANDBOX_GROUP 644.
read -r owner mode < <(stat -c '%U:%G %a' "${gc}" 2>/dev/null)
if [[ "${owner}" == "root:${SANDBOX_GROUP}" && "${mode}" == 644 ]]; then
    pass "gitconfig is left root:${SANDBOX_GROUP} 644"
else
    fail "gitconfig ownership/mode wrong: ${owner} ${mode}"
fi

# (C) add is idempotent -- a re-run keeps a single entry.
run "${proj}" || true
if [[ "$(count "${proj}")" == 1 ]]; then pass "add is idempotent (no duplicate entry)"
else fail "re-add produced $(count "${proj}") entries"; fi

# (D) a path no operator's allowlist covers is left unregistered (fail-closed).
run "${outside}" || true
if ! listed "${outside}"; then pass "a non-allowlisted path is left unregistered"
else fail "non-allowlisted ${outside} was registered"; fi

# (E) --remove drops the entry.
run --remove "${proj}" || true
if ! listed "${proj}"; then pass "--remove drops the entry"
else fail "--remove left ${proj} registered"; fi

# (F) --remove is lenient -- removing an absent entry is a quiet success (rc 0).
if run --remove "${proj}"; then pass "--remove of an absent entry succeeds quietly"
else fail "--remove of an absent entry returned non-zero"; fi

finish

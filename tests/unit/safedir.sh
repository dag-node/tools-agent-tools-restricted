#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/safedir.sh
# Hermetic unit tests for the deployed ai-tools-safedir helper: the git safe.directory entry it adds at project claim
# and removes at unclaim, its idempotency, the allowlist gate on add, and the root:SANDBOX_GROUP 644 and the SELinux
# type it leaves behind. Runs the installed helper against a /tmp testdir with a dummy allowlist (AI_TOOLS_ALLOWLIST)
# and a fixture gitconfig (AI_TOOLS_GITCONFIG); reads and does not write a path outside the testdir.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-safedir"
section "ai-tools-safedir: git safe.directory registration (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-safedir" "not installed at ${HELPER}"; finish; exit
fi

mktestdir
proj="$(realpath "${TESTDIR}")/proj"
outside="$(realpath "${TESTDIR}")/outside"
mkdir -p "${proj}" "${outside}"
mk_allowlist "@ ${proj}"                            # proj is allowed; outside is not
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

# (B2) the helper leaves the gitconfig at the SELinux type its file context gives it. `git config --file` renames a new
# inode over the file, which takes the type of its parent directory; the fixture sits in a directory relabelled
# to etc_t, so a helper that does not restore the label leaves the file at etc_t and fails this case. A path under /tmp
# has no default label on some hosts, so the directory is in the projects user's home, where the policy gives one.
if ! command -v selinuxenabled >/dev/null 2>&1 || ! selinuxenabled || ! command -v matchpathcon >/dev/null 2>&1; then
    skip "the gitconfig's SELinux type after a write" "SELinux is not in use on this host, or matchpathcon is not installed"
else
    labelled=""   # assigned by mk_fixture_dir through its nameref
    mk_fixture_dir labelled "${PROJECTS_HOME}" labelled
    : > "${labelled}/gitconfig"
    want="$(matchpathcon -n "${labelled}/gitconfig" 2>/dev/null | cut -d: -f3)" || want=""
    if [[ -z "${want}" || "${want}" == *'<<none>>'* || "${want}" == etc_t ]] \
            || ! chcon -t etc_t "${labelled}" 2>/dev/null; then
        skip "the gitconfig's SELinux type after a write" "the policy gives ${labelled}/gitconfig no default type other than etc_t"
    else
        AI_TOOLS_GITCONFIG="${labelled}/gitconfig" setsid "${HELPER}" "${proj}" < /dev/null > /dev/null 2>&1 || true
        got="$(stat -c '%C' "${labelled}/gitconfig" | cut -d: -f3)"
        if [[ "${got}" == "${want}" ]]; then
            pass "the gitconfig takes the type its file context gives it after a write (${want})"
        else
            fail "the gitconfig is ${got} after a write, expected ${want}"
        fi
    fi
fi

# (C) add is idempotent -- a re-run keeps a single entry.
run "${proj}" || true
if [[ "$(count "${proj}")" == 1 ]]; then pass "add is idempotent (no duplicate entry)"
else fail "re-add produced $(count "${proj}") entries"; fi

# (D) a path no operator's allowlist covers is left unregistered (fail-closed), and the refusal is reported rather than
# recorded in the log alone -- a direct run reaches no other account of it.
outside_err="$(AI_TOOLS_GITCONFIG="${gc}" setsid "${HELPER}" "${outside}" < /dev/null 2>&1 > /dev/null || true)"
if ! listed "${outside}"; then pass "a non-allowlisted path is left unregistered"
else fail "non-allowlisted ${outside} was registered"; fi
assert_msg MSG-P5B5 "${outside_err}" "an uncovered path is refused on stderr, under its code"

# (E) `--remove` drops the entry.
run --remove "${proj}" || true
if ! listed "${proj}"; then pass "--remove drops the entry"
else fail "--remove left ${proj} registered"; fi

# (F) `--remove` is lenient -- removing an absent entry is a quiet success (rc 0).
if run --remove "${proj}"; then pass "--remove of an absent entry succeeds quietly"
else fail "--remove of an absent entry returned non-zero"; fi

finish

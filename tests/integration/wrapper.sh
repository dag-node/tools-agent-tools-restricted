#!/usr/bin/env bash
# tests/integration/wrapper.sh
# Integration: the deployed launch wrapper (~/.local/bin/claude). Exercises the allowlist
# gate and the symlink-existence guard against the REAL installed wrapper, hermetically:
# the wrapper keys its allowlist off ${HOME}, so the test points HOME at a /tmp testdir with
# a controlled allowed-projects (no dependency on the operator's real allowlist, and the
# install dir is deliberately NOT approved by install.sh). Every wrapper run is detached via
# setsid so the wrapper's /dev/tty claim prompt can never fire -- the test never claims a
# project as a side effect. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly wrapper="${PROJECTS_HOME}/.local/bin/claude"
section "Wrapper allowlist gate + symlink resolution (integration)"

if [[ ! -x "${wrapper}" ]]; then
    skip "wrapper integration" "wrapper not installed at ${wrapper}"; finish; exit
fi

mktestdir
# A hermetic HOME with a controlled allowlist: approve one temp project dir, leave a sibling
# unapproved. The home tree is owned by the projects user so the wrapper (run as that user)
# reads its own allowlist.
home="${TESTDIR}/home"
approved="${TESTDIR}/approved"
unapproved="${TESTDIR}/unapproved"
mkdir -p "${home}/.config/ai-tools" "${approved}" "${unapproved}"
printf '%s\n' "${approved}" > "${home}/.config/ai-tools/allowed-projects"
chmod -R 0755 "${home}" "${approved}" "${unapproved}"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${home}" "${approved}" "${unapproved}"

# Run the deployed wrapper as the projects user with the hermetic HOME, from $1 as cwd,
# detached (setsid) so no /dev/tty prompt can fire. HOME is set via `env` (the command sudo
# execs), not a sudo command-line assignment, so it reaches the wrapper regardless of sudo's
# env_reset/set_home handling -- the wrapper keys its allowlist off ${HOME}. Echoes combined
# stdout+stderr.
run_wrapper() {  # $1 = cwd
    ( cd "$1" && setsid sudo -u "${PROJECTS_USER}" -- env HOME="${home}" \
        "${wrapper}" --version < /dev/null 2>&1 || true )
}

# (1) An unapproved cwd is blocked at the allowlist gate.
out="$(run_wrapper "${unapproved}")"
if printf '%s' "${out}" | grep -qE "approved projects list|allowlist not found"; then
    pass "wrapper blocks execution from an unapproved directory"
else
    fail "wrapper did NOT block an unapproved directory (output: ${out})"
fi

# (2) An approved cwd passes the allowlist gate. It then stops at the downstream claim guard
#     (the temp dir is approved but not group-claimed) -- that is expected and not the
#     allowlist block, so we assert only that the allowlist message is ABSENT.
out2="$(run_wrapper "${approved}")"
if printf '%s' "${out2}" | grep -qE "approved projects list|allowlist not found"; then
    fail "wrapper incorrectly blocked an approved directory (output: ${out2})"
else
    pass "wrapper passes the allowlist gate for an approved directory"
fi

# (3) End-to-end symlink resolution on that same approved run: the deployed
#     /opt/ai-tools/bin/claude resolves through a package dir the user cannot stat, so an
#     `-e` existence guard would mis-report the link as missing. The wrapper must NOT.
if printf '%s' "${out2}" | grep -q "symlink not found"; then
    fail "wrapper falsely reports the claude symlink missing (output: ${out2})"
else
    pass "wrapper does not falsely report the claude symlink missing"
fi

# ── Symlink-existence guard: -L, not -e ──────────────────────────────────────────
#
# The wrapper must test link existence with `[[ -L ]]`, not `[[ -e ]]`: -e dereferences the
# full chain (bin/claude -> versioned bin/claude -> .../claude-code/bin/claude.exe), and the
# package dir is mode 700 owned by the agent, so the invoking user cannot stat the final
# target (EACCES) and -e would report a valid link as missing. -L tests the link itself.
section "Wrapper symlink-existence guard (-L not -e)"

# (A) Reproduce the hazard hermetically: a symlink chain whose final target sits behind a
#     dir the invoking user cannot enter. -L must still see the link even though -e cannot
#     stat through to the target.
fx="${TESTDIR}/fx"
mkdir -p "${fx}/pkg"
chmod 755 "${fx}"                                 # let the projects user traverse to the link
chmod 700 "${fx}/pkg"                             # root-owned 700: blocks the final stat
: > "${fx}/pkg/claude.exe"
ln -s "${fx}/pkg/claude.exe" "${fx}/versioned"    # npm symlink analogue
ln -s "${fx}/versioned"      "${fx}/link"         # stable link -> versioned -> pkg/claude.exe

l_ok=false; e_ok=false
sudo -u "${PROJECTS_USER}" test -L "${fx}/link" && l_ok=true
sudo -u "${PROJECTS_USER}" test -e "${fx}/link" && e_ok=true
if ${l_ok} && ! ${e_ok}; then
    pass "symlink with unreadable target: -L detects it, -e does not"
elif ! ${l_ok}; then
    fail "fixture broken: -L failed to detect the symlink as ${PROJECTS_USER}"
else
    skip "hazard demo" "final target is readable to ${PROJECTS_USER}; EACCES path not exercised"
fi

# (B) Pin the deployed wrapper to -L: a revert to -e reintroduces the bug.
if grep -Eq '!\s*-L\s+"\$\{CLAUDE_LINK\}"' "${wrapper}"; then
    pass "wrapper guards CLAUDE_LINK with -L"
elif grep -Eq '!\s*-e\s+"\$\{CLAUDE_LINK\}"' "${wrapper}"; then
    fail "wrapper uses -e on CLAUDE_LINK -- reintroduces false 'symlink not found' bug"
else
    fail "wrapper has no recognisable CLAUDE_LINK existence guard"
fi

finish

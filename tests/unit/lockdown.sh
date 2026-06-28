#!/usr/bin/env bash
# tests/unit/lockdown.sh
# Hermetic unit tests for the deployed ai-tools-lockdown helper: the PROACTIVE secret sweep.
# Unlike ai-tools-chown (reactive, agent-owned paths only), lockdown locks down EVERY
# secret-named path under an allowed project -- including pre-existing user-owned ones the
# agent could otherwise read -- setting files 600, directories 700, owner <you>:SANDBOX_GROUP.
# It operates on the CWD (not a path arg), honours the same allowlist + '!'-exclusions + skip
# list, refuses to run as the sandbox account, and applies through a pinned fd. Run against a
# /tmp testdir with a dummy allowlist (AI_TOOLS_ALLOWLIST override) as root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/sbin/ai-tools/ai-tools-lockdown"
section "ai-tools-lockdown: proactive secret sweep (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-lockdown" "not installed at ${HELPER}"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"
mkdir -p "${proj}/secrets" "${proj}/vendor" "${proj}/.git"
chmod 0755 "${TESTDIR}" "${proj}"

# Pre-existing, user-owned fixtures (the case ai-tools-chown never reaches). Secret-named
# file + dir, an ordinary file, a secret under a '!'-excluded subtree, and a secret under a
# skipped (.git) tree.
mk_secret() { : > "$1"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "$1"; chmod 0644 "$1"; }
mk_secret "${proj}/.env"                                            # secret file
chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${proj}/secrets"; chmod 0755 "${proj}/secrets"  # secret dir
: > "${proj}/secrets/inner"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${proj}/secrets/inner"
mk_secret "${proj}/README.md" && chmod 0644 "${proj}/README.md"     # ordinary (non-secret name)
mk_secret "${proj}/vendor/.npmrc"                                   # secret under '!'-excluded
mk_secret "${proj}/.git/id_rsa"                                     # secret under skipped .git
mk_allowlist "${proj}" "!${proj}/vendor"

# Run the deployed helper in <cwd> (it acts on pwd), non-interactive (--yes), never aborting
# the suite. Captures combined output to <outfile>; sets the global LD_RC to its exit code.
run_ld() {  # <cwd> <outfile> [args...]
    local cwd="$1" out="$2"; shift 2
    ( cd "${cwd}" && "${HELPER}" "$@" ) < /dev/null > "${out}" 2>&1 && LD_RC=0 || LD_RC=$?
}

# (1) Dry-run reports the secret but changes nothing.
out="${TESTDIR}/dry"
run_ld "${proj}" "${out}" --dry-run
if [[ "$(stat -c '%U:%G' "${proj}/.env")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/.env")" == 644 ]] \
        && grep -q "${proj}/.env" "${out}"; then
    pass "dry-run lists the secret and makes no changes (.env stays ${PROJECTS_USER}:${PROJECTS_GROUP} 644)"
else
    fail "dry-run altered .env or did not report it: $(stat -c '%U:%G' "${proj}/.env") $(perm "${proj}/.env")"
fi

# (2) Apply: lock down the tree.
run_ld "${proj}" "${TESTDIR}/apply" --yes
if [[ "${LD_RC}" -ne 0 ]]; then
    fail "lockdown --yes exited ${LD_RC}: $(cat "${TESTDIR}/apply")"
fi

# (2a) Secret file -> <you>:SANDBOX_GROUP 600 (agent, mode 600, loses read).
if [[ "$(stat -c '%U:%G' "${proj}/.env")" == "${PROJECTS_USER}:${SANDBOX_GROUP}" && "$(perm "${proj}/.env")" == 600 ]]; then
    pass "secret file -> ${PROJECTS_USER}:${SANDBOX_GROUP} 600 (agent read revoked)"
else
    fail "secret file ended $(stat -c '%U:%G' "${proj}/.env") $(perm "${proj}/.env")"
fi

# (2b) Secret directory -> <you>:SANDBOX_GROUP 700.
if [[ "$(stat -c '%U:%G' "${proj}/secrets")" == "${PROJECTS_USER}:${SANDBOX_GROUP}" && "$(perm "${proj}/secrets")" == 700 ]]; then
    pass "secret dir -> ${PROJECTS_USER}:${SANDBOX_GROUP} 700"
else
    fail "secret dir ended $(stat -c '%U:%G' "${proj}/secrets") $(perm "${proj}/secrets")"
fi

# (2c) Ordinary file is left untouched.
if [[ "$(stat -c '%U:%G' "${proj}/README.md")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/README.md")" == 644 ]]; then
    pass "ordinary (non-secret) file is left untouched"
else
    fail "ordinary file altered: $(stat -c '%U:%G' "${proj}/README.md") $(perm "${proj}/README.md")"
fi

# (2d) '!'-excluded secret is skipped.
if [[ "$(stat -c '%U:%G' "${proj}/vendor/.npmrc")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/vendor/.npmrc")" == 644 ]]; then
    pass "'!'-excluded secret is left untouched"
else
    fail "excluded secret was locked: $(stat -c '%U:%G' "${proj}/vendor/.npmrc") $(perm "${proj}/vendor/.npmrc")"
fi

# (2e) Secret under a skipped tree (.git) is left untouched.
if [[ "$(stat -c '%U:%G' "${proj}/.git/id_rsa")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/.git/id_rsa")" == 644 ]]; then
    pass "secret under a skipped tree (.git) is left untouched"
else
    fail "skipped-tree secret was locked: $(stat -c '%U:%G' "${proj}/.git/id_rsa") $(perm "${proj}/.git/id_rsa")"
fi

# (3) A non-allowlisted CWD is refused (non-zero), and its secret is untouched.
mk_secret "${TESTDIR}/.env"                       # TESTDIR itself is NOT in the allowlist
run_ld "${TESTDIR}" "${TESTDIR}/refuse" --yes
if [[ "${LD_RC}" -ne 0 ]] && grep -qi 'not in allowed projects' "${TESTDIR}/refuse" \
        && [[ "$(perm "${TESTDIR}/.env")" == 644 ]]; then
    pass "refuses a non-allowlisted CWD (non-zero, nothing changed)"
else
    fail "non-allowlisted CWD not refused (rc=${LD_RC}) or .env changed: $(cat "${TESTDIR}/refuse")"
fi

# (4) Refuses to run as the sandbox account (guard fires before any change). A fresh secret
#     created for this case stays untouched.
mk_secret "${proj}/fresh.key"
( cd "${proj}" && SUDO_USER="${SANDBOX_USER}" "${HELPER}" --yes ) < /dev/null > "${TESTDIR}/asagent" 2>&1 \
    && agent_rc=0 || agent_rc=$?
if [[ "${agent_rc}" -ne 0 ]] && grep -qi 'must be run by you, not' "${TESTDIR}/asagent" \
        && [[ "$(stat -c '%U:%G' "${proj}/fresh.key")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" ]]; then
    pass "refuses to run as the sandbox account (no changes made)"
else
    fail "did not refuse the sandbox account (rc=${agent_rc}) or fresh.key changed: $(cat "${TESTDIR}/asagent")"
fi

finish

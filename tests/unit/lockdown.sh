#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/lockdown.sh
# Hermetic unit tests for the deployed ai-tools-lockdown helper: the PROACTIVE secret sweep.
# Unlike ai-tools-chown (reactive, agent-owned paths only), lockdown locks down EVERY
# secret-named path under an allowed project -- including pre-existing user-owned ones the
# agent could otherwise read -- setting files 600, directories 700, owner <you>:<you>.
# It operates on the CWD (not a path arg), honours the same allowlist + '!'-exclusions + skip
# list, refuses to run as the sandbox account, and applies through a pinned fd. Run against a
# /tmp testdir with a dummy allowlist (AI_TOOLS_ALLOWLIST override) as root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-lockdown"
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
# A secret carrying the residue a file born inside a claimed tree would have: the project's
# inherited group ACL entry. chmod alone only masks it, so the lock has to remove it. Kept on its
# own fixture because `setfacl -m` recalculates the mask, which moves the visible mode bits.
residue_acl=false
if command -v setfacl >/dev/null 2>&1; then
    mk_secret "${proj}/residue.key"
    if setfacl -m "group:${SANDBOX_GROUP}:rwX" "${proj}/residue.key" 2>/dev/null; then
        residue_acl=true
    fi
fi
# Owner-only, NON-secret fixtures: the paths an operator seals by MODE rather than by name, which
# no pattern reaches. Built in the real order -- the ACL arrives by inheritance first, the
# operator's chmod comes after -- so the entry is present but masked, as on a path created inside
# a claimed tree.
seal_fx=false
if command -v setfacl >/dev/null 2>&1; then
    mkdir -p "${proj}/privatedir"
    : > "${proj}/notes.txt"
    chown -R "${PROJECTS_USER}:${SANDBOX_GROUP}" "${proj}/privatedir" "${proj}/notes.txt"
    if setfacl -m "group:${SANDBOX_GROUP}:rwX" \
            "${proj}/privatedir" "${proj}/notes.txt" 2>/dev/null; then
        setfacl -d -m "group:${SANDBOX_GROUP}:rwX" "${proj}/privatedir" 2>/dev/null || true
        seal_fx=true
    fi
    chmod 2700 "${proj}/privatedir"
    chmod 0600 "${proj}/notes.txt"
fi
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

# (1b) The dry run covers the SEAL pass too, not just the secret lock. An apply strips residue
#      from paths sealed by MODE, so a preview that showed only the secret half would understate
#      what the operator is about to authorize -- and the seal half is the one that touches paths
#      they never named. Each hit says what it carries, and the tree is byte-for-byte untouched:
#      setgid still set, group still the sandbox's, ACL entry still there.
if ${seal_fx}; then
    if grep -q 'privatedir' "${out}" \
            && [[ "$(stat -c '%a %G' "${proj}/privatedir")" == "2700 ${SANDBOX_GROUP}" ]] \
            && getfacl -c -- "${proj}/privatedir" 2>/dev/null | grep -q "^group:${SANDBOX_GROUP}:"; then
        pass "dry-run reports the seal pass and strips nothing (privatedir keeps setgid, group and ACL)"
    else
        fail "dry-run seal preview missing or it mutated privatedir: $(stat -c '%a %G' "${proj}/privatedir")"
    fi
else
    skip "dry-run seal preview" "ACL fixture unavailable"
fi

# (2) Apply: lock down the tree.
run_ld "${proj}" "${TESTDIR}/apply" --yes
if [[ "${LD_RC}" -ne 0 ]]; then
    fail "lockdown --yes exited ${LD_RC}: $(cat "${TESTDIR}/apply")"
fi

# (2a) Secret file -> <you>:<you> 600. The owner's OWN group, not the sandbox group: at 600 the
#      group grants nothing either way, but leaving it as SANDBOX_GROUP would hand the file back
#      to the agent the moment the mode was widened. Same target ai-tools-chown uses on write.
if [[ "$(stat -c '%U:%G' "${proj}/.env")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/.env")" == 600 ]]; then
    pass "secret file -> ${PROJECTS_USER}:${PROJECTS_GROUP} 600 (agent read revoked)"
else
    fail "secret file ended $(stat -c '%U:%G' "${proj}/.env") $(perm "${proj}/.env")"
fi

# (2b) Secret directory -> <you>:<you> 700.
if [[ "$(stat -c '%U:%G' "${proj}/secrets")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/secrets")" == 700 ]]; then
    pass "secret dir -> ${PROJECTS_USER}:${PROJECTS_GROUP} 700"
else
    fail "secret dir ended $(stat -c '%U:%G' "${proj}/secrets") $(perm "${proj}/secrets")"
fi

# (2c) A locked secret keeps no sandbox ACL entry: chmod 600 masks the inherited entry but does
#      not remove it, so widening the mode later would re-expose the secret.
if ${residue_acl}; then
    if getfacl -c -- "${proj}/residue.key" 2>/dev/null | grep -q "^group:${SANDBOX_GROUP}:"; then
        fail "a locked secret still carries a group:${SANDBOX_GROUP} ACL entry"
    else
        pass "a locked secret's inherited group:${SANDBOX_GROUP} ACL entry is removed"
    fi
    if [[ "$(perm "${proj}/residue.key")" == 600 ]]; then
        pass "stripping the entry leaves the locked secret at 600 (mask not recalculated)"
    else
        fail "locked secret ended $(perm "${proj}/residue.key"), expected 600"
    fi
else
    skip "locked-secret ACL strip" "setfacl unavailable"
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
# The mode is what distinguishes "refused" from "locked" here: a locked secret is now owned
# <you>:<you> too, so ownership alone no longer tells the two apart.
if [[ "${agent_rc}" -ne 0 ]] && grep -qi 'must be run by you, not' "${TESTDIR}/asagent" \
        && [[ "$(perm "${proj}/fresh.key")" == 644 ]] \
        && [[ "$(stat -c '%U:%G' "${proj}/fresh.key")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" ]]; then
    pass "refuses to run as the sandbox account (no changes made)"
else
    fail "did not refuse the sandbox account (rc=${agent_rc}) or fresh.key changed: $(cat "${TESTDIR}/asagent")"
fi

# (5) The seal pass: a NON-secret path the operator sealed by mode has its residue stripped even
#     though no pattern matches its name, so a path sealed after the claim is cleaned up here
#     rather than waiting for the next claim. Asserted on the run from (2).
if ${seal_fx}; then
    dm="$(stat -c '%a' "${proj}/privatedir")"
    if (( (8#${dm} & 8#2000) == 0 )) && [[ "$(perm "${proj}/privatedir")" == 700 ]]; then
        pass "a sealed non-secret dir loses its setgid bit and keeps mode 700"
    else
        fail "sealed dir ended mode ${dm}, expected setgid cleared and 700"
    fi
    if [[ "$(stat -c '%G' "${proj}/privatedir")" != "${SANDBOX_GROUP}" ]]; then
        pass "a sealed non-secret dir is moved off group ${SANDBOX_GROUP}"
    else
        fail "a sealed dir is still group ${SANDBOX_GROUP}"
    fi
    if getfacl -c -- "${proj}/privatedir" 2>/dev/null \
            | grep -q "^\(default:\)\?group:${SANDBOX_GROUP}:"; then
        fail "a sealed dir kept its sandbox ACL entries"
    else
        pass "a sealed dir's access and default sandbox ACL entries are removed"
    fi
    if [[ "$(perm "${proj}/notes.txt")" == 600 ]] \
            && ! getfacl -c -- "${proj}/notes.txt" 2>/dev/null \
                 | grep -q "^group:${SANDBOX_GROUP}:"; then
        pass "a sealed non-secret file is stripped and stays 600"
    else
        fail "sealed file ended $(perm "${proj}/notes.txt") $(stat -c '%U:%G' "${proj}/notes.txt")"
    fi
else
    skip "owner-only seal pass" "setfacl unavailable"
fi

finish

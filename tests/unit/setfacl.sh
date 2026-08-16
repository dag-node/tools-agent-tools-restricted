#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/setfacl.sh
# Hermetic unit tests for the deployed ai-tools-setfacl helper: the group-permission ACL it
# applies at project claim, the opt-in --with-git .git normalization (group + setgid + ACL),
# its owner guard, and its secret/exclusion/skip-list skips. Runs the installed helper against a
# /tmp testdir with a dummy allowlist (AI_TOOLS_ALLOWLIST); reads and writes nothing outside
# the testdir.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-setfacl"
section "ai-tools-setfacl: project ACL normalization (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-setfacl" "not installed at ${HELPER}"; finish; exit
elif ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
    skip "ai-tools-setfacl" "setfacl/getfacl not available"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"
mkdir -p "${proj}/sub" "${proj}/.git/objects" "${proj}/.env/inside" "${proj}/private/nested"
# Pin the fixture's directory modes. mktestdir chmods only TESTDIR, so these would otherwise
# inherit the RUNNER's umask -- and under umask 077 they land 0700, which the owner-only guard
# then skips, taking the whole tree (project root included) out of the walk. Mode is behaviour
# here, not cosmetics, so the test states it rather than inheriting it.
find "${proj}" -type d -exec chmod 0755 {} +
mk_allowlist "${proj}" "!${proj}/sub"          # sub is '!'-excluded

if ! setfacl -m g:"${SANDBOX_GROUP}":rwX "${proj}" 2>/dev/null; then
    skip "ai-tools-setfacl" "filesystem does not support ACLs"; finish; exit
fi
setfacl -b "${proj}" 2>/dev/null || true       # undo the probe entry

# Fixtures (a fresh /tmp dir inherits no setgid and no default ACL, so any ACL afterwards
# is attributable to the helper).
( umask 077; : > "${proj}/sub_restricted" )    # 600: group locked out
mv "${proj}/sub_restricted" "${proj}/restricted"
: > "${proj}/world";        chmod 0644 "${proj}/world"        # stray other-read
: > "${proj}/.env.local";   chmod 0644 "${proj}/.env.local"  # secret-named
: > "${proj}/.env/inside/k"                                   # secret subtree
: > "${proj}/.git/objects/o"                                  # .git tree (default: skipped)
: > "${proj}/.git/.env.local"                                 # secret-named inside .git
: > "${proj}/excluded"; mv "${proj}/excluded" "${proj}/sub/excluded"  # under '!' sub
: > "${proj}/private/nested/k"                                       # inside the 0700 subtree
# Same reason as the directories above: pin every file's mode, then restore the one fixture
# whose owner-only mode is the point (A2). Without this the runner's umask decides which files
# the owner-only guard skips, and the ACL assertions below become umask-dependent.
find "${proj}" -type f -exec chmod 0644 {} +
chmod 0600 "${proj}/restricted"
# Owner-only DIRECTORY, set before the helper ever runs. Creating it afterwards would let it
# inherit proj's default ACL at birth, and the inherited entries (harmless -- a 0700 mode holds
# the mask at ---) would be indistinguishable from entries the helper wrote.
chmod 0700 "${proj}/private"
# The whole tree must be owned by the projects user, or the helper's owner guard skips it
# (fixtures are created here as root). 'foreign' is then re-owned to a third party to
# exercise that guard.
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${proj}"
if id nobody >/dev/null 2>&1; then
    : > "${proj}/foreign"; chown nobody:nobody "${proj}/foreign"; foreign=true
else
    foreign=false
fi

setsid "${HELPER}" "${proj}" < /dev/null > /dev/null 2>&1 || true

g()  { getfacl -p "$1" 2>/dev/null | grep -qE "^group:${SANDBOX_GROUP}:"; }
dg() { getfacl -p "$1" 2>/dev/null | grep -qE "^default:group:${SANDBOX_GROUP}:"; }
u()  { getfacl -p "$1" 2>/dev/null | grep -qE "^user:${PROJECTS_USER}:"; }
du() { getfacl -p "$1" 2>/dev/null | grep -qE "^default:user:${PROJECTS_USER}:"; }

# (A) project root carries the default ACL (group rwX + other denied).
droot="$(getfacl -p "${proj}" 2>/dev/null)"
if grep -qE "^default:group:${SANDBOX_GROUP}:rwx" <<<"${droot}" && grep -qE '^default:other::---' <<<"${droot}"; then
    pass "project root gets default group:${SANDBOX_GROUP}:rwX, other denied"
else
    fail "root default ACL missing/loose: $(tr '\n' ' ' <<<"${droot}")"
fi

# (A2) an owner-only file (0600) is left out of the agent's reach entirely -- no group entry,
# no operator entry, no mask raised. `setfacl -m` recalculates the mask, so granting here would
# give the agent EFFECTIVE rw while `ls -l` still shows -rw-------; the operator cannot review a
# grant they cannot see, so the claim honours the mode instead. secret-handling.rule.md tells
# operators to use `700 <you>:<you>` for exactly this, which only holds if the walk skips it.
fr="$(getfacl -p "${proj}/restricted" 2>/dev/null)"
if ! grep -qE "^(group:${SANDBOX_GROUP}|user:${PROJECTS_USER}):" <<<"${fr}" \
        && [[ "$(perm "${proj}/restricted")" == 600 ]]; then
    pass "an owner-only 0600 file gains no ACL and stays 600 (mask never raised)"
else
    fail "600 file was opened: $(perm "${proj}/restricted") $(tr '\n' ' ' <<<"${fr}")"
fi

# (A2b) the same for a DIRECTORY, and its whole subtree goes with it: an unreachable directory's
# contents cannot be granted through it, so descending would re-open what the parent sealed.
priv="${proj}/private"
mkdir -p "${priv}/nested"; : > "${priv}/nested/k"
chmod 700 "${priv}"; chmod 0644 "${priv}/nested/k"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${priv}"
setsid "${HELPER}" "${proj}" < /dev/null > /dev/null 2>&1 || true
if ! g "${priv}" && ! dg "${priv}" && [[ "$(perm "${priv}")" == 700 ]] \
        && ! g "${priv}/nested/k"; then
    pass "an owner-only 0700 directory and its whole subtree are skipped"
else
    fail "700 dir opened: $(perm "${priv}") dir_acl=$(getfacl -p "${priv}" 2>/dev/null | tr '\n' ' ')"
fi

# (A2c) the skip is REPORTED, not silent: under --with-git it means history the operator asked
# to share was not shared, so a quiet skip would leave them believing the opposite.
if setsid "${HELPER}" "${proj}" < /dev/null 2>&1 >/dev/null | grep -q 'owner-only'; then
    pass "owner-only skips are reported on stderr"
else
    fail "owner-only skips were silent"
fi

# (A3) self-heal: a file created later under a restrictive umask inherits group rw.
( umask 077; : > "${proj}/sub_born" ); mv "${proj}/sub_born" "${proj}/born"
if g "${proj}/born" && [[ "$(stat -c '%A' "${proj}/born")" == -rw-rw---* ]]; then
    pass "a file born later under umask 077 inherits group rw (self-heal)"
else
    fail "default ACL did not heal a new file: $(stat -c '%A' "${proj}/born")"
fi

# (A4) stray other-access stripped.
if getfacl -p "${proj}/world" 2>/dev/null | grep -qE '^other::---'; then
    pass "stray other-access is stripped from existing files"
else
    fail "other access not stripped: $(stat -c '%A' "${proj}/world")"
fi

# (A5) the operator-named grant mirrors the group grant -- the operator's umask-independent
# access to agent-written files, so it co-writes without SANDBOX_GROUP membership.
# Asserted on a group-accessible file: an owner-only one is skipped outright (A2), so it would
# prove nothing about the operator grant.
if grep -qE "^default:user:${PROJECTS_USER}:rwx" <<<"${droot}" && u "${proj}/world"; then
    pass "operator gains user:${PROJECTS_USER}:rwX (access + default), no group membership needed"
else
    fail "operator user ACL missing: root_default=$(grep -E '^default:user:' <<<"${droot}" | tr '\n' ' ') file=$(getfacl -p "${proj}/world" 2>/dev/null | grep -E '^user:' | tr '\n' ' ')"
fi

# (B) secret-named file and secret-dir subtree get NEITHER grant (group or operator), so a
# secret is exposed to neither the agent group nor a named operator entry.
if ! g "${proj}/.env.local" && ! g "${proj}/.env/inside/k" && ! dg "${proj}/.env" \
   && ! u "${proj}/.env.local" && ! du "${proj}/.env"; then
    pass "secret-named file and secret-dir subtree are left untouched (no group or operator ACL)"
else
    fail "a secret path was granted an ACL (exposed)"
fi

# (B2) skipped trees (.git) skipped; (B3) '!'-excluded subtree skipped.
if ! g "${proj}/.git/objects/o"; then pass "skipped trees (.git) are skipped"
else fail "a skipped-tree file was ACL'd"; fi
if ! g "${proj}/sub" && ! g "${proj}/sub/excluded"; then pass "'!'-excluded subtree is skipped"
else fail "an excluded path was ACL'd"; fi

# (B4) owner guard: a third-party-owned file gets neither grant.
if ${foreign}; then
    if ! g "${proj}/foreign" && ! u "${proj}/foreign"; then pass "a third-party-owned file is left untouched (owner guard)"
    else fail "foreign-owned file was granted an ACL"; fi
else
    skip "owner guard" "user 'nobody' not present"
fi

# (C) a path NOT under any allowed project is left untouched.
out="${TESTDIR}/outside"; mkdir -p "${out}"
setsid "${HELPER}" "${out}" < /dev/null > /dev/null 2>&1 || true
if ! dg "${out}"; then pass "a non-allowlisted path is left untouched"
else fail "non-allowlisted ${out} gained the project ACL"; fi

# (D) --with-git: the opt-in pass normalizes .git (group ACL + setgid + group ownership),
# while a secret-named path inside .git is still skipped (the secret/exclusion skips apply
# to the .git pass too).
setsid "${HELPER}" --with-git "${proj}" < /dev/null > /dev/null 2>&1 || true
if g "${proj}/.git/objects/o" && u "${proj}/.git/objects/o"; then pass "--with-git applies the group + operator ACL inside .git"
else fail "--with-git did not ACL .git contents"; fi
read -r gmode ggrp < <(stat -c '%a %G' "${proj}/.git" 2>/dev/null)
if [[ "${ggrp}" == "${SANDBOX_GROUP}" ]] && (( (0${gmode} & 02000) != 0 )); then
    pass "--with-git sets .git group ${SANDBOX_GROUP} + setgid"
else
    fail ".git not group/setgid normalized: ${gmode} ${ggrp}"
fi
if ! g "${proj}/.git/.env.local"; then pass "a secret-named path inside .git stays skipped under --with-git"
else fail "a secret inside .git was ACL'd under --with-git"; fi

finish

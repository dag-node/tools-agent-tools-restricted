#!/usr/bin/env bash
# tests/unit/setfacl.sh
# Hermetic unit tests for the deployed ai-tools-setfacl helper: the group-permission ACL it
# applies at project claim, the opt-in --with-git .git normalization (group + setgid + ACL),
# its owner guard, and its secret/exclusion/prune skips. Runs the installed helper against a
# /tmp testdir with a dummy allowlist (AI_TOOLS_ALLOWLIST); reads and writes nothing outside
# the testdir.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/sbin/ai-tools/ai-tools-setfacl"
section "ai-tools-setfacl: project ACL normalization (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-setfacl" "not installed at ${HELPER}"; finish; exit
elif ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
    skip "ai-tools-setfacl" "setfacl/getfacl not available"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"
mkdir -p "${proj}/sub" "${proj}/.git/objects" "${proj}/.env/inside"
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

# (A) project root carries the default ACL (group rwX + other denied).
droot="$(getfacl -p "${proj}" 2>/dev/null)"
if grep -qE "^default:group:${SANDBOX_GROUP}:rwx" <<<"${droot}" && grep -qE '^default:other::---' <<<"${droot}"; then
    pass "project root gets default group:${SANDBOX_GROUP}:rwX, other denied"
else
    fail "root default ACL missing/loose: $(tr '\n' ' ' <<<"${droot}")"
fi

# (A2) a pre-existing 600 file becomes group-readable via the access ACL.
fr="$(getfacl -p "${proj}/restricted" 2>/dev/null)"
if grep -qE "^group:${SANDBOX_GROUP}:rw" <<<"${fr}" && grep -qE '^other::---' <<<"${fr}"; then
    pass "a pre-existing 600 file gains group rw (other stays denied)"
else
    fail "600 file not opened to the group: $(tr '\n' ' ' <<<"${fr}")"
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

# (B) secret-named file and secret-dir subtree are never granted the group ACL.
if ! g "${proj}/.env.local" && ! g "${proj}/.env/inside/k" && ! dg "${proj}/.env"; then
    pass "secret-named file and secret-dir subtree are left untouched"
else
    fail "a secret path was granted the group ACL (exposed)"
fi

# (B2) pruned trees (.git) skipped; (B3) '!'-excluded subtree skipped.
if ! g "${proj}/.git/objects/o"; then pass "pruned trees (.git) are skipped"
else fail "a pruned-tree file was ACL'd"; fi
if ! g "${proj}/sub" && ! g "${proj}/sub/excluded"; then pass "'!'-excluded subtree is skipped"
else fail "an excluded path was ACL'd"; fi

# (B4) owner guard: a third-party-owned file is left untouched.
if ${foreign}; then
    if ! g "${proj}/foreign"; then pass "a third-party-owned file is left untouched (owner guard)"
    else fail "foreign-owned file was granted the group ACL"; fi
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
if g "${proj}/.git/objects/o"; then pass "--with-git applies the group ACL inside .git"
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

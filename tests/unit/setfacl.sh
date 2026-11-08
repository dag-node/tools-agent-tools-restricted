#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/setfacl.sh
# Hermetic unit tests for the deployed ai-tools-setfacl helper: the group-permission ACL it applies at project claim,
# the opt-in `--with-git` .git normalization (group + setgid + ACL), its owner guard, and its secret/exclusion/skip-list
# skips. Runs the installed helper against a /tmp testdir with a dummy allowlist (AI_TOOLS_ALLOWLIST); reads and does
# not write a path outside the testdir.

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
mkdir -p "${proj}/sub" "${proj}/noted" "${proj}/.git/objects" "${proj}/.env/inside" "${proj}/private/nested"
# Pin the fixture's directory modes. mktestdir chmods only TESTDIR, so these would otherwise inherit the RUNNER's umask
# -- and under umask 077 they land 0700, which the owner-only guard then skips, taking the whole tree (project root
# included) out of the walk. Mode is behaviour here, not cosmetics, so the test states it rather than inheriting it.
find "${proj}" -type d -exec chmod 0755 {} +
# sub is '!'-excluded by a plain line; noted by a line carrying an end-of-line comment, which the shared allowlist
# grammar accepts. A walk that read the second line raw would match no path against it and grant the excluded path.
mk_allowlist "@ ${proj}" "! ${proj}/sub" "! ${proj}/noted   # excluded"

if ! setfacl -m g:"${SANDBOX_GROUP}":rwX "${proj}" 2>/dev/null; then
    skip "ai-tools-setfacl" "filesystem does not support ACLs"; finish; exit
fi
setfacl -b "${proj}" 2>/dev/null || true       # undo the probe entry

# Fixtures (a fresh /tmp dir does not inherit setgid and no default ACL, so any ACL afterwards is attributable
# to the helper).
( umask 077; : > "${proj}/sub_restricted" )    # 600: group locked out
mv "${proj}/sub_restricted" "${proj}/restricted"
: > "${proj}/world";        chmod 0644 "${proj}/world"        # stray other-read
: > "${proj}/.env.local";   chmod 0644 "${proj}/.env.local"  # secret-named
: > "${proj}/.env/inside/k"                                   # secret subtree
: > "${proj}/.git/objects/o"                                  # .git tree (default: skipped)
: > "${proj}/.git/.env.local"                                 # secret-named inside .git
: > "${proj}/excluded"; mv "${proj}/excluded" "${proj}/sub/excluded"  # under '!' sub
: > "${proj}/noted/excluded"                                          # under the commented '!'
: > "${proj}/private/nested/k"                                       # inside the 0700 subtree
# Same reason as the directory fixtures: pin every file's mode, then restore the one fixture whose owner-only mode is
# the point (A2). Without this the runner's umask decides which files the owner-only guard skips, and the ACL assertions
# become umask-dependent.
find "${proj}" -type f -exec chmod 0644 {} +
chmod 0600 "${proj}/restricted"
# Owner-only DIRECTORY, set before the helper ever runs. Creating it afterwards would let it inherit proj's default ACL
# at birth, and the inherited entries (harmless -- a 0700 mode holds
# the mask at ---) would be indistinguishable from entries the helper wrote.
chmod 0700 "${proj}/private"
# The whole tree must be owned by the projects user, or the helper's owner guard skips it (fixtures are created here
# as root). 'foreign' is then re-owned to a third party to exercise that guard.
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

# (A2) an owner-only file (0600) is left out of the agent's reach entirely -- no group entry, no operator entry, no mask
# raised. `setfacl -m` recalculates the mask, so granting here would give the agent EFFECTIVE rw while `ls -l` still
# shows `-rw-------`; the operator cannot review a grant they cannot see, so the claim honours the mode instead.
# secret-handling.rule.md tells operators to use `700 <you>:<you>` for exactly this, which only holds if the walk skips
# it.
fr="$(getfacl -p "${proj}/restricted" 2>/dev/null)"
if ! grep -qE "^(group:${SANDBOX_GROUP}|user:${PROJECTS_USER}):" <<<"${fr}" \
        && [[ "$(perm "${proj}/restricted")" == 600 ]]; then
    pass "an owner-only 0600 file gains no ACL and stays 600 (mask never raised)"
else
    fail "600 file was opened: $(perm "${proj}/restricted") $(tr '\n' ' ' <<<"${fr}")"
fi

# (A2b) the same for a DIRECTORY, and its whole subtree goes with it: an unreachable directory's contents cannot be
# granted through it, so descending would re-open what the parent sealed.
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

# (A2c) the skip is REPORTED, not silent: under `--with-git` it means history the operator asked to share was not
# shared, so a quiet skip would leave them believing the opposite.
sealed_err="$(setsid "${HELPER}" "${proj}" < /dev/null 2>&1 >/dev/null || true)"
assert_msg MSG-C9Z6 "${sealed_err}" "owner-only skips are reported on stderr"

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

# (A5) the operator-named grant mirrors the group grant -- the operator's umask-independent access to agent-written
# files, so it co-writes without SANDBOX_GROUP membership. Asserted on a group-accessible file: an owner-only one is
# skipped outright (A2), so it would prove no property of the operator grant.
if grep -qE "^default:user:${PROJECTS_USER}:rwx" <<<"${droot}" && u "${proj}/world"; then
    pass "operator gains user:${PROJECTS_USER}:rwX (access + default), no group membership needed"
else
    fail "operator user ACL missing: root_default=$(grep -E '^default:user:' <<<"${droot}" | tr '\n' ' ') file=$(getfacl -p "${proj}/world" 2>/dev/null | grep -E '^user:' | tr '\n' ' ')"
fi

# (B) secret-named file and secret-dir subtree get NEITHER grant (group or operator), so a secret is exposed to neither
# the agent group nor a named operator entry.
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
if ! g "${proj}/noted" && ! g "${proj}/noted/excluded" && ! u "${proj}/noted/excluded"; then
    pass "'!'-excluded subtree is skipped when its line carries a comment (shared grammar)"
else fail "a subtree excluded by a commented line was ACL'd"; fi

# (B4) owner guard: a third-party-owned file gets neither grant.
if ${foreign}; then
    if ! g "${proj}/foreign" && ! u "${proj}/foreign"; then pass "a third-party-owned file is left untouched (owner guard)"
    else fail "foreign-owned file was granted an ACL"; fi
else
    skip "owner guard" "user 'nobody' not present"
fi

# (B5) the owner-guard skip is REPORTED, not silent -- the half the CLI reads. Without the report, a claim over a tree
# owned by a third party closes with a clean ✓ while granting no path at all.
if ${foreign}; then
    guard_err="$(setsid "${HELPER}" "${proj}" < /dev/null 2>&1 >/dev/null || true)"
    # The code separates this report from the project-root one below, which reads alike.
    assert_msg MSG-K8M2 "${guard_err}" "a third-party-owned path is reported on stderr"
else
    skip "owner-guard reporting" "user 'nobody' not present"
fi

# (C) a path NOT under any allowed project is left untouched.
out="${TESTDIR}/outside"; mkdir -p "${out}"
setsid "${HELPER}" "${out}" < /dev/null > /dev/null 2>&1 || true
if ! dg "${out}"; then pass "a non-allowlisted path is left untouched"
else fail "non-allowlisted ${out} gained the project ACL"; fi

# (D) `--with-git`: the opt-in pass normalizes .git (group ACL + setgid + group ownership), while a secret-named path
# inside .git is still skipped (the secret/exclusion skips apply to the .git pass too).
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

# (D2) The share a `projects create` accepts: a project root carrying the clone area's inherited entries (a named group
# standing in for `ai-ops`, on the root's access and default ACL) over a `.git` the create stripped to its mode bits.
# `--with-git` gives `.git` the sandbox group's entry and does not carry the root's named group into it, so after
# the share an operator's access to another account's `.git` stays that owner's to grant.
if id nobody >/dev/null 2>&1; then
    share="${TESTDIR}/share"; third_group="$(id -gn nobody)"
    mkdir -p "${share}/.git/objects"; : > "${share}/.git/HEAD"; : > "${share}/.git/objects/o"
    chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${share}"
    chmod 0750 "${share}"; chmod 2750 "${share}/.git" "${share}/.git/objects"
    chmod 0640 "${share}/.git/HEAD" "${share}/.git/objects/o"
    setfacl -m "g:${third_group}:rwx,d:g:${third_group}:rwx" "${share}"
    mk_allowlist "@ ${share}"
    third() { getfacl -R -p "$1" 2>/dev/null | grep -qE "^(default:)?group:${third_group}:"; }
    if third "${share}" && ! third "${share}/.git"; then
        pass "control: the root carries the named group and the stripped .git does not"
    else
        fail "fixture: the root's named group or the .git strip is not as set"
    fi
    setsid "${HELPER}" --with-git "${share}" < /dev/null > /dev/null 2>&1 || true
    if getfacl -p "${share}/.git/HEAD" 2>/dev/null | grep -qE "^group:${SANDBOX_GROUP}:rw"; then
        pass "the accepted share gives .git the sandbox group's entry"
    else
        fail "the accepted share did not give .git/HEAD the sandbox group's entry: $(getfacl -p "${share}/.git/HEAD" 2>/dev/null | tr '\n' ' ')"
    fi
    if ! third "${share}/.git"; then pass "and does not carry the root's named group into .git"
    else fail "the accepted share carried group:${third_group} into .git"; fi
else
    skip "the accepted share's named-group row" "user 'nobody' not present"
fi

# (E) the project ROOT owned by a third party: every path under it is then unreachable through it, so this is the whole
# outcome of the claim rather than one skipped path, and it says so.
p2="${TESTDIR}/proj2"
mkdir -p "${p2}/sub"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${p2}"
chmod -R 0770 "${p2}"
mk_allowlist "@ ${p2}"
if id nobody >/dev/null 2>&1; then
    chown nobody:nobody "${p2}"
    root_err="$(setsid "${HELPER}" "${p2}" < /dev/null 2>&1 >/dev/null || true)"
    assert_msg MSG-M6H3 "${root_err}" "a third-party-owned project root is reported as granting no access"
else
    skip "third-party project root" "user 'nobody' not present"
fi

# (F) The secret patterns are loaded AFTER the owner resolve. The loader builds its path from PROJECTS_HOME, so a load
# ahead of the resolve reads the built-in baseline and never the operator's own file -- a regression the secret case (B)
# cannot see, since a fixture cannot write the operator's real ~/.config. Read as source order in the installed helper;
# an anchor no longer found FAILS, since a refactor that moved either call is when this needs re-asserting.
resolve_line="$(grep -n -m1 -E '^ai_tools_operator__resolve_owner "' "${HELPER}" | cut -d: -f1)"
load_line="$(grep -n -m1 -F 'ai_tools_secret_patterns__load' "${HELPER}" | cut -d: -f1)"
if [[ -z "${resolve_line}" || -z "${load_line}" ]]; then
    fail "the owner resolve or the secret-pattern load is no longer where this reads it (resolve -> ${resolve_line:-none}, load -> ${load_line:-none})"
elif (( resolve_line < load_line )); then
    pass "the secret patterns are loaded after the owner resolve, so the operator's own file is read"
else
    fail "the secret patterns are loaded at line ${load_line}, ahead of the owner resolve at ${resolve_line} -- the walk reads the baseline, never the operator's file"
fi

# A secret-patterns file that is present and cannot be read refuses the grant before its first write (exit 3,
# under the library's code), where an absent file loads the baseline and grants. Driven through the loader's file hook
# at a directory, the one unreadable state root meets on any host; the tree is read back with no ACL.
proj2="${TESTDIR}/proj2"
mkdir -p "${proj2}"; : > "${proj2}/plain.txt"
mk_allowlist "@ ${proj}" "@ ${proj2}"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${proj2}"
chmod 0750 "${proj2}"; chmod 0640 "${proj2}/plain.txt"
mkdir -p "${TESTDIR}/patterns-dir"
rc=0
err="$(AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-dir" setsid "${HELPER}" "${proj2}" < /dev/null 2>&1 >/dev/null)" || rc=$?
if (( rc == 3 )) && ! getfacl -p "${proj2}/plain.txt" 2>/dev/null | grep -q "^group:${SANDBOX_GROUP}:"; then
    pass "an unreadable secret-patterns file refuses the grant (exit 3) and leaves the tree without an ACL"
else
    fail "an unreadable secret-patterns file: rc=${rc} (want 3), ACL: $(getfacl -p "${proj2}/plain.txt" 2>/dev/null | tr '\n' ' ')"
fi
assert_msg MSG-S4T9 "${err}" "the refusal names the unreadable file under the library's code"

# ── A pinned path whose ancestor is a symlink ────────────────────────────────
# The state ai_tools_safe_paths__is_pinned_fd_at_path refuses (safe-paths.lib.sh), driven through _safe_setfacl read
# out of the installed helper as text, since the walk never emits it. The directory outside gains no ACL entry and keeps
# its group; the same function on a real path is the control that it still grants.
section "ai-tools-setfacl: a pinned path whose ancestor is a symlink"
pin_proj="${TESTDIR}/pin-proj"; pin_outside="${TESTDIR}/pin-outside"
mkdir -p "${pin_proj}/real" "${pin_outside}/inside"
ln -s "${pin_outside}" "${pin_proj}/link"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${pin_proj}" "${pin_outside}"
chmod 0750 "${pin_proj}" "${pin_proj}/real" "${pin_outside}" "${pin_outside}/inside"
# drive_safe_setfacl <path> : _safe_setfacl from the installed helper, in a subshell holding the globals it reads.
drive_safe_setfacl() {
    # shellcheck disable=SC2034  # the extracted function reads the globals set here
    (
        set -euo pipefail
        # shellcheck source=/dev/null
        source /usr/local/lib/ai-tools/safe-paths.lib.sh
        # shellcheck source=/dev/null
        source /usr/local/lib/ai-tools/owner-only.lib.sh
        # shellcheck source=/dev/null
        source /usr/local/lib/ai-tools/project-permissions.lib.sh
        SANDBOX_UID="$(id -u "${SANDBOX_USER}")"; GROUP="${SANDBOX_GROUP}"; SKIP_DRIFTED=false
        ACL_SPEC=""
        ai_tools_project_permissions__build_acl_specification ACL_SPEC "${PROJECTS_USER}" "${GROUP}"
        eval "$(extract_function "${HELPER}" _safe_setfacl)"
        _safe_setfacl "$1"
    )
}
has_group_acl() { getfacl -p "$1" 2>/dev/null | grep -q "^group:${SANDBOX_GROUP}:"; }
rc=0; drive_safe_setfacl "${pin_proj}/real" || rc=$?
if (( rc == 0 )) && has_group_acl "${pin_proj}/real"; then
    pass "control: the extracted function grants the ACL on a directory at its real path"
else
    fail "control: rc=${rc}, real carries '$(getfacl -p "${pin_proj}/real" 2>/dev/null | tr '\n' ' ')' -- the refusal below is not evidence"
fi
rc=0; drive_safe_setfacl "${pin_proj}/link/inside" || rc=$?
if (( rc != 0 )) && ! has_group_acl "${pin_outside}/inside" \
        && [[ "$(stat -c '%G' "${pin_outside}/inside")" == "${PROJECTS_GROUP}" ]]; then
    pass "a directory reached through a symlinked ancestor is refused and left as it was"
else
    fail "symlinked ancestor: rc=${rc}, the directory outside is $(stat -c '%G' "${pin_outside}/inside") with '$(getfacl -p "${pin_outside}/inside" 2>/dev/null | tr '\n' ' ')' (want a refusal, ${PROJECTS_GROUP}, no entry)"
fi

# ── A registry the grammar refuses: the target is left as it was ─────────────────────────
# The loader refuses a registry holding a line its grammar does not recognise, so the owner resolver does not cover any
# path and this helper acts on none; the same tree under the valid registry is the control that the case can act at all.
# The control runs second, so the refused run is read on the untouched tree.
ir="${TESTDIR}/invalid-registry"; mkdir -p "${ir}/sub"; chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${ir}"
chmod 0770 "${ir}" "${ir}/sub"
mk_allowlist "@ ${ir}" "@ relative/entry"
setsid "${HELPER}" "${ir}" < /dev/null > /dev/null 2>&1 || true
if ! has_group_acl "${ir}/sub"; then
    pass "a registry holding a refused line: no ACL entry is written"
else
    fail "a registry holding a refused line: ${ir}/sub carries the group entry"
fi
mk_allowlist "@ ${ir}"
setsid "${HELPER}" "${ir}" < /dev/null > /dev/null 2>&1 || true
if has_group_acl "${ir}/sub"; then
    pass "control: the same tree under the valid registry takes the group entry"
else
    fail "control: ${ir}/sub carries no group entry -- the refusal above is not evidence"
fi

# ── The mask per path: what the owner has, not the execute or write a path inherited ───────────────────────────
# A file created under a default ACL inherits the named and group:: entries with x, held at r-- by the mask its mode
# set; a `setfacl -m` of `rwX` would resolve X to x and recalculate the mask to rwx, so a 0640 file would end 0670
# and executable to every group-class entry, and a 0444 file would end writable to it. The helper writes both named
# entries rwx and gives each path its mask explicitly from the owner's permissions, as a file created later
# under the default ACL carries it, and leaves a directory's sticky bit. Each fixture is asserted on the mode, the mask
# and both named entries in effect, under a parent that carried a default ACL when the file was created and under one
# that did not. The owner's chmod of the group execute bit then decides, which is what the operator page states.
section "ai-tools-setfacl: the mask a path gets"
ps="${TESTDIR}/mask-per-path"
mkdir -p "${ps}/inherited" "${ps}/plain/dir" "${ps}/plain/rodir" "${ps}/plain/sticky"
chmod 0750 "${ps}" "${ps}/inherited" "${ps}/plain" "${ps}/plain/dir"
chmod 0770 "${ps}/plain/sticky"; chmod +t "${ps}/plain/sticky"
setfacl -m "d:group::rwx,d:user:${PROJECTS_USER}:rwx,d:group:${SANDBOX_GROUP}:rwx,d:other::---" "${ps}/inherited"
: > "${ps}/inherited/data"; : > "${ps}/plain/data"; : > "${ps}/plain/tool"; : > "${ps}/plain/readonly"
: > "${ps}/inherited/readonly"
chmod 0640 "${ps}/inherited/data" "${ps}/plain/data"; chmod 0750 "${ps}/plain/tool"
chmod 0444 "${ps}/plain/readonly" "${ps}/inherited/readonly"; chmod 0550 "${ps}/plain/rodir"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${ps}"
if getfacl -p "${ps}/inherited/data" 2>/dev/null | grep -qx "group::rwx[[:space:]]*#effective:r--"; then
    pass "fixture: the file under the default ACL inherits group::rwx under a r-- mask"
else
    fail "fixture: ${ps}/inherited/data did not inherit group::rwx under a r-- mask -- the cases below are not evidence: $(getfacl -p "${ps}/inherited/data" 2>/dev/null | tr '\n' ' ')"
fi
mk_allowlist "@ ${ps}"
setsid "${HELPER}" "${ps}" < /dev/null > /dev/null 2>&1 || true
# assert_acl_mask_and_entries <what> <path> <want-mode> <want-effective>: the mode, the mask, and both named entries
# written rwx and granting <want-effective> in effect.
assert_acl_mask_and_entries() {
    local acl entry missing=""
    acl="$(getfacl -p -c "$2" 2>/dev/null)"
    for entry in "user:${PROJECTS_USER}" "group:${SANDBOX_GROUP}"; do
        if [[ "$4" == rwx ]]; then
            grep -qx -- "${entry}:rwx" <<< "${acl}" || missing+=" ${entry}:rwx"
        else
            grep -qx -- "${entry}:rwx[[:space:]]*#effective:$4" <<< "${acl}" || missing+=" ${entry}:rwx (effective $4)"
        fi
    done
    grep -qx -- "mask::$4" <<< "${acl}" || missing+=" mask::$4"
    if [[ -z "${missing}" && "$(stat -c '%A' "$2")" == "$3" ]]; then
        pass "$1: $3, both named entries rwx, $4 in effect"
    else
        fail "$1: $(stat -c '%A' "$2"), missing${missing:- none} in '$(tr '\n' ' ' <<< "${acl}")' (want $3, $4)"
    fi
}
assert_acl_mask_and_entries "a 0640 file created under a default ACL" "${ps}/inherited/data" -rw-rw---- rw-
assert_acl_mask_and_entries "a 0640 file created without a default ACL" "${ps}/plain/data" -rw-rw---- rw-
assert_acl_mask_and_entries "a 0750 file" "${ps}/plain/tool" -rwxrwx--- rwx
assert_acl_mask_and_entries "a directory" "${ps}/plain/dir" drwxrws--- rwx
# The mask copies the owner's permissions, so a path the owner cannot write stays unwritable to the agent in place.
assert_acl_mask_and_entries "a 0444 file" "${ps}/plain/readonly" -r--r----- r--
assert_acl_mask_and_entries "a 0444 file created under a default ACL" "${ps}/inherited/readonly" -r--r----- r--
assert_acl_mask_and_entries "a 0550 directory" "${ps}/plain/rodir" dr-xr-s--- r-x
assert_acl_mask_and_entries "a sticky 0770 directory, its sticky bit kept" "${ps}/plain/sticky" drwxrws--T rwx
chmod g+x "${ps}/plain/data"; chmod g-x "${ps}/plain/tool"
assert_acl_mask_and_entries "the owner's chmod g+x on a claimed data file" "${ps}/plain/data" -rw-rwx--- rwx
assert_acl_mask_and_entries "the owner's chmod g-x on a claimed script" "${ps}/plain/tool" -rwxrw---- rw-
# A walk sets each file's mask from the owner bit again: a group execute bit without the owner's goes, and one taken
# from a script the owner runs comes back.
setsid "${HELPER}" "${ps}" < /dev/null > /dev/null 2>&1 || true
assert_acl_mask_and_entries "a later walk over the chmod g+x data file" "${ps}/plain/data" -rw-rw---- rw-
assert_acl_mask_and_entries "a later walk over the chmod g-x script" "${ps}/plain/tool" -rwxrwx--- rwx

# ── A declined group repair: `--skip-drifted` ────────────────────────────────
# A claimed tree holding a file and a directory moved in with the operator's own group and group bits, beside a file
# already in the sandbox group. Under `--skip-drifted` the walk leaves each drifted path with its group and without
# an entry, reports how many it left, and still writes the project ACL on the file beside them; the walk without
# the flag over a copy of the tree is the control that the fixture is drift the walk repairs.
section "ai-tools-setfacl: --skip-drifted leaves a declined group repair alone"
skip_tree() {  # skip_tree <dir>: the claimed tree with its two moved-in paths
    mkdir -p "$1/moved-dir"; : > "$1/shared"; : > "$1/moved-in"; : > "$1/moved-dir/inside"
    chown -R "${PROJECTS_USER}:${SANDBOX_GROUP}" "$1"
    chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "$1/moved-in" "$1/moved-dir" "$1/moved-dir/inside"
    chmod 2770 "$1"; chmod 0750 "$1/moved-dir"; chmod 0660 "$1/shared"; chmod 0640 "$1/moved-in" "$1/moved-dir/inside"
}
sd="${TESTDIR}/skip-drifted"; sd_control="${TESTDIR}/skip-drifted-control"
skip_tree "${sd}"; skip_tree "${sd_control}"
mk_allowlist "@ ${sd}" "@ ${sd_control}"
setsid "${HELPER}" "${sd_control}" < /dev/null > /dev/null 2>&1 || true
if [[ "$(stat -c '%G' "${sd_control}/moved-in")" == "${SANDBOX_GROUP}" ]] && g "${sd_control}/moved-in"; then
    pass "control: the walk without --skip-drifted moves the drifted file to ${SANDBOX_GROUP} with the project ACL"
else
    fail "control: the walk without --skip-drifted did not repair the drifted file -- the cases below are not evidence: $(stat -c '%G %a' "${sd_control}/moved-in")"
fi
sd_err="$(setsid "${HELPER}" --skip-drifted "${sd}" < /dev/null 2>&1 >/dev/null || true)"
for sd_path in "${sd}/moved-in" "${sd}/moved-dir" "${sd}/moved-dir/inside"; do
    if [[ "$(stat -c '%G' "${sd_path}")" == "${PROJECTS_GROUP}" ]] && ! g "${sd_path}" && ! u "${sd_path}" \
            && ! dg "${sd_path}"; then
        pass "--skip-drifted leaves ${sd_path#"${sd}"/} in its group without an entry"
    else
        fail "--skip-drifted changed ${sd_path#"${sd}"/}: $(stat -c '%G %a' "${sd_path}") $(getfacl -p "${sd_path}" 2>/dev/null | tr '\n' ' ')"
    fi
done
if g "${sd}/shared" && u "${sd}/shared"; then
    pass "--skip-drifted still writes the project ACL on the file beside them"
else
    fail "--skip-drifted left the file in the sandbox group without the project ACL: $(getfacl -p "${sd}/shared" 2>/dev/null | tr '\n' ' ')"
fi
assert_msg MSG-X6T6 "${sd_err}" "the paths --skip-drifted left are reported"
if grep -q "left 3 path(s)" <<< "${sd_err}"; then pass "the report counts the three drifted paths"
else fail "the report does not count three paths: $(tr '\n' ' ' <<< "${sd_err}")"; fi

# ── The project's `.git` with the VCS skip list cleared ──────────────────────────────────
# `SKIP_VCS_DIRS=[]` takes `.git` off the skip list, which leaves the main walk the one thing between it and the project
# ACL, so the walk prunes it by name: `.git` and the file inside keep their group and carry no entry, while the file
# beside it takes the ACL (the control that the walk ran) and so does a file in a `.git` nested deeper, which only
# the cleared list lets the walk reach (the control that the override took effect). `--with-git` is the route
# that shares the project's `.git`, and the control that the fixture's `.git` is reachable.
section "ai-tools-setfacl: the project's .git with SKIP_VCS_DIRS cleared"
vcs="${TESTDIR}/vcs-cleared"
mkdir -p "${vcs}/.git/objects" "${vcs}/sub/.git"
: > "${vcs}/README.md"; : > "${vcs}/.git/objects/o"; : > "${vcs}/sub/.git/HEAD"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${vcs}"
chmod 0750 "${vcs}" "${vcs}/.git" "${vcs}/.git/objects" "${vcs}/sub" "${vcs}/sub/.git"
chmod 0640 "${vcs}/README.md" "${vcs}/.git/objects/o" "${vcs}/sub/.git/HEAD"
mk_allowlist "@ ${vcs}"
printf 'SKIP_VCS_DIRS=[]\n' >> "${TESTDIR}/operator.conf"
setsid "${HELPER}" "${vcs}" < /dev/null > /dev/null 2>&1 || true
if g "${vcs}/README.md" && g "${vcs}/sub/.git/HEAD"; then
    pass "control: the walk under the cleared VCS list gives the file beside .git, and one in a nested .git, the ACL"
else
    fail "control: README.md or sub/.git/HEAD carries no group entry -- the walk or the override did not take, so the case below is not evidence"
fi
if ! g "${vcs}/.git" && ! g "${vcs}/.git/objects/o" && ! u "${vcs}/.git/objects/o" \
        && [[ "$(stat -c '%G' "${vcs}/.git")" == "${PROJECTS_GROUP}" ]]; then
    pass "with SKIP_VCS_DIRS cleared, the walk leaves .git in its group and without an entry"
else
    fail "the walk under a cleared VCS list reached .git: $(stat -c '%G %a' "${vcs}/.git") $(getfacl -p "${vcs}/.git/objects/o" 2>/dev/null | tr '\n' ' ')"
fi
setsid "${HELPER}" --with-git "${vcs}" < /dev/null > /dev/null 2>&1 || true
if g "${vcs}/.git/objects/o"; then pass "control: --with-git shares the same .git"
else fail "control: --with-git did not share the fixture's .git -- the refusal above is not evidence"; fi

# A worktree's or a submodule's `.git` is a regular file pointing at the git directory elsewhere, and the main walk
# grants it like any other file: the agent's git reads it to find the repository. The name guard leaves the `.git`
# directory to `--with-git` and not the pointer, under the default skip list, which skips `.git` only as a directory.
section "ai-tools-setfacl: a worktree's .git pointer file takes the project ACL"
wt="${TESTDIR}/worktree"
mkdir -p "${wt}"; printf 'gitdir: /elsewhere/.git/worktrees/wt\n' > "${wt}/.git"; : > "${wt}/README.md"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${wt}"
chmod 0750 "${wt}"; chmod 0640 "${wt}/.git" "${wt}/README.md"
mk_allowlist "@ ${wt}"
setsid "${HELPER}" "${wt}" < /dev/null > /dev/null 2>&1 || true
if g "${wt}/README.md" && [[ -f "${wt}/.git" && ! -L "${wt}/.git" ]]; then
    pass "control: the walk ran over the worktree, whose .git is a regular file"
else
    fail "control: the worktree walk did not run or its .git is not a file -- the case below is not evidence"
fi
if g "${wt}/.git" && u "${wt}/.git"; then
    pass "the worktree's .git pointer file carries the group and operator entries"
else
    fail "the worktree's .git pointer was left without the project ACL: $(getfacl -p "${wt}/.git" 2>/dev/null | tr '\n' ' ')"
fi

# ── A baseline exemption ─────────────────────────────────────────────────────
# The walk classifies each path by its canonical path, so a file the baseline exempts takes the project ACL while its
# unexempted sibling, matched by the same pattern, is skipped as the control. Driven with the baseline in force
# through the loader's file hook at an absent file.
section "ai-tools-setfacl: a baseline-exempt path takes the project ACL"
ng="${TESTDIR}/ng"
mkdir -p "${ng}/src/environments"
: > "${ng}/src/environments/environment.prod.ts"; : > "${ng}/src/environments/environment.staging.ts"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${ng}"
find "${ng}" -type d -exec chmod 0755 {} +
find "${ng}" -type f -exec chmod 0644 {} +
mk_allowlist "@ ${ng}"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/no-such-patterns" setsid "${HELPER}" "${ng}" < /dev/null > /dev/null 2>&1 \
    || true
if g "${ng}/src/environments/environment.prod.ts" && ! g "${ng}/src/environments/environment.staging.ts"; then
    pass "a baseline-exempt file takes the project ACL, and its unexempted sibling is skipped"
else
    fail "baseline exemption: environment.prod.ts $(getfacl -p "${ng}/src/environments/environment.prod.ts" 2>/dev/null | grep -c "^group:${SANDBOX_GROUP}:"), environment.staging.ts $(getfacl -p "${ng}/src/environments/environment.staging.ts" 2>/dev/null | grep -c "^group:${SANDBOX_GROUP}:") group entries (want 1, 0)"
fi

finish

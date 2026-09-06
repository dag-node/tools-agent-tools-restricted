#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/unclaim.sh
# Hermetic unit tests for the deployed ai-tools-unclaim helper: the filesystem hand-back it
# performs at project unclaim -- clear the agent ACL + default ACL, regroup to a target
# group, drop group write, and clear the setgid bit on directories -- plus the dedicated
# .git reversal pass, its owner guard, secret skip, and target-group validation. Installed
# helper against a /tmp testdir.
#
# A closing section covers the CLI-side decision that feeds this helper,
# ai-tools.sh's resolve_handback_group, because it has TWO results (the group, and the hint that
# no hand-back can run) and therefore returns both as globals in its caller's shell rather than on
# stdout. No part of that is visible from a `$(...)` capture -- which is how it regressed: the
# capture's subshell dropped the second result, and reading it back under `set -u` aborted every
# unclaim before it touched anything. So the assertion is made from a real caller.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-unclaim"
section "ai-tools-unclaim: filesystem hand-back + revocation (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-unclaim" "not installed at ${HELPER}"; finish; exit
elif ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
    skip "ai-tools-unclaim" "setfacl/getfacl not available"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"
mkdir -p "${proj}/d" "${proj}/.env" "${proj}/.git/objects"
mk_allowlist "${proj}"

if ! setfacl -m g:"${SANDBOX_GROUP}":rwX "${proj}" 2>/dev/null; then
    skip "ai-tools-unclaim" "filesystem does not support ACLs"; finish; exit
fi
setfacl -b "${proj}" 2>/dev/null || true

# Simulate the claimed state: setgid dir, group-rw file, 400 file, a secret, and the
# group-permission ACL claim applies.
: > "${proj}/f";  chmod 0660 "${proj}/f"
chmod 2770 "${proj}/d"                         # setgid dir, as claim leaves it
: > "${proj}/ro"; chmod 0400 "${proj}/ro"
: > "${proj}/gx"; chmod 0670 "${proj}/gx"      # data file the agent left group-executable
: > "${proj}/sh"; chmod 0770 "${proj}/sh"      # a genuine script (owner has execute)
: > "${proj}/.env/secret"
# .git as a --with-git claim leaves it: setgid dirs + group-rw object (the main walk skips
# .git, so only the dedicated reversal pass can revert these).
: > "${proj}/.git/objects/o"; chmod 0660 "${proj}/.git/objects/o"
chmod 2770 "${proj}/.git" "${proj}/.git/objects"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${proj}"
setfacl -R -m "g:${SANDBOX_GROUP}:rwX,o::-" "${proj}"
find "${proj}" -type d -exec setfacl -d -m "g:${SANDBOX_GROUP}:rwX,o::-" {} +
foreign=false
if id nobody >/dev/null 2>&1; then
    : > "${proj}/foreign"; setfacl -m "g:${SANDBOX_GROUP}:rwX" "${proj}/foreign"
    chown nobody:nobody "${proj}/foreign"; foreign=true
fi

setsid "${HELPER}" "${proj}" "${PROJECTS_GROUP}" < /dev/null > /dev/null 2>&1 || true

agentacl() { getfacl -p "$1" 2>/dev/null | grep -qE "^group:${SANDBOX_GROUP}:"; }

# (A) 660 file -> 640, regrouped to the target, agent ACL cleared.
if [[ "$(perm "${proj}/f")" == 640 && "$(stat -c '%G' "${proj}/f")" == "${PROJECTS_GROUP}" ]] \
        && ! agentacl "${proj}/f"; then
    pass "660 file -> 640, regrouped to target, agent ACL cleared"
else
    fail "f is $(stat -c '%a' "${proj}/f") $(stat -c '%G' "${proj}/f") (want 640 ${PROJECTS_GROUP}, no agent ACL)"
fi

# (B) 770 setgid dir -> clean 750 (setgid cleared), regrouped, ACL + default ACL gone.
d_mode="$(stat -c '%a' "${proj}/d")"
if [[ "${d_mode}" == 750 && "$(stat -c '%G' "${proj}/d")" == "${PROJECTS_GROUP}" ]] \
        && ! getfacl -p "${proj}/d" 2>/dev/null | grep -qE "^default:|^group:${SANDBOX_GROUP}:"; then
    pass "770 setgid dir -> clean 750 (setgid cleared), regrouped, ACL + default cleared"
else
    fail "d is ${d_mode} $(stat -c '%G' "${proj}/d") (want 750 ${PROJECTS_GROUP}, no setgid/ACL/default)"
fi

# (C) a 400 file stays 400.
if [[ "$(perm "${proj}/ro")" == 400 ]]; then pass "a 400 file stays 400 (group already has no write)"
else fail "ro is $(stat -c '%a' "${proj}/ro") (want 400)"; fi

# (C2) a data file that landed group-executable (the agent Write's stray exec bit, surfaced
# when setfacl -b promotes group::r-x into the mode) -> 640: execute stripped along with write.
if [[ "$(perm "${proj}/gx")" == 640 && "$(stat -c '%G' "${proj}/gx")" == "${PROJECTS_GROUP}" ]] \
        && ! agentacl "${proj}/gx"; then
    pass "group-executable data file -> 640 (stray execute stripped)"
else
    fail "gx is $(stat -c '%a' "${proj}/gx") $(stat -c '%G' "${proj}/gx") (want 640 ${PROJECTS_GROUP})"
fi

# (C3) a genuine script (owner rwx) keeps group r-x -- only group write is dropped (770 -> 750).
if [[ "$(perm "${proj}/sh")" == 750 && "$(stat -c '%G' "${proj}/sh")" == "${PROJECTS_GROUP}" ]] \
        && ! agentacl "${proj}/sh"; then
    pass "script (owner rwx) -> 750 (group r-x kept, write dropped)"
else
    fail "sh is $(stat -c '%a' "${proj}/sh") $(stat -c '%G' "${proj}/sh") (want 750 ${PROJECTS_GROUP})"
fi

# (D) a secret-named path is left untouched (keeps its agent ACL / not regrouped).
if agentacl "${proj}/.env/secret"; then pass "a secret-named path is left untouched"
else fail "a secret path was regrouped/cleared"; fi

# (E) owner guard: a third-party-owned file is left untouched.
if ${foreign}; then
    if [[ "$(stat -c '%U' "${proj}/foreign")" == nobody ]] && agentacl "${proj}/foreign"; then
        pass "a third-party-owned file is left untouched (owner guard)"
    else
        fail "foreign-owned file was modified"
    fi
else
    skip "owner guard" "user 'nobody' not present"
fi

# (F) an unknown target group is rejected (helper exits non-zero, no path changed).
if ! "${HELPER}" "${proj}" "no_such_group_$$" < /dev/null > /dev/null 2>&1; then
    pass "an unknown target group is rejected"
else
    fail "accepted a nonexistent target group"
fi

# (G) .git is reverted by the dedicated pass (the main walk skips it): the object is
# regrouped + agent ACL cleared + group write dropped, and the .git dir setgid is cleared.
if [[ "$(stat -c '%G' "${proj}/.git/objects/o")" == "${PROJECTS_GROUP}" ]] \
        && ! agentacl "${proj}/.git/objects/o" \
        && [[ "$(perm "${proj}/.git")" == 750 && "$(stat -c '%G' "${proj}/.git")" == "${PROJECTS_GROUP}" ]] \
        && ! getfacl -p "${proj}/.git" 2>/dev/null | grep -qE "^default:|^group:${SANDBOX_GROUP}:"; then
    pass ".git is reverted (regrouped, agent ACL cleared, dir setgid cleared)"
else
    fail ".git not fully reverted: objects/o group $(stat -c '%G' "${proj}/.git/objects/o"), .git $(stat -c '%a %G' "${proj}/.git")"
fi

# (H) a target NOT in allowed-projects is a no-op: unclaim must never modify permissions
# outside the allowlist. The dummy allowlist lists only ${proj}, so a sibling tree is
# unlisted -- resolve_owner and _is_allowed both gate on membership and leave it untouched.
unlisted="${TESTDIR}/unlisted"
mkdir -p "${unlisted}"
: > "${unlisted}/f"; chmod 0660 "${unlisted}/f"
chown -R "${PROJECTS_USER}:${SANDBOX_GROUP}" "${unlisted}"
setfacl -m "g:${SANDBOX_GROUP}:rwX" "${unlisted}/f" 2>/dev/null || true
"${HELPER}" "${unlisted}" "${PROJECTS_GROUP}" < /dev/null > /dev/null 2>&1 || true
if [[ "$(stat -c '%G' "${unlisted}/f")" == "${SANDBOX_GROUP}" ]] && agentacl "${unlisted}/f"; then
    pass "a target outside allowed-projects is left untouched (allowlist backstop)"
else
    fail "unlisted target was modified: f is $(stat -c '%a %G' "${unlisted}/f") (want ${SANDBOX_GROUP} + agent ACL)"
fi

# ── --unlisted: the residue gate replaces the allowlist gate ─────────────────────────────
# The mode exists for a claimed project copied or moved out of the allowlist. What makes it
# safe on a mistyped path is not caution about which bits it writes -- those are identical to
# a listed unclaim -- but that it writes them ONLY to a path still carrying the ai-tools
# fingerprint. Every assertion below is a form of that one property.

# The mode resolves its owner from the invoking operator, so it needs one configured.
operator_conf="${AI_TOOLS_OPERATOR_CONF:-/etc/ai-tools/operator.conf}"
if [[ -r "${operator_conf}" ]] && grep -qE "^[[:space:]]*OPERATORS=.*\b${PROJECTS_USER}\b" "${operator_conf}"; then
    copy="${TESTDIR}/copy"
    mkdir -p "${copy}/sub" "${copy}/node_modules"
    # Residue: what a `cp -a` of a claimed tree carries out of the allowlist.
    : > "${copy}/res";  chmod 0660 "${copy}/res"
    : > "${copy}/owned"; chmod 0660 "${copy}/owned"
    chmod 2770 "${copy}/sub"
    : > "${copy}/node_modules/dep"; chmod 0660 "${copy}/node_modules/dep"
    # Not residue: a file of the operator's own that was never part of any claim. The whole
    # point of the mode is that this one is not touched.
    : > "${copy}/mine"; chmod 0664 "${copy}/mine"
    chown -R "${PROJECTS_USER}:${SANDBOX_GROUP}" "${copy}"
    chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${copy}/mine"
    chown "${SANDBOX_USER}:${PROJECTS_GROUP}" "${copy}/owned" 2>/dev/null || true

    setsid "${HELPER}" "${copy}" "${PROJECTS_GROUP}" --unlisted < /dev/null > /dev/null 2>&1 || true

    # (I) a residue path is reverted exactly as a listed unclaim reverts it.
    if [[ "$(perm "${copy}/res")" == 640 && "$(stat -c '%G' "${copy}/res")" == "${PROJECTS_GROUP}" ]]; then
        pass "--unlisted reverts a residue file (660 -> 640, regrouped)"
    else
        fail "--unlisted left res at $(stat -c '%a %G' "${copy}/res") (want 640 ${PROJECTS_GROUP})"
    fi

    # (J) THE property: a path with no ai-tools fingerprint is not touched at all. This is what
    # makes running the mode on the wrong directory a no-op rather than a mass permission edit.
    if [[ "$(perm "${copy}/mine")" == 664 ]]; then
        pass "--unlisted leaves a non-residue file byte-for-byte (residue gate)"
    else
        fail "--unlisted modified a non-residue file: mine is $(stat -c '%a' "${copy}/mine") (want 664)"
    fi

    # (K) a sandbox-OWNED inode is handed back to the operator: regrouping alone would leave
    # the agent its access through the user bits, and ai-tools-reclaim refuses an unlisted path.
    if id "${SANDBOX_USER}" >/dev/null 2>&1; then
        if [[ "$(stat -c '%U' "${copy}/owned")" == "${PROJECTS_USER}" ]]; then
            pass "--unlisted chowns a sandbox-owned file back to the operator"
        else
            fail "owned is still $(stat -c '%U' "${copy}/owned") (want ${PROJECTS_USER})"
        fi
    else
        skip "--unlisted chown" "sandbox account not present"
    fi

    # (L) the skip list still applies without --full, so residue in a heavy tree survives --
    # the reason the CLI reports it and offers --full rather than silently under-reverting.
    if [[ "$(stat -c '%G' "${copy}/node_modules/dep")" == "${SANDBOX_GROUP}" ]]; then
        pass "--unlisted honors the skip list (node_modules residue left for --full)"
    else
        fail "node_modules was walked without --full"
    fi

    # (M) --full reaches it.
    setsid "${HELPER}" "${copy}" "${PROJECTS_GROUP}" --unlisted --full < /dev/null > /dev/null 2>&1 || true
    if [[ "$(stat -c '%G' "${copy}/node_modules/dep")" == "${PROJECTS_GROUP}" ]]; then
        pass "--unlisted --full reverts residue under a skip-listed directory"
    else
        fail "--full did not reach node_modules/dep"
    fi

    # (N) --unlisted is refused on a REGISTERED project: the caller picked the wrong mode, and
    # running the narrower per-path gate over a real project would silently under-revert it.
    if ! setsid "${HELPER}" "${proj}" "${PROJECTS_GROUP}" --unlisted < /dev/null > /dev/null 2>&1; then
        pass "--unlisted is refused on a registered project"
    else
        fail "--unlisted accepted a registered project"
    fi

    # (O) fails closed with no invoking operator: the identity that bounds the walk cannot be
    # resolved, so no path is touched. env -u SUDO_UID reproduces a direct root call.
    noop="${TESTDIR}/noop"
    mkdir -p "${noop}"; : > "${noop}/f"; chmod 0660 "${noop}/f"
    chown -R "${PROJECTS_USER}:${SANDBOX_GROUP}" "${noop}"
    if ! env -u SUDO_UID setsid "${HELPER}" "${noop}" "${PROJECTS_GROUP}" --unlisted \
            < /dev/null > /dev/null 2>&1 \
            && [[ "$(stat -c '%G' "${noop}/f")" == "${SANDBOX_GROUP}" ]]; then
        pass "--unlisted fails closed with no invoking operator (nothing changed)"
    else
        fail "--unlisted acted without an invoking operator: f is $(stat -c '%a %G' "${noop}/f")"
    fi
else
    skip "--unlisted residue gate" "${PROJECTS_USER} is not a configured operator in ${operator_conf}"
fi

# ── Hardlink guard (both modes) ──────────────────────────────────────────────────────────
# chgrp and chmod act on the INODE, which a second name reaches from outside the tree, so a
# multiply-linked regular file is refused rather than changed through. Same boundary
# ai-tools-chown enforces; asserted here in the LISTED mode, where the tree is fully authorized
# and the guard is therefore the only thing standing between the walk and the outside name.
hl_proj="${TESTDIR}/hlproj"
mkdir -p "${hl_proj}"
outside="${TESTDIR}/outside-target"
: > "${outside}"; chmod 0660 "${outside}"
chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${outside}"
if ln "${outside}" "${hl_proj}/linked" 2>/dev/null; then
    : > "${hl_proj}/plain"; chmod 0660 "${hl_proj}/plain"
    chown -R "${PROJECTS_USER}:${SANDBOX_GROUP}" "${hl_proj}"
    mk_allowlist "${hl_proj}"
    setsid "${HELPER}" "${hl_proj}" "${PROJECTS_GROUP}" < /dev/null > /dev/null 2>&1 || true
    if [[ "$(stat -c '%G' "${outside}")" == "${SANDBOX_GROUP}" && "$(perm "${outside}")" == 660 ]]; then
        pass "a hardlinked file is refused, so the outside name is unchanged"
    else
        fail "hardlink guard breached: outside target is now $(stat -c '%a %G' "${outside}")"
    fi
    if [[ "$(perm "${hl_proj}/plain")" == 640 ]]; then
        pass "the hardlink refusal is per-path (a singly-linked sibling still reverts)"
    else
        fail "plain is $(stat -c '%a' "${hl_proj}/plain") (want 640)"
    fi
else
    skip "hardlink guard" "could not create a hardlink in ${TESTDIR}"
fi

# ── CLI: the hand-back group decision (ai-tools.sh resolve_handback_group) ────────────────────
# Driven from a REAL caller: source the CLI (its sourced-guard skips the gates and dispatch), call
# the function, then read both results back the way cmd_project_unclaim does. Run as the projects
# user, since ai-tools refuses to be sourced as root or the sandbox account, and under setsid so
# the no-terminal path takes its default instead of prompting. `set -u` is on inside, so a result
# the function failed to publish to its caller is an abort here -- exactly the failure being
# pinned, and one no stdout-capturing test can see.
section "ai-tools --project-unclaim: hand-back group resolution (unit)"
readonly CLI="/usr/local/bin/ai-tools"
if [[ ! -x "${CLI}" ]]; then
    skip "resolve_handback_group" "CLI not installed at ${CLI}"
elif ! command -v runuser >/dev/null 2>&1; then
    skip "resolve_handback_group" "runuser unavailable"
else
    # resolve_hb <group-opt> : echo "<group>|<hint>" as the caller sees them, or fail non-zero.
    resolve_hb() {
        # shellcheck disable=SC2016  # the $N are for the inner `bash -c`, not this shell
        setsid runuser -u "${PROJECTS_USER}" -- bash -c '
            set -euo pipefail
            source "$1" >/dev/null 2>&1 || exit 99
            declare -F resolve_handback_group >/dev/null 2>&1 || exit 98
            resolve_handback_group "$2" >/dev/null 2>&1
            printf "%s|%s\n" "${HANDBACK_GROUP}" "${HANDBACK_HINT}"
        ' _ "${CLI}" "$1" < /dev/null 2>/dev/null
    }
    if ! out="$(resolve_hb "${PROJECTS_GROUP}")"; then
        skip "resolve_handback_group" "CLI not sourceable or helper absent (partial install?)"
    else
        # --group names the group outright: it is published as-is, with no hint (the state is correct).
        if [[ "${out}" == "${PROJECTS_GROUP}|" ]]; then
            pass "an explicit --group reaches the caller as the hand-back group, with no hint"
        else
            fail "resolve_handback_group '${PROJECTS_GROUP}' -> '${out}', expected '${PROJECTS_GROUP}|'"
        fi
        # No --group and no terminal: both prompts take their defaults (hand back: yes; to the
        # invoking user's group), so the caller still gets a usable group and no hint.
        out="$(resolve_hb "")" || out="<abort>"
        if [[ "${out}" == "${PROJECTS_GROUP}|" ]]; then
            pass "with no --group and no terminal the defaults resolve to the invoker's own group"
        else
            fail "resolve_handback_group '' -> '${out}', expected '${PROJECTS_GROUP}|'"
        fi
    fi
fi

finish

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/owner-only.lib.sh
# Which paths the operator sealed, and what a claim may remove from one. Shared by every helper
# that walks a claimed tree -- ai-tools-setgid, ai-tools-setfacl, ai-tools-lockdown,
# ai-tools-chown -- so all four agree on both.
#
# An owner-only path -- a mode with no group and no other bits (0600, 0700) -- is the operator's
# standing decision to keep it out of the sandbox account's reach. A claim honours it: the path
# is never granted, and a sealed directory takes its whole subtree with it.
#
# The mode alone does not hold, because setgid and default-ACL inheritance act at CREATE time: a
# path born inside a claimed tree already carries group @SANDBOX_GROUP@, the setgid bit and the
# project's default ACL, and a later chmod only masks them. Widening the mode once re-activates
# the lot. So sealing also strips that residue -- exactly what the sandbox put there:
#   * the group:@SANDBOX_GROUP@ ACL entries, access and default
#   * the setgid bit on a DIRECTORY grouped to the sandbox account or to the operator
#   * the group owner, when it is @SANDBOX_GROUP@, moved to the operator's own group
# Everything else is left as found: mode bits, ownership, setuid/setgid on files, and every other
# ACL entry -- including the operator's own user:<operator> grant and the traverse-only
# u:@SANDBOX_USER@:--x that claim's reachability opt-in places on ancestors.
#
# `setfacl -n` is load-bearing. Without it setfacl recalculates the mask from the entries that
# remain, so on a sealed 0600 file still carrying user:<operator>:rwX the mask rises to rwx and
# the file lands 0670 -- a strip that grants. With -n the mode is bit-for-bit unchanged.
#
# A setgid bit whose group is neither the sandbox account's nor the operator's is left alone and
# reported instead: an operator who set it deliberately is not overruled by a walk that cannot
# ask. Surfacing it is the caller's job; the session hooks have no terminal.

if [[ -n "${_AI_TOOLS_OWNER_ONLY_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_OWNER_ONLY_LIB=1

# The sandbox group, substituted at install. Every arm of the strip is keyed on it, so a tree
# that never met a claim has nothing to strip.
readonly AI_TOOLS_SANDBOX_GROUP="@SANDBOX_GROUP@"

# ai_tools_is_owner_only <octal-mode>: 0 when the mode carries no group and no other bits.
# An empty or unparseable mode reads as sealed, so a path whose stat failed is skipped by the
# walkers rather than granted.
ai_tools_is_owner_only() {
    local mode="${1:-}"
    [[ "${mode}" =~ ^[0-7]+$ ]] || return 0
    (( ( 8#${mode} & 077 ) == 0 ))
}

# ai_tools_strip_sandbox_residue <fd> <ftype> <group-name> <octal-mode> [operator-group]
# Strips the residue listed in the header from the caller's already-pinned, already-validated
# inode, so it inherits that caller's TOCTOU guarantee. <ftype>/<group-name>/<octal-mode> are
# the values the caller read from that same descriptor.
#
# Returns 0 when something was stripped, 1 when there was nothing to strip. Sets:
#   AI_TOOLS_RESIDUE_ACTIONS   what changed, as an array of acl / setgid / group
#   AI_TOOLS_RESIDUE_SURFACE   1 when a third-party group's setgid was left for the caller
#                              to report
# shellcheck disable=SC2034  # both are outputs, read by the walkers and ai-tools-lockdown
ai_tools_strip_sandbox_residue() {
    local fd="$1" ftype="$2" grp="$3" mode="$4" opgrp="${5:-}"
    local path="/proc/self/fd/${fd}"
    local changed=1
    AI_TOOLS_RESIDUE_ACTIONS=()
    AI_TOOLS_RESIDUE_SURFACE=0

    # Remove only the entries that are actually present -- setfacl fails the whole call on one
    # that is not. The matches are anchored: the access entry's text is a suffix of the default.
    if command -v getfacl >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1; then
        local acl
        acl="$(getfacl -c -- "${path}" 2>/dev/null)" || acl=""
        local -a rm=()
        if grep -q "^group:${AI_TOOLS_SANDBOX_GROUP}:" <<<"${acl}"; then
            rm+=( -x "group:${AI_TOOLS_SANDBOX_GROUP}" )
        fi
        if grep -q "^default:group:${AI_TOOLS_SANDBOX_GROUP}:" <<<"${acl}"; then
            rm+=( -x "default:group:${AI_TOOLS_SANDBOX_GROUP}" )
        fi
        if [[ "${#rm[@]}" -gt 0 ]] && setfacl -n "${rm[@]}" "${path}" 2>/dev/null; then
            AI_TOOLS_RESIDUE_ACTIONS+=("acl")
            changed=0
        fi
    fi

    if [[ "${ftype}" == "directory" && "${mode}" =~ ^[0-7]+$ ]] \
            && (( ( 8#${mode} & 8#2000 ) != 0 )); then
        if [[ "${grp}" == "${AI_TOOLS_SANDBOX_GROUP}" ]] \
                || { [[ -n "${opgrp}" ]] && [[ "${grp}" == "${opgrp}" ]]; }; then
            if chmod g-s "${path}" 2>/dev/null; then
                AI_TOOLS_RESIDUE_ACTIONS+=("setgid")
                changed=0
            fi
        else
            AI_TOOLS_RESIDUE_SURFACE=1
        fi
    fi

    # With no operator resolved there is no defensible target, so the group is left as it is
    # rather than guessed at.
    if [[ "${grp}" == "${AI_TOOLS_SANDBOX_GROUP}" && -n "${opgrp}" ]] \
            && [[ "${opgrp}" != "${AI_TOOLS_SANDBOX_GROUP}" ]]; then
        if chgrp -- "${opgrp}" "${path}" 2>/dev/null; then
            AI_TOOLS_RESIDUE_ACTIONS+=("group")
            changed=0
        fi
    fi

    return "${changed}"
}

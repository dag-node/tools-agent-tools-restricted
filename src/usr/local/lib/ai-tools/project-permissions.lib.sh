#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/project-permissions.lib.sh
# The POSIX ACL a claim grants on a project tree, stated once for the helper that applies it (ai-tools-setfacl)
# and for the claim's verifier that checks the repair took (group_check in ai-tools), so the verifier tests the entries
# the helper writes rather than a copy of them.
#
# A pure function: the caller passes the identities it resolved, and sourcing the library neither touches the filesystem
# nor resolves a name. The helper passes names; the verifier passes numeric ids, which is the form `getfacl --numeric`
# prints them in. Its domain rule is cli.rule.md.

if [[ -n "${_AI_TOOLS_PROJECT_PERMISSIONS_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_PROJECT_PERMISSIONS_LIB=1

# ai_tools_project_permissions_build_acl_specification <output-variable> <operator> <sandbox-group>  -- set
# <output-variable> to the `setfacl -m` specification a claim applies: the operator's named grant, the sandbox group's,
# and `other::---`. `rwX` grants execute only on a directory or a file that already has an execute bit. Returns 1
# with the variable empty when an identity is empty or holds a character outside `[A-Za-z0-9._-]`, since a `,` or `:`
# in one would add an entry of its own to the specification; returns 2 on an invalid variable name.
ai_tools_project_permissions_build_acl_specification() {
    local _output="$1" _operator="$2" _group="$3"
    [[ "${_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    printf -v "${_output}" '%s' ''
    local LC_ALL=C
    [[ "${_operator}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 1
    [[ "${_group}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 1
    printf -v "${_output}" 'user:%s:rwX,group:%s:rwX,other::---' "${_operator}" "${_group}"
}

#!/usr/bin/env bash
# /usr/local/lib/ai-tools/relabel.lib.sh
# Single source of the per-project SELinux labelling primitive: map an approved
# project directory to ai_tools_project_t (or revert it) so the confined agent
# (ai_tools_t) can read and write the tree. Sourced by the root helper
# ai-tools-relabel and by selinux/install-selinux.sh's allowlist sweep, so the
# `semanage fcontext` + `restorecon` body exists in exactly one place.
#
# In-place project paths (under a user's home) are DYNAMIC, so they get a
# per-project `semanage fcontext` rule here. Sandbox clones under
# /var/opt/ai-tools/sandbox-projects are already mapped by a STATIC rule in
# selinux/ai_tools.fc, so for those a plain restorecon suffices and adding a local
# rule would be redundant -- the helpers below detect and skip the semanage step
# for sandbox paths. See selinux/ai_tools.fc and selinux/ai_tools.te.
#
# Every mutating function is root-only: semanage writes the policy store and
# restorecon needs relabel. Callers must already be root. The functions are
# best-effort -- a disabled SELinux or a missing toolchain is reported via the
# return code (2 = unavailable, 1 = hard failure), never an abort -- so a sourcing
# script keeps `set -e` semantics by checking the return value.

readonly AI_TOOLS_PROJECT_TYPE="ai_tools_project_t"
readonly AI_TOOLS_SANDBOX_ROOT="/var/opt/ai-tools/sandbox-projects"

# ai_tools_relabel_available: 0 when SELinux is active and restorecon is present,
# i.e. when labelling can do anything. Non-zero (2) otherwise.
ai_tools_relabel_available() {
    command -v restorecon >/dev/null 2>&1 || return 2
    [[ "$(getenforce 2>/dev/null)" == "Disabled" ]] && return 2
    return 0
}

# _ai_tools_is_sandbox <dir>: 0 if <dir> lies under the statically-labelled sandbox
# root, whose subtree ai_tools.fc already maps to ai_tools_project_t.
_ai_tools_is_sandbox() { [[ "$1/" == "${AI_TOOLS_SANDBOX_ROOT}/"* ]]; }

# ai_tools_label_project <dir>: ensure <dir> and its subtree carry
# ai_tools_project_t. Adds (or refreshes) the per-project fcontext rule -- skipped
# for sandbox clones, which the static rule already covers -- then restorecons.
# Returns 2 if SELinux is unavailable, 1 on a hard failure (e.g. the type is not in
# the loaded policy because the module is not installed), 0 on success.
ai_tools_label_project() {
    local dir="$1"
    ai_tools_relabel_available || return 2
    if ! _ai_tools_is_sandbox "${dir}"; then
        semanage fcontext -a -t "${AI_TOOLS_PROJECT_TYPE}" "${dir}(/.*)?" 2>/dev/null \
            || semanage fcontext -m -t "${AI_TOOLS_PROJECT_TYPE}" "${dir}(/.*)?" 2>/dev/null \
            || return 1
    fi
    restorecon -RF "${dir}" 2>/dev/null || return 1
}

# ai_tools_unlabel_project <dir>: drop any per-project fcontext rule for <dir> and
# restorecon the subtree back to its default type (e.g. user_home_t). The semanage
# delete is skipped for sandbox clones (no local rule was ever added); the
# restorecon still runs. Returns 2 if SELinux is unavailable, 1 on restorecon
# failure, 0 otherwise.
ai_tools_unlabel_project() {
    local dir="$1"
    ai_tools_relabel_available || return 2
    _ai_tools_is_sandbox "${dir}" \
        || semanage fcontext -d "${dir}(/.*)?" 2>/dev/null || true
    restorecon -RF "${dir}" 2>/dev/null || return 1
}

# ai_tools_project_labelled <dir>: 0 if <dir>'s root currently carries
# ai_tools_project_t. A cheap, read-only state check for idempotent callers -- it
# inspects the live label, makes no policy change, and needs no privilege.
ai_tools_project_labelled() {
    local ctx
    ctx="$(ls -Zd "$1" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "${ctx}" == *":${AI_TOOLS_PROJECT_TYPE}:"* ]]
}

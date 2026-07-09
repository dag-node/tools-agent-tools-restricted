#!/usr/bin/env bash
# /usr/local/lib/ai-tools/safe-paths.lib.sh
# Single source of truth for the system directories the ai-tools elevated helpers must
# never operate on, plus the guard that enforces it. Defense in depth against an operator
# config error: the allowlist alone would let a recursive chown/setgid/setfacl/relabel run
# wherever it points, so a system directory mistakenly added to allowed-projects (or passed
# to a helper) could be rewritten. This list is the independent backstop -- the launch
# wrapper, the claim CLI, and every elevated helper refuse a protected target regardless of
# the allowlist, before acting.
#
# Matching is exact-or-ancestor: a target is protected when its resolved real path EQUALS a
# list entry or CONTAINS one (is an ancestor, e.g. "/"). A user home ROOT (a direct child
# of /home) is additionally protected exactly: a whole home as a claim or sweep target
# would hand the agent every dotfile and key in it (~/.ssh, ~/.gnupg, ...). Descendants
# pass, so a real project nested under an operator home (/home/<user>/<proj>) or a sandbox
# clone (/var/opt/ai-tools/sandbox-projects/<repo>) is unaffected -- those are the trees
# the helpers legitimately act on. A deeper or glob-expanded accident inside a protected tree
# stays covered by each helper's owner-guard, which acts only on agent- or operator-owned
# paths and never the root-owned files that fill a system directory.
#
# Sourced (not executed) so every consumer shares ONE list and ONE matcher. Deployed
# 644 root:root (world-readable; carries no secrets; the operator wrapper, the CLI, and the
# root helpers all read it) like msg.lib.sh / log.lib.sh.

# shellcheck disable=SC2034  # consumed by the sourcing scripts and the test suite
AI_TOOLS_PROTECTED_PATHS=(
    /                                              # the filesystem root itself
    /bin /sbin /lib /lib64 /lib32 /libx32          # usrmerge compat symlinks + libraries
    /usr /usr/bin /usr/sbin /usr/lib /usr/lib64 /usr/libexec /usr/local
    /etc                                           # system configuration
    /var /var/tmp                                  # variable/runtime state, spool, logs, DBs
    /boot /boot/efi /efi                           # bootloader, kernels, EFI system partition
    /root                                          # the root account's home
    /home                                          # parent of every user home (homes themselves pass)
    /srv                                           # served data
    /opt /opt/ai-tools                             # add-on packages + the sandbox control plane
    /dev /proc /sys /run                           # device, kernel, and runtime pseudo-filesystems
    /mnt /media                                    # mount points
    /tmp /lost+found                               # scratch space + fsck recovery
)

# ai_tools_protected_path_match <abspath>
# Print the matching protected entry and return 0 when <abspath> is protected -- it equals
# an entry, is an ancestor that contains one, or is a user home root. Return 1 otherwise.
# Expects an absolute path; normalizes a trailing slash so "/etc/" matches "/etc" and bare
# root stays "/".
ai_tools_protected_path_match() {
    local path="${1:-}" entry
    [[ -n "${path}" ]] || return 1
    path="${path%/}"; [[ -z "${path}" ]] && path="/"
    for entry in "${AI_TOOLS_PROTECTED_PATHS[@]}"; do
        [[ "${path}" == "${entry}" ]] && { printf '%s\n' "${entry}"; return 0; }   # exact
        [[ "${entry}" == "${path}/"* ]] && { printf '%s\n' "${entry}"; return 0; } # path contains entry
    done
    # User home roots: a direct child of /home matches exactly; deeper paths pass.
    if [[ "${path}" =~ ^/home/[^/]+$ ]]; then
        printf '%s\n' "${path} (user home root)"; return 0
    fi
    return 1
}

# ai_tools_assert_safe_target <path> [operation-label]
# When <path> resolves to a protected system directory, emit a framed refusal (a msg.lib
# box on a terminal, plain lines otherwise), log it at WARNING, and return 1 so the caller
# aborts BEFORE acting. Return 0 silently when the path is safe. The path is resolved with
# realpath -m (no existence requirement) and falls back to the raw argument, so an
# unresolvable path is still matched against the list rather than slipping through.
ai_tools_assert_safe_target() {
    local raw_path="${1:-}" operation="${2:-operation}" resolved_path matched_entry
    resolved_path="$(realpath -m -- "${raw_path}" 2>/dev/null)" || resolved_path="${raw_path}"
    matched_entry="$(ai_tools_protected_path_match "${resolved_path}")" || return 0
    local line_intro="Refusing the ${operation}: the target is a protected system directory."
    local line_path="${resolved_path}"
    local line_detail="It is on the ai-tools protected-paths backstop (matched ${matched_entry}); the sandbox does not operate on system directories. A real project must live elsewhere -- do not add a system directory to allowed-projects."
    ai_tools_msg_error "${line_intro}" "${line_path}" "${line_detail}"
    declare -F ai_tools_log_warn >/dev/null 2>&1 \
        && ai_tools_log_warn "refused ${operation} on protected path ${resolved_path} (matched ${matched_entry})"
    return 1
}

# msg.lib is REQUIRED (the refusal above renders through it, and the sourcing helpers
# rely on its ai_tools_msg_confirm): a bare source, so a missing lib fails this library's
# own load and the consumer's fail-closed handling takes over. msg.lib carries an include
# guard, so a consumer that already sourced it re-sources a no-op.
# shellcheck source=SCRIPTDIR/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh

#!/usr/bin/env bash
# /usr/local/lib/ai-tools/relabel.lib.sh
# Single source of the SELinux labelling primitives the sandbox applies at runtime, in two
# families:
#   * PROJECTS -- map an approved project directory to ai_tools_project_t (or revert it) so the
#     confined agent (ai_tools_t) can read and write the tree. Sourced by the root helper
#     ai-tools-relabel and by selinux/install-selinux.sh's allowlist sweep.
#   * AGENT PATHS -- map each enabled agent's own paths to the types this policy defines: its
#     launcher binary to ai_tools_exec_t (the label that drives the -> ai_tools_t domain
#     transition on exec) and its config directory to ai_tools_home_t (so the confined session can
#     write its state). Sourced by the root helper ai-tools-relabel-agent and by the same
#     installer's verify pass.
# Both families keep their `semanage fcontext` + `restorecon` body in exactly one place.
#
# In-place project paths (under a user's home) are DYNAMIC, so they get a
# per-project `semanage fcontext` rule here. Sandbox clones under
# /var/opt/ai-tools/sandbox-projects are already mapped by a STATIC rule in
# selinux/policy/ai_tools.fc, so for those a plain restorecon suffices and adding a local
# rule would be redundant -- the helpers below detect and skip the semanage step
# for sandbox paths. See selinux/policy/ai_tools.fc and selinux/policy/ai_tools.te.
#
# Every mutating function is root-only: semanage writes the policy store and
# restorecon needs relabel. Callers must already be root. The functions are
# best-effort -- a disabled SELinux or a missing toolchain is reported via the
# return code (2 = unavailable, 1 = hard failure), never an abort -- so a sourcing
# script keeps `set -e` semantics by checking the return value.

readonly AI_TOOLS_PROJECT_TYPE="ai_tools_project_t"
readonly AI_TOOLS_SANDBOX_ROOT="/var/opt/ai-tools/sandbox-projects"
# The entrypoint type is pinned HERE, not read from a manifest: an agent package declares only
# WHICH path is its entrypoint, never what type to give it, so no manifest can label a file into
# a domain of its choosing.
readonly AI_TOOLS_ENTRYPOINT_TYPE="ai_tools_exec_t"
# The type every agent's own config directory carries -- the same one the rest of the agent's
# home state uses, so the confined domain may write its session state there.
readonly AI_TOOLS_AGENT_CONFIG_TYPE="ai_tools_home_t"
# The one tree an agent entrypoint may live in -- the sandbox's own Node toolchain. Every
# declared pattern is checked against it (ai_tools_entrypoint_fcontext_valid).
readonly AI_TOOLS_ENTRYPOINT_ROOT="/opt/ai-tools/.nvm/versions/node"

# Which agents are enabled and what each declares comes from the provider manifests; the home
# root, the config-directory contract, and its name validator come from control-plane.lib.sh
# (which loads providers itself). Both best-effort: without them the agent functions below refuse
# (they resolve no agent), while the project functions -- which need neither -- keep working.
# shellcheck source=SCRIPTDIR/providers.lib.sh
source "${BASH_SOURCE[0]%/*}/providers.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/control-plane.lib.sh
source "${BASH_SOURCE[0]%/*}/control-plane.lib.sh" 2>/dev/null || true

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

# ── Agent-declared SELinux paths ─────────────────────────────────────────────────────────────
# Two paths per agent must carry a type from this policy, and both are agent-specific, so each
# agent package DECLARES them in its manifest and the rules are applied as LOCAL
# `semanage fcontext` entries rather than carried in the base policy module:
#
#   entrypoint_fcontext -> ai_tools_exec_t   the launcher binary. Without this label its exec
#                                            fires no domain transition and the session would run
#                                            unconfined (ai-tools-run refuses to launch instead).
#   config_dir          -> ai_tools_home_t   the agent's control-plane directory. Without it the
#                                            confined session cannot write its own state (the
#                                            home root is usr_t, which ai_tools_t may not write).
#
# The base pins the TYPES here; a manifest chooses only which path is which, and each declaration
# is checked to be containable -- the entrypoint pattern under the sandbox toolchain, the config
# directory to one component under the sandbox home. So a second agent brings its binary and its
# state directory into this policy without the base policy naming either.

# ai_tools_entrypoint_fcontext_valid <pattern>: pure check, no I/O -- succeed when <pattern> is a
#   file-context regex that can only ever match inside the sandbox toolchain. Two conditions,
#   both required, because the type it will be given is an exec entrypoint of the confined
#   domain: with its backslash escapes removed the pattern must start with the toolchain root
#   (so the literal head is anchored there), and it must contain no `|`, `(`, or other
#   metacharacter that could match a path outside that head. Character classes, `*`, `+`, `.`,
#   and escapes are what a path pattern needs and all it gets.
ai_tools_entrypoint_fcontext_valid() {
    # Path characters, character classes, `*`, `+`, `.` and escapes -- no `|`, no `(`, no `$`,
    # no whitespace. `]` leads the set and `-` closes it, the POSIX way to include both.
    local allowed='^[]A-Za-z0-9_./@+*^[\-]+$'
    local pattern="${1:-}" plain="${1//\\/}"
    [[ -n "${pattern}" ]] || return 1
    [[ "${pattern}" =~ ${allowed} ]] || return 1
    [[ "${pattern}" != *..* ]] || return 1
    [[ "${plain}" == "${AI_TOOLS_ENTRYPOINT_ROOT}/"* ]]
}

# _ai_tools_entrypoint_policy_active: succeed when there is an ai_tools_exec_t to assign, i.e.
#   SELinux is on, the labelling tools are present, and the ai_tools module is loaded. Where it
#   fails there is nothing to label and that is not an error -- the SELinux layer is optional.
_ai_tools_entrypoint_policy_active() {
    ai_tools_relabel_available || return 1
    command -v semanage >/dev/null 2>&1 || return 1
    command -v semodule  >/dev/null 2>&1 || return 1
    semodule -l 2>/dev/null | grep -qE '^ai_tools([[:space:]]|$)'
}

# _ai_tools_fcontext <add|delete> <file-type> <selinux-type> <pattern>: register or drop the local
#   file-context rule mapping <pattern> to <selinux-type>, scoped by semanage's file-type letter
#   (`f` regular files, as the base policy's own `--` rules are scoped; `a` all types, for a
#   subtree). `-a` fails when a rule for the pattern already exists, so an add falls back to `-m`
#   and the call is idempotent.
_ai_tools_fcontext() {
    local action="$1" file_type="$2" selinux_type="$3" pattern="$4"
    if [[ "${action}" == delete ]]; then
        semanage fcontext -d -f "${file_type}" -- "${pattern}" 2>/dev/null || true
        return 0
    fi
    semanage fcontext -a -f "${file_type}" -t "${selinux_type}" -- "${pattern}" 2>/dev/null && return 0
    semanage fcontext -m -f "${file_type}" -t "${selinux_type}" -- "${pattern}" 2>/dev/null
}

# _ai_tools_agent_config_pattern <config-dir-name>: print the file-context pattern for an agent's
#   config directory and everything under it. Dots are escaped (a bare `.` in a regex matches any
#   character), and the name has already been validated as one component.
_ai_tools_agent_config_pattern() {
    printf '%s/%s(/.*)?' "${CP_HOME}" "${1//./\\.}"
}

# _ai_tools_entrypoint_paths <pattern>: print each installed file the pattern matches. find's
#   POSIX-extended `-regex` matches the whole path, the same anchoring SELinux gives a file-context
#   regex, so the set relabelled here is the set the rule governs -- no second pattern language.
#   The walk is rooted at the toolchain (never `/`) and runs on a relabel, not on a launch.
_ai_tools_entrypoint_paths() {
    find "${AI_TOOLS_ENTRYPOINT_ROOT}" -xdev -regextype posix-extended \
         -regex "$1" -type f 2>/dev/null
}

# _ai_tools_verify_label <path> <wanted-type> : restore the label on <path> and report the
#   outcome as one status line (see ai_tools_label_agent_paths). Returns non-zero when the path
#   did not take the type.
_ai_tools_verify_label() {
    local path="$1" wanted="$2" context
    restorecon -F "${path}" 2>/dev/null || true
    context="$(stat -c '%C' -- "${path}" 2>/dev/null | awk -F: '{print $3}')"
    if [[ "${context}" == "${wanted}" ]]; then
        printf 'ok %s\n' "${path}"
        return 0
    fi
    printf 'bad %s %s %s\n' "${path}" "${context:-unknown}" "${wanted}"
    return 1
}

# _ai_tools_label_agent_entrypoint <agent> : the entrypoint half of the loop below. Emits status
#   lines; returns non-zero on a refusal or a path that did not take the type.
_ai_tools_label_agent_entrypoint() {
    local agent="$1" pattern path status=0 matched=0
    pattern="$(ai_tools_agent_manifest_field "${agent}" entrypoint_fcontext || true)"
    if [[ -z "${pattern}" ]]; then
        printf 'skip %s declares no entrypoint_fcontext\n' "${agent}"
        return 0
    fi
    if ! ai_tools_entrypoint_fcontext_valid "${pattern}"; then
        printf 'skip %s entrypoint_fcontext is not a plain path pattern under %s\n' \
            "${agent}" "${AI_TOOLS_ENTRYPOINT_ROOT}"
        return 1
    fi
    if ! _ai_tools_fcontext add f "${AI_TOOLS_ENTRYPOINT_TYPE}" "${pattern}"; then
        printf 'skip %s could not register its entrypoint file-context rule\n' "${agent}"
        return 1
    fi
    while IFS= read -r path; do
        matched=1
        _ai_tools_verify_label "${path}" "${AI_TOOLS_ENTRYPOINT_TYPE}" || status=1
    done < <(_ai_tools_entrypoint_paths "${pattern}")
    (( matched )) || printf 'none %s its entrypoint\n' "${agent}"
    return "${status}"
}

# _ai_tools_label_agent_config_dir <agent> : the config-directory half. Same shape; the subtree is
#   restored recursively, and only the directory itself is verified (its contents inherit).
_ai_tools_label_agent_config_dir() {
    local agent="$1" config_dir path pattern
    config_dir="$(ai_tools_agent_manifest_field "${agent}" config_dir || true)"
    if [[ -z "${config_dir}" ]]; then
        printf 'skip %s declares no config_dir\n' "${agent}"
        return 0
    fi
    if ! declare -F ai_tools_agent_config_dir_valid >/dev/null 2>&1 \
            || ! ai_tools_agent_config_dir_valid "${config_dir}"; then
        printf 'skip %s config_dir is not one plain component under %s\n' "${agent}" "${CP_HOME}"
        return 1
    fi
    pattern="$(_ai_tools_agent_config_pattern "${config_dir}")"
    if ! _ai_tools_fcontext add a "${AI_TOOLS_AGENT_CONFIG_TYPE}" "${pattern}"; then
        printf 'skip %s could not register its config-directory file-context rule\n' "${agent}"
        return 1
    fi
    path="${CP_HOME}/${config_dir}"
    if [[ ! -d "${path}" ]]; then
        printf 'none %s its config directory\n' "${agent}"
        return 0
    fi
    restorecon -RF "${path}" 2>/dev/null || true
    _ai_tools_verify_label "${path}" "${AI_TOOLS_AGENT_CONFIG_TYPE}"
}

# ai_tools_label_agent_paths: apply every ENABLED agent's declared file-context rules -- its
#   entrypoint and its config directory -- and restore the labels on what they match. Prints one
#   status line per outcome, for the caller to render in its own voice:
#     ok    <path>                     the path carries the type the base pins for it
#     bad   <path> <actual> <wanted>   it does not -- the session would break or run unconfined
#     none  <agent> <what>             declared, but not installed (yet)
#     skip  <agent> <reason...>        nothing to apply, or a declaration was refused
#   Returns 0 when every path it managed is correctly labelled, 1 when one is not or a rule could
#   not be registered, and 2 when the SELinux layer is inactive (nothing to do).
ai_tools_label_agent_paths() {
    _ai_tools_entrypoint_policy_active || return 2
    declare -F ai_tools_enabled_agents >/dev/null 2>&1 || return 2
    local agent status=0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        _ai_tools_label_agent_entrypoint "${agent}" || status=1
        _ai_tools_label_agent_config_dir "${agent}" || status=1
    done < <(ai_tools_enabled_agents 2>/dev/null)
    return "${status}"
}

# ai_tools_unlabel_agent_paths <agent>: drop that agent's declared file-context rules and restore
#   default labels on what they matched -- the erase-time counterpart, so a removed agent package
#   leaves no rule behind for types its host may no longer define. Reads the manifest, so it runs
#   while that package's files are still present (rpm %preun). Returns 2 when the SELinux layer is
#   inactive, 1 when the agent declares nothing usable, 0 otherwise.
ai_tools_unlabel_agent_paths() {
    local agent="$1" pattern config_dir path dropped=1
    _ai_tools_entrypoint_policy_active || return 2
    declare -F ai_tools_agent_manifest_field >/dev/null 2>&1 || return 2

    pattern="$(ai_tools_agent_manifest_field "${agent}" entrypoint_fcontext || true)"
    if ai_tools_entrypoint_fcontext_valid "${pattern}"; then
        _ai_tools_fcontext delete f "${AI_TOOLS_ENTRYPOINT_TYPE}" "${pattern}"
        while IFS= read -r path; do
            restorecon -F "${path}" 2>/dev/null || true
        done < <(_ai_tools_entrypoint_paths "${pattern}")
        dropped=0
    fi

    config_dir="$(ai_tools_agent_manifest_field "${agent}" config_dir || true)"
    if declare -F ai_tools_agent_config_dir_valid >/dev/null 2>&1 \
            && ai_tools_agent_config_dir_valid "${config_dir}"; then
        _ai_tools_fcontext delete a "${AI_TOOLS_AGENT_CONFIG_TYPE}" \
            "$(_ai_tools_agent_config_pattern "${config_dir}")"
        # The directory itself is agent STATE and survives the package (like .nvm), so it is
        # relabelled to whatever the remaining policy maps it to rather than left on a type this
        # host may stop defining.
        path="${CP_HOME}/${config_dir}"
        [[ -d "${path}" ]] && restorecon -RF "${path}" 2>/dev/null
        dropped=0
    fi
    return "${dropped}"
}

# ai_tools_project_labelled <dir>: 0 if <dir>'s root currently carries
# ai_tools_project_t. A cheap, read-only state check for idempotent callers -- it
# inspects the live label, makes no policy change, and needs no privilege.
ai_tools_project_labelled() {
    local ctx
    ctx="$(ls -Zd "$1" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "${ctx}" == *":${AI_TOOLS_PROJECT_TYPE}:"* ]]
}

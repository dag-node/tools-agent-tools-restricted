#!/usr/bin/env bash
# shellcheck disable=SC2034  # boundary-mode constants, read by install.sh and the perms test
# /usr/local/lib/ai-tools/control-plane.lib.sh
# Canonical boundary-mode constants for the /opt/ai-tools control plane. The control plane is
# owned root:ai-tools permanently -- the RPM ships it that way and nothing re-owns it to a person
# -- so the agent (group ai-tools) reaches its state while root owns the locked control files.
# This file is *sourced* (never executed) so the installer and the test suite assert the same
# boundary modes the spec %files declares, from one source. See ownership-and-hooks.rule.md.
#
# It carries the canonical home, its mode, and the per-subdirectory modes -- plus the contract
# for an AGENT CONFIG DIRECTORY, which is a shape rather than a path: base owns the home root and
# bin, while each agent package owns a directory under the home whose NAME its manifest declares
# (config_dir) and whose mode and label this file pins. That is what lets a second agent bring its
# own control-plane directory without the base layer naming it. The agent's own subtrees
# (.nvm/.cache/.local/.npm) stay agent-owned and .git is root-private 0700, so they are not
# described here.

# Sourced more than once in a single shell: the readonly below would abort under set -e on the
# second pass. Return early (an if-statement, not `[[ ]] && return`, which returns 1 for an unset
# guard and trips the sourcing shell's set -e).
if [[ -n "${_AI_TOOLS_CONTROL_PLANE_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_CONTROL_PLANE_LIB=1

# Control-plane home root. The boundary modes below apply to it and its sub-directories.
readonly CP_HOME=/opt/ai-tools

# Boundary modes (every path is owned root:ai-tools):
#   CP_HOME_MODE   2751 home root: the agent (group) traverses+reads, setgid keeps files born here
#                       in the sandbox group, and the o+x search bit lets any operator readlink the
#                       launcher (the only reach an operator needs into the control plane)
#   CP_DIR_MODES        per base-owned sub-directory:
#                     0551 bin     locked -- the agent cannot swap a launcher symlink or the
#                                  updater; o+x so an operator readlinks bin/<launcher>
#   CP_AGENT_CONFIG_MODE
#                     3770 setgid+sticky, applied to EVERY agent's config directory: the agent is
#                          a group-writer for its own session state but cannot unlink the control
#                          files (settings, hooks) it does not own
#   CP_SHARED_SKILLS
#                          the one place skills live, agent-agnostic: the base ships them here
#                          and each agent's config directory carries SYMLINKS into it rather than
#                          a copy, so a skill is authored, updated, and read in one location. Its
#                          mode is CP_DIR_MODES[skills] -- root-owned, agent-readable, not
#                          agent-writable.
readonly CP_HOME_MODE=2751
readonly -A CP_DIR_MODES=( [bin]=0551 [skills]=0750 )
readonly CP_AGENT_CONFIG_MODE=3770
readonly CP_SHARED_SKILLS="${CP_HOME}/skills"

# Which agents are installed and enabled, and what each declares, comes from the provider
# manifests. Loaded best-effort: without it the resolver below yields nothing, which leaves a
# caller asserting no agent config directory rather than guessing a path.
# shellcheck source=SCRIPTDIR/providers.lib.sh
source "${BASH_SOURCE[0]%/*}/providers.lib.sh" 2>/dev/null || true

# ai_tools_agent_config_dir_valid <name> : pure check -- succeed when <name> is usable as an
#   agent's config directory: ONE path component under the home, no traversal, no separator. The
#   value reaches root helpers as a path and a `semanage fcontext` pattern, so a manifest names a
#   directory beneath the home and can address nothing else.
ai_tools_agent_config_dir_valid() {
    local name="${1:-}"
    [[ -n "${name}" ]] || return 1
    [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "${name}" != . && "${name}" != .. && "${name}" != *..* ]]
}

# ai_tools_agent_skills_dirs : print "agent<TAB>absolute-path" for the skills directory of every
#   ENABLED agent that declares one (manifest skills_dir, a single component inside its config
#   directory). An agent that declares none takes no skill links -- the shared skills are in the
#   Claude Code SKILL.md format, so an agent that cannot read that format simply does not ask.
ai_tools_agent_skills_dirs() {
    declare -F ai_tools_enabled_agents >/dev/null 2>&1 || return 0
    local agent config_dir skills_dir
    while IFS=$'\t' read -r agent config_dir; do
        skills_dir="$(ai_tools_agent_manifest_field "${agent}" skills_dir || true)"
        ai_tools_agent_config_dir_valid "${skills_dir}" || continue
        printf '%s\t%s/%s\n' "${agent}" "${config_dir}" "${skills_dir}"
    done < <(ai_tools_agent_config_dirs)
    return 0
}

# ai_tools_agent_config_dirs : print "agent<TAB>absolute-path" for every ENABLED agent that
#   declares a valid config_dir, in manifest order. The one resolver for "which control-plane
#   directories exist on this host", used by the installer, the SELinux labelling, the
#   managed-asset seeding, and the permission test, so none of them names a directory itself.
ai_tools_agent_config_dirs() {
    declare -F ai_tools_enabled_agents >/dev/null 2>&1 || return 0
    local agent config_dir
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        config_dir="$(ai_tools_agent_manifest_field "${agent}" config_dir || true)"
        ai_tools_agent_config_dir_valid "${config_dir}" || continue
        printf '%s\t%s/%s\n' "${agent}" "${CP_HOME}" "${config_dir}"
    done < <(ai_tools_enabled_agents 2>/dev/null)
    return 0
}

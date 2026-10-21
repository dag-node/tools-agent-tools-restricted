#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck disable=SC2034  # boundary-mode constants, read by install.sh and the perms test
# /usr/local/lib/ai-tools/control-plane.lib.sh
# Canonical boundary-mode constants for the /opt/ai-tools control plane. The control plane is owned root:ai-tools
# permanently -- the RPM ships it that way and no step re-owns it to a person -- so the agent (group ai-tools) reaches
# its state while root owns the locked control files. This file is *sourced* (never executed) so the installer
# and the test suite assert the same boundary modes the spec %files declares, from one source. See
# ownership-and-hooks.rule.md.
#
# It carries the canonical home, its mode, and the per-subdirectory modes -- plus the contract for an AGENT CONFIG
# DIRECTORY, which is a shape rather than a path: base owns the home root and bin, while each agent package owns
# a directory under the home whose NAME its manifest declares (config_dir) and whose mode and label this file pins.
# That is what lets a second agent bring its own control-plane directory without the base layer naming it. The agent's
# own subtrees (.nvm/.cache/.npm) stay agent-owned and .git is root-private 0700, so they are not described here.
#
# It also carries the unit search path chain of the account's `systemd --user` manager (ownership-and-hooks.rule.md).

# Sourced more than once in a single shell: this library's readonly constants would abort under `set -e` on the second
# pass. Return early (an if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and trips the sourcing
# shell's `set -e`).
if [[ -n "${_AI_TOOLS_CONTROL_PLANE__LOADED:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_CONTROL_PLANE__LOADED=1

# Control-plane home root. The boundary modes apply to it and its sub-directories.
readonly CP_HOME=/opt/ai-tools

# Boundary modes (every path is owned root:ai-tools). Each mode is its own constant; what it
# grants:
#   CP_HOME_MODE   home root: the agent (group) traverses+reads, setgid keeps files born here in
#                  the sandbox group, and the o+x search bit lets any operator readlink the
#                  launcher (the only reach an operator needs into the control plane)
#   CP_DIR_MODES   per base-owned sub-directory:
#                  bin  locked -- the agent cannot swap a launcher symlink or the updater, since
#                       the directory denies group write and it does not own it; o+x so an
#                       operator readlinks bin/<launcher>
#   CP_AGENT_CONFIG_MODE
#                  setgid+sticky, applied to EVERY agent's config directory: the agent is a
#                  group-writer for its own session state but cannot unlink the control files
#                  (settings, hooks) it does not own, since sticky allows that only to an entry's
#                  owner and root owns the directory
#   CP_INTEGRATIONS        the one root under which every INTEGRATION keeps its sandbox-side
#                          state, one directory per integration named for its manifest
#                          (integrations/<name>/...). Base owns the root and its single SELinux
#                          file-context rule; each integration package owns its own directory and
#                          chooses the modes inside it, so a new toolchain brings neither policy nor
#                          dotdir at the home root.
#   CP_SHARED_SKILLS / CP_SHARED_SUBAGENTS / CP_SHARED_ORIENTATION
#                          the one place each SHARED asset kind lives, agent-agnostic: the base
#                          ships them here and every agent's config directory carries SYMLINKS
#                          into them rather than copies, so an asset is authored, updated, and
#                          read in one location. Their modes are CP_DIR_MODES[<kind>] --
#                          root-owned, agent-readable, not agent-writable.
readonly CP_HOME_MODE=2751
readonly -A CP_DIR_MODES=(
    [bin]=0551 [skills]=0750 [subagents]=0750 [orientation]=0750 [integrations]=0750
)
readonly CP_AGENT_CONFIG_MODE=3770
readonly CP_SHARED_SKILLS="${CP_HOME}/skills"
readonly CP_SHARED_SUBAGENTS="${CP_HOME}/subagents"
readonly CP_SHARED_ORIENTATION="${CP_HOME}/orientation"
readonly CP_INTEGRATIONS="${CP_HOME}/integrations"

# The unit search path chain, top-down, and each directory's mode (owner root, group ai-tools):
#   .local, .local/share   3770  setgid+sticky: the account keeps its own XDG entries there and cannot rename the next
#                                link, since sticky allows that to the entry's owner alone
#   .local/share/systemd   2750  the account cannot create `user` in it
# CP_TIMER_STAMP_DIR stays the account's at CP_TIMER_STAMP_DIR_MODE, because its manager writes the Persistent= stamps
# there; CP_UPDATE_TIMER_STAMP is the one nvm-update.timer keeps.
readonly -a CP_UNIT_SEARCH_PATH_CHAIN=(.local .local/share .local/share/systemd)
readonly -A CP_UNIT_SEARCH_PATH_MODES=([.local]=3770 [.local/share]=3770 [.local/share/systemd]=2750)
readonly CP_TIMER_STAMP_DIR=.local/share/systemd/timers
readonly CP_TIMER_STAMP_DIR_MODE=0750
readonly CP_UPDATE_TIMER_STAMP=stamp-nvm-update.timer

# Which agents are installed and enabled, and what each declares, comes from the provider manifests. Loaded best-effort:
# without it the agent resolvers yield an empty set, so a caller does not assert any agent config directory rather than
# guessing a path.
# shellcheck source=SCRIPTDIR/providers.lib.sh
source "${BASH_SOURCE[0]%/*}/providers.lib.sh" 2>/dev/null || true

# ai_tools_control_plane__apply_mode <mode> <path>... : set the mode EXACTLY, special bits included. Load-bearing here
#   because the control-plane home is setgid (CP_HOME_MODE): every directory created under it INHERITS setgid, and GNU
#   chmod preserves a directory's setuid/setgid bits unless the octal mode carries five digits -- so `chmod 0750` leaves
#   2750 in place and a declared mode silently does not hold. The RPM sets modes exactly, so without this the two
#   install paths would disagree about the same directory. Normalizes to five digits.
ai_tools_control_plane__apply_mode() {
    local mode="0000${1}"; shift
    chmod "0${mode: -4}" "$@"
}

# _ai_tools_control_plane__format_printable <text> : print <text> with every byte outside printable ASCII and tab
#   replaced by `?`. A name under the chain is the sandbox account's to choose and reaches a terminal from an RPM
#   scriptlet, which does not load a logger, so the clamp is local.
_ai_tools_control_plane__format_printable() { printf '%s' "$*" | tr -c '[:print:]\t' '?'; }

# ai_tools_control_plane__find_unexpected_unit_search_path_entries <home> : print each entry in the chain's last
#   directory other than CP_TIMER_STAMP_DIR, one path per line, clamped by _ai_tools_control_plane__format_printable. No
#   ai-tools step writes one, and `user` among them is a unit search path, so each is a finding the operator inspects.
ai_tools_control_plane__find_unexpected_unit_search_path_entries() {
    local home="${1:?}" entry
    local data_dir="${home}/${CP_UNIT_SEARCH_PATH_CHAIN[-1]}"
    [[ -d "${data_dir}" && ! -L "${data_dir}" ]] || return 0
    while IFS= read -r -d '' entry; do
        [[ "${entry}" == "${home}/${CP_TIMER_STAMP_DIR}" && -d "${entry}" && ! -L "${entry}" ]] && continue
        _ai_tools_control_plane__format_printable "${entry}"; printf '\n'
    done < <(find "${data_dir}" -xdev -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

# The chain is brought to these modes by the layout reconcile (layout.lib.sh), whose rows hold each directory of it
# and the timer-stamp directory; ai_tools_control_plane__find_unit_search_path_drift
# and ai_tools_control_plane__find_unexpected_unit_search_path_entries are what `ai-tools-admin status` reports from.

# ai_tools_control_plane__find_unit_search_path_drift <home> <group> : print one line per chain directory whose owner
#   or mode is not the declared one, as `<path> <owner:group mode> root:<group> <mode>`; an absent, symlinked
#   or unreadable path prints that word in place of the owner and mode. Returns 0 when it printed drift, 1
#   when the chain holds its layout, and 2 when an argument is missing, so a caller does not render a failed reading
#   as a closed path.
ai_tools_control_plane__find_unit_search_path_drift() {
    local home="${1:-}" group="${2:-}" relative path mode got drifted=1
    [[ -n "${home}" && -n "${group}" ]] || return 2
    for relative in "${CP_UNIT_SEARCH_PATH_CHAIN[@]}"; do
        path="${home}/${relative}"
        mode="${CP_UNIT_SEARCH_PATH_MODES[${relative}]}"
        if [[ -L "${path}" ]]; then
            printf '%s symlink root:%s %s\n' "${path}" "${group}" "${mode}"; drifted=0; continue
        fi
        if [[ ! -d "${path}" ]]; then
            printf '%s absent root:%s %s\n' "${path}" "${group}" "${mode}"; drifted=0; continue
        fi
        got="$(stat -c '%U:%G %a' -- "${path}" 2>/dev/null)" || { printf '%s unreadable root:%s %s\n' "${path}" "${group}" "${mode}"; drifted=0; continue; }
        [[ "${got}" == "root:${group} ${mode}" ]] && continue
        printf '%s %s root:%s %s\n' "${path}" "${got}" "${group}" "${mode}"
        drifted=0
    done
    return "${drifted}"
}

# ai_tools_control_plane__is_agent_config_dir_valid <name> : pure check -- succeed when <name> is usable as an agent's
#   config directory: ONE path component under the home, no traversal, no separator. The value reaches root helpers
#   as a path and a `semanage fcontext` pattern, so a manifest names a directory beneath the home and cannot address
#   a path outside it.
ai_tools_control_plane__is_agent_config_dir_valid() {
    local name="${1:-}"
    [[ -n "${name}" ]] || return 1
    [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "${name}" != . && "${name}" != .. && "${name}" != *..* ]]
}

# ai_tools_control_plane__list_agent_asset_dirs <manifest-field> : print "agent<TAB>absolute-path" for the directory
#   every ENABLED agent declares in <manifest-field> (skills_dir, subagents_dir) -- a single component inside
#   that agent's config directory, so the agent names WHERE its own product expects a kind of asset while the layout
#   under the home stays the base package's. An agent that declares none is given no links of that kind: the shared
#   assets are in the Claude Code format, which an agent that cannot read it leaves unset.
ai_tools_control_plane__list_agent_asset_dirs() {
    declare -F ai_tools_providers__list_enabled_agents >/dev/null 2>&1 || return 0
    local field="$1" agent config_dir asset_dir
    while IFS=$'\t' read -r agent config_dir; do
        asset_dir="$(ai_tools_providers__read_agent_manifest_field "${agent}" "${field}" || true)"
        ai_tools_control_plane__is_agent_config_dir_valid "${asset_dir}" || continue
        printf '%s\t%s/%s\n' "${agent}" "${config_dir}" "${asset_dir}"
    done < <(ai_tools_control_plane__list_agent_config_dirs)
    return 0
}

# ai_tools_control_plane__list_agent_memory_targets : print "agent<TAB>absolute-path" for the file every ENABLED agent
#   declares in `memory_file` -- the name its own product reads as user-scope instructions, loaded in every session
#   in every project (CLAUDE.md for Claude Code). One component inside that agent's config directory, validated exactly
#   as config_dir is, so a manifest names a file beneath the home and cannot address a path outside it. An agent
#   that declares none is given no orientation link, the same way it is given no links of an asset kind it cannot read.
ai_tools_control_plane__list_agent_memory_targets() {
    declare -F ai_tools_providers__list_enabled_agents >/dev/null 2>&1 || return 0
    local agent config_dir memory_file
    while IFS=$'\t' read -r agent config_dir; do
        memory_file="$(ai_tools_providers__read_agent_manifest_field "${agent}" memory_file || true)"
        ai_tools_control_plane__is_agent_config_dir_valid "${memory_file}" || continue
        printf '%s\t%s/%s\n' "${agent}" "${config_dir}" "${memory_file}"
    done < <(ai_tools_control_plane__list_agent_config_dirs)
    return 0
}

# ai_tools_control_plane__list_agent_config_dirs : print "agent<TAB>absolute-path" for every ENABLED agent that declares
#   a valid config_dir, in manifest order. The one resolver for "which control-plane directories exist on this host",
#   used by the installer, the SELinux labelling, the managed-asset seeding, and the permission test, so none of them
#   names a directory itself.
ai_tools_control_plane__list_agent_config_dirs() {
    declare -F ai_tools_providers__list_enabled_agents >/dev/null 2>&1 || return 0
    local agent config_dir
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        config_dir="$(ai_tools_providers__read_agent_manifest_field "${agent}" config_dir || true)"
        ai_tools_control_plane__is_agent_config_dir_valid "${config_dir}" || continue
        printf '%s\t%s/%s\n' "${agent}" "${CP_HOME}" "${config_dir}"
    done < <(ai_tools_providers__list_enabled_agents 2>/dev/null)
    return 0
}

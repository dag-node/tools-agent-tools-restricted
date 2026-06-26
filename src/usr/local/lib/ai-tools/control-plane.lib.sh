#!/usr/bin/env bash
# /usr/local/lib/ai-tools/control-plane.lib.sh
# Canonical manifest of the /opt/ai-tools control plane, grouped by security boundary, plus the
# re-own routine that asserts it. This file is *sourced* (never executed) by ai-tools-enroll (the
# full enroll and the %posttrans `--reassert`) and by install.sh (the dev deploy), so the boundary
# -- which paths the operator owns and at which modes -- is defined ONCE and the runtime re-assert
# and the installer cannot drift.
#
# This is the single place to list a control-plane path: add it to the array for its boundary and
# reown_control_plane picks it up. The arrays hold the operator-owned control plane; the agent's
# own subtrees (.nvm/.cache/.local/.npm) stay agent-owned and .git stays operator-private, so they
# are not listed here.

# Sourced more than once in a single shell: the readonly below would abort under set -e on the
# second pass. Return early (an if-statement, not `[[ ]] && return`, which returns 1 for an unset
# guard and trips the sourcing shell's set -e).
if [[ -n "${_AI_TOOLS_CONTROL_PLANE_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_CONTROL_PLANE_LIB=1

# Control-plane home root. Paths in the arrays below are relative to it. AI_TOOLS_CONTROL_PLANE_HOME
# overrides it when set -- a root-only test hook (same rationale as AI_TOOLS_ALLOWLIST /
# AI_TOOLS_OPERATOR_CONF): sudo strips it and the callers run with their own environment, so neither
# the operator nor the agent can redirect the re-own in production; only a root caller that sets the
# env and sources the lib directly (the test suite) can point it at a /tmp fixture tree.
readonly CP_HOME="${AI_TOOLS_CONTROL_PLANE_HOME:-/opt/ai-tools}"

# Boundary modes (the paths are operator-owned in every case):
#   CP_HOME_MODE   2750 home root: the agent (group) traverses+reads, setgid keeps files born
#                       here in the sandbox group
#   CP_DIR_MODES        per sub-directory:
#                     0550 bin     locked -- the agent cannot swap the launcher symlink or updater
#                     3770 .claude setgid+sticky -- the agent is a group-writer for its own session
#                                  state but cannot unlink the control files it does not own
#   CP_STATE_MODE  0460 group-writable state files: the agent persists its own state while the
#                       owner's copy cannot be silently rewritten
readonly CP_HOME_MODE=2750
readonly -A CP_DIR_MODES=( [bin]=0550 [.claude]=3770 )
readonly CP_STATE_MODE=0460

# Control files: chowned to the operator only (content modes are set when the file is deployed).
readonly CP_FILES=(
    bin/claude-run
    bin/nvm-update.sh
    .claude/settings.json
    .claude/post-tool-hook.sh
    .claude/session-hook.sh
    .gitconfig
    .gitignore
)
# Launcher symlinks: chowned with -h (the link, not its target in the agent's nvm tree).
readonly CP_SYMLINKS=( bin/claude )
# Group-writable state files (mode CP_STATE_MODE).
readonly CP_STATE_FILES=( .claude.json )

# reown_control_plane: re-own the control plane to PROJECTS_USER:SANDBOX_GROUP -- the operator owns
# it, the agent reaches it through the sandbox group -- and reassert the boundary modes. It reads
# the identity from the globals PROJECTS_USER and SANDBOX_GROUP, which the caller sets (enroll from
# the enrolled operator, install.sh from its resolved identity), matching how the other root
# helpers consume operator.lib.sh. Used to recover from the package's neutral root:ai-tools
# placeholder after an RPM unpack and to lock a fresh tree to the operator. Each path is -e guarded
# so it runs cleanly whether or not the tree is fully populated, and modes are reasserted so a
# re-run is authoritative. It does not log -- the caller announces the action.
reown_control_plane() {
    [[ -d "${CP_HOME}" ]] || return 0
    local _rel _p
    chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${CP_HOME}"; chmod "${CP_HOME_MODE}" "${CP_HOME}"
    for _rel in "${!CP_DIR_MODES[@]}"; do
        _p="${CP_HOME}/${_rel}"
        [[ -d "${_p}" ]] || continue
        chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${_p}"; chmod "${CP_DIR_MODES[${_rel}]}" "${_p}"
    done
    for _rel in "${CP_FILES[@]}"; do
        [[ -e "${CP_HOME}/${_rel}" ]] && chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${CP_HOME}/${_rel}"
    done
    for _rel in "${CP_SYMLINKS[@]}"; do
        [[ -L "${CP_HOME}/${_rel}" ]] && chown -h "${PROJECTS_USER}:${SANDBOX_GROUP}" "${CP_HOME}/${_rel}"
    done
    for _rel in "${CP_STATE_FILES[@]}"; do
        [[ -e "${CP_HOME}/${_rel}" ]] || continue
        chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${CP_HOME}/${_rel}"; chmod "${CP_STATE_MODE}" "${CP_HOME}/${_rel}"
    done
}

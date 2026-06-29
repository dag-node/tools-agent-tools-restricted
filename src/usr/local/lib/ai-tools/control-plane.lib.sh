#!/usr/bin/env bash
# shellcheck disable=SC2034  # boundary-mode constants, read by install.sh and the perms test
# /usr/local/lib/ai-tools/control-plane.lib.sh
# Canonical boundary-mode constants for the /opt/ai-tools control plane. The control plane is
# owned root:ai-tools permanently -- the RPM ships it that way and nothing re-owns it to a person
# -- so the agent (group ai-tools) reaches its state while root owns the locked control files.
# This file is *sourced* (never executed) so the installer and the test suite assert the same
# boundary modes the spec %files declares, from one source.
#
# It carries constants only: the canonical home, its mode, the per-subdirectory modes, and the
# group-writable state-file mode. The agent's own subtrees (.nvm/.cache/.local/.npm) stay
# agent-owned and .git is root-private 0700, so they are not described here.

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
#   CP_DIR_MODES        per sub-directory:
#                     0551 bin     locked -- the agent cannot swap the launcher symlink or updater;
#                                  o+x so an operator readlinks bin/claude
#                     3770 .claude setgid+sticky -- the agent is a group-writer for its own session
#                                  state but cannot unlink the control files it does not own
#   CP_STATE_MODE  0460 group-writable state files: the agent persists its own state while the
#                       root-owned copy cannot be silently rewritten
readonly CP_HOME_MODE=2751
readonly -A CP_DIR_MODES=( [bin]=0551 [.claude]=3770 )
readonly CP_STATE_MODE=0460

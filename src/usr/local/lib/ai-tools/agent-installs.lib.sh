#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/agent-installs.lib.sh
# Which agents this host carries outside the sandbox: an executable of a launcher's name in a system directory,
# and the package that owns it. Such a binary runs unconfined, so `install.sh` and the ai-tools-base %post report it
# once the wrapper is installed beside it.
#
# It reads the filesystem alone: where an account's shell resolves a launcher is path-order.lib.sh's reading,
# and ordering a PATH is path-order.sh's.
#
# Sourced, not executed. Deployed 644 root:root -- it reads directory entries every account can already list.
#
# Deploy:
#   ```bash
#   install -o root -g root -m 644 \
#       src/usr/local/lib/ai-tools/agent-installs.lib.sh /usr/local/lib/ai-tools/agent-installs.lib.sh
#   ```

[[ -n "${_AI_TOOLS_AGENT_INSTALLS_LIB_LOADED:-}" ]] && return 0
# shellcheck disable=SC2034  # include guard, read on the next source of this lib
_AI_TOOLS_AGENT_INSTALLS_LIB_LOADED=1

# The directories searched, in the order a report names them. /usr/local/bin is absent: it is the wrappers' own. /bin
# leads because the agent's other distribution channel -- its own package rather than the npm one this stack installs --
# puts it there.
readonly AI_TOOLS_AGENT_INSTALL_DIRS=(/bin /usr/bin /usr/sbin /sbin /usr/local/sbin /opt/bin)
# The wrappers' directory. A candidate that is the same file as the wrapper of its name is not reported:
# where /usr/local/sbin is a symlink to /usr/local/bin (Fedora's merged layout), /usr/local/sbin/<launcher> is
# the wrapper.
readonly AI_TOOLS_AGENT_INSTALL_WRAPPER_DIR=/usr/local/bin

# ai_tools_agent_installs <launcher> [<dir>...] Print "<path>\t<other spellings of the same file>" per distinct
# executable of that name in <dir>... (default: AI_TOOLS_AGENT_INSTALL_DIRS), leaving out the wrapper itself. `-ef` is
# what makes a usr-merged host's /bin/claude and /usr/bin/claude one install rather than two.
#
# The launcher name becomes a path, so it is admitted only in a launcher's own charset; a name outside it does not
# produce any line.
ai_tools_agent_installs() {
    local launcher="${1:-}"; shift || true
    [[ "${launcher}" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
    local -a dirs=("$@")
    (( ${#dirs[@]} )) || dirs=("${AI_TOOLS_AGENT_INSTALL_DIRS[@]}")

    local dir candidate idx seen
    local -a paths=() aliases=()
    for dir in "${dirs[@]}"; do
        candidate="${dir}/${launcher}"
        [[ -x "${candidate}" && ! -d "${candidate}" ]] || continue
        [[ "${candidate}" -ef "${AI_TOOLS_AGENT_INSTALL_WRAPPER_DIR}/${launcher}" ]] && continue
        seen=""
        for idx in "${!paths[@]}"; do
            [[ "${candidate}" -ef "${paths[idx]}" ]] || continue
            aliases[idx]="${aliases[idx]:+${aliases[idx]}, }${candidate}"
            seen=1; break
        done
        [[ -n "${seen}" ]] && continue
        paths+=( "${candidate}" ); aliases+=( "" )
    done
    for idx in "${!paths[@]}"; do
        printf '%s\t%s\n' "${paths[idx]}" "${aliases[idx]}"
    done
}

# ai_tools_agent_install_owner <path> Print the name of the package owning <path>; prints nothing where rpm does not own
# that file, or is not installed. The value is rendered into a `dnf remove` command a person is invited to run, so it is
# admitted only in a package name's charset.
ai_tools_agent_install_owner() {
    local path="${1:-}" package
    [[ -n "${path}" ]] || return 0
    command -v rpm >/dev/null 2>&1 || return 0
    package="$(rpm -qf --queryformat '%{NAME}' "${path}" 2>/dev/null)" || return 0
    [[ "${package}" =~ ^[A-Za-z0-9._+-]+$ ]] || return 0
    printf '%s\n' "${package}"
}

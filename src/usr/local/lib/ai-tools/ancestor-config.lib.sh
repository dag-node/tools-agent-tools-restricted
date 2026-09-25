#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/ancestor-config.lib.sh
# Reports the configuration files in a project's ancestor directories that a confined session is denied. A build
# toolchain collects configuration by walking from the project directory toward /, opening every file of a name it
# recognises, and a file it opens outside the project is denied -- a hard error naming that path, whose message does not
# mention the sandbox boundary. .NET is the measured case (.claude/rules/dotnet.rule.md lists the five files
# and the error each produces); the reader here does not name any toolchain, taking both the marker set that decides
# whether a project belongs to one and the file names to look for from the installed integration manifests
# (project_markers, ancestor_config_files -- ai-tools-providers(5)).
#
# It REPORTS and does not change any file: the claim CLI prints the paths in its Review block and the launch wrapper
# prints them with its pre-launch notices, so the failure is named before a build meets it. Reading an ancestor config
# into the session is a grant, which no path here makes.
#
# The walk is bounded by the protected-paths backstop, not by a toolchain's own stop marker: Roslyn applies
# .editorconfig's `root = true` when it PARSES the file, so a file has to be opened before it can say the search should
# have stopped, and a walk honouring the marker would miss the file whose read already failed. The backstop's one
# carve-out here is the user home root: the walk scans it and stops at the `/home` entry that contains it. A toolchain
# walks through a home like any other directory, and reading a directory is not the tree-rewriting operation
# the backstop refuses a target for.
#
# Deployed 644 root:root, world-readable like msg/log/safe-paths: it carries a general reader and no secrets. Sourced
# (never executed) by the CLI and by the launch-wrapper gate library, each of which has already loaded safe-paths.lib.sh
# -- the bound is probed rather than sourced here, so this library does not pull in the message renderer that one
# requires. Without it the reader prints nothing, which costs the report and leaves the walk inside the window
# the backstop defines.

[[ -n "${_AI_TOOLS_ANCESTOR_CONFIG_LIB_LOADED:-}" ]] && return 0
readonly _AI_TOOLS_ANCESTOR_CONFIG_LIB_LOADED=1

# The account a confined session runs as, which is whose read ai_tools_session_can_read is about.
readonly AI_TOOLS_SESSION_ACCOUNT="@SANDBOX_USER@"
readonly AI_TOOLS_SESSION_GROUP="@SANDBOX_GROUP@"

# The types the confined domain reads inside the walk's window. A claim applies the first to a project tree
# and relabel.lib.sh applies the second to its build output, and every other type a candidate can carry there belongs
# to a home or to a host data directory, which the base policy grants ai_tools_t no read on -- the measured denial
# the detector exists for is exactly that (a group-readable .editorconfig on user_home_t).
readonly AI_TOOLS_SESSION_READABLE_TYPES=(ai_tools_project_t ai_tools_project_build_t)

# The manifest field reader, which resolves both keys from every INSTALLED integration -- installed rather than enabled,
# since an ancestor config breaks a build wherever the toolchain is on the host and whichever integrations a later
# session receives. Best-effort, the same posture relabel.lib.sh takes: without it no key resolves and the reader prints
# nothing.
# shellcheck source=SCRIPTDIR/providers.lib.sh
source "${BASH_SOURCE[0]%/*}/providers.lib.sh" 2>/dev/null || true

# _ai_tools_declared_items <key> <charset-regex>: print each item every installed integration
#   declares under <key>, one per line, deduplicated and sorted in the C locale so a report reads the
#   same on every host. An item is accepted only as one plain component that matches <charset-regex>
#   and does not carry `..`: a name is joined to an ancestor path and a marker is expanded as a glob there,
#   so a `/` or a traversal would let a manifest name a file outside the directory being scanned.
_ai_tools_declared_items() {
    local key="$1" charset="$2" declared item
    declare -F ai_tools_installed_integrations_declaring >/dev/null 2>&1 || return 0
    declare -F ai_tools_conf_list_value >/dev/null 2>&1 || return 0
    local -a items
    while IFS=$'\t' read -r _ declared; do
        [[ -n "${declared}" ]] || continue
        items=()
        ai_tools_conf_list_value items "${declared}" 0 "${key} in an integration manifest"
        for item in "${items[@]}"; do
            [[ "${item}" =~ ${charset} && "${item}" != *..* ]] || continue
            printf '%s\n' "${item}"
        done
    done < <(ai_tools_installed_integrations_declaring "${key}" 2>/dev/null) | LC_ALL=C sort -u
}

# ai_tools_ancestor_config_names: print the configuration file names the installed integrations
#   declare (ancestor_config_files), one per line. Empty where none declares any, which is the state
#   of a host with no integration installed and the reason such a host reports nothing.
ai_tools_ancestor_config_names() {
    _ai_tools_declared_items ancestor_config_files '^[A-Za-z0-9._-]+$'
}

# ai_tools_project_markers: print the filename globs that mark a project as some installed
#   integration's (project_markers), one per line. `*` and `?` are in the charset because a marker
#   matches by extension (`*.csproj`); every other glob construct is refused, so a marker names files
#   in one directory and cannot reach past it.
ai_tools_project_markers() {
    _ai_tools_declared_items project_markers '^[A-Za-z0-9._?*-]+$'
}

# ai_tools_project_has_marker <dir>: 0 when <dir> holds a file matching a declared marker. This is
#   what keeps the report off a project no installed toolchain claims: a Python or Node tree does not
#   raise a notice, since no installed manifest declares a marker it matches.
ai_tools_project_has_marker() {
    local dir="${1:-}" marker nullglob_state
    [[ -n "${dir}" && -d "${dir}" ]] || return 1
    local -a markers=() entries=()
    mapfile -t markers < <(ai_tools_project_markers)
    (( ${#markers[@]} )) || return 1
    # `shopt -p` exits non-zero when the option is off, which would abort a caller running under `set -e`
    # before the restore is ever recorded.
    nullglob_state="$(shopt -p nullglob 2>/dev/null)" || nullglob_state="shopt -u nullglob"
    shopt -s nullglob
    for marker in "${markers[@]}"; do
        # The glob is deliberately unquoted -- it is the pattern, and it comes from a root-owned manifest validated
        # to one plain component, while the directory it expands in is the quoted operand. This is the same operand
        # arrangement the secret-name and protected-path matchers use (.claude/rules/shellcheck.rule.md), in the form
        # an array assignment takes.
        # shellcheck disable=SC2206  # the right-hand side is the pattern; quoting it defeats the match
        entries=( "${dir}"/${marker} )
        if (( ${#entries[@]} )); then
            eval "${nullglob_state}"
            return 0
        fi
    done
    eval "${nullglob_state}"
    return 1
}

# ai_tools_ancestor_scan_allowed <dir>: 0 while the ancestor walk may look inside <dir> -- it does not
#   match any protected path, or matches only as a user home root. Every system directory and /home
#   itself stop the walk, so the report does not name a file under /etc or /usr. Fail-closed on
#   a backstop the caller has not loaded: an unbounded walk would read directories outside the window
#   the backstop defines.
ai_tools_ancestor_scan_allowed() {
    local path="${1:-}" matched
    [[ -n "${path}" ]] || return 1
    declare -F ai_tools_protected_path_match >/dev/null 2>&1 || return 1
    matched="$(ai_tools_protected_path_match "${path}")" || return 0
    [[ "${matched}" == *"(user home root)" ]]
}

# _ai_tools_session_type_readable <path>: 0 when SELinux is not enforcing, where the label does not
#   decide a read, or when <path> carries one of the types the confined domain reads. A context that cannot be read
#   on an enforcing host returns 1, so the path is reported rather than assumed readable.
_ai_tools_session_type_readable() {
    local path="$1" type context
    command -v getenforce >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] || return 0
    context="$(ls -Zd -- "${path}" 2>/dev/null)" || return 1
    for type in "${AI_TOOLS_SESSION_READABLE_TYPES[@]}"; do
        [[ "${context}" == *":${type}:"* ]] && return 0
    done
    return 1
}

# ai_tools_session_can_read <path>: 0 when a confined session can read the regular file <path>. Both
#   layers have to allow it and each is asked separately, because the case this detector was built
#   for passes one and fails the other: an ancestor .editorconfig at 670 <operator>:@SANDBOX_GROUP@
#   is group-readable and still denied, the file being user_home_t. A check computed from mode and
#   group alone therefore answers "readable" exactly where the report is needed.
ai_tools_session_can_read() {
    local path="${1:-}" mode group
    [[ -n "${path}" && -f "${path}" ]] || return 1
    mode="$(stat -c '%a' "${path}" 2>/dev/null)" || return 1
    [[ "${mode}" =~ ^[0-7]+$ ]] || return 1
    if ! (( 8#${mode} & 0004 )); then
        group="$(stat -c '%G' "${path}" 2>/dev/null || true)"
        if [[ "${group}" != "${AI_TOOLS_SESSION_GROUP}" ]] || ! (( 8#${mode} & 0040 )); then
            # An ACL entry is the remaining route to a read. A mask that clears the read bit leaves the entry without
            # it, and getfacl reports that as an `#effective:` comment on the entry's own line, so a line
            # whose effective permissions have lost the read bit does not count.
            command -v getfacl >/dev/null 2>&1 || return 1
            getfacl -p -- "${path}" 2>/dev/null \
                | grep -E "^user:${AI_TOOLS_SESSION_ACCOUNT}:r" \
                | grep -qv '#effective:[^r]' || return 1
        fi
    fi
    _ai_tools_session_type_readable "${path}"
}

# ai_tools_unreadable_ancestor_configs <dir>: print every declared configuration file in <dir>'s
#   ancestry that ai_tools_session_can_read refuses, one absolute path per line, nearest first.
#   Prints nothing -- and always returns 0 -- for a project no installed integration's markers claim,
#   for a host whose manifests declare none, and where the backstop that bounds the walk is not
#   loaded, so a caller reads the output rather than a status.
#
#   The project directory itself is not scanned: a claim grants the session access to the tree, so a
#   configuration file inside it is readable by the same steps that make the sources readable.
#
#   An ancestor that is itself a claimed project does not need a case of its own, and the walk does not stop
#   at one. Its files carry the group, the ACL and the project label that claim applied, so
#   ai_tools_session_can_read passes them and they are not reported -- while a file further up, which
#   a toolchain reaches by walking past that project, still is. Reading allowed-projects here would
#   answer a different question and get both wrong: an entry gates where a session LAUNCHES, not what
#   it may read, so a PARKED claimed ancestor -- a registry edit that leaves group and label in place
#   -- would be reported over files the session reads.
ai_tools_unreadable_ancestor_configs() {
    local dir="${1:-}" ancestor name candidate
    [[ -n "${dir}" && -d "${dir}" ]] || return 0
    ai_tools_project_has_marker "${dir}" || return 0
    local -a names=()
    mapfile -t names < <(ai_tools_ancestor_config_names)
    (( ${#names[@]} )) || return 0
    ancestor="$(dirname -- "${dir}")"
    while [[ "${ancestor}" != / && "${ancestor}" != . ]]; do
        ai_tools_ancestor_scan_allowed "${ancestor}" || break
        for name in "${names[@]}"; do
            candidate="${ancestor}/${name}"
            [[ -f "${candidate}" ]] || continue
            if ! ai_tools_session_can_read "${candidate}"; then
                printf '%s\n' "${candidate}"
            fi
        done
        ancestor="$(dirname -- "${ancestor}")"
    done
    return 0
}

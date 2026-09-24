#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/toolchain.lib.sh
# What the sandbox toolchain holds for each agent, and the one write that removes a package. The invariant this library
# serves: the toolchain under /opt/ai-tools/.nvm holds exactly the enabled agents' npm packages, each of them whole. It
# is read in both directions.
#
# A package of an agent whose manifest is installed but whose name is not in AI_TOOLS_AGENTS is RESIDUE: its entrypoint
# stays executable at its real path from inside any session, so every path that writes the toolchain
# (ai-tools-bootstrap, nvm-update, the agent package's %preun and `install.sh uninstall`) removes it
# through ai_tools_agent_package_remove, and both launch tiers (the wrapper's gate and ai-tools-run's) refuse every
# agent's launch while any is present. The readers, the writer's outcomes, and where each caller sits are
# in updater.rule.md; the launch refusal is in launch.rule.md.
#
# An ENABLED agent's package that does not hold the entrypoint its manifest declares is INCOMPLETE
# (ai_tools_agent_incomplete): the package directory is installed and the executable is not, so no launch of that agent
# starts. The reader answers on that absence alone. How a package reaches that state, what each provisioner does
# about it, and why the absence is the condition rather than any cause are in updater.rule.md.
#
# Two residue readers, one per principal, since the tree is 0750 and only the sandbox account traverses it:
# the operator's wrapper and `ai-tools status` read the stable launcher link as the proxy for a provisioned package
# (ai_tools_agent_residue_links), and the shim, the provisioners and the updater read the tree itself
# (ai_tools_agent_residue). Agent identity enters every function as a manifest record read through providers.lib.sh,
# never as a name this file knows, so a third agent package is covered without an edit here.
#
# Sourced, not executed. Deployed 644 root:root: it reads manifests every account can already read, and the account
# that runs the writer owns the tree the writer edits. providers.lib.sh is REQUIRED -- without the enabled and installed
# sets there is no residue to compute, and guessing either direction would either remove an enabled agent's package
# or pass residue as clean -- so a load that fails does not define a reader and returns non-zero, the shape
# providers.lib.sh itself takes over conf.lib.sh, and every consumer probes for a reader before trusting the source.

# Include guard, as an if-statement: `[[ ]] && return` returns 1 for an unset guard and trips a sourcing shell's
# `set -e`.
if [[ -n "${_AI_TOOLS_TOOLCHAIN_LIB_LOADED:-}" ]]; then
    return 0
fi

# _ai_tools_toolchain_warn [code] <message...> / _ai_tools_toolchain_notice [code] <message...> : report to stderr
#   (the terminal, or the journal a unit routes it to) and, when log.lib.sh loaded, to journald. A leading message
#   code (msg.lib.sh states the form) goes on its own line ahead of the message, the shape tests/lib/harness.sh's
#   assert_msg reads. Both on stderr: this library's stdout is a wire format its callers read with `$(...)`.
_ai_tools_toolchain_warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools: %s\n' "$*" >&2
    declare -F ai_tools_log_warn >/dev/null 2>&1 && ai_tools_log_warn "toolchain: $*"
    return 0
}
_ai_tools_toolchain_notice() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools: notice: %s\n' "$*" >&2
    declare -F ai_tools_log_info >/dev/null 2>&1 && ai_tools_log_info "toolchain: $*"
    return 0
}

# The provider resolver: the installed and enabled sets, and each manifest's fields. REQUIRED, and probed rather than
# assumed, since providers.lib.sh returns non-zero without defining a resolver when conf.lib.sh is missing.
# shellcheck source=SCRIPTDIR/providers.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/providers.lib.sh" 2>/dev/null \
        || ! declare -F ai_tools_installed_agents >/dev/null 2>&1 \
        || ! declare -F ai_tools_enabled_agents >/dev/null 2>&1 \
        || ! declare -F ai_tools_agents_empty_verdict >/dev/null 2>&1 \
        || ! declare -F ai_tools_launcher_target_valid >/dev/null 2>&1 \
        || ! declare -F ai_tools_agent_manifest_field >/dev/null 2>&1; then
    _ai_tools_toolchain_warn "toolchain.lib.sh: providers.lib.sh missing or incomplete -- no toolchain reader defined"
    return 1
fi

_AI_TOOLS_TOOLCHAIN_LIB_LOADED=1

# The shape an npm package name takes: an optional scope, then a name, each drawn from npm's own charset. The name
# becomes a path component under the version directory, so anything else -- a separator run, a traversal -- is refused
# before it is joined.
readonly _AI_TOOLS_NPM_PACKAGE_RE='^(@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+$'

# ai_tools_installed_not_enabled_agents : print "name<TAB>npm_package<TAB>launcher" per agent whose
#   trusted manifest is installed and whose name the enabled set does not carry, in manifest-filename
#   order. The set both residue readers iterate. An untrusted manifest is not an installed agent
#   (providers.lib.sh skips and reports it), so it is not residue either: what it would provision
#   is unknown, and the launch refuses its launcher on its own. An empty enabled set that
#   ai_tools_agents_empty_verdict does not classify as `none` -- an invalid AI_TOOLS_AGENTS, an
#   untrusted operator.conf, a list none of whose names resolved -- does not print a line: the set
#   the operator declared is unknown rather than empty, and reading it as empty would make every
#   installed agent's package residue for the writer to remove. Data-only stdout.
ai_tools_installed_not_enabled_agents() {
    local name npm_package launcher enabled=" " verdict=""
    while IFS=$'\t' read -r name _ _; do
        [[ -n "${name}" ]] && enabled+="${name} "
    done < <(ai_tools_enabled_agents 2>/dev/null)
    if [[ "${enabled}" == " " ]]; then
        IFS=$'\t' read -r verdict _ < <(ai_tools_agents_empty_verdict 2>/dev/null) || true
        [[ "${verdict}" == none ]] || return 0
    fi
    while IFS=$'\t' read -r name npm_package launcher; do
        [[ -n "${name}" ]] || continue
        [[ "${enabled}" == *" ${name} "* ]] && continue
        printf '%s\t%s\t%s\n' "${name}" "${npm_package}" "${launcher}"
    done < <(ai_tools_installed_agents)
    return 0
}

# ai_tools_agent_residue <nvm-dir> : print "name<TAB>npm_package<TAB>version-dir" for every installed,
#   not enabled agent whose package directory exists under a semver version directory of <nvm-dir>
#   (<version-dir>/lib/node_modules/<npm_package>), one line per version directory. Read-only;
#   the definitive read, which needs an account that traverses the tree. A package name outside
#   npm's charset is skipped and reported, since it cannot be joined to a path.
ai_tools_agent_residue() {
    local nvm_dir="${1:-}" name npm_package version_dir
    [[ -n "${nvm_dir}" && -d "${nvm_dir}/versions/node" ]] || return 0
    while IFS=$'\t' read -r name npm_package _; do
        [[ -n "${name}" ]] || continue
        if ! [[ "${npm_package}" =~ ${_AI_TOOLS_NPM_PACKAGE_RE} ]]; then
            _ai_tools_toolchain_warn "skipping ${name}: its npm_package $(printf '%q' "${npm_package}") is not an npm package name"
            continue
        fi
        for version_dir in "${nvm_dir}/versions/node"/v*; do
            [[ "${version_dir##*/}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            [[ -e "${version_dir}/lib/node_modules/${npm_package}" || -L "${version_dir}/lib/node_modules/${npm_package}" ]] \
                || continue
            printf '%s\t%s\t%s\n' "${name}" "${npm_package}" "${version_dir}"
        done
    done < <(ai_tools_installed_not_enabled_agents)
    return 0
}

# ai_tools_agent_residue_links <launcher-dir> : print "name<TAB>launcher" for every installed, not
#   enabled agent whose stable launcher symlink exists in <launcher-dir>. The operator-side twin
#   of ai_tools_agent_residue: the link is written last by every provisioning of a package and
#   removed with it, so its presence is what an account that cannot traverse the toolchain reads
#   as "the package is still there". `-L`, not `-e`: `-e` follows the link into the 0750 tree.
ai_tools_agent_residue_links() {
    local launcher_dir="${1:-}" name launcher
    [[ -n "${launcher_dir}" ]] || return 0
    while IFS=$'\t' read -r name _ launcher; do
        [[ -n "${name}" && -n "${launcher}" ]] || continue
        [[ "${launcher}" =~ ^[A-Za-z0-9._-]+$ ]] || continue
        [[ -L "${launcher_dir}/${launcher}" ]] && printf '%s\t%s\n' "${name}" "${launcher}"
    done < <(ai_tools_installed_not_enabled_agents)
    return 0
}

# ai_tools_agent_incomplete <version-dir> : print "name<TAB>npm_package" for every ENABLED agent whose
#   manifest declares a launcher_target that <version-dir> does not hold. Read-only, and the definitive
#   read: the tree is 0750, so it needs the account that traverses it. An agent declaring no
#   launcher_target yields no line -- npm's own link is its launcher, and this library has no declared
#   path to compare the tree against -- and a target ai_tools_launcher_target_valid refuses is skipped
#   and reported, since it cannot be joined to a path.
ai_tools_agent_incomplete() {
    local version_dir="${1:-}" name npm_package launcher_target
    [[ -n "${version_dir}" && -d "${version_dir}" ]] || return 0
    while IFS=$'\t' read -r name npm_package _; do
        [[ -n "${name}" && -n "${npm_package}" ]] || continue
        launcher_target="$(ai_tools_agent_manifest_field "${name}" launcher_target 2>/dev/null || true)"
        [[ -n "${launcher_target}" ]] || continue
        if ! ai_tools_launcher_target_valid "${launcher_target}"; then
            _ai_tools_toolchain_warn "skipping ${name}: its launcher_target $(printf '%q' "${launcher_target}") is not a relative path inside a version directory"
            continue
        fi
        [[ -e "${version_dir}/${launcher_target}" ]] && continue
        printf '%s\t%s\n' "${name}" "${npm_package}"
    done < <(ai_tools_enabled_agents 2>/dev/null)
    return 0
}

# ai_tools_path_in_use <dir> [<executable>...] : pure, no I/O -- succeed when any <executable> is
#   <dir> or lies under it. The predicate behind the deferral: a process executing from a package
#   directory (codex stages symlinks to its own entrypoint and execs them per edit) would fail
#   its next exec if that directory were removed under it.
ai_tools_path_in_use() {
    local dir="${1%/}" executable; shift || true
    [[ -n "${dir}" ]] || return 1
    for executable in "$@"; do
        [[ "${executable}" == "${dir}" || "${executable}" == "${dir}/"* ]] && return 0
    done
    return 1
}

# _ai_tools_toolchain_exe_targets : print what each live process's /proc/<pid>/exe resolves to, one
#   per line, for every process the caller may read. As the sandbox account that is its own
#   processes -- the set that matters, since every session and the subprocesses it spawns run as
#   that account. Best-effort in the keeping direction: an exited or unreadable pid is skipped.
_ai_tools_toolchain_exe_targets() {
    local exe target
    for exe in /proc/[0-9]*/exe; do
        target="$(readlink -- "${exe}" 2>/dev/null)" || continue
        printf '%s\n' "${target}"
    done
    return 0
}

# ai_tools_agent_package_in_use <package-dir> : succeed when a live process executes from under
#   <package-dir>. The I/O around ai_tools_path_in_use.
ai_tools_agent_package_in_use() {
    local -a targets=()
    mapfile -t targets < <(_ai_tools_toolchain_exe_targets)
    ai_tools_path_in_use "$1" "${targets[@]+"${targets[@]}"}"
}

# _ai_tools_toolchain_agent_of_package <npm_package> : print the name of the installed agent whose
#   manifest declares <npm_package>, empty when none does.
_ai_tools_toolchain_agent_of_package() {
    local wanted="$1" name npm_package
    while IFS=$'\t' read -r name npm_package _; do
        [[ "${npm_package}" == "${wanted}" ]] && { printf '%s' "${name}"; return 0; }
    done < <(ai_tools_installed_agents 2>/dev/null)
    return 0
}

# _ai_tools_toolchain_state_notice <agent> : say, once per removal, what a removal leaves. The
#   agent's state directory under the sandbox home -- its login or token, its history, whatever
#   else it keeps there -- is not touched, and under the one sandbox account every session of every
#   enabled agent can read it; moving it out of the account's reach is a manual step.
_ai_tools_toolchain_state_notice() {
    local agent="$1" config_dir
    config_dir="$(ai_tools_agent_manifest_field "${agent}" config_dir 2>/dev/null || true)"
    _ai_tools_toolchain_notice MSG-G4M8 "removed the ${agent} package from the sandbox toolchain, and left its state directory ${config_dir:+/opt/ai-tools/${config_dir} }in place -- a login or token it stored and the history it kept are readable by every session of every enabled agent until you move that directory out of the sandbox account's reach"
}

# ai_tools_agent_package_remove <version-dir> <npm_package> [erase] : the one write -- remove
#   <version-dir>/lib/node_modules/<npm_package> with that version's own npm (`npm uninstall -g`,
#   <version-dir> as the prefix; the registry is not reached) and print one word for the outcome:
#     absent    no such package directory, so no write was made
#     removed   the package directory is gone (the state-directory notice follows on stderr)
#     deferred  a live process executes from the package directory, so it is left for the next
#               run (returns 0: the caller's run is not at fault, and a launch stays refused
#               until it is gone)
#   Prints nothing, reports under its code and returns 1 when the package belongs to an ENABLED
#   agent (MSG-X7Z9: a provisioning run must not remove what it maintains, so the direction is
#   less access only) unless the third argument is `erase`, the form an agent package's own erase
#   takes while its manifest still names the package; when <npm_package> falls outside npm's
#   package-name charset or <version-dir> is not a directory (MSG-J5W4); and when the uninstall
#   leaves the directory in place (MSG-X8F9).
ai_tools_agent_package_remove() {
    local version_dir="${1:-}" npm_package="${2:-}" mode="${3:-}" package_dir agent name
    if [[ -z "${version_dir}" || ! -d "${version_dir}" ]] || ! [[ "${npm_package}" =~ ${_AI_TOOLS_NPM_PACKAGE_RE} ]]; then
        _ai_tools_toolchain_warn MSG-J5W4 "cannot remove $(printf '%q' "${npm_package}") from $(printf '%q' "${version_dir}"): not an npm package name in a version directory -- leaving the toolchain as it is"
        return 1
    fi
    package_dir="${version_dir}/lib/node_modules/${npm_package}"
    agent="$(_ai_tools_toolchain_agent_of_package "${npm_package}")"
    if [[ "${mode}" != erase ]]; then
        while IFS=$'\t' read -r name _ _; do
            if [[ -n "${name}" && "${name}" == "${agent}" ]]; then
                _ai_tools_toolchain_warn MSG-X7Z9 "refusing to remove ${npm_package} from ${version_dir##*/}: ${name} is enabled in AI_TOOLS_AGENTS -- leaving it as it is"
                return 1
            fi
        done < <(ai_tools_enabled_agents 2>/dev/null)
    fi
    if [[ ! -e "${package_dir}" && ! -L "${package_dir}" ]]; then
        printf 'absent'
        return 0
    fi
    if ai_tools_agent_package_in_use "${package_dir}"; then
        _ai_tools_toolchain_warn MSG-X2B7 "deferring the removal of ${npm_package} from ${version_dir##*/}: a live session executes from it -- it is removed on the next provisioning or update run, and no session starts until then"
        printf 'deferred'
        return 0
    fi
    # That version's own npm, with the version directory pinned as the global prefix, so the uninstall edits the tree it
    # was asked about whatever prefix the environment or an .npmrc would otherwise resolve. npm's own chatter goes
    # to stderr, since this function's stdout is the outcome word alone.
    PATH="${version_dir}/bin:${PATH}" npm uninstall -g --prefix "${version_dir}" "${npm_package}" >&2 \
        || true
    if [[ -e "${package_dir}" || -L "${package_dir}" ]]; then
        _ai_tools_toolchain_warn MSG-X8F9 "could not remove ${package_dir} (npm uninstall left it in place) -- every launch stays refused until it is gone; remove it by hand as the sandbox account, then re-run: sudo ai-tools-admin system bootstrap"
        return 1
    fi
    printf 'removed'
    [[ -n "${agent}" ]] && _ai_tools_toolchain_state_notice "${agent}"
    return 0
}

# ai_tools_agent_package_erase <nvm-dir> <agent> : remove <agent>'s package from every version
#   directory of <nvm-dir>, enabled or not -- the erase-time form, for an agent package's %preun
#   and `install.sh uninstall`, run while the manifest that names the package is still on disk.
#   Prints "version-dir<TAB>outcome" per version directory holding the package (the writer's
#   words), and returns non-zero when any removal failed. Prints nothing for an agent whose
#   manifest does not name a package, or whose package no version directory holds.
ai_tools_agent_package_erase() {
    local nvm_dir="${1:-}" agent="${2:-}" npm_package version_dir outcome rc=0
    npm_package="$(ai_tools_agent_manifest_field "${agent}" npm_package 2>/dev/null || true)"
    [[ -n "${npm_package}" && -n "${nvm_dir}" && -d "${nvm_dir}/versions/node" ]] || return 0
    [[ "${npm_package}" =~ ${_AI_TOOLS_NPM_PACKAGE_RE} ]] || return 1
    for version_dir in "${nvm_dir}/versions/node"/v*; do
        [[ "${version_dir##*/}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        [[ -e "${version_dir}/lib/node_modules/${npm_package}" || -L "${version_dir}/lib/node_modules/${npm_package}" ]] \
            || continue
        if outcome="$(ai_tools_agent_package_remove "${version_dir}" "${npm_package}" erase)"; then
            printf '%s\t%s\n' "${version_dir}" "${outcome}"
        else
            printf '%s\tfailed\n' "${version_dir}"
            rc=1
        fi
    done
    return "${rc}"
}

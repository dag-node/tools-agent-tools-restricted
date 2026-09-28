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
# (ai_tools_agent_residue). The same link names the Node version directory it points into, so it is also the operator's
# read of which Node the toolchain is on (ai_tools_agent_link_node_versions), and the pure verdict both status reports
# render their Node line from sits beside it. Agent identity enters every function as a manifest record read
# through providers.lib.sh, never as a name this file knows, so a third agent package is covered without an edit
# here.
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
# The logger, best-effort from this library's directory: journald for _ai_tools_toolchain_warn
# and _ai_tools_toolchain_notice, and the sanitizer npm's output passes before it reaches a terminal or the journal.
# Without it npm's text is left out of a report.
# shellcheck source=SCRIPTDIR/log.lib.sh
source "${BASH_SOURCE[0]%/*}/log.lib.sh" 2>/dev/null || true

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

# The two functions ahead of the provider requirement read no manifest, so they are defined whatever it decides:
# a bootstrap that provisions Node alone, with no resolver loaded, still runs every toolchain step through
# ai_tools_as_sandbox.
# ai_tools_nvm_default_version <nvm-dir> : print the version directory name (`v22.23.3`) nvm's `default` alias selects
#   among the installed versions, or an empty string. Read as data -- the alias file, then the version directories --
#   so a root caller learns the version without sourcing nvm.sh, which is the sandbox account's to rewrite
#   (updater.rule.md). The alias holds what nvm wrote: an exact `vX.Y.Z`, or a prefix of one (`22`, `v22.23`), which
#   selects the highest installed match, as `nvm version default` does. Any other value -- `node`, `lts/*`, a line
#   the account put there -- is outside the admitted shape and prints nothing, which the callers report as an unset
#   alias.
ai_tools_nvm_default_version() {
    local nvm_dir="${1:-}" alias_value prefix candidate best=""
    [[ -n "${nvm_dir}" && -f "${nvm_dir}/alias/default" && ! -L "${nvm_dir}/alias/default" ]] || return 0
    alias_value="$(head -c 64 -- "${nvm_dir}/alias/default" 2>/dev/null | head -n1 || true)"
    alias_value="${alias_value//[[:space:]]/}"
    [[ "${alias_value}" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ ]] || return 0
    prefix="v${alias_value#v}"
    for candidate in "${nvm_dir}"/versions/node/v*; do
        candidate="${candidate##*/}"
        [[ "${candidate}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        [[ "${candidate}" == "${prefix}" || "${candidate}" == "${prefix}".* ]] || continue
        best="$(printf '%s\n%s\n' "${best}" "${candidate}" | sed '/^$/d' | sort -V | tail -n1)"
    done
    printf '%s' "${best}"
}

# ai_tools_as_sandbox <account> <command> [arg...] : run <command> as the sandbox account <account> for a root caller,
#   the one route by which a root process runs a file that account can write (the invariant in CLAUDE.md, its mechanism
#   in updater.rule.md). The child gets:
#     - no controlling terminal (setsid): a process sharing root's terminal can open /dev/tty and inject input into it
#       with TIOCSTI where the kernel permits, whatever its own descriptors point at;
#     - no terminal on stdin: a terminal is replaced with /dev/null, while a heredoc or a pipe the caller gives passes;
#     - a clean environment (`env -i`): HOME, a PATH of /usr/bin:/bin and LANG=C.UTF-8, and whatever the command itself
#       sets with a leading `env NAME=value`;
#     - its stdout and its stderr kept apart, since a caller may read stdout as a wire format, each through
#       ai_tools_log_sanitize_stream, or withheld with a line on stderr where log.lib.sh did not load.
#   Returns the command's own status; returns 1 without running anything when the caller is not root (runuser needs
#   root) or <account> is not a plain account name.
ai_tools_as_sandbox() {
    local account="${1:-}"
    shift || true
    if [[ "${EUID:-$(id -u)}" -ne 0 || ! "${account}" =~ ^[a-z_][a-z0-9_-]*$ || $# -eq 0 ]]; then
        _ai_tools_toolchain_warn "ai_tools_as_sandbox: needs root, a plain account name and a command -- not run"
        return 1
    fi
    local home
    home="$(getent passwd "${account}" 2>/dev/null | cut -d: -f6)"
    [[ -n "${home}" ]] || home=/
    local stdin_source=/dev/stdin
    [[ -t 0 ]] && stdin_source=/dev/null
    local rc=0
    if declare -F ai_tools_log_sanitize_stream >/dev/null 2>&1; then
        # Both streams through process substitutions rather than a pipeline, so the status is the command's own whatever
        # the caller's pipefail; a caller reading stdout with $(...) waits for its sanitizer, which holds the pipe open
        # until it has written the last line.
        setsid --wait runuser -u "${account}" -- env -i HOME="${home}" PATH=/usr/bin:/bin LANG=C.UTF-8 "$@" \
            <"${stdin_source}" > >(ai_tools_log_sanitize_stream) 2> >(ai_tools_log_sanitize_stream >&2) || rc=$?
    else
        setsid --wait runuser -u "${account}" -- env -i HOME="${home}" PATH=/usr/bin:/bin LANG=C.UTF-8 "$@" \
            <"${stdin_source}" >/dev/null 2>&1 || rc=$?
        _ai_tools_toolchain_warn "output of $(printf '%q' "$1") withheld: log.lib.sh, which sanitizes it, did not load"
    fi
    # The sanitizers run as process substitutions; wait for them, so their lines land before the caller's next one.
    wait 2>/dev/null || true
    return "${rc}"
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

# ai_tools_agent_link_node_versions <launcher-dir> : print "name<TAB>launcher<TAB>version" for every ENABLED
#   agent whose stable launcher symlink in <launcher-dir> names a Node version directory: the target,
#   read back with readlink(1) and not followed, matched against
#   .../versions/node/v<MAJOR>.<MINOR>.<PATCH>/bin/<launcher>, the shape ai-tools-launcher-symlink
#   writes and ai-tools-run accepts. This is the operator's read of which Node the toolchain is on:
#   every path that changes Node repoints the link (the bootstrap as root, the updater through
#   the handback bridge), so the read is current whichever of them wrote it, and it is
#   unprivileged -- the same one-hop read the launch wrapper makes, with the 0750 tree never entered.
#   A missing link and a target of another shape each yield no line. Data-only stdout.
ai_tools_agent_link_node_versions() {
    local launcher_dir="${1:-}" name launcher target
    [[ -n "${launcher_dir}" ]] || return 0
    while IFS=$'\t' read -r name _ launcher; do
        [[ -n "${name}" && -n "${launcher}" ]] || continue
        [[ "${launcher}" =~ ^[A-Za-z0-9._-]+$ ]] || continue
        [[ -L "${launcher_dir}/${launcher}" ]] || continue
        target="$(readlink -- "${launcher_dir}/${launcher}" 2>/dev/null)" || continue
        [[ "${target}" =~ ^/.*/versions/node/(v[0-9]+\.[0-9]+\.[0-9]+)/bin/"${launcher}"$ ]] || continue
        printf '%s\t%s\t%s\n' "${name}" "${launcher}" "${BASH_REMATCH[1]}"
    done < <(ai_tools_enabled_agents 2>/dev/null)
    return 0
}

# ai_tools_node_version_verdict <stamp-node> : read ai_tools_agent_link_node_versions lines on stdin and
#   print the one line both status reports render their Node line from. The active version comes
#   from the links; <stamp-node> is what the updater's last-run stamp recorded (already clamped
#   by ai_tools_service_stamp_field, `unknown` read as none), shown only where it differs, since that
#   is the one fact a link cannot carry: the toolchain changed after the updater last ran.
#     active<TAB><version>              every link names this version, and the stamp agrees or is absent
#     active<TAB><version><TAB><stamp>  every link names this version; the stamp recorded another
#     split<TAB>name=version ...        the links disagree: an update between two repoints, or a provisioning
#                                       that left one agent on an older version
#     stamp<TAB><stamp>                 no link names a version; the stamp does
#     none                              neither
#   Pure -- no I/O, ALWAYS returns 0 -- so tests/unit/toolchain.sh drives the table.
ai_tools_node_version_verdict() {
    local stamp_node="${1:-}" name version active="" pairs="" split=0
    [[ "${stamp_node}" == unknown ]] && stamp_node=""
    while IFS=$'\t' read -r name _ version; do
        [[ -n "${name}" && -n "${version}" ]] || continue
        pairs+="${pairs:+ }${name}=${version}"
        if [[ -z "${active}" ]]; then active="${version}"
        elif [[ "${version}" != "${active}" ]]; then split=1; fi
    done
    if (( split )); then
        printf 'split\t%s\n' "${pairs}"
    elif [[ -n "${active}" ]]; then
        if [[ -n "${stamp_node}" && "${stamp_node}" != "${active}" ]]; then
            printf 'active\t%s\t%s\n' "${active}" "${stamp_node}"
        else
            printf 'active\t%s\n' "${active}"
        fi
    elif [[ -n "${stamp_node}" ]]; then
        printf 'stamp\t%s\n' "${stamp_node}"
    else
        printf 'none\n'
    fi
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

# ai_tools_toolchain_bin_copies <version-dir> : print, one per line, the name of each entry in <version-dir>/bin that is
#   a regular file other than `node`. npm's global layout keeps a symlink into lib/node_modules there for every command
#   a package installs, so a regular file in its place is a copy a transfer of the tree left where the link was -- the
#   state that stops npm (its entry script requires relative to its own directory) and leaves an agent's launcher on
#   an unlabelled file. A stat per entry, so a root caller reads it as data. A name outside the launcher charset is
#   not printed, since the directory is the sandbox account's; it is counted on stderr instead.
ai_tools_toolchain_bin_copies() {
    local version_dir="${1:-}" entry name unnamed=0
    [[ -d "${version_dir}/bin" ]] || return 0
    for entry in "${version_dir}/bin"/*; do
        [[ -f "${entry}" && ! -L "${entry}" ]] || continue
        name="${entry##*/}"
        [[ "${name}" == node ]] && continue
        if [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
            printf '%s\n' "${name}"
        else
            unnamed=$(( unnamed + 1 ))
        fi
    done
    (( unnamed == 0 )) || _ai_tools_toolchain_warn "${version_dir}/bin holds ${unnamed} regular file(s) whose name is outside [A-Za-z0-9._-] -- not reported by name"
    return 0
}

# ai_tools_toolchain_relink_copies <version-dir> : restore the symlink npm keeps in <version-dir>/bin for each copy
#   ai_tools_toolchain_bin_copies names, and print `name<TAB>outcome` per copy:
#     relinked  replaced by a relative symlink to its target -- a temporary name, then `mv -T`, the write
#               ai_tools_relink_launcher makes, so the name is never absent
#     differs   the target exists and the copy's bytes differ from it: not the transfer's doing, left as it is
#     unknown   no enabled agent and no global package declares the name, or its target does not stay inside
#               the version directory: left as it is
#     failed    the write did not complete: left as it was
#   The target is the enabled agent's `launcher_target` where its manifest declares one for that launcher, and otherwise
#   the `bin` entry of the global package declaring the name, read from the packages' package.json by that version's
#   own node. Only a byte-identical copy is replaced, so the link lands on the file the copy already held. Refuses root:
#   it runs node from the tree, which only the sandbox account runs (updater.rule.md, "Root runs none of the toolchain").
ai_tools_toolchain_relink_copies() {
    local version_dir="${1:-}"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        _ai_tools_toolchain_warn "ai_tools_toolchain_relink_copies runs node from the toolchain, so it refuses root -- run it through ai_tools_as_sandbox"
        return 1
    fi
    [[ -d "${version_dir}/bin" && -d "${version_dir}/lib/node_modules" ]] || return 0
    local -a copies=()
    mapfile -t copies < <(ai_tools_toolchain_bin_copies "${version_dir}")
    (( ${#copies[@]} )) || return 0

    # name -> target, relative to the version directory. Packages first, so an agent's declared target overrides
    # the shim npm links.
    local -A target_of=()
    local name rel agent launcher declared
    if [[ -x "${version_dir}/bin/node" ]]; then
        while IFS=$'\t' read -r name rel; do
            [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] && ai_tools_launcher_target_valid "${rel}" 2>/dev/null \
                && target_of["${name}"]="${rel}"
        done < <("${version_dir}/bin/node" -e '
            const fs = require("fs"), path = require("path");
            const root = path.join(process.argv[1], "lib", "node_modules");
            const dirs = [];
            for (const d of fs.readdirSync(root)) {
                if (d.startsWith("@")) {
                    for (const s of fs.readdirSync(path.join(root, d))) dirs.push(path.join(d, s));
                } else if (!d.startsWith(".")) dirs.push(d);
            }
            for (const d of dirs) {
                let j; try { j = JSON.parse(fs.readFileSync(path.join(root, d, "package.json"), "utf8")); } catch (_) { continue; }
                let bin = j.bin;
                if (typeof bin === "string") bin = { [String(j.name || d).split("/").pop()]: bin };
                if (!bin || typeof bin !== "object") continue;
                for (const [n, p] of Object.entries(bin))
                    process.stdout.write(n + "\t" + path.posix.join("lib/node_modules", d, path.posix.normalize(String(p))) + "\n");
            }' "${version_dir}" 2>/dev/null)
    fi
    while IFS=$'\t' read -r agent _ launcher; do
        [[ -n "${agent}" && -n "${launcher}" ]] || continue
        declared="$(ai_tools_agent_manifest_field "${agent}" launcher_target 2>/dev/null || true)"
        [[ -n "${declared}" ]] && ai_tools_launcher_target_valid "${declared}" 2>/dev/null \
            && target_of["${launcher}"]="${declared}"
    done < <(ai_tools_enabled_agents 2>/dev/null)

    local version_real target_path tmp outcome
    version_real="$(realpath -e -- "${version_dir}" 2>/dev/null)" || return 1
    for name in "${copies[@]}"; do
        rel="${target_of[${name}]:-}"
        target_path=""
        [[ -n "${rel}" ]] && target_path="$(realpath -e -- "${version_dir}/${rel}" 2>/dev/null || true)"
        if [[ -z "${target_path}" || "${target_path}" != "${version_real}/"* || ! -f "${target_path}" ]]; then
            outcome=unknown
        elif ! cmp -s -- "${version_dir}/bin/${name}" "${target_path}"; then
            outcome=differs
        else
            tmp="$(mktemp -u "${version_dir}/bin/.${name}.XXXXXX" 2>/dev/null)" || tmp=""
            if [[ -n "${tmp}" ]] && ln -s "../${rel}" "${tmp}" 2>/dev/null && mv -Tf "${tmp}" "${version_dir}/bin/${name}" 2>/dev/null; then
                outcome=relinked
            else
                [[ -n "${tmp}" ]] && rm -f -- "${tmp}"
                outcome=failed
            fi
        fi
        printf '%s\t%s\n' "${name}" "${outcome}"
    done
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
    # was asked about whatever prefix the environment or an .npmrc would otherwise resolve. npm and the tree it runs
    # from are the sandbox account's, so what it prints is held rather than passed through: it is not printed
    # on success, and on a failure its first error line, sanitized, in the report.
    local npm_output npm_said
    npm_output="$(PATH="${version_dir}/bin:${PATH}" npm uninstall -g --prefix "${version_dir}" "${npm_package}" 2>&1)" \
        || true
    if [[ -e "${package_dir}" || -L "${package_dir}" ]]; then
        npm_said="$(grep -m1 -E 'ERR!|^[A-Za-z]*Error' <<<"${npm_output}" || head -n1 <<<"${npm_output}")"
        if [[ -z "${npm_said}" ]]; then
            npm_said="npm printed no error"
        elif declare -F ai_tools_log_sanitize >/dev/null 2>&1; then
            npm_said="npm: $(ai_tools_log_sanitize "${npm_said:0:200}")"
        else
            npm_said="npm's error is not shown: log.lib.sh, which sanitizes it, did not load"
        fi
        _ai_tools_toolchain_warn MSG-X8F9 "could not remove ${package_dir} (npm uninstall left it in place; ${npm_said}) -- every launch stays refused until it is gone; remove it by hand as the sandbox account, then re-run: sudo ai-tools-admin system bootstrap"
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

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/selinux-groups.lib.sh
# Single source for the optional SELinux policy-group registry: each group's name,
# its operator-facing description, the reason it is off by default, and its stability.
# Sourced by the source-tree authoring tool (selinux/install-selinux.sh, which COMPILES a
# group from its .te/.fc), by the installed operator helper (ai-tools-admin selinux, which
# LOADS a compiled .pp from the package directory below), and by selinux/policy/shipped-modules.sh
# (which derives the set a release ships from the stability field), so none of them drifts
# on which groups exist or what they mean. Read-only data plus pure predicates -- no I/O and
# no root operation of its own; the caller owns semodule/make. Include-guarded, so a double
# source no-ops.
#
# Deploy:
#   sudo install -o root -g root -m 644 \
#       src/usr/local/lib/ai-tools/selinux-groups.lib.sh /usr/local/lib/ai-tools/

[[ -n "${_AI_TOOLS_SELINUX_GROUPS_LIB_LOADED:-}" ]] && return 0
readonly _AI_TOOLS_SELINUX_GROUPS_LIB_LOADED=1

# Installed location of the compiled policy modules (the core ai_tools.pp, one
# ai_tools_<group>.pp per stable group, each layout module), populated by the RPM %install
# and by `selinux/install-selinux.sh build`. ai-tools-admin loads a group's .pp from here;
# the source-tree authoring tool compiles into its own policy/ dir first.
# shellcheck disable=SC2034  # read by ai-tools-admin
readonly AI_TOOLS_SELINUX_PACKAGE_DIR="/usr/share/selinux/packages/ai-tools"

# Optional policy groups, all DISABLED by default (the core module alone covers
# repo-only work). Each entry is a pipe-delimited record:
#   name | operator-facing description | why it is off by default | stability
# The reason text is what a caller quotes when a task needs a group that is not
# loaded: it explains the SELinux type mismatch that makes the access fail.
# The stability field is 'experimental' or 'stable', and it decides both whether a group
# is on the shipped set (selinux/policy/shipped-modules.sh reads this field and nothing else
# names the set) and which front door may enable it. An 'experimental' group is an
# unaudited draft whose rule set has not been verified under permissive against a real
# workload: it is off the shipped set, and `ai-tools-admin selinux groups enable` refuses
# it and points at the source workflow rather than loading it. A 'stable' group's rule set
# has been exercised against the workload it serves on an enforcing host; it is on the
# shipped set and loads from that command directly. Add a group as 'experimental' until
# an audit earns it 'stable'.
# shellcheck disable=SC2034  # iterated by consumers via the accessors below
readonly AI_TOOLS_SELINUX_GROUPS=(
    "systemd|System inspection (systemctl, journalctl, unit files)|systemctl is labelled systemd_systemctl_exec_t; ai_tools_t needs execute + D-Bus access to query PID 1. journalctl is journalctl_exec_t.|experimental"
    "pkgmgmt|Package management (rpm, dnf, RPM database)|/usr/bin/rpm is labelled rpm_exec_t (not bin_t); the RPM database is rpm_var_lib_t. Both need explicit allow rules. dnf is bin_t (already executable) but also reads rpm_var_lib_t.|experimental"
    "netadmin|Network administration (firewall-cmd D-Bus, nmcli D-Bus)|firewall-cmd and nmcli are bin_t (already executable) but send commands to firewalld_t and NetworkManager_t via D-Bus; ai_tools_t lacks the dbus send_msg permission those daemons require.|experimental"
    "podman|Container operations (podman/buildah exec, image storage reads)|/usr/bin/podman is labelled container_runtime_exec_t; ai_tools_t cannot execute it without this group. Container image storage (container_file_t) is dontaudit'd in the core module and needs explicit read here.|experimental"
    "tmpmap|Memory-mapping /tmp files (dotnet build, git/SQLite in /tmp)|Files the agent creates under /tmp are ai_tools_tmp_t; the core module grants file map only on the project and home types, so any mmap of a /tmp file fails EACCES. This adds file map on ai_tools_tmp_t -- mmap only, not execute; /tmp is noexec regardless.|stable"
    "apphost|In-memory executable code for .NET hosts (apphost/JIT: dotnet run, ASP.NET Core, worker services, xunit.v3, single-file)|.NET writes generated native code and its apphost to an anonymous memfd file and maps it PROT_EXEC; the core grants execmem (anonymous RWX) but not execute on a tmpfs FILE mapping, so any executable/host project fails to build or run. This adds map+execute on tmpfs (memfd) files. It permits fileless in-memory execution but grants no new privilege (still ai_tools_t, no entrypoint), and is separate from /tmp, which stays noexec. Library builds and in-process test runners (MSTest) do not need it.|experimental"
    "localipc|Local IPC between the session's own processes (unix sockets and FIFOs under /tmp and the home state, loopback TCP to an ephemeral port): dotnet test, multi-node MSBuild, a dev server and its browser, a language server|A socket or FIFO the workload creates under /tmp is born tmp_t, which the base transitions only files, directories and symlinks away from, so it cannot be created; the base also grants no connectto on the domain's own stream sockets and no connect to an ephemeral loopback port. This adds those, all between the sandbox's own processes in its own tmp/home -- the same benign class as the file management the base grants -- and does not reach any new host surface. Off by default because the agent itself needs none of it.|stable"
    "buildexec|Executing a project's build output (the directories each integration's layout module types -- and any script written there)|Running a native host built in the tree (a .NET apphost, a test host, a ReadyToRun image) needs execute on a project file, which the base grants nowhere. This grants it on ai_tools_project_build_t alone, the type carried by the directories an integration's manifest names as its build output (build_output_dirs, ai-tools-providers(5)), so a built binary runs while a git hook or a project script stays non-executable; the type follows the directory name, so a script written under such a directory runs too, which is why the module is off by default. See .claude/rules/dotnet.rule.md.|stable"
)

# A group's FORMER module name, where a group has been renamed or split out of an older one:
# `name|old-module`. A host that loaded the old module through either front door keeps it
# loaded across a package upgrade (no scriptlet unloads a module the registry no longer names),
# still carrying the old module's rule set. Each front door reads this list to replace such a
# module with EVERY current group that names it, in a single semodule transaction, so an
# upgrade neither breaks the workload the old group served nor leaves the old grant in place
# once the operator runs anything that loads policy. An entry is dropped once no supported host
# can still carry the old module.
# shellcheck disable=SC2034  # iterated through the accessors below
readonly AI_TOOLS_SELINUX_GROUP_FORMER_MODULES=(
    "localipc|ai_tools_netcore"
    "buildexec|ai_tools_netcore"
)

# Field accessors for one AI_TOOLS_SELINUX_GROUPS record (name|desc|reason|stability).
ai_tools_selinux_group_name()      { printf '%s' "${1%%|*}"; }
ai_tools_selinux_group_desc()      { local s="${1#*|}"; printf '%s' "${s%%|*}"; }
ai_tools_selinux_group_reason()    { local s="${1#*|}"; s="${s#*|}"; printf '%s' "${s%%|*}"; }
ai_tools_selinux_group_stability() { printf '%s' "${1##*|}"; }

# ai_tools_selinux_group_is_experimental <name>: succeed when <name> is a known group
# whose stability is not 'stable' (unknown/absent stability is treated as experimental --
# fail safe toward warning). A caller gates its confirmation prompt on this.
ai_tools_selinux_group_is_experimental() {
    local name="$1" entry
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        if [[ "$(ai_tools_selinux_group_name "${entry}")" == "${name}" ]]; then
            [[ "$(ai_tools_selinux_group_stability "${entry}")" != "stable" ]]
            return
        fi
    done
    return 0  # unknown group -> treat as experimental (caller validates existence separately)
}

# ai_tools_selinux_group_valid <name>: succeed when <name> is a known group.
ai_tools_selinux_group_valid() {
    local name="$1" entry
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        [[ "$(ai_tools_selinux_group_name "${entry}")" == "${name}" ]] && return 0
    done
    return 1
}

# ai_tools_selinux_group_loaded <name>: succeed when module ai_tools_<name> is
# currently loaded in the kernel. `semodule -l` prints one module NAME per line with
# no version column (selinux-policy on RHEL/Rocky 9/10 and UEK R8), so match the whole
# line exactly -- the same form tests/integration/selinux.sh uses for the core.
#
# The listing is captured first and matched from a here-string, NOT piped into `grep -q`.
# This is the canonical note for every `semodule -l` probe in the tree; the others point
# here. `grep -q` exits on its first match, and an ai_tools* name sorts early in a listing
# of some 400 modules, so the match lands in the first buffer while semodule is still
# writing -- it then dies of SIGPIPE, and under the `set -o pipefail` every consumer of this
# library runs with, the pipeline reports 141 for a probe that SUCCEEDED. The module reads as
# absent at random, and each caller acts on that: no label registered, no group reported
# loaded. A here-string is fully written before grep starts, so no reader can exit early on it.
ai_tools_selinux_group_loaded() { ai_tools_selinux_module_loaded "ai_tools_${1}"; }

# ai_tools_selinux_module_loaded <module>: succeed when the named policy module is in the store.
# The probe behind ai_tools_selinux_group_loaded, taking a full module name so a group's former
# module can be asked about too. Same capture-then-match shape, for the same SIGPIPE reason.
ai_tools_selinux_module_loaded() {
    local modules
    modules="$(semodule -l 2>/dev/null || true)"
    grep -qx "$1" <<<"${modules}"
}

# ai_tools_selinux_group_former_module <name>: print the module name a group's rules were loaded
# under before; empty and non-zero for a group without a former module.
ai_tools_selinux_group_former_module() {
    local entry
    for entry in "${AI_TOOLS_SELINUX_GROUP_FORMER_MODULES[@]}"; do
        if [[ "${entry%%|*}" == "$1" ]]; then
            printf '%s' "${entry#*|}"
            return 0
        fi
    done
    return 1
}

# ai_tools_selinux_groups_from_former_module <module>: print every current group name whose rules
# the former module carried, one per line -- the set a swap loads in the old module's place.
ai_tools_selinux_groups_from_former_module() {
    local entry
    for entry in "${AI_TOOLS_SELINUX_GROUP_FORMER_MODULES[@]}"; do
        [[ "${entry#*|}" == "$1" ]] && printf '%s\n' "${entry%%|*}"
    done
    return 0
}

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/selinux-groups.lib.sh
# Single source for the optional SELinux policy-group registry: each group's name,
# its operator-facing description, and the reason it is off by default. Sourced by
# both the source-tree authoring tool (selinux/install-selinux.sh, which COMPILES a
# group from its .te/.fc) and the installed operator helper (ai-tools-admin selinux,
# which LOADS the prebuilt .pp), so the two never drift on which groups exist or what
# they mean. Read-only data plus pure predicates -- no I/O and no root operation of
# its own; the caller owns semodule/make. Include-guarded, so a double source no-ops.
#
# Deploy:
#   sudo install -o root -g root -m 644 \
#       src/usr/local/lib/ai-tools/selinux-groups.lib.sh /usr/local/lib/ai-tools/

[[ -n "${_AI_TOOLS_SELINUX_GROUPS_LIB_LOADED:-}" ]] && return 0
readonly _AI_TOOLS_SELINUX_GROUPS_LIB_LOADED=1

# Installed location of the prebuilt policy packages (core ai_tools.pp + one
# ai_tools_<group>.pp per optional group), populated by the RPM %install and by
# selinux/install-selinux.sh. ai-tools-admin loads a group's prebuilt .pp from here;
# the source-tree authoring tool builds into its own policy/ dir instead.
# shellcheck disable=SC2034  # read by ai-tools-admin
readonly AI_TOOLS_SELINUX_PACKAGE_DIR="/usr/share/selinux/packages/ai-tools"

# Optional policy groups, all DISABLED by default (the core module alone covers
# repo-only work). Each entry is a pipe-delimited record:
#   name | operator-facing description | why it is off by default | stability
# The reason text is what a caller quotes when a task needs a group that is not
# loaded: it explains the SELinux type mismatch that makes the access fail.
# The stability field is 'experimental' or 'stable': 'experimental' groups are
# unaudited drafts whose rule set has not been verified under permissive against a
# real workload, so a consumer that enables one warns and confirms first (see
# ai-tools-admin selinux enable-group); a 'stable' group is a single, reasoned rule
# that has been tested. Add a group as 'experimental' until it earns 'stable'.
# shellcheck disable=SC2034  # iterated by consumers via the accessors below
readonly AI_TOOLS_SELINUX_GROUPS=(
    "systemd|System inspection (systemctl, journalctl, unit files)|systemctl is labelled systemd_systemctl_exec_t; ai_tools_t needs execute + D-Bus access to query PID 1. journalctl is journalctl_exec_t.|experimental"
    "pkgmgmt|Package management (rpm, dnf, RPM database)|/usr/bin/rpm is labelled rpm_exec_t (not bin_t); the RPM database is rpm_var_lib_t. Both need explicit allow rules. dnf is bin_t (already executable) but also reads rpm_var_lib_t.|experimental"
    "netadmin|Network administration (firewall-cmd D-Bus, nmcli D-Bus)|firewall-cmd and nmcli are bin_t (already executable) but send commands to firewalld_t and NetworkManager_t via D-Bus; ai_tools_t lacks the dbus send_msg permission those daemons require.|experimental"
    "podman|Container operations (podman/buildah exec, image storage reads)|/usr/bin/podman is labelled container_runtime_exec_t; ai_tools_t cannot execute it without this group. Container image storage (container_file_t) is dontaudit'd in the core module and needs explicit read here.|experimental"
    "tmpmap|Memory-mapping /tmp files (dotnet build, git/SQLite in /tmp)|Files the agent creates under /tmp are ai_tools_tmp_t; the core module grants file map only on the project and home types, so any mmap of a /tmp file fails EACCES. This adds file map on ai_tools_tmp_t -- mmap only, not execute; /tmp is noexec regardless.|stable"
    "apphost|In-memory executable code for .NET hosts (apphost/JIT: dotnet run, ASP.NET Core, worker services, xunit.v3, single-file)|.NET writes generated native code and its apphost to an anonymous memfd file and maps it PROT_EXEC; the core grants execmem (anonymous RWX) but not execute on a tmpfs FILE mapping, so any executable/host project fails to build or run. This adds map+execute on tmpfs (memfd) files. It permits fileless in-memory execution but grants no new privilege (still ai_tools_t, no entrypoint), and is separate from /tmp, which stays noexec. Library builds and in-process test runners (MSTest) do not need it.|experimental"
    "netcore|.NET runtime IPC (dotnet test, multi-node MSBuild pipes) and running a project's built executable|The CoreCLR runtime opens diagnostic sockets and FIFOs under /tmp and .local that the base does not create there, and executes native hosts it built from the project tree (ai_tools_project_t) -- neither needed by the agent itself. The IPC half is benign and unblocks dotnet test and multi-node MSBuild; the execution half grants on-disk native execution of a built binary, so the module is off by default. Pairs with tmpmap and apphost; see .claude/rules/dotnet.rule.md.|experimental"
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
ai_tools_selinux_group_loaded() {
    semodule -l 2>/dev/null | grep -qx "ai_tools_${1}"
}

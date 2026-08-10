# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck shell=bash
# /usr/local/lib/ai-tools/session-env.d/dotnet.env.sh
# Session environment for the dotnet integration: a host-managed .NET toolchain, a
# sandbox-writable NuGet cache, and the admin-provisioned shared tools on PATH.
#
# ai-tools-run sources this when `dotnet` is enabled in /etc/ai-tools/operator.conf
# (AI_TOOLS_INTEGRATIONS). It self-gates on a host dotnet, so it is inert on a host without
# one even when enabled -- this integration packages no runtime.
#
# One state root backs it, provisioned by `sudo ai-tools-dotnet setup` -- every integration keeps
# its sandbox-side state under /opt/ai-tools/integrations/<name>, so no toolchain adds a dotdir to
# the sandbox home and one SELinux rule covers them all:
#   integrations/dotnet/nuget   restore cache, agent-writable across every project
#   integrations/dotnet/cli     the SDK's own state (DOTNET_CLI_HOME), agent-writable
#   integrations/dotnet/tools   shared global tools, read-only to the agent (sudo-only writes)
#
# The variables are those .NET 8 LTS and later read. DOTNET_CLI_HOME is what keeps the shared
# tools tree read-only: the SDK's own state defaults to $HOME/.dotnet, so it is pinned at the
# writable sibling instead.
#
# MSBUILDDISABLENODEREUSE=1 stops MSBuild from leaving persistent worker nodes running between
# invocations. Every operator's builds share one sandbox UID, so a reused node keeps a build
# task's assemblies loaded and locks the prior project's output file -- a second build in the same
# solution then fails on the lock (dotnet/msbuild#6461, for which the maintainers recommend exactly
# this variable). Disabling reuse costs a little per-build cold start, never correctness.
#
# Fragment contract (see providers.rule.md): append to session_environment_options and
# session_path_entries, unset your own temporaries, and do not exec, prompt, or read stdin.
# shellcheck disable=SC2154  # both arrays belong to the sourcing launcher

[[ -x /usr/bin/dotnet ]] || return 0

# The host SDK/runtime tree at its RPM path, or wherever the muxer resolves to. The muxer is
# already on the session PATH, so PATH itself needs no dotnet entry.
dotnet_root=/usr/lib64/dotnet
[[ -d "${dotnet_root}" ]] || dotnet_root="$(dirname -- "$(readlink -f /usr/bin/dotnet)")"

session_environment_options+=(
    "--setenv=DOTNET_ROOT=${dotnet_root}"
    "--setenv=NUGET_PACKAGES=/opt/ai-tools/integrations/dotnet/nuget/packages"
    "--setenv=DOTNET_CLI_HOME=/opt/ai-tools/integrations/dotnet/cli"
    "--setenv=DOTNET_CLI_TELEMETRY_OPTOUT=1"
    "--setenv=DOTNET_NOLOGO=1"
    "--setenv=MSBUILDDISABLENODEREUSE=1"
    "--setenv=ASPNETCORE_ENVIRONMENT=Development"
    "--setenv=DOTNET_ENVIRONMENT=Development"
)
# Only the root-owned shared tools join PATH. A tool the agent installs for itself under
# DOTNET_CLI_HOME stays runnable by full path but never lands on the session PATH, so the
# sandbox cannot put an executable of its own choosing there.
session_path_entries+=( /opt/ai-tools/integrations/dotnet/tools )

unset dotnet_root

# shellcheck shell=bash
# /usr/local/lib/ai-tools/session-env.d/dotnet.env.sh
# Session environment for the dotnet integration: a host-managed .NET toolchain, a
# sandbox-writable NuGet cache, and the admin-provisioned shared tools on PATH.
#
# ai-tools-run sources this when `dotnet` is enabled in /etc/ai-tools/operator.conf
# (AI_TOOLS_INTEGRATIONS). It self-gates on a host dotnet, so it is inert on a host without
# one even when enabled -- this integration packages no runtime.
#
# Two directories back it, provisioned by `sudo ai-tools-dotnet setup`:
#   /opt/ai-tools/.nuget   restore cache, agent-writable across every project
#   /opt/ai-tools/.dotnet  shared global tools, read-only to the agent (sudo-only writes)
#
# The variables are those .NET 8 LTS and later read. DOTNET_CLI_HOME is what keeps the shared
# tools tree read-only: the SDK's own state defaults to $HOME/.dotnet, which here IS that tree,
# so it is redirected into the writable .cache subtree.
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
    "--setenv=NUGET_PACKAGES=/opt/ai-tools/.nuget/packages"
    "--setenv=DOTNET_CLI_HOME=/opt/ai-tools/.cache/dotnet"
    "--setenv=DOTNET_CLI_TELEMETRY_OPTOUT=1"
    "--setenv=DOTNET_NOLOGO=1"
    "--setenv=ASPNETCORE_ENVIRONMENT=Development"
    "--setenv=DOTNET_ENVIRONMENT=Development"
)
# Only the root-owned shared tools join PATH. A tool the agent installs for itself under
# DOTNET_CLI_HOME stays runnable by full path but never lands on the session PATH, so the
# sandbox cannot put an executable of its own choosing there.
session_path_entries+=( /opt/ai-tools/.dotnet/tools )

unset dotnet_root

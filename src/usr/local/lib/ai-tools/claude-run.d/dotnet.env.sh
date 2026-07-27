# shellcheck shell=bash
# /usr/local/lib/ai-tools/claude-run.d/dotnet.env.sh
# Session-env fragment for the dotnet integration (ai-tools-integration-dotnet). claude-run
# sources this -- in its own scope, as @SANDBOX_USER@ -- ONLY when `dotnet` is enabled in
# operator.conf (AI_TOOLS_INTEGRATIONS) and this file is root-owned and not group/other-writable
# (see the seam in claude-run). It appends to the launcher's _setenv (session env vars) and
# _extra_path (PATH tail); it must not exec, prompt, or depend on the caller's env beyond those
# two arrays. It self-gates on a host dotnet being present, so it is inert on a host without the
# toolchain even when enabled -- the integration carries no dotnet RPM dependency and detects the
# host install at runtime.
#
# _setenv / _extra_path are defined by the sourcing launcher (claude-run), not here.
# shellcheck disable=SC2154

[[ -x /usr/bin/dotnet ]] || return 0

# DOTNET_ROOT: the host SDK/runtime tree (the RPM path); fall back to the muxer's resolved dir.
# The muxer (/usr/bin/dotnet) is already on the pinned PATH, so PATH need not carry DOTNET_ROOT.
_dotnet_root=/usr/lib64/dotnet
[[ -d "${_dotnet_root}" ]] || _dotnet_root="$(dirname -- "$(readlink -f /usr/bin/dotnet)")"

_setenv+=(
    "--setenv=DOTNET_ROOT=${_dotnet_root}"
    # NuGet restore cache: a sandbox-writable, cross-project dir (labelled ai_tools_home_t by the
    # package's local fcontext), so per-build restores land off the read-only host tree.
    "--setenv=NUGET_PACKAGES=/opt/ai-tools/.nuget/packages"
    # Quiet + non-interactive: no telemetry, no logo, no first-run writes to the read-only home root.
    "--setenv=DOTNET_CLI_TELEMETRY_OPTOUT=1"
    "--setenv=DOTNET_NOLOGO=1"
    "--setenv=DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1"
    "--setenv=DOTNET_PRINT_TELEMETRY_MESSAGE=false"
    "--setenv=ASPNETCORE_ENVIRONMENT=Development"
    "--setenv=DOTNET_ENVIRONMENT=Development"
)
# Admin-provisioned global tools (sudo ai-tools-dotnet install-tools) live here, read-only to the
# agent; add them to the session PATH tail.
_extra_path+=( /opt/ai-tools/.dotnet/tools )

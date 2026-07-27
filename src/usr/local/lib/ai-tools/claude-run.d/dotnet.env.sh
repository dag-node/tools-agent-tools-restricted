# shellcheck shell=bash
# /usr/local/lib/ai-tools/claude-run.d/dotnet.env.sh
# Session-env fragment for the dotnet integration (ai-tools-integration-dotnet). claude-run
# sources this -- in its own scope, as @SANDBOX_USER@ -- ONLY when `dotnet` is enabled in
# operator.conf (AI_TOOLS_INTEGRATIONS) and both this file and its directory are root-owned and
# not group/other-writable (see the seam in claude-run). It appends to the launcher's _setenv
# (session env vars) and _extra_path (PATH tail); it must not exec, prompt, or depend on the
# caller's env beyond those two arrays, and it unsets its own temporaries, since claude-run's
# scope is shared with every other enabled fragment. It self-gates on a host dotnet being present,
# so it is inert on a host without the toolchain even when enabled -- the integration carries no
# dotnet RPM dependency and detects the host install at runtime.
#
# The variables below are those current for .NET 8 LTS and every later release. The .NET Core
# 2.x/3.x-era opt-outs (DOTNET_SKIP_FIRST_TIME_EXPERIENCE, DOTNET_PRINT_TELEMETRY_MESSAGE) are
# deliberately absent: they were removed from the SDK and setting them silences nothing.
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
    # The SDK's own state dir (first-use sentinels, CLI logs). It defaults to $HOME/.dotnet, which
    # here is the ADMIN-managed shared tools tree the agent must not write, so it is redirected
    # into the already-writable, already-ai_tools_home_t-labelled .cache subtree -- no extra
    # fcontext, and the read-only tools dir stays read-only.
    "--setenv=DOTNET_CLI_HOME=/opt/ai-tools/.cache/dotnet"
    # Quiet + non-interactive: no telemetry, no logo.
    "--setenv=DOTNET_CLI_TELEMETRY_OPTOUT=1"
    "--setenv=DOTNET_NOLOGO=1"
    "--setenv=ASPNETCORE_ENVIRONMENT=Development"
    "--setenv=DOTNET_ENVIRONMENT=Development"
)
# Admin-provisioned global tools (sudo ai-tools-dotnet install-tools) live here, read-only to the
# agent; add them to the session PATH tail. Only this root-owned dir goes on PATH: a tool the
# agent installs for itself under DOTNET_CLI_HOME stays reachable by full path but never joins the
# session PATH, so the sandbox cannot put an executable of its own choosing on it.
_extra_path+=( /opt/ai-tools/.dotnet/tools )

unset _dotnet_root

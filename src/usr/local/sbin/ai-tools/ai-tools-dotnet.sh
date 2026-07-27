#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-dotnet
# Provision and inspect the dotnet integration for the ai-tools sandbox. Root/sudo helper.
#
# The .NET SDK/runtime itself is the HOST's RPM-managed dotnet (this integration adds no runtime
# and carries no dotnet RPM dependency). This helper sets up the sandbox-side directories and
# SELinux labels the session-env fragment (claude-run.d/dotnet.env.sh) relies on, and installs
# shared global tools an operator wants available to every project. "Modifications require sudo":
# the tools dir is root-owned and read-only to the agent, so only this helper changes it.
#
#   sudo ai-tools-dotnet setup                  # create + label the .nuget/.dotnet dirs (offline, idempotent)
#   sudo ai-tools-dotnet install-tools <pkg...> # install global dotnet tools into the shared dir (network)
#   sudo ai-tools-dotnet status                 # show host SDKs/runtimes + sandbox state
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-dotnet.sh /usr/local/sbin/ai-tools/ai-tools-dotnet

set -euo pipefail

readonly SANDBOX_GROUP="@SANDBOX_GROUP@"
readonly SANDBOX_HOME="/opt/ai-tools"
readonly NUGET_DIR="${SANDBOX_HOME}/.nuget"
readonly DOTNET_DIR="${SANDBOX_HOME}/.dotnet"
readonly TOOLS_DIR="${DOTNET_DIR}/tools"
readonly OPERATOR_CONF="/etc/ai-tools/operator.conf"

die() { printf 'ai-tools-dotnet: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'ai-tools-dotnet: %s\n' "$*"; }

[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"

# apply_home_label <path> : add (or update) a local fcontext mapping <path> to ai_tools_home_t and
# relabel it, so ai_tools_t may read/write (.nuget) or read/exec (.dotnet) it under enforcing.
# A no-op when SELinux is Disabled or the ai_tools type is not installed (DAC still governs).
apply_home_label() {
    local path="$1"
    command -v semanage >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null)" != Disabled ]] || return 0
    semanage fcontext -a -t ai_tools_home_t "${path}(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t ai_tools_home_t "${path}(/.*)?" 2>/dev/null || true
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "${path}" >/dev/null 2>&1 || true
    fi
}

setup() {
    # NuGet restore cache: agent-WRITABLE (setgid, group ai-tools rwx), shared across projects, so
    # a package restored once serves every project.
    install -d -o root -g "${SANDBOX_GROUP}" -m 2770 "${NUGET_DIR}" "${NUGET_DIR}/packages"
    # Shared global tools + CLI home: admin-managed, READ-ONLY to the agent (no group write), so
    # only this helper (root) changes them.
    install -d -o root -g "${SANDBOX_GROUP}" -m 0755 "${DOTNET_DIR}" "${TOOLS_DIR}"
    # Both are ai_tools_home_t: the type grants ai_tools_t the SELinux access (write on the cache,
    # exec on the tools), while the DAC modes above are the enforced read/write boundary. Mirrors
    # the .npm/.cache home-state labels; not a core-module change.
    apply_home_label "${NUGET_DIR}"
    apply_home_label "${DOTNET_DIR}"
    log "dotnet integration ready: writable NuGet cache ${NUGET_DIR}, shared tools ${TOOLS_DIR}"
    log "enable it for sessions by adding 'dotnet' to AI_TOOLS_INTEGRATIONS in ${OPERATOR_CONF}"
}

install_tools() {
    [[ $# -gt 0 ]] || die "usage: ai-tools-dotnet install-tools <package> [<package> ...]"
    command -v dotnet >/dev/null 2>&1 || die "dotnet not found on PATH -- install a host dotnet-sdk package first"
    setup   # ensure the tools dir exists and is labelled before writing into it
    local package
    for package in "$@"; do
        log "installing global tool ${package} into ${TOOLS_DIR}"
        DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
            dotnet tool install --tool-path "${TOOLS_DIR}" "${package}" \
            || DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
               dotnet tool update --tool-path "${TOOLS_DIR}" "${package}" \
            || die "failed to install or update ${package}"
    done
    # Relabel the freshly written tool binaries ai_tools_home_t (so the agent may exec them) while
    # they stay root-owned and non-group-writable (RO to the agent).
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "${TOOLS_DIR}" >/dev/null 2>&1 || true
    fi
    log "done; the tools are on the session PATH when the dotnet integration is enabled"
}

status() {
    if command -v dotnet >/dev/null 2>&1; then
        log "host dotnet: $(dotnet --version 2>/dev/null || echo '?')"
        log "SDKs:";     dotnet --list-sdks     2>/dev/null | sed 's/^/  /' || true
        log "runtimes:"; dotnet --list-runtimes 2>/dev/null | sed 's/^/  /' || true
    else
        log "host dotnet: NOT installed -- install a host dotnet-sdk package to use this integration"
    fi
    log "NuGet cache:  ${NUGET_DIR} ($( [[ -d "${NUGET_DIR}" ]] && echo present || echo missing ))"
    local tool_count=0
    [[ -d "${TOOLS_DIR}" ]] && tool_count="$(find "${TOOLS_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    log "shared tools: ${TOOLS_DIR} (${tool_count} tool file(s))"
    if grep -Eq '^[[:space:]]*AI_TOOLS_INTEGRATIONS=.*dotnet' "${OPERATOR_CONF}" 2>/dev/null; then
        log "session enablement: dotnet ENABLED in ${OPERATOR_CONF}"
    else
        log "session enablement: dotnet NOT enabled -- add it to AI_TOOLS_INTEGRATIONS in ${OPERATOR_CONF}"
    fi
}

case "${1:-}" in
    setup)          setup ;;
    install-tools)  shift; install_tools "$@" ;;
    status)         status ;;
    *)              die "usage: ai-tools-dotnet {setup|install-tools <pkg...>|status}" ;;
esac

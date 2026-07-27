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
#   sudo ai-tools-dotnet install-tools <pkg...> # install global tools into the shared dir (network)
#   sudo ai-tools-dotnet status                 # show host SDKs/runtimes + sandbox state
#
# Every step FAILS LOUDLY: a directory it cannot create or a label it cannot apply on a host that
# should support it is an error with a non-zero exit, not a silent skip, so a half-provisioned
# integration cannot masquerade as a working one. The genuine no-ops -- SELinux disabled, no
# policycoreutils, the ai_tools module not installed -- are recognized and logged as such. Every
# outcome goes through the shared logger to journald and /var/log/ai-tools/dotnet.log.
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

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/dotnet.log.
# shellcheck disable=SC2034  # read by log.lib.sh
AI_TOOLS_LOG_TAG="ai-tools-dotnet"
# shellcheck disable=SC2034  # read by log.lib.sh
AI_TOOLS_LOG_FILE="dotnet.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

die()  { ai_tools_log_error "$*"; printf 'ai-tools-dotnet: error: %s\n' "$*" >&2; exit 1; }
log()  { ai_tools_log_info  "$*"; printf 'ai-tools-dotnet: %s\n' "$*"; }
warn() { ai_tools_log_warn  "$*"; printf 'ai-tools-dotnet: warning: %s\n' "$*" >&2; }

[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"

# selinux_active : succeed when this host both runs SELinux and carries the ai-tools policy, i.e.
# when a labelling failure is a real failure. A host with SELinux disabled, without the
# policycoreutils tooling, or without the ai_tools module loaded has no ai_tools_home_t to map to;
# there the label step is a legitimate no-op and DAC alone governs.
selinux_active() {
    command -v semanage   >/dev/null 2>&1 || return 1
    command -v restorecon >/dev/null 2>&1 || return 1
    command -v getenforce >/dev/null 2>&1 || return 1
    [[ "$(getenforce 2>/dev/null)" != Disabled ]] || return 1
    command -v semodule >/dev/null 2>&1 || return 1
    semodule -l 2>/dev/null | grep -qx ai_tools
}

# apply_home_label <path> : map <path> to ai_tools_home_t with a local fcontext rule and relabel
# it, so ai_tools_t may read/write (.nuget) or read/exec (.dotnet) it under enforcing. Adds the
# rule, or modifies an existing one; a failure of BOTH is fatal, because a silently unlabelled dir
# breaks the integration only later, inside a confined session, as an opaque denial.
apply_home_label() {
    local path="$1"
    semanage fcontext -a -t ai_tools_home_t "${path}(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t ai_tools_home_t "${path}(/.*)?" 2>/dev/null \
        || die "could not map ${path} to ai_tools_home_t (semanage fcontext -a/-m both failed)"
    restorecon -R "${path}" >/dev/null 2>&1 \
        || die "could not relabel ${path} (restorecon failed)"
    ai_tools_log_debug "labelled ${path} ai_tools_home_t"
}

setup() {
    # NuGet restore cache: agent-WRITABLE (setgid, group ai-tools rwx), shared across projects, so
    # a package restored once serves every project.
    install -d -o root -g "${SANDBOX_GROUP}" -m 2770 "${NUGET_DIR}" "${NUGET_DIR}/packages" \
        || die "could not create the NuGet cache under ${NUGET_DIR}"
    # Shared global tools + their parent: admin-managed, READ-ONLY to the agent (no group write),
    # so only this helper (root) changes them. The SDK's own state dir is NOT here -- the session
    # fragment points DOTNET_CLI_HOME at the writable .cache subtree.
    install -d -o root -g "${SANDBOX_GROUP}" -m 0755 "${DOTNET_DIR}" "${TOOLS_DIR}" \
        || die "could not create the shared tools dir ${TOOLS_DIR}"
    # Both are ai_tools_home_t: the type grants ai_tools_t the SELinux access (write on the cache,
    # exec on the tools), while the DAC modes above are the enforced read/write boundary. Mirrors
    # the .npm/.cache home-state labels; not a core-module change.
    if selinux_active; then
        apply_home_label "${NUGET_DIR}"
        apply_home_label "${DOTNET_DIR}"
    else
        log "SELinux labelling skipped: no enforcing ai-tools policy on this host (DAC governs)"
    fi
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
    if selinux_active; then
        restorecon -R "${TOOLS_DIR}" >/dev/null 2>&1 \
            || die "installed ${*}, but could not relabel ${TOOLS_DIR} -- the agent cannot exec the tools until it is relabelled"
    fi
    log "done; the tools are on the session PATH when the dotnet integration is enabled"
}

# dotnet_enabled : succeed when a session would actually get the dotnet integration -- the same
# verdict claude-run reaches, via the shared resolver, rather than a grep over operator.conf that
# would also match a commented-out line or a different name containing "dotnet".
dotnet_enabled() {
    local providers_lib=/usr/local/lib/ai-tools/providers.lib.sh
    # shellcheck source=SCRIPTDIR/../../lib/ai-tools/providers.lib.sh
    if ! source "${providers_lib}" 2>/dev/null \
            || ! declare -F ai_tools_enabled_integrations >/dev/null 2>&1; then
        warn "provider resolver unavailable -- cannot report session enablement"
        return 1
    fi
    ai_tools_enabled_integrations 2>/dev/null | grep -qx dotnet
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
    if dotnet_enabled; then
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

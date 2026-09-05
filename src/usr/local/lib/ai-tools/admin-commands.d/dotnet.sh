#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# ai-tools-admin-command: dotnet
# ai-tools-admin-api-min-version: 1.0
# ai-tools-admin-verbs: bootstrap tools status
# /usr/local/lib/ai-tools/admin-commands.d/dotnet
# The `dotnet` domain of ai-tools-admin: provision and inspect the dotnet integration. A command
# fragment, contributed by ai-tools-integration-dotnet and exec'd by ai-tools-admin, so the base
# package dispatches this domain without knowing the integration exists (providers.rule.md).
#
# The three `ai-tools-admin-*` lines above are the seam's interface declaration, read by
# ai-tools-admin before it runs anything here: the domain this file is installed as, the least
# interface version it needs from that tool, and the top-level verbs it answers. They stay within
# the first 20 lines, and `verbs` stays in step with the dispatch at the foot of this file --
# `system bootstrap --scope full` reads that list to decide whether this integration has
# provisioning to do, rather than running the command to find out.
#
# The .NET SDK/runtime itself is the HOST's RPM-managed dotnet (this integration does not ship a
# runtime of its own, and does not take a dotnet RPM dependency). This command sets up the
# sandbox-side directories and SELinux labels the session-env fragment (session-env.d/dotnet.env.sh)
# relies on, and installs shared global tools an operator wants available to every project.
# "Modifications require sudo": the tools dir is root-owned and read-only to the agent, so only this
# command changes it.
#
#   sudo ai-tools-admin dotnet bootstrap             # create + label the .nuget/.dotnet dirs (offline, idempotent)
#   sudo ai-tools-admin dotnet tools install <pkg...> # install global tools into the shared dir (network)
#   sudo ai-tools-admin dotnet status                # show host SDKs/runtimes + sandbox state
#
# Every step FAILS LOUDLY: a directory it cannot create or a label it cannot apply on a host that
# should support it is an error with a non-zero exit, not a silent skip, so a half-provisioned
# integration cannot masquerade as a working one. The genuine no-ops -- SELinux disabled, no
# policycoreutils, the ai_tools module not installed -- are recognized and logged as such. Every
# outcome goes through the shared logger to journald and /var/log/ai-tools/dotnet.log, both under
# the ai-tools-dotnet tag: the log identity is what an operator queries and it stays as it is,
# where the typed command is what moved.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/lib/ai-tools/admin-commands.d/dotnet.sh /usr/local/lib/ai-tools/admin-commands.d/dotnet

set -euo pipefail

readonly SANDBOX_GROUP="@SANDBOX_GROUP@"
readonly OPERATOR_CONF="/etc/ai-tools/operator.conf"

# The control-plane contract: CP_INTEGRATIONS is the one root every integration keeps its
# sandbox-side state under, and the base's static file-context rule already maps that whole tree
# to ai_tools_home_t -- so this command creates directories and never touches SELinux policy.
# REQUIRED: without it the paths below are unknown, and guessing them would put the cache
# somewhere the policy does not cover. Bare source under set -e.
# shellcheck source=SCRIPTDIR/../control-plane.lib.sh
source /usr/local/lib/ai-tools/control-plane.lib.sh
readonly STATE_DIR="${CP_INTEGRATIONS}/dotnet"
readonly NUGET_DIR="${STATE_DIR}/nuget"
readonly CLI_HOME_DIR="${STATE_DIR}/cli"
readonly TOOLS_DIR="${STATE_DIR}/tools"

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/dotnet.log.
# shellcheck disable=SC2034  # read by log.lib.sh
AI_TOOLS_LOG_TAG="ai-tools-dotnet"
# shellcheck disable=SC2034  # read by log.lib.sh
AI_TOOLS_LOG_FILE="dotnet.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

die()  { ai_tools_log_error "$*"; printf 'ai-tools-admin dotnet: error: %s\n' "$*" >&2; exit 1; }
log()  { ai_tools_log_info  "$*"; printf 'ai-tools-admin dotnet: %s\n' "$*"; }
warn() { ai_tools_log_warn  "$*"; printf 'ai-tools-admin dotnet: warning: %s\n' "$*" >&2; }

# reject <message>: the command line was rejected. Exit 2, the same split ai-tools-admin makes --
# a command nobody can type correctly, rather than an operation that ran and failed.
reject() {
    printf 'ai-tools-admin dotnet: %s\n' "$*" >&2
    printf "try 'ai-tools-admin dotnet --help'\n" >&2
    exit 2
}

# usage: this domain's commands. Orientation, like ai-tools-admin's own: the mechanism each one
# applies is in .claude/rules/dotnet.rule.md and providers.rule.md.
usage() {
    cat <<EOF
ai-tools-admin dotnet -- the .NET toolchain: its sandbox state and shared tools

    dotnet bootstrap                    create and label the sandbox-side .NET state
    dotnet tools install <pkg>...       install shared global tools (reaches the network)
    dotnet status                       host SDKs and runtimes, and the sandbox state

  The .NET SDK is the host's own; this integration ships no runtime. A session gets
  it once 'dotnet' is named in AI_TOOLS_INTEGRATIONS in ${OPERATOR_CONF}.
EOF
}

# --help leaves the host as it is and does not read its state, so it answers any caller and is handled
# ahead of the root check -- ai-tools-admin's own rule, applied one level down.
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
esac

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
    # Captured, not piped into `grep -q`: an early-exiting reader makes semodule die of SIGPIPE
    # and pipefail then reports the probe failed -- see ai_tools_selinux_group_loaded.
    local modules
    modules="$(semodule -l 2>/dev/null || true)"
    grep -qx ai_tools <<<"${modules}"
}

# label_state <path> : give <path> the label the base policy already maps it to. No `semanage`:
# the integrations root carries a STATIC rule in ai_tools.fc, so every integration's state is
# covered by one base-owned rule and a new toolchain does not add policy of its own. A failure is
# fatal -- a silently unlabelled dir breaks the integration only later, inside a confined
# session, as an opaque denial.
label_state() {
    local path="$1"
    restorecon -R "${path}" >/dev/null 2>&1 \
        || die "could not relabel ${path} (restorecon failed)"
    ai_tools_log_debug "labelled ${path} from the base file-context rule"
}

# drop_legacy_fcontexts : remove the local fcontext rules earlier versions of this command added
# for its home-root dotdirs. They name paths this integration no longer uses, and they would
# outlive the ai_tools module that defines their type. Best-effort: absent rules are the normal
# case on a fresh host.
drop_legacy_fcontexts() {
    local legacy
    for legacy in /opt/ai-tools/.nuget /opt/ai-tools/.dotnet; do
        semanage fcontext -d "${legacy}(/.*)?" >/dev/null 2>&1 || :
    done
}

# bootstrap : the integration's first-run setup, and the verb every provider takes for it
# (cli-grammar.rule.md). Idempotent and offline, so `system bootstrap --scope full` and this
# package's own %post both reach it without asking what the host is already carrying.
bootstrap() {
    [[ $# -eq 0 ]] || reject "dotnet bootstrap: takes no arguments"
    # This integration's state root, inside the base-owned integrations tree. Root-owned and
    # group-traversable: what the agent may write is decided per directory below, not here.
    install -d -o root -g "${SANDBOX_GROUP}" -m "${CP_DIR_MODES[integrations]}" \
        "${CP_INTEGRATIONS}" "${STATE_DIR}" \
        || die "could not create the dotnet state root ${STATE_DIR}"
    # Set both modes exactly: created under the setgid control-plane home, a new directory
    # inherits setgid, and a plain chmod would not clear it (see ai_tools_apply_mode).
    ai_tools_apply_mode "${CP_DIR_MODES[integrations]}" "${CP_INTEGRATIONS}" "${STATE_DIR}" \
        || die "could not set the mode on ${STATE_DIR}"
    # NuGet restore cache and the SDK's own state: agent-WRITABLE (setgid, group ai-tools rwx).
    # The cache is shared across projects, so a package restored once serves every project; the
    # CLI home is what keeps the shared tools tree below read-only, since the SDK would otherwise
    # write its state into $HOME/.dotnet.
    install -d -o root -g "${SANDBOX_GROUP}" -m 2770 \
        "${NUGET_DIR}" "${NUGET_DIR}/packages" "${CLI_HOME_DIR}" \
        || die "could not create the writable dotnet state under ${STATE_DIR}"
    # Shared global tools: admin-managed, READ-ONLY to the agent (no group write), so only this
    # command (root) changes them.
    install -d -o root -g "${SANDBOX_GROUP}" -m 0755 "${TOOLS_DIR}" \
        || die "could not create the shared tools dir ${TOOLS_DIR}"
    ai_tools_apply_mode 0755 "${TOOLS_DIR}" || die "could not set the mode on ${TOOLS_DIR}"
    # One label for the whole tree, from the base policy's static rule: the type grants ai_tools_t
    # the SELinux access (write on the cache, exec on the tools), while the DAC modes above are
    # the enforced read/write boundary.
    if selinux_active; then
        drop_legacy_fcontexts
        label_state "${STATE_DIR}"
    else
        log "SELinux labelling skipped: no enforcing ai-tools policy on this host (DAC governs)"
    fi
    log "dotnet integration ready: writable NuGet cache ${NUGET_DIR}, shared tools ${TOOLS_DIR}"
    log "enable it for sessions by adding 'dotnet' to AI_TOOLS_INTEGRATIONS in ${OPERATOR_CONF}"
}

tools_install() {
    [[ $# -gt 0 ]] || reject "dotnet tools install: name at least one package"
    command -v dotnet >/dev/null 2>&1 || die "dotnet not found on PATH -- install a host dotnet-sdk package first"
    bootstrap   # ensure the tools dir exists and is labelled before writing into it
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
# verdict ai-tools-run reaches, via the shared resolver, rather than a grep over operator.conf that
# would also match a commented-out line or a different name containing "dotnet".
dotnet_enabled() {
    local providers_lib=/usr/local/lib/ai-tools/providers.lib.sh
    # shellcheck source=SCRIPTDIR/../providers.lib.sh
    if ! source "${providers_lib}" 2>/dev/null \
            || ! declare -F ai_tools_enabled_integrations >/dev/null 2>&1; then
        warn "provider resolver unavailable -- cannot report session enablement"
        return 1
    fi
    ai_tools_enabled_integrations 2>/dev/null | grep -qx dotnet
}

status() {
    [[ $# -eq 0 ]] || reject "dotnet status: takes no arguments"
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

# ── dispatch ─────────────────────────────────────────────────────────────────────────────────
# `tools` is a collection with no `list` yet, so a bare `dotnet tools` names its verb rather than
# running one: the installed tools are already reported by `dotnet status`.
tools_dispatch() {
    [[ $# -ge 1 ]] || reject "dotnet tools takes a verb: 'dotnet tools install <pkg>...'"
    local verb="$1"; shift
    case "${verb}" in
        install) tools_install "$@" ;;
        *)       reject "unknown command 'dotnet tools ${verb}' (install)" ;;
    esac
}

case "${1:-}" in
    bootstrap) shift; bootstrap "$@" ;;
    tools)     shift; tools_dispatch "$@" ;;
    status)    shift; status "$@" ;;
    '')        reject "dotnet takes a command: 'dotnet bootstrap', 'dotnet tools install <pkg>...', 'dotnet status'" ;;
    *)         reject "unknown command 'dotnet $1' (bootstrap|tools|status)" ;;
esac

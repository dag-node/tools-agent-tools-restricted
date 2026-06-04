#!/usr/bin/env bash
# /usr/local/lib/ai-tools/log.lib.sh
# Shared leveled logger for the ai-tools sandbox components. Sourced (not executed)
# by the sudo root helpers (ai-tools-chown / -setgid / -claude-symlink / -lockdown),
# the lifecycle hooks (post-tool-hook.sh, session-hook.sh), and the ai-tools project
# CLI, so every component records DEBUG / INFO / WARNING / ERROR lines in one format
# to two sinks:
#
#   journald  -- ALWAYS. Each line goes to the systemd journal via logger(1) with a
#                per-component SyslogIdentifier (AI_TOOLS_LOG_TAG) and a syslog
#                priority matching the level, so `journalctl -t ai-tools-chown -p
#                warning` (and friends) just work. This is the universal sink: it is
#                writable by the NON-root components (the hooks run as the agent, the
#                CLI as the projects user) which cannot write the root-only file logs.
#
#   file      -- OPTIONALLY, when the caller set AI_TOOLS_LOG_FILE to a basename under
#                /var/log/ai-tools (root:root 700, files 600). Only the root writers
#                (the sudo helpers, install.sh) set it; the append is best-effort and
#                silently no-ops for a non-root caller, so the file logs stay a
#                root-only durable trail -- quarantined-secret filenames are never
#                exposed to the agent -- while the journal carries the same lines for
#                everyone (and for the agent's own hook messages, its own only).
#
# Both sinks are best-effort: a failed write (no journald, full disk, a SELinux denial,
# EPERM on the file) is swallowed so logging can never abort -- or alter the exit
# status of -- the operation the caller is performing.
#
# Scope is a CALLER convention, not enforced here: log the privileged operations the
# hooks and sudo helpers perform, the CLI's workflow milestones (project / sandbox
# created, locked down), and the full install transcript -- not routine per-path sweep
# churn, which is emitted at DEBUG only (and only when a path is actually changed).

readonly AI_TOOLS_LOG_DIR="/var/log/ai-tools"

# _ai_tools_log_prio <level> -- map a level word to its syslog priority. Unknown -> info.
_ai_tools_log_prio() {
    case "$1" in
        dbg|debug)     printf 'debug' ;;
        inf|info)      printf 'info' ;;
        notice)        printf 'notice' ;;
        warn|warning)  printf 'warning' ;;
        err|error)     printf 'err' ;;
        *)             printf 'info' ;;
    esac
}

# ai_tools_log <level> <message...> -- emit one leveled line to journald (always) and,
# when AI_TOOLS_LOG_FILE is set and writable, to /var/log/ai-tools/<file>. AI_TOOLS_LOG_TAG
# (default "ai-tools") becomes the journald SyslogIdentifier. Read at call time, so the
# caller may set either variable any time before logging.
ai_tools_log() {
    local level="$1"; shift
    local tag="${AI_TOOLS_LOG_TAG:-ai-tools}" prio msg
    prio="$(_ai_tools_log_prio "${level}")"
    msg="$*"

    # journald via logger(1): -t sets the SyslogIdentifier, -p the facility.level
    # PRIORITY. Always attempted; failure (no logger, no journald) is ignored.
    logger -t "${tag}" -p "daemon.${prio}" -- "${msg}" 2>/dev/null || true

    # Optional root-only file sink. The umask subshell keeps a freshly created log 600.
    if [[ -n "${AI_TOOLS_LOG_FILE:-}" ]]; then
        ( umask 077
          printf '%s %-7s [%d] %s\n' "$(date -Is)" "${level^^}" "$$" "${msg}" \
              >> "${AI_TOOLS_LOG_DIR}/${AI_TOOLS_LOG_FILE}"
        ) 2>/dev/null || true
    fi
}

# Convenience wrappers -- prefixed to avoid colliding with callers' own log()/warn().
ai_tools_log_debug() { ai_tools_log debug   "$@"; }
ai_tools_log_info()  { ai_tools_log info    "$@"; }
ai_tools_log_warn()  { ai_tools_log warning "$@"; }
ai_tools_log_error() { ai_tools_log error   "$@"; }

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

# Include guard. Consumers source this lib directly, and msg.lib.sh sources it too (for its
# decision audit trail), so one process can reach it twice; the readonly below would abort a
# re-source under set -e, so a second source is a no-op. Tags, files, and levels are read per
# call, so a single definition serves every caller.
if [[ -n "${_AI_TOOLS_LOG_LIB_LOADED:-}" ]]; then return 0; fi
readonly _AI_TOOLS_LOG_LIB_LOADED=1

# Directory for the optional root-only file sink. Defaults to /var/log/ai-tools; an
# AI_TOOLS_LOG_DIR already in the environment overrides it. Like AI_TOOLS_ALLOWLIST this is
# a root-only hook -- sudo strips it (env_reset, not in env_keep) and the handback daemon
# execs the helpers with its own environment, so neither an operator nor the agent can
# redirect the audit trail in production; only a root caller that execs a helper directly
# (the test suite) can, so a test run's helper logs land in a throwaway dir instead of the
# real trail. The journald sink is unaffected. See tests.rule.md.
readonly AI_TOOLS_LOG_DIR="${AI_TOOLS_LOG_DIR:-/var/log/ai-tools}"

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

# ai_tools_log_sanitize <text> -- reduce text to safe-for-display characters before it reaches
# a log sink or a terminal, printing the result. A default-deny **allowlist**: it keeps only
# printable ASCII (0x20-0x7E) and replaces every other byte -- the ASCII controls (ESC, the C0
# set, DEL) and every byte of a non-ASCII sequence -- with `?`. Agent-influenced filenames flow
# through the logger (a handback records the path it restored), so this stops a crafted name
# from injecting a terminal escape into a session that `cat`s the root-owned file log, forging a
# log line, or visually reordering the audit text (the Trojan-Source bidi class).
#
# Allowlist, not a blocklist, on purpose: enumerating every dangerous control/format/bidi code
# point is open-ended (Unicode keeps adding them) and needs the Unicode database the shell
# cannot reach, so it is never provably complete; permitting a known-safe set rejects every
# unknown by construction, with no maintenance. The cost is deliberate -- a legitimate
# non-ASCII filename shows as `?` in the log, while the real name stays on disk. Matching is
# byte-wise under a forced C locale (`[[:print:]]` is then 0x20-0x7E), so the result is
# locale-independent and each non-ASCII byte becomes one `?`. The handback daemon carries the
# same allowlist in Python (`_sanitize`). Retaining the control/bidi set instead as a
# malicious-attempt *detector* (quarantine-logging the probe) is a deferred idea; see the
# `## Deferred` section of logging.rule.md.
ai_tools_log_sanitize() {
    local s="$1"
    local LC_ALL=C                                # byte-wise: [[:print:]] is 0x20-0x7E only
    printf '%s' "${s//[^[:print:]]/?}"
}

# DEFERRED -- retained, not yet called. Where ai_tools_log_sanitize (the allowlist) reduces
# non-standard bytes to '?' for safe display, this is the complementary *detector*: it targets
# exactly the ASCII/Unicode control, format, and bidi bytes (C0/C1, zero-width, the
# Trojan-Source bidi overrides/isolates, line/paragraph separators, BOM), byte-wise and
# locale-independent. A sane agent never emits these in a filename or path, so their presence is
# a malicious-attempt signal worth quarantine-logging (path + which bytes) rather than silently
# reducing. Kept here so the hard-won byte set is not lost; wire it into a quarantine sink when
# that detector is built (see the `## Deferred` section of logging.rule.md).
# shellcheck disable=SC2317  # deferred: defined for a future caller, intentionally unused now
ai_tools_log_sanitize_unicode_controlchars() {
    local s="$1"
    s="${s//[[:cntrl:]]/?}"                       # C0 controls + DEL
    s="${s//$'\xc2'[$'\x80'-$'\x9f']/?}"          # C1 controls              U+0080-009F
    s="${s//$'\xc2\xad'/?}"                        # soft hyphen              U+00AD
    s="${s//$'\xd8\x9c'/?}"                        # Arabic letter mark       U+061C
    s="${s//$'\xe2\x80'[$'\x8b'-$'\x8f']/?}"       # zero-width, LRM/RLM      U+200B-200F
    s="${s//$'\xe2\x80'[$'\xa8'-$'\xae']/?}"       # line/para sep, bidi      U+2028-202E
    s="${s//$'\xe2\x81'[$'\xa0'-$'\xaf']/?}"       # word joiner, isolates    U+2060-206F
    s="${s//$'\xef\xbb\xbf'/?}"                    # BOM / ZWNBSP             U+FEFF
    s="${s//$'\xef\xbf'[$'\xb9'-$'\xbb']/?}"       # interlinear annotation   U+FFF9-FFFB
    printf '%s' "${s}"
}

# ai_tools_log <level> <message...> -- emit one leveled line to journald (always) and,
# when AI_TOOLS_LOG_FILE is set and writable, to /var/log/ai-tools/<file>. AI_TOOLS_LOG_TAG
# (default "ai-tools") becomes the journald SyslogIdentifier. Read at call time, so the
# caller may set either variable any time before logging.
ai_tools_log() {
    local level="$1"; shift
    local tag="${AI_TOOLS_LOG_TAG:-ai-tools}" prio msg raw="$*"
    prio="$(_ai_tools_log_prio "${level}")"
    # Reduce the message to safe-for-display characters before EITHER sink (see
    # ai_tools_log_sanitize). If anything was replaced, flag it inline -- a non-standard byte
    # where a filename or path is expected is worth recording as a possible probe. The marker
    # is pure ASCII, so it cannot itself re-trigger a replacement.
    msg="$(ai_tools_log_sanitize "${raw}")"
    [[ "${msg}" == "${raw}" ]] || msg="${msg}  [!] non-standard characters replaced"

    # journald via logger(1): -t sets the SyslogIdentifier, -p the facility.level
    # PRIORITY. Always attempted; failure (no logger, no journald) is ignored.
    logger -t "${tag}" -p "daemon.${prio}" -- "${msg}" 2>/dev/null || true

    # Optional root-only file sink. The umask subshell keeps a freshly created log 600.
    # AI_TOOLS_LOG_FILE is reduced to a bare basename (strip any leading path), so a value
    # carrying '/' or '..' can never escape AI_TOOLS_LOG_DIR into an arbitrary file. This is
    # defense in depth, not a live exposure: only the root helpers set the variable, each to
    # a literal like "chown.log" (a plain assignment that overwrites anything a caller
    # inherited), and an agent cannot reach a root writer's environment (the handback daemon
    # execs helpers with systemd's env, not the session's; sudo strips the caller's), while
    # the sink no-ops for a non-root caller regardless. The guard bounds a FUTURE caller that
    # might set it from less-trusted input.
    if [[ -n "${AI_TOOLS_LOG_FILE:-}" ]]; then
        local file="${AI_TOOLS_LOG_FILE##*/}"
        ( umask 077
          printf '%s %-7s [%d] %s\n' "$(date -Is)" "${level^^}" "$$" "${msg}" \
              >> "${AI_TOOLS_LOG_DIR}/${file}"
        ) 2>/dev/null || true
    fi
}

# Convenience wrappers -- prefixed to avoid colliding with callers' own log()/warn().
ai_tools_log_debug() { ai_tools_log debug   "$@"; }
ai_tools_log_info()  { ai_tools_log info    "$@"; }
ai_tools_log_warn()  { ai_tools_log warning "$@"; }
ai_tools_log_error() { ai_tools_log error   "$@"; }

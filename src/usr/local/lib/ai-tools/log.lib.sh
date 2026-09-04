#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/log.lib.sh
# Shared leveled logger for the ai-tools sandbox components. Sourced (not executed)
# by the sudo root helpers (ai-tools-chown / -setgid / -launcher-symlink / -lockdown),
# the lifecycle hooks (post-tool-hook.sh, session-hook.sh), and the ai-tools project
# CLI, so every component records DEBUG / INFO / WARNING / ERROR lines in one format
# to two sinks:
#
#   journald  -- ALWAYS. Each line goes to the systemd journal via logger(1) with a
#                per-component SyslogIdentifier (AI_TOOLS_LOG_TAG) and a syslog
#                priority matching the level, so `journalctl -t ai-tools-chown _UID=0
#                -p warning` (and friends) just work. This is the universal sink: it is
#                writable by the NON-root components (the hooks run as the agent, the
#                CLI as the projects user) which cannot write the root-only file logs --
#                and that is why a query names the writer's _UID as well as the tag. The
#                tag is chosen by whoever writes the line and ANY account reaching
#                /dev/log can write under ANY tag; _UID comes from the sender's kernel
#                credentials and cannot be set by the sender. Detail, and the per-tag
#                uid map: .claude/rules/logging.rule.md.
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
# ai_tools_log_structured adds NATIVE JOURNALD FIELDS beside the human-readable MESSAGE, for a
# record that is also read by machine (`journalctl -o json`, a journal ingester). It is OPT-IN
# and additive: ai_tools_log is unchanged, a caller passing no fields takes the identical path,
# and a host whose logger(1) predates `--journald` falls back to it. A key=value MESSAGE is only
# conventionally structured -- every consumer re-parses it and a value containing the delimiter
# is ambiguous -- whereas the native protocol delimits each field itself, so a field value cannot
# forge a sibling field, and escaping is unnecessary. Detail: .claude/rules/logging.rule.md.
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

# _ai_tools_log_prio_number <level> -- the same mapping as a NUMERIC syslog priority.
# The journald native protocol takes PRIORITY as a number (RFC 5424 severity), where the
# `logger -p` command line takes the name, so both spellings are needed. Unknown -> 6 (info).
_ai_tools_log_prio_number() {
    case "$1" in
        dbg|debug)     printf '7' ;;
        inf|info)      printf '6' ;;
        notice)        printf '5' ;;
        warn|warning)  printf '4' ;;
        err|error)     printf '3' ;;
        *)             printf '6' ;;
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
    local tag="${AI_TOOLS_LOG_TAG:-ai-tools}" prio msg
    prio="$(_ai_tools_log_prio "${level}")"
    msg="$(_ai_tools_log_render "$*")"

    # journald via logger(1): -t sets the SyslogIdentifier, -p the facility.level
    # PRIORITY. Always attempted; failure (no logger, no journald) is ignored.
    logger -t "${tag}" -p "daemon.${prio}" -- "${msg}" 2>/dev/null || true

    _ai_tools_log_write_file "${level}" "${msg}"
}

# _ai_tools_log_render <raw> -- PRINT the message as both sinks record it.
# Reduces the text to safe-for-display characters (see ai_tools_log_sanitize) and, if anything
# was replaced, flags it inline -- a non-standard byte where a filename or path is expected is
# worth recording as a possible probe. The marker is pure ASCII, so it cannot itself re-trigger
# a replacement.
_ai_tools_log_render() {
    local raw="$1" rendered
    rendered="$(ai_tools_log_sanitize "${raw}")"
    [[ "${rendered}" == "${raw}" ]] || rendered="${rendered}  [!] non-standard characters replaced"
    printf '%s' "${rendered}"
}

# _ai_tools_log_write_file <level> <rendered-message> -- append to the optional root-only file
# sink. The umask subshell keeps a freshly created log 600. AI_TOOLS_LOG_FILE is reduced to a
# bare basename (strip any leading path), so a value carrying '/' or '..' can never escape
# AI_TOOLS_LOG_DIR into an arbitrary file. This is defense in depth, not a live exposure: only
# the root helpers set the variable, each to a literal like "chown.log" (a plain assignment that
# overwrites anything a caller inherited), and an agent cannot reach a root writer's environment
# (the handback daemon execs helpers with systemd's env, not the session's; sudo strips the
# caller's), while the sink no-ops for a non-root caller regardless. The guard bounds a FUTURE
# caller that might set it from less-trusted input.
_ai_tools_log_write_file() {
    local level="$1" msg="$2" file
    [[ -n "${AI_TOOLS_LOG_FILE:-}" ]] || return 0
    file="${AI_TOOLS_LOG_FILE##*/}"
    ( umask 077
      printf '%s %-7s [%d] %s\n' "$(date -Is)" "${level^^}" "$$" "${msg}" \
          >> "${AI_TOOLS_LOG_DIR}/${file}"
    ) 2>/dev/null || true
}

# ai_tools_log_structured <level> <message> [FIELD=value ...] -- emit one line carrying both a
# human-readable MESSAGE and native journald fields, so the same record serves an operator
# reading `journalctl -t <tag>` and a machine consumer selecting on a field
# (`journalctl -o json`, or an ingester such as Seq or Vector reading the journal).
#
# WHY BOTH. A key=value MESSAGE is only conventionally structured: every consumer has to
# re-parse it, and a value containing the delimiter is ambiguous. journald's native protocol
# delimits each field itself, so a field VALUE cannot forge a sibling, and escaping is unnecessary
# field. The MESSAGE stays the authoritative human rendering and the fields are the machine
# one; callers pass both, and the two are expected to agree.
#
# OPT-IN, and identical to ai_tools_log when unused: a caller that passes fields, or a host
# whose logger(1) predates `--journald`, takes exactly the plain path above. The fallback is
# decided by ATTEMPTING the native write and falling back on its exit status rather than by
# probing logger's capabilities, so there is no cached verdict to go stale and no fork spent on
# a version check per call.
#
# FIELD NAMES ARE VALIDATED, values are reduced. A name must be [A-Z][A-Z0-9_]* -- which
# excludes the leading-underscore namespace journald reserves for the TRUSTED fields it stamps
# itself (_UID, _PID, _SYSTEMD_USER_UNIT), the very fields that make a line attributable. A
# sender cannot set those in any case (journald ignores the attempt), but refusing them here
# means a caller never believes it set one. A malformed name drops that field and keeps the
# rest: a bad label must not cost the record. Values pass ai_tools_log_sanitize, which removes
# the newline that would otherwise terminate a field early in the newline-delimited protocol,
# along with every other non-printable byte.
ai_tools_log_structured() {
    local level="$1" raw_message="$2"; shift 2
    local tag="${AI_TOOLS_LOG_TAG:-ai-tools}" priority_name priority_number message
    local field field_name field_value
    local -a journal_entry=()

    priority_name="$(_ai_tools_log_prio "${level}")"
    priority_number="$(_ai_tools_log_prio_number "${level}")"
    message="$(_ai_tools_log_render "${raw_message}")"

    # SYSLOG_FACILITY 3 is `daemon`, matching the `-p daemon.<level>` the plain path sends, so a
    # record reads the same whichever path wrote it.
    journal_entry+=( "MESSAGE=${message}" "PRIORITY=${priority_number}"
                     "SYSLOG_IDENTIFIER=${tag}" "SYSLOG_FACILITY=3" )
    for field in "$@"; do
        field_name="${field%%=*}"
        field_value="${field#*=}"
        [[ "${field}" == *=* ]] || continue
        [[ "${field_name}" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        journal_entry+=( "${field_name}=$(ai_tools_log_sanitize "${field_value}")" )
    done

    if ! printf '%s\n' "${journal_entry[@]}" | logger --journald 2>/dev/null; then
        logger -t "${tag}" -p "daemon.${priority_name}" -- "${message}" 2>/dev/null || true
    fi

    _ai_tools_log_write_file "${level}" "${message}"
}

# Convenience wrappers -- prefixed to avoid colliding with callers' own log()/warn().
ai_tools_log_debug() { ai_tools_log debug   "$@"; }
ai_tools_log_info()  { ai_tools_log info    "$@"; }
ai_tools_log_warn()  { ai_tools_log warning "$@"; }
ai_tools_log_error() { ai_tools_log error   "$@"; }

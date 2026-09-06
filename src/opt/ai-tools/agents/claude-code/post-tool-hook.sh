#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /opt/ai-tools/.claude/post-tool-hook.sh
# PostToolUse hook, dispatched on $1 the way session-hook.sh dispatches its session
# phases. Both forms record the tool call in the operator-readable trail; the
# argument-less form additionally restores operator:ai-tools ownership.
#
#   (no argument)  Write|Edit -- record the call, then hand the written file back
#   record         Bash       -- record the call only; a Bash write does not report a
#                               file_path and is swept at turn end instead
#
# Runs as ai-tools. It deliberately does NOT pre-check the approved-projects
# allowlist: that file lives under the operator's home .config (mode 700, owned by
# the operator), which ai-tools cannot traverse -- so a `[[ -f ALLOWLIST ]]`
# test here is always false and would make the hook a permanent no-op. The
# allowlist is enforced authoritatively by ai-tools-chown, which runs as root
# and CAN read it (and is the real security boundary regardless).
#
# This hook only decides, cheaply and as ai-tools, whether a handback call is
# even worth making. It exits early -- without calling the client -- when:
#   - the tool input does not contain a file path
#   - the file is not owned by ai-tools (already handed back, or never agent-written)
#
# Ownership handback is delegated to the socket privilege bridge
# (/usr/local/bin/ai-tools-handback-client), which connects to
# ai-tools-handback.socket (a root daemon) and sends a CHOWN request.  This
# replaces the former `sudo ai-tools-chown` calls, which fail silently under
# NNP (PR_SET_NO_NEW_PRIVS, forced by RestrictNamespaces=yes in the session
# service unit) because NNP drops sudo's SUID bit before it can switch uid.
#
# Deploy: sudo install -o ai-tools -g ai-tools -m 750 \
#             src/opt/ai-tools/agents/claude-code/post-tool-hook.sh /opt/ai-tools/.claude/post-tool-hook.sh

set -euo pipefail

# Shared leveled logger -- journald only (this hook runs as the agent and cannot
# write the root-only /var/log/ai-tools files; the sudo helper it calls records the
# actual file mutation there). Best-effort no-op fallback if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-hook"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../../../usr/local/lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

readonly HANDBACK_CLIENT="/usr/local/bin/ai-tools-handback-client"

# ── The tool-call record's content bound ─────────────────────────────────────────
# These two constants ARE the bound on what a session's command line can put into the
# audit trail, so they are named and stated here rather than buried as literals inside
# the jq program below. Widening either widens what the trail carries; the reasoning
# for the current values is in format_tool_call_record and pinned in logging.rule.md.
# 128 rather than a tighter figure because a PATH is the common second word (`cd <dir>`,
# `mkdir <dir>`, `dotnet build <proj>`) and a cap that truncates one mid-directory removes
# exactly the part that identifies it. This is not the bound that matters -- first-line-two-words
# already bounds the record structurally -- it is the backstop for a single pathological word
# with no whitespace in it, such as a base64 blob, so it needs only to be finite.
readonly MAX_RECORDED_WORD_LENGTH=128
readonly RECORDED_LEADING_WORD_COUNT=2

# The unit separator (0x1F) joining the parts format_tool_call_record prints. Every value is
# stripped of control characters before it is joined, so the delimiter cannot occur inside one.
readonly RECORD_FIELD_SEPARATOR=$'\037'

# format_tool_call_record <hook-event-json> -- PRINT the audit-trail record for the tool call
# this event carries, or an empty string when it cannot be read. Never fails the caller.
#
# The output is one 0x1F-delimited list: the human-readable MESSAGE first, then zero or more
# `FIELD=value` pairs for the journal's native structured fields. Both renderings are built
# here, from one parse, because they must agree -- and they are reduced differently, because
# they are read differently (see below).
#
# The line is the only trail of the agent's own ACTIONS: every other record in this system
# covers a privileged operation performed on the operator's behalf. journald is a sink the
# agent can append to but can neither edit nor delete, unlike the session transcript under
# /opt/ai-tools/.claude/projects, which the session owns and can rewrite at will.
#
# WHAT IS RECORDED, and why it stops there. For Bash: only the first two words of the
# command's FIRST LINE (each capped at MAX_RECORDED_WORD_LENGTH, a longer one marked `~`)
# plus the count of words on that line. Taking the first line excludes a here-doc body by
# construction rather than by a length cap -- `cat > f <<'EOF'` followed by a credential
# records `cmd="cat >" argc=4` and no part of the payload -- and two words keep a command
# distinguishable from its subcommand (`git log` from `git push`). Recording the full
# command line would make the trail carry unbounded file content.
#
# HOW UNTRUSTED INPUT IS REDUCED, and why the two renderings differ. Every value here is
# agent-supplied -- the tool name and the working directory as much as the command -- and both
# renderings drop control characters first (`strip_controls`), which is what makes the 0x1F
# delimiter safe to join on and removes the newline that would truncate a journal field.
#
# The MESSAGE is additionally passed through `clamp`, a narrower allowlist keeping printable
# ASCII MINUS the three characters that delimit it: space, `"` and `=`. In free prose those
# three are ordinary text -- which is why the shared logger's ai_tools_log_sanitize, a DISPLAY
# guard against terminal escapes and bidi overrides, permits them -- but in a key=value line
# they are STRUCTURE, so a word containing them forges fields: a leading word of
# `git" argc=0 cwd=/etc/passwd` would otherwise render as `cmd="git" argc=0" argc=8`, handing a
# reader the planted argc. Reducing them to `?` makes the line's shape unforgeable while leaving
# it readable, and the variable-length part is placed LAST, so no agent-controlled value
# precedes a field a reader trusts. The class spells the surviving set as its two ranges: `!`
# (0x21), `#`-`<` (0x23-0x3C, excluding space 0x20 and `"` 0x22), and `>`-`~` (0x3E-0x7E,
# excluding `=` 0x3D).
#
# The structured FIELDS need none of that narrowing: journald's native protocol delimits each
# field itself, so a value cannot forge a sibling, and escaping is unnecessary. They therefore keep
# what the MESSAGE reduces -- a path with a space stays a path with a space, where the MESSAGE
# shows `?` -- and the shared logger applies its display allowlist to each on the way out. The
# MESSAGE is the lossy human view; the fields are the faithful machine one.
#
# The length cap is the one reduction BOTH renderings take, since it bounds a pathological word
# rather than the record's shape: AI_TOOLS_CMD is capped like the MESSAGE's copy of it, while
# AI_TOOLS_PATH is not capped at all (a file path is already bounded by PATH_MAX).
#
# Extraction runs inside jq rather than the shell, so an unbounded here-doc body is never
# assigned to a shell variable on its way to being discarded.
format_tool_call_record() {
    local hook_event_json="$1"
    # shellcheck disable=SC2016  # a jq program: every $name below is a jq variable, not shell
    local record_filter='
        def strip_controls: gsub("[[:cntrl:]]"; "?");
        def clamp: gsub("[^!#-<>-~]"; "?");
        def cap: if length > $max_word_length
                 then .[0:$max_word_length] + "~" else . end;
        ((.tool_name // "?") | strip_controls | cap) as $tool_name
        | ((.cwd // "-") | strip_controls) as $working_directory
        | (if $tool_name == "Bash"
           then ([ ((.tool_input.command // "")
                    | split("\n") | (.[0] // "") | scan("[^ \t]+")) ]) as $command_words
                | ($command_words[0:$leading_word_count]
                   | map(strip_controls | cap)) as $leading_words
                | ($command_words | length | tostring) as $word_count
                | [ "cmd=\"" + ($leading_words | map(clamp) | join(" "))
                    + "\" argc=" + $word_count,
                    "AI_TOOLS_CMD=" + ($leading_words | join(" ")),
                    "AI_TOOLS_ARGC=" + $word_count ]
           else ((.tool_input.file_path // "-") | strip_controls) as $written_path
                | [ "path=" + ($written_path | clamp),
                    "AI_TOOLS_PATH=" + $written_path ]
           end) as $tool_detail
        | [ "tool=" + ($tool_name | clamp)
            + " cwd=" + ($working_directory | clamp)
            + " " + $tool_detail[0],
            "AI_TOOLS_TOOL=" + $tool_name,
            "AI_TOOLS_CWD=" + $working_directory ]
          + $tool_detail[1:]
        | join($separator)'

    jq -j --argjson max_word_length "${MAX_RECORDED_WORD_LENGTH}" \
          --argjson leading_word_count "${RECORDED_LEADING_WORD_COUNT}" \
          --arg separator "${RECORD_FIELD_SEPARATOR}" \
          "${record_filter}" <<< "${hook_event_json}" 2>/dev/null || return 1
}

# record_tool_call <hook-event-json> -- emit the audit-trail line for this event.
#
# A record that cannot be built is never guessed at -- an unreadable event is not evidence of
# what ran -- but neither is it passed over in silence. Silence here is ambiguous in the one
# direction that matters: a reader of a trail with no lines in it cannot tell "this session
# ran no tools" from "the recorder was broken or bypassed", and the second reads as the first,
# which is worse than no trail at all because it manufactures confidence. So a failure to
# record is itself recorded, at WARNING, naming the gap. The reason is resolved only on the
# failure path, so the common case does not pay for it, and `jq` is singled out because its
# absence degrades every hook in the session (handback and sweeps included), not just this
# line -- that is a host-level fault an operator must see, not a parse hiccup.
record_tool_call() {
    local hook_event_json="$1" formatted_record="" failure_reason=""
    local -a record_parts=()
    if formatted_record="$(format_tool_call_record "${hook_event_json}")" \
            && [[ -n "${formatted_record}" ]]; then
        # Element 0 is the human-readable MESSAGE; the rest are FIELD=value pairs for the
        # journal's structured fields, which the shared logger validates and reduces.
        # printf, not a here-string: a here-string appends a newline, which would ride along on
        # the final field's value.
        mapfile -t -d "${RECORD_FIELD_SEPARATOR}" record_parts \
            < <(printf '%s' "${formatted_record}")
        ai_tools_log_structured info "${record_parts[0]}" "${record_parts[@]:1}"
        return 0
    fi
    failure_reason="the event JSON could not be parsed"
    command -v jq >/dev/null 2>&1 \
        || failure_reason="jq is not installed, so every hook in this session is degraded"
    ai_tools_log_warn "tool call NOT recorded (${failure_reason}) -- this is a gap in the trail"
}

# hand_back_written_path <hook-event-json> -- restore operator ownership of the file this
# Write/Edit produced, and of any parent directory the write itself created.
#
# The handback call is made only for a path the agent itself wrote -- one currently owned by
# @SANDBOX_USER@ -- which is exactly the set ai-tools-chown will act on (its own owner guard)
# and the same signal the parent-dir walk uses, so an already-handed-back file
# (operator-owned, or a quarantined secret) does not call the socket. The root-owned validator
# does the real work: it checks the allowlist (as root, which can read it), chowns + strips
# world bits, and for secret-named files revokes ai-tools access and prints a NOTICE. That
# stderr is deliberately NOT redirected to /dev/null, so Claude Code surfaces the NOTICE in
# the session.
hand_back_written_path() {
    local hook_event_json="$1" written_file_path="" current_owner_name="" parent_directory=""

    written_file_path="$(jq -r '.tool_input.file_path // empty' \
        <<< "${hook_event_json}" 2>/dev/null)" || return 0
    [[ -n "${written_file_path}" ]] || return 0

    current_owner_name="$(stat -c '%U' "${written_file_path}" 2>/dev/null || true)"
    if [[ "${current_owner_name}" == "@SANDBOX_USER@" ]]; then
        ai_tools_log_debug "PostToolUse handing back ${written_file_path} (owner ${current_owner_name})"
        "${HANDBACK_CLIENT}" CHOWN "${written_file_path}" || true
    fi

    # Normalize any directories the write just created. Claude Code's Write tool makes
    # missing parent dirs owned by ai-tools at the agent's umask -- often world-traversable
    # and never handed back. Walk upward from the file's directory and hand back each
    # ai-tools-owned dir, stopping at the first dir the agent does NOT own: that is the
    # pre-existing user tree (the project root and above, which is <you>-owned), so the walk
    # never leaves the project. The common case -- writing into an existing dir -- breaks on
    # the first iteration with no socket call. ai-tools-chown re-validates each path against
    # the allowlist as root.
    parent_directory="$(dirname -- "${written_file_path}")"
    while [[ "${parent_directory}" != "/" && "${parent_directory}" != "." ]]; do
        [[ "$(stat -c '%U' "${parent_directory}" 2>/dev/null || true)" == "@SANDBOX_USER@" ]] || break
        "${HANDBACK_CLIENT}" CHOWN "${parent_directory}" || true
        parent_directory="$(dirname -- "${parent_directory}")"
    done
    return 0
}

main() {
    local hook_invocation_mode="${1-}" hook_event_json=""

    # An empty stdin is not a tool call the harness made: it means this hook ran outside the
    # session that feeds it (a hand invocation, a misconfigured declaration). Say so rather
    # than exiting mute, for the same reason record_tool_call reports its gaps -- but at the
    # lower level, since no record was lost from the trail here; there was no call to record.
    hook_event_json="$(cat)" || return 0
    if [[ -z "${hook_event_json}" ]]; then
        ai_tools_log_info "PostToolUse invoked with no event on stdin -- nothing to record or hand back"
        return 0
    fi

    record_tool_call "${hook_event_json}"

    # The Bash form records and stops: a Bash-created file does not report a file_path, so there is
    # no path for the handback to act on (the Stop sweep catches those at turn end).
    if [[ "${hook_invocation_mode}" == "record" ]]; then
        return 0
    fi

    hand_back_written_path "${hook_event_json}"
}

main "$@"

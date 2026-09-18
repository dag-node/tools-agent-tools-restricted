#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /opt/ai-tools/.codex/post-tool-hook.sh
# PostToolUse hook for codex, declared on every tool in /etc/codex/requirements.toml. It records the tool call
# in the operator-readable trail, and for an `apply_patch` call it additionally hands the files the patch names back
# to operator:ai-tools ownership. Codex's payload differs from claude's in the write tool: there is no Write|Edit
# carrying a `file_path`; a file write is an `apply_patch` whose `tool_input` carries the whole patch text under one
# of three keys (see PATCH_TOOL_NAME), so the paths are read out of the patch's `*** Add File:` / `*** Update File:` /
# `*** Delete File:` lines. A `Bash` call carries `tool_input.command`, the same key as claude's, and is recorded
# alone: a Bash-created file does not name a path here and is swept at turn end (the Stop hook) or at session end (the
# shim's sweep).
#
# Runs as ai-tools. It deliberately does NOT pre-check the approved-projects allowlist: that file lives
# under the operator's home .config (mode 700, owned by the operator), which ai-tools cannot traverse --
# so a `[[ -f ALLOWLIST ]]` test here is always false and would make the hook a permanent no-op. The allowlist is
# enforced authoritatively by ai-tools-chown, which runs as root and CAN read it (and is the real security boundary
# regardless).
#
# This hook only decides, as ai-tools and from one stat per path, whether a handback call is worth making. It exits
# early -- without calling the client -- when the patch does not name a path, or the path is not owned by ai-tools
# (already handed back, deleted by the patch, or never agent-written).
#
# Ownership handback is delegated to the socket privilege bridge (/usr/local/bin/ai-tools-handback-client),
# which connects to ai-tools-handback.socket (a root daemon) and sends a CHOWN request. A `sudo ai-tools-chown` call
# cannot serve here: the session runs under NNP (PR_SET_NO_NEW_PRIVS, forced by RestrictNamespaces=yes in the session
# service unit), which drops sudo's SUID bit before it can switch uid, so the call fails silently.
#
# Installed 750 root:ai-tools: the session executes it through the group and cannot rewrite it, which is what keeps
# the handback it performs out of the agent's control (see ownership-and-hooks.rule.md). Sourced by its unit test
# to reach the parsers, which is what the guard at the end is for.

set -euo pipefail

# Shared leveled logger -- journald only (this hook runs as the agent and cannot write the root-only /var/log/ai-tools
# files; the root helper it calls records the actual file mutation there). Best-effort no-op fallback if the lib is
# missing.
AI_TOOLS_LOG_TAG="ai-tools-hook"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../../../usr/local/lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

readonly HANDBACK_CLIENT="/usr/local/bin/ai-tools-handback-client"

# ── The tool-call record's content bound ─────────────────────────────────────────
# These two constants ARE the bound on what a session's command line can put into the audit trail, so they are named
# here rather than buried as literals inside the jq program itself: widening either widens what the trail carries. Two
# words keep a command distinguishable from its subcommand (`git log` from `git push`); the cap is a backstop
# for a single pathological word with no whitespace in it, such as a base64 blob, so it only has to be finite.
# What the bound covers, and why it is not to be widened, is in logging.rule.md.
readonly MAX_RECORDED_WORD_LENGTH=128
readonly RECORDED_LEADING_WORD_COUNT=2

# The unit separator (0x1F) joining the parts format_tool_call_record prints. Every value is stripped of control
# characters before it is joined, so the delimiter cannot occur inside one.
readonly RECORD_FIELD_SEPARATOR=$'\037'

# The one line of the apply_patch grammar that names a file. Held here once and handed to both jq programs, so the path
# the record reports and the paths the handback acts on are read by the same rule. A `*** Move to:` line renames the
# file the preceding `*** Update File:` named; the new name is what exists after the call, so it is read too.
readonly PATCH_FILE_LINE='^\*\*\* (Add File|Update File|Delete File|Move to): (?<path>.+)$'

# The tool codex writes files with. Its `tool_input` key is read as every spelling the vendor has used for the patch
# text -- `input`, `patch`, and `command`, which is what codex 0.154 sends when the model reaches the tool through code
# mode -- so a rename between releases degrades to "no path" (swept at turn end) rather than to a parse failure. The key
# is shared with `Bash`, whose value is a shell command rather than a patch; the two never meet, because the tool
# name selects the branch before the key is read, and a value that is not patch text does not match the `*** ... File:` line.
readonly PATCH_TOOL_NAME="apply_patch"

# format_tool_call_record <hook-event-json> -- PRINT the audit-trail record for the tool call this event carries,
# or an empty string when it cannot be read. Never fails the caller.
#
# The output is one 0x1F-delimited list: the human-readable MESSAGE first, then zero or more `FIELD=value` pairs
# for the journal's native structured fields. Both are built here from one parse, so they agree, and both drop control
# characters (`strip_controls`) -- which is what makes the 0x1F delimiter safe to join on and removes the newline
# that would truncate a journal field. What each rendering carries, and why the MESSAGE is reduced further than
# the fields, is in logging.rule.md.
#
# Two things local to this implementation. `clamp` spells the MESSAGE's narrower allowlist as the ranges that survive
# it: `!` (0x21), `#`-`<` (0x23-0x3C, excluding space 0x20 and `"` 0x22), and `>`-`~` (0x3E-0x7E, excluding `=` 0x3D).
# And extraction runs inside jq rather than the shell: the event arrives in one shell variable (main's read of stdin)
# and every value derived from it -- the path list, the count, the clamped message -- is produced by jq from that one
# copy, so an unbounded patch body is never re-split, re-joined, or copied per path it names. An apply_patch record
# carries the FIRST path and, past one, the count, so the line stays one path wide whatever the patch touched.
format_tool_call_record() {
    local hook_event_json="$1"
    # shellcheck disable=SC2016  # a jq program: every $name in it is a jq variable, not shell
    local record_filter='
        def strip_controls: gsub("[[:cntrl:]]"; "?");
        def clamp: gsub("[^!#-<>-~]"; "?");
        def cap: if length > $max_word_length
                 then .[0:$max_word_length] + "~" else . end;
        def patch_paths: [ (.tool_input.input // .tool_input.patch // .tool_input.command // "")
                           | split("\n")[] | capture($patch_file_line) | .path ];
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
           elif $tool_name == $patch_tool_name
           then patch_paths as $paths
                | (($paths[0] // "-") | strip_controls) as $written_path
                | [ "path=" + ($written_path | clamp)
                    + (if ($paths | length) > 1
                       then " files=" + ($paths | length | tostring) else "" end),
                    "AI_TOOLS_PATH=" + $written_path ]
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
          --arg patch_file_line "${PATCH_FILE_LINE}" \
          --arg patch_tool_name "${PATCH_TOOL_NAME}" \
          "${record_filter}" <<< "${hook_event_json}" 2>/dev/null || return 1
}

# record_tool_call <hook-event-json> -- emit the audit-trail line for this event.
#
# An event the parse does not turn into a record is recorded as a gap instead, at WARNING, rather than passed over --
# logging.rule.md carries why an empty trail is the one ambiguity that matters. The reason is resolved only
# on the failure path, so the common case does not pay for it, and a missing `jq` is named separately because it
# degrades every hook in the session (handback and sweeps included) rather than this line alone.
record_tool_call() {
    local hook_event_json="$1" formatted_record="" failure_reason=""
    local -a record_parts=()
    if formatted_record="$(format_tool_call_record "${hook_event_json}")" \
            && [[ -n "${formatted_record}" ]]; then
        # Element 0 is the human-readable MESSAGE; the rest are FIELD=value pairs for the journal's structured fields,
        # which the shared logger validates and reduces. printf, not a here-string: a here-string appends a newline,
        # which would ride along on the final field's value.
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

# patch_written_paths <hook-event-json> -- PRINT, one per line, the absolute path of every file an apply_patch event
# names, or no line when the event is not one. A relative path is joined to the event's `cwd`, the directory codex
# applied the patch in; a path already absolute is kept. A patch line ends at a newline, so a path cannot carry one
# and one-per-line is unambiguous. Never fails the caller.
patch_written_paths() {
    local hook_event_json="$1"
    # shellcheck disable=SC2016  # a jq program: every $name in it is a jq variable, not shell
    local paths_filter='
        select((.tool_name // "") == $patch_tool_name)
        | (.cwd // "") as $cwd
        | (.tool_input.input // .tool_input.patch // .tool_input.command // "")
        | split("\n")[] | capture($patch_file_line) | .path
        | select(length > 0)
        | if startswith("/") or $cwd == "" then . else $cwd + "/" + . end'
    jq -r --arg patch_file_line "${PATCH_FILE_LINE}" --arg patch_tool_name "${PATCH_TOOL_NAME}" \
        "${paths_filter}" <<< "${hook_event_json}" 2>/dev/null || return 0
}

# hand_back_patch_paths <hook-event-json> -- restore operator ownership of each file an apply_patch produced, and of any
# parent directory the patch itself created.
#
# The call is made only for a path currently owned by @SANDBOX_USER@ -- the same set ai-tools-chown will act
# on under its own owner guard, and the same signal the parent-dir walk uses -- so an already-handed-back file
# (operator-owned, or a quarantined secret), and a path the patch deleted, do not reach the socket. The root-owned
# validator does the real work, the allowlist check only it can read included. Its stderr is deliberately NOT redirected
# to /dev/null, so a secret-file NOTICE reaches the agent's session.
hand_back_patch_paths() {
    local hook_event_json="$1" written_file_path="" parent_directory=""

    while IFS= read -r written_file_path; do
        [[ -n "${written_file_path}" ]] || continue
        if [[ "$(stat -c '%U' "${written_file_path}" 2>/dev/null || true)" == "@SANDBOX_USER@" ]]; then
            ai_tools_log_debug "PostToolUse handing back ${written_file_path}"
            "${HANDBACK_CLIENT}" CHOWN "${written_file_path}" || true
        fi

        # Normalize any directories the patch just created: an Add File makes missing parent dirs owned by ai-tools
        # at the agent's umask, often world-traversable, and no event carries their paths. Walk upward from the file's
        # directory, handing back each ai-tools-owned dir and stopping at the first dir the agent does NOT own --
        # the pre-existing user tree (the project root and its ancestors, <you>-owned) -- so the walk stays inside
        # the project. Writing into an existing dir, the common case, breaks on the first iteration with no socket call.
        # ai-tools-chown re-validates each path as root.
        parent_directory="$(dirname -- "${written_file_path}")"
        while [[ "${parent_directory}" != "/" && "${parent_directory}" != "." ]]; do
            [[ "$(stat -c '%U' "${parent_directory}" 2>/dev/null || true)" == "@SANDBOX_USER@" ]] || break
            "${HANDBACK_CLIENT}" CHOWN "${parent_directory}" || true
            parent_directory="$(dirname -- "${parent_directory}")"
        done
    done < <(patch_written_paths "${hook_event_json}")
    return 0
}

main() {
    local hook_event_json=""

    # An empty stdin is not a tool call the harness made: it means this hook ran outside the session that feeds it (a
    # hand invocation, a misconfigured declaration). Say so rather than exiting mute, for the same reason
    # record_tool_call reports its gaps -- but at the lower level, since no record was lost from the trail here; there
    # was no call to record.
    hook_event_json="$(cat)" || return 0
    if [[ -z "${hook_event_json}" ]]; then
        ai_tools_log_info "PostToolUse invoked with no event on stdin -- nothing to record or hand back"
        return 0
    fi

    record_tool_call "${hook_event_json}"
    hand_back_patch_paths "${hook_event_json}"
}

# When this file is SOURCED rather than executed (its unit test loads it to drive the record and the patch parser
# on captured payloads), stop here: expose the functions and read no event. On execution BASH_SOURCE[0] equals $0,
# so this is a no-op and the hook proceeds.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

main "$@"

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/session-sweep.lib.sh
# The sandbox housekeeping each agent's session-hook.sh runs at lifecycle boundaries (Stop, SessionStart, SessionEnd).
# The stub sources this library and calls ai_tools_session_sweep__run with its mode and its own directory, which holds
# the state files. The sweep hands back every @SANDBOX_USER@-owned file and directory under the session's project
# that the per-call PostToolUse hook did not catch -- chiefly files created or modified via the Bash tool (npm/build
# output, codegen, sed/mv, redirects), which name no path in their event -- and, at session start, normalizes
# the project's setgid bit (via ai-tools-setgid) so files the projects user creates inherit @SANDBOX_GROUP@.
#
# Runs as @SANDBOX_USER@. Reads the hook JSON on stdin for .cwd (the allowlisted project root the agent launched
# in) and sweeps there. Each path is handed to the root validator ai-tools-chown (via the handback socket bridge),
# which independently re-checks the allowlist and the agent-owned guard -- so this sweep cannot reach a path
# the per-call hook could not. Each agent's Stop and SessionStart payloads carry .cwd and .source under the same keys,
# so the reading is the same for every agent.
#
# Three modes, selected by the stub's $1:
#
#   stop          (default) -- Stop hook, fires at each turn's end. Bounded by a
#                 timestamp marker: only paths whose status changed since the previous sweep
#                 are processed, so the turn-end pass stays cheap. It is a turn-end
#                 net, NOT a per-tool action -- handing a file back makes it
#                 <you>:@SANDBOX_GROUP@ 640 (group @SANDBOX_GROUP@ loses write), which would break
#                 an in-progress Bash sequence editing a file in place. Running at
#                 Stop avoids that: the agent keeps ownership mid-turn, handback
#                 happens once control returns.
#
#   session-start -- SessionStart hook, fires when a session begins. UNBOUNDED:
#                 ignores the marker and sweeps every @SANDBOX_USER@-owned path, then
#                 resets the marker to "now". This reclaims leftovers from a prior
#                 session that was killed (crash, kill -9, closed terminal) before
#                 its Stop sweep could run -- the one gap the Stop net cannot close
#                 itself. It ALSO reclaims the project's .git, which every sweep
#                 skips (see the .git reclaim). Gated on the hook's .source: only "startup"
#                 and "resume" (a freshly started process, which is what can follow
#                 an interrupted session) trigger the pass. Any other source stays
#                 within a live process whose Stop sweeps already cover the tree,
#                 so it is a no-op (and skips an otherwise pointless full-tree
#                 walk on every compaction).
#
#   session-end   -- SessionEnd hook, fires once when the process exits
#                 gracefully. Removes the clean-exit marker (.session-active) FIRST and
#                 then reclaims this project's .git: the session is over, so no live git
#                 command is there to disturb. That marker is written at session-start
#                 and cleared here; if it instead SURVIVES into the next session-start,
#                 the previous session was killed before this ran (tokens
#                 exhausted, crash, closed terminal). A surviving marker widens the
#                 .git reclaim (which runs every session-start) to the killed
#                 session's recorded cwd -- which may be a different project -- and is
#                 what raises the SessionStart NOTICE: only the interrupted case emits
#                 one (framed via msg.lib.sh), while the routine post-git-activity
#                 reclaim is logged to journald alone so it never clobbers the agent's
#                 startup banner.
#
# .git reclaim: every sweep SKIPS .git for cost, so @SANDBOX_USER@-owned objects the agent writes there via `git commit`
# (Bash tool -> no path in the event) are never handed back by the sweep, on a graceful exit as much as a killed one --
# leaving .git in mixed ownership, which makes git report "dubious ownership". The unbounded session-start pass
# and the session-end pass therefore reclaim .git; a per-turn Stop reclaim is avoided (it would change ownership
# mid-turn under a live git command).
#
# Heavy/transient trees are skipped in both sweeping modes (their contents are world-readable anyway, so <you> can
# already read them) and the scan stays on one filesystem (`-xdev`).
#
# Handback socket down: every CHOWN runs over _AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET, so a socket that is not
# listening fails every hand-back. Each pass checks the socket first and, when it is down, skips its walk, leaves
# the sweep marker where it was and records the STRANDED count rather than tallying failed calls --
# and the session-start pass emits a distinct NOTICE naming the fix instead of a reassuring "Reclaimed N". Every pass
# otherwise counts CONFIRMED hand-backs (client exit 0), not attempts, and logs the calls that failed in one warning.
# The socket is a data-ownership convenience, not a confinement boundary (the user:<operator> ACL keeps <you> reading
# agent files regardless), so this warns and proceeds -- it never blocks a session.
#
# The state files (.sweep-marker, .session-active) live in the directory the stub passes, its own -- the agent's config
# directory, whose name its manifest declares -- so this library does not name an agent (ownership-and-hooks.rule.md).
# The mode reaches _ai_tools_session_sweep__sweep_project as its fourth argument, for its log lines. Installed 644
# root:root; the stub that sources it is root-owned and not agent-writable, so the session cannot rewrite either.
# ai_tools_session_sweep__run is the one public member; every other member is private, and the tests that reassign
# the private client and socket globals after sourcing (tests/unit/sweep-bound.sh) are why those are not readonly.

# shellcheck disable=SC2034  # include guard, read on the next source of this lib
if [[ -n "${_AI_TOOLS_SESSION_SWEEP__LOADED:-}" ]]; then return 0; fi
readonly _AI_TOOLS_SESSION_SWEEP__LOADED=1

# The root-op client every CHOWN and SETGID goes through, and the socket it talks to. Literals rather than environment
# reads: a project's agent settings reach a hook's environment, and neither path may be the session's to choose.
_AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT=/usr/local/bin/ai-tools-handback-client
_AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET=/run/ai-tools/handback.sock

# Shared leveled logger -- journald only (this hook runs as the agent and cannot write the root-only /var/log/ai-tools
# files; the root helpers it calls record the actual file mutations there). Best-effort no-op fallback if the lib is
# missing.
AI_TOOLS_LOG_TAG="ai-tools-hook"
# shellcheck source=SCRIPTDIR/log.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/log.lib.sh" 2>/dev/null; then
    ai_tools_log__write() { :; }; ai_tools_log__debug() { :; }; ai_tools_log__info() { :; }
    ai_tools_log__warn() { :; }; ai_tools_log__error() { :; }
    # The sanitizer is not one of the emitters, so its fallback is not a no-op: this hook puts a path into a NOTICE
    # the model reads, and that path comes from an agent-written marker. The allowlist is the library's
    # (ai_tools_log__sanitize) -- printable ASCII, every other byte replaced -- kept working rather than degraded,
    # because a hook that only emits must not fail closed and must not emit a raw escape sequence either.
    ai_tools_log__sanitize() { local LC_ALL=C; printf '%s' "${1//[^[:print:]]/?}"; }
fi

# Shared message formatter -- frames the SessionStart NOTICE in the paste-safe '#' box, wrapped within 80 columns.
# The one msg.lib consumer that keeps a fallback: every other consumer requires the lib (it carries their yes/no
# decisions and their runs may fail closed), but this library only EMITS, and its sweep is itself the safety action --
# the handback must run even on an install broken enough to lose the formatter, so a missing lib degrades the notice
# to plain text instead of stopping the sweep (see messaging.rule.md).
# shellcheck source=SCRIPTDIR/msg.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/msg.lib.sh" 2>/dev/null; then
    ai_tools_msg__alert() { shift 2; printf '%s\n' "$@"; }
    ai_tools_msg__wrap() { shift; printf '%s\n' "$*"; }
fi

# Directory-skip selector from the shared library (single source of truth, shared with ai-tools-setgid /
# ai-tools-lockdown). A missing lib leaves a stub that descends everywhere.
# shellcheck source=SCRIPTDIR/skip-dirs.lib.sh
source "${BASH_SOURCE[0]%/*}/skip-dirs.lib.sh" 2>/dev/null \
    || ai_tools_skip_dirs__build_find_expression() { AI_TOOLS_SKIP_DIRS__FIND_EXPRESSION=(); return 0; }

# _ai_tools_session_sweep__emit_session_context <text> -- hand <text> to the agent as the session's additional context,
# in the `hookSpecificOutput` envelope and in that spelling alone. Claude Code reads the envelope; codex 0.154 rejects
# a reply carrying the top-level `additionalContext` key its own hook contract names: measured one shape per session,
# the envelope read `SessionStart Completed` while the top-level key and the two keys together each read
# `SessionStart Failed`, which loses the whole reply rather than the unknown key. A release that moves the key is
# a failed hook line in every session that has something to report, so the shape is re-measured rather than carried
# in two spellings. Best-effort: a jq failure emits nothing rather than half a reply.
_ai_tools_session_sweep__emit_session_context() {
    jq -cn --arg ctx "$1" \
        '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' \
        2>/dev/null || true
}

# _ai_tools_session_sweep__quote_path <path> -- print <path> as one bash word for a command a warning or the NOTICE
# carries. `printf %q` encodes a byte the locale calls non-printable and leaves the rest raw, so it runs under the C
# locale, where every byte outside printable ASCII is encoded: bash reads the word back as the same path under any
# locale, the logger's sanitizer (which replaces a byte outside printable ASCII) leaves the word as written,
# and a Unicode control in a directory name reaches the model as its escape. The hook inherits the operator's locale
# through ai-tools-run's environment allowlist. The path is encoded as it is, never sanitized first: the command has
# to name the directory that exists.
_ai_tools_session_sweep__quote_path() {
    local LC_ALL=C
    printf '%q' "$1"
}

# _ai_tools_session_sweep__reclaim_git_tree <project> -- hand every ai-tools-owned path under <project>/.git
# to ai-tools-chown, which re-validates the allowlist, exclusions and secret rules exactly as the sweep does. Echoes
# the count of paths processed on stdout. The client writes only to stderr -- MSG relays of the helper's stderr, and its
# own errors -- and leaves stdout empty, so it cannot corrupt this function's captured count or the JSON the hook emits.
# No <project>/.git -> echo 0. Used by the session-end reclaim and the session-start pass.
_ai_tools_session_sweep__reclaim_git_tree() {
    local proj="$1" n=0 path
    # Socket down: no path can be handed back -- report zero, not a count of failed calls.
    [[ -S "${_AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET}" ]] || { printf '0'; return 0; }
    if [[ -n "${proj}" && -d "${proj}/.git" ]]; then
        while IFS= read -r -d '' path; do
            # Count CONFIRMED handbacks (client exit 0), not attempts, so the reported total reflects what changed
            # owner.
            if "${_AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT}" CHOWN "${path}"; then
                n=$((n + 1))
            fi
        done < <(find "${proj}/.git" -xdev -user @SANDBOX_USER@ \
                     \( -type f -o -type d \) -print0 2>/dev/null)
    fi
    printf '%s' "${n}"
}

# _ai_tools_session_sweep__read_prior_cwd <marker> -- PRINT the project a prior session recorded, or an empty string.
# The marker sits in the group-writable config directory, so its first line is AGENT-WRITTEN, and it decides which tree
# the cross-project .git reclaim walks. It is accepted only as an existing directory named by an absolute path,
# so a crafted line costs that one reclaim and cannot aim a walk at something that is not a project; the root helper
# re-validates every path either way. The path does not reach the model: the interrupted-session NOTICE names a prior
# project without printing its path, since under one shared config directory that project may be another operator's.
_ai_tools_session_sweep__read_prior_cwd() {
    local marker="${1:-}" recorded
    [[ -f "${marker}" ]] || return 0
    recorded="$(head -n1 "${marker}" 2>/dev/null || true)"
    [[ -n "${recorded}" ]] || return 0
    if [[ "${recorded}" != /* || ! -d "${recorded}" ]]; then
        ai_tools_log__warn "session-start: the clean-exit marker does not name a directory -- no cross-project reclaim (${recorded})"
        return 0
    fi
    printf '%s' "${recorded}"
}

# _ai_tools_session_sweep__count_git_agent_owned <project> -- number of @SANDBOX_USER@-owned paths under <project>/.git
# (0 if there is no such tree). Used only when the socket is down, to tell whether there is stranded git work to warn
# about.
_ai_tools_session_sweep__count_git_agent_owned() {
    local proj="$1"
    [[ -n "${proj}" && -d "${proj}/.git" ]] || { printf '0'; return 0; }
    find "${proj}/.git" -xdev -user @SANDBOX_USER@ \( -type f -o -type d \) -printf '.' 2>/dev/null | wc -c
}

# _ai_tools_session_sweep__sweep_project <project> <marker> <unbounded 0|1> <mode> -- hand every @SANDBOX_USER@-owned
# path under <project> to ai-tools-chown, bounded by <marker> unless <unbounded> is 1, and print the count of confirmed
# handbacks on stdout. <mode> names the pass in its log lines. Returns 0 after a walk, and 1 when the socket was
# down and no path was offered.
_ai_tools_session_sweep__sweep_project() {
    local dir="$1" marker="$2" unbounded="$3" mode="$4"
    local bounded=0 swept=0 failed=0 path below quoted
    # The project as a command argument, for the remedy a warning prints (the %q form, as the NOTICE carries it).
    quoted="$(_ai_tools_session_sweep__quote_path "${dir}")"
    # `find DIR -xdev \( skip heavy trees \) -prune -o \( ai-tools-owned [cnewer] file|dir \) -print0`
    ai_tools_skip_dirs__build_find_expression sweep '' "${dir}"
    local -a expr=( "${dir}" -xdev "${AI_TOOLS_SKIP_DIRS__FIND_EXPRESSION[@]}" '(' -user @SANDBOX_USER@ )
    # Bound to paths whose status changed since the marker, EXCEPT an unbounded (session-start) pass, which sweeps every
    # ai-tools-owned path. A first-ever stop run (no marker) is likewise a full sweep. The bound reads ctime, so a file
    # moved into the tree is selected (ownership-and-hooks.rule.md). A path handed back is no longer ai-tools-owned,
    # so its new ctime does not select it again. A directory moved in keeps its descendants' ctimes, so the bound
    # selects the directory alone; each directory a bounded pass selects is walked once more without the bound
    # (descendant_expr), each path is offered once, and a directory an earlier walk reached is not walked again.
    if [[ "${unbounded}" -eq 0 && -f "${marker}" ]]; then
        expr+=( -cnewer "${marker}" )
        bounded=1
    fi
    expr+=( '(' -type f -o -type d ')' -print0 ')' )
    local -a descendant_expr=( -mindepth 1 -xdev "${AI_TOOLS_SKIP_DIRS__FIND_EXPRESSION[@]}" '(' -user @SANDBOX_USER@ \
        '(' -type f -o -type d ')' -print0 ')' )

    # Delegate each path to the root validator. </dev/null keeps ai-tools-chown on its non-interactive branch. The find
    # reads via process substitution (not a pipe) so the count survives the loop; a find non-zero (e.g. an unreadable
    # subdir) only ends the stream and cannot trip `set -e` / pipefail or skip the marker update.
    ai_tools_log__debug "${mode} sweep: handing back agent-owned paths under ${dir}$([[ "${unbounded}" -eq 1 ]] && echo ' (unbounded)' || echo ' (since marker)')"
    if [[ ! -S "${_AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET}" ]]; then
        # Socket down: every CHOWN would fail, so skip the walk and record it once. Counting the failed calls would also
        # mis-fire the large-batch skip-list hint.
        ai_tools_log__warn "${mode} sweep skipped: handback socket ${_AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET} is down -- paths under ${dir} stay @SANDBOX_USER@-owned (reclaim with: ai-tools projects handback ${quoted})"
        printf '%s\n' "${swept}"
        return 1
    fi

    # Count CONFIRMED handbacks (client exit 0), not attempts, and the calls that failed apart from them.
    local -A offered=()
    while IFS= read -r -d '' path; do
        # A path an earlier walk offered sits under a directory that walk covered whole, so it is not walked again.
        [[ -z "${offered[${path}]+x}" ]] || continue
        offered["${path}"]=1
        if "${_AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT}" CHOWN "${path}"; then
            swept=$((swept + 1))
        else
            failed=$((failed + 1))
        fi
        (( bounded )) && [[ -d "${path}" && ! -L "${path}" ]] || continue
        while IFS= read -r -d '' below; do
            [[ -z "${offered[${below}]+x}" ]] || continue
            offered["${below}"]=1
            if "${_AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT}" CHOWN "${below}"; then
                swept=$((swept + 1))
            else
                failed=$((failed + 1))
            fi
        done < <(find "${path}" "${descendant_expr[@]}" 2>/dev/null) || true
    done < <(find "${expr[@]}" 2>/dev/null) || true

    # A failed call is a helper refusal or a socket lost mid-walk, which the client's exit does not tell apart.
    if [[ "${failed}" -gt 0 ]]; then
        ai_tools_log__warn "${mode} sweep: ${failed} path(s) under ${dir} not handed back -- the helper refused them or the socket stopped answering mid-walk; reclaim with: ai-tools projects handback ${quoted}"
    fi

    # A large sweep is the skip-list signal: hundreds of agent-owned paths per pass usually means a build or dependency
    # tree is handed back over and over. Journald-only (routine, no action for the operator in-session); the operator
    # tunes the skip categories.
    if [[ "${swept}" -ge 200 ]]; then
        ai_tools_log__info "${mode} sweep: handed back ${swept} paths -- a recurring build tree can be skipped via SKIP_ARTIFACT_DIRS in /etc/ai-tools/operator.conf (reference: /usr/local/lib/ai-tools/skip-dirs.lib.sh)"
    fi
    printf '%s\n' "${swept}"
}

# ai_tools_session_sweep__run <mode> <state_dir> -- the hook: read the event on stdin once, run the pass <mode> selects
# ("stop", "session-start" or "session-end"), and print the SessionStart reply, if any, on stdout. <state_dir> holds
# the sweep marker and the clean-exit marker. Returns 0 on every path, so a hook never fails the agent's turn.
ai_tools_session_sweep__run() {
    local mode="${1:-stop}" state_dir="$2"
    local marker="${state_dir}/.sweep-marker"
    # Clean-exit marker: written at session-start (process birth), removed at session-end (graceful exit). Surviving
    # into the next session-start means the previous session was killed before its SessionEnd ran -- the signal
    # for the deep .git reclaim. Global, not per-project (mirrors the sweep marker); it records the prior session's cwd
    # so the deep reclaim can target that project. Under concurrent sessions the single marker races (a second start
    # sees the first's marker as "interrupted"); the sandbox is single-session by design, same caveat as the sweep
    # marker.
    local active_marker="${state_dir}/.session-active"
    local end_payload end_cwd end_found payload dir display_dir quoted_dir src unbounded interrupted prev_cwd scan_start
    local git_found prev_found total_found scope prose reconcile stranded

    # session-end: graceful process exit. Clear the clean-exit marker FIRST -- codex kills this hook at 3 s,
    # and a cleared marker is what keeps the next session-start from reading this session as interrupted -- then reclaim
    # this project's .git now that the session is over and no live git command is there to disturb. Ownership then
    # tracks the work tree the Stop sweeps already handed back, instead of waiting for the next session-start;
    # the user:<operator> ACL keeps .git accessible meanwhile. A killed session exits before this handler runs,
    # and the next session-start's pass catches what it left, as it catches a reclaim a timeout cut short.
    if [[ "${mode}" == "session-end" ]]; then
        ai_tools_log__debug "session-end: clearing clean-exit marker"
        rm -f "${active_marker}" 2>/dev/null || true
        end_payload="$(cat 2>/dev/null)" || return 0
        end_cwd="$(jq -r '.cwd // empty' <<<"${end_payload}" 2>/dev/null)" || true
        if [[ -n "${end_cwd}" && -d "${end_cwd}" ]]; then
            end_found="$(_ai_tools_session_sweep__reclaim_git_tree "${end_cwd}")"
            if [[ "${end_found}" -gt 0 ]]; then
                ai_tools_log__info "session-end: reclaimed ${end_found} agent-owned .git path(s) under ${end_cwd}"
            fi
        fi
        return 0
    fi

    # Capture the hook JSON once (stdin is a pipe, readable only once), then parse both .cwd and -- in session-start
    # mode -- .source from the captured payload.
    payload="$(cat 2>/dev/null)" || return 0

    # The session's working dir (allowlisted project root). No cwd -> return without acting.
    dir="$(jq -r '.cwd // empty' <<<"${payload}" 2>/dev/null)" || return 0
    [[ -n "${dir}" && -d "${dir}" ]] || return 0
    # The path as the NOTICE prints it, from the hook payload: the prose takes it sanitized, and a command takes bash's
    # %q encoding, which pastes back as the same path.
    display_dir="$(ai_tools_log__sanitize "${dir}")"
    quoted_dir="$(_ai_tools_session_sweep__quote_path "${dir}")"

    # Decide whether this pass ignores the marker. Only session-start mode sets it, and only for a freshly started
    # process, so a Stop pass stays bounded by the marker. An agent's declaration may already select these two sources
    # with a matcher; the check here holds the same line whatever the declaration selects.
    unbounded=0
    if [[ "${mode}" == "session-start" ]]; then
        src="$(jq -r '.source // empty' <<<"${payload}" 2>/dev/null)"
        case "${src}" in
            startup|resume) unbounded=1 ;;
            *) return 0 ;;          # any other source: a live process, Stop covers it
        esac
    fi

    # Interrupted-session detection (real process start only). A surviving clean-exit marker means the previous session
    # exited before its SessionEnd handler ran. Capture the cwd it recorded so the deep .git reclaim can target
    # that project, then (re)stamp the marker with THIS session's cwd.
    interrupted=0
    prev_cwd=""
    if [[ "${unbounded}" -eq 1 ]]; then
        if [[ -f "${active_marker}" ]]; then
            interrupted=1
            prev_cwd="$(_ai_tools_session_sweep__read_prior_cwd "${active_marker}")"
        fi
        printf '%s\n' "${dir}" > "${active_marker}" 2>/dev/null || true
        # Hooks before 0.27.0 left a .sweep.XXXXXX file here when killed mid-walk; the account owns them. Retired once
        # 0.27.0 is the oldest release in use.
        rm -f -- "${state_dir}"/.sweep.?????? 2>/dev/null || true
    fi

    # Session start on a genuinely new process (the unbounded pass): normalize the project's setgid bit so files
    # the projects user creates inherit @SANDBOX_GROUP@, letting the projects user be a non-member of that group.
    # The root helper re-validates dir against the allowlist and is idempotent. Gated on the unbounded pass, so a Stop
    # turn does not repeat it.
    if [[ "${unbounded}" -eq 1 ]]; then
        ai_tools_log__debug "session-start: normalizing setgid on ${dir}"
        "${_AI_TOOLS_SESSION_SWEEP__HANDBACK_CLIENT}" SETGID "${dir}" || true
    fi

    # The scan's start time, set on the marker only after the sweep completes, so anything written during the sweep is
    # still caught next time. In session-start mode this resets the marker, so this session's Stop sweeps bound
    # from session start.
    scan_start="$(date --rfc-3339=ns 2>/dev/null)" || scan_start=""

    # Advance the marker to the scan's start once the walk ran; a skipped walk or a run ended mid-walk leaves it,
    # so the next pass covers the same span. A failed call does not hold it, since a path refused for good would pin it.
    # No file carries the time: a Stop hook codex kills at its timeout does not run a trap, so one would stay behind.
    # The `if` keeps the stub's `set -e` off the walk's status; its count is for the tests, as stdout is the agent's
    # reply.
    if _ai_tools_session_sweep__sweep_project "${dir}" "${marker}" "${unbounded}" "${mode}" >/dev/null; then
        [[ -z "${scan_start}" ]] || touch -d "${scan_start}" "${marker}" 2>/dev/null || true
    fi

    # .git ownership reclaim, run on every unbounded (session-start) pass. Every sweep SKIPS .git, so ai-tools-owned
    # objects the agent writes there via `git commit` (Bash tool, no path in the event, so no PostToolUse handback)
    # escape the sweep and leave .git in mixed ownership -- work tree <you>-owned, .git internals ai-tools-owned --
    # which makes git report "dubious ownership" and, once <you> is not an ai-tools group member, blocks reads
    # and repacks. The marker does not gate this reclaim; it only selects the cross-project target and the NOTICE
    # wording.
    [[ "${unbounded}" -eq 1 ]] || return 0
    if [[ -S "${_AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET}" ]]; then
        git_found="$(_ai_tools_session_sweep__reclaim_git_tree "${dir}")"

        # A killed prior session may have been working in a DIFFERENT project; its recorded cwd is the only pointer
        # to that repo, so reclaim its .git too when it differs from this session's project. A graceful prior session
        # clears the marker, so its own next start reclaims its .git -- no cross-project pointer needed.
        prev_found=0
        if [[ "${interrupted}" -eq 1 && -n "${prev_cwd}" && "${prev_cwd}" != "${dir}" ]]; then
            prev_found="$(_ai_tools_session_sweep__reclaim_git_tree "${prev_cwd}")"
        fi

        # Report the reclaim. Every reclaim is logged to journald (the audit trail of what was handed back). Only
        # the INTERRUPTED case is ALSO surfaced as SessionStart additionalContext, because only it is actionable:
        # a killed prior session can leave cross-project mixed ownership the agent should relay, with the manual
        # reconcile for stragglers the helper could not reach (excluded or quarantined paths). The routine
        # post-git-activity reclaim has already repaired ownership, so its notice would carry a line the user cannot act
        # on, and injecting additionalContext would force a TUI re-render that clobbers the agent's startup banner. It
        # therefore stays journald-only.
        total_found=$((git_found + prev_found))
        if [[ "${total_found}" -gt 0 ]]; then
            ai_tools_log__info "reclaimed ${total_found} agent-owned .git path(s) under ${dir}$([[ "${prev_found}" -gt 0 ]] && echo " and ${prev_cwd}")$([[ "${interrupted}" -eq 1 ]] && echo ' (prior session interrupted)')"
            if [[ "${interrupted}" -eq 1 ]]; then
                # What reaches the model is sanitized and does not NAME the prior project. The path is the sandbox
                # account's to write, and under one shared config directory per host the prior session may be another
                # operator's, so relaying it would disclose a project this session has no business knowing
                # about; the reclaim already happened, and journald holds the path for the operator who does. This
                # session's own project is named -- it is the one the agent is working in -- through the log sanitizer,
                # since it arrives in the hook payload.
                scope="${display_dir}/.git"
                [[ "${prev_found}" -gt 0 ]] && scope="${scope} and a prior session's project"
                # Frame the explanation in the '#' box (wrapped within 80 cols); keep the reconcile command on its own
                # line UNDER the box so it stays copy-pasteable. The wrap never splits a single token (paths survive
                # intact), but a multi-word command would break across lines, so it is left outside the box.
                prose="$(AI_TOOLS_MSG_BOX=1 ai_tools_msg__alert NOTICE 1 \
                    "The previous session ended without cleanup (interrupted). Reclaimed ${total_found} agent-owned path(s) under ${scope} to repair the mixed ownership that makes git report \"dubious ownership\".")"
                # The command names THIS session's project for the same reason the prose does: it is the one the user
                # asking is working in, and a command naming a path from the marker would be a command typed
                # against a tree nobody in this session chose. The handback command resolves each path's owner
                # through ai-tools-chown, with its exclusion and secret rules, and walks .git by default.
                reconcile="If git still complains, ask the user to run:"$'\n'"  ai-tools projects handback ${quoted_dir}"
                _ai_tools_session_sweep__emit_session_context "${prose}"$'\n'"${reconcile}"
            fi
        fi
    else
        # Socket DOWN: every CHOWN would fail, so the reclaim is skipped. Surface the stranded paths and the fix rather
        # than a count of a reclaim that did not happen. Count the strand under this session's project and, if a prior
        # session was killed elsewhere, that project too.
        stranded="$(_ai_tools_session_sweep__count_git_agent_owned "${dir}")"
        if [[ "${interrupted}" -eq 1 && -n "${prev_cwd}" && "${prev_cwd}" != "${dir}" ]]; then
            stranded=$(( stranded + $(_ai_tools_session_sweep__count_git_agent_owned "${prev_cwd}") ))
        fi
        if [[ "${stranded}" -gt 0 ]]; then
            ai_tools_log__warn "handback socket ${_AI_TOOLS_SESSION_SWEEP__HANDBACK_SOCKET} is down -- ${stranded} agent-owned .git path(s) under ${dir} not reclaimed; run: ai-tools projects handback ${quoted_dir}"
            prose="$(AI_TOOLS_MSG_BOX=1 ai_tools_msg__alert NOTICE 1 \
                "The ownership handback socket is down, so ${stranded} file(s) the agent wrote to git stay ai-tools-owned and git may report \"dubious ownership\". Bring the socket up, then reclaim the tree:")"
            reconcile="  sudo systemctl enable --now ai-tools-handback.socket"$'\n'"  ai-tools projects handback ${quoted_dir}"
            _ai_tools_session_sweep__emit_session_context "${prose}"$'\n'"${reconcile}"
        fi
    fi
    return 0
}

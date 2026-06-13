#!/usr/bin/env bash
# /opt/ai-tools/.claude/session-hook.sh
# Sandbox housekeeping hook, run at lifecycle boundaries (Stop + SessionStart). It
# hands back every ai-tools-owned file and directory under the session's project
# that the precise Write|Edit PostToolUse hook did not catch -- chiefly files
# created/modified via the Bash tool (npm/build output, codegen, sed/mv, redirects),
# which carry no file_path and so never trigger post-tool-hook.sh -- and, at session
# start, normalizes the project's setgid bit (via ai-tools-setgid) so files the
# projects user creates inherit @SANDBOX_GROUP@.
#
# Runs as ai-tools. Reads the hook JSON on stdin for .cwd (the allowlisted project
# root claude launched in) and sweeps there. Each path is handed to the root
# validator ai-tools-chown (via the handback socket bridge), which independently
# re-checks the allowlist and the agent-owned guard -- so this sweep can reach
# nothing the precise hook could not.
#
# Three modes, selected by $1:
#
#   stop          (default) -- Stop hook, fires at each turn's end. Bounded by a
#                 timestamp marker: only paths modified since the previous sweep
#                 are processed, so the turn-end pass stays cheap. It is a turn-end
#                 net, NOT a per-tool action -- handing a file back makes it
#                 <you>:ai-tools 640 (group ai-tools loses write), which would break
#                 an in-progress Bash sequence editing a file in place. Running at
#                 Stop avoids that: the agent keeps ownership mid-turn, handback
#                 happens once control returns.
#
#   session-start -- SessionStart hook, fires when a session begins. UNBOUNDED:
#                 ignores the marker and sweeps every ai-tools-owned path, then
#                 resets the marker to "now". This reclaims leftovers from a prior
#                 session that was killed (crash, kill -9, closed terminal) before
#                 its Stop sweep could run -- the one gap the Stop net cannot close
#                 itself. It ALSO reclaims the project's .git, which every sweep
#                 prunes (see below). Gated on the hook's .source: only "startup"
#                 and "resume" (a freshly started process, which is what can follow
#                 an interrupted session) trigger the pass. "clear"/"compact" stay
#                 within a live process whose Stop sweeps already cover the tree,
#                 so they are a no-op (and skip an otherwise pointless full-tree
#                 walk on every compaction).
#
#   session-end   -- SessionEnd hook, fires once when the process exits
#                 gracefully. Removes the clean-exit marker (.session-active) and
#                 does nothing else. That marker is written at session-start and
#                 cleared here; if it instead SURVIVES into the next session-start,
#                 the previous session was killed before this ran (tokens
#                 exhausted, crash, closed terminal). A surviving marker widens the
#                 .git reclaim (which runs every session-start, below) to the killed
#                 session's recorded cwd -- which may be a different project -- and is
#                 what raises the SessionStart NOTICE: only the interrupted case emits
#                 one (framed via msg.lib.sh), while the routine post-git-activity
#                 reclaim is logged to journald alone so it never clobbers claude's
#                 startup banner.
#
# .git reclaim: every sweep PRUNES .git for cost, so ai-tools-owned objects the agent
# writes there via `git commit` (Bash tool -> no Write|Edit PostToolUse) are never
# handed back by the sweep, on a graceful exit as much as a killed one -- rotting .git
# into mixed ownership that makes git report "dubious ownership". The unbounded
# session-start pass therefore reclaims .git unconditionally; a per-turn Stop reclaim
# is deliberately avoided (it would change ownership mid-turn under a live git command).
#
# Heavy/transient trees are pruned in both sweeping modes (their contents are world-readable
# anyway, so <you> can already read them) and the scan stays on one filesystem (-xdev).
#
# Deploy: sudo install -o @PROJECTS_USER@ -g ai-tools -m 750 \
#             src/opt/ai-tools/.claude/session-hook.sh /opt/ai-tools/.claude/session-hook.sh
# Wired to the Stop, SessionStart, and SessionEnd hooks in settings.json (the
# SessionStart entry passes "session-start", the SessionEnd entry "session-end").

set -euo pipefail

readonly MARKER="/opt/ai-tools/.claude/.sweep-marker"

# Clean-exit marker: written at session-start (process birth), removed at
# session-end (graceful exit). Surviving into the next session-start means the
# previous session was killed before its SessionEnd ran -- the signal for the
# deep .git reclaim below. Global, not per-project (mirrors MARKER); it records
# the prior session's cwd so the deep reclaim can target that project. Under
# concurrent sessions the single marker races (a second start sees the first's
# marker as "interrupted"); the sandbox is single-session by design, same caveat
# as MARKER.
readonly ACTIVE_MARKER="/opt/ai-tools/.claude/.session-active"

# Mode: "stop" (default, bounded sweep), "session-start" (unbounded reclaim) or
# "session-end" (clear the clean-exit marker).
readonly MODE="${1:-stop}"

# Shared leveled logger -- journald only (this hook runs as the agent and cannot write
# the root-only /var/log/ai-tools files; the sudo helpers it calls record the actual
# file mutations there). Best-effort no-op fallback if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-hook"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=/dev/null
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Shared message formatter -- frames the SessionStart NOTICE below in the paste-safe
# '#' box, wrapped within 80 columns. Best-effort: if the lib is missing, fall back to
# plain text so the notice still reaches the user.
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=/dev/null
if ! source "${MSG_LIB}" 2>/dev/null; then
    ai_tools_msg() { shift 2; printf '%s\n' "$@"; }
    ai_tools_msg_wrap() { shift; printf '%s\n' "$*"; }
fi

# session-end: graceful process exit. Clear the clean-exit marker so the next
# session-start does not read this session as interrupted, then stop. Nothing
# else to do -- the live process's Stop sweeps already handed back the work tree.
if [[ "${MODE}" == "session-end" ]]; then
    ai_tools_log_debug "session-end: clearing clean-exit marker"
    rm -f "${ACTIVE_MARKER}" 2>/dev/null || true
    exit 0
fi

# Pruned directory names from the shared library (single source of truth, shared
# with ai-tools-setgid / ai-tools-lockdown). Unreadable -> empty -> no pruning.
readonly PRUNE_LIB="/usr/local/lib/ai-tools/prune-dirs.lib.sh"
AI_TOOLS_PRUNE_NAMES=()
# shellcheck source=/dev/null
[[ -r "${PRUNE_LIB}" ]] && source "${PRUNE_LIB}" || true

# Capture the hook JSON once (stdin is a pipe, readable only once), then parse
# both .cwd and -- in session-start mode -- .source from the captured payload.
payload="$(cat 2>/dev/null)" || exit 0

# The session's working dir (allowlisted project root). No cwd -> nothing to do.
dir="$(jq -r '.cwd // empty' <<<"${payload}" 2>/dev/null)" || exit 0
[[ -n "${dir}" && -d "${dir}" ]] || exit 0

# Decide whether this pass ignores the marker. Stop mode always honours it.
# Session-start mode is unbounded, but only for a freshly started process.
unbounded=0
if [[ "${MODE}" == "session-start" ]]; then
    src="$(jq -r '.source // empty' <<<"${payload}" 2>/dev/null)"
    case "${src}" in
        startup|resume) unbounded=1 ;;
        *) exit 0 ;;            # clear/compact/unknown: live process, Stop covers it
    esac
fi

# Interrupted-session detection (real process start only). A surviving
# ACTIVE_MARKER means the previous session never ran its SessionEnd handler.
# Capture the cwd it recorded so the deep .git reclaim below can target that
# project, then (re)stamp the marker with THIS session's cwd.
interrupted=0
prev_cwd=""
if [[ "${unbounded}" -eq 1 ]]; then
    if [[ -f "${ACTIVE_MARKER}" ]]; then
        interrupted=1
        prev_cwd="$(head -n1 "${ACTIVE_MARKER}" 2>/dev/null || true)"
    fi
    printf '%s\n' "${dir}" > "${ACTIVE_MARKER}" 2>/dev/null || true
fi

# Session start on a genuinely new process (the unbounded pass): normalize the
# project's setgid bit so files the projects user creates inherit @SANDBOX_GROUP@,
# letting the projects user be a non-member of that group. The root helper
# re-validates dir against the allowlist and is idempotent. Stop mode never does this.
if [[ "${unbounded}" -eq 1 ]]; then
    ai_tools_log_debug "session-start: normalizing setgid on ${dir}"
    /usr/local/bin/ai-tools-handback-client SETGID "${dir}" || true
fi

# New marker stamped to "now" (scan start). Applied to MARKER only after the sweep
# completes, so anything written during the sweep is still caught next time. In
# session-start mode this resets the marker, so this session's Stop sweeps bound
# from session start.
newref="$(mktemp "/opt/ai-tools/.claude/.sweep.XXXXXX" 2>/dev/null)" || exit 0

# find DIR -xdev \( prune heavy trees \) -prune -o \( ai-tools-owned [newer] file|dir \) -print0
declare -a expr=( "${dir}" -xdev )
if (( ${#AI_TOOLS_PRUNE_NAMES[@]} > 0 )); then
    expr+=( '(' )
    for i in "${!AI_TOOLS_PRUNE_NAMES[@]}"; do
        (( i > 0 )) && expr+=( -o )
        expr+=( -name "${AI_TOOLS_PRUNE_NAMES[$i]}" )
    done
    expr+=( ')' -prune -o )
fi
expr+=( '(' -user @SANDBOX_USER@ )
# Bound to paths changed since the marker, EXCEPT an unbounded (session-start)
# pass, which sweeps every ai-tools-owned path. A first-ever stop run (no marker)
# is likewise a full sweep.
if [[ "${unbounded}" -eq 0 && -f "${MARKER}" ]]; then
    expr+=( -newer "${MARKER}" )
fi
expr+=( '(' -type f -o -type d ')' -print0 ')' )

# Delegate each path to the root validator. </dev/null keeps ai-tools-chown on its
# non-interactive branch. Trailing `|| true` so a find/pipe non-zero (e.g. an
# unreadable subdir) cannot trip set -e / pipefail and skip the marker update.
ai_tools_log_debug "${MODE} sweep: handing back agent-owned paths under ${dir}$([[ "${unbounded}" -eq 1 ]] && echo ' (unbounded)' || echo ' (since marker)')"
find "${expr[@]}" 2>/dev/null \
    | while IFS= read -r -d '' path; do
        /usr/local/bin/ai-tools-handback-client CHOWN "${path}" || true
      done || true

# Advance the marker to this scan's start time (rename within the same dir keeps
# the mtime). Best-effort; never block the turn/session from proceeding.
mv -f "${newref}" "${MARKER}" 2>/dev/null || rm -f "${newref}" 2>/dev/null || true

# reclaim_git_tree PROJECT -- hand every ai-tools-owned path under PROJECT/.git to
# ai-tools-chown, which re-validates the allowlist, exclusions and secret rules
# exactly as the sweep does. Echoes the count of paths processed on stdout; the
# helper's own stdout is redirected to stderr (1>&2) so it can never corrupt the
# additionalContext JSON this script emits on stdout. No PROJECT/.git -> echo 0.
reclaim_git_tree() {
    local proj="$1" n=0 path
    if [[ -n "${proj}" && -d "${proj}/.git" ]]; then
        while IFS= read -r -d '' path; do
            /usr/local/bin/ai-tools-handback-client CHOWN "${path}" || true
            n=$((n + 1))
        done < <(find "${proj}/.git" -xdev -user @SANDBOX_USER@ \
                     \( -type f -o -type d \) -print0 2>/dev/null)
    fi
    printf '%s' "${n}"
}

# .git ownership reclaim, run on every unbounded (session-start) pass. Every sweep
# PRUNES .git, so ai-tools-owned objects the agent writes there via `git commit`
# (Bash tool, no file_path, so no Write|Edit PostToolUse handback) escape the sweep
# on graceful and killed exits alike. Such objects leave .git in mixed ownership
# (work tree <you>-owned, .git internals ai-tools-owned), which makes git report
# "dubious ownership" and, once <you> is not an ai-tools group member, blocks reads
# and repacks. The marker does not gate this reclaim; it only selects the cross-project
# target and the NOTICE wording below.
if [[ "${unbounded}" -eq 1 ]]; then
    git_found="$(reclaim_git_tree "${dir}")"

    # A killed prior session may have been working in a DIFFERENT project; its
    # recorded cwd is the only pointer to that repo, so reclaim its .git too when it
    # differs from this session's project. A graceful prior session clears the
    # marker, so its own next start reclaims its .git -- no cross-project pointer needed.
    prev_found=0
    if [[ "${interrupted}" -eq 1 && -n "${prev_cwd}" && "${prev_cwd}" != "${dir}" ]]; then
        prev_found="$(reclaim_git_tree "${prev_cwd}")"
    fi

    # Report the reclaim. Every reclaim is logged to journald (the audit trail of what was
    # handed back). Only the INTERRUPTED case is ALSO surfaced as SessionStart
    # additionalContext, because only it is actionable: a killed prior session can leave
    # cross-project mixed ownership the agent should relay, with the manual reconcile for
    # stragglers the helper could not reach (excluded or quarantined paths). The routine
    # post-git-activity reclaim runs on essentially every session-start (the per-turn sweeps
    # always prune .git) and has already repaired ownership, so there is nothing for the user
    # to act on; injecting additionalContext would only force a TUI re-render that clobbers
    # claude's startup banner. It therefore stays journald-only.
    total_found=$((git_found + prev_found))
    if [[ "${total_found}" -gt 0 ]]; then
        ai_tools_log_info "reclaimed ${total_found} agent-owned .git path(s) under ${dir}$([[ "${prev_found}" -gt 0 ]] && echo " and ${prev_cwd}")$([[ "${interrupted}" -eq 1 ]] && echo ' (prior session interrupted)')"
        if [[ "${interrupted}" -eq 1 ]]; then
            scope="${dir}/.git"
            [[ "${prev_found}" -gt 0 ]] && scope="${scope} and ${prev_cwd}/.git"
            # Frame the explanation in the '#' box (wrapped within 80 cols); keep the
            # reconcile command on its own line BELOW the box so it stays copy-pasteable.
            # The wrap never splits a single token (paths survive intact), but a
            # multi-word command would break across lines, so it is left outside the box.
            prose="$(AI_TOOLS_MSG_BOX=1 ai_tools_msg NOTICE 1 \
                "The previous session ended without cleanup (interrupted). Reclaimed ${total_found} agent-owned path(s) under ${scope} to repair the mixed ownership that makes git report \"dubious ownership\".")"
            reconcile="If git still complains, ask the user to run:"$'\n'"  sudo chown -R --from=@SANDBOX_USER@ @PROJECTS_USER@:@SANDBOX_GROUP@ \"${prev_cwd:-${dir}}\""
            jq -cn --arg ctx "${prose}"$'\n'"${reconcile}" \
                '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' \
                2>/dev/null || true
        fi
    fi
fi
exit 0

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
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
# re-checks the allowlist and the agent-owned guard -- so this sweep cannot reach
# a path the precise hook could not.
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
#                 skips (see the .git reclaim). Gated on the hook's .source: only "startup"
#                 and "resume" (a freshly started process, which is what can follow
#                 an interrupted session) trigger the pass. "clear"/"compact" stay
#                 within a live process whose Stop sweeps already cover the tree,
#                 so they are a no-op (and skip an otherwise pointless full-tree
#                 walk on every compaction).
#
#   session-end   -- SessionEnd hook, fires once when the process exits
#                 gracefully. Removes the clean-exit marker (.session-active) and
#                 reclaims this project's .git: the session is over, so no live git
#                 command is there to disturb. That marker is written at session-start
#                 and cleared here; if it instead SURVIVES into the next session-start,
#                 the previous session was killed before this ran (tokens
#                 exhausted, crash, closed terminal). A surviving marker widens the
#                 .git reclaim (which runs every session-start) to the killed
#                 session's recorded cwd -- which may be a different project -- and is
#                 what raises the SessionStart NOTICE: only the interrupted case emits
#                 one (framed via msg.lib.sh), while the routine post-git-activity
#                 reclaim is logged to journald alone so it never clobbers claude's
#                 startup banner.
#
# .git reclaim: every sweep SKIPS .git for cost, so ai-tools-owned objects the agent
# writes there via `git commit` (Bash tool -> no Write|Edit PostToolUse) are never
# handed back by the sweep, on a graceful exit as much as a killed one -- leaving .git
# in mixed ownership, which makes git report "dubious ownership". The unbounded
# session-start pass and the session-end pass therefore reclaim .git; a per-turn Stop
# reclaim is avoided (it would change ownership mid-turn under a live git command).
#
# Heavy/transient trees are skipped in both sweeping modes (their contents are world-readable
# anyway, so <you> can already read them) and the scan stays on one filesystem (-xdev).
#
# Handback socket down: every CHOWN runs over /run/ai-tools/handback.sock, so a socket that is
# not listening fails every hand-back. Each pass checks the socket first and, when it is down,
# skips its walk and records the STRANDED count rather than tallying failed calls -- and the
# session-start pass emits a distinct NOTICE naming the fix instead of a reassuring "Reclaimed
# N". Every pass otherwise counts CONFIRMED hand-backs (client exit 0), not attempts. The socket
# is a data-ownership convenience, not a confinement boundary (the user:<operator> ACL keeps <you>
# reading agent files regardless), so this warns and proceeds -- it never blocks a session.
#
# Installed 750 root:ai-tools: the session executes it through the group and cannot rewrite it,
# which is what keeps the sweeps out of the agent's control (see ownership-and-hooks.rule.md).
# Deploying from a checkout: docs/install-from-source.md.
# Wired to the Stop, SessionStart, and SessionEnd hooks in settings.json (the
# SessionStart entry passes "session-start", the SessionEnd entry "session-end").

set -euo pipefail

# The hook's own directory -- this agent's config dir, whose name its manifest declares -- so the
# state files follow the hook instead of repeating a path the base layer no longer owns.
HOOK_DIR="${BASH_SOURCE[0]%/*}"
readonly HOOK_DIR
readonly MARKER="${HOOK_DIR}/.sweep-marker"

# Clean-exit marker: written at session-start (process birth), removed at
# session-end (graceful exit). Surviving into the next session-start means the
# previous session was killed before its SessionEnd ran -- the signal for the
# deep .git reclaim. Global, not per-project (mirrors MARKER); it records
# the prior session's cwd so the deep reclaim can target that project. Under
# concurrent sessions the single marker races (a second start sees the first's
# marker as "interrupted"); the sandbox is single-session by design, same caveat
# as MARKER.
readonly ACTIVE_MARKER="${HOOK_DIR}/.session-active"

# The handback socket every CHOWN runs over. Each pass checks it before walking, so a socket
# that is down reports the stranded work rather than a count of failed calls (see the header).
readonly HANDBACK_SOCKET="/run/ai-tools/handback.sock"

# Mode: "stop" (default, bounded sweep), "session-start" (unbounded reclaim) or
# "session-end" (clear the clean-exit marker).
readonly MODE="${1:-stop}"

# Shared leveled logger -- journald only (this hook runs as the agent and cannot write
# the root-only /var/log/ai-tools files; the sudo helpers it calls record the actual
# file mutations there). Best-effort no-op fallback if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-hook"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../../../usr/local/lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Shared message formatter -- frames the SessionStart NOTICE in the paste-safe
# '#' box, wrapped within 80 columns. THE one msg.lib consumer that keeps a fallback:
# every other consumer requires the lib (it carries their yes/no decisions and their
# runs may fail closed), but this hook only EMITS, and its sweep is itself the safety
# action -- the handback must run even on an install broken enough to lose the
# formatter, so a missing lib degrades the notice to plain text instead of stopping
# the sweep (see messaging.rule.md).
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
# shellcheck source=SCRIPTDIR/../../../../usr/local/lib/ai-tools/msg.lib.sh
if ! source "${MSG_LIB}" 2>/dev/null; then
    ai_tools_msg() { shift 2; printf '%s\n' "$@"; }
    ai_tools_msg_wrap() { shift; printf '%s\n' "$*"; }
fi

# Operator identity (PROJECTS_USER) from /etc/ai-tools/operator.conf via the shared resolver,
# used only to render the reconcile command in the interrupted-session NOTICE. Sweeping
# itself does not need an operator identity -- it finds @SANDBOX_USER@-owned paths and the root
# validator re-checks ownership. Best-effort: an unenrolled/missing config leaves PROJECTS_USER
# empty, degrading only the suggested command's owner field.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../../../usr/local/lib/ai-tools/operator.lib.sh
if source "${OPERATOR_LIB}" 2>/dev/null; then
    ai_tools_load_operator || true
else
    PROJECTS_USER=''
fi

# reclaim_git_tree PROJECT -- hand every ai-tools-owned path under PROJECT/.git to
# ai-tools-chown, which re-validates the allowlist, exclusions and secret rules exactly as
# the sweep does. Echoes the count of paths processed on stdout. The client writes only to
# stderr -- MSG relays of the helper's stderr, and its own errors -- and leaves stdout empty,
# so it cannot corrupt this function's captured count or the additionalContext JSON this
# script emits. No PROJECT/.git -> echo 0. Used by the session-end reclaim and the session-start pass.
reclaim_git_tree() {
    local proj="$1" n=0 path
    # Socket down: no path can be handed back -- report zero, not a count of failed calls.
    [[ -S "${HANDBACK_SOCKET}" ]] || { printf '0'; return 0; }
    if [[ -n "${proj}" && -d "${proj}/.git" ]]; then
        while IFS= read -r -d '' path; do
            # Count CONFIRMED handbacks (client exit 0), not attempts, so the reported total
            # reflects what changed owner.
            if /usr/local/bin/ai-tools-handback-client CHOWN "${path}"; then
                n=$((n + 1))
            fi
        done < <(find "${proj}/.git" -xdev -user @SANDBOX_USER@ \
                     \( -type f -o -type d \) -print0 2>/dev/null)
    fi
    printf '%s' "${n}"
}

# session-end: graceful process exit. Clear the clean-exit marker so the next session-start does
# not read this session as interrupted, and reclaim this project's .git now that the session is
# over and no live git command is there to disturb. Ownership then tracks the work tree the Stop
# sweeps already handed back, instead of waiting for the next session-start; the user:<operator>
# ACL keeps .git accessible meanwhile. A killed session exits before this handler runs, and the
# next session-start's pass catches what it left.
if [[ "${MODE}" == "session-end" ]]; then
    ai_tools_log_debug "session-end: clearing clean-exit marker"
    rm -f "${ACTIVE_MARKER}" 2>/dev/null || true
    end_payload="$(cat 2>/dev/null)" || exit 0
    end_cwd="$(jq -r '.cwd // empty' <<<"${end_payload}" 2>/dev/null)" || true
    if [[ -n "${end_cwd}" && -d "${end_cwd}" ]]; then
        end_found="$(reclaim_git_tree "${end_cwd}")"
        if [[ "${end_found}" -gt 0 ]]; then
            ai_tools_log_info "session-end: reclaimed ${end_found} agent-owned .git path(s) under ${end_cwd}"
        fi
    fi
    exit 0
fi

# Directory-skip selector from the shared library (single source of truth, shared with
# ai-tools-setgid / ai-tools-lockdown). A missing lib leaves a stub that descends everywhere.
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../../../../usr/local/lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# Capture the hook JSON once (stdin is a pipe, readable only once), then parse
# both .cwd and -- in session-start mode -- .source from the captured payload.
payload="$(cat 2>/dev/null)" || exit 0

# The session's working dir (allowlisted project root). No cwd -> exit without acting.
dir="$(jq -r '.cwd // empty' <<<"${payload}" 2>/dev/null)" || exit 0
[[ -n "${dir}" && -d "${dir}" ]] || exit 0

# Decide whether this pass ignores the marker. Only session-start mode sets it, and only for
# a freshly started process, so a Stop pass stays bounded by the marker.
unbounded=0
if [[ "${MODE}" == "session-start" ]]; then
    src="$(jq -r '.source // empty' <<<"${payload}" 2>/dev/null)"
    case "${src}" in
        startup|resume) unbounded=1 ;;
        *) exit 0 ;;            # clear/compact/unknown: live process, Stop covers it
    esac
fi

# Interrupted-session detection (real process start only). A surviving
# ACTIVE_MARKER means the previous session exited before its SessionEnd handler ran.
# Capture the cwd it recorded so the deep .git reclaim can target that
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
# re-validates dir against the allowlist and is idempotent. Gated on the unbounded
# pass, so a Stop turn does not repeat it.
if [[ "${unbounded}" -eq 1 ]]; then
    ai_tools_log_debug "session-start: normalizing setgid on ${dir}"
    /usr/local/bin/ai-tools-handback-client SETGID "${dir}" || true
fi

# New marker stamped to "now" (scan start). Applied to MARKER only after the sweep
# completes, so anything written during the sweep is still caught next time. In
# session-start mode this resets the marker, so this session's Stop sweeps bound
# from session start.
newref="$(mktemp "${HOOK_DIR}/.sweep.XXXXXX" 2>/dev/null)" || exit 0

# find DIR -xdev \( skip heavy trees \) -prune -o \( ai-tools-owned [newer] file|dir \) -print0
ai_tools_skip_find_expr sweep '' "${dir}"
declare -a expr=( "${dir}" -xdev "${AI_TOOLS_SKIP_FIND_EXPR[@]}" '(' -user @SANDBOX_USER@ )
# Bound to paths changed since the marker, EXCEPT an unbounded (session-start)
# pass, which sweeps every ai-tools-owned path. A first-ever stop run (no marker)
# is likewise a full sweep.
if [[ "${unbounded}" -eq 0 && -f "${MARKER}" ]]; then
    expr+=( -newer "${MARKER}" )
fi
expr+=( '(' -type f -o -type d ')' -print0 ')' )

# Delegate each path to the root validator. </dev/null keeps ai-tools-chown on its
# non-interactive branch. The find reads via process substitution (not a pipe) so the
# count survives the loop; a find non-zero (e.g. an unreadable subdir) only ends the
# stream and cannot trip set -e / pipefail or skip the marker update.
ai_tools_log_debug "${MODE} sweep: handing back agent-owned paths under ${dir}$([[ "${unbounded}" -eq 1 ]] && echo ' (unbounded)' || echo ' (since marker)')"
swept=0
if [[ ! -S "${HANDBACK_SOCKET}" ]]; then
    # Socket down: every CHOWN would fail, so skip the walk and record it once. Counting the
    # failed calls would also mis-fire the large-batch skip-list hint.
    ai_tools_log_warn "${MODE} sweep skipped: handback socket ${HANDBACK_SOCKET} is down -- paths under ${dir} stay @SANDBOX_USER@-owned (reclaim with: ai-tools --reclaim ${dir})"
else
    # Count CONFIRMED handbacks (client exit 0), not attempts.
    while IFS= read -r -d '' path; do
        if /usr/local/bin/ai-tools-handback-client CHOWN "${path}"; then
            swept=$((swept + 1))
        fi
    done < <(find "${expr[@]}" 2>/dev/null) || true
fi

# A large sweep is the skip-list signal: hundreds of agent-owned paths per pass usually
# means a build or dependency tree is handed back over and over. Journald-only (routine,
# no action for the operator in-session); the operator tunes the skip categories.
if [[ "${swept}" -ge 200 ]]; then
    ai_tools_log_info "${MODE} sweep: handed back ${swept} paths -- a recurring build tree can be skipped via SKIP_ARTIFACT_DIRS in /etc/ai-tools/operator.conf (reference: /usr/local/lib/ai-tools/skip-dirs.lib.sh)"
fi

# Advance the marker to this scan's start time (rename within the same dir keeps
# the mtime). Best-effort: a failed rename falls through to `|| true`, so the turn
# or session proceeds either way.
mv -f "${newref}" "${MARKER}" 2>/dev/null || rm -f "${newref}" 2>/dev/null || true

# count_git_agent_owned PROJECT -- number of @SANDBOX_USER@-owned paths under PROJECT/.git (0 if
# there is no such tree). Used only when the socket is down, to tell whether there is stranded
# git work to warn about.
count_git_agent_owned() {
    local proj="$1"
    [[ -n "${proj}" && -d "${proj}/.git" ]] || { printf '0'; return 0; }
    find "${proj}/.git" -xdev -user @SANDBOX_USER@ \( -type f -o -type d \) -printf '.' 2>/dev/null | wc -c
}

# .git ownership reclaim, run on every unbounded (session-start) pass. Every sweep
# SKIPS .git, so ai-tools-owned objects the agent writes there via `git commit`
# (Bash tool, no file_path, so no Write|Edit PostToolUse handback) escape the sweep
# and leave .git in mixed ownership -- work tree <you>-owned, .git internals
# ai-tools-owned -- which makes git report "dubious ownership" and, once <you> is not
# an ai-tools group member, blocks reads and repacks. The marker does not gate this
# reclaim; it only selects the cross-project target and the NOTICE wording.
if [[ "${unbounded}" -eq 1 ]]; then
  if [[ -S "${HANDBACK_SOCKET}" ]]; then
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
    # post-git-activity reclaim has already repaired ownership, so its notice would carry a
    # line the user cannot act on, and injecting additionalContext would force a TUI re-render
    # that clobbers the agent's startup banner. It therefore stays journald-only.
    total_found=$((git_found + prev_found))
    if [[ "${total_found}" -gt 0 ]]; then
        ai_tools_log_info "reclaimed ${total_found} agent-owned .git path(s) under ${dir}$([[ "${prev_found}" -gt 0 ]] && echo " and ${prev_cwd}")$([[ "${interrupted}" -eq 1 ]] && echo ' (prior session interrupted)')"
        if [[ "${interrupted}" -eq 1 ]]; then
            scope="${dir}/.git"
            [[ "${prev_found}" -gt 0 ]] && scope="${scope} and ${prev_cwd}/.git"
            # Frame the explanation in the '#' box (wrapped within 80 cols); keep the
            # reconcile command on its own line UNDER the box so it stays copy-pasteable.
            # The wrap never splits a single token (paths survive intact), but a
            # multi-word command would break across lines, so it is left outside the box.
            prose="$(AI_TOOLS_MSG_BOX=1 ai_tools_msg NOTICE 1 \
                "The previous session ended without cleanup (interrupted). Reclaimed ${total_found} agent-owned path(s) under ${scope} to repair the mixed ownership that makes git report \"dubious ownership\".")"
            reconcile="If git still complains, ask the user to run:"$'\n'"  sudo chown -R --from=@SANDBOX_USER@ ${PROJECTS_USER}:@SANDBOX_GROUP@ \"${prev_cwd:-${dir}}\""
            jq -cn --arg ctx "${prose}"$'\n'"${reconcile}" \
                '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' \
                2>/dev/null || true
        fi
    fi
  else
    # Socket DOWN: every CHOWN would fail, so the reclaim is skipped. Surface the stranded
    # paths and the fix rather than a count of a reclaim that did not happen.
    # Count the strand under this session's project and, if a prior session was killed
    # elsewhere, that project too.
    stranded="$(count_git_agent_owned "${dir}")"
    if [[ "${interrupted}" -eq 1 && -n "${prev_cwd}" && "${prev_cwd}" != "${dir}" ]]; then
        stranded=$(( stranded + $(count_git_agent_owned "${prev_cwd}") ))
    fi
    if [[ "${stranded}" -gt 0 ]]; then
        ai_tools_log_warn "handback socket ${HANDBACK_SOCKET} is down -- ${stranded} agent-owned .git path(s) under ${dir} not reclaimed; run: ai-tools --reclaim ${dir}"
        prose="$(AI_TOOLS_MSG_BOX=1 ai_tools_msg NOTICE 1 \
            "The ownership handback socket is down, so ${stranded} file(s) the agent wrote to git stay ai-tools-owned and git may report \"dubious ownership\". Bring the socket up, then reclaim the tree:")"
        reconcile="  sudo systemctl enable --now ai-tools-handback.socket"$'\n'"  ai-tools --reclaim \"${dir}\""
        jq -cn --arg ctx "${prose}"$'\n'"${reconcile}" \
            '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' \
            2>/dev/null || true
    fi
  fi
fi
exit 0

#!/usr/bin/env bash
# /opt/ai-tools/.claude/post-write-sweep.sh
# Write-sweep hook: hand back every ai-tools-owned file and directory under the
# session's project that the precise Write|Edit PostToolUse hook did not catch --
# chiefly files created/modified via the Bash tool (npm/build output, codegen,
# sed/mv, redirects), which carry no file_path and so never trigger
# post-tool-hook.sh.
#
# Runs as ai-tools. Reads the hook JSON on stdin for .cwd (the allowlisted project
# root claude launched in) and sweeps there. Each path is handed to the root
# validator ai-tools-chown, which independently re-checks the allowlist and the
# agent-owned guard -- so this sweep can reach nothing the precise hook could not.
#
# Two modes, selected by $1:
#
#   stop          (default) -- Stop hook, fires at each turn's end. Bounded by a
#                 timestamp marker: only paths modified since the previous sweep
#                 are processed, so the turn-end pass stays cheap. It is a turn-end
#                 net, NOT a per-tool action -- handing a file back makes it
#                 xd:ai-tools 640 (group ai-tools loses write), which would break
#                 an in-progress Bash sequence editing a file in place. Running at
#                 Stop avoids that: the agent keeps ownership mid-turn, handback
#                 happens once control returns.
#
#   session-start -- SessionStart hook, fires when a session begins. UNBOUNDED:
#                 ignores the marker and sweeps every ai-tools-owned path, then
#                 resets the marker to "now". This reclaims leftovers from a prior
#                 session that was killed (crash, kill -9, closed terminal) before
#                 its Stop sweep could run -- the one gap the Stop net cannot close
#                 itself. Gated on the hook's .source: only "startup" and "resume"
#                 (a freshly started process, which is what can follow an
#                 interrupted session) trigger the pass. "clear"/"compact" stay
#                 within a live process whose Stop sweeps already cover the tree,
#                 so they are a no-op (and skip an otherwise pointless full-tree
#                 walk on every compaction).
#
# Heavy/transient trees are pruned in both modes (their contents are world-readable
# anyway, so xd can already read them) and the scan stays on one filesystem (-xdev).
#
# Deploy: sudo install -o @INSTALL_USER@ -g ai-tools -m 750 \
#             scripts/post-write-sweep.sh /opt/ai-tools/.claude/post-write-sweep.sh
# Wired to both the Stop and SessionStart hooks in settings.json (the SessionStart
# entry passes the "session-start" argument).

set -euo pipefail

readonly MARKER="/opt/ai-tools/.claude/.sweep-marker"

# Mode: "stop" (default, bounded by marker) or "session-start" (unbounded reclaim).
readonly MODE="${1:-stop}"

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

# New marker stamped to "now" (scan start). Applied to MARKER only after the sweep
# completes, so anything written during the sweep is still caught next time. In
# session-start mode this resets the marker, so this session's Stop sweeps bound
# from session start.
newref="$(mktemp "/opt/ai-tools/.claude/.sweep.XXXXXX" 2>/dev/null)" || exit 0

# find DIR -xdev \( prune heavy trees \) -prune -o \( ai-tools-owned [newer] file|dir \) -print0
declare -a expr=(
    "${dir}" -xdev
    '(' -name .git -o -name node_modules -o -name .venv -o -name __pycache__ ')' -prune
    -o '(' -user ai-tools
)
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
find "${expr[@]}" 2>/dev/null \
    | while IFS= read -r -d '' path; do
        sudo /usr/local/sbin/ai-tools-chown "${path}" </dev/null || true
      done || true

# Advance the marker to this scan's start time (rename within the same dir keeps
# the mtime). Best-effort; never block the turn/session from proceeding.
mv -f "${newref}" "${MARKER}" 2>/dev/null || rm -f "${newref}" 2>/dev/null || true
exit 0

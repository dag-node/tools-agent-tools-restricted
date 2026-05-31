#!/usr/bin/env bash
# /opt/ai-tools/.claude/post-write-sweep.sh
# Stop hook: at the end of each Claude turn, hand back every ai-tools-owned file
# and directory under the session's project that the precise Write|Edit
# PostToolUse hook did not catch -- chiefly files created/modified via the Bash
# tool (npm/build output, codegen, sed/mv, redirects), which carry no file_path
# and so never trigger post-tool-hook.sh.
#
# Runs as ai-tools. Reads the hook JSON on stdin for .cwd (the allowlisted project
# root claude launched in) and sweeps there. Each path is handed to the root
# validator ai-tools-chown, which independently re-checks the allowlist and the
# agent-owned guard -- so this sweep can reach nothing the precise hook could not.
#
# It is a turn-end net, NOT a per-tool action: handing a file back makes it
# xd:ai-tools 640 (group ai-tools loses write), which would break an in-progress
# Bash sequence that edits a file in place. Running at Stop avoids that -- the
# agent keeps ownership mid-turn, handback happens once control returns.
#
# Bounded by a timestamp marker so it stays cheap: only paths modified since the
# previous sweep are processed. Heavy/transient trees are pruned (their contents
# are world-readable anyway, so xd can already read them).
#
# Deploy: sudo install -o @INSTALL_USER@ -g ai-tools -m 750 \
#             scripts/post-write-sweep.sh /opt/ai-tools/.claude/post-write-sweep.sh

set -euo pipefail

readonly MARKER="/opt/ai-tools/.claude/.sweep-marker"

# The session's working dir (allowlisted project root). No cwd -> nothing to do.
dir="$(jq -r '.cwd // empty' 2>/dev/null)" || exit 0
[[ -n "${dir}" && -d "${dir}" ]] || exit 0

# New marker stamped to "now" (scan start). Applied to MARKER only after the sweep
# completes, so anything written during the sweep is still caught next time.
newref="$(mktemp "/opt/ai-tools/.claude/.sweep.XXXXXX" 2>/dev/null)" || exit 0

# find DIR -xdev \( prune heavy trees \) -prune -o \( ai-tools-owned [newer] file|dir \) -print0
declare -a expr=(
    "${dir}" -xdev
    '(' -name .git -o -name node_modules -o -name .venv -o -name __pycache__ ')' -prune
    -o '(' -user ai-tools
)
# First run (no marker) sweeps all ai-tools-owned paths; later runs only changes.
[[ -f "${MARKER}" ]] && expr+=( -newer "${MARKER}" )
expr+=( '(' -type f -o -type d ')' -print0 ')' )

# Delegate each path to the root validator. </dev/null keeps ai-tools-chown on its
# non-interactive branch. Trailing `|| true` so a find/pipe non-zero (e.g. an
# unreadable subdir) cannot trip set -e / pipefail and skip the marker update.
find "${expr[@]}" 2>/dev/null \
    | while IFS= read -r -d '' path; do
        sudo /usr/local/sbin/ai-tools-chown "${path}" </dev/null || true
      done || true

# Advance the marker to this scan's start time (rename within the same dir keeps
# the mtime). Best-effort; never block the turn from ending.
mv -f "${newref}" "${MARKER}" 2>/dev/null || rm -f "${newref}" 2>/dev/null || true
exit 0

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/source-text.sh
# Hermetic check that every tracked TEXT file in the tree is a POSIX text file: a sequence of lines, each ending
# in a newline, so a non-empty one ends with LF. Binary blobs are excluded by git's own heuristic, not by extension.
#
# The gap this closes: a missing final newline is INVISIBLE in a normal review -- an editor renders the last line
# the same either way -- while several tools downstream of it are not. `git diff` renders the last line
# as `\ No newline at end of file` and a later edit to a neighbouring line then shows both lines as changed; a `cat`
# of two files runs their last and first lines together; `read` drops the final line, which matters here because
# the config parser, the allowlist reader and the hook payload readers are all built on it; and appending to a file
# that lacks one corrupts the line it appends to. None of those failures names the newline as the cause.
#
# Pure `git ls-files` comparison -- no root, no install dependency, no file execution. Only TRACKED content is checked:
# an untracked scratch file in a developer's checkout is theirs.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "source tree: every tracked text file ends with a newline (unit)"

if ! command -v git >/dev/null 2>&1 || [[ ! -d "${ROOT}/.git" ]]; then
    skip "final newline" "not a git checkout"
    finish; exit
fi
if ! command -v python3 >/dev/null 2>&1; then
    skip "final newline" "python3 not available to read the tracked files"
    finish; exit
fi

# The binary test is git's: a NUL byte within the first 8000 bytes. Reusing it rather than an extension list means
# an asset a later commit adds is classified the way `git diff` already classifies it, with no list to maintain and no
# text file silently exempted by its suffix.
offenders="$(cd "${ROOT}" && git ls-files -z | python3 -c '
import os, sys

SNIFF = 8000
bad = []
for path in sys.stdin.buffer.read().split(b"\0"):
    if not path:
        continue
    name = path.decode("utf-8", "surrogateescape")
    if not os.path.isfile(name) or os.path.islink(name):
        continue          # a submodule, a symlink or a dangling entry carries no content of its own
    try:
        with open(name, "rb") as handle:
            head = handle.read(SNIFF)
            if not head:
                continue  # an empty file is a POSIX text file already
            if b"\0" in head:
                continue  # binary, by the same heuristic git diff applies
            handle.seek(-1, os.SEEK_END)
            if handle.read(1) != b"\n":
                bad.append(name)
    except OSError as exc:
        bad.append("%s (unreadable: %s)" % (name, exc.strerror))
print("\n".join(sorted(bad)))
')"

# One result line per offender, rather than one carrying the list: the harness reduces a message to safe-for-display
# characters, so an embedded newline would arrive as '?' and run the paths together on a single unreadable line.
if [[ -z "${offenders}" ]]; then
    pass "every tracked text file ends with a newline"
else
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        fail "${path} does not end with a newline -- fix: printf '\\n' >> ${path}"
    done <<<"${offenders}"
fi

finish

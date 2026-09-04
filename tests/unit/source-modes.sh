#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/source-modes.sh
# Hermetic consistency check on the exec bit git TRACKS for every `.sh` in the tree: within a
# directory, all of them must agree. A directory here holds one kind of file -- the root helpers
# are all commands, the shared libraries are all sourced, the tests are all run as `bash <file>` --
# so a single file disagreeing with its siblings is drift, not intent, and the rule does not require a
# hand-maintained list of which paths are executable.
#
# The gap this closes: a mode flip is INVISIBLE in a normal review. `git show` renders it as a
# zero-line change, and every install path sets its own mode explicitly (`install_subst 750 root
# root`, `%attr(0750, root, root)`, asserted for the installed artifacts by
# tests/integration/perms.sh), so no downstream check has to make the drift noticeable. What it
# does cause is a file that reads as permanently modified in `git status` once a checkout's mode
# and the index disagree -- noise that then hides a real change.
#
# Only the TRACKED mode is checked, never the mode on disk. A working tree's own modes are
# collaborative state (the operator and the sandbox account co-write it, 660/770 under umask 0007
# and setgid directories), vary per host and per checkout, and are deliberately not what the
# repository records.
#
# WHY THE TWO NUMBERS NEVER MATCH, since a reader meets them side by side and they look like a
# contradiction: git stores only two modes for a regular file, 100644 and 100755. It records the
# OWNER EXECUTE BIT alone -- no group bits, no world bits, no setgid. So this tree's
# collaborative 770 is tracked as 100755 and its 660 as 100644, and `ls -l` showing `rwxrwx---`
# for a file reported as 100755 is agreement, not drift. The remediation is therefore stated as a
# numeric mode to apply on disk, while the assertion it satisfies is about the tracked bit.
#
# Pure `git ls-files` comparison -- no root, no install dependency, no file execution.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "source tree: tracked exec bit consistent per directory (unit)"

if ! command -v git >/dev/null 2>&1 || [[ ! -d "${ROOT}/.git" ]]; then
    skip "source mode consistency" "not a git checkout"
    finish; exit
fi

# Every tracked *.sh as "<mode> <dir> <path>". git reports the mode as 100644 or 100755, which is
# exactly the property under test -- the repository's own record, independent of any checkout.
listing="$(cd "${ROOT}" && git ls-files -s -- '*.sh' \
    | awk '{ path = $4; dir = path; sub(/\/[^\/]*$/, "", dir); if (dir == "") dir = "."; print $1, dir, path }')"

if [[ -z "${listing}" ]]; then
    fail "no tracked .sh files found -- the check would pass vacuously"
    finish; exit
fi

pass "scanned $(wc -l <<<"${listing}") tracked .sh files"

# For each directory holding more than one mode, report the minority file(s) as the outlier: the
# majority is what that directory's kind of file is, so naming the odd one out points at the fix
# rather than at the whole directory. With no STRICT majority -- a two-file directory split one
# and one -- there is no odd one out to name, and picking either would send the reader to fix a
# file chosen by a coin flip, so the directory is reported with both sides for a human to settle.
mixed=0
while read -r dir; do
    [[ -n "${dir}" ]] || continue
    mixed=$(( mixed + 1 ))
    counts="$(awk -v d="${dir}" '$2 == d { print $1 }' <<<"${listing}" | sort | uniq -c | sort -rn)"
    top="$(awk 'NR==1 { print $1 }' <<<"${counts}")"
    runner_up="$(awk 'NR==2 { print $1 }' <<<"${counts}")"
    if [[ "${top}" == "${runner_up}" ]]; then
        fail "${dir}/ has no majority exec bit ($(tr '\n' ' ' <<<"${counts}" | tr -s ' ')) -- decide which kind of file it holds"
        continue
    fi
    majority="$(awk 'NR==1 { print $2 }' <<<"${counts}")"
    # Remediation is a NUMERIC chmod on the working tree, which git then records as the tracked
    # bit. Numeric, not `chmod +x`: with no who-clause that means a+x masked by umask, so under
    # the common 0022 it sets the OTHER execute bit too and turns 660 into 771 -- a world bit this
    # tree does not carry. 770/660 say the whole mode outright and are umask-independent, matching
    # the collaborative modes the operator and the sandbox account co-write the tree with.
    if [[ "${majority}" == "100755" ]]; then want=770; else want=660; fi
    while read -r mode _ path; do
        [[ "${mode}" == "${majority}" ]] && continue
        fail "${path} is tracked ${mode} but its siblings in ${dir}/ are ${majority} -- fix: chmod ${want} ${path}"
    done < <(awk -v d="${dir}" '$2 == d' <<<"${listing}")
done < <(awk '{ print $2, $1 }' <<<"${listing}" | sort -u | awk '{ print $1 }' | uniq -d)

if (( mixed == 0 )); then
    pass "every directory's .sh files agree on the tracked exec bit"
fi

finish

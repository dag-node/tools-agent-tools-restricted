#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/source-modes.sh
# Hermetic consistency check on the exec bit git TRACKS for every script in the tree: within a directory, all of them
# must agree. A script is a tracked file named `*.sh` or one whose first line opens with `#!`, so a command written
# in Python and a hook without a suffix are compared beside the shell files they sit with. A directory here holds one
# kind of file -- the root helpers are all commands, the shared libraries are all sourced, the tests are all run
# as `bash <file>` -- so a single file disagreeing with its siblings is drift, not intent, and the rule does not require
# a hand-maintained list of which paths are executable.
#
# WHAT IT DOES NOT ESTABLISH: that a file's bit is the one its installed copy carries. The convention is that a file
# installed with owner execute is tracked 100755, and this check reads agreement between siblings alone, so a directory
# whose scripts all carry the wrong bit passes, and a directory holding one script has no sibling to compare it with.
#
# The gap this closes: a mode flip is INVISIBLE in a normal review. `git show` renders it as a zero-line change,
# and every install path sets its own mode explicitly (`install_subst 750 root root`, `%attr(0750, root, root)`,
# asserted for the installed artifacts by tests/integration/perms.sh), so no downstream check has to make the drift
# noticeable. What it does cause is a file that reads as permanently modified in `git status` once a checkout's mode
# and the index disagree -- noise that then hides a real change.
#
# Only the TRACKED mode is checked, never the mode on disk. A working tree's own modes are collaborative state (the
# operator and the sandbox account co-write it, 660/770 under umask 0007 and setgid directories), vary per host
# and per checkout, and are deliberately not what the repository records.
#
# WHY THE TWO NUMBERS NEVER MATCH, since a reader meets them side by side and they look like a contradiction: git stores
# only two modes for a regular file, 100644 and 100755. It records the OWNER EXECUTE BIT alone -- no group bits, no
# world bits, no setgid. So this tree's collaborative 770 is tracked as 100755 and its 660 as 100644, and `ls -l`
# showing `rwxrwx---` for a file reported as 100755 is agreement, not drift. The remediation is therefore stated
# as a numeric mode to apply on disk, while the assertion it satisfies is about the tracked bit.
#
# Mode and first line are both read from the index (`git ls-files -s`, `git grep --cached`), so an unstaged edit does
# not change which file is judged. No root, no install dependency, no file execution.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "source tree: tracked exec bit consistent per directory (unit)"

if ! command -v git >/dev/null 2>&1 || [[ ! -d "${ROOT}/.git" ]]; then
    skip "source mode consistency" "not a git checkout"
    finish; exit
fi

# Every index entry as "<mode> <sha> <stage>\t<path>". core.quotePath=false leaves a non-ASCII path as written,
# so the one path git still quotes is one holding a control character, a double quote or a backslash, which the tab-
# and line-separated records here cannot carry.
entries="$(cd "${ROOT}" && git -c core.quotePath=false ls-files -s)" || entries=""
if [[ -z "${entries}" ]]; then
    fail "git ls-files printed no entry, so the check has no file to compare and cannot fail"
    finish; exit
fi
unmerged="$(awk -F'\t' '{ split($1, f, " "); if (f[3] != 0) n++ } END { print n + 0 }' <<<"${entries}")"
quoted="$(awk -F'\t' 'substr($2, 1, 1) == "\"" { n++ } END { print n + 0 }' <<<"${entries}")"
if (( unmerged > 0 )); then
    fail "${unmerged} index entries are unmerged, so no tracked mode can be read for them -- resolve the merge first"
    finish; exit
fi
if (( quoted > 0 )); then
    fail "${quoted} tracked paths hold a control character, a quote or a backslash, which this check cannot compare"
    finish; exit
fi

# The files whose first line opens with `#!`, from the staged blobs: `git grep -z` prints "<path>\0<line
# number>\0<line>", and the first line is the one that decides. git grep exits 0 past a blob it cannot read and names it
# on stderr, and exits 1 where no line matched, so a run with either a non-zero status or a line on stderr did not read
# every file, and its listing is not compared.
mktestdir
grep_rc=0
(cd "${ROOT}" && git -c core.quotePath=false grep --cached -I -n -z -e '^#!') \
    > "${TESTDIR}/first-lines" 2> "${TESTDIR}/grep-errors" || grep_rc=$?
if (( grep_rc != 0 )) || [[ -s "${TESTDIR}/grep-errors" ]]; then
    fail "git grep over the index exited ${grep_rc} with $(wc -l < "${TESTDIR}/grep-errors") error lines, so the files opening with #! are not known and none was compared"
    finish; exit
fi
interpreter_paths="$(tr '\0' '\t' < "${TESTDIR}/first-lines" | awk -F'\t' '$2 == 1 { print $1 }')"

# Every script as "<mode>\t<dir>\t<path>". git reports the mode as 100644 or 100755, which is exactly the property
# under test -- the repository's own record, independent of any checkout.
listing="$(awk -F'\t' '
    NR == FNR { if ($0 != "") opens_with_interpreter[$0] = 1; next }
    ($2 in opens_with_interpreter) || $2 ~ /\.sh$/ {
        split($1, f, " "); dir = $2
        if (sub(/\/[^\/]*$/, "", dir) == 0) dir = "."
        print f[1] "\t" dir "\t" $2
    }' <(printf '%s\n' "${interpreter_paths}") <(printf '%s\n' "${entries}"))"

if [[ -z "${listing}" ]]; then
    fail "no tracked script found, so the check has no file to compare and cannot fail"
    finish; exit
fi

script_count="$(wc -l <<<"${listing}")"
suffixless_count="$(awk -F'\t' '$3 !~ /\.sh$/ { n++ } END { print n + 0 }' <<<"${listing}")"
if (( suffixless_count == 0 )); then
    fail "no tracked file outside *.sh was read as opening with #!, so the first-line read is not known to work"
    finish; exit
fi
pass "scanned ${script_count} tracked scripts, ${suffixless_count} of them outside *.sh"

# For each directory holding more than one mode, report the minority file(s) as the outlier: the majority is
# what that directory's kind of file is, so naming the odd one out points at the fix rather than at the whole directory.
# With no STRICT majority -- a two-file directory split one and one -- there is no odd one out to name, and picking
# either would send the reader to fix a file chosen by a coin flip, so the directory is reported with both sides
# for a human to settle.
mixed=0
while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    mixed=$(( mixed + 1 ))
    counts="$(awk -F'\t' -v d="${dir}" '$2 == d { print $1 }' <<<"${listing}" | sort | uniq -c | sort -rn)"
    top="$(awk 'NR==1 { print $1 }' <<<"${counts}")"
    runner_up="$(awk 'NR==2 { print $1 }' <<<"${counts}")"
    if [[ "${top}" == "${runner_up}" ]]; then
        fail "${dir}/ has no majority exec bit ($(tr '\n' ' ' <<<"${counts}" | tr -s ' ')) -- decide which kind of file it holds"
        continue
    fi
    majority="$(awk 'NR==1 { print $2 }' <<<"${counts}")"
    # Remediation is a NUMERIC chmod on the working tree, which git then records as the tracked bit. Numeric, not
    # `chmod +x`: with no who-clause that means a+x masked by umask, so under the common 0022 it sets the OTHER execute
    # bit too and turns 660 into 771 -- a world bit this tree does not carry. 770/660 say the whole mode outright
    # and are umask-independent, matching the collaborative modes the operator and the sandbox account co-write the tree
    # with.
    if [[ "${majority}" == "100755" ]]; then want=770; else want=660; fi
    while IFS=$'\t' read -r mode _ path; do
        [[ "${mode}" == "${majority}" ]] && continue
        fail "${path} is tracked ${mode} but its siblings in ${dir}/ are ${majority} -- fix: chmod ${want} ${path}"
    done < <(awk -F'\t' -v d="${dir}" '$2 == d' <<<"${listing}")
done < <(awk -F'\t' '{ print $2 "\t" $1 }' <<<"${listing}" | sort -u | awk -F'\t' '{ print $1 }' | uniq -d)

if (( mixed == 0 )); then
    pass "every directory's scripts agree on the tracked exec bit"
fi

finish

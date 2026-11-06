#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/admin-groups-restore.sh
# Unit test for _restore_group_static_labels -- the walk `ai-tools-admin selinux groups enable|disable` runs
# over the sandbox-clone area once a group is loaded or unloaded, since a group's file contexts decide labels there.
#
# The clone area is a tree the sandbox account can write, so the walk runs through the descriptor-pinned walker whatever
# process of that account is live (cli.rule.md, ref-section-e6c6), at the canonical path, since the walker refuses
# a root whose path is not the one it reads back. Each status the walker returns is driven with the walker a shell
# function and the clone area a fixture: a walk that labelled every entry prints nothing; one that left hardlinked paths
# is a log line naming them, not a warning; any other exit warns under its code with the walker's line and the walk
# to re-run; a tree named through a symlinked ancestor reaches the walker resolved; a path realpath cannot resolve is
# warned and not walked; an absent area is neither. The function is read out of the helper as text, its two literals
# (the clone area, the walker) rewritten, and run with the helper's own log and warn.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Installed copy first, then the source tree; the function does not read a substituted token.
HELPER="/usr/local/libexec/ai-tools/ai-tools-admin"
[[ -r "${HELPER}" ]] || HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh"

section "ai-tools-admin selinux groups: the clone area's walk after a group change (unit)"

if [[ ! -r "${HELPER}" ]]; then
    skip "the clone area's walk" "helper not readable (neither installed nor in a checkout)"
    finish; exit
fi
mktestdir

restore_text="$(extract_function "${HELPER}" _restore_group_static_labels)"
warn_text="$(extract_function "${HELPER}" warn)"
# log is a one-line definition, which extract_function's `^}` range does not end on.
log_text="$(grep -E '^log\(\)[[:space:]]+\{.*\}$' "${HELPER}" || true)"
if [[ -z "${restore_text}" || -z "${warn_text}" || -z "${log_text}" ]]; then
    fail "${HELPER} does not define _restore_group_static_labels, warn and log in the form this file reads"
    finish; exit
fi
clones="${TESTDIR}/clones"
mkdir -p "${clones}/acme-clone"
ln -s "${TESTDIR}" "${TESTDIR}/alias"
ln -s "${TESTDIR}/absent-target" "${TESTDIR}/dangling"
# run_restore <walk-status> <walker-stderr> [clone-area]: run the function over <clone-area> (the fixture by default)
#   with the walker a shell function printing <walker-stderr> and exiting <walk-status>, answering the fixture's
#   canonical path alone; prints both streams, then the recorder's one line per walker call.
# The call alone is rewritten, so the re-run command the warning names keeps the walker's path.
# shellcheck disable=SC2016  # literal command substitutions, matched and expanded by the inner shell
walker_call='$(/usr/local/libexec/ai-tools/ai-tools-relabel-tree -- ' stub_call='$(fake_walker -- '
# shellcheck disable=SC2016  # the inner shell expands these, not this one
run_restore() {
    local text="${restore_text//\/var\/opt\/ai-tools\/sandbox-projects/${3:-${clones}}}"
    text="${text//"${walker_call}"/"${stub_call}"}"
    : > "${TESTDIR}/recorder"
    bash -c '
        set -euo pipefail
        C_YEL="" C_RST="" C_DIM=""
        eval "$1"; eval "$2"; eval "$3"
        fake_status="$4" fake_stderr="$5" fixture_dir="$6" recorder="$7"
        fake_walker() {
            printf "walk %s\n" "$*" >> "${recorder}"
            [[ "$1" == -- && "$2" == "${fixture_dir}" ]] || return 99
            printf "%s" "${fake_stderr}" >&2; return "${fake_status}"
        }
        _restore_group_static_labels
    ' _ "${log_text}" "${warn_text}" "${text}" "$1" "$2" "${clones}" "${TESTDIR}/recorder" 2>&1 || true
    cat "${TESTDIR}/recorder"
}
if [[ "${restore_text}" != *"${walker_call}"* ]]; then
    fail "_restore_group_static_labels does not run the walker in the form this file rewrites"
    finish; exit
fi

out="$(run_restore 0 "")"
if [[ "${out}" == "walk -- ${clones}" ]]; then
    pass "control: a walk that labelled every entry runs once over the clone area and prints nothing"
else
    fail "a walk at status 0 printed: $(_san "${out}")"
fi
out="$(run_restore 4 $'skipped hardlinked path /c/x (link count 2, inode 7)\nsummary hardlinks-left=1 failures=0\n')"
if grep -qF "left these hardlinked entries at their type: skipped hardlinked path /c/x (link count 2, inode 7)" <<<"${out}" \
        && ! grep -q '^MSG-' <<<"${out}" && ! grep -q 'summary hardlinks-left' <<<"${out}"; then
    pass "a walk that left hardlinked paths is a log line naming them, its summary line dropped, and not a warning"
else
    fail "a walk at status 4 printed: $(_san "${out}")"
fi
for status in 1 3; do
    out="$(run_restore "${status}" $'ai-tools-relabel-tree: could not label /c/y\nsummary hardlinks-left=0 failures=1\n')"
    assert_msg MSG-C9W9 "${out}" "a walker exiting ${status} is warned under its code"
    if grep -qF "could not restore labels under ${clones} -- ai-tools-relabel-tree: could not label /c/y; run: sudo /usr/local/libexec/ai-tools/ai-tools-relabel-tree -- ${clones}" <<<"${out}"; then
        pass "the warning at ${status} carries the walker's line and the walk to re-run"
    else
        fail "a walk at status ${status} printed: $(_san "${out}")"
    fi
done
out="$(run_restore 0 "" "${TESTDIR}/alias/clones")"
if [[ "${out}" == "walk -- ${clones}" ]]; then
    pass "a clone area named through a symlinked ancestor is walked at its canonical path"
else
    fail "a symlinked ancestor printed: $(_san "${out}")"
fi
out="$(run_restore 0 "" "${TESTDIR}/dangling")"
if ! grep -q '^walk ' <<<"${out}" && ! grep -q 'MSG-' <<<"${out}"; then
    pass "a clone area that is not a directory is neither walked nor warned"
else
    fail "a dangling clone area printed: $(_san "${out}")"
fi
# A directory whose canonical path realpath cannot read: a component the test itself cannot make unreadable
# as the sandbox account, so the refusal branch is driven by rewriting the resolve to fail.
out="$(restore_text="${restore_text//realpath -e -- /false -- }" run_restore 0 "")"
assert_msg MSG-S8K7 "${out}" "a clone area realpath cannot resolve is warned under its code"
if ! grep -q '^walk ' <<<"${out}" && grep -qF "realpath cannot resolve it" <<<"${out}"; then
    pass "a clone area realpath cannot resolve is not walked, and the warning says why"
else
    fail "an unresolvable clone area printed: $(_san "${out}")"
fi

finish

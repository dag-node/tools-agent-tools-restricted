#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/sweep-bound.sh
# Unit test for the bound the Stop sweep puts on its walk: every agent's session hook selects the paths whose status
# changed since the sweep marker (`find -cnewer`), so a file moved into the project -- renamed within one filesystem,
# or moved from another -- is selected though its mtime is older than the marker. The live chain runs only inside
# a claimed project (tests/manual/verify-live-flows.sh), so this file drives the bound's find shape over a fixture,
# with `-newer` as the control that misses both moves, and reads both hooks' source for the bound they carry.
#
# The bound narrows only which sandbox-owned paths a pass offers to ai-tools-chown; the `-user` test and the helper's
# own guard decide what is handed back, so no boundary half is owed here. Runs unprivileged or as root.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "sweep bound: a file moved into the project is selected by status-change time (unit)"

mktestdir
WALKED="${TESTDIR}/project"; OUTSIDE="${TESTDIR}/outside"
mkdir -p "${WALKED}" "${OUTSIDE}"
MARKER="${TESTDIR}/.sweep-marker"

# A file another filesystem holds, for the cross-filesystem move. The projects user's home is a residue site, and is
# usually not the filesystem /tmp is.
OTHER_FS=""
if mk_fixture_dir OTHER_FS "${PROJECTS_HOME}" sweepbound 2>/dev/null \
        && [[ "$(stat -c '%d' "${OTHER_FS}")" != "$(stat -c '%d' "${TESTDIR}")" ]]; then
    :
else
    OTHER_FS=""
fi

# The moved files are written, then dated an hour back, before the marker: their mtime and the marker's order them
# the way a file written earlier elsewhere is ordered.
printf 'kept\n' > "${WALKED}/untouched.txt"
printf 'renamed\n' > "${OUTSIDE}/renamed.txt"
[[ -n "${OTHER_FS}" ]] && printf 'moved\n' > "${OTHER_FS}/moved.txt"
touch -d '-1 hour' "${WALKED}/untouched.txt" "${OUTSIDE}/renamed.txt" ${OTHER_FS:+"${OTHER_FS}/moved.txt"}
sleep 1
touch "${MARKER}"
sleep 1
mv "${OUTSIDE}/renamed.txt" "${WALKED}/"
[[ -n "${OTHER_FS}" ]] && mv "${OTHER_FS}/moved.txt" "${WALKED}/"

# select <test> : the names find selects under the walked tree with <test> against the marker, sorted.
select_by() { find "${WALKED}" -type f "$1" "${MARKER}" -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }
by_ctime="$(select_by -cnewer)"
by_mtime="$(select_by -newer)"

if [[ -f "${WALKED}/renamed.txt" && "$(stat -c '%Y' "${WALKED}/renamed.txt")" -lt "$(stat -c '%Y' "${MARKER}")" ]]; then
    pass "setup: the renamed file is in the tree and its mtime is older than the marker"
else
    fail "setup: the renamed file's state is not the one under test"
fi
if [[ "${by_mtime}" != *renamed.txt* ]]; then
    pass "control: -newer does not select a file renamed into the tree"
else
    fail "control: -newer selected the renamed file (${by_mtime}), so the case below is not evidence"
fi
if [[ "${by_ctime}" == *renamed.txt* ]]; then
    pass "-cnewer selects a file renamed into the tree"
else
    fail "-cnewer missed the renamed file: selected '${by_ctime}'"
fi
if [[ -n "${OTHER_FS}" ]]; then
    if [[ "${by_mtime}" != *moved.txt* ]]; then
        pass "control: -newer does not select a file moved in from another filesystem"
    else
        fail "control: -newer selected the moved file (${by_mtime})"
    fi
    if [[ "${by_ctime}" == *moved.txt* ]]; then
        pass "-cnewer selects a file moved in from another filesystem"
    else
        fail "-cnewer missed the moved file: selected '${by_ctime}'"
    fi
else
    skip "a move from another filesystem" "no writable directory on a filesystem other than ${TESTDIR}'s"
fi
if [[ "${by_ctime}" != *untouched.txt* ]]; then
    pass "-cnewer does not select a file untouched since before the marker"
else
    fail "-cnewer selected the untouched file: '${by_ctime}'"
fi

# ── The bound each hook carries ──────────────────────────────────────────────────────────────────────────────────────
section "sweep bound: every agent's session hook bounds its Stop sweep on ctime"
for hook in "${ROOT}"/src/opt/ai-tools/agents/*/session-hook.sh; do
    agent="${hook%/session-hook.sh}"; agent="${agent##*/}"
    source_text="$(<"${hook}")"
    if grep -qF 'expr+=( -cnewer "${MARKER}" )' <<<"${source_text}" \
            && ! grep -qF -- '-newer "${MARKER}"' <<<"${source_text//-cnewer/}"; then
        pass "${agent}: the Stop sweep is bounded by -cnewer on the marker, with no -newer bound"
    else
        fail "${agent}: session-hook.sh does not carry the -cnewer bound alone"
    fi
done

finish

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
# own guard decide what is handed back, so no boundary half is owed here. A directory moved in is the bound's one blind
# spot, since its descendants keep their ctimes: each hook's sweep block is read out of its source and run over a moved
# directory, and must offer what is inside it. Runs unprivileged or as root.
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

# ── A directory moved into the tree ──────────────────────────────────────────────────────────────────────────────────
# A directory moved in takes a new ctime and its descendants keep theirs, so the bound alone selects the directory
# and not the file inside it. Each hook walks a directory its bounded pass selects once more without the bound.
# That block of each hook is read out of its source and run over the fixture, with the handback client replaced
# by a stub recording each path it is offered, its socket test read as a socket that is up, the hook's skip expression
# stubbed to prune `node_modules`, and the walked owner the invoker; the walked root is the invoker's here too, so its
# own new ctime selects it as well, which the de-dup
# answers.
section "sweep bound: a directory moved into the project is walked for its descendants"
MOVED="${OUTSIDE}/moved-dir"
mkdir -p "${MOVED}/node_modules"
printf 'inside\n' > "${MOVED}/inside.txt"; printf 'dep\n' > "${MOVED}/node_modules/dep.js"
touch -d '-1 hour' "${MOVED}/inside.txt" "${MOVED}/node_modules/dep.js" "${MOVED}/node_modules" "${MOVED}"
sleep 1; touch "${MARKER}"; sleep 1
mv "${MOVED}" "${WALKED}/"
by_ctime_dir="$(find "${WALKED}" -cnewer "${MARKER}" -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')"
if [[ "${by_ctime_dir}" == *"moved-dir "* && "${by_ctime_dir}" != *inside.txt* ]]; then
    pass "control: -cnewer selects the moved directory and not the older file inside it"
else
    fail "control: the moved directory's selection is not the state under test: '${by_ctime_dir}'"
fi
walk_owner="$(stat -c '%U' "${WALKED}")"
for hook in "${ROOT}"/src/opt/ai-tools/agents/*/session-hook.sh; do
    agent="${hook%/session-hook.sh}"; agent="${agent##*/}"
    sweep_block="$(awk '/^ai_tools_skip_dirs__build_find_expression sweep /{on=1} on{print} on && /^fi$/ && seen{exit} /done < <\(find "\$\{expr\[@\]\}"/{seen=1}' "${hook}")"
    sweep_block="${sweep_block//\/usr\/local\/bin\/ai-tools-handback-client/stub_client}"
    sweep_block="${sweep_block//@SANDBOX_USER@/${walk_owner}}"
    # shellcheck disable=SC2016  # the hook's own text, matched and replaced as written
    socket_test='! -S "${HANDBACK_SOCKET}"'
    if [[ "${sweep_block}" != *'swept=0'* || "${sweep_block}" != *'find "${expr[@]}"'* \
            || "${sweep_block}" != *"${socket_test}"* ]]; then
        fail "${agent}: the sweep block is no longer where this reads it"
        continue
    fi
    sweep_block="${sweep_block//"${socket_test}"/-z socket-is-up}"
    offered="$(bash -c '
        set -euo pipefail
        dir="$1" MARKER="$2" MODE=stop unbounded=0
        ai_tools_skip_dirs__build_find_expression() { AI_TOOLS_SKIP_DIRS__FIND_EXPRESSION=( "(" -name node_modules ")" -prune -o ); }
        ai_tools_log__debug() { :; }; ai_tools_log__warn() { :; }
        stub_client() { printf "%s\n" "${2#"${dir}/"}"; }
        eval "$3"
        ' _ "${WALKED}" "${MARKER}" "${sweep_block}" 2>&1 | LC_ALL=C sort)" || offered="the block did not run: ${offered}"
    if [[ "$(grep -cxF moved-dir <<< "${offered}")" == 1 && "$(grep -cxF moved-dir/inside.txt <<< "${offered}")" == 1 ]] \
            && ! grep -q 'node_modules' <<< "${offered}"; then
        pass "${agent}: the bounded sweep offers the moved directory and the older file inside it, each once, with the skip kept"
    else
        fail "${agent}: the moved directory's offers: $(_san "${offered}")"
    fi
done

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

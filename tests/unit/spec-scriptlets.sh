#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/spec-scriptlets.sh
# Static check over packaging/ai-tools.spec: every scriptlet section that calls a library function checks,
# with `declare -F`, that the installed library defines each function it calls, and exits 0 when one is missing.
#
# rpm runs a scriptlet from the package it belongs to over the files on disk at that moment. In an upgrade those are
# the new release's libraries, and the old release's %triggerin and its erase-guarded %preun/%postun run against them,
# so a function the new release renamed is reached by a scriptlet that does not know the new name. The guard turns
# that into one line and a skip the installed version's own scriptlet covers. Pure text over the spec; skips outside
# a checkout. %prep and the build sections are not read: they call this tree's own library.
#
# Two further reads over the erase scriptlets, each a property a package host alone would otherwise show: no agent
# %preun nulls the relabel helper's stderr, the stream its deferred-cleanup warning is on; and the selinux %postun reads
# the sandbox account's sessions ahead of its first policy-store write, the gate its comment states.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC="${ROOT}/packaging/ai-tools.spec"
section "spec scriptlets check the library functions they call (unit)"

if [[ ! -r "${SPEC}" ]]; then
    skip "spec scriptlets" "not a source checkout (no ${SPEC})"
    finish; exit
fi

# One record per scriptlet section ahead of the %changelog line: the header line, then the section's text with newlines
# folded, separated by a form feed. A section runs from a scriptlet header to the next line that opens a % section.
scriptlet_header='^%(pre|post|preun|postun|pretrans|posttrans|triggerin|triggerun|triggerpostun|transfiletriggerin|transfiletriggerpostun)( |$)'
mapfile -d $'\f' -t sections < <(
    awk -v hdr="${scriptlet_header}" '
        /^%changelog/ { exit }
        /^%[a-z]/ { if (open) printf "\f"; open = ($0 ~ hdr); if (open) printf "%s\n", $0; next }
        open { printf "%s\n", $0 }
    ' "${SPEC}"
)

checked=0
for sec in "${sections[@]}"; do
    header="${sec%%$'\n'*}"
    # The functions the section calls, read off its code lines alone, since a comment may name one, and the functions
    # its `declare -F` guards name.
    code="$(grep -vE '^[[:space:]]*#' <<< "${sec}" || true)"
    mapfile -t called < <(grep -oE '\b_?ai_tools_[a-z0-9_]+__[a-z0-9_]+\b' <<< "${code}" | sort -u)
    (( ${#called[@]} > 0 )) || continue
    mapfile -t declared < <(grep -oE 'declare -F( +_?ai_tools_[a-z0-9_]+__[a-z0-9_]+)+' <<< "${code}" \
        | grep -oE '\b_?ai_tools_[a-z0-9_]+__[a-z0-9_]+\b' | sort -u)
    missing=()
    for fn in "${called[@]}"; do
        found=0
        for d in "${declared[@]}"; do [[ "${d}" == "${fn}" ]] && { found=1; break; }; done
        (( found )) || missing+=("${fn}")
    done
    guards_exit=1
    while IFS= read -r line; do
        [[ "${line}" == *'exit 0'* ]] || guards_exit=0
    done < <(grep -oE 'declare -F[^;]*;?[^;]*' <<< "${code}" | grep -E '\|\|' || true)
    if (( ${#missing[@]} == 0 )) && (( guards_exit )); then
        pass "${header}: declare -F guards every library function it calls (${#called[@]})"  # prose-check: ignore
    elif (( ${#missing[@]} > 0 )); then
        fail "${header}: called without a declare -F guard: ${missing[*]}"
    else
        fail "${header}: a declare -F guard does not exit 0 when a function is missing"
    fi
    checked=$(( checked + 1 ))
done

if (( checked == 0 )); then
    fail "no scriptlet section calling a library function was found; the parser or the spec changed shape"
else
    pass "${checked} scriptlet section(s) call a library function and were checked"
fi

section "the erase scriptlets keep the helper's stderr and gate the store on the sessions (unit)"

# ai-tools-relabel-agent --remove prints its deferred-cleanup warning on stderr (the config directory left labelled
# while a session runs, with the restorecon the operator owes), so a %preun that nulls that stream hides the one line
# the erase has to show. Read over the whole spec: every agent package's %preun runs the helper.
nulled="$(grep -nE 'relabel-agent --remove.*2>&1' "${SPEC}" || true)"
if [[ -z "${nulled}" ]]; then
    pass "no agent %preun nulls the relabel helper's stderr"
else
    fail "an agent %preun nulls the relabel helper's stderr: ${nulled//$'\n'/; }"
fi

# The selinux %postun's first policy-store write (a rule delete, the module unload) follows its reading of the sandbox
# account's sessions, so an erase with a session open leaves the store as it is. Read as source order over the
# section's code lines.
postun_code=""
for sec in "${sections[@]}"; do
    [[ "${sec%%$'\n'*}" == "%postun -n ai-tools-selinux" ]] || continue
    postun_code="$(grep -vE '^[[:space:]]*#' <<< "${sec}" || true)"
done
if [[ -z "${postun_code}" ]]; then
    fail "the selinux %postun section was not found; the parser or the spec changed shape"
else
    read_hits="$(grep -nE 'ai_tools_sessions__read_live_session_state' <<< "${postun_code}" || true)"
    write_hits="$(grep -nE 'semanage fcontext -d|semodule .*-r ' <<< "${postun_code}" || true)"
    read_line="${read_hits%%:*}"; write_line="${write_hits%%:*}"
    if [[ -n "${read_line}" && -n "${write_line}" ]] && (( read_line < write_line )); then
        pass "the selinux %postun reads the sessions (line ${read_line}) ahead of its first store write (line ${write_line})"
    else
        fail "the selinux %postun does not read the sessions ahead of its first store write (read: '${read_line}', write: '${write_line}')"
    fi
fi

finish

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

finish

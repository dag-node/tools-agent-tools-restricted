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
# the sandbox account's sessions ahead of its first policy-store write, read as source order over its command lines.
# Source order does not show that the writes wait on the reading; unit/spec-selinux-erase.sh runs the scriptlet
# under stubs for that.
#
# Its last section reads the spec through RPM's macro expansion, which every scriptlet body passes
# through before the shell does (the spec's preamble states the escaping rule): no scriptlet carries a percent run
# of odd length ahead of an opening parenthesis, which RPM runs as a command at parse time; and, where `rpmspec` is
# on the host, the spec parses with an empty stderr, and the two parameter expansions a scriptlet's result turns on are
# evaluated from the parsed text.

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
# account's sessions. Read as source order over the section's command lines: an echo or printf line names those commands
# in the text it prints, so each is dropped first.
postun_code=""
for sec in "${sections[@]}"; do
    [[ "${sec%%$'\n'*}" == "%postun -n ai-tools-selinux" ]] || continue
    postun_code="$(grep -vE '^[[:space:]]*(#|echo |printf )' <<< "${sec}" || true)"
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

section "the scriptlets reach the shell as written through RPM's macro expansion (unit)"

# list_odd_paren_runs <text>: print each run of percents directly ahead of `(` whose length is odd -- the form RPM runs
# as a shell command while it parses the spec. An even run is an escaped percent, which reaches the shell halved.
list_odd_paren_runs() {
    local run
    while IFS= read -r run; do
        (( ${#run} % 2 == 0 )) || printf '%s\n' "${run}"
    done < <(grep -oE '%+\(' <<< "$1" | sed 's/($//' || true)
}
# shellcheck disable=SC2016  # the control lines are spec text, read and not expanded
if [[ -n "$(list_odd_paren_runs 'x="${p%(/.*)?}"')" && -z "$(list_odd_paren_runs 'x="${p%%(/.*)?}"')" ]]; then
    odd_runs=""
    for sec in "${sections[@]}"; do
        [[ -z "$(list_odd_paren_runs "${sec}")" ]] || odd_runs+="${sec%%$'\n'*}; "
    done
    if [[ -z "${odd_runs}" ]]; then
        pass "no scriptlet carries an unescaped %( for RPM to run at parse time"
    else
        fail "a scriptlet carries an unescaped %( that RPM runs as a command at parse time: ${odd_runs}"
    fi
else
    fail "the percent-run reader does not tell %( from %%( on its control lines"
fi

if ! command -v rpmspec >/dev/null 2>&1; then
    note "rpmspec" "absent on this host; the parsed-spec checks did not run"
else
    parse_err="$(mktemp)"
    parsed="$(rpmspec -P --define "_sourcedir ${ROOT}/packaging" "${SPEC}" 2>"${parse_err}" || true)"
    parse_errors="$(cat "${parse_err}")"; rm -f "${parse_err}"
    if [[ -n "${parsed}" && -z "${parse_errors}" ]]; then
        pass "rpmspec -P parses the spec with an empty stderr"
    else
        fail "rpmspec -P reported while parsing the spec: ${parse_errors//$'\n'/; }"
    fi
    # The selinux %post's former-module swap keys on the first word of each registry row, and the %postun's project
    # restore line on the literal ahead of a project rule's `(/.*)?`; each expansion is evaluated as RPM ships it.
    group_line="$(grep -m1 -E '^[[:space:]]*_old_group_mod=' <<< "${parsed}" | sed 's/^[[:space:]]*//' || true)"
    literal_line="$(grep -m1 -E '^[[:space:]]*literal="\$\{pattern' <<< "${parsed}" | sed 's/^[[:space:]]*//' || true)"
    # shellcheck disable=SC2016  # the child shells expand these, not this one
    if [[ -n "${group_line}" ]] \
            && [[ "$(bash -c '_row="$1"; eval "$2"; printf "%s" "${_old_group_mod}"' _ "ai_tools_netcore localipc buildexec" "${group_line}")" == ai_tools_netcore ]] \
            && [[ "$(bash -c '_row="$1"; eval "$2"; printf "%s" "${_old_group_mod}"' _ "ai_tools_apphost memfdexec" "${group_line}")" == ai_tools_apphost ]]; then
        pass "the shipped %post reads each former module as its row's first word: ${group_line%%;*}"
    else
        fail "the shipped %post does not read a row's first word as the former module: '${group_line}'"
    fi
    # shellcheck disable=SC2016  # the child shell expands these, not this one
    if [[ -n "${literal_line}" ]] \
            && [[ "$(bash -c 'pattern="$1"; eval "$2"; printf "%s" "${literal}"' _ '/home/op/app\.v1(/.*)?' "${literal_line}")" == '/home/op/app\.v1' ]]; then
        pass "the shipped %postun takes the literal ahead of a project rule's (/.*)?: ${literal_line}"
    else
        fail "the shipped %postun does not take a project rule's literal: '${literal_line}'"
    fi
fi

finish

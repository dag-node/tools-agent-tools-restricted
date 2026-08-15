#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/services.sh
# Unit test for the service-health registry (services.lib.sh), the single source shared by
# `ai-tools --status` and the launch wrapper's pre-launch health warning. Pins:
#   * the '|'-delimited record accessor and the registry shape;
#   * ai_tools_service_state's active/down/absent/unknown mapping, including that a sandbox-user
#     unit reports 'unknown' (not operator-checkable) without calling systemctl;
#   * ai_tools_services_scan's filters -- crucially that the 'wrapper' filter EXCLUDES the handback
#     socket (preflight=shim, warned by ai-tools-run), so the wrapper never double-warns it, and
#     that each down record still carries its remedy command.
#
# systemctl is stubbed as a shell FUNCTION (which overrides the PATH lookup), so the test needs no
# executable shim -- and works where /tmp is mounted noexec. Read-only, no root, no real units.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Installed copy first, then the source tree (the lib carries no token substitution, so identical).
LIB="/usr/local/lib/ai-tools/services.lib.sh"
[[ -r "${LIB}" ]] || LIB="${ROOT}/src/usr/local/lib/ai-tools/services.lib.sh"
section "services: registry accessors + state mapping + scan filters (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "services" "library not readable (neither installed nor in a checkout)"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" \
        || ! declare -F ai_tools_service_field >/dev/null 2>&1 \
        || ! declare -F ai_tools_service_state >/dev/null 2>&1 \
        || ! declare -F ai_tools_services_scan >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define its functions"; finish; exit
fi

# --- (A) the accessor splits a record on '|' ---
rec="unit-x|system|critical|wrapper|because reasons|sudo fix it"
if [[ "$(ai_tools_service_field "${rec}" 1)" == "unit-x" \
   && "$(ai_tools_service_field "${rec}" 4)" == "wrapper" \
   && "$(ai_tools_service_field "${rec}" 6)" == "sudo fix it" ]]; then
    pass "ai_tools_service_field returns the 1st/4th/6th '|' fields"
else
    fail "field accessor wrong: 1=$(ai_tools_service_field "${rec}" 1) 4=$(ai_tools_service_field "${rec}" 4) 6=$(ai_tools_service_field "${rec}" 6)"
fi

# The three known units are registered.
recs="$(ai_tools_service_records)"
if grep -q 'ai-tools-handback.socket' <<<"${recs}" \
   && grep -q 'ai-tools-relabel.path' <<<"${recs}" \
   && grep -q 'nvm-update.timer' <<<"${recs}"; then
    pass "registry lists the handback socket, relabel watcher, and update timer"
else
    fail "registry is missing an expected unit: ${recs}"
fi

# --- systemctl stub: a function overrides the external command for the whole test. State per unit
# comes from _SVC_STATE (active|down|absent); an unset unit defaults to absent. is-active succeeds
# only for 'active'; cat (presence) succeeds for anything not 'absent'. ---
declare -A _SVC_STATE=()
systemctl() {
    local verb="$1"; shift
    local a unit=""
    for a in "$@"; do [[ "${a}" == -* ]] && continue; unit="${a}"; done
    case "${verb}" in
        is-active) [[ "${_SVC_STATE[${unit}]:-absent}" == active ]] ;;
        cat)       [[ "${_SVC_STATE[${unit}]:-absent}" != absent ]] ;;
        *)         return 3 ;;
    esac
}

# --- (B) state mapping ---
_SVC_STATE=( [ai-tools-handback.socket]=active [ai-tools-relabel.path]=down )
st_socket="$(ai_tools_service_state ai-tools-handback.socket system)"
st_relabel="$(ai_tools_service_state ai-tools-relabel.path system)"
st_absent="$(ai_tools_service_state some-uninstalled.service system)"
st_timer="$(ai_tools_service_state nvm-update.timer sandbox-user)"
if [[ "${st_socket}" == active && "${st_relabel}" == down \
   && "${st_absent}" == absent && "${st_timer}" == unknown ]]; then
    pass "state maps active/down/absent, and a sandbox-user unit is 'unknown' (not queried)"
else
    fail "state mapping wrong: socket=${st_socket} relabel=${st_relabel} absent=${st_absent} timer=${st_timer}"
fi

# --- (C) the 'wrapper' scan excludes the socket even when it is down (preflight=shim) ---
_SVC_STATE=( [ai-tools-handback.socket]=down [ai-tools-relabel.path]=down [nvm-update.timer]=down )
if ai_tools_services_scan wrapper; then
    if [[ "${#AI_TOOLS_SERVICES_DOWN[@]}" -eq 1 ]] \
       && [[ "$(ai_tools_service_field "${AI_TOOLS_SERVICES_DOWN[0]}" 1)" == ai-tools-relabel.path ]]; then
        pass "wrapper scan reports only relabel.path down (socket excluded: preflight=shim)"
    else
        fail "wrapper scan set wrong: [${AI_TOOLS_SERVICES_DOWN[*]}]"
    fi
    # the down record carries its exact remedy command
    if [[ "$(ai_tools_service_field "${AI_TOOLS_SERVICES_DOWN[0]}" 6)" == *"systemctl enable --now ai-tools-relabel.path"* ]]; then
        pass "the down record carries its remedy command"
    else
        fail "down record missing its remedy: $(ai_tools_service_field "${AI_TOOLS_SERVICES_DOWN[0]}" 6)"
    fi
else
    fail "wrapper scan found nothing down when relabel.path is down"
fi

# --- (D) all healthy -> the wrapper scan reports nothing ---
_SVC_STATE=( [ai-tools-handback.socket]=active [ai-tools-relabel.path]=active [nvm-update.timer]=active )
if ai_tools_services_scan wrapper; then
    fail "wrapper scan reported a down service on a healthy host: [${AI_TOOLS_SERVICES_DOWN[*]}]"
else
    pass "wrapper scan reports nothing down on a healthy host"
fi

finish

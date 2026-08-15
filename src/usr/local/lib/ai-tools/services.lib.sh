#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/services.lib.sh
# Single source of the systemd units the stack relies on, their purpose, and how to bring each
# back. Shared by `ai-tools --status` (the full report) and the launch wrapper's pre-launch health
# warning (critical system units only), so the detection and the canonical purpose/remedy text live
# here ONCE and each consumer only formats -- no duplicated service knowledge.
#
# Pure data + detection: this library renders nothing (no msg.lib dependency). A consumer sources it,
# scans, and formats the result however it likes (a framed warn at launch, a plain table in --status).
#
# Sourced, not executed. Deployed 644 root:root -- it carries no secrets, and the two principals that
# source it (the operator launch wrapper and the unprivileged CLI) both need to read a system unit's
# is-active/is-enabled, which any user may.

[[ -n "${_AI_TOOLS_SERVICES_LIB_LOADED:-}" ]] && return 0
readonly _AI_TOOLS_SERVICES_LIB_LOADED=1

# Registry: "unit|scope|severity|preflight|purpose|remedy".
#   scope    = system       -- checkable unprivileged via `systemctl is-active` (a system unit's
#                              state is world-readable).
#              sandbox-user  -- a --user unit in the sandbox account's own systemd instance, which
#                              the operator cannot query unprivileged, so its live state is reported
#                              as unknown with a check hint rather than a guessed value.
#   severity = critical      -- down affects a session or the ownership hand-back.
#              maintenance   -- down only stalls background upkeep (no security or launch impact).
#   preflight = wrapper      -- the operator launch wrapper (claude.sh) warns about this at launch.
#               shim         -- ai-tools-run already runs its own dedicated preflight for this
#                              (the handback-socket NOTICE), so the wrapper does NOT also warn --
#                              this field is what keeps the socket from being reported twice.
#               none         -- surfaced only in `ai-tools --status`, never at launch.
# purpose/remedy are operator-facing prose: one sentence of consequence, then the exact command.
# shellcheck disable=SC2034  # read by the accessors below and by both consumers (ai-tools, claude.sh)
_AI_TOOLS_SERVICES=(
  "ai-tools-handback.socket|system|critical|shim|the privilege bridge every ownership hand-back runs over; while it is down, files the agent writes stay ai-tools-owned and git reports \"dubious ownership\"|sudo systemctl enable --now ai-tools-handback.socket"
  "ai-tools-relabel.path|system|critical|wrapper|the watcher that re-labels the agent entrypoint after a Node auto-upgrade repoints its symlink; while it is down, a post-upgrade launch fail-closes on a mislabelled binary|sudo systemctl enable --now ai-tools-relabel.path"
  "nvm-update.timer|sandbox-user|maintenance|none|the sandbox account's toolchain auto-update; while it is down, Node and the agent packages stop receiving updates|sudo ai-tools-bootstrap"
)

# ai_tools_service_records  -- emit each registry record on its own line, for a consumer to iterate.
ai_tools_service_records() { printf '%s\n' "${_AI_TOOLS_SERVICES[@]}"; }

# ai_tools_service_field <record> <1-based field>  -- one '|'-delimited field of a registry record.
ai_tools_service_field() {
    local -a f; IFS='|' read -r -a f <<<"$1"
    printf '%s' "${f[$(( ${2} - 1 ))]:-}"
}

# ai_tools_service_state <unit> <scope>  -- PRINT one of active|down|absent|unknown; the state is
# the stdout value and the function ALWAYS returns 0 (so a `state="$(...)"` capture is safe under
# `set -e` -- no consumer reads the exit status):
#   active  -- the unit is running (is-active).
#   down    -- installed but not active (disabled or stopped) -- the state a remedy addresses.
#   absent  -- the unit is not installed on this host (e.g. relabel.path on a base-only install) --
#              nothing to warn about.
#   unknown -- not checkable here: systemctl missing, or a sandbox-user unit (see scope above).
ai_tools_service_state() {
    local unit="$1" scope="$2"
    if [[ "${scope}" != system ]] || ! command -v systemctl >/dev/null 2>&1; then
        printf 'unknown'; return 0
    fi
    if systemctl is-active --quiet -- "${unit}" 2>/dev/null; then
        printf 'active'
    elif systemctl cat -- "${unit}" >/dev/null 2>&1; then
        printf 'down'
    else
        printf 'absent'
    fi
    return 0
}

# ai_tools_services_scan [all|system|wrapper]  -- fill AI_TOOLS_SERVICES_DOWN with the records whose
# state is 'down', limited by the filter (default 'all'): 'system' = system-scope units; 'wrapper' =
# the ones the launch wrapper warns about (system + preflight=wrapper, i.e. not the socket the shim
# already handles). Returns 0 when at least one is down, 1 when none -- so a consumer can gate a
# warning on `if ai_tools_services_scan wrapper; then`.
# shellcheck disable=SC2034  # AI_TOOLS_SERVICES_DOWN is this scanner's output, read by callers.
AI_TOOLS_SERVICES_DOWN=()
ai_tools_services_scan() {
    local filter="${1:-all}" rec scope preflight unit
    AI_TOOLS_SERVICES_DOWN=()
    for rec in "${_AI_TOOLS_SERVICES[@]}"; do
        scope="$(ai_tools_service_field "${rec}" 2)"
        preflight="$(ai_tools_service_field "${rec}" 4)"
        case "${filter}" in
            system)   [[ "${scope}" == system ]] || continue ;;
            wrapper)  [[ "${scope}" == system && "${preflight}" == wrapper ]] || continue ;;
            all|*)    ;;
        esac
        unit="$(ai_tools_service_field "${rec}" 1)"
        [[ "$(ai_tools_service_state "${unit}" "${scope}")" == down ]] \
            && AI_TOOLS_SERVICES_DOWN+=("${rec}")
    done
    [[ "${#AI_TOOLS_SERVICES_DOWN[@]}" -gt 0 ]]
}

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/services.lib.sh
# Single source of the systemd units the stack relies on, their purpose, and how to bring each
# back. Shared by `ai-tools --status` (the full report) and the launch wrapper's pre-launch health
# warning (critical system units only), so the detection and the canonical purpose/remedy text live
# here ONCE and each consumer only formats -- no duplicated service knowledge.
#
# Pure data + detection: this library does not render output (no msg.lib dependency). A consumer sources it,
# scans, and formats the result however it likes (a framed warn at launch, a plain table in --status).
#
# Detection is two-sourced, by scope. A system unit is queried live (`systemctl is-active`, which
# any user may read) -- except a Type=oneshot service, which is inactive whenever it is healthy and
# is judged by the result of its last run instead. A unit in the sandbox account's own `systemd --user` manager is not reachable
# from the operator's session at all -- the machine transport needs root and no NOPASSWD rule grants
# it -- so its state comes from a LAST-RUN STAMP the unit writes to a path the operator can read
# (/var/opt/ai-tools/state), and from the one live fact that IS readable: whether its unit file is
# installed. Both scopes therefore distinguish a unit that is absent from one that is present and
# in some state, so a unit an optional package never installed is reported as such rather than as
# something this host merely cannot see.
#
# A STAMP IS NOT TRUSTED INPUT, and no reader here treats it as such. Its writer is the sandbox
# account, so that account can state any outcome it likes; the mode on the file and its directory
# bound WHAT it can touch (one inode's contents -- not the directory, not another file, not a
# symlink out of the tree), never whether the contents are true. Two things make that acceptable
# rather than a hole. The stamp gates NO DECISION: it is rendered in one status report, is never
# evaluated, and every value is read through ai_tools_service_stamp_field, which clamps it to a
# short safe-charset token so no control byte or escape sequence reaches the operator's terminal.
# And it is never the weakest link -- an agent able to write it can already write the toolchain the
# stamp reports on, which is the more valuable target by far. (On an enforcing host the confined
# ai_tools_t session can write neither: both resolve to usr_t, which the domain may only read.)
#
# Sourced, not executed. Deployed 644 root:root -- it does not carry any secrets, and the two principals that
# source it (the operator launch wrapper and the unprivileged CLI) both need to read a system unit's
# is-active/is-enabled, which any user may.

[[ -n "${_AI_TOOLS_SERVICES_LIB_LOADED:-}" ]] && return 0
readonly _AI_TOOLS_SERVICES_LIB_LOADED=1

# Registry: "unit|scope|severity|preflight|purpose|remedy|stamp|stamp_mode|max_age".
#   scope    = system       -- checkable unprivileged (a system unit's state is world-readable):
#                              from `systemctl is-active`, or, for a Type=oneshot service, from the
#                              result of its last run, since such a unit is inactive while healthy.
#              sandbox-user  -- a --user unit in the sandbox account's own systemd instance, which
#                              the operator cannot query unprivileged, so its live state comes from
#                              a last-run stamp if the unit publishes one and is reported as
#                              unknown with a check hint otherwise -- never a guessed value.
#   severity = critical      -- down affects a session or the ownership hand-back.
#              maintenance   -- down only stalls background upkeep (no security or launch impact).
#   preflight = wrapper      -- the operator launch wrapper (claude.sh) warns about this at launch.
#               shim         -- ai-tools-run already runs its own dedicated preflight for this
#                              (the handback-socket NOTICE), so the wrapper does NOT also warn --
#                              this field is what keeps the socket from being reported twice.
#               none         -- surfaced only in `ai-tools --status`, never at launch.
#   stamp     = absolute path to a last-run stamp, or empty when this unit has none to read. Only
#               a sandbox-user unit needs one: a system unit's live state is already readable.
#   stamp_mode = what that stamp says ABOUT THIS UNIT -- two units can share one stamp and read
#               different things from it, which is how the timer gets a verdict of its own:
#               result   -- the run's RESULT is this unit's verdict (it IS the unit that ran),
#                           including a run that correctly declined to act (RESULT=skipped).
#               fired    -- only the RECENCY of a SYSTEMD-STARTED run matters: such a run,
#                           successful or not, is proof this unit triggered it, so a failed run
#                           leaves the trigger healthy. A run the operator started by hand is not
#                           evidence about a schedule and is declined (stamp field TRIGGER).
#   max_age   = seconds after which a stamp stops being evidence of a HEALTHY unit, or empty for
#               no freshness judgment. This is what separates "the last run succeeded" from "runs
#               are still happening": every individual run can succeed while the schedule that
#               drives them has silently stopped, and past max_age the unit reports 'stale'.
# purpose/remedy are operator-facing prose: one sentence of consequence, then the exact command.
# A purpose is worded state-neutrally ("without it ...", not "while it is down ..."), since the
# same sentence is printed under down, failed, and stale.
# remedy is EMPTY on a sandbox-user unit whose remedy is simply re-running it: the restart (and
# the journal query) go through that account's --user manager, so they name the sandbox account,
# and this library is deployed with no @SANDBOX_USER@ substitution. The consumer knows the account
# name and composes both -- see ai-tools' cmd_status, the single place that renders that transport.
# shellcheck disable=SC2034  # read by the accessors below and by both consumers (ai-tools, claude.sh)
# The 172800 (48h) grace on both nvm-update records is twice the timer's daily OnCalendar: one
# missed window is a reboot or a suspended laptop, two is a schedule that has stopped.
_AI_TOOLS_SERVICES=(
  "ai-tools-handback.socket|system|critical|shim|the privilege bridge every ownership hand-back runs over; without it, files the agent writes stay ai-tools-owned and git reports \"dubious ownership\"|sudo systemctl enable --now ai-tools-handback.socket|||"
  "ai-tools-relabel.path|system|critical|wrapper|the watcher that re-labels the agent entrypoint after a Node auto-upgrade repoints its symlink; without it, a post-upgrade launch fail-closes on a mislabelled binary|sudo systemctl enable --now ai-tools-relabel.path|||"
  "ai-tools-relabel.service|system|critical|none|the relabel run the watcher triggers, which gives a freshly installed agent entrypoint its ai_tools_exec_t type; without a run that succeeded the entrypoint can carry the wrong type and the next launch fail-closes|sudo systemctl start ai-tools-relabel.service|||"
  "nvm-update.timer|sandbox-user|maintenance|none|the sandbox account's toolchain auto-update schedule; without it, Node and the agent packages stop receiving updates|sudo ai-tools-bootstrap|/var/opt/ai-tools/state/nvm-update.status|fired|172800"
  "nvm-update.service|sandbox-user|maintenance|none|the toolchain update run the timer triggers; without a recent successful run, Node and the agent packages stop receiving updates||/var/opt/ai-tools/state/nvm-update.status|result|172800"
)

# ai_tools_service_records  -- emit each registry record on its own line, for a consumer to iterate.
ai_tools_service_records() { printf '%s\n' "${_AI_TOOLS_SERVICES[@]}"; }

# ai_tools_service_field <record> <1-based field>  -- one '|'-delimited field of a registry record.
ai_tools_service_field() {
    local -a f; IFS='|' read -r -a f <<<"$1"
    printf '%s' "${f[$(( ${2} - 1 ))]:-}"
}

# ai_tools_service_stamp_field <stamp-path> <KEY>  -- PRINT the value of KEY from a last-run stamp
# file, or an empty string; ALWAYS returns 0. A stamp is written by an UNPRIVILEGED sandbox-account job and
# read by the operator's terminal, so the read is defensive on every axis a writer controls: a
# symlink or non-regular path is refused outright (the file is never followed somewhere else), only
# the first 4 KiB is examined (an unbounded line cannot exhaust the reader), the line must match an
# anchored KEY=<value>, and the value must be a short token of [A-Za-z0-9:+._-] -- so no control
# byte, terminal escape, or line break can reach the consumer's output through this path.
ai_tools_service_stamp_field() {
    local stamp="$1" key="$2" line
    [[ -n "${stamp}" && ! -L "${stamp}" && -f "${stamp}" && -r "${stamp}" ]] || return 0
    line="$(head -c 4096 -- "${stamp}" 2>/dev/null \
                | grep -m1 -E "^${key}=[A-Za-z0-9:+._-]{1,64}$" 2>/dev/null)" || return 0
    printf '%s' "${line#*=}"
    return 0
}

# ai_tools_service_unit_property <unit> <property>  -- PRINT one systemd property of a SYSTEM unit,
# or an empty string. ALWAYS returns 0. A system unit's properties are world-readable, so this does
# not need privilege; a sandbox-user unit's are not reachable from here at all and are read from a stamp
# instead. The value is clamped to the same display-safe charset as a stamp field: it reaches the
# operator's terminal, and while systemd is a trusted writer, one reader for both records means one
# place where that guarantee is made.
ai_tools_service_unit_property() {
    local unit="${1:-}" property="${2:-}" value
    [[ -n "${unit}" && -n "${property}" ]] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    value="$(systemctl show -p "${property}" --value -- "${unit}" 2>/dev/null)" || return 0
    [[ "${value}" =~ ^[A-Za-z0-9:+._\ -]{1,64}$ ]] || return 0
    printf '%s' "${value}"
    return 0
}

# ai_tools_service_stamp_age <stamp-path> [key]  -- PRINT the whole seconds since the timestamp the
# stamp records under <key> (default FINISHED), or an EMPTY STRING when that cannot be determined
# (no stamp, no such key, an unparseable value, or no date(1)). ALWAYS returns 0. Consumers must
# treat the empty string as "age unknown" and never as "old": a missing age must not manufacture a 'stale'
# verdict out of an absence.
# The key is a parameter because more than one record in this grammar carries a time an operator
# reads as an age -- the updater's stamp (FINISHED) and an entrypoint pin (VERIFIED) -- and both
# must age through one implementation rather than two that can drift.
# The value reaches date(1) only after ai_tools_service_stamp_field's charset clamp, and as a single
# argument, so a hostile stamp can make this fail to parse and no worse.
ai_tools_service_stamp_age() {
    local stamp="$1" key="${2:-FINISHED}" finished stamped now
    finished="$(ai_tools_service_stamp_field "${stamp}" "${key}")"
    [[ -n "${finished}" ]] || return 0
    command -v date >/dev/null 2>&1 || return 0
    stamped="$(date -u -d "${finished}" +%s 2>/dev/null)" || return 0
    [[ "${stamped}" =~ ^[0-9]+$ ]] || return 0
    now="$(date -u +%s 2>/dev/null)" || return 0
    # A stamp dated in the future (clock skew) is not evidence of staleness; report age 0.
    if [[ "${now}" -gt "${stamped}" ]]; then printf '%s' "$(( now - stamped ))"; else printf '0'; fi
    return 0
}

# _ai_tools_user_unit_installed <unit>  -- 0 when a system-wide `systemd --user` unit FILE of that
# name exists. This is the one question about a sandbox-user unit the operator's session CAN
# answer: the unit files are world-readable even though the manager that runs them is unreachable.
# It separates "installed but unqueryable" from "not installed at all" -- every unit in the
# registry ships with an OPTIONAL package, so absence is a normal state, not a fault to chase.
# The account's own ~/.config/systemd/user is deliberately NOT searched: it sits in a home the
# operator cannot traverse. Every unit named here is shipped to the system-wide directory, so the
# omission leaves the report complete.
# AI_TOOLS_USER_UNIT_DIRS overrides the ':'-separated search path, so a test does not depend on
# which optional packages the host has. It does not widen access -- the value decides only what a
# read-only report says, and its reader already runs as the operator, who can read these paths
# anyway. IFS is pinned for the split: this library is sourced into scripts that set their own.
_ai_tools_user_unit_installed() {
    local unit="$1" dir
    local -a dirs=()
    IFS=: read -ra dirs <<<"${AI_TOOLS_USER_UNIT_DIRS:-/etc/systemd/user:/run/systemd/user:/usr/local/lib/systemd/user:/usr/lib/systemd/user}"
    for dir in "${dirs[@]}"; do
        [[ -n "${dir}" && -e "${dir}/${unit}" ]] && return 0
    done
    return 1
}

# ai_tools_service_state <unit> <scope> [stamp] [stamp_mode] [max_age]  -- PRINT one of
# active|skipped|down|failed|stale|absent|unknown; the state is the stdout value and the function
# ALWAYS returns 0 (so a `state="$(...)"` capture is safe under `set -e` -- no consumer reads the
# exit status). ai_tools_service_state_of below takes a whole record and is what consumers call.
#   active  -- the unit is running (is-active), or its stamp records a recent healthy run.
#   skipped -- the last run ended in a transient condition it did not cause and could not fix (the
#              updater offline: the registry was unreachable, so the toolchain was left alone and
#              the previous version stays). Not a fault -- there is no action for an operator, and calling
#              it FAILED spends attention a real fault then competes with -- but not a claim of
#              health either, so it stays distinct from 'active' and keeps AGEING: a host that is
#              offline once reads skipped, one that has been offline for days reads 'stale'.
#   down    -- installed but not active (disabled or stopped) -- the state a remedy addresses.
#   failed  -- the unit's last run ended non-zero: a stamped sandbox-user unit's recorded RESULT, or
#              a system oneshot's systemd-recorded one. A system unit of any other type that is not
#              running reads 'down' instead, which carries the same remedy.
#   stale   -- the stamp is older than max_age. The unit is not reporting a fault -- which is the
#              point: a schedule that quietly stops firing leaves every recorded run successful and
#              would otherwise read as a permanent, and increasingly wrong, OK.
#   absent  -- the unit is not installed on this host (e.g. relabel.path on a base-only install,
#              or the nvm-update pair without the nodejs integration) -- no fault to warn about.
#   unknown -- not checkable here: systemctl missing, or a sandbox-user unit that is installed but
#              does not publish a stamp (or has not run since the stamp was introduced).
ai_tools_service_state() {
    local unit="$1" scope="$2" stamp="${3:-}" stamp_mode="${4:-result}" max_age="${5:-}"
    # A sandbox-user unit's live state needs that account's own bus, which the operator cannot
    # reach; its last-run stamp is the only evidence available here, so a unit that publishes one
    # is reported from it and one that does not stays 'unknown' rather than guessed.
    if [[ "${scope}" != system ]]; then
        local result age
        # Installed at all? A unit shipped by an OPTIONAL package is legitimately absent (the
        # nvm-update pair without the nodejs integration), and "this host cannot query it" is the
        # wrong thing to say about a unit that is not there -- it invites the operator to chase a
        # unit no package installed. The unit FILE is readable even though the manager is not, so
        # this one question is answerable from here; asked first, so it beats any stale stamp an
        # uninstall left behind.
        if ! _ai_tools_user_unit_installed "${unit}"; then printf 'absent'; return 0; fi
        result="$(ai_tools_service_stamp_field "${stamp}" RESULT)"
        age="$(ai_tools_service_stamp_age "${stamp}")"
        # 'fired' reads recency alone: a run happened, so whatever triggers it is working, and its
        # outcome belongs to the unit that ran (reported separately, in 'result' mode).
        # Only a run SYSTEMD started is evidence about the trigger. A run the operator did by hand
        # is no evidence about the schedule, and counting it would report a dead timer as healthy for
        # the whole grace window -- and, worse, suppress the staleness that is the only way a
        # stopped schedule shows up at all. A stamp whose TRIGGER is anything else (a hand run, or
        # one written before this field existed) declines the judgment rather than guessing either
        # way, the same posture as an unparseable age.
        if [[ "${stamp_mode}" == fired ]]; then
            [[ "$(ai_tools_service_stamp_field "${stamp}" TRIGGER)" == unit ]] \
                || { printf 'unknown'; return 0; }
            [[ -n "${age}" ]] || { printf 'unknown'; return 0; }
        else
            case "${result}" in
                ok|skipped) ;;
                failed)     printf 'failed'; return 0 ;;
                *)          printf 'unknown'; return 0 ;;
            esac
        fi
        # Staleness is judged FIRST, and for a skipped run as much as a successful one: "the
        # registry was unreachable" is a fine answer once and a stopped toolchain after a week, so
        # the grace window is what separates them. 'fired' mode never reads RESULT (a run of any
        # outcome proves its trigger fired), so a skipped run leaves the timer's verdict untouched.
        if [[ -n "${max_age}" && -n "${age}" && "${age}" -gt "${max_age}" ]]; then
            printf 'stale'
        elif [[ "${stamp_mode}" != fired && "${result}" == skipped ]]; then
            printf 'skipped'
        else
            printf 'active'
        fi
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        printf 'unknown'; return 0
    fi
    if ! systemctl cat -- "${unit}" >/dev/null 2>&1; then
        printf 'absent'; return 0
    fi
    # A Type=oneshot service is 'inactive' whenever it is HEALTHY -- it runs, does its work and
    # exits -- so is-active cannot judge it and would read every successful run as 'down'. Its
    # verdict is the result of its last run instead, which is also the only way a run that failed
    # hours ago is still visible. Read from the unit's own type, so a oneshot added later does not need a
    # registry field: the property is what makes is-active meaningless, not this unit's identity.
    if [[ "$(ai_tools_service_unit_property "${unit}" Type)" == oneshot ]]; then
        # Never run: no result to report, and Result reads 'success' on a unit that has not
        # run at all, which would otherwise be an OK no run has earned.
        [[ -n "$(ai_tools_service_unit_property "${unit}" ExecMainStartTimestamp)" ]] \
            || { printf 'unknown'; return 0; }
        if [[ "$(ai_tools_service_unit_property "${unit}" Result)" == success ]]; then
            printf 'active'
        else
            printf 'failed'
        fi
        return 0
    fi
    if systemctl is-active --quiet -- "${unit}" 2>/dev/null; then
        printf 'active'
    else
        printf 'down'
    fi
    return 0
}

# ai_tools_service_state_of <record>  -- ai_tools_service_state for a whole registry record, so a
# consumer never has to know which fields feed the verdict. PRINTs the state; ALWAYS returns 0.
ai_tools_service_state_of() {
    ai_tools_service_state \
        "$(ai_tools_service_field "$1" 1)" "$(ai_tools_service_field "$1" 2)" \
        "$(ai_tools_service_field "$1" 7)" "$(ai_tools_service_field "$1" 8)" \
        "$(ai_tools_service_field "$1" 9)"
}

# ai_tools_service_needs_attention <state>  -- 0 when the state is one a consumer should report as
# a problem (down, failed, stale). The single definition of "broken", so the scanner's set and the
# CLI's report cannot drift apart. 'unknown' is deliberately NOT one: it says the vantage point
# cannot tell, which is not the same as a fault. Nor is 'skipped': it reports a run that correctly
# declined to act, and it becomes 'stale' on its own if the condition persists -- so the escalation is
# the grace window's job, not this predicate's.
ai_tools_service_needs_attention() {
    case "$1" in down|failed|stale) return 0 ;; *) return 1 ;; esac
}

# ai_tools_services_scan [all|system|wrapper]  -- fill AI_TOOLS_SERVICES_DOWN with the records that
# need attention (see the predicate above), limited by the filter (default 'all'): 'system' =
# system-scope units; 'wrapper' = the ones the launch wrapper warns about (system + preflight=
# wrapper, i.e. not the socket the shim already handles). Returns 0 when at least one needs
# attention, 1 when none -- so a consumer can gate a warning on `if ai_tools_services_scan wrapper`.
# Only a sandbox-user unit can be 'failed' or 'stale', so neither the 'system' nor the 'wrapper'
# filter can select one: the wrapper's warning still speaks only of units that are not running.
# shellcheck disable=SC2034  # AI_TOOLS_SERVICES_DOWN is this scanner's output, read by callers.
AI_TOOLS_SERVICES_DOWN=()
ai_tools_services_scan() {
    local filter="${1:-all}" rec scope preflight
    AI_TOOLS_SERVICES_DOWN=()
    for rec in "${_AI_TOOLS_SERVICES[@]}"; do
        scope="$(ai_tools_service_field "${rec}" 2)"
        preflight="$(ai_tools_service_field "${rec}" 4)"
        case "${filter}" in
            system)   [[ "${scope}" == system ]] || continue ;;
            wrapper)  [[ "${scope}" == system && "${preflight}" == wrapper ]] || continue ;;
            all|*)    ;;
        esac
        ai_tools_service_needs_attention "$(ai_tools_service_state_of "${rec}")" \
            && AI_TOOLS_SERVICES_DOWN+=("${rec}")
    done
    [[ "${#AI_TOOLS_SERVICES_DOWN[@]}" -gt 0 ]]
}

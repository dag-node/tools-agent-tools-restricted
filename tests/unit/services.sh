#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/services.sh
# Unit test for the service-health registry (services.lib.sh), the single source shared by
# `ai-tools --status` and the launch wrapper's pre-launch health warning. Pins:
#   * the '|'-delimited record accessor and the registry shape;
#   * ai_tools_service_state's active/down/failed/stale/absent/unknown mapping, including that a
#     sandbox-user unit is never queried through systemctl -- it reports from its last-run stamp,
#     or 'unknown' when it publishes none, and 'absent' when its unit file is not installed at all
#     (the one live fact about that account's manager this vantage point can read, and the
#     difference between a unit no optional package shipped and one this host merely cannot see);
#   * the FRESHNESS half of that mapping, which exists for a failure a RESULT cannot express: every
#     recorded run succeeds while the schedule driving them has stopped. So a successful run goes
#     stale past max_age, a failed one stays failed at any age, an unknown age never manufactures
#     staleness, and 'fired' mode reads the recency of a SYSTEMD-STARTED run alone -- letting one
#     stamp yield two verdicts, a healthy trigger beside the failed run it started, while a run the
#     operator did by hand (which proves nothing about a schedule) is declined in both directions;
#   * ai_tools_service_stamp_field's defensive read of that stamp. It is the one input here a
#     non-root writer controls (the sandbox account writes it) and it is rendered to the operator's
#     terminal, so each way a hostile or corrupt value could reach that terminal -- a symlinked
#     stamp, a control byte or escape sequence in a value, an over-long or unanchored line -- must
#     read as NO value, which in turn degrades the unit to 'unknown' rather than to a wrong verdict;
#   * ai_tools_services_scan's filters -- crucially that the 'wrapper' filter EXCLUDES the handback
#     socket (preflight=shim, warned by ai-tools-run), so the wrapper never double-warns it, and
#     that each reported record still carries its remedy command or the empty remedy whose commands
#     the consumer composes.
#
# systemctl is stubbed as a shell FUNCTION (which overrides the PATH lookup), so the test needs no
# executable shim -- and works where /tmp is mounted noexec. The stamp fixtures are written with
# known content in the test's own /tmp testdir; no real unit, no real stamp, no root.

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
        || ! declare -F ai_tools_service_stamp_field >/dev/null 2>&1 \
        || ! declare -F ai_tools_services_scan >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define its functions"; finish; exit
fi
mktestdir

# A sandbox-user unit's PRESENCE is read from its unit file -- the one live fact the operator's
# session can see about that account's manager -- so the whole file points the lookup at a fixture
# directory. Without it every case below would depend on which optional packages this host
# installed, which is exactly the environment coupling a unit test must not have.
mkdir -p "${TESTDIR}/user-units"
: > "${TESTDIR}/user-units/nvm-update.timer"
: > "${TESTDIR}/user-units/nvm-update.service"
: > "${TESTDIR}/user-units/u"                    # the synthetic unit the freshness cases drive
export AI_TOOLS_USER_UNIT_DIRS="${TESTDIR}/user-units"

# --- (A) the accessor splits a record on '|' ---
rec="unit-x|system|critical|wrapper|because reasons|sudo fix it|/var/tmp/stamp"
if [[ "$(ai_tools_service_field "${rec}" 1)" == "unit-x" \
   && "$(ai_tools_service_field "${rec}" 4)" == "wrapper" \
   && "$(ai_tools_service_field "${rec}" 6)" == "sudo fix it" \
   && "$(ai_tools_service_field "${rec}" 7)" == "/var/tmp/stamp" ]]; then
    pass "ai_tools_service_field returns the 1st/4th/6th/7th '|' fields"
else
    fail "field accessor wrong: 1=$(ai_tools_service_field "${rec}" 1) 4=$(ai_tools_service_field "${rec}" 4) 6=$(ai_tools_service_field "${rec}" 6) 7=$(ai_tools_service_field "${rec}" 7)"
fi

# A record that omits the trailing stamp field yields the empty string, not an unbound-variable
# abort -- the state resolver keys on that emptiness to mean "publishes no stamp".
if [[ -z "$(ai_tools_service_field "unit-y|system|critical|none|why|how" 7)" ]]; then
    pass "an absent trailing field reads as empty"
else
    fail "an absent trailing field did not read as empty"
fi

# The four known units are registered.
recs="$(ai_tools_service_records)"
if grep -q 'ai-tools-handback.socket' <<<"${recs}" \
   && grep -q 'ai-tools-relabel.path' <<<"${recs}" \
   && grep -q 'nvm-update.timer' <<<"${recs}" \
   && grep -q 'nvm-update.service' <<<"${recs}"; then
    pass "registry lists the handback socket, relabel watcher, update timer, and update service"
else
    fail "registry is missing an expected unit: ${recs}"
fi

# The update service's stamp path is the one the updater writes; a drift between the two would
# leave --status permanently reporting 'unknown' with nothing to say why.
svc_rec="$(grep '^nvm-update\.service|' <<<"${recs}")"
if [[ "$(ai_tools_service_field "${svc_rec}" 7)" == /var/opt/ai-tools/state/nvm-update.status ]]; then
    pass "nvm-update.service names the updater's stamp path"
else
    fail "nvm-update.service stamp path wrong: $(ai_tools_service_field "${svc_rec}" 7)"
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
    pass "state maps active/down/absent, and a stampless sandbox-user unit is 'unknown'"
else
    fail "state mapping wrong: socket=${st_socket} relabel=${st_relabel} absent=${st_absent} timer=${st_timer}"
fi

# A sandbox-user unit is never queried through systemctl -- that account's bus is unreachable from
# here, so a stub reporting it 'active' must not be able to leak into the verdict.
_SVC_STATE=( [nvm-update.service]=active )
if [[ "$(ai_tools_service_state nvm-update.service sandbox-user)" == unknown ]]; then
    pass "a sandbox-user unit ignores systemctl entirely (no stamp -> unknown)"
else
    fail "a sandbox-user unit was resolved through systemctl"
fi

# --- (B2) the stamp decides a sandbox-user unit's state ---
STAMP="${TESTDIR}/nvm-update.status"
mk_stamp() { printf '%s\n' "$@" > "${STAMP}"; }

# An uninstalled sandbox-user unit is 'absent', not 'unknown': every unit in the registry ships
# with an OPTIONAL package, and "this host cannot query it" would send the operator after a unit
# no package installed. Asserted against a FRESH stamp, because absence has to beat one an
# uninstall left behind -- the unit is gone whatever the file still says about its last run.
mk_stamp 'RESULT=ok' "FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$(ai_tools_service_state not-installed.timer sandbox-user "${STAMP}" fired 172800)" == absent \
   && "$(ai_tools_service_state not-installed.service sandbox-user "${STAMP}" result 172800)" == absent ]]; then
    pass "an uninstalled sandbox-user unit is 'absent' in both stamp modes, even with a fresh stamp"
else
    fail "an uninstalled sandbox-user unit did not report absent"
fi

mk_stamp '# comment' 'RESULT=ok' 'EXIT_CODE=0' 'FINISHED=2026-08-17T05:50:59Z' 'NODE=v22.20.0'
st_ok="$(ai_tools_service_state nvm-update.service sandbox-user "${STAMP}")"
got_finished="$(ai_tools_service_stamp_field "${STAMP}" FINISHED)"
mk_stamp 'RESULT=failed' 'EXIT_CODE=1' 'FINISHED=2026-08-17T05:50:59Z'
st_failed="$(ai_tools_service_state nvm-update.service sandbox-user "${STAMP}")"
got_rc="$(ai_tools_service_stamp_field "${STAMP}" EXIT_CODE)"
if [[ "${st_ok}" == active && "${st_failed}" == failed \
   && "${got_finished}" == 2026-08-17T05:50:59Z && "${got_rc}" == 1 ]]; then
    pass "a stamped sandbox-user unit reports ok->active / failed->failed, with its detail fields"
else
    fail "stamp mapping wrong: ok=${st_ok} failed=${st_failed} finished=${got_finished} rc=${got_rc}"
fi

# --- (B3) every way the stamp can be hostile or corrupt reads as NO value -> 'unknown' ---
# Each case is a way a value written by the unprivileged sandbox account could otherwise reach the
# operator's terminal, or a way a wrong verdict could be manufactured.
stamp_rejects() {
    local desc="$1"; shift
    mk_stamp "$@"
    local v st
    v="$(ai_tools_service_stamp_field "${STAMP}" RESULT)"
    st="$(ai_tools_service_state nvm-update.service sandbox-user "${STAMP}")"
    if [[ -z "${v}" && "${st}" == unknown ]]; then
        pass "stamp rejected: ${desc}"
    else
        fail "stamp NOT rejected (${desc}): value=$(printf '%q' "${v}") state=${st}"
    fi
}
stamp_rejects "a control byte / terminal escape in the value" "$(printf 'RESULT=ok\033[31mred')"
stamp_rejects "a space-separated trailer after a good value"  'RESULT=ok rm -rf /'
stamp_rejects "an unanchored line (key not at line start)"    'NOTRESULT=ok'
stamp_rejects "an over-long value"                            "RESULT=$(printf 'o%.0s' {1..80})"
stamp_rejects "an empty file"                                 ''

# A syntactically valid but unrecognised result word is a different failure: the field reads fine,
# and it is the STATE resolver that must fall through to unknown rather than guess a verdict.
mk_stamp 'RESULT=maybe'
if [[ "$(ai_tools_service_stamp_field "${STAMP}" RESULT)" == maybe \
   && "$(ai_tools_service_state nvm-update.service sandbox-user "${STAMP}")" == unknown ]]; then
    pass "an unrecognised result word resolves to unknown, not to a guessed verdict"
else
    fail "an unrecognised result word did not resolve to unknown"
fi

# --- (B4) freshness: a successful run that stopped repeating must not read as OK forever ---
# The failure this guards is the one a RESULT alone cannot express: every recorded run succeeded,
# but the schedule driving them stopped, so the last verdict stays green while the toolchain
# silently falls behind. Times are written relative to now so the assertions never depend on a
# fixed date.
at_age() { date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
readonly DAY=86400 GRACE=172800   # GRACE mirrors the registry's 48h max_age

mk_stamp "RESULT=ok" "FINISHED=$(at_age 3600)"
st_fresh="$(ai_tools_service_state u sandbox-user "${STAMP}" result "${GRACE}")"
mk_stamp "RESULT=ok" "FINISHED=$(at_age $(( 13 * DAY )))"
st_old="$(ai_tools_service_state u sandbox-user "${STAMP}" result "${GRACE}")"
if [[ "${st_fresh}" == active && "${st_old}" == stale ]]; then
    pass "a successful run goes active while fresh and stale past max_age"
else
    fail "freshness wrong: fresh=${st_fresh} old=${st_old}"
fi

# A failed run is FAILED at any age -- staleness must never mask a fault as merely old.
mk_stamp "RESULT=failed" "EXIT_CODE=1" "FINISHED=$(at_age $(( 13 * DAY )))"
if [[ "$(ai_tools_service_state u sandbox-user "${STAMP}" result "${GRACE}")" == failed ]]; then
    pass "an old FAILED run stays failed, not stale"
else
    fail "an old failed run was reported stale"
fi

# 'fired' mode: the trigger's verdict is the recency of a SYSTEMD-STARTED run, and nothing else. A
# RECENT run that failed still proves the timer fired, so the timer is healthy while the service it
# started is not -- the two must not collapse into one verdict, or a failing service would also
# condemn a working schedule.
mk_stamp "RESULT=failed" "EXIT_CODE=1" "FINISHED=$(at_age 3600)" "TRIGGER=unit"
st_fired="$(ai_tools_service_state u sandbox-user "${STAMP}" fired  "${GRACE}")"
st_ran="$(  ai_tools_service_state u sandbox-user "${STAMP}" result "${GRACE}")"
if [[ "${st_fired}" == active && "${st_ran}" == failed ]]; then
    pass "one stamp, two verdicts: the trigger is OK while the run it started failed"
else
    fail "'fired' mode was swayed by RESULT: trigger=${st_fired} run=${st_ran}"
fi
mk_stamp "RESULT=ok" "FINISHED=$(at_age $(( 13 * DAY )))" "TRIGGER=unit"
if [[ "$(ai_tools_service_state u sandbox-user "${STAMP}" fired "${GRACE}")" == stale ]]; then
    pass "'fired' mode reports stale when no run has been recorded in a long time"
else
    fail "'fired' mode did not go stale on an old stamp"
fi

# A run the OPERATOR started is not evidence about a schedule. Counting it would report a dead
# timer as healthy for the whole grace window -- and suppress the staleness that is the only way a
# stopped schedule ever surfaces -- so a hand run (and a stamp predating the field) declines the
# judgment in BOTH directions: fresh does not mean OK, old does not mean stale. The run itself is
# still the service's own verdict, which is what keeps this from losing information.
mk_stamp "RESULT=ok" "FINISHED=$(at_age 3600)" "TRIGGER=manual"
st_fired="$(ai_tools_service_state u sandbox-user "${STAMP}" fired "${GRACE}")"
st_ran="$(  ai_tools_service_state u sandbox-user "${STAMP}" result "${GRACE}")"
mk_stamp "RESULT=ok" "FINISHED=$(at_age $(( 13 * DAY )))" "TRIGGER=manual"
st_old="$(ai_tools_service_state u sandbox-user "${STAMP}" fired "${GRACE}")"
mk_stamp "RESULT=ok" "FINISHED=$(at_age 3600)"
st_nofield="$(ai_tools_service_state u sandbox-user "${STAMP}" fired "${GRACE}")"
if [[ "${st_fired}" == unknown && "${st_old}" == unknown && "${st_nofield}" == unknown \
   && "${st_ran}" == active ]]; then
    pass "'fired' mode declines a hand-started run (and a stamp with no TRIGGER), fresh or old"
else
    fail "'fired' mode judged a non-systemd run: fresh=${st_fired} old=${st_old} none=${st_nofield} run=${st_ran}"
fi

# No max_age means no freshness judgment, and an UNPARSEABLE date must not manufacture staleness
# out of an absence -- an unknown age is not an old one.
mk_stamp "RESULT=ok" "FINISHED=$(at_age $(( 99 * DAY )))"
st_nomax="$(ai_tools_service_state u sandbox-user "${STAMP}" result "")"
mk_stamp "RESULT=ok" "FINISHED=not-a-date"
st_baddate="$(ai_tools_service_state u sandbox-user "${STAMP}" result "${GRACE}")"
if [[ "${st_nomax}" == active && "${st_baddate}" == active ]]; then
    pass "no max_age and an unparseable date both decline to claim staleness"
else
    fail "staleness invented: no-max=${st_nomax} bad-date=${st_baddate}"
fi

# A stamp dated in the future (clock skew) reads as age 0, never as a negative or huge age.
mk_stamp "RESULT=ok" "FINISHED=$(at_age -3600)"
if [[ "$(ai_tools_service_stamp_age "${STAMP}")" == 0 \
   && "$(ai_tools_service_state u sandbox-user "${STAMP}" result "${GRACE}")" == active ]]; then
    pass "a future-dated stamp clamps to age 0"
else
    fail "a future-dated stamp gave age $(ai_tools_service_stamp_age "${STAMP}")"
fi

# The registry's own records must carry the freshness policy, or none of the above ever applies in
# production: both nvm-update records point at the stamp, and the timer reads it in 'fired' mode.
svc_rec="$(grep '^nvm-update\.service|' <<<"${recs}")"
tmr_rec="$(grep '^nvm-update\.timer|'   <<<"${recs}")"
if [[ "$(ai_tools_service_field "${svc_rec}" 8)" == result \
   && "$(ai_tools_service_field "${tmr_rec}" 8)" == fired \
   && "$(ai_tools_service_field "${svc_rec}" 9)" =~ ^[0-9]+$ \
   && "$(ai_tools_service_field "${tmr_rec}" 7)" == "$(ai_tools_service_field "${svc_rec}" 7)" ]]; then
    pass "the registry wires the update timer and service to one stamp, read two ways"
else
    fail "registry freshness wiring wrong: svc mode=$(ai_tools_service_field "${svc_rec}" 8) age=$(ai_tools_service_field "${svc_rec}" 9); timer mode=$(ai_tools_service_field "${tmr_rec}" 8)"
fi

# needs_attention is the single definition of "broken" both the scanner and the CLI report from.
# 'unknown' must stay out of it: a vantage point that cannot tell is not a fault, and counting it
# would make every unqueryable unit alarm on a healthy host.
att_ok=true
for _s in down failed stale; do
    ai_tools_service_needs_attention "${_s}" || att_ok=false
done
for _s in active absent unknown; do
    ai_tools_service_needs_attention "${_s}" && att_ok=false
done
if ${att_ok}; then
    pass "needs_attention covers down/failed/stale and excludes active/absent/unknown"
else
    fail "needs_attention classified a state wrongly"
fi

# A symlinked stamp is refused outright -- the read must never follow a writer-chosen path.
rm -f "${STAMP}"
printf 'RESULT=ok\n' > "${TESTDIR}/elsewhere"
ln -s "${TESTDIR}/elsewhere" "${STAMP}"
if [[ -z "$(ai_tools_service_stamp_field "${STAMP}" RESULT)" \
   && "$(ai_tools_service_state nvm-update.service sandbox-user "${STAMP}")" == unknown ]]; then
    pass "stamp rejected: a symlink, however valid its target"
else
    fail "a symlinked stamp was followed"
fi
rm -f "${STAMP}"

# An absent stamp is the normal state of a host whose updater has not run yet: unknown, no error.
if [[ "$(ai_tools_service_state nvm-update.service sandbox-user "${STAMP}")" == unknown ]]; then
    pass "an absent stamp reads as unknown"
else
    fail "an absent stamp did not read as unknown"
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

# --- (E) a FAILED unit is reported by the 'all' scan, and by neither system-scope filter ---
# Driven through a fixture registry (the record array is plain data) so the assertion depends on
# this test's own stamp rather than the host's real one. This is the last section; nothing after it
# reads the registry. The wrapper/system filters must stay clean: only a sandbox-user unit can be
# 'failed', so the launch wrapper's warning still speaks only of units that are not running.
mk_stamp 'RESULT=failed' 'EXIT_CODE=1' 'FINISHED=2026-08-17T05:50:59Z'
_AI_TOOLS_SERVICES=(
  "fixture-sys.path|system|critical|wrapper|a system unit|sudo fix it|"
  "fixture-user.service|sandbox-user|maintenance|none|a sandbox --user unit||${STAMP}"
)
_SVC_STATE=( [fixture-sys.path]=active )
if ai_tools_services_scan all \
   && [[ "${#AI_TOOLS_SERVICES_DOWN[@]}" -eq 1 ]] \
   && [[ "$(ai_tools_service_field "${AI_TOOLS_SERVICES_DOWN[0]}" 1)" == fixture-user.service ]]; then
    pass "the 'all' scan reports a failed sandbox-user unit"
else
    fail "the 'all' scan missed the failed unit: [${AI_TOOLS_SERVICES_DOWN[*]}]"
fi
# Its remedy field is deliberately EMPTY: re-running it goes through the sandbox account's --user
# manager, so the command names that account and the consumer composes it (services.lib.sh ships
# with no @SANDBOX_USER@ substitution). An accidental value here would print an unsubstituted
# command to the operator.
if [[ -z "$(ai_tools_service_field "${AI_TOOLS_SERVICES_DOWN[0]}" 6)" ]]; then
    pass "a sandbox-user record leaves the remedy to the consumer"
else
    fail "the sandbox-user record carries a remedy: $(ai_tools_service_field "${AI_TOOLS_SERVICES_DOWN[0]}" 6)"
fi
if ai_tools_services_scan wrapper || ai_tools_services_scan system; then
    fail "a system-scope filter selected the failed sandbox-user unit: [${AI_TOOLS_SERVICES_DOWN[*]}]"
else
    pass "neither the wrapper nor the system filter can select a failed sandbox-user unit"
fi

finish

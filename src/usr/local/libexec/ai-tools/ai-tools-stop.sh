#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-stop
# Stops running agent sessions and everything they spawned. This is the stop rung of the incident
# ladder: the one control that acts on a session ALREADY RUNNING, where every other operator
# control (unclaim, disable a provider, revoke an operator) only changes what the NEXT launch gets.
#
# THE PROPERTY THIS FILE EXISTS TO HOLD: a stop that is asked for and reported as done HAS
# HAPPENED. The design that follows from it -- why sessions are found by CGROUP rather than by
# process tree, why it takes no target, where containment ends, and the residual failure
# modes -- is documented once, in docs/session-stop.md. This header states only what a reader of
# THIS FILE needs; each function below carries its own local mechanism.
#
# ── Two inverted conventions, stated here so they are not "fixed" back ───────────────────────
# For every other component in this project the safe direction is DON'T ACT. For this one it is
# ACT, and two project-wide conventions invert for that single reason (the "Degradation policy"
# section of docs/session-stop.md):
#
#   1. NO REQUIRED DEPENDENCIES, and deliberately NO `set -e`. A missing library that aborted the
#      run, or an unexpected non-zero that abandoned a half-finished kill, would be a stop that did
#      not happen. `set -u` IS used, and it ends a run just as abruptly wherever a name or an
#      argument is read unset -- so a value a caller may legitimately not have passed is defaulted
#      where it is read (confirm_stop). Every library loads behind an inline fallback; the kill
#      path -- enumerate, signal, verify -- runs on bash builtins plus /proc and /sys reads, with
#      `sleep` its only external. That is independence from THIS PROJECT's libraries, not from the
#      base system: `id`, `date`, `logger`, `timeout`, `systemctl` and `sudo` are each outside the
#      kill path or best-effort within it, and the two that can BLOCK -- the attribution calls into
#      the sandbox account's user manager -- run under `timeout`, since a stop that hangs is a stop
#      that did not happen. NO project library is load-bearing here: this helper takes no input
#      that decides WHICH sessions to stop, so there is nothing left for one to gate.
#   2. THE CONFIRMATION DEFAULTS TO YES (messaging.rule.md requires NO). A pipe, a cron run, an
#      absent msg.lib.sh and a bare Enter all proceed; only a deliberate `n` declines. -n/--dry-run
#      is how this command is looked at without acting.
#
# ── The mechanism, in one paragraph ──────────────────────────────────────────────────────────
# Sessions are enumerated by walking the sandbox account's per-user cgroup slice: a cgroup is the
# one container a spawned process cannot fall out of (inherited across fork(), surviving setsid(2)
# and the double fork). A systemd UNIT cgroup is the unit of work. The graceful pass is SIGTERM,
# deepest-first, re-collected each second; the kill pass writes `cgroup.kill` (atomic, 5.14+) with
# a start-time-validated per-pid loop as the older-kernel fallback. Liveness is read from the
# kernel -- `cgroup.events`, `cgroup.procs`, /proc -- and never from systemd, which is used for
# exactly one thing: reading a unit's WorkingDirectory to attribute a session to a project, which
# is best-effort, is REPORTED rather than acted on, and never decides whether something is running
# or whether it is stopped. Every liveness read fails CLOSED. Nothing is spared -- the account's own
# user manager included -- and it is put back afterwards (restore_user_manager) rather than exempted.
#
# ── Why root, and why there is no per-project form ───────────────────────────────────────────
# Signalling the sandbox account's cgroups and writing cgroup.kill is root's to do. There is no
# NOPASSWD grant -- this is reached through `sudo ai-tools --stop` and sudo prompts, like
# ai-tools-lockdown, -reclaim and -audit.
#
# THIS COMMAND TAKES NO AUTHORIZATION INPUT AND NO TARGET, and that is a deliberate narrowing
# rather than a missing feature. A per-project form would have to decide which sessions belong to
# a project, and the only available answer -- a unit's WorkingDirectory -- is read from the
# sandbox account's own user manager, i.e. from the account being stopped. Anything a session
# reports about itself can therefore shape what a stop reaches, which is exactly backwards. A unit
# name is no better: on a DAC-only host a session can reach that manager and choose its own. So
# attribution is kept for the operator to READ, and the set of things this stops is decided by one
# fact the session cannot influence -- membership of the account's cgroup slice.
#
# The routine way to FINISH a session is `/exit` inside it, which lets it run its own session-end
# handback. This command TERMINATES instead: it kills the process tree, so no handback runs and the
# last turn's writes may still be sandbox-owned (which is why a run names the reclaim per project).
# It is the incident rung, and the scenario that reaches for it is one that wants everything gone.
#
# Usage:  ai-tools-stop [-n|--dry-run] [-y|--yes] [--force] [--all]
#
# `--all` is accepted and inert: every run already stops every session, and the flag exists only so
# a script that spells the intent out is not refused for being explicit. A PATH is refused (exit 2)
# rather than ignored -- see refuse_positional_argument for why that direction, and only that one,
# leaves room to add targeting later without changing what an existing command line means.
#
# WHAT A SUCCESSFUL EXIT MEANS, stated exactly rather than generously. Exit 0 means: every session
# that existed at ENUMERATION was stopped, and a final re-enumeration found nothing still live. It
# does NOT mean no session can exist afterwards -- the launch/stop window is a stated residual. It
# says nothing about the user manager, whose restoration is reported separately and never folded
# into this status.
#
# Exit:   0 stopped and verified gone (or nothing was running)
#         1 something survived SIGKILL -- the only outcome that is not a stop
#         2 usage (an unknown option, or a path -- this command takes no target)
#         4 declined at the confirmation (a deliberate `n`; never a degraded path)
#         5 this helper could not run (no cgroup2 hierarchy, no sandbox uid) -- distinct from 1,
#           so a caller can tell a broken tool from a surviving process
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/libexec/ai-tools/ai-tools-stop.sh /usr/local/libexec/ai-tools/ai-tools-stop

# NOT `set -e`: see inverted convention 1 above. An unexpected non-zero must never abandon a
# half-finished kill.
set -uo pipefail

# A fixed PATH, set before anything is resolved. This helper runs as root and is reachable directly
# as well as through the CLI, so it must not resolve `sleep`, `id` or `realpath` through a PATH an
# invoker chose. sudoers `secure_path` normally covers the sudo route; this covers the direct one
# too, and costs nothing.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# The cgroup walk must see EVERY child directory, and `*/` alone does not: a name beginning with a
# dot is skipped by default globbing. Every name inside the delegated subtree is the DELEGATEE's to
# choose (see the delegation note above), so without `dotglob` a session could place itself in a
# cgroup called `.hidden` and drop out of the enumeration -- including under --all, the form that
# must hold against a hostile session. `nullglob` makes a childless cgroup yield nothing rather than
# the unexpanded pattern. Set once, at file scope: every walk here depends on it.
shopt -s dotglob nullglob

readonly SANDBOX_USER='@SANDBOX_USER@'

# How long the graceful pass gets before the kill. Short and owned here rather than left to a
# unit's TimeoutStopSec (90s by default): an operator waiting that long per session will reach for
# kill -9 by hand and lose the record of having done so.
readonly GRACE_SECONDS=10
# How long the kernel gets to reap after SIGKILL before a process is called unkillable. A task only
# outlives SIGKILL while blocked in an uninterruptible syscall, which resolves well inside this or
# not at all.
readonly REAP_SECONDS=5

STOP_EXIT_REACHED=false

# ── Optional libraries, every one behind a fallback ──────────────────────────────────────────
# Loaded for quality of output ONLY -- a logger and a message renderer. Neither gates anything, and
# neither is allowed to prevent a stop. safe-paths.lib.sh and operator.lib.sh were loaded to vet and
# authorize a caller-supplied target; with no target to take, this helper has nothing for them to
# decide and does not load them at all.
AI_TOOLS_LOG_TAG="ai-tools-stop"
AI_TOOLS_LOG_FILE="stop.log"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
source /usr/local/lib/ai-tools/log.lib.sh 2>/dev/null || true
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh 2>/dev/null || true

# sanitize <text> -- reduce to printable ASCII before anything agent-influenced reaches a terminal
# or the trail. Prefers the shared reducer; the fallback is the same allowlist of bytes, inline,
# because a missing logger must not mean an unsanitized path.
sanitize() {
    if declare -F ai_tools_log_sanitize >/dev/null 2>&1; then
        ai_tools_log_sanitize "$1"; return 0
    fi
    local LC_ALL=C
    printf '%s' "${1//[^[:print:]]/?}"
}

# log_event <level> <message> [FIELD=value ...] -- record to journald and, as root, to the file
# sink. Prefers the shared structured logger; falls back to logger(1) and a direct append, and to
# silence if even those are unavailable. Logging never changes what happens.
log_event() {
    local level="$1" message="$2"; shift 2
    if declare -F ai_tools_log_structured >/dev/null 2>&1; then
        ai_tools_log_structured "${level}" "${message}" "$@"
        return 0
    fi
    message="$(sanitize "${message}")"
    logger -t ai-tools-stop -p "daemon.${level}" -- "${message}" 2>/dev/null || true
    ( umask 077
      printf '%s %-7s [%d] %s\n' "$(date -Is 2>/dev/null)" "${level^^}" "$$" "${message}" \
          >> /var/log/ai-tools/stop.log
    ) 2>/dev/null || true
}

# say_error / say_warn / say_notice <line...> -- framed through msg.lib.sh when it loaded, plain
# otherwise. Output formatting is the most expendable thing here.
#
# THE EMITTERS TAKE LINES ONLY, NOT A LEADING FD -- unlike ai_tools_msg_headline below, whose
# signature IS <title> <fd> <line...>. The two shapes sit next to each other, so passing the
# headline's fd to an emitter reads as consistent and is not: ai_tools_msg_error bakes in fd 2
# already, so a leading `2` becomes the message's FIRST LINE and every refusal prints a stray
# digit above itself. It is invisible in the boxed path and obvious only when captured.
say_error()  { if declare -F ai_tools_msg_error  >/dev/null 2>&1; then ai_tools_msg_error  "$@"; else printf 'ai-tools-stop: %s\n' "$@" >&2; fi; }
say_warn()   { if declare -F ai_tools_msg_warn   >/dev/null 2>&1; then ai_tools_msg_warn   "$@"; else printf 'ai-tools-stop: %s\n' "$@" >&2; fi; }
say_notice() { if declare -F ai_tools_msg_notice >/dev/null 2>&1; then ai_tools_msg_notice "$@"; else printf '%s\n'               "$@";     fi; }
say_headline() {
    local title="$1"; shift
    if declare -F ai_tools_msg_headline >/dev/null 2>&1; then ai_tools_msg_headline "${title}" 1 "$@"
    else printf '\n== %s ==\n%s\n' "${title}" "$*"; fi
}

# ── Arguments ────────────────────────────────────────────────────────────────────────────────
DRY_RUN=false
ASSUME_YES=false
FORCE_KILL=false

# refuse_positional_argument <argument> -- refuse anything that is not an option, and exit 2.
#
# WHY THIS IS AN ERROR RATHER THAN AN IGNORED ARGUMENT. Someone typing a path after --stop believes
# they are NARROWING the command. Proceeding would do the opposite of that belief -- end every
# session on the host -- and the confirmation defaults YES, so a reflexive Enter completes it. A
# refusal costs one corrected command; the alternative costs every running session.
#
# This is not inverted convention 1 being violated. That convention says to act where the
# operator's intent is KNOWN and something environmental is in the way -- no terminal, a missing
# library, a wedged manager. An unexpected argument is ambiguity about what was ASKED FOR, and
# guessing the most destructive reading of it is not degrading toward stopping. Nothing is left
# running either: the operator is one keystroke away, and the message below says which.
#
# AND IT KEEPS A LATER EXTENSION NON-BREAKING. If per-target stopping is ever built -- which needs
# a session-to-project mapping the session cannot influence, i.e. something root records at launch,
# NOT the user manager's WorkingDirectory -- then `--stop <path>` moves from an error to an
# accepted, narrower request. That is a pure widening and no existing command line changes meaning.
# Had it meant "stop everything, ignoring your path", the identical line would silently begin doing
# something different, which is the one outcome that cannot be rolled out safely.
refuse_positional_argument() {
    printf 'ai-tools-stop: this command takes no path: %s\n' "$1" >&2
    printf '%s' '
  ai-tools --stop TERMINATES every agent session on this host, and has no per-project
  form. It is not the way to end a session you are finished with -- it kills the process
  tree, so the session cannot run its own session-end handback.
  A session is attributed to a project by asking the sandbox account'"'"'s own user manager
  -- the account being stopped -- so that attribution is reported, never trusted to
  decide what a stop reaches.

  Terminate every session:    ai-tools --stop
  See what is running first:  ai-tools --stop --dry-run
  End one session cleanly:    /exit inside it, which runs its session-end handback
  Terminate one by hand:      sudo systemctl --user -M @SANDBOX_USER@@.host stop <unit>
' >&2
    exit 2
}

parse_command_line() {
    while (( $# )); do
        case "$1" in
            # Accepted and inert. Every run stops every session with or without it, so --all is
            # kept purely so a script that spells the intent out is not refused for being
            # explicit. `ai-tools --stop` is the documented form.
            --all)        shift ;;
            -n|--dry-run) DRY_RUN=true; shift ;;
            -y|--yes)     ASSUME_YES=true; shift ;;
            --force)      FORCE_KILL=true; shift ;;
            -*) printf 'ai-tools-stop: unknown option: %s\n' "$1" >&2; exit 2 ;;
            *)  refuse_positional_argument "$1" ;;
        esac
    done
    readonly DRY_RUN ASSUME_YES FORCE_KILL
}

# resolve_run_context -- establish who is asking and what account is being stopped, and arm the
# trail's traps. Everything here either succeeds or exits; nothing below it runs on a guess.
resolve_run_context() {
    if [[ "$(id -u)" != "0" ]]; then
        say_error "ai-tools-stop must run as root: stopping a session means signalling ${SANDBOX_USER}'s cgroups" \
                  "run it as: sudo ai-tools --stop"
        exit 5
    fi

    # Who sudo says invoked this -- written by a root process, unreachable by the sandbox account.
    # This is recorded for the TRAIL and authorizes nothing -- the command takes no authorization
    # input, so a caller identity decides nothing about what is terminated. It is still cross-checked
    # rather than taken at face value, because "who asked for this" is the line an operator reads
    # first after an incident and a wrong name there is worse than no name.
    #
    # SUDO_USER ALONE IS NOT PROOF OF A SUDO TRANSACTION. A root shell entered with `sudo -i` keeps
    # SUDO_USER set, so its presence does not establish that *this* invocation came through sudo on
    # behalf of that user -- it may be inherited state from an earlier one. SUDO_UID is cross-checked
    # against it: the two are set together by the same sudo run, so a pair that disagrees is inherited
    # or forged environment and is refused rather than trusted. Both, plus the real uid, are recorded
    # separately, so the trail carries what was observed rather than one derived conclusion.
    CALLER="${SUDO_USER:-root}"
    if [[ -n "${SUDO_USER:-}" ]]; then
        local caller_uid_from_name
        caller_uid_from_name="$(id -u "${SUDO_USER}" 2>/dev/null)"
        if [[ -z "${SUDO_UID:-}" || -z "${caller_uid_from_name}" \
              || "${SUDO_UID}" != "${caller_uid_from_name}" ]]; then
            log_event warning \
                "SUDO_USER=${SUDO_USER} does not agree with SUDO_UID=${SUDO_UID:-<unset>} -- recording this as a direct root invocation rather than trusting the name" \
                "AI_TOOLS_SUDO_USER=${SUDO_USER}" "AI_TOOLS_SUDO_UID=${SUDO_UID:-}" "AI_TOOLS_RESULT=identity-rejected"
            CALLER="root"
        fi
    fi
    readonly CALLER

    SANDBOX_UID="$(id -u "${SANDBOX_USER}" 2>/dev/null)"
    if [[ -z "${SANDBOX_UID}" ]]; then
        say_error "ai-tools-stop: cannot resolve the uid of ${SANDBOX_USER}, so no cgroup can be located" \
                  "the sandbox account is missing -- reprovision with: sudo ai-tools-bootstrap"
        log_event error "REFUSED: ${SANDBOX_USER} has no uid; cannot locate any session cgroup"
        exit 5
    fi
    readonly SANDBOX_UID

    # An incomplete run must be visible in the trail. The trap covers every exit including a signal
    # that bash can handle; only SIGKILL of this helper escapes it, which is a documented residual.
    trap record_incomplete_run EXIT
    # A signal during a stop is its own event, not merely an incomplete run: an operator who
    # interrupts one mid-way needs the trail to say a kill was in flight when it happened, because
    # the tree is then in whatever state that pass left it. Named separately from the EXIT trap so
    # the two causes are distinguishable. SIGKILL of this helper remains untrappable and is a stated
    # residual.
    trap 'log_event error "stop run by ${CALLER} interrupted by a signal -- some sessions may be partially stopped" "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_RESULT=interrupted"; STOP_EXIT_REACHED=true; exit 130' INT TERM HUP
}

record_incomplete_run() {
    ${STOP_EXIT_REACHED} && return 0
    log_event error "stop run by ${CALLER} ended without completing -- state unverified" \
        "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_RESULT=incomplete"
}

# ── Locating the sandbox account's cgroups ───────────────────────────────────────────────────
# cgroup2_mount -- PRINT the cgroup v2 hierarchy's mount point. Unified hosts mount it at
# /sys/fs/cgroup; a hybrid host puts v1 controllers there and v2 at /sys/fs/cgroup/unified. Read
# from /proc/mounts rather than assumed, and with no external command.
cgroup2_mount() {
    local mount_point fstype
    while read -r _ mount_point fstype _; do
        [[ "${fstype}" == "cgroup2" ]] && { printf '%s' "${mount_point}"; return 0; }
    done < /proc/mounts
    return 1
}

# resolve_cgroup_layout -- fix the three paths the whole enumeration is expressed against, or
# refuse. Every one is derived from the host, never assumed.
resolve_cgroup_layout() {
    CGROUP2_MOUNT="$(cgroup2_mount)"
    if [[ -z "${CGROUP2_MOUNT}" ]]; then
        say_error "ai-tools-stop: this host has no cgroup v2 hierarchy, so sessions cannot be enumerated or stopped reliably." \
                  "Stop them by hand and report the host: sudo systemctl --user -M ${SANDBOX_USER}@.host list-units"
        log_event error "REFUSED: no cgroup2 mount; cannot enumerate sessions for ${CALLER}"
        exit 5
    fi
    readonly CGROUP2_MOUNT
    # The account's own manager slice. A process the operator's sudo spawned under that account
    # lives in the INVOKING session's slice, not this one, so scoping to this path is also what
    # keeps this helper from selecting its own children.
    #
    # The root is the account's WHOLE per-user slice, not just its `user@<uid>.service` manager
    # subtree. systemd places login session scopes (`session-N.scope`) as SIBLINGS of the manager
    # service, under the same per-user slice -- so a scan rooted at the manager alone has a blind
    # spot for anything not started by that manager. The sandbox account has no login shell and no
    # password, so nothing should ever appear there; scanning the wider root costs one directory
    # level and removes the need for that to be true.
    #
    # It stays scoped to the ACCOUNT's slice rather than widening to uid alone, which is what keeps
    # the scan off this helper's own `sudo -u` children: those share the account's uid but live in
    # the INVOKING user's slice.
    readonly SANDBOX_SLICE="${CGROUP2_MOUNT}/user.slice/user-${SANDBOX_UID}.slice"
    # The manager unit, named exactly rather than by basename. It is descended into but never
    # emitted as a session; nothing is exempt from the stop. See find_session_cgroups.
    readonly MANAGER_SERVICE="${SANDBOX_SLICE}/user@${SANDBOX_UID}.service"
}

# find_session_cgroups -- PRINT one absolute cgroup directory per live session, deepest first.
# Every directory under the account's manager slice is a candidate except init.scope, which holds
# `systemd --user` and its (sd-pam) helper. Recursion is a bash glob walk, so no `find` is needed
# and a sandbox that forbids external binaries cannot disarm this.
find_session_cgroups() {
    [[ -d "${SANDBOX_SLICE}" ]] || return 0
    local -a stack=("${SANDBOX_SLICE}")
    local current child leaf
    # Tasks placed directly in the manager slice belong to no unit at all. systemd does not put
    # them there, so this is the "something else entirely" case -- reported rather than skipped.
    has_own_tasks "${SANDBOX_SLICE}" && printf '%s\n' "${SANDBOX_SLICE}"
    while (( ${#stack[@]} )); do
        current="${stack[-1]}"; unset 'stack[-1]'
        for child in "${current}"/*/; do
            child="${child%/}"
            [[ -d "${child}" ]] || continue
            leaf="${child##*/}"
            # NOTHING IS EXEMPT -- and that is the guarantee, not an oversight.
            #
            # An exemption is a place to hide. Every name inside the delegated subtree is the
            # DELEGATEE's to choose, and on a DAC-only host a session can reach its own user
            # manager and ask for a unit by any name it likes, so an exemption expressed as a name
            # is one the monitored system can claim for itself. Expressed as an exact path it is
            # still a destination: moving tasks into a spared cgroup is the other DAC-only escape.
            # Sparing nothing closes both at once, and costs no distro-specific knowledge -- no
            # unit name appears in this file, so there is nothing here to differ between EL9,
            # EL10 and Fedora.
            #
            # `init.scope` is therefore enumerated and stopped like anything else, the account's
            # own `systemd --user` and its (sd-pam) helper included. What that would otherwise
            # break -- the next launch finding no --user instance -- is repaired afterwards by
            # restore_user_manager rather than bought with an exemption.
            #
            # ONE cgroup is still special-cased, and it is not an exemption:
            #   user@<uid>.service -- the manager unit. DESCENDED INTO but never emitted, because
            #                         its name ends in `.service`, so the stop-at-first-unit rule
            #                         below would otherwise swallow the whole manager subtree as a
            #                         single "session" and never reach the real units inside it.
            #                         Its contents, init.scope among them, are emitted instead --
            #                         so everything under it is still stopped, and the operator's
            #                         confirmation lists real units rather than one opaque row.
            if [[ "${child}" == "${MANAGER_SERVICE}" ]]; then
                has_own_tasks "${child}" && printf '%s\n' "${child}"
                stack+=("${child}")
                continue
            fi
            if [[ "${leaf}" == *.service || "${leaf}" == *.scope ]]; then
                # A unit is ONE session. Its nested cgroups are part of it -- cgroup_pids counts
                # them and cgroup.kill kills them -- so descending further would list the same
                # processes again under a second heading, double the count the operator confirms
                # against, and (worse) offer a parent SLICE as a stoppable thing, which would take
                # every sibling unit with it.
                printf '%s\n' "${child}"
            else
                has_own_tasks "${child}" && printf '%s\n' "${child}"
                stack+=("${child}")
            fi
        done
    done
}

# has_own_tasks <cgroup-dir> -- succeed when tasks sit in THIS cgroup's own cgroup.procs, ignoring
# descendants. This is what separates "a slice, whose tasks all live in the units below it" from
# "a cgroup holding processes directly", and it is why enumerating units does not lose anything:
# the only place a task can hide from a unit walk is a slice, and a slice with its own tasks is
# emitted in its own right.
#
# FAIL-CLOSED WHERE A READ ERROR IS DISTINGUISHABLE, which is the whole point. "I could not read
# cgroup.procs" and "there are no tasks" are different facts, and collapsing them is a fail-open on
# the predicate the guarantee rests on. Only one failure means empty -- the file not existing, i.e.
# the cgroup was removed, which is the successful outcome.
#
# Bash cannot tell a failed read(2) from a clean EOF: `read` returns 1 for both, and so does
# `x="$(< file)"`. Verified, not assumed. So each cause is separated by a fact that IS observable:
#
#   permission-unreadable -- `-r` answers it directly, and answers LIVE.
#   THREADED cgroup       -- the kernel's documented case, and the one that matters here: in a
#                            threaded subtree every cgroup.procs below the threaded root fails the
#                            read (EOPNOTSUPP) while the cgroup holds live threads, and the file is
#                            permission-readable, so `-r` does NOT catch it. cgroup.threads is
#                            readable in EVERY cgroup including those, so it is the corroborating
#                            source: no pid but a tid means tasks. In a domain cgroup the two
#                            always agree (a member process' threads are in its own cgroup), so
#                            consulting it costs an ordinary empty cgroup one extra failed open.
#
# What remains indistinguishable -- a cgroup.procs that is present, permission-readable, and errors
# for some third reason with no cgroup.threads beside it -- is not a shape cgroupfs produces.
has_own_tasks() {
    local first_task=""
    [[ -e "$1/cgroup.procs" ]] || return 1          # cgroup gone == no tasks, the good outcome
    # `2>/dev/null` precedes the input redirect: see the note in cgroup_pids.
    read -r first_task 2>/dev/null < "$1/cgroup.procs"
    [[ -n "${first_task}" ]] && return 0
    [[ -r "$1/cgroup.procs" ]] || return 0          # exists, unreadable: assume LIVE
    read -r first_task 2>/dev/null < "$1/cgroup.threads"
    [[ -n "${first_task}" ]]
}

# cgroup_unit_name <cgroup-dir> -- PRINT the systemd unit this cgroup belongs to, or empty.
cgroup_unit_name() {
    local leaf="${1##*/}"
    [[ "${leaf}" == *.service || "${leaf}" == *.scope ]] && printf '%s' "${leaf}"
}

# ── Classification (advisory, exactly like attribution) ──────────────────────────────────────
# The account's slice holds more than agent sessions: its own `systemd --user` and `init.scope`, a
# dbus broker, and a login session scope for every `sudo -u` that crossed pam_systemd. All of them
# are terminated -- nothing is exempt -- but calling four such cgroups "4 agent sessions" in the
# table an operator confirms against, and in the line they read first after an incident, is untrue,
# and untrue in the direction that inflates how much agent work was running.
#
# THIS CHANGES A LABEL AND A COUNT, NEVER A TARGET. It has the same standing as
# unit_working_directory and carries the same caveat: a unit name inside the delegated subtree is
# the delegatee's to choose, so a session can name itself out of the agent class -- and gains
# nothing by it, because both classes are enumerated, listed and killed identically. Nothing here
# is consulted to decide what a stop reaches; that remains cgroup-slice membership alone.

# session_is_agent <unit-name> -- succeed for a unit ai-tools-run started. It names every session
# `<SANDBOX_USER>-<agent>-<pid>.service`, so this matches THIS PROJECT's own prefix rather than any
# distro's unit names -- the file still contains no name that differs between EL9, EL10 and Fedora.
session_is_agent() {
    [[ "$1" == "${SANDBOX_USER}-"*.service ]]
}

# session_class_note <unit-name> -- PRINT the parenthetical a non-agent row is marked with, or
# empty for an agent session.
#
# ONE MARKER, deliberately, rather than naming the user manager separately. Distinguishing it would
# take either a path test against MANAGER_SERVICE -- which is wrong, since every unit that manager
# starts is inside its subtree, agent sessions included, so the account's dbus broker came out
# labelled "user manager" -- or an `init.scope` literal, which would put a systemd unit name back
# in a file that deliberately holds none. The headline already states that the manager is among
# these and is restarted afterwards, which is the part an operator acts on.
session_class_note() {
    session_is_agent "$1" && return 0
    printf '(account plumbing)'
}

# cgroup_pids <cgroup-dir> -- PRINT every pid in this cgroup AND its descendants. cgroup.procs is
# per-cgroup, so a nested cgroup's members are not listed by its parent and the subtree is walked.
# This is the liveness source of truth: a task cannot remove itself from a cgroup, so it cannot
# hide from this by forking, calling setsid(2), or being re-parented to PID 1.
# Emission is DEEPEST FIRST, so a caller signalling in order reaches children before their parents
# and a parent is never left waiting on a child it can still see. The walk is breadth-first, which
# yields the directories in non-decreasing depth, and they are then read in reverse -- rather than
# a depth-ordered sort, which would need an external command in the middle of the kill path.
cgroup_pids() {
    local -a directories=("$1")
    local index=0 current child pid
    while (( index < ${#directories[@]} )); do
        current="${directories[index]}"; index=$(( index + 1 ))
        for child in "${current}"/*/; do
            child="${child%/}"
            [[ -d "${child}" ]] && directories+=("${child}")
        done
    done
    for (( index = ${#directories[@]} - 1; index >= 0; index-- )); do
        # `2>/dev/null` PRECEDES the input redirect deliberately: redirections are applied left to
        # right, so with the order reversed a cgroup that disappeared mid-walk (the normal outcome
        # of a successful kill) writes its failure to the real stderr before the suppression is
        # installed. Verified, not assumed.
        while read -r pid; do
            [[ -n "${pid}" ]] && printf '%s\n' "${pid}"
        done 2>/dev/null < "${directories[index]}/cgroup.procs"
    done
}

# cgroup_is_live <cgroup-dir> -- succeed while any task remains in the subtree. Deliberately not
# `systemctl is-active`: that asks the manager, and the manager is one of the things that can be
# broken. A cgroup with no tasks is stopped whatever any daemon believes.
# It walks rather than reusing cgroup_pids because this is the VERIFICATION predicate and the one
# place a missing external command would be catastrophic: `cgroup_pids | head -n1` yields an empty
# string when `head` is absent, which reads as "no tasks" and would report a stop as complete while
# the session is still running -- a fail-open on the single check the guarantee rests on. Walking
# in-shell also exits at the first task found, so it is cheaper than collecting every pid to ask a
# yes/no question.
#
# `cgroup.events` is consulted FIRST, because it is the kernel's own answer to exactly this
# question: its `populated` field is 1 while the cgroup OR ANY DESCENDANT holds a live process, so
# one read replaces the whole walk and cannot disagree with the kernel's view. It is absent on the
# root cgroup only, and every target here is a non-root cgroup. The walk remains as the fallback
# for a kernel or layout that does not present it.
#
# Both paths fail closed: an unreadable or unparseable answer reports LIVE. A cgroup directory that
# no longer exists is the one failure that reports empty, because that is what a completed kill
# looks like.
cgroup_is_live() {
    [[ -d "$1" ]] || return 1                        # removed: the successful outcome
    local field value
    if [[ -e "$1/cgroup.events" ]]; then
        if [[ -r "$1/cgroup.events" ]]; then
            while read -r field value; do
                [[ "${field}" == "populated" ]] || continue
                [[ "${value}" == "0" ]] && return 1
                return 0
            done 2>/dev/null < "$1/cgroup.events"
        fi
        # Present but unreadable, or readable with no `populated` line: unprovable, so LIVE.
        return 0
    fi
    local -a directories=("$1")
    local index=0 current child
    while (( index < ${#directories[@]} )); do
        current="${directories[index]}"; index=$(( index + 1 ))
        has_own_tasks "${current}" && return 0
        for child in "${current}"/*/; do
            child="${child%/}"
            [[ -d "${child}" ]] && directories+=("${child}")
        done
    done
    return 1
}

# ── Signalling ───────────────────────────────────────────────────────────────────────────────
# pid_start_time <pid> -- PRINT /proc/<pid>/stat field 22, the process' start time in clock ticks.
# It is unique per pid for that process' lifetime, which makes it the portable guard against
# signalling a RECYCLED pid: capture it when the pid is collected, re-check it immediately before
# the kill. comm (field 2) may contain spaces and parentheses, so the fields are read after the
# LAST ')' -- field 22 is then index 19.
#
# Failing to read it means the process is GONE: this runs as root, the pid came from a cgroup being
# torn down, and root's only reason to fail on /proc/<pid>/stat is that the entry no longer exists.
# So a read failure skips the pid, which is correct rather than fail-open -- there is nothing left
# to signal. The readability test comes first purely to keep the common vanished-pid case off
# stderr; the read is still checked, because the pid can exit between the two.
pid_start_time() {
    local stat_line fields_after_comm
    [[ -r "/proc/$1/stat" ]] || return 1
    stat_line="$(< "/proc/$1/stat")" || return 1
    [[ -n "${stat_line}" ]] || return 1
    fields_after_comm="${stat_line##*) }"
    local -a fields
    read -ra fields <<< "${fields_after_comm}"
    (( ${#fields[@]} > 19 )) || return 1
    printf '%s' "${fields[19]}"
}

# signal_pids_validated <signal> <pid>... -- signal each pid only if its start time still matches
# what it had when it was collected, so a pid recycled in between is skipped rather than signalled
# blind. `kill` is a bash builtin, so this needs no external binary. A pid that has already exited
# is not an error -- that is the outcome being aimed at.
signal_pids_validated() {
    local signal="$1"; shift
    local entry pid expected_start current_start
    for entry in "$@"; do
        pid="${entry%%:*}"; expected_start="${entry#*:}"
        current_start="$(pid_start_time "${pid}")" || continue
        [[ "${current_start}" == "${expected_start}" ]] || continue
        kill "-${signal}" "${pid}" 2>/dev/null
    done
}

# collect_pids_with_start_time <cgroup-dir> -- PRINT `<pid>:<start-time>` per live task, which is
# what signal_pids_validated consumes. Collected fresh on every pass: a set read once and signalled
# twice would miss whatever was forked in between.
collect_pids_with_start_time() {
    local pid start
    while read -r pid; do
        start="$(pid_start_time "${pid}")" || continue
        printf '%s:%s\n' "${pid}" "${start}"
    done < <(cgroup_pids "$1")
}

# terminate_gracefully <cgroup-dir> -- the SIGTERM pass. Succeeds when the subtree empties within
# the grace. Re-collects each second so a child forked after the previous pass is signalled too,
# and cgroup_pids returns deepest-first, so children are reached before their parents.
terminate_gracefully() {
    local cgroup_directory="$1" waited=0
    local -a pids
    while (( waited < GRACE_SECONDS )); do
        mapfile -t pids < <(collect_pids_with_start_time "${cgroup_directory}")
        (( ${#pids[@]} )) || return 0
        signal_pids_validated TERM "${pids[@]}"
        sleep 1
        waited=$(( waited + 1 ))
    done
    ! cgroup_is_live "${cgroup_directory}"
}

# kill_outright <cgroup-dir> -- the unrefusable pass. Succeeds when the subtree is empty.
#
# cgroup.kill is the mechanism that makes the guarantee: one write freezes the cgroup and SIGKILLs
# every member INCLUDING descendants, atomically, so there is no window in which a fork can outrun
# the signal. Where the kernel predates it (< 5.14), the fallback re-collects and re-signals in a
# loop, which narrows that window to one iteration but does not close it -- which is exactly why
# cgroup.kill is preferred rather than treated as an optimisation.
kill_outright() {
    local cgroup_directory="$1" waited=0
    local cgroup_kill_reported=false
    local -a pids
    while (( waited < REAP_SECONDS )); do
        cgroup_is_live "${cgroup_directory}" || return 0
        # Re-asserted every pass, not written once before the loop. The write is idempotent and
        # costs nothing, and writing it once would make the whole guarantee rest on a single
        # syscall whose failure is invisible. Re-asserting also covers a nested cgroup created
        # between passes, which the one-shot form would leave to the pid fallback alone.
        #
        # A failure is REPORTED, once per session, and the two reasons are not the same event: an
        # absent file is an old kernel and expected, while a present file that will not take the
        # write means the atomic mechanism is unavailable on a host that should have it, and the
        # run has silently dropped to the racier pid loop. That distinction is exactly what an
        # operator needs after a stop that did not converge, so it must not be swallowed.
        if [[ -e "${cgroup_directory}/cgroup.kill" ]]; then
            if ! printf '1' > "${cgroup_directory}/cgroup.kill" 2>/dev/null; then
                ${cgroup_kill_reported} || log_event warning \
                    "cgroup.kill exists but refused the write for ${cgroup_directory} -- falling back to per-pid signalling, which is not atomic" \
                    "AI_TOOLS_CGROUP=${cgroup_directory}" "AI_TOOLS_MECHANISM=cgroup-kill-failed"
                cgroup_kill_reported=true
            fi
        else
            ${cgroup_kill_reported} || log_event info \
                "no cgroup.kill on this kernel -- using per-pid signalling for ${cgroup_directory}" \
                "AI_TOOLS_CGROUP=${cgroup_directory}" "AI_TOOLS_MECHANISM=cgroup-kill-absent"
            cgroup_kill_reported=true
        fi
        mapfile -t pids < <(collect_pids_with_start_time "${cgroup_directory}")
        (( ${#pids[@]} )) && signal_pids_validated KILL "${pids[@]}"
        sleep 1
        waited=$(( waited + 1 ))
    done
    ! cgroup_is_live "${cgroup_directory}"
}

# end_session <cgroup-dir> -- PRINT which pass ended it: `terminated`, `killed`, or `alive`.
# The kill pass runs whether or not the graceful pass reported success, because its own verification
# is the only thing trusted.
end_session() {
    local cgroup_directory="$1"
    if ! ${FORCE_KILL}; then
        terminate_gracefully "${cgroup_directory}" && { printf 'terminated'; return 0; }
    fi
    kill_outright "${cgroup_directory}" && { printf 'killed'; return 0; }
    printf 'alive'
}

# ── Attribution (best-effort, and never decides liveness) ────────────────────────────────────
# unit_working_directory <unit> -- PRINT the unit's WorkingDirectory, or empty when the user
# manager cannot be reached. The machine transport is preferred: this runs as root, where the
# system bus already authorizes it, whereas `sudo -u` needs that account's own bus to accept the
# connection, which a host can refuse while the manager is healthy. A failure here costs
# attribution and nothing else.
#
# BOUNDED IN TIME, because "the user manager is wedged" is not a hypothetical here -- it is one of
# the states an operator reaches for this command IN. A d-bus call to a hung manager blocks
# indefinitely, and a stop that hangs while attributing sessions is a stop that did not happen,
# which is the one outcome this file exists to prevent. Both calls therefore run under a short
# `timeout`, and every way that can fail -- the manager not answering, `timeout` itself absent --
# yields no attribution, which refuses the SCOPED form and sends the operator to --all. --all needs
# no attribution at all, so the undeclinable form cannot be delayed by this at all.
unit_working_directory() {
    local raw
    raw="$(timeout 5 systemctl --user -M "${SANDBOX_USER}@.host" show --property=WorkingDirectory "$1" 2>/dev/null)"
    if [[ -z "${raw}" ]]; then
        raw="$(timeout 5 sudo -n -u "${SANDBOX_USER}" XDG_RUNTIME_DIR="/run/user/${SANDBOX_UID}" \
                   systemctl --user show --property=WorkingDirectory "$1" 2>/dev/null)"
    fi
    raw="${raw#WorkingDirectory=}"
    # Strip systemd's "missing is ok" marker. THE D-BUS PROPERTY RENDERS IT `!`, which is what
    # `show` returns and therefore the only spelling this function actually meets; `-` is the
    # unit-file spelling of the same flag and is stripped too, so neither rendering reaches the
    # comparison below. (Observed: dbus-broker.service reports `WorkingDirectory=!/home/<user>`.)
    if [[ "${raw}" == '!'* || "${raw}" == '-'* ]]; then raw="${raw:1}"; fi
    # ONLY AN ABSOLUTE PATH IS A RESULT; anything else yields nothing and the session reads as
    # `unknown`. Attribution decides nothing here, so this is not a gate -- it is what keeps a value
    # this helper cannot interpret from being printed as though it could be used. The concrete case
    # is print_reclaim_guidance, which turns each attributed directory into a command the operator
    # is invited to run: an unstripped marker emitted `ai-tools --reclaim !/opt/ai-tools`, which is
    # not a runnable command and, pasted into an interactive bash, is not even an inert one.
    #
    # The shape is ALLOWLISTED rather than the markers enumerated, so a rendering systemd adds later
    # degrades to `unknown` instead of reaching the operator as a broken command. `~`
    # (WorkingDirectory=~, the account's home) carries no path and is correctly refused here.
    [[ "${raw}" == /* ]] || raw=""
    printf '%s' "${raw}"
}

# ── Restoring the user manager ───────────────────────────────────────────────────────────────
# restore_user_manager -- put `user@<uid>.service` back after a stop that necessarily took it down.
#
# WHY IT HAS TO EXIST. The enumeration spares nothing, the account's own `systemd --user` included
# (see find_session_cgroups): an exemption is a destination a session can move into, and on a
# DAC-only host it can also ask that manager for a unit outside any subtree we chose to sweep.
# Sparing nothing closes both. The price is that the manager is gone afterwards -- and SIGKILL
# leaves `user@<uid>.service` FAILED rather than restarting it, so the next launch would find no
# --user instance. This pays that price back instead of buying it with an exemption.
#
# IT RUNS AFTER THE KILL AND AFTER THE VERIFICATION, and cannot affect either. The invariant is
# that a stop reported as done HAS happened; a manager that did not come back is a different and
# lesser problem -- the host cannot start a NEW session until it is fixed, which is nearer to the
# point of this command than against it. So every failure here warns, names the command, and
# leaves the exit status alone.
restore_user_manager() {
    local unit="user@${SANDBOX_UID}.service"
    # reset-failed first: the manager was SIGKILLed, so the unit is in `failed`, and `start` on a
    # failed unit is not uniformly a reset-and-start across systemd versions.
    timeout 10 systemctl reset-failed "${unit}" >/dev/null 2>&1
    if timeout 30 systemctl start "${unit}" >/dev/null 2>&1; then
        log_event notice "restarted ${unit} after the stop -- the next launch has a --user instance" \
            "AI_TOOLS_UNIT=${unit}" "AI_TOOLS_RESULT=manager-restored"
        return 0
    fi
    say_warn "The sessions were stopped, but ${SANDBOX_USER}'s user manager did not come back, so the next launch has no systemd --user instance to start a session in. Restore it with:" \
             "sudo systemctl reset-failed ${unit} && sudo systemctl start ${unit}"
    log_event error "could not restart ${unit} after the stop -- the next launch will have no --user instance" \
        "AI_TOOLS_UNIT=${unit}" "AI_TOOLS_RESULT=manager-not-restored"
    return 1
}

# ── Confirmation ─────────────────────────────────────────────────────────────────────────────
# confirm_stop <agent-count> <plumbing-count> -- succeed unless the operator deliberately declines.
# Inverted convention 2 in the header: the default is YES, so no terminal, no msg.lib.sh, a pipe, or
# a bare Enter all proceed, and only an explicit `n` stops the stop.
#
# THE QUESTION NAMES BOTH CLASSES, for the reason the table separates them: consent given to "4
# sessions" that were one session and three units of the account's own plumbing was not informed
# consent about either number.
#
# THE ARITY IS DEFAULTED, and that is inverted convention 1 rather than defensive habit. This file
# runs under `set -u`, where reading an argument a caller did not pass aborts the shell outright --
# here, mid-question, after the table has been printed and before anything has been signalled: a
# stop that was asked for and did not happen, which is the one outcome this file exists to prevent.
# main() always passes both counts, so the default is not an expected path; it is the guarantee that
# a caller's slip costs the wording of a question and never the answer to it.
#
# WHICH PATH GAVE CONSENT IS RECORDED, because the paths are not equally strong and a reader of
# the trail must not have to guess. `--yes` is an operator decision; the library prompt is a real
# answered question; the raw /dev/tty prompt is the same question asked without the shared
# renderer; and `no-tty` means nobody was asked at all and the default carried the run. The last
# is legitimate -- it is the whole point of defaulting YES -- but it is the one an operator would
# want to see when asking why a cron job stopped a session at 4am.
confirm_stop() {
    local agent_count="${1:-0}" plumbing_count="${2:-0}"
    # Three shapes, none of which names a class that is not there. main() reaches this only with at
    # least one cgroup selected, so "no sessions and no plumbing" cannot occur.
    local question
    if   (( agent_count == 0 )); then question="Terminate the ${plumbing_count} unit(s) of the ${SANDBOX_USER} account's own plumbing listed above?"
    elif (( plumbing_count ));   then question="Terminate the ${agent_count} agent session(s) listed above, and ${plumbing_count} unit(s) of the ${SANDBOX_USER} account's own plumbing with them?"
    else                              question="Terminate the ${agent_count} agent session(s) listed above?"
    fi
    if ${ASSUME_YES}; then
        log_event info "stop confirmed by ${CALLER} via --yes" "AI_TOOLS_CONSENT=flag"
        return 0
    fi
    if declare -F ai_tools_msg_confirm >/dev/null 2>&1; then
        if ai_tools_msg_confirm "${question}" y; then
            log_event info "stop confirmed by ${CALLER} at the prompt" "AI_TOOLS_CONSENT=prompt"
            return 0
        fi
        return 1
    fi
    local answer=""
    if ! read -r -p "${question} [Y/n] (default: Yes): " answer 2>/dev/null < /dev/tty; then
        log_event notice \
            "no terminal to confirm with -- proceeding, since a stop that declines when unattended is a stop that failed" \
            "AI_TOOLS_CONSENT=no-tty"
        return 0
    fi
    if [[ "${answer}" =~ ^[Nn] ]]; then return 1; fi
    log_event info "stop confirmed by ${CALLER} at the fallback prompt (msg.lib.sh unavailable)" \
        "AI_TOOLS_CONSENT=fallback-prompt"
    return 0
}

# ── Reporting ────────────────────────────────────────────────────────────────────────────────
# print_session_table <verb> -- the detail the confirmation is answered against. An operator
# agreeing to stop "3 sessions" without seeing which projects they are in is not consenting to
# anything.
#
# Reads the parallel selection arrays directly rather than taking packed records. Nothing in this
# file joins fields into a delimited string any more: a WorkingDirectory is an arbitrary pathname
# and may contain the delimiter, which would split one session into two garbled rows -- in the very
# table whose job is to be exact.
# Agent sessions are listed FIRST, ahead of the account's plumbing, because the table is read under
# time pressure and the rows that answer "what was running" must not be interleaved with rows that
# are always there. Order is presentation only; every selected cgroup is ended by the loop in main()
# in its own order, and nothing is dropped from either pass.
print_session_table() {
    local verb="$1" index note
    printf '  %-11s %-40s %6s  %s\n' "" "SESSION" "PROCS" "PROJECT"
    for index in "${!selected_cgroups[@]}"; do
        ${selected_is_agent[index]} || continue
        printf '  %-11s %-40s %6s  %s\n' "${verb}" \
            "$(sanitize "${selected_units[index]:-unattributed cgroup}")" \
            "${selected_counts[index]}" \
            "$(sanitize "${selected_dirs[index]:-unknown}")"
    done
    for index in "${!selected_cgroups[@]}"; do
        ${selected_is_agent[index]} && continue
        note="$(session_class_note "${selected_units[index]}")"
        printf '  %-11s %-40s %6s  %s  %s\n' "${verb}" \
            "$(sanitize "${selected_units[index]:-unattributed cgroup}")" \
            "${selected_counts[index]}" \
            "$(sanitize "${selected_dirs[index]:-unknown}")" "${note}"
    done
}

# print_reclaim_guidance <dir>... -- name the reclaim per project actually stopped. A stop cannot
# run the agent's SessionEnd hook, so the in-flight turn's writes may still be sandbox-owned;
# naming the project beats a pointer the operator must translate mid-incident.
#
# CALLED WITH AGENT SESSIONS' DIRECTORIES ONLY. The account's plumbing has no project to hand back,
# and its WorkingDirectory is routinely a path `ai-tools --reclaim` would refuse outright: the
# account's dbus broker reports `/opt/ai-tools`, the control plane, which the safe-paths backstop
# protects. Emitting it produced a remedy that cannot run, offered to an operator mid-incident with
# nothing to distinguish it from the one that can.
print_reclaim_guidance() {
    local directory
    local -A seen=()
    local -a targets=()
    for directory in "$@"; do
        [[ -n "${directory}" ]] || continue
        [[ -n "${seen[${directory}]:-}" ]] && continue
        seen["${directory}"]=1
        targets+=("${directory}")
    done
    (( ${#targets[@]} )) || return 0
    printf '\n  %s\n' "A stopped session cannot run its own session-end handback, so the last turn's"
    printf '  %s\n'   "writes may still be ${SANDBOX_USER}-owned. Hand them back with:"
    for directory in "${targets[@]}"; do
        printf '  %s\n' "    ai-tools --reclaim $(sanitize "${directory}")"
    done
}

# ── Run ──────────────────────────────────────────────────────────────────────────────────────
main() {
    # There is one scope and no way to ask for another, so it is a constant rather than a decision:
    # every live cgroup in the account's slice. Kept as a named value because it is what the
    # headline, the trail and the nothing-running message all read.
    local scope="every agent session"

    # Recorded before anything is selected, so a run interrupted part-way still left a record of
    # what was asked for and by whom.
    log_event notice \
        "${CALLER} requested stop (scope=${scope}, force=${FORCE_KILL}, dry-run=${DRY_RUN})" \
        "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_SCOPE=${scope}" \
        "AI_TOOLS_FORCE=${FORCE_KILL}" "AI_TOOLS_DRYRUN=${DRY_RUN}"

    local -a selected_cgroups=() selected_units=() selected_dirs=() selected_counts=() \
             selected_is_agent=()
    local agent_count=0 plumbing_count=0
    local cgroup_directory unit working_directory pid_count
    local -a session_pids
    while read -r cgroup_directory; do
        [[ -n "${cgroup_directory}" ]] || continue
        # Counted in the shell rather than through `wc -l`: the pid list is already being read, so
        # a pipe to an external command buys nothing and puts one more binary on the path.
        mapfile -t session_pids < <(cgroup_pids "${cgroup_directory}")
        pid_count=${#session_pids[@]}
        (( pid_count )) || continue
        unit="$(cgroup_unit_name "${cgroup_directory}")"
        working_directory=""
        [[ -n "${unit}" ]] && working_directory="$(unit_working_directory "${unit}")"
        # NOTHING IS FILTERED. Attribution is read for the table and the reclaim guidance only --
        # it selects nothing, so a session whose working directory cannot be read is stopped
        # exactly like one whose can, and simply shows as `unknown`. That is what makes the
        # attribution safe to take from the account being stopped: a unit that misreports its
        # project misleads a reader, and cannot buy itself survival.
        selected_cgroups+=("${cgroup_directory}")
        selected_units+=("${unit}")
        selected_dirs+=("${working_directory}")
        selected_counts+=("${pid_count}")
        if session_is_agent "${unit}"; then
            selected_is_agent+=(true);  agent_count=$(( agent_count + 1 ))
        else
            selected_is_agent+=(false); plumbing_count=$(( plumbing_count + 1 ))
        fi
    done < <(find_session_cgroups)

    if (( ${#selected_cgroups[@]} == 0 )); then
        say_headline "Stop" "No agent session is running."
        log_event info "no session matched ${scope} for ${CALLER} -- nothing stopped"
        return 0
    fi

    # The two counts are reported separately everywhere, never summed into one "session" figure.
    # See the classification block above for why, and for why the split is advisory.
    #
    # Two wordings, because "go with them" has no antecedent when no agent session was found -- the
    # shape a RERUN always takes, the manager having been restarted by the run before it.
    local plumbing_clause=""
    if (( plumbing_count && agent_count )); then
        plumbing_clause=" ${plumbing_count} unit(s) of the ${SANDBOX_USER} account's own plumbing (marked below) go with them -- nothing in the account's slice is exempt -- and its user manager is restarted afterwards."
    elif (( plumbing_count )); then
        plumbing_clause=" ${plumbing_count} unit(s) of the ${SANDBOX_USER} account's own plumbing (marked below) are stopped regardless -- nothing in the account's slice is exempt -- and its user manager is restarted afterwards."
    fi

    if ${DRY_RUN}; then
        local dry_headline
        if (( agent_count )); then
            dry_headline="${agent_count} agent session(s) would be terminated.${plumbing_clause} Nothing was changed."
        else
            dry_headline="No agent session is running.${plumbing_clause} Nothing was changed."
        fi
        say_headline "Stop (dry run)" "${dry_headline}"
        print_session_table "would stop"
        log_event info "dry run: ${agent_count} agent session(s) and ${plumbing_count} account unit(s) would be stopped in ${scope} for ${CALLER}"
        return 0
    fi

    local headline
    if (( agent_count == 0 )); then
        headline="No agent session is running.${plumbing_clause}"
    elif ${FORCE_KILL}; then
        headline="${agent_count} agent session(s) will be KILLED immediately (--force): no grace period, no session-end handback, and unsaved work in the current turn is lost.${plumbing_clause}"
    else
        headline="${agent_count} agent session(s) will be terminated, with everything they spawned. Each gets ${GRACE_SECONDS}s to exit before it is killed. No session runs its session-end handback, so reclaim the projects named below afterwards.${plumbing_clause}"
    fi
    say_headline "Terminate agent sessions" "${headline}"
    print_session_table "stop"

    if ! confirm_stop "${agent_count}" "${plumbing_count}"; then
        say_notice "Nothing was stopped."
        log_event notice \
            "${CALLER} declined the stop of ${agent_count} agent session(s) and ${plumbing_count} account unit(s) in ${scope} -- nothing stopped" \
            "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_SCOPE=${scope}" "AI_TOOLS_RESULT=declined"
        return 4
    fi

    local index outcome survivors=0 class_note
    local -a survived_cgroups=()
    for index in "${!selected_cgroups[@]}"; do
        cgroup_directory="${selected_cgroups[index]}"
        unit="${selected_units[index]}"
        working_directory="${selected_dirs[index]}"
        # Carried onto the result lines too, not just the table: in a run with several sessions the
        # table has scrolled off by the time these appear, and these are what the operator watches.
        class_note="$(session_class_note "${unit}")"
        [[ -n "${class_note}" ]] && class_note="  ${class_note}"
        outcome="$(end_session "${cgroup_directory}")"
        case "${outcome}" in
            terminated)
                printf '  stopped    %s  (%s)%s\n' \
                    "$(sanitize "${unit:-unattributed cgroup}")" "$(sanitize "${working_directory:-unknown}")" "${class_note}"
                log_event notice \
                    "stopped session ${unit:-<unattributed>} in ${working_directory:-<none>} on SIGTERM for ${CALLER}" \
                    "AI_TOOLS_UNIT=${unit}" "AI_TOOLS_CWD=${working_directory}" \
                    "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_PASS=sigterm" "AI_TOOLS_RESULT=stopped" ;;
            killed)
                local reason
                ${FORCE_KILL} && reason="--force: no grace period" \
                              || reason="did not exit within ${GRACE_SECONDS}s"
                printf '  KILLED     %s  (%s)  %s%s\n' \
                    "$(sanitize "${unit:-unattributed cgroup}")" "$(sanitize "${working_directory:-unknown}")" "${reason}" "${class_note}"
                log_event warning \
                    "killed session ${unit:-<unattributed>} in ${working_directory:-<none>} with SIGKILL for ${CALLER} (${reason}; it flushed nothing)" \
                    "AI_TOOLS_UNIT=${unit}" "AI_TOOLS_CWD=${working_directory}" \
                    "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_PASS=sigkill" "AI_TOOLS_RESULT=killed" ;;
            *)
                survivors=$(( survivors + 1 ))
                survived_cgroups+=("${cgroup_directory}")
                printf '  STILL UP   %s  (%s)%s\n' \
                    "$(sanitize "${unit:-unattributed cgroup}")" "$(sanitize "${working_directory:-unknown}")" "${class_note}" >&2
                log_event error \
                    "session ${unit:-<unattributed>} in ${working_directory:-<none>} survived SIGKILL for ${CALLER}" \
                    "AI_TOOLS_UNIT=${unit}" "AI_TOOLS_CWD=${working_directory}" \
                    "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_PASS=sigkill" "AI_TOOLS_RESULT=alive" ;;
        esac
    done

    # ONE FINAL SWEEP OF THE WHOLE SLICE, after every session has been dealt with individually.
    # Each cgroup above was verified empty on its own, which leaves one theoretical gap: a process
    # that moved between two selected cgroups during the run would be verified gone from the one it
    # left and never looked for in the one it joined. Migration needs write access to the
    # destination's cgroup.procs, which the confined session does not have -- so this closes a gap
    # that should be unreachable, and its value is exactly that: if it ever fires, a confinement
    # invariant has broken and that is far more important than the stop it just caught.
    #
    # RE-ENUMERATED, not merely re-checking what was selected: a session that started while this
    # ran sits in a cgroup that was never selected, so a selection-only recheck would report success
    # with a live session on the host. Re-walking catches it. It does not make the command atomic --
    # a session starting after this sweep is still missed, and closing that needs a launch/stop gate
    # shared with ai-tools-run -- but it converts a silent miss into a reported one, which is the
    # honest bound. See the exit contract at the top of this file for what a success means.
    #
    # The assertion is now the simple one, because the sweep spares nothing: the account's slice
    # holds no live cgroup at all.
    local -a remaining=()
    while read -r cgroup_directory; do
        [[ -n "${cgroup_directory}" ]] && cgroup_is_live "${cgroup_directory}" \
            && remaining+=("${cgroup_directory}")
    done < <(find_session_cgroups)
    # The sweep's verdict is SET-BASED, not a count comparison. `survivors` counts SESSIONS that
    # reported alive; `remaining` counts LIVE CGROUPS afterwards. Those are different units -- one
    # session cgroup holds many tasks, and a cgroup that appeared after the loop was never in
    # `survivors` at all -- so comparing the two numbers detects nothing reliably: it misses a new
    # cgroup whenever `survivors` was already non-zero, and can fire when nothing is wrong.
    #
    # So: ANY live cgroup after a run is a failure, full stop. And separately, a live cgroup that is
    # not one the loop already reported alive is the interesting case -- something appeared in, or
    # moved into, a cgroup after it was verified empty. Within a DELEGATED subtree that move is
    # permitted (see the header), so this is a reachable event and not a broken invariant; it is
    # reported because it means a session started while the command was running, or that something
    # re-entered a cgroup after it was verified empty.
    local -a unexpected=()
    local swept known was_known
    for swept in "${remaining[@]}"; do
        was_known=false
        for known in "${survived_cgroups[@]}"; do
            [[ "${swept}" == "${known}" ]] && { was_known=true; break; }
        done
        ${was_known} || unexpected+=("${swept}")
    done

    if (( ${#unexpected[@]} )); then
        log_event error \
            "final sweep found ${#unexpected[@]} live cgroup(s) that the per-session checks had verified empty -- either a new session started during this run, or a process moved between cgroups inside the delegated subtree to evade the stop" \
            "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_SCOPE=${scope}" "AI_TOOLS_RESULT=reappeared"
        say_error "The final sweep found live cgroups that the per-session checks had verified empty, so a session started while this ran or something re-entered a cgroup after it was emptied. Re-running is safe and is the remedy -- this command is idempotent. To see what is there first:" \
                  "sudo ps -o pid,stat,cgroup,cmd -u ${SANDBOX_USER}"
        for swept in "${unexpected[@]}"; do
            printf '  UNEXPECTED %s\n' "$(sanitize "${swept}")" >&2
            log_event error "unexpected live cgroup after the stop: ${swept}" \
                "AI_TOOLS_CGROUP=${swept}" "AI_TOOLS_RESULT=reappeared"
        done
    fi
    # Whatever the cause, a non-empty sweep means the stop did not complete. Take the sweep's count
    # as authoritative over the loop's, since it is the later and broader observation.
    (( ${#remaining[@]} )) && survivors=${#remaining[@]}

    # Unconditional, and deliberately placed after every verification and before the exit-status
    # decision: the manager has to come back whether or not something survived SIGKILL, and it must
    # not be able to influence what this command reports about the stop itself.
    restore_user_manager

    if (( survivors )); then
        log_event error \
            "stop finished with ${survivors} of ${#selected_cgroups[@]} cgroup(s) still present for ${CALLER}" \
            "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_SCOPE=${scope}" "AI_TOOLS_RESULT=survived"
        say_error "${survivors} of ${#selected_cgroups[@]} cgroup(s) survived SIGKILL. A task only outlives SIGKILL while blocked in an uninterruptible kernel call: it holds no CPU, runs no code and can start nothing new, but only the I/O completing or a reboot clears it. Inspect it with:" \
                  "sudo ps -o pid,stat,wchan:20,cmd -u ${SANDBOX_USER}"
        return 1
    fi
    log_event notice \
        "stopped ${agent_count} agent session(s) and ${plumbing_count} account unit(s) in ${scope} for ${CALLER}, verified empty via cgroup.procs and a final slice sweep" \
        "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_SCOPE=${scope}" \
        "AI_TOOLS_COUNT=${#selected_cgroups[@]}" "AI_TOOLS_AGENT_COUNT=${agent_count}"
    # Agent sessions only -- the account's plumbing has no project to reclaim. See the function.
    local -a agent_dirs=(); local index_reclaim
    for index_reclaim in "${!selected_cgroups[@]}"; do
        ${selected_is_agent[index_reclaim]} && agent_dirs+=("${selected_dirs[index_reclaim]}")
    done
    (( ${#agent_dirs[@]} )) && print_reclaim_guidance "${agent_dirs[@]}"
    return 0
}

# ── Entry point ──────────────────────────────────────────────────────────────────────────────
# SOURCING THIS FILE IS INERT: it defines the functions and returns here, having parsed nothing,
# resolved nothing about the host, armed no trap and signalled nothing. That is what lets the unit
# suite drive the enumeration and liveness predicates -- the two things a reading review has
# repeatedly failed to get right -- against a FIXTURE cgroup tree, on any host, with no session
# running and no privilege. It is not a mode and not a hook: there is no environment variable to
# set, no branch inside any function, and nothing an invoker can reach that changes what a real run
# does. Running the file is unchanged.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

parse_command_line "$@"
resolve_run_context
resolve_cgroup_layout
main
main_status=$?
STOP_EXIT_REACHED=true
exit "${main_status}"

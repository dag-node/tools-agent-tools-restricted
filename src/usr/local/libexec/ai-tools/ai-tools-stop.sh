#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-stop
# Stops running agent sessions and everything they spawned. This is the stop rung of the incident
# ladder: the one control that acts on a session ALREADY RUNNING, where every other operator
# control (unclaim, disable a provider, revoke an operator) only changes what the NEXT launch gets.
#
# THE PROPERTY THIS FILE EXISTS TO HOLD: a stop that is asked for and reported as done HAS
# HAPPENED. Everything below follows from that one sentence, including three places where this
# helper deliberately inverts a project-wide convention. Each inversion is called out where it
# appears, and they share one reason: for every other component the safe direction is DON'T ACT,
# and for this one it is ACT.
#
# ── Inversion 1: this helper has no required dependencies ────────────────────────────────────
# Everywhere else, a missing library aborts the operation, because not acting is safe. Here a
# missing library that aborted the run would be a stop that did not happen. So every library is
# loaded best-effort behind an inline fallback, `set -e` is deliberately NOT used (an unexpected
# non-zero anywhere must not abandon a half-finished kill), and the kill path itself -- enumerate,
# signal, verify -- runs on bash builtins plus /proc and /sys reads, with `sleep` the only external
# it calls. A host broken enough to have lost /usr/local/lib/ai-tools can still be stopped.
#
# Scoped precisely, because the weaker claim is the true one: this does NOT survive a broken
# coreutils, and does not pretend to. `id` resolves the account, `realpath` canonicalizes a scoped
# target, `date` timestamps the fallback log line, and `logger`, `systemctl` and `sudo` serve
# logging and attribution. Every one of those is outside the kill path or best-effort within it;
# what the file guarantees is independence from THIS PROJECT's libraries, not from the base system.
#
# The one seam kept: the SCOPED form authorizes against the caller's allowlist, and that matcher
# stays single-sourced in operator.lib.sh rather than being reimplemented here. If it will not
# load, the scoped form refuses and names --all -- which stops MORE, so even that degradation
# moves toward stopping.
#
# ── Inversion 2: the confirmation defaults to YES ────────────────────────────────────────────
# messaging.rule.md requires a destructive question to default NO, because Enter and any run
# without a terminal take the default. The rule's actual principle is "the default is the SAFE
# outcome", and for a stop the safe outcome is stopping. So this prompt defaults YES: a piped run,
# a cron job, an absent msg.lib.sh and a plain Enter all proceed, and declining takes a deliberate
# `n`. -n/--dry-run is the way to look without acting.
#
# ── Inversion 3: the protected-paths backstop is advisory here ───────────────────────────────
# safe-paths.lib.sh is fail-closed in every other helper because those helpers WRITE to the path.
# This one only selects processes by it; "stopping sessions whose working directory is under /etc"
# writes nothing to /etc. So a missing backstop degrades to no gate rather than to no stop.
#
# ── Why root, and what authorizes a scoped stop ──────────────────────────────────────────────
# Sessions run in the sandbox account's cgroups; signalling them and writing cgroup.kill is root's
# to do. There is no NOPASSWD grant -- this is reached through `sudo ai-tools --stop` and sudo
# prompts, like ai-tools-lockdown, -reclaim and -audit. The sudoers surface stays at two rules.
#
# All sessions run as one shared account, so a routine stop must be scoped or one operator would
# terminate another's work -- and the scoping input must be something the sandbox account cannot
# write. Nothing the session records about itself qualifies: the launch line, the unit name and the
# unit's own properties are all written by that account, so a session could name any operator it
# liked. The input used instead is the CALLER'S OWN allowed-projects (0600 inside a 0700 home,
# unreadable and unwritable by the sandbox) paired with a caller identity sudo supplies (SUDO_USER,
# written by a root process; the session cannot invoke sudo at all -- NoNewPrivileges drops its
# SUID bit). Two operators who both claimed a project can stop each other's sessions in it, which
# is consistent with them already sharing write access to that tree.
#
# --all takes NO authorization input. Scoping by working directory is sound but not complete: a
# process can sit in a unit whose directory no allowlist covers, or in no unit at all. A stop path
# the monitored system can put itself outside of is not a stop path. --all reaches every cgroup in
# the account's slice, any operator may pull it, and it can only ever over-stop.
#
# ── The mechanism: cgroups, not process trees ────────────────────────────────────────────────
# A session spawns children, and children are the whole difficulty. Three ways to find them:
#
#   process group  -- broken by setsid(2): a process that leaves the group stops being signalled.
#   ppid walk      -- broken by the double fork: a re-parented process's ppid becomes 1, so it
#                     drops out of the subtree entirely. (This is what a portable process-tree
#                     terminator must use when it cannot assume a cgroup, and its known hole.)
#   cgroup         -- inherited across fork(), and SURVIVES setsid(2) and the double fork. A task
#                     is only ever moved by an explicit write to a cgroup.procs, never by anything
#                     it does to itself.
#
# So the cgroup is the container a spawned process cannot fall out of, and it is what this helper
# enumerates and kills. Nothing here depends on the ppid graph or on process groups.
#
# WHAT THAT DOES **NOT** MEAN, stated plainly because an earlier version of this file got it wrong:
# it is NOT true that the session cannot move between cgroups. systemd DELEGATES the per-user
# subtree to the account, which is what lets the user manager create units at all -- and delegation
# by definition permits the delegatee to move its own tasks around INSIDE that subtree. Containment
# holds at the delegation boundary, not within it. So a session that wants to can move a process
# from one cgroup in the account's slice to another.
#
# The consequence is precise and is the reason the two forms of this command differ in strength:
#
#   --all  reaches every cgroup in the account's slice, so a move WITHIN the slice cannot escape it.
#          This form holds against a hostile session.
#   scoped selects by the project a cgroup is attributed to, so a process moved into a cgroup
#          attributed elsewhere is no longer selected. This form is for routine use -- stopping
#          one's own session in one project -- and must NOT be relied on against a session that is
#          actively evading it.
#
# That is not a gap being tolerated: it is why --all exists, needs no authorization, and is the rung
# the incident ladder points at. The final sweep below reports a cgroup that became live after being
# verified empty, which is what such a move looks like from here.
#
# `cgroup.kill` (Linux 5.14+, so both supported EL targets) makes the kill ATOMIC: one write
# freezes the cgroup and SIGKILLs every member including descendants, so there is no window in
# which a fork can outrun the signal. Where it is absent, the fallback signals pids in a
# re-collecting loop -- re-reading the set each pass so late children are caught -- and validates
# each pid's start time (/proc/<pid>/stat field 22) immediately before signalling, so a pid
# recycled between reading and killing is skipped rather than signalled blind.
#
# The user manager (`systemd --user`) and its (sd-pam) helper are spared, by CGROUP and not by
# name: they live in init.scope, which this never descends into. They run no agent code, and
# killing them breaks the lingering the next launch needs.
#
# systemd is used for exactly one thing: reading a unit's WorkingDirectory, to attribute a session
# to a project for the scoped form. It is best-effort and never decides whether something is
# running -- a wedged user manager or an absent machine transport degrades attribution, not the
# stop. Where the unit view and the cgroup disagree about liveness, the cgroup wins.
#
# ── What "graceful" means here, and what it does not ─────────────────────────────────────────
# The first pass is SIGTERM, deepest-first (children before parents, so a parent is not left
# waiting on a child it can still see), which gives each process its own handlers. It does NOT run
# the agent's SessionEnd hook, and no stop can: that hook fires when the agent exits on its own
# terms, not when it is signalled. A stopped session therefore leaves its clean-exit marker
# behind, which is by design the signal the next session-start reads to widen its .git reclaim and
# warn the operator (ownership-and-hooks.rule.md). The tree is not left unknown either way: the
# per-turn PostToolUse and Stop hooks already handed back everything up to the last completed
# turn, so what a stop can strand is the in-flight turn's writes. This command names the reclaim
# for the projects it actually stopped.
#
# ── Everything is recorded ───────────────────────────────────────────────────────────────────
# The request, every authorization refusal, the answer to the confirmation, each session ended and
# WHICH PASS ended it, and anything that survived, all with the caller and the target -- to
# journald and to the root-only /var/log/ai-tools/stop.log. An operator ending another operator's
# work is a thing the trail must show, and so is a stop that had to escalate. An EXIT trap records
# an incomplete run, so silence in the trail is never ambiguous.
#
# Usage:  ai-tools-stop [-n|--dry-run] [-y|--yes] [--force] <absolute-project-path>
#         ai-tools-stop [-n|--dry-run] [-y|--yes] [--force] --all
#
# WHAT A SUCCESSFUL EXIT MEANS, stated exactly rather than generously. Exit 0 means: every session
# matching the request that existed at ENUMERATION was stopped, and a final re-enumeration found
# nothing matching still live. It does NOT mean no matching session can exist afterwards -- a
# session launched after that final sweep is outside the window, and closing that needs a
# launch/stop gate shared with the launcher, which does not exist yet. For the incident use this
# command is built for, the operator holds the launch path anyway; for an adversarial session,
# --all plus a revoked launch grant is the answer, not a stronger promise here.
#
# Exit:   0 stopped and verified gone (or nothing was running)
#         1 something survived SIGKILL -- the only outcome that is not a stop
#         2 usage
#         3 refused (unsafe target, not covered by the caller's allowlist, or unattributable)
#         4 declined at the confirmation (a deliberate `n`; never a degraded path)
#         5 this helper could not run (no cgroup2 hierarchy, no sandbox uid) -- distinct from 1,
#           so a caller can tell a broken tool from a surviving process
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/libexec/ai-tools/ai-tools-stop.sh /usr/local/libexec/ai-tools/ai-tools-stop

# NOT `set -e`: see Inversion 1. An unexpected non-zero must never abandon a half-finished kill.
set -uo pipefail

# A fixed PATH, set before anything is resolved. This helper runs as root and is reachable directly
# as well as through the CLI, so it must not resolve `sleep`, `id` or `realpath` through a PATH an
# invoker chose. sudoers `secure_path` normally covers the sudo route; this covers the direct one
# too, and costs nothing.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

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
# Loaded for quality of output and for the single-sourced allowlist matcher. Not one of them is
# allowed to prevent a stop.
AI_TOOLS_LOG_TAG="ai-tools-stop"
AI_TOOLS_LOG_FILE="stop.log"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
source /usr/local/lib/ai-tools/log.lib.sh 2>/dev/null || true
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh 2>/dev/null || true
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source /usr/local/lib/ai-tools/safe-paths.lib.sh 2>/dev/null || true
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source /usr/local/lib/ai-tools/operator.lib.sh 2>/dev/null || true

# sanitize <text> -- reduce to printable ASCII before anything agent-influenced reaches a terminal
# or the trail. Prefers the shared allowlist; the fallback is the same allowlist, inline, because a
# missing logger must not mean an unsanitized path.
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
say_error()  { if declare -F ai_tools_msg_error  >/dev/null 2>&1; then ai_tools_msg_error  2 "$@"; else printf 'ai-tools-stop: %s\n' "$@" >&2; fi; }
say_warn()   { if declare -F ai_tools_msg_warn   >/dev/null 2>&1; then ai_tools_msg_warn   2 "$@"; else printf 'ai-tools-stop: %s\n' "$@" >&2; fi; }
say_notice() { if declare -F ai_tools_msg_notice >/dev/null 2>&1; then ai_tools_msg_notice 1 "$@"; else printf '%s\n'               "$@";     fi; }
say_headline() {
    local title="$1"; shift
    if declare -F ai_tools_msg_headline >/dev/null 2>&1; then ai_tools_msg_headline "${title}" 1 "$@"
    else printf '\n== %s ==\n%s\n' "${title}" "$*"; fi
}

# ── Arguments ────────────────────────────────────────────────────────────────────────────────
STOP_EVERY_SESSION=false
DRY_RUN=false
ASSUME_YES=false
FORCE_KILL=false
TARGET_PROJECT=""
while (( $# )); do
    case "$1" in
        --all)        STOP_EVERY_SESSION=true; shift ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -y|--yes)     ASSUME_YES=true; shift ;;
        --force)      FORCE_KILL=true; shift ;;
        -*) printf 'ai-tools-stop: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *)  if [[ -n "${TARGET_PROJECT}" ]]; then
                printf 'ai-tools-stop: too many arguments\n' >&2; exit 2
            fi
            TARGET_PROJECT="$1"; shift ;;
    esac
done
if ${STOP_EVERY_SESSION} && [[ -n "${TARGET_PROJECT}" ]]; then
    printf 'ai-tools-stop: --all takes no path\n' >&2; exit 2
fi
if ! ${STOP_EVERY_SESSION} && [[ -z "${TARGET_PROJECT}" ]]; then
    printf 'usage: ai-tools-stop [-n|--dry-run] [-y|--yes] [--force] <absolute-project-path>\n' >&2
    printf '       ai-tools-stop [-n|--dry-run] [-y|--yes] [--force] --all\n' >&2
    exit 2
fi
readonly STOP_EVERY_SESSION DRY_RUN ASSUME_YES FORCE_KILL TARGET_PROJECT

if [[ "$(id -u)" != "0" ]]; then
    say_error "ai-tools-stop must run as root: stopping a session means signalling ${SANDBOX_USER}'s cgroups" \
              "run it as: sudo ai-tools --stop"
    exit 5
fi

# Who sudo says invoked this -- written by a root process, unreachable by the sandbox account. A
# direct root invocation has no SUDO_USER and therefore no allowlist, which is why the scoped form
# refuses it rather than inventing one.
#
# SUDO_USER ALONE IS NOT PROOF OF A SUDO TRANSACTION. A root shell entered with `sudo -i` keeps
# SUDO_USER set, so its presence does not establish that *this* invocation came through sudo on
# behalf of that user -- it may be inherited state from an earlier one. SUDO_UID is cross-checked
# against it: the two are set together by the same sudo run, so a pair that disagrees is inherited
# or forged environment and is refused rather than trusted. Both, plus the real uid, are recorded
# separately, so the trail carries what was observed rather than one derived conclusion.
CALLER="${SUDO_USER:-root}"
if [[ -n "${SUDO_USER:-}" ]]; then
    caller_uid_from_name="$(id -u "${SUDO_USER}" 2>/dev/null)"
    if [[ -z "${SUDO_UID:-}" || -z "${caller_uid_from_name}" \
          || "${SUDO_UID}" != "${caller_uid_from_name}" ]]; then
        log_event warning \
            "SUDO_USER=${SUDO_USER} does not agree with SUDO_UID=${SUDO_UID:-<unset>} -- treating this as a direct root invocation, which cannot run a scoped stop" \
            "AI_TOOLS_SUDO_USER=${SUDO_USER}" "AI_TOOLS_SUDO_UID=${SUDO_UID:-}" "AI_TOOLS_RESULT=identity-rejected"
        CALLER="root"
    fi
    unset caller_uid_from_name
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
record_incomplete_run() {
    ${STOP_EXIT_REACHED} && return 0
    log_event error "stop run by ${CALLER} ended without completing -- state unverified" \
        "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_RESULT=incomplete"
}
trap record_incomplete_run EXIT
# A signal during a stop is its own event, not merely an incomplete run: an operator who
# interrupts one mid-way needs the trail to say a kill was in flight when it happened, because the
# tree is then in whatever state that pass left it. Named separately from the EXIT trap so the two
# causes are distinguishable. SIGKILL of this helper remains untrappable and is a stated residual.
trap 'log_event error "stop run by ${CALLER} interrupted by a signal -- some sessions may be partially stopped" "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_RESULT=interrupted"; STOP_EXIT_REACHED=true; exit 130' INT TERM HUP

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

CGROUP2_MOUNT="$(cgroup2_mount)"
if [[ -z "${CGROUP2_MOUNT}" ]]; then
    say_error "ai-tools-stop: this host has no cgroup v2 hierarchy, so sessions cannot be enumerated or stopped reliably." \
              "Stop them by hand and report the host: sudo systemctl --user -M ${SANDBOX_USER}@.host list-units"
    log_event error "REFUSED: no cgroup2 mount; cannot enumerate sessions for ${CALLER}"
    exit 5
fi
readonly CGROUP2_MOUNT
# The account's own manager slice. A process the operator's sudo spawned under that account lives
# in the INVOKING session's slice, not this one, so scoping to this path is also what keeps this
# helper from selecting its own children.
#
# The root is the account's WHOLE per-user slice, not just its `user@<uid>.service` manager subtree.
# systemd places login session scopes (`session-N.scope`) as SIBLINGS of the manager service, under
# the same per-user slice -- so a scan rooted at the manager alone has a blind spot for anything
# not started by that manager. The sandbox account has no login shell and no password, so nothing
# should ever appear there; scanning the wider root costs one directory level and removes the need
# for that to be true.
#
# It stays scoped to the ACCOUNT's slice rather than widening to uid alone, which is what keeps the
# scan off this helper's own `sudo -u` children: those share the account's uid but live in the
# INVOKING user's slice.
readonly SANDBOX_SLICE="${CGROUP2_MOUNT}/user.slice/user-${SANDBOX_UID}.slice"
# The two structural cgroups, named exactly rather than by basename. See find_session_cgroups.
readonly MANAGER_SERVICE="${SANDBOX_SLICE}/user@${SANDBOX_UID}.service"
readonly MANAGER_INIT_SCOPE="${MANAGER_SERVICE}/init.scope"

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
            # Two structural cgroups are special-cased by EXACT PATH, never by basename. A
            # basename test would extend the exemption to any nested cgroup that chose the same
            # name -- and every name in a delegated subtree is the delegatee's to choose, so that
            # would be an exemption the monitored system can claim for itself.
            #
            #   init.scope             -- `systemd --user` and its (sd-pam) helper. Skipped whole:
            #                             they run no agent code and killing them breaks the
            #                             lingering the next launch needs.
            #   user@<uid>.service     -- the manager unit itself. DESCENDED INTO but never emitted:
            #                             its name ends in `.service`, so the stop-at-first-unit
            #                             rule below would otherwise swallow the entire manager
            #                             subtree as one "session" and never reach the real units
            #                             inside it.
            [[ "${child}" == "${MANAGER_INIT_SCOPE}" ]] && continue
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
# FAIL-CLOSED ON A READ ERROR, which is the whole point. "I could not read cgroup.procs" and "there
# are no tasks" are different facts, and collapsing them is a fail-open on the predicate the
# guarantee rests on. The kernel has a documented case: reading cgroup.procs in a THREADED cgroup
# fails with EOPNOTSUPP, and a threaded descendant would otherwise read as empty while holding live
# threads. Only one failure means empty -- the file not existing, i.e. the cgroup was removed, which
# is the successful outcome. Every other failure answers "live", so an unprovable subtree is
# reported as still running rather than silently declared stopped.
has_own_tasks() {
    local first_pid=""
    [[ -e "$1/cgroup.procs" ]] || return 1          # cgroup gone == no tasks, the good outcome
    # `2>/dev/null` precedes the input redirect: see the note in cgroup_pids.
    if ! read -r first_pid 2>/dev/null < "$1/cgroup.procs"; then
        # `read` also returns non-zero on a clean EOF with no data -- an empty but readable file --
        # so the two are separated by re-testing readability rather than by the status alone.
        [[ -r "$1/cgroup.procs" ]] || return 0      # exists, unreadable: assume LIVE
    fi
    [[ -n "${first_pid}" ]]
}

# cgroup_unit_name <cgroup-dir> -- PRINT the systemd unit this cgroup belongs to, or empty.
cgroup_unit_name() {
    local leaf="${1##*/}"
    [[ "${leaf}" == *.service || "${leaf}" == *.scope ]] && printf '%s' "${leaf}"
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
unit_working_directory() {
    local raw
    raw="$(systemctl --user -M "${SANDBOX_USER}@.host" show --property=WorkingDirectory "$1" 2>/dev/null)"
    if [[ -z "${raw}" ]]; then
        raw="$(sudo -u "${SANDBOX_USER}" XDG_RUNTIME_DIR="/run/user/${SANDBOX_UID}" \
                   systemctl --user show --property=WorkingDirectory "$1" 2>/dev/null)"
    fi
    raw="${raw#WorkingDirectory=}"
    # systemd renders an ignore-failure path as `-/some/path`. Strip only that exact marker form,
    # so a value that merely starts with a hyphen is left intact.
    [[ "${raw}" == -/* ]] && raw="${raw#-}"
    printf '%s' "${raw}"
}

# ── Authorization (scoped form only) ─────────────────────────────────────────────────────────
# authorize_scoped_stop -- PRINT the canonical path this caller may stop in, or refuse. Each gate
# fails toward no stop, and the caller is told about --all, which needs none of them.
authorize_scoped_stop() {
    local canonical caller_allowlist
    # Absolute only, checked before canonicalization. A relative path would otherwise be resolved
    # against THIS HELPER's working directory, which is the caller's shell cwd carried through
    # sudo -- so the same command would mean different projects from different directories, and the
    # path the operator is shown would not be the path they typed.
    if [[ "${TARGET_PROJECT}" != /* ]]; then
        say_error "ai-tools-stop: the project must be an absolute path: ${TARGET_PROJECT}"
        log_event warning "REFUSED: ${CALLER} gave a relative path to a scoped stop"
        return 3
    fi
    canonical="$(realpath -e -- "${TARGET_PROJECT}" 2>/dev/null)"
    if [[ -z "${canonical}" || ! -d "${canonical}" ]]; then
        say_error "ai-tools-stop: not a directory: ${TARGET_PROJECT}"
        log_event warning "REFUSED: ${CALLER} named an unusable path for a scoped stop"
        return 3
    fi
    # Advisory here, not fail-closed -- see Inversion 3.
    if declare -F ai_tools_assert_safe_target >/dev/null 2>&1; then
        ai_tools_assert_safe_target "${canonical}" "stop" || return 3
    fi
    if [[ "${CALLER}" == "root" ]]; then
        say_error "ai-tools-stop: a scoped stop is authorized by the calling operator's own allowed-projects, and root has none." \
                  "run it as the operator (sudo ai-tools --stop), or stop every session with --all"
        log_event warning "REFUSED: scoped stop invoked directly as root, which has no allowlist"
        return 3
    fi
    if ! declare -F ai_tools_operator_allowlist_for >/dev/null 2>&1 \
            || ! declare -F ai_tools_allowlist_covers >/dev/null 2>&1; then
        say_error "ai-tools-stop: the allowlist matcher is unavailable, so this stop cannot be scoped to one project." \
                  "stop every session instead: sudo ai-tools --stop --all"
        log_event error "REFUSED: operator.lib.sh unavailable; scoped stop cannot authorize -- ${CALLER} sent to --all"
        return 3
    fi
    caller_allowlist="$(ai_tools_operator_allowlist_for "${CALLER}" 2>/dev/null)"
    if [[ -z "${caller_allowlist}" ]] \
            || ! ai_tools_allowlist_covers "${caller_allowlist}" "${canonical}"; then
        say_error "ai-tools-stop: ${canonical} is not one of your claimed projects, so you cannot stop the sessions running in it." \
                  "claim it first, or stop every session with: sudo ai-tools --stop --all"
        log_event warning "REFUSED: ${CALLER} has no allowlist entry covering ${canonical} -- nothing stopped"
        return 3
    fi
    printf '%s' "${canonical}"
}

# ── Confirmation ─────────────────────────────────────────────────────────────────────────────
# confirm_stop <count> -- succeed unless the operator deliberately declines. See Inversion 2: the
# default is YES, so no terminal, no msg.lib.sh, a pipe, or a bare Enter all proceed. Only an
# explicit `n` stops the stop.
# WHICH PATH GAVE CONSENT IS RECORDED, because the paths are not equally strong and a reader of
# the trail must not have to guess. `--yes` is an operator decision; the library prompt is a real
# answered question; the raw /dev/tty prompt is the same question asked without the shared
# renderer; and `no-tty` means nobody was asked at all and the inversion carried the run. The last
# is legitimate -- it is the whole point of defaulting YES -- but it is the one an operator would
# want to see when asking why a cron job stopped a session at 4am.
confirm_stop() {
    if ${ASSUME_YES}; then
        log_event info "stop confirmed by ${CALLER} via --yes" "AI_TOOLS_CONSENT=flag"
        return 0
    fi
    if declare -F ai_tools_msg_confirm >/dev/null 2>&1; then
        if ai_tools_msg_confirm "Stop the $1 session(s) listed above?" y; then
            log_event info "stop confirmed by ${CALLER} at the prompt" "AI_TOOLS_CONSENT=prompt"
            return 0
        fi
        return 1
    fi
    local answer=""
    if ! read -r -p "Stop the $1 session(s) listed above? [Y/n] (default: Yes): " answer 2>/dev/null < /dev/tty; then
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
print_session_table() {
    local verb="$1" index
    printf '  %-11s %-40s %6s  %s\n' "" "SESSION" "PROCS" "PROJECT"
    for index in "${!selected_cgroups[@]}"; do
        printf '  %-11s %-40s %6s  %s\n' "${verb}" \
            "$(sanitize "${selected_units[index]:-unattributed cgroup}")" \
            "${selected_counts[index]}" \
            "$(sanitize "${selected_dirs[index]:-unknown}")"
    done
}

# print_reclaim_guidance <dir>... -- name the reclaim per project actually stopped. A stop cannot
# run the agent's SessionEnd hook, so the in-flight turn's writes may still be sandbox-owned;
# naming the project beats a pointer the operator must translate mid-incident.
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
    local mode scope canonical=""
    if ${STOP_EVERY_SESSION}; then
        mode="all"; scope="every session"
    else
        mode="project"
        canonical="$(authorize_scoped_stop)" || return 3
        scope="${canonical}"
    fi

    # Recorded before anything is selected, so a run interrupted part-way still left a record of
    # what was asked for and by whom.
    log_event notice \
        "${CALLER} requested stop (mode=${mode}, scope=${scope}, force=${FORCE_KILL}, dry-run=${DRY_RUN})" \
        "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_MODE=${mode}" "AI_TOOLS_SCOPE=${scope}" \
        "AI_TOOLS_FORCE=${FORCE_KILL}" "AI_TOOLS_DRYRUN=${DRY_RUN}"

    local -a selected_cgroups=() selected_units=() selected_dirs=() selected_counts=()
    local -a unattributable=()
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
        if [[ "${mode}" == "project" ]]; then
            # A session whose project cannot be read cannot be attributed, so a SCOPED stop must
            # not claim it -- and must not quietly narrow either. Collected by PATH, not merely
            # counted, so the refusal below can name what blocked it.
            if [[ -z "${working_directory}" ]]; then
                unattributable+=("${cgroup_directory}")
                continue
            fi
            [[ "${working_directory}" == "${canonical}" \
               || "${working_directory}" == "${canonical}/"* ]] || continue
        fi
        selected_cgroups+=("${cgroup_directory}")
        selected_units+=("${unit}")
        selected_dirs+=("${working_directory}")
        selected_counts+=("${pid_count}")
    done < <(find_session_cgroups)

    # Refuse rather than half-act: a scoped stop that cannot see every candidate's project cannot
    # honestly scope, and --all needs no attribution at all.
    #
    # The blocking cgroups are NAMED, not just counted. One unregistered cgroup otherwise blocks
    # every scoped stop on the host with nothing to act on, which turns a safety refusal into a
    # dead end -- the operator needs to see what it is to decide between investigating it and
    # reaching for --all.
    if (( ${#unattributable[@]} )); then
        say_error "ai-tools-stop: ${#unattributable[@]} live ${SANDBOX_USER} cgroup(s) could not be attributed to a project, so this stop cannot be scoped safely." \
                  "stop every session instead: sudo ai-tools --stop --all"
        for cgroup_directory in "${unattributable[@]}"; do
            printf '  unattributable  %s\n' "$(sanitize "${cgroup_directory}")" >&2
            log_event warning "unattributable live cgroup blocks a scoped stop: ${cgroup_directory}" \
                "AI_TOOLS_CGROUP=${cgroup_directory}" "AI_TOOLS_CALLER=${CALLER}"
        done
        log_event error \
            "REFUSED: scoped stop for ${CALLER} found ${#unattributable[@]} unattributable live cgroup(s) -- sent to --all, nothing stopped" \
            "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_SCOPE=${scope}" "AI_TOOLS_RESULT=refused"
        return 3
    fi

    if (( ${#selected_cgroups[@]} == 0 )); then
        say_headline "Stop" "No agent session is running in ${scope}."
        log_event info "no session matched ${scope} for ${CALLER} -- nothing stopped"
        return 0
    fi

    if ${DRY_RUN}; then
        say_headline "Stop (dry run)" \
            "${#selected_cgroups[@]} session(s) would be stopped in ${scope}. Nothing was changed."
        print_session_table "would stop"
        log_event info "dry run: ${#selected_cgroups[@]} session(s) would be stopped in ${scope} for ${CALLER}"
        return 0
    fi

    local headline
    if ${FORCE_KILL}; then
        headline="${#selected_cgroups[@]} session(s) in ${scope} will be KILLED immediately (--force): no grace period, and unsaved work in the current turn is lost."
    else
        headline="${#selected_cgroups[@]} session(s) in ${scope} will be stopped, with everything they spawned. Each gets ${GRACE_SECONDS}s to exit before it is killed."
    fi
    say_headline "Stop agent sessions" "${headline}"
    print_session_table "stop"

    if ! confirm_stop "${#selected_cgroups[@]}"; then
        say_notice "Nothing was stopped."
        log_event notice \
            "${CALLER} declined the stop of ${#selected_cgroups[@]} session(s) in ${scope} -- nothing stopped" \
            "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_SCOPE=${scope}" "AI_TOOLS_RESULT=declined"
        return 4
    fi

    local index outcome survivors=0
    local -a survived_cgroups=()
    for index in "${!selected_cgroups[@]}"; do
        cgroup_directory="${selected_cgroups[index]}"
        unit="${selected_units[index]}"
        working_directory="${selected_dirs[index]}"
        outcome="$(end_session "${cgroup_directory}")"
        case "${outcome}" in
            terminated)
                printf '  stopped    %s  (%s)\n' \
                    "$(sanitize "${unit:-unattributed cgroup}")" "$(sanitize "${working_directory:-unknown}")"
                log_event notice \
                    "stopped session ${unit:-<unattributed>} in ${working_directory:-<none>} on SIGTERM for ${CALLER}" \
                    "AI_TOOLS_UNIT=${unit}" "AI_TOOLS_CWD=${working_directory}" \
                    "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_PASS=sigterm" "AI_TOOLS_RESULT=stopped" ;;
            killed)
                local reason
                ${FORCE_KILL} && reason="--force: no grace period" \
                              || reason="did not exit within ${GRACE_SECONDS}s"
                printf '  KILLED     %s  (%s)  %s\n' \
                    "$(sanitize "${unit:-unattributed cgroup}")" "$(sanitize "${working_directory:-unknown}")" "${reason}"
                log_event warning \
                    "killed session ${unit:-<unattributed>} in ${working_directory:-<none>} with SIGKILL for ${CALLER} (${reason}; it flushed nothing)" \
                    "AI_TOOLS_UNIT=${unit}" "AI_TOOLS_CWD=${working_directory}" \
                    "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_PASS=sigkill" "AI_TOOLS_RESULT=killed" ;;
            *)
                survivors=$(( survivors + 1 ))
                survived_cgroups+=("${cgroup_directory}")
                printf '  STILL UP   %s  (%s)\n' \
                    "$(sanitize "${unit:-unattributed cgroup}")" "$(sanitize "${working_directory:-unknown}")" >&2
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
    # For --all the assertion is simply that the slice holds nothing outside init.scope. For a
    # scoped run only the selected cgroups are re-checked, since other operators' sessions are
    # legitimately still running.
    local -a remaining=()
    if [[ "${mode}" == "all" ]]; then
        while read -r cgroup_directory; do
            [[ -n "${cgroup_directory}" ]] && cgroup_is_live "${cgroup_directory}" \
                && remaining+=("${cgroup_directory}")
        done < <(find_session_cgroups)
    else
        # RE-ENUMERATED, not merely re-checking what was selected. Proving the selected cgroups are
        # empty proves less than it looks: a session started in the same project after enumeration
        # sits in a cgroup that was never selected, so a selection-only recheck reports success
        # while the project has a live session. Re-walking and re-matching catches that.
        #
        # It does not make the command atomic -- a session starting after this sweep is still
        # missed, and closing that needs a launch/stop gate shared with ai-tools-run. What it does
        # is convert a silent miss into a reported one, which is the honest bound. See the exit
        # contract at the top of this file for exactly what a success means.
        local swept_unit swept_directory
        while read -r cgroup_directory; do
            [[ -n "${cgroup_directory}" ]] || continue
            cgroup_is_live "${cgroup_directory}" || continue
            swept_unit="$(cgroup_unit_name "${cgroup_directory}")"
            swept_directory=""
            [[ -n "${swept_unit}" ]] && swept_directory="$(unit_working_directory "${swept_unit}")"
            [[ "${swept_directory}" == "${canonical}" \
               || "${swept_directory}" == "${canonical}/"* ]] || continue
            remaining+=("${cgroup_directory}")
        done < <(find_session_cgroups)
    fi
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
    # reported because it is the visible signature of a session evading a scoped stop, and because
    # under --all it means a new session started while the command was running.
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
        say_error "The final sweep found live cgroups that the per-session checks had verified empty. Either a session started while this ran, or a process moved between cgroups to avoid being stopped. Re-run with --all, which reaches every cgroup in the account's slice and cannot be evaded that way. To see what is there:" \
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

    if (( survivors )); then
        log_event error \
            "stop finished with ${survivors} of ${#selected_cgroups[@]} session(s) still present for ${CALLER}" \
            "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_SCOPE=${scope}" "AI_TOOLS_RESULT=survived"
        say_error "${survivors} of ${#selected_cgroups[@]} session(s) survived SIGKILL. A task only outlives SIGKILL while blocked in an uninterruptible kernel call: it holds no CPU, runs no code and can start nothing new, but only the I/O completing or a reboot clears it. Inspect it with:" \
                  "sudo ps -o pid,stat,wchan:20,cmd -u ${SANDBOX_USER}"
        return 1
    fi
    log_event notice \
        "stopped ${#selected_cgroups[@]} session(s) in ${scope} for ${CALLER}, verified empty via cgroup.procs and a final slice sweep" \
        "AI_TOOLS_CALLER=${CALLER}" "AI_TOOLS_MODE=${mode}" "AI_TOOLS_SCOPE=${scope}" \
        "AI_TOOLS_COUNT=${#selected_cgroups[@]}"
    print_reclaim_guidance "${selected_dirs[@]}"
    return 0
}

main
main_status=$?
STOP_EXIT_REACHED=true
exit "${main_status}"

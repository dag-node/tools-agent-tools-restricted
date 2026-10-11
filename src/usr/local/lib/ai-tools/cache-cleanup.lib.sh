#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/cache-cleanup.lib.sh
# The one removal every path that empties a cache under the sandbox home goes through, and the state record of what each
# removal did. Any process of the sandbox account can rename an entry inside its own caches while a removal runs,
# so the removal walks by directory file descriptors and does not follow a symbolic link: shutil.rmtree in the host's
# /usr/bin/python3, run only where Python reports shutil.rmtree.avoids_symlink_attacks. A directory swapped for a link
# mid-walk has the link unlinked or left, and its target is not entered. A group a running session uses is removed only
# by a session launch that does not find another session through the admission lock or the user manager's listing.
# The groups, when each is removed, the state file, the callers and the residual are in updater.rule.md; the launch-time
# step is in launch.rule.md.
#
# Sourced, not executed. Deployed 644 root:root: it holds shipped logic and does not read operator data. conf.lib.sh
# (the trust predicate over the home), sandbox-exec.lib.sh (the identity a removal requires) and services.lib.sh (the
# defensive field reader the state file is read through) are REQUIRED: a load that fails does not define any function
# here and returns non-zero, the shape providers.lib.sh takes over conf.lib.sh, so every consumer probes for a function
# before trusting the source.

# Include guard, as an if-statement: `[[ ]] && return` returns 1 for an unset guard and trips a sourcing shell's
# `set -e`.
if [[ -n "${_AI_TOOLS_CACHE_CLEANUP__LOADED:-}" ]]; then
    return 0
fi
# The logger, best-effort: every removal is recorded in journald under the caller's AI_TOOLS_LOG_TAG, and without
# the library the coded warnings still reach stderr.
# shellcheck source=SCRIPTDIR/log.lib.sh
source "${BASH_SOURCE[0]%/*}/log.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/conf.lib.sh
source "${BASH_SOURCE[0]%/*}/conf.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/sandbox-exec.lib.sh
source "${BASH_SOURCE[0]%/*}/sandbox-exec.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/services.lib.sh
source "${BASH_SOURCE[0]%/*}/services.lib.sh" 2>/dev/null || true
if ! declare -F ai_tools_conf__is_trusted >/dev/null 2>&1 \
        || ! declare -F ai_tools_sandbox_exec__is_sandbox_account >/dev/null 2>&1 \
        || ! declare -F ai_tools_services__read_stamp_field >/dev/null 2>&1; then
    return 1
fi
_AI_TOOLS_CACHE_CLEANUP__LOADED=1

# The home every caller passes, the state file every writer rewrites, and the three readonly settings: how often
# a launch removes a launch-timed group, how long the launch step may take across every group it removes, and the age
# of a launch-timed group's last removal past which both status reports count it. No environment variable moves
# the state path (updater.rule.md); the status reports read it through their own root-only override.
# shellcheck disable=SC2034  # read by ai-tools-run, nvm-update and ai-tools-bootstrap
readonly AI_TOOLS_CACHE_CLEANUP__SANDBOX_HOME="/opt/ai-tools"
# shellcheck disable=SC2034  # read by ai-tools-run, nvm-update, ai-tools-bootstrap and both status reports
readonly AI_TOOLS_CACHE_CLEANUP__STATE_FILE="/var/opt/ai-tools/state/cache-cleanup.status"
# The admission lock beside the state file: every session launch holds it shared from its admission to the end of its
# unit, and the launch that removes a launch-timed group holds it exclusive from the due test to the state write
# (ai_tools_cache_cleanup__remove_due_groups). It is a file of its own, root-owned and readable by the account, since
# the state file's lock serializes that file's writers, which the nightly updater is while sessions run.
# shellcheck disable=SC2034  # read by ai-tools-run
readonly AI_TOOLS_CACHE_CLEANUP__ADMISSION_LOCK="/var/opt/ai-tools/state/cache-cleanup.lock"
readonly AI_TOOLS_CACHE_CLEANUP__LAUNCH_INTERVAL_SECONDS=604800
# shellcheck disable=SC2034  # read by ai-tools-run, nvm-update and ai-tools-bootstrap
readonly AI_TOOLS_CACHE_CLEANUP__LAUNCH_BOUND_SECONDS=30
readonly AI_TOOLS_CACHE_CLEANUP__OVERDUE_SECONDS=1209600

# The groups: name, path under the home, timing, whether its producer writes links, and the state file's key prefix.
# npm-cache holds content-addressed tarballs that npm reads and a process does not execute, so the updater removes it
# after every run whatever is running. npx holds packages `npx` installed, which a session can be executing,
# and node-compile holds compile output a running node reads, so each is removed at a launch with no other session
# active. npm writes node_modules/.bin links under _npx, so a link there is expected; _cacache and node-compile-cache
# hold no link a producer writes.
readonly -a _AI_TOOLS_CACHE_CLEANUP__GROUPS=(
    $'npm-cache\t.npm/_cacache\tnightly\tnone\tNPM_CACHE'
    $'npx\t.npm/_npx\tlaunch\texpected\tNPX'
    $'node-compile\t.cache/node-compile-cache\tlaunch\tnone\tNODE_COMPILE'
)

# The results a record carries. removed and absent leave the group clean; every other one carries a reason token.
readonly _AI_TOOLS_CACHE_CLEANUP__RESULTS='removed absent partial refused failed skipped'

# The walk: one isolated python3 program reading the home and the group's path from argv. It prints
# `counted <bytes> <links>` once the report pass ends, so a bound that cuts the removal short still reports
# what the tree held, then one `<result> <bytes> <links> <reason>` line. Every exit it takes on purpose is status 0,
# so a non-zero status is the interpreter failing. The report pass sums regular files once per inode and counts every
# link, and reads the filesystem of every directory, since rmtree descends into a mount point and a cache holds none.
# A FileNotFoundError during the removal is a concurrent removal and is ignored; any other error leaves the result
# partial, named by its errno, or `swapped` for the directory rmtree found replaced by a link.
_AI_TOOLS_CACHE_CLEANUP__WALK_PROGRAM=""
read -r -d '' _AI_TOOLS_CACHE_CLEANUP__WALK_PROGRAM <<'PYTHON' || true
import errno, os, shutil, stat, sys

home, relative = sys.argv[1], sys.argv[2]

def finish(result, total=0, links=0, reason="-"):
    print("%s\t%d\t%d\t%s" % (result, total, links, reason), flush=True)
    sys.exit(0)

if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):
    finish("refused", reason="unsafe-rmtree")

target = os.path.join(home, relative)
try:
    home_device = os.stat(home).st_dev
    top = os.lstat(target)
except FileNotFoundError:
    finish("absent")
except OSError:
    finish("failed", reason="stat")

if stat.S_ISLNK(top.st_mode):
    try:
        os.unlink(target)
    except FileNotFoundError:
        pass
    except OSError as error:
        finish("partial", 0, 1, errno.errorcode.get(error.errno, "unlink").lower())
    finish("removed", 0, 1)
if not stat.S_ISDIR(top.st_mode):
    finish("refused", reason="not-a-directory")
if top.st_dev != home_device:
    finish("refused", reason="other-fs")

total, links, seen = 0, 0, set()
for _, directories, files, directory_fd in os.fwalk(target, follow_symlinks=False):
    if os.fstat(directory_fd).st_dev != top.st_dev:
        finish("refused", total, links, "other-fs")
    for name in directories + files:
        try:
            entry = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError:
            continue
        if stat.S_ISLNK(entry.st_mode):
            links += 1
        elif stat.S_ISREG(entry.st_mode) and (entry.st_dev, entry.st_ino) not in seen:
            seen.add((entry.st_dev, entry.st_ino))
            total += entry.st_size
print("counted\t%d\t%d" % (total, links), flush=True)

errors = []
def record(function, path, error):
    if not isinstance(error, FileNotFoundError):
        errors.append(error)
if sys.version_info >= (3, 12):
    shutil.rmtree(target, onexc=record)
else:
    shutil.rmtree(target, onerror=lambda function, path, info: record(function, path, info[1]))
if errors:
    first = errors[0]
    finish("partial", total, links, errno.errorcode.get(first.errno, "error").lower() if first.errno else "swapped")
finish("removed", total, links)
PYTHON
readonly _AI_TOOLS_CACHE_CLEANUP__WALK_PROGRAM

# _ai_tools_cache_cleanup__log <level> <message> [FIELD=value...] : one journald record through log.lib.sh, where it
#   loaded. Always 0.
_ai_tools_cache_cleanup__log() {
    declare -F ai_tools_log__structured >/dev/null 2>&1 && ai_tools_log__structured "$@"
    return 0
}

# _ai_tools_cache_cleanup__error <code> <message> [FIELD=value...] / _ai_tools_cache_cleanup__warn <code> <message>
#   [FIELD=value...] : a coded situation, at ERROR or WARNING: the code on its own line then the message on stderr
#   (a terminal, or the journal a unit routes it to), and one journald record carrying the code as AI_TOOLS_MSG, where
#   log.lib.sh loaded. stdout carries the records, so it is left alone. Always 0.
_ai_tools_cache_cleanup__error() { _ai_tools_cache_cleanup__report_coded error "$@"; }
_ai_tools_cache_cleanup__warn()  { _ai_tools_cache_cleanup__report_coded warning "$@"; }
_ai_tools_cache_cleanup__report_coded() {
    local level="$1" code="$2" message="$3"; shift 3
    printf '%s\nai-tools: %s\n' "${code}" "${message}" >&2
    declare -F ai_tools_log__coded >/dev/null 2>&1 && ai_tools_log__coded "${level}" "${code}" "${message}" "$@"
    return 0
}

# ai_tools_cache_cleanup__list_groups : print `name<TAB>path<TAB>timing<TAB>links<TAB>key` per group.
ai_tools_cache_cleanup__list_groups() {
    printf '%s\n' "${_AI_TOOLS_CACHE_CLEANUP__GROUPS[@]}"
}

# _ai_tools_cache_cleanup__get_group <name> : print the group's declaration line; non-zero for a name not declared.
_ai_tools_cache_cleanup__get_group() {
    local declaration
    for declaration in "${_AI_TOOLS_CACHE_CLEANUP__GROUPS[@]}"; do
        [[ "${declaration%%$'\t'*}" == "${1:-}" ]] && { printf '%s' "${declaration}"; return 0; }
    done
    return 1
}

# ai_tools_cache_cleanup__remove_group <home> <group> [seconds] : remove one group's directory under <home> and print
#   one record, `group<TAB>result<TAB>bytes<TAB>links<TAB>reason`, reason `-` where there is none. 0 for removed
#   and absent, 1 otherwise. The process is the sandbox account, <group> a declared name whose path comes from
#   the declaration, <home> passes ai_tools_conf__is_trusted, and the group's first component is a directory that
#   account owns, so it cannot rename a component between the home and the removed directory; each check that fails
#   is `refused` with its reason, and the tree is left as it was. With [seconds] the walk runs under timeout -k 5,
#   and a walk cut short is `partial timeout`.
#
#   Each call is journalled under the caller's AI_TOOLS_LOG_TAG: the removal it starts at DEBUG, and its outcome
#   after -- removed or absent at INFO, a removal refused or failed under MSG-G5U7 at ERROR, one cut short
#   under MSG-Y7B4 at WARNING, and links in a group whose producer writes none under MSG-J4Y8 at WARNING, each coded
#   one on stderr as well.
ai_tools_cache_cleanup__remove_group() {
    local home="${1:-}" group="${2:-}" declaration relative="" link_policy=none record result bytes links reason
    local path size log_result
    if declaration="$(_ai_tools_cache_cleanup__get_group "${group}")"; then
        IFS=$'\t' read -r _ relative _ link_policy _ <<<"${declaration}"
    fi
    path="${home}/${relative:-?}"
    _ai_tools_cache_cleanup__log debug "removing ${path}" "AI_TOOLS_PATH=${path}"
    record="$(_ai_tools_cache_cleanup__remove_checked "$@")" || true
    IFS=$'\t' read -r _ result bytes links reason <<<"${record}"
    size="$(ai_tools_cache_cleanup__format_bytes "${bytes}")"
    case "${result}" in
        removed) _ai_tools_cache_cleanup__log info "removed ${path} (${size}, ${links} link(s))" \
                     "AI_TOOLS_PATH=${path}" AI_TOOLS_RESULT=ok ;;
        absent)  _ai_tools_cache_cleanup__log info "${path} was already absent" \
                     "AI_TOOLS_PATH=${path}" AI_TOOLS_RESULT=ok ;;
        partial) _ai_tools_cache_cleanup__warn MSG-Y7B4 "cache partly removed: ${path} (${reason}) -- $(ai_tools_cache_cleanup__get_remedy "${reason}")" \
                     "AI_TOOLS_PATH=${path}" AI_TOOLS_RESULT=failed ;;
        *)       log_result=failed
                 [[ "${result}" == refused ]] && log_result=refused
                 _ai_tools_cache_cleanup__error MSG-G5U7 "cache not removed: ${path} (${result}, ${reason}) -- $(ai_tools_cache_cleanup__get_remedy "${reason}")" \
                     "AI_TOOLS_PATH=${path}" "AI_TOOLS_RESULT=${log_result}" ;;
    esac
    if [[ "${link_policy}" == none && "${links}" =~ ^[0-9]+$ ]] && (( links > 0 )); then
        _ai_tools_cache_cleanup__warn MSG-J4Y8 "cache held ${links} symbolic link(s) its producer does not write: ${path} -- $(ai_tools_cache_cleanup__get_remedy links)" \
            "AI_TOOLS_PATH=${path}"
    fi
    printf '%s\n' "${record}"
    [[ "${result}" == removed || "${result}" == absent ]]
}

# _ai_tools_cache_cleanup__remove_checked <home> <group> [seconds] : the checks and the walk behind
#   ai_tools_cache_cleanup__remove_group, printing its record without logging it.
_ai_tools_cache_cleanup__remove_checked() {
    local home="${1:-}" group="${2:-}" seconds="${3:-}" declaration relative first_component owner
    # A name the declaration does not hold is printed as `-`, so the record does not carry a byte the caller supplied.
    declaration="$(_ai_tools_cache_cleanup__get_group "${group}")" || group=-
    if ! ai_tools_sandbox_exec__is_sandbox_account; then
        printf '%s\trefused\t0\t0\tnot-sandbox\n' "${group}"
        return 1
    fi
    if [[ "${group}" == - ]]; then
        printf -- '-\trefused\t0\t0\tunknown-group\n'
        return 1
    fi
    IFS=$'\t' read -r _ relative _ _ _ <<<"${declaration}"
    if ! ai_tools_conf__is_trusted "${home}"; then
        printf '%s\trefused\t0\t0\thome-untrusted\n' "${group}"
        return 1
    fi
    first_component="${home}/${relative%%/*}"
    owner="$(/usr/bin/stat -c '%u' -- "${first_component}" 2>/dev/null || true)"
    if [[ -L "${first_component}" || ! -d "${first_component}" || "${owner}" != "${EUID}" ]]; then
        printf '%s\trefused\t0\t0\tparent-untrusted\n' "${group}"
        return 1
    fi

    local -a walk=( /usr/bin/python3 -I -c "${_AI_TOOLS_CACHE_CLEANUP__WALK_PROGRAM}" "${home}" "${relative}" )
    [[ "${seconds}" =~ ^[1-9][0-9]*$ ]] && walk=( /usr/bin/timeout -k 5 "${seconds}" "${walk[@]}" )
    local output status=0 line counted_bytes=0 counted_links=0 result="" bytes links reason
    output="$("${walk[@]}" </dev/null 2>/dev/null)" || status=$?
    while IFS=$'\t' read -r line bytes links reason; do
        case "${line}" in
            counted) counted_bytes="${bytes}"; counted_links="${links}" ;;
            removed|absent|partial|refused|failed)
                [[ "${bytes}" =~ ^[0-9]+$ && "${links}" =~ ^[0-9]+$ && "${reason}" =~ ^[a-z0-9-]{1,32}$ ]] || continue
                result="${line}"
                printf '%s\t%s\t%s\t%s\t%s\n' "${group}" "${result}" "${bytes}" "${links}" "${reason}" ;;
        esac
    done <<<"${output}"
    if [[ -z "${result}" ]]; then
        [[ "${counted_bytes}" =~ ^[0-9]+$ ]] || counted_bytes=0
        [[ "${counted_links}" =~ ^[0-9]+$ ]] || counted_links=0
        case "${status}" in
            124|137) result=partial; reason=timeout ;;
            *)       result=failed;  reason='walk-error' ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\n' "${group}" "${result}" "${counted_bytes}" "${counted_links}" "${reason}"
    fi
    [[ "${result}" == removed || "${result}" == absent ]]
}

# ai_tools_cache_cleanup__is_launch_due <now-epoch> <cleaned-epoch|-> : succeed when a launch-timed group's last removal
#   is older than the interval, absent, or dated after now -- a forged or skewed time is not evidence of a recent one.
ai_tools_cache_cleanup__is_launch_due() {
    local now="${1:-}" cleaned="${2:--}"
    [[ "${now}" =~ ^[0-9]+$ && "${cleaned}" =~ ^[0-9]+$ ]] || return 0
    (( cleaned > now || now - cleaned > AI_TOOLS_CACHE_CLEANUP__LAUNCH_INTERVAL_SECONDS ))
}

# ai_tools_cache_cleanup__evaluate_launch <now-epoch> <cleaned-epoch|-> <other-sessions|unknown> : print the launch
#   decision for one group -- not-due, run, sessions (another session unit is active), or unknown (the count could not
#   be read, which skips like a session would).
ai_tools_cache_cleanup__evaluate_launch() {
    local other_sessions="${3:-unknown}"
    if ! ai_tools_cache_cleanup__is_launch_due "${1:-}" "${2:--}"; then
        printf 'not-due'
    elif [[ ! "${other_sessions}" =~ ^[0-9]+$ ]]; then
        printf 'unknown'
    elif (( other_sessions > 0 )); then
        printf 'sessions'
    else
        printf 'run'
    fi
}

# ai_tools_cache_cleanup__read_cleaned_epoch <state-file> <group> : print the epoch of the group's last removal, or `-`
#   where the record carries none or it does not parse.
ai_tools_cache_cleanup__read_cleaned_epoch() {
    local declaration key cleaned epoch
    declaration="$(_ai_tools_cache_cleanup__get_group "${2:-}")" || { printf -- '-'; return 0; }
    key="${declaration##*$'\t'}"
    cleaned="$(ai_tools_services__read_stamp_field "${1:-}" "${key}_CLEANED")"
    epoch="$(/usr/bin/date -u -d "${cleaned}" +%s 2>/dev/null || true)"
    [[ -n "${cleaned}" && "${epoch}" =~ ^[0-9]+$ ]] || epoch=-
    printf '%s' "${epoch}"
}

# ai_tools_cache_cleanup__write_state_locked <state-file> <record>... : rewrite the existing, non-symlink <state-file>
#   in place, one block per declared group: a group a record names takes that record with CHECKED now, FIRST_CHECKED
#   kept from the file or now where it held none, and, for removed or absent, CLEANED now; every other group keeps
#   the values the file held. A value outside its shape is not written.
#   The caller holds the state file's lock (ai_tools_cache_cleanup__lock), so two writers do not interleave
#   a read of the previous values with a write. Non-zero where the file is absent, a symlink, or not writable.
ai_tools_cache_cleanup__write_state_locked() {
    local state="${1:-}"; shift
    [[ -n "${state}" && ! -L "${state}" && -f "${state}" && -w "${state}" ]] || return 1
    local now record group result bytes links reason declaration key field value text
    local -A records=()
    for record in "$@"; do
        IFS=$'\t' read -r group result bytes links reason <<<"${record}"
        [[ " ${_AI_TOOLS_CACHE_CLEANUP__RESULTS} " == *" ${result} "* && "${bytes}" =~ ^[0-9]+$ \
              && "${links}" =~ ^[0-9]+$ && "${reason}" =~ ^[a-z0-9-]{1,32}$ ]] || continue
        _ai_tools_cache_cleanup__get_group "${group}" >/dev/null || continue
        records["${group}"]="${record}"
    done
    now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    text='# cache cleanup state -- written by the callers of cache-cleanup.lib.sh, read by both status reports.'$'\n'
    for declaration in "${_AI_TOOLS_CACHE_CLEANUP__GROUPS[@]}"; do
        group="${declaration%%$'\t'*}"; key="${declaration##*$'\t'}"
        if [[ -n "${records[${group}]:-}" ]]; then
            IFS=$'\t' read -r _ result bytes links reason <<<"${records[${group}]}"
            text+="${key}_RESULT=${result}"$'\n'"${key}_CHECKED=${now}"$'\n'
            value="$(ai_tools_services__read_stamp_field "${state}" "${key}_FIRST_CHECKED")"
            text+="${key}_FIRST_CHECKED=${value:-${now}}"$'\n'
            if [[ "${result}" == removed || "${result}" == absent ]]; then
                text+="${key}_CLEANED=${now}"$'\n'
            else
                value="$(ai_tools_services__read_stamp_field "${state}" "${key}_CLEANED")"
                [[ -n "${value}" ]] && text+="${key}_CLEANED=${value}"$'\n'
            fi
            text+="${key}_BYTES=${bytes}"$'\n'"${key}_LINKS=${links}"$'\n'
            [[ "${reason}" != - ]] && text+="${key}_REASON=${reason}"$'\n'
        else
            for field in RESULT CHECKED FIRST_CHECKED CLEANED BYTES LINKS REASON; do
                value="$(ai_tools_services__read_stamp_field "${state}" "${key}_${field}")"
                [[ -n "${value}" ]] && text+="${key}_${field}=${value}"$'\n'
            done
        fi
    done
    { printf '%s' "${text}" >"${state}"; } 2>/dev/null
}

# The descriptor ai_tools_cache_cleanup__lock holds, or empty.
_AI_TOOLS_CACHE_CLEANUP__LOCK_FD=""

# ai_tools_cache_cleanup__lock <state-file> <wait-seconds> : take an exclusive flock on <state-file>, waiting at most
#   <wait-seconds>; non-zero where the file cannot be opened or the wait runs out. The lock serializes the state writes
#   and the launch step's due read; the removal's safety does not rest on it.
ai_tools_cache_cleanup__lock() {
    local state="${1:-}" wait="${2:-0}"
    [[ -n "${state}" && ! -L "${state}" && -f "${state}" && "${wait}" =~ ^[0-9]+$ ]] || return 1
    { exec {_AI_TOOLS_CACHE_CLEANUP__LOCK_FD}<"${state}"; } 2>/dev/null || { _AI_TOOLS_CACHE_CLEANUP__LOCK_FD=""; return 1; }
    /usr/bin/flock -w "${wait}" "${_AI_TOOLS_CACHE_CLEANUP__LOCK_FD}" 2>/dev/null && return 0
    ai_tools_cache_cleanup__unlock
    return 1
}

# ai_tools_cache_cleanup__unlock : close the lock's descriptor, which releases it, so no child started afterwards
#   inherits it.
ai_tools_cache_cleanup__unlock() {
    [[ -n "${_AI_TOOLS_CACHE_CLEANUP__LOCK_FD}" ]] || return 0
    exec {_AI_TOOLS_CACHE_CLEANUP__LOCK_FD}<&-
    _AI_TOOLS_CACHE_CLEANUP__LOCK_FD=""
}

# ai_tools_cache_cleanup__write_state <state-file> <wait-seconds> <record>... : take the state file's lock, waiting
#   at most <wait-seconds>, write the records through ai_tools_cache_cleanup__write_state_locked, and release it;
#   non-zero where the lock or the write did not happen.
ai_tools_cache_cleanup__write_state() {
    local state="$1" wait="$2" rc=0; shift 2
    ai_tools_cache_cleanup__lock "${state}" "${wait}" || return 1
    ai_tools_cache_cleanup__write_state_locked "${state}" "$@" || rc=1
    ai_tools_cache_cleanup__unlock
    return "${rc}"
}

# The descriptor ai_tools_cache_cleanup__admit_session holds on the admission lock, or empty. It stays open
# for the process's life, so the admission ends with the shim and the unit it waited for.
_AI_TOOLS_CACHE_CLEANUP__ADMISSION_FD=""
# What the last admission in this process was: cleaner, admitted or unadmitted.
AI_TOOLS_CACHE_CLEANUP__ADMISSION=""

# ai_tools_cache_cleanup__admit_session <lock-file> <wait-seconds> : take the admission lock for this process
#   and publish AI_TOOLS_CACHE_CLEANUP__ADMISSION in the caller's shell -- a published value rather than a printed one,
#   since the descriptor must be this process's. `cleaner`: the exclusive lock was taken at once, so no session holds
#   it and this launch may remove a launch-timed group until ai_tools_cache_cleanup__share_admission. `admitted`:
#   the shared lock was taken within <wait-seconds>, beside the sessions that hold it or after the cleaner that held it
#   exclusive. `unadmitted`: the file could not be opened or the wait ran out, and no lock is held. Always 0.
ai_tools_cache_cleanup__admit_session() {
    local lock="${1:-}" wait="${2:-0}"
    AI_TOOLS_CACHE_CLEANUP__ADMISSION=unadmitted
    [[ -n "${lock}" && ! -L "${lock}" && -f "${lock}" && "${wait}" =~ ^[0-9]+$ ]] || return 0
    { exec {_AI_TOOLS_CACHE_CLEANUP__ADMISSION_FD}<"${lock}"; } 2>/dev/null \
        || { _AI_TOOLS_CACHE_CLEANUP__ADMISSION_FD=""; return 0; }
    if /usr/bin/flock -n -x "${_AI_TOOLS_CACHE_CLEANUP__ADMISSION_FD}" 2>/dev/null; then
        AI_TOOLS_CACHE_CLEANUP__ADMISSION=cleaner
    elif /usr/bin/flock -w "${wait}" -s "${_AI_TOOLS_CACHE_CLEANUP__ADMISSION_FD}" 2>/dev/null; then
        AI_TOOLS_CACHE_CLEANUP__ADMISSION=admitted
    else
        ai_tools_cache_cleanup__release_admission
    fi
    return 0
}

# ai_tools_cache_cleanup__share_admission : convert the cleaner's exclusive admission lock to the shared one every
#   admitted session holds, so the launches waiting on it are admitted. flock converts by releasing and taking again,
#   so a launch whose exclusive attempt lands in that instant is a cleaner beside this one; it finds what this one
#   removed not due. Non-zero where no lock is held.
ai_tools_cache_cleanup__share_admission() {
    [[ -n "${_AI_TOOLS_CACHE_CLEANUP__ADMISSION_FD}" ]] || return 1
    /usr/bin/flock -s "${_AI_TOOLS_CACHE_CLEANUP__ADMISSION_FD}" 2>/dev/null && AI_TOOLS_CACHE_CLEANUP__ADMISSION=admitted
}

# ai_tools_cache_cleanup__release_admission : close the admission descriptor, which releases the lock.
ai_tools_cache_cleanup__release_admission() {
    [[ -n "${_AI_TOOLS_CACHE_CLEANUP__ADMISSION_FD}" ]] || return 0
    exec {_AI_TOOLS_CACHE_CLEANUP__ADMISSION_FD}<&-
    _AI_TOOLS_CACHE_CLEANUP__ADMISSION_FD=""
    AI_TOOLS_CACHE_CLEANUP__ADMISSION=unadmitted
}

# ai_tools_cache_cleanup__read_active_session_count <unit-glob> : print how many of this account's service units
#   matching <unit-glob> the user manager lists in a state other than inactive or failed -- active, activating
#   and deactivating, a unit still ending its processes among them -- or `unknown` where the listing could not be read
#   within five seconds. The caller passes the glob its own session unit names match; a launch reads it before its own
#   unit exists, so every unit it counts is another session, whether or not its launch holds the admission lock.
ai_tools_cache_cleanup__read_active_session_count() {
    local unit_glob="${1:-}" units unit active count=0
    [[ -n "${unit_glob}" ]] || { printf 'unknown'; return 0; }
    units="$(/usr/bin/timeout 5 /usr/bin/systemctl --user list-units --type=service --all --plain --no-legend \
                 2>/dev/null)" || { printf 'unknown'; return 0; }
    # The unit name and its active state are the first and third space-separated columns; the split is pinned, since
    # the library is sourced into a script that sets IFS to newline and tab, where the whole line would read
    # as the name.
    while IFS=$' \t' read -r unit _ active _; do
        # shellcheck disable=SC2053  # the glob is the caller's constant, matched as a pattern
        [[ -n "${unit}" && "${unit}" == ${unit_glob} && "${active}" != inactive && "${active}" != failed ]] \
            && count=$(( count + 1 ))
    done <<<"${units}"
    printf '%s' "${count}"
}

# ai_tools_cache_cleanup__remove_due_groups <home> <state-file> <admission-lock> <session-unit-glob>
#   <records-array-name> : admit this launch through <admission-lock> and remove each launch-timed group under <home>
#   that is due, appending each record to the caller's array. The admission is taken in this process and kept, shared,
#   until the process ends: the caller is the shim, whose process ends with the session unit it waits for. The launch
#   is the cleaner where no session held the lock AND the user manager does not list a session unit matching
#   <session-unit-glob> that is not inactive or failed; updater.rule.md states why it takes both. As the cleaner
#   the step stays inside one bound: the due test is read under <state-file>'s own lock, each removal takes the time
#   left, the records are written under that lock within what remains, and the admission is then shared. Beside
#   a session, or `unadmitted`, a due group is recorded `skipped` with its reason (`sessions`, or `unknown`), so
#   the reports show why; a state lock not taken within the bound leaves the state file unwritten. With no group due
#   the admission is taken and the state read alone. Each skip is journalled under the caller's AI_TOOLS_LOG_TAG, as
#   each removal is. Always 0: housekeeping is not a launch gate.
ai_tools_cache_cleanup__remove_due_groups() {
    local home="${1:-}" state="${2:-}" lock="${3:-}" unit_glob="${4:-}" bound="${AI_TOOLS_CACHE_CLEANUP__LAUNCH_BOUND_SECONDS}"
    local -n _ai_tools_cache_cleanup__records_out="$5"
    local group timing now deadline other_sessions verdict record remaining
    local -a launch_records=()
    local -A cleaned_epoch=()
    _ai_tools_cache_cleanup__records_out=()
    deadline=$(( SECONDS + bound ))
    ai_tools_cache_cleanup__admit_session "${lock}" "${bound}"
    case "${AI_TOOLS_CACHE_CLEANUP__ADMISSION}" in
        cleaner)  other_sessions="$(ai_tools_cache_cleanup__read_active_session_count "${unit_glob}")" ;;
        admitted) other_sessions=1 ;;
        *)        other_sessions=unknown
                  _ai_tools_cache_cleanup__log info "launch cleanup: not admitted through ${lock} within ${bound}s" ;;
    esac
    remaining=$(( deadline - SECONDS )); (( remaining >= 1 )) || remaining=1
    if ! ai_tools_cache_cleanup__lock "${state}" "${remaining}"; then
        _ai_tools_cache_cleanup__log info "launch cleanup skipped: ${state} stayed locked for ${remaining}s"
        [[ "${AI_TOOLS_CACHE_CLEANUP__ADMISSION}" != cleaner ]] || ai_tools_cache_cleanup__share_admission || true
        return 0
    fi
    while IFS=$'\t' read -r group _ timing _ _; do
        [[ "${timing}" == launch ]] || continue
        cleaned_epoch["${group}"]="$(ai_tools_cache_cleanup__read_cleaned_epoch "${state}" "${group}")"
    done < <(ai_tools_cache_cleanup__list_groups)
    ai_tools_cache_cleanup__unlock
    now="$(/usr/bin/date -u +%s)"
    while IFS=$'\t' read -r group _ timing _ _; do
        [[ "${timing}" == launch ]] || continue
        verdict="$(ai_tools_cache_cleanup__evaluate_launch "${now}" "${cleaned_epoch[${group}]:--}" "${other_sessions}")"
        [[ "${verdict}" != not-due ]] || continue
        (( deadline - SECONDS >= 1 )) || [[ "${verdict}" != run ]] || verdict=timeout
        if [[ "${verdict}" == run ]]; then
            record="$(ai_tools_cache_cleanup__remove_group "${home}" "${group}" $(( deadline - SECONDS )))" || true
        else
            record="${group}"$'\tskipped\t0\t0\t'"${verdict}"
            _ai_tools_cache_cleanup__log info "launch cleanup of ${group} skipped (${verdict})"
        fi
        launch_records+=( "${record}" )
    done < <(ai_tools_cache_cleanup__list_groups)
    if (( ${#launch_records[@]} > 0 )); then
        remaining=$(( deadline - SECONDS )); (( remaining >= 1 )) || remaining=1
        ai_tools_cache_cleanup__write_state "${state}" "${remaining}" "${launch_records[@]}" \
            || _ai_tools_cache_cleanup__log warning "launch cleanup: ${state} was not rewritten"
    fi
    if [[ "${AI_TOOLS_CACHE_CLEANUP__ADMISSION}" == cleaner ]]; then
        ai_tools_cache_cleanup__share_admission \
            || _ai_tools_cache_cleanup__log warning "launch cleanup: the admission lock was not shared"
    fi
    _ai_tools_cache_cleanup__records_out=( "${launch_records[@]}" )
    return 0
}

# ai_tools_cache_cleanup__format_cleaned_line <record>... : print the one line a launch shows for its removals,
#   `cleaned .npm/_npx (22 MiB), .cache/node-compile-cache (16 MiB)`, from the records whose result is removed; empty
#   where none is.
ai_tools_cache_cleanup__format_cleaned_line() {
    local record group result bytes declaration relative line=""
    for record in "$@"; do
        IFS=$'\t' read -r group result bytes _ _ <<<"${record}"
        [[ "${result}" == removed ]] || continue
        declaration="$(_ai_tools_cache_cleanup__get_group "${group}")" || continue
        IFS=$'\t' read -r _ relative _ _ _ <<<"${declaration}"
        line+="${line:+, }${relative} ($(ai_tools_cache_cleanup__format_bytes "${bytes}"))"
    done
    [[ -n "${line}" ]] && printf 'cleaned %s' "${line}"
    return 0
}

# ai_tools_cache_cleanup__get_remedy <reason|verdict> : print what an operator does about a group: left in place for
#   a record's <reason>, or reported under the status verdict `links` or `overdue`. The warnings print this text, and
#   both status reports print it through ai_tools_cache_cleanup__get_status_remedy.
ai_tools_cache_cleanup__get_remedy() {
    # shellcheck disable=SC2016  # the backticks mark a command for the reader and are printed, not run
    case "${1:-}" in
        home-untrusted)   printf 'the sandbox home must be root-owned and not group- or other-writable: `sudo ai-tools-admin system bootstrap`' ;;
        parent-untrusted) printf 'the parent of the cache must be a directory the sandbox account owns: `sudo ai-tools-admin system bootstrap` names the chown' ;;
        unsafe-rmtree)    printf '/usr/bin/python3 on this host does not report a symlink-safe rmtree, so no cache is removed here' ;;
        timeout)          printf 'the next run removes the rest' ;;
        unknown)          printf 'no launch could take the admission lock beside the state file within its bound or read the session list of the user manager: reinstalling ai-tools-base restores an absent lock file, and `ai-tools stop` ends a session holding the lock' ;;
        links)            printf 'each was removed as a link and its target left alone; a process of the sandbox account planted it, or a copy of the home broke it -- `sudo ai-tools audit` names what ran in the sessions since' ;;
        overdue)          printf 'another session was active at every launch for two weeks: end them all gracefully or with `ai-tools stop`, and the cleanup runs at the next session start' ;;
        *)                printf 'the cache stays as it is until a run removes it' ;;
    esac
}

# ai_tools_cache_cleanup__get_status_remedy <verdict> <reason> : print the remedy a status report shows under a counted
#   verdict: the record's <reason>'s for failed, the verdict's for links, and for overdue the verdict's, or the reason's
#   where the launches skipped the group as `unknown`, since ending sessions does not clear that cause. Empty for ok
#   and unknown.
ai_tools_cache_cleanup__get_status_remedy() {
    case "${1:-}:${2:-}" in
        failed:*)        ai_tools_cache_cleanup__get_remedy "${2:-}" ;;
        links:*)         ai_tools_cache_cleanup__get_remedy links ;;
        overdue:unknown) ai_tools_cache_cleanup__get_remedy unknown ;;
        overdue:*)       ai_tools_cache_cleanup__get_remedy overdue ;;
    esac
    return 0
}

# ai_tools_cache_cleanup__format_result <result> <bytes> <reason> : print a record's result the way both status reports
#   show it: `cleaned 4.2 GiB`, `absent`, or the result with its reason, `skipped (sessions)`.
ai_tools_cache_cleanup__format_result() {
    case "${1:-}" in
        removed) printf 'cleaned %s' "$(ai_tools_cache_cleanup__format_bytes "${2:-}")" ;;
        absent)  printf 'absent' ;;
        *)       printf '%s (%s)' "${1:-?}" "${3:--}" ;;
    esac
}

# ai_tools_cache_cleanup__format_bytes <bytes> : print a size the way an operator reads it: `512 B`, `4.3 GiB`, `22 MiB`
#   (one decimal below 10 of a unit). Empty for a value that is not a whole number.
ai_tools_cache_cleanup__format_bytes() {
    local bytes="${1:-}" unit=0 scaled
    local -a units=( B KiB MiB GiB TiB )
    [[ "${bytes}" =~ ^[0-9]+$ ]] || return 0
    scaled=$(( bytes * 10 ))
    while (( scaled >= 10240 && unit < 4 )); do
        scaled=$(( scaled / 1024 )); unit=$(( unit + 1 ))
    done
    if (( unit > 0 && scaled < 100 )); then
        printf '%d.%d %s' $(( scaled / 10 )) $(( scaled % 10 )) "${units[unit]}"
    else
        printf '%d %s' $(( scaled / 10 )) "${units[unit]}"
    fi
}

# ai_tools_cache_cleanup__evaluate_state <timing> <links-policy> <result> <links> <age-seconds|-> [reason] : print
#   the status verdict for one group: unknown where no result is recorded; failed for refused or failed, and for
#   a partial removal whose reason is not the bound's `timeout`; links for links in a group whose producer writes none;
#   overdue for a launch-timed group whose <age-seconds> is past the attention age; ok otherwise. Every verdict but ok
#   and unknown counts toward a status report's exit.
ai_tools_cache_cleanup__evaluate_state() {
    local timing="${1:-}" link_policy="${2:-}" result="${3:-}" links="${4:-}" cleaned_age="${5:--}" reason="${6:--}"
    case "${result}" in
        '')             printf 'unknown'; return 0 ;;
        refused|failed) printf 'failed';  return 0 ;;
        partial)        [[ "${reason}" == timeout ]] || { printf 'failed'; return 0; } ;;
    esac
    if [[ "${link_policy}" == none && "${links}" =~ ^[0-9]+$ ]] && (( links > 0 )); then
        printf 'links'
    elif [[ "${timing}" == launch && "${cleaned_age}" =~ ^[0-9]+$ ]] \
            && (( cleaned_age > AI_TOOLS_CACHE_CLEANUP__OVERDUE_SECONDS )); then
        printf 'overdue'
    else
        printf 'ok'
    fi
}

# ai_tools_cache_cleanup__list_group_statuses <state-file> : print, per declared group,
#   `name<TAB>path<TAB>verdict<TAB>result<TAB>bytes<TAB>links<TAB>reason<TAB>checked-age<TAB>cleaned-age`, each value
#   read through ai_tools_services__read_stamp_field and `-` where the record does not carry it, the ages in seconds.
#   The verdict's age is the last removal's, or the first record's for a group never removed. The two status reports
#   render this one reading.
ai_tools_cache_cleanup__list_group_statuses() {
    local state="${1:-}" declaration name relative timing link_policy key field verdict checked_age cleaned_age
    local first_checked_age
    local -A value=()
    for declaration in "${_AI_TOOLS_CACHE_CLEANUP__GROUPS[@]}"; do
        IFS=$'\t' read -r name relative timing link_policy key <<<"${declaration}"
        for field in RESULT BYTES LINKS REASON; do
            value["${field}"]="$(ai_tools_services__read_stamp_field "${state}" "${key}_${field}")"
        done
        checked_age="$(ai_tools_services__read_stamp_age "${state}" "${key}_CHECKED")"
        cleaned_age="$(ai_tools_services__read_stamp_age "${state}" "${key}_CLEANED")"
        first_checked_age="$(ai_tools_services__read_stamp_age "${state}" "${key}_FIRST_CHECKED")"
        verdict="$(ai_tools_cache_cleanup__evaluate_state "${timing}" "${link_policy}" "${value[RESULT]}" \
                       "${value[LINKS]}" "${cleaned_age:-${first_checked_age:--}}" "${value[REASON]:--}")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${name}" "${relative}" "${verdict}" "${value[RESULT]:--}" \
            "${value[BYTES]:--}" "${value[LINKS]:--}" "${value[REASON]:--}" "${checked_age:--}" "${cleaned_age:--}"
    done
}

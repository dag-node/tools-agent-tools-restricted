#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only /usr/local/lib/ai-tools/path-order.lib.sh Where an operator's shell finds
# an agent launcher. Every wrapper this project ships lives in /usr/local/bin and is the only route into the sandbox,
# so a launcher of the same name earlier on that operator's PATH -- an agent they installed under their own nvm --
# starts an UNCONFINED session as them, holding their credentials and their home and outside the allowlist,
# the SELinux domain and the ownership handback. path-order.sh ranks /usr/local/bin first and is what settles it; this
# library reads which of the two an account gets, so the question can be asked with the stake named and re-checked
# afterwards. What each state means is launch.rule.md's PATH ordering section.
#
# The decision is pure (ai_tools_path_order_verdict) and the probing is separate, the split confinement.lib.sh makes
# for the launch decision, so the truth table is driven in tests/unit/path-order.sh against no account at all. The
# callers: `ai-tools-admin operators add` (asks, then wires), `ai-tools --status` (re-checks, from the operator's own
# shell), `ai-tools-admin system bootstrap` (names each operator whose shell reaches an agent elsewhere), and the base
# package's %post (names an operator whose init still sources the fragment's former path).
#
# It reports where a name resolves and does not decide any access question, so a reading it cannot take yields
# `unknown` and the caller asks or reports rather than refusing.
#
# Sourced, not executed. Deployed 644 root:root -- no secrets; sourced by root (the admin helper, the scriptlet)
# and by the operator (the CLI).
#
# Deploy:
#   ```bash
#   install -o root -g root -m 644 \
#       src/usr/local/lib/ai-tools/path-order.lib.sh /usr/local/lib/ai-tools/path-order.lib.sh
#   ```

[[ -n "${_AI_TOOLS_PATH_ORDER_LIB_LOADED:-}" ]] && return 0
# shellcheck disable=SC2034  # include guard, read on the next source of this lib
_AI_TOOLS_PATH_ORDER_LIB_LOADED=1

# The directory every agent wrapper ships into, and the fragment that ranks it first. The guard line is defined here
# and nowhere else: ai_tools_path_order_guard_present matches on the fragment path, wire_init_file appends the line,
# and the two agree because they read one string.
readonly AI_TOOLS_PATH_ORDER_WRAPPER_DIR="/usr/local/bin"
readonly AI_TOOLS_PATH_ORDER_FRAGMENT="/usr/local/lib/ai-tools/path-order.sh"
# The name the fragment shipped under before it was renamed to match this library. The guard line sources the fragment
# only while the file is present, so an upgraded host carrying the old path keeps a line that succeeds without
# applying the ordering. ai_tools_path_order_repoint is what follows the file, and the former name is recorded here
# for the same reason the SELinux registry records a group's former module name: a rename answers for the hosts
# already running the old name.
readonly AI_TOOLS_PATH_ORDER_FRAGMENT_FORMER="/usr/local/lib/ai-tools/path-dedup.sh"
# shellcheck disable=SC2034  # read by ai-tools-admin, which appends this line, and by `ai-tools --status`
readonly AI_TOOLS_PATH_ORDER_GUARD='[[ -f /usr/local/lib/ai-tools/path-order.sh ]] && source /usr/local/lib/ai-tools/path-order.sh || true'

# ai_tools_path_order_verdict <wired> <winner>...
# Echo a verdict token and return 0 (the ordering is right), 1 (a launcher is shadowed) or 2 (the reading could not be
# taken) from the account's wiring and one winner per launcher:
#   wired   "yes" when an init file already sources the fragment, else "no"
#   winner  "<launcher>=<path>" -- where that launcher resolves for the account. The path is empty when this host
#           does not install a wrapper of that name, and "?" when the reading could not be taken.
#
#   wired | winners                                  | verdict  | status
#   ------+-------------------------------------------+----------+-------
#     -   | any winner outside /usr/local/bin         | shadowed |   1
#     -   | no shadow, any "?"                         | unknown  |   2
#    yes  | every winner is the wrapper or empty       | wired    |   0
#    no   | every winner is the wrapper or empty       | clear    |   0
#
# `shadowed` outranks `unknown`, since one launcher read as shadowed states what that account gets whatever another
# launcher's probe did. An empty winner leaves the verdict alone: this host does not install a wrapper of that name,
# so the PATH has no ordering to get wrong there. A call that passes an empty winner list reads `unknown` rather than
# as a clean bill, which is what an unloaded provider resolver produces.
#
# `wired` and `clear` differ in whether the reading survives the next change to PATH: each reaches the wrapper today,
# and an unwired account loses that as soon as anything prepends to its PATH.
ai_tools_path_order_verdict() {
    local wired="${1:-no}"; shift || true
    local pair launcher winner unknown=0 seen=0
    for pair in "$@"; do
        launcher="${pair%%=*}"; winner="${pair#*=}"
        seen=1
        case "${winner}" in
            '')  continue ;;
            '?') unknown=1 ;;
            "${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}/${launcher}") ;;
            *)   printf 'shadowed\n'; return 1 ;;
        esac
    done
    if (( unknown )) || (( ! seen )); then printf 'unknown\n'; return 2; fi
    if [[ "${wired}" == yes ]]; then printf 'wired\n'; else printf 'clear\n'; fi
    return 0
}

# ai_tools_path_order_launcher_valid <name>
# The launcher name is interpolated into a shell command run as another account, so it is admitted only in the shape
# a launcher has: letters, digits, dot, underscore and dash. A manifest is root-owned and trust-checked before it is
# read, so this is the second fence rather than the first, and it fails closed -- a name outside that set is not
# probed.
ai_tools_path_order_launcher_valid() { [[ "${1-}" =~ ^[A-Za-z0-9._-]+$ ]]; }

# ai_tools_path_order_readable <path>
# Admit a probe result only as an absolute path that does not hold whitespace or a control byte. The value comes
# from a login shell whose dotfiles the account writes, and it is rendered to a terminal and compared
# against the wrapper path, so any other shape reads as unreadable rather than as an answer.
ai_tools_path_order_readable() {
    [[ "${1-}" == /* && "${1}" != *[[:space:][:cntrl:]]* ]]
}

# ai_tools_path_order_guard_present <file>...
# Echo "yes" when one of the named init files already sources the fragment, else "no". Matched on the fragment's path
# rather than on the whole guard line, so a line an operator reformatted or wrote themselves counts as wired.
ai_tools_path_order_guard_present() {
    local f
    for f in "$@"; do
        [[ -r "${f}" ]] || continue
        if grep -qF "${AI_TOOLS_PATH_ORDER_FRAGMENT}" "${f}" 2>/dev/null; then
            printf 'yes\n'; return 0
        fi
    done
    printf 'no\n'
}

# ai_tools_path_order_winner_here <launcher>
# Where <launcher> resolves on THIS process's PATH -- the operator's own, when the CLI runs from their shell. Prints
# the path, an empty line when this host does not install a wrapper of that name, or "?" when the name or the answer
# fails its admission check.
ai_tools_path_order_winner_here() {
    local launcher="$1" winner
    ai_tools_path_order_launcher_valid "${launcher}" || { printf '?\n'; return 0; }
    [[ -x "${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}/${launcher}" ]] || { printf '\n'; return 0; }
    winner="$(command -v -- "${launcher}" 2>/dev/null)" || winner=""
    [[ -z "${winner}" ]] && { printf '\n'; return 0; }
    ai_tools_path_order_readable "${winner}" || winner="?"
    printf '%s\n' "${winner}"
}

# ai_tools_path_order_winner_for_user <user> <launcher>
# The same reading for ANOTHER account, taken from a login shell of its own: that account's init files are what decide
# its sessions, and grepping them answers for the guard line instead of for the ordering. Requires root (runuser),
# and is bounded by a timeout because the dotfiles it runs belong to the account. Prints the path, an empty line
# when this host does not install a wrapper of that name, or "?" when the reading could not be taken.
#
# The command runs AS the operator, so it carries only the access that account already has, and its output is admitted
# only in the shape a path has: a login shell prints its own banner, so the last line is taken and then validated.
ai_tools_path_order_winner_for_user() {
    local user="$1" launcher="$2" winner=""
    ai_tools_path_order_launcher_valid "${launcher}" || { printf '?\n'; return 0; }
    [[ -x "${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}/${launcher}" ]] || { printf '\n'; return 0; }
    if [[ "${EUID:-$(id -u)}" -ne 0 ]] || ! command -v runuser >/dev/null 2>&1; then
        printf '?\n'; return 0
    fi
    winner="$(timeout 10 runuser -l "${user}" -c "command -v -- ${launcher}" 2>/dev/null \
        | tail -n 1)" || winner=""
    [[ -z "${winner}" ]] && { printf '?\n'; return 0; }
    ai_tools_path_order_readable "${winner}" || winner="?"
    printf '%s\n' "${winner}"
}

# ai_tools_path_order_launchers
# One launcher name per line, for the agents operator.conf enables -- the wrappers whose ordering matters on this
# host. Prints no line when the provider resolver is not loaded, which the verdict reads as `unknown`: a set this host
# could not resolve is reported apart from one that resolved to no agent.
ai_tools_path_order_launchers() {
    declare -F ai_tools_enabled_agents >/dev/null 2>&1 || return 0
    local launcher
    while IFS= read -r launcher; do
        [[ -n "${launcher}" ]] && printf '%s\n' "${launcher}"
    done < <(ai_tools_enabled_agents 2>/dev/null | cut -f3)
}

# ai_tools_path_order_read_user <user>  -- read that account's ordering, as root ai_tools_path_order_read_here        --
# read this process's own, whatever account it runs as Two named entry points rather than one optional argument,
# because the two readings answer for different accounts and an omitted argument would silently choose the other one.
#
# Each takes the whole reading in one call and publishes it in four variables, since a caller needs the verdict
# AND what to say about it:
#   AI_TOOLS_PATH_ORDER_STATE   the verdict token (wired|clear|shadowed|unknown)
#   AI_TOOLS_PATH_ORDER_WINNERS the "<launcher>=<path>" pairs behind that verdict
#   AI_TOOLS_PATH_ORDER_SHADOW  the first shadowing binary, the one a message names
#   AI_TOOLS_PATH_ORDER_WIRED   "yes" when an init file sources the fragment -- published apart from the verdict
#                               because a wired account that is STILL shadowed has a different remedy. The line
#                               has to follow whatever prepends to PATH, so appending a second copy edits
#                               the file and leaves the ordering as it was
# Returns the verdict's status.
ai_tools_path_order_read_user() { _ai_tools_path_order_read "${1:?ai_tools_path_order_read_user: user is required}"; }
ai_tools_path_order_read_here() { _ai_tools_path_order_read ""; }

_ai_tools_path_order_read() {
    local user="$1" launcher winner wired status=0
    AI_TOOLS_PATH_ORDER_WINNERS=()
    AI_TOOLS_PATH_ORDER_SHADOW=""
    while IFS= read -r launcher; do
        if [[ -n "${user}" ]]; then
            winner="$(ai_tools_path_order_winner_for_user "${user}" "${launcher}")"
        else
            winner="$(ai_tools_path_order_winner_here "${launcher}")"
        fi
        AI_TOOLS_PATH_ORDER_WINNERS+=( "${launcher}=${winner}" )
        if [[ -n "${winner}" && "${winner}" != '?' \
              && "${winner}" != "${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}/${launcher}" \
              && -z "${AI_TOOLS_PATH_ORDER_SHADOW}" ]]; then
            AI_TOOLS_PATH_ORDER_SHADOW="${winner}"
        fi
    done < <(ai_tools_path_order_launchers)

    if [[ -n "${user}" ]]; then
        local home; home="$(getent passwd "${user}" | cut -d: -f6)"
        wired="$(ai_tools_path_order_guard_present "${home}/.bashrc" "${home}/.bash_profile")"
    else
        wired="$(ai_tools_path_order_guard_present "${HOME}/.bashrc" "${HOME}/.bash_profile")"
    fi
    # shellcheck disable=SC2034  # published for the caller, like the three names this header lists
    AI_TOOLS_PATH_ORDER_WIRED="${wired}"
    # shellcheck disable=SC2034  # published for the caller: the three consumers this file's header names
    AI_TOOLS_PATH_ORDER_STATE="$(ai_tools_path_order_verdict "${wired}" \
        "${AI_TOOLS_PATH_ORDER_WINNERS[@]+"${AI_TOOLS_PATH_ORDER_WINNERS[@]}"}")" || status=$?
    return "${status}"
}

# ai_tools_path_order_repoint <file>...
# Point a guard line that names the FORMER fragment at the current one, in place, and print each file rewritten.
# Returns 0 whichever files it rewrote; a file it cannot read or write is skipped without a message, since the caller
# reports the ordering itself and the file belongs to the account.
#
# This is the one edit this project makes to an operator's shell init without asking, and the bound on it is that it
# is neither a merge nor an addition: it replaces one path token, inside a line this package wrote, that names a file
# this package moved. It does not add a line or remove one, and it leaves a file naming neither path byte-identical,
# so an operator who never had the line does not acquire one and one who wrote their own keeps its spelling. Leaving
# the line as it stands would instead stop the ordering applying at an upgrade, where no terminal exists to ask at.
#
# It does not write a sidecar. The fragment ships root-owned and the package replaces it, and the deduplication and
# ordering it performs are unchanged, so the repointed line behaves as the old one did and a backup would preserve
# a path resolving to a file that is gone.
ai_tools_path_order_repoint() {
    local f content rewritten
    for f in "$@"; do
        [[ -f "${f}" && -r "${f}" && -w "${f}" && ! -L "${f}" ]] || continue
        content="$(< "${f}")" || continue
        [[ "${content}" == *"${AI_TOOLS_PATH_ORDER_FRAGMENT_FORMER}"* ]] || continue
        rewritten="${content//${AI_TOOLS_PATH_ORDER_FRAGMENT_FORMER}/${AI_TOOLS_PATH_ORDER_FRAGMENT}}"
        # Written through the existing inode, so the file keeps the owner, group and mode the account gave it -- this
        # runs as root, and a fresh file would land root-owned.
        printf '%s\n' "${rewritten}" > "${f}" 2>/dev/null || continue
        printf '%s\n' "${f}"
    done
}

# ai_tools_path_order_repoint_user <user>
# The same for an account, resolved through its passwd entry: the init files bash reads.
ai_tools_path_order_repoint_user() {
    local home; home="$(getent passwd "${1}" | cut -d: -f6)"
    [[ -n "${home}" && -d "${home}" ]] || return 0
    ai_tools_path_order_repoint "${home}/.bashrc" "${home}/.bash_profile"
}

# ai_tools_path_order_shadowed_operators <user>...
# Print "<user><TAB><launcher><TAB><winner>" for each named account whose shell reaches an agent somewhere other than
# /usr/local/bin, and no line for an account in any other state. Root only, since each reading is taken from a login
# shell of the account.
#
# It exists for `ai-tools-admin system bootstrap`, which reports what a freshly provisioned host still owes and does
# not hold a loop of its own. An account this reading could not be taken for is left unnamed, because a report that
# guessed would name a host it could not read, and the operator's own `ai-tools --status` answers precisely.
ai_tools_path_order_shadowed_operators() {
    local user pair launcher
    for user in "$@"; do
        [[ -n "${user}" ]] || continue
        ai_tools_path_order_read_user "${user}" >/dev/null 2>&1 || true
        [[ "${AI_TOOLS_PATH_ORDER_STATE:-}" == shadowed ]] || continue
        launcher=""
        for pair in "${AI_TOOLS_PATH_ORDER_WINNERS[@]+"${AI_TOOLS_PATH_ORDER_WINNERS[@]}"}"; do
            [[ "${pair#*=}" == "${AI_TOOLS_PATH_ORDER_SHADOW}" ]] && { launcher="${pair%%=*}"; break; }
        done
        printf '%s\t%s\t%s\n' "${user}" "${launcher}" "${AI_TOOLS_PATH_ORDER_SHADOW}"
    done
}

# ai_tools_path_order_stale_operators <user>...
# Print each named account whose bash init still names the FORMER fragment. A READ, and the only
# question about the PATH ordering an rpm scriptlet asks: a package installs into the host's own
# directories and leaves a home alone, so the scriptlet reports and `ai-tools-admin operators add`
# is what rewrites the line, with its confirm. It does not start a login shell either -- the
# accurate reading executes the account's own init, which is a person's command to give rather
# than a transaction's.
ai_tools_path_order_stale_operators() {
    local user home f
    for user in "$@"; do
        [[ -n "${user}" ]] || continue
        home="$(getent passwd "${user}" | cut -d: -f6)"
        [[ -n "${home}" && -d "${home}" ]] || continue
        for f in "${home}/.bashrc" "${home}/.bash_profile"; do
            [[ -r "${f}" ]] || continue
            if grep -qF "${AI_TOOLS_PATH_ORDER_FRAGMENT_FORMER}" "${f}" 2>/dev/null; then
                printf '%s\n' "${user}"
                break
            fi
        done
    done
}

# ai_tools_path_order_reconcile_operators <user>...
# The whole per-host pass, in one call: repoint every guard line naming the former fragment, then report each account
# whose shell reaches an agent outside /usr/local/bin. Prints one TAB-separated record per event, tagged so a caller
# reads the two kinds from one stream:
#
#   repointed<TAB><file>
#   shadowed<TAB><user><TAB><launcher><TAB><winner>
#
# Root only. It exists so the base package's %post is one invocation rather than a loop spelled in scriptlet shell,
# and the order carries the meaning: the repoint runs first, so the report describes the host as the upgrade leaves it
# rather than as it found it.
ai_tools_path_order_reconcile_operators() {
    local user line
    for user in "$@"; do
        [[ -n "${user}" ]] || continue
        while IFS= read -r line; do
            [[ -n "${line}" ]] && printf 'repointed\t%s\n' "${line}"
        done < <(ai_tools_path_order_repoint_user "${user}")
    done
    while IFS= read -r line; do
        [[ -n "${line}" ]] && printf 'shadowed\t%s\n' "${line}"
    done < <(ai_tools_path_order_shadowed_operators "$@")
}

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/settings-merge.lib.sh
# The merge that carries this version's hook declarations into an agent's settings.json when an upgrade keeps the file,
# the read-only check for the ask entries such a file lacks, and the jq gate every JSON path of the reconciliation
# passes first. Sourced by install.sh, `ai-tools-admin system post-upgrade` and the agent package's typesafe trigger,
# all as root at install time; kept out of conf.lib.sh, which every session launch and every root helper sources
# and which does not need jq. What the merge adds, removes and leaves as written is in claude-settings.rule.md.
#
# conf.lib.sh is a hard dependency: it holds the dated sidecars (the .bak kept before a merge replaces the file,
# the .shipped baseline left when a merge cannot run) and the report this file writes through. A load failure returns
# non-zero before any function here is defined, so a caller's `source ... && declare -F ...` guard falls back to its
# unmerged path rather than merging without a backup.

# Include guard: this file's readonly jq programs would abort a `set -e` shell sourcing it twice. An if-statement, not
# `[[ ]] && return`, which returns 1 for an unset guard and trips the sourcing shell's `set -e`.
if [[ -n "${_AI_TOOLS_SETTINGS_MERGE_LIB:-}" ]]; then
    return 0
fi

# _ai_tools_settings_merge_warn [code] <message...> : the load refusal's report, on stderr, in the leading-code form
#   msg.lib.sh states. Defined here rather than taken from conf.lib.sh, since it reports that library failing to load.
_ai_tools_settings_merge_warn() {
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then printf '%s\n' "$1" >&2; shift; fi
    printf 'ai-tools: %s\n' "$*" >&2
    return 0
}

# shellcheck source=SCRIPTDIR/conf.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/conf.lib.sh" 2>/dev/null \
        || ! declare -F ai_tools_conf_backup >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_reference >/dev/null 2>&1; then
    _ai_tools_settings_merge_warn MSG-U9Y9 \
        "settings-merge.lib.sh: conf.lib.sh missing or incomplete -- hook declarations not merged"
    return 1
fi
readonly _AI_TOOLS_SETTINGS_MERGE_LIB=1

# ai_tools_conf_require_jq : succeed when jq is callable. jq is a package dependency, so its
#   absence is a broken install rather than a host variation -- this reports and fails instead of
#   degrading, and each JSON path gates on it. Not checked when this library is sourced: install.sh
#   and ai-tools-admin source it at startup, and a missing jq costs the JSON step alone, not
#   the install or the post-upgrade pass around it.
ai_tools_conf_require_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    _ai_tools_conf_warn MSG-F9W4 "jq not found -- it is a package dependency; reinstall ai-tools-base"
    return 1
}

# ── JSON hook declarations ───────────────────────────────────────────────────────────────────
# An agent's settings file is kept across an upgrade, because it carries host tuning a reset would revert. Its HOOK
# DECLARATIONS are not tuning though: they are control plane that merges additively and that no lower-precedence layer
# may remove, so a version that ships a new hook has to get that declaration into a kept file or the hook it installed
# never runs.
#
# The merge adds only declarations the file lacks and leaves every other key -- the permission arrays it was kept
# for, an operator's own hook -- as written. It also removes a SHIPPED command declared more than once under the same
# event and matcher, keeping the first: Claude Code runs every declaration, so a repeat runs that hook twice per call,
# and a file carrying one is repaired on its next merge. Reporting is the caller's: this sets what happened and returns
# how it went, so the same decision can be rendered by an installer, a test, or a future agent's tooling without
# the wording living here.

# The shipped hook commands a deployed file does not declare, as "<event>: <command>". The command binds to $command
# before the membership test: inside index(), `.` is that function's own input -- the $have array -- so an unbound form
# asks whether the array contains itself and does not report a gap wherever the event already declares a hook.
# shellcheck disable=SC2016  # jq variables, bound by `--slurpfile` and jq's own `as`
readonly _AI_TOOLS_CONF_HOOKS_MISSING_FILTER='
    . as $cur
    | ($shipped[0].hooks // {}) | to_entries[] as $event
    | ([ (($cur.hooks // {})[$event.key] // [])[] | (.hooks // [])[] | .command ]) as $have
    | $event.value[] | (.hooks // [])[] | .command as $command
    | select(($have | index($command)) == null)
    | "\($event.key): \($command)"'

# dedupe_event($cmds): one event's matcher groups with every repeat of a command in $cmds under the same matcher
# dropped, the first occurrence in file order kept, and a group the drop empties removed; {groups, removed}
# with the dropped commands in `removed`. A command outside $cmds -- an operator's own hook -- is never dropped. Defined
# once and shared by the report and the merge, so what is reported is what is removed.
# shellcheck disable=SC2016  # jq variables, bound by jq's own `as`
readonly _AI_TOOLS_CONF_HOOKS_DEDUPE_DEF='
    def dedupe_event($cmds):
        reduce (.[]) as $group ({seen: {}, groups: [], removed: []};
            (($group.matcher // "") | tostring) as $matcher
            | if ($group | has("hooks") | not) then .groups += [$group]
              else
                (reduce ($group.hooks[]) as $hook ({seen: .seen, keep: [], removed: .removed};
                    ($hook.command // null) as $command
                    | ($matcher + "\u0000" + ($command | tostring)) as $key
                    | if $command != null and ($cmds | any(. == $command)) and (.seen[$key] // false)
                      then .removed += [$command]
                      else .keep += [$hook] | .seen[$key] = true
                      end)) as $walk
                | .seen = $walk.seen | .removed = $walk.removed
                | if ($walk.keep | length) == 0 and ($group.hooks | length) > 0 then .
                  else .groups += [$group + {hooks: $walk.keep}] end
              end);'

# The shipped hook commands a deployed file declares more than once under one event and matcher, as "<event>: <command>"
# per repeat the merge removes.
# shellcheck disable=SC2016  # jq variables, bound by `--slurpfile` and jq's own `as`
readonly _AI_TOOLS_CONF_HOOKS_DUPLICATE_FILTER="${_AI_TOOLS_CONF_HOOKS_DEDUPE_DEF}"'
    . as $cur
    | ($shipped[0].hooks // {}) | to_entries[] as $event
    | [ $event.value[] | (.hooks // [])[] | .command ] as $cmds
    | ((($cur.hooks // {})[$event.key] // []) | dedupe_event($cmds)).removed[]
    | "\($event.key): \(.)"'

# Append, under each shipped group's matcher, only that group's commands the event does not declare, so a command
# already declared elsewhere in the event is not declared again; then drop the repeats dedupe_event finds.
# shellcheck disable=SC2016  # jq variables, as in the report programs
readonly _AI_TOOLS_CONF_HOOKS_MERGE_FILTER="${_AI_TOOLS_CONF_HOOKS_DEDUPE_DEF}"'
    ($shipped[0].hooks // {}) as $ship
    | reduce ($ship | to_entries[]) as $event (
        .;
        reduce ($event.value[]) as $group (
            .;
            ([ ((.hooks // {})[$event.key] // [])[] | (.hooks // [])[] | .command ]) as $have
            | [ ($group.hooks // [])[] | select(.command as $command | ($have | any(. == $command)) | not) ] as $absent
            | if ($absent | length) == 0 then .
              else .hooks[$event.key] = ((.hooks[$event.key] // []) + [$group + {hooks: $absent}])
              end
          )
        | [ $event.value[] | (.hooks // [])[] | .command ] as $cmds
        | if (.hooks // {})[$event.key] == null then .
          else .hooks[$event.key] = (.hooks[$event.key] | dedupe_event($cmds)).groups end
      )'

# ai_tools_conf_merge_hook_declarations <deployed> <shipped> : merge the shipped hook
#   declarations into <deployed>.
#     returns 0  merged      _ai_tools_conf_merge_added holds "<event>: <command>" per addition,
#                            _ai_tools_conf_merge_removed the same per duplicate removed,
#                            _ai_tools_conf_merge_backup the copy of what the operator had
#     returns 1  no change   the file declares everything shipped, each once; no write happens
#     returns 2  refused     the file is byte-identical and _ai_tools_conf_merge_reference holds
#                            the baseline dropped for a hand merge (empty if even that failed);
#                            _ai_tools_conf_merge_reason says which check refused
#   The deployed file is never opened for writing: the merge is built in a temporary file and
#   validated as JSON before an atomic rename, so a failure at any point leaves the original.
ai_tools_conf_merge_hook_declarations() {
    local deployed="$1" shipped="$2" missing="" duplicates="" tmp=""
    _ai_tools_conf_merge_added=()
    _ai_tools_conf_merge_removed=()
    _ai_tools_conf_merge_backup=""
    _ai_tools_conf_merge_reference=""
    _ai_tools_conf_merge_reason=""

    _refuse() {
        _ai_tools_conf_merge_reason="$1"
        _ai_tools_conf_merge_reference="$(ai_tools_conf_reference "${deployed}" "${shipped}")" || true
        return 2
    }

    [[ -f "${deployed}" && -f "${shipped}" ]] || { _ai_tools_conf_merge_reason="missing file"; return 2; }
    ai_tools_conf_require_jq || { _refuse "jq is not installed"; return 2; }
    jq -e . "${deployed}" >/dev/null 2>&1 || { _refuse "the deployed file is not valid JSON"; return 2; }

    missing="$(jq -r --slurpfile shipped "${shipped}" \
        "${_AI_TOOLS_CONF_HOOKS_MISSING_FILTER}" "${deployed}" 2>/dev/null)" \
        || { _refuse "the deployed file's hook declarations could not be read"; return 2; }
    duplicates="$(jq -r --slurpfile shipped "${shipped}" \
        "${_AI_TOOLS_CONF_HOOKS_DUPLICATE_FILTER}" "${deployed}" 2>/dev/null)" \
        || { _refuse "the deployed file's hook declarations could not be read"; return 2; }
    [[ -n "${missing}" || -n "${duplicates}" ]] || return 1

    tmp="$(mktemp "${deployed}.XXXXXX" 2>/dev/null)" || { _refuse "no temporary file could be created"; return 2; }
    if ! jq --slurpfile shipped "${shipped}" \
            "${_AI_TOOLS_CONF_HOOKS_MERGE_FILTER}" "${deployed}" > "${tmp}" 2>/dev/null \
            || ! jq -e . "${tmp}" >/dev/null 2>&1; then
        rm -f "${tmp}"
        _refuse "the merged result was not valid JSON"
        return 2
    fi

    # Keep what the operator had before replacing it: this is the only copy that restores host tuning if a merge is
    # valid JSON yet wrong, which the JSON check cannot catch.
    _ai_tools_conf_merge_backup="$(ai_tools_conf_backup "${deployed}")" || true
    _ai_tools_conf_match_perms "${tmp}" "${deployed}"
    mv -f "${tmp}" "${deployed}" || { rm -f "${tmp}"; _refuse "the merged file could not be moved into place"; return 2; }

    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && _ai_tools_conf_merge_added+=("${line}")
    done <<< "${missing}"
    while IFS= read -r line; do
        [[ -n "${line}" ]] && _ai_tools_conf_merge_removed+=("${line}")
    done <<< "${duplicates}"
    return 0
}

# ── JSON ask entries ─────────────────────────────────────────────────────────────────────────
# A command that sends data off the host carries an `ask` entry in the shipped settings.json, so the operator confirms
# every call (claude-settings.rule.md). The merge leaves the permission arrays as the host wrote them, so a kept file
# does not gain a newly shipped entry, and after an upgrade the host may hold no shipped copy to compare with. Each
# entry is therefore listed here as "<command path>|<entry>", and a kept file is checked against this table. The shipped
# settings.json carries every entry listed here.
readonly -a _AI_TOOLS_CONF_ASK_GATES=(
    "/usr/local/lib/ai-tools/typesafe/decide.mjs|Bash(node /usr/local/lib/ai-tools/typesafe/decide.mjs *)"
)

# ai_tools_conf_ask_gaps <settings> [root] : print each ask entry <settings> does not carry for a command installed
#   under <root> (default /), one per line. Prints nothing when every installed command asks.
#     returns 0  checked     the gaps, if any, are on stdout
#     returns 1  not checked jq is missing, <settings> is not readable JSON, or its permissions.ask is not an array
#   Read-only: the permission arrays are the host's, so a caller reports the gap and does not write the entry.
ai_tools_conf_ask_gaps() {
    local settings="$1" root="${2:-}" have gate command entry
    ai_tools_conf_require_jq || return 1
    have="$(jq -r '(.permissions.ask // []) | if type == "array" then .[] else error end' "${settings}" 2>/dev/null)" \
        || return 1
    for gate in "${_AI_TOOLS_CONF_ASK_GATES[@]}"; do
        command="${gate%%|*}"
        entry="${gate#*|}"
        [[ -e "${root}${command}" ]] || continue
        grep -qxF -- "${entry}" <<< "${have}" || printf '%s\n' "${entry}"
    done
    return 0
}

# ai_tools_conf_ask_fix <settings> <entry>... : print where the entries go in <settings> and the JSON to paste there.
#   stdout: line 1 says where, the lines after it are the snippet, shaped for the file as it stands -- the entries alone
#   when `permissions.ask` exists, an `"ask"` array when `permissions` exists without one, and a `"permissions"` object
#   when neither does. Each entry is JSON-encoded. The snippet goes FIRST in its object or array and ends in a comma
#   unless that container is empty, so the pasted file is valid JSON. Returns 1 when jq is missing, <settings> is not
#   a readable JSON object, or its `permissions` or `permissions.ask` is present with the wrong type.
ai_tools_conf_ask_fix() {
    local settings="$1" shape empty entry comma=","
    shift
    ai_tools_conf_require_jq || return 1
    shape="$(jq -r 'if type != "object" then error
        elif has("permissions") | not then "none \(length == 0)"
        elif (.permissions | type) != "object" then error
        elif (.permissions | has("ask")) | not then "permissions \(.permissions | length == 0)"
        elif (.permissions.ask | type) != "array" then error
        else "ask \(.permissions.ask | length == 0)" end' "${settings}" 2>/dev/null)" || return 1
    empty="${shape#* }"
    shape="${shape%% *}"
    [[ "${empty}" == true ]] && comma=""
    local -a encoded=()
    for entry in "$@"; do encoded+=("$(jq -n --arg e "${entry}" '$e')"); done
    case "${shape}" in
    ask)
        printf 'paste as the first lines of the "ask" list inside "permissions", right after its [:\n'
        _ai_tools_conf_ask_items "" "${comma}" "${encoded[@]}" ;;
    permissions)
        printf 'paste as the first lines inside "permissions", right after its {:\n'
        printf '"ask": [\n'
        _ai_tools_conf_ask_items "  " "" "${encoded[@]}"
        printf ']%s\n' "${comma}" ;;
    *)
        printf 'paste as the first lines of the file, right after its opening {:\n'
        printf '"permissions": {\n  "ask": [\n'
        _ai_tools_conf_ask_items "    " "" "${encoded[@]}"
        printf '  ]\n}%s\n' "${comma}" ;;
    esac
}

# _ai_tools_conf_ask_items <indent> <last> <json-string>... : print the items of a JSON array, a comma after each but
#   the last, which takes <last> ("," when more items follow in the file, "" when none do).
_ai_tools_conf_ask_items() {
    local indent="$1" last="$2" i
    shift 2
    for (( i = 1; i <= $#; i++ )); do
        if (( i < $# )); then printf '%s%s,\n' "${indent}" "${!i}"; else printf '%s%s%s\n' "${indent}" "${!i}" "${last}"; fi
    done
}

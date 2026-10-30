#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/conf.lib.sh
# The one KEY=value grammar every ai-tools config file is read with, the trust predicate that decides whether a file may
# be read at all, and what shares the grammar and so lives beside it: the kind prefix a provider list item carries
# (ai_tools_conf__read_kind_list, which filters.lib.sh reads as well as providers.lib.sh), the dated config sidecars
# (`<name>.<YYYYMMDD>-<N>.{bak,shipped}`, whose stamp ai_tools_conf__find_sidecar_path is the single home of), the one
# in-place write of a KEY=value file (ai_tools_conf__set_key for a scalar, ai_tools_conf__set_list for a list),
# and every read AND write of the project registry. The settings.json hook-declaration merge, which writes
# through the sidecars, is settings-merge.lib.sh. Sourced (never executed) by operator.lib.sh, skip-dirs.lib.sh,
# providers.lib.sh, the launch wrapper, the CLI and the root helpers, so a key and an allowlist line read the same
# whichever component reads them. The grammar, the present/absent distinction the provider gating turns
# on, and what the trust predicate requires are in providers.rule.md; the allowlist state model is in cli.rule.md.
#
# Config files are PARSED, never sourced: a malformed or tampered file yields a bad value, never executed code
# in a privileged script. List splitting pins IFS locally, because the sourcing scripts run under the strict-mode
# IFS=$'\n\t', where an inherited IFS would read "a b" as one item -- for a provider allowlist, a wrong "no such
# provider" verdict.
#
# A trust refusal reports the owner uid and mode the predicate read (ai_tools_conf__read_untrusted_reason). The owner is
# read through the calling process's uid map, so on the refusal path the reason names the translation where the map is
# not the identity (ai_tools_conf__is_uid_map_identity). The predicate itself does not read the map: what each map does
# to the owner, and where every reader runs, are providers.rule.md's (ref-section-x4z9).

# Sourced more than once in a single shell: this library's readonly constants would abort under `set -e` on the second
# pass. Return early (an if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and trips the sourcing
# shell's `set -e`).
if [[ -n "${_AI_TOOLS_CONF__LOADED:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_CONF__LOADED=1

# ai_tools_conf__warn [code] <message...> : this library's one report, on stderr. A leading message code (msg.lib.sh
#   states the form) goes on its own line ahead of the message, the shape tests/lib/harness.sh's assert_msg reads;
#   matched inline, since this library is sourced by every root helper and by the sandbox account on each launch
#   and so takes no dependency of its own. The `conf: ` prefix is stated here, so a message text does not carry one.
ai_tools_conf__warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'conf: %s\n' "$*" >&2
}

# ai_tools_conf__is_text_file <path> : succeed when <path> is a regular file that is empty or holds text -- no NUL
#   bytes, which is what `grep -I` reports a binary file by. For a file whose whole content is handed to a program
#   as prose (an agent's system prompt): the trust predicate says who may have written it, this says the bytes are
#   the kind the reader expects. It READS the file, so the caller is an account that may.
ai_tools_conf__is_text_file() {
    local path="$1"
    [[ -f "${path}" ]] || return 1
    [[ -s "${path}" ]] || return 0
    LC_ALL=C grep -Iq . "${path}" 2>/dev/null
}

# ai_tools_conf__is_trusted <path> : succeed when <path> exists, is not a symlink, is owned by root, and is writable
#   by neither group nor other -- the property that makes it safe for a sandbox-side process to parse or source.
#   A symlink is refused outright rather than followed, so a link planted in a writable directory cannot redirect
#   the read at a root-owned target. Applies to directories too: a group-writable directory lets a non-root writer
#   unlink and replace the root-owned file inside it, so a trusted file in an untrusted directory is not trusted. Fails
#   closed on any stat error.
ai_tools_conf__is_trusted() {
    local path="${1:-}" meta owner mode
    [[ -n "${path}" ]] || return 1
    [[ -L "${path}" ]] && return 1
    [[ -e "${path}" ]] || return 1
    meta="$(stat -c '%u %a' "${path}" 2>/dev/null)" || return 1
    owner="${meta%% *}"; mode="${meta##* }"
    [[ "${owner}" == 0 ]] || return 1
    [[ "${mode}" =~ ^[0-7]+$ ]] || return 1
    (( (0${mode} & 022) == 0 ))
}

# ai_tools_conf__is_uid_map_identity [map-file] : succeed when this process's uid map is exactly one identity range
#   over the whole uid space -- the initial user namespace's map, and the one under which an owner uid read off disk
#   means what it says. Any other content, an empty map included, means uids are translated and fails closed
#   with the rest. Parsing sets IFS locally, since callers run under a strict IFS that would otherwise stop `read -a`
#   splitting the kernel's space-padded columns, and a map of several ranges is refused on the embedded newline rather
#   than parsed from its first line alone. <map-file> is /proc/self/uid_map for a live reading (the default)
#   and a fixture under test; it is a positional argument, so no environment variable selects it.
ai_tools_conf__is_uid_map_identity() {
    local map_file="${1:-/proc/self/uid_map}" map IFS=$' \t\n'
    local -a ranges=()
    [[ -r "${map_file}" ]] || return 1
    map="$(<"${map_file}")"
    [[ "${map}" == *$'\n'* ]] && return 1
    read -r -a ranges <<< "${map}"
    (( ${#ranges[@]} == 3 )) || return 1
    [[ "${ranges[0]}" == 0 && "${ranges[1]}" == 0 && "${ranges[2]}" == 4294967295 ]]
}

# ai_tools_conf__read_untrusted_reason <path> : print, on one line, what ai_tools_conf__is_trusted observed
#   about a <path> it refused -- the owner uid and mode it read, against what it requires -- so the refusal states
#   what was observed. When the owner check fails under a uid map other than the identity the line says so: the uid read
#   there is a translation, and ownership on disk cannot be evaluated from it. Always prints and returns 0.
ai_tools_conf__read_untrusted_reason() {
    local path="${1:-}" meta owner mode
    [[ -n "${path}" ]] || { printf 'no path given'; return 0; }
    [[ -L "${path}" ]] && { printf 'is a symlink'; return 0; }
    [[ -e "${path}" ]] || { printf 'does not exist'; return 0; }
    meta="$(stat -c '%u %a' "${path}" 2>/dev/null)" || { printf 'could not be stat-ed'; return 0; }
    owner="${meta%% *}"; mode="${meta##* }"
    printf 'owner=%s mode=%s, expected owner=0 with no group/other write' "${owner}" "${mode}"
    if [[ "${owner}" != 0 ]] && ! ai_tools_conf__is_uid_map_identity /proc/self/uid_map; then
        printf ' (this process'"'"'s uid map is not the identity, so the owner it reads is a translation and ownership on disk cannot be evaluated here; a uid outside the map reads as the overflow uid 65534)'
    fi
    return 0
}

# ai_tools_conf__read_unreadable_reason <path> : print, on one line, why a <path> ai_tools_conf__is_trusted accepted
#   could not be read by this process -- the account, and the type, owner and mode stat read -- and the command
#   that restores the installed layout. The twin of ai_tools_conf__read_untrusted_reason: the trust predicate reads
#   a path with stat alone, so an input can pass it and still be unreadable, and every reader of an installed input
#   reports that state through this one text. Always prints and returns 0.
ai_tools_conf__read_unreadable_reason() {
    local path="${1:-}" account meta
    [[ -n "${path}" ]] || { printf 'no path given'; return 0; }
    account="$(id -un 2>/dev/null)" || account="uid ${EUID}"
    meta="$(stat -c '%F, owner=%U:%G, mode=%a' -- "${path}" 2>/dev/null)" || meta="could not be stat-ed"
    printf '%s cannot read it (%s) -- restore the installed layout: atr admin system layout reconcile' \
        "${account}" "${meta}"
    return 0
}

# _ai_tools_conf__strip_inline_comment <text> : set ai_tools_conf__value to <text> with an inline comment removed. `#`
#   ends the value only where a comment conventionally starts -- at the very beginning, or after whitespace --
#   so an interior `#` (a fragment, a C# name, a colour) stays part of an unquoted value.
_ai_tools_conf__strip_inline_comment() {
    local rest="$1" kept="" head
    while [[ "${rest}" == *'#'* ]]; do
        head="${rest%%#*}"
        if [[ -z "${kept}${head}" || "${head}" == *[[:space:]] ]]; then
            ai_tools_conf__value="${kept}${head}"
            return 0
        fi
        kept+="${head}#"
        rest="${rest#*#}"
    done
    ai_tools_conf__value="${kept}${rest}"
}

# _ai_tools_conf__parse_value <raw> : set ai_tools_conf__value to the value <raw> (everything after the `=`) denotes --
#   surrounding whitespace trimmed, one matched quote layer stripped, inline comment removed. A quoted value ends at its
#   closing quote and whatever follows is discarded, so `#` inside quotes stays literal. An unmatched opening quote is
#   taken verbatim rather than silently truncating the value at some later character. Sets _ai_tools_conf__value_quoted
#   to 1 when the value opened with a quote and 0 otherwise, which is what ai_tools_conf__split_list_value tells `"[a]"`
#   from `[a]` by once the quotes are gone.
_ai_tools_conf__parse_value() {
    local value="$1" quote rest
    value="${value#"${value%%[![:space:]]*}"}"
    case "${value}" in
        '"'*) quote='"' ;;
        "'"*) quote="'" ;;
        *)    quote=''  ;;
    esac
    _ai_tools_conf__value_quoted=0
    [[ -n "${quote}" ]] && _ai_tools_conf__value_quoted=1
    if [[ -n "${quote}" ]]; then
        rest="${value#?}"
        if [[ "${rest}" == *"${quote}"* ]]; then
            ai_tools_conf__value="${rest%%"${quote}"*}"
            return 0
        fi
        value="${rest}"
    else
        _ai_tools_conf__strip_inline_comment "${value}"
        value="${ai_tools_conf__value}"
    fi
    ai_tools_conf__value="${value%"${value##*[![:space:]]}"}"
}

# ai_tools_conf__read <file> <key> : set ai_tools_conf__value to the value of the LAST assignment of <key> in <file>.
#   Returns 0 when the key is PRESENT (an empty value included), 1 when it is absent from a file read whole, and 2
#   when the file fails the regular-file or read-permission test or its read did not complete -- the present-but-empty /
#   absent distinction the fail-closed allowlist gating depends on, and the absent / unread distinction a reader
#   whose default for an absent key widens access depends on (the assets resolver reads a missing asset_profiles
#   as the base profiles). The file is read whole through cat, whose status reports an open or read failure
#   where the read builtin reports end of input, so a directory or a file an I/O error cuts short is 2.
ai_tools_conf__read() {
    local file="$1" wanted="$2" line key content found=1
    ai_tools_conf__value=""
    _ai_tools_conf__value_quoted=0
    [[ -f "${file}" && -r "${file}" ]] || return 2
    content="$(cat -- "${file}" 2>/dev/null)" || return 2
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${line}" || "${line}" == '#'* || "${line}" != *=* ]] && continue
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "${key}" == "${wanted}" ]] || continue
        _ai_tools_conf__parse_value "${line#*=}"
        found=0
    done <<< "${content}"
    return "${found}"
}

# ai_tools_conf__is_yes <file> <key> : succeed when <key> is set to a yes value -- yes, true, 1 or on, in any case
#   and with or without quotes, which the grammar has already removed. No, false, 0, off, an empty value, an absent key
#   and an unreadable file are all no. A value in neither set is no as well, and is reported, so a mistyped switch does
#   not change what a launch does without a line saying so.
ai_tools_conf__is_yes() {
    local file="$1" key="$2"
    ai_tools_conf__read "${file}" "${key}" || return 1
    case "${ai_tools_conf__value,,}" in
        yes|true|1|on) return 0 ;;
        no|false|0|off|"") return 1 ;;
    esac
    ai_tools_conf__warn MSG-D2F9 "switch ${key} in ${file} is neither a yes value (yes, true, 1, on) nor a no value (no, false, 0, off) -- read as no"
    return 1
}

# ai_tools_conf__is_no <file> <key> : succeed when <key> is set to a no value -- no, false, 0, off or an empty value,
#   in any case and with or without quotes -- the reader for a switch whose default is yes. A yes value, an absent key
#   and an unreadable file are not no. A value in neither set is not no either, and is reported, so a mistyped switch
#   keeps the posture its default gives and does not change what a launch does without a line saying so.
ai_tools_conf__is_no() {
    local file="$1" key="$2"
    ai_tools_conf__read "${file}" "${key}" || return 1
    case "${ai_tools_conf__value,,}" in
        no|false|0|off|"") return 0 ;;
        yes|true|1|on) return 1 ;;
    esac
    ai_tools_conf__warn MSG-H7N5 "switch ${key} in ${file} is neither a yes value (yes, true, 1, on) nor a no value (no, false, 0, off) -- read as yes"
    return 1
}

# ai_tools_conf__print_value <file> <key> : print the value of <key>, empty when absent, at the status
#   ai_tools_conf__read returns. For a caller that only wants the string; one that must tell absent from empty calls
#   ai_tools_conf__read.
ai_tools_conf__print_value() {
    local status=0
    ai_tools_conf__read "$1" "$2" || status=$?
    printf '%s' "${ai_tools_conf__value}"
    return "${status}"
}

# ai_tools_conf__split <array-name> <value> : split <value> into the named array on commas and whitespace, dropping
#   empty items. IFS is set locally, so the result does not depend on the caller's IFS. The splitter for a command-line
#   argument, which does not read brackets; a list read from a file goes through ai_tools_conf__split_list_value. Every
#   local carries the function's prefix: <array-name> resolves from this function outward through its callers,
#   so a local of that name in any of them would take the items and leave the caller's array empty.
ai_tools_conf__split() {
    local -n _ai_tools_conf__split_out="$1"
    local _ai_tools_conf__split_token
    local -a _ai_tools_conf__split_tokens=()
    local IFS=$' \t\n,'
    read -ra _ai_tools_conf__split_tokens <<< "${2-}"
    _ai_tools_conf__split_out=()
    for _ai_tools_conf__split_token in "${_ai_tools_conf__split_tokens[@]}"; do
        [[ -n "${_ai_tools_conf__split_token}" ]] && _ai_tools_conf__split_out+=("${_ai_tools_conf__split_token}")
    done
    return 0
}

# ai_tools_conf__read_list <array-name> <file> <key> : read <key> from <file> and split it into the named array,
#   but ONLY when the key is present -- a present key REPLACES the array (an empty value giving an empty array,
#   an explicit "none"), while an absent key leaves it untouched and returns 1. That is what makes an override key
#   override: a caller seeds the array with its default and calls this, and a config that omits the key keeps
#   that default. A file not read whole leaves the array untouched as well and returns 2, ai_tools_conf__read's status,
#   so a caller that reports an absent key tells it from a file it could not read.
ai_tools_conf__read_list() {
    ai_tools_conf__read "$2" "$3" || return $?
    ai_tools_conf__split_list_value "$1" "${ai_tools_conf__value}" "${_ai_tools_conf__value_quoted}" "$3 in $2"
}

# ai_tools_conf__split_list_value <array-name> <value> [quoted] [label] : split a list value read from a file
#   into the named array. `[a, b]` is a bracketed list, whose inside splits as ai_tools_conf__split splits; any other
#   value splits as it stands. A value with one bracket and not the other, one whose quotes the parser stripped
#   (<quoted> 1, `"[a]"`), and a bracketed one carrying a quote or a further bracket inside is invalid: the array is set
#   EMPTY, MSG-D5N5 names <label> on stderr, and ai_tools_conf__list_invalid is set to 1 (0 otherwise). Empty is
#   the less-access reading for every list that grants something -- an empty OPERATORS does not enrol any account,
#   an empty AI_TOOLS_AGENTS does not enable any agent -- where treating the key as absent would fall back to a default
#   that enables more. Returns 0 either way, since several callers run under `set -e`. Its locals carry a prefix
#   for the reason ai_tools_conf__split's do, until the array's last write.
ai_tools_conf__split_list_value() {
    local _ai_tools_conf__list_value_text="${2-}" _ai_tools_conf__list_value_inner _ai_tools_conf__list_value_reason=""
    ai_tools_conf__list_invalid=0
    _ai_tools_conf__list_value_text="${_ai_tools_conf__list_value_text#"${_ai_tools_conf__list_value_text%%[![:space:]]*}"}"
    _ai_tools_conf__list_value_text="${_ai_tools_conf__list_value_text%"${_ai_tools_conf__list_value_text##*[![:space:]]}"}"
    if [[ "${_ai_tools_conf__list_value_text}" != '['* && "${_ai_tools_conf__list_value_text}" != *']' ]]; then
        ai_tools_conf__split "$1" "${_ai_tools_conf__list_value_text}"
        return 0
    fi
    _ai_tools_conf__list_value_inner="${_ai_tools_conf__list_value_text#[}"; _ai_tools_conf__list_value_inner="${_ai_tools_conf__list_value_inner%]}"
    if [[ "${_ai_tools_conf__list_value_text}" != '['*']' ]]; then
        _ai_tools_conf__list_value_reason="it has one bracket and not the other"
    elif [[ "${3:-0}" == 1 ]]; then
        _ai_tools_conf__list_value_reason="a bracketed list is written without quotes around it"
    elif [[ "${_ai_tools_conf__list_value_inner}" == *[\"\'\[\]]* ]]; then
        _ai_tools_conf__list_value_reason="an item inside brackets carries no quote or bracket"
    fi
    if [[ -n "${_ai_tools_conf__list_value_reason}" ]]; then
        local -n _ai_tools_conf__list_value_out="$1"
        _ai_tools_conf__list_value_out=()
        ai_tools_conf__list_invalid=1
        # Plain names for the message, declared once the nameref is not written again.
        local label="${4:-a list value}" reason="${_ai_tools_conf__list_value_reason}" value="${_ai_tools_conf__list_value_text}"
        ai_tools_conf__warn MSG-D5N5 "invalid list, read as the empty list -- ${label} (${reason}): ${value}; write it as [a, b]"
        return 0
    fi
    ai_tools_conf__split "$1" "${_ai_tools_conf__list_value_inner}"
}

# ── Kind prefixes: what a provider list item names ───────────────────────────────────────────
# An item of AI_TOOLS_AGENTS, AI_TOOLS_INTEGRATIONS or AI_TOOLS_FILTERS carries its kind as a prefix (agent-claude-code,
# integration-dotnet, filter-dotnet), so one word names one thing wherever an operator writes it: dotnet is both
# an integration and a filter set. The prefix lives in operator.conf alone -- a manifest, a fragment and a rules file
# keep the bare name, since their directory already states the kind -- so the list reader strips it and every consumer
# receives the bare name. An item without its key's prefix makes the whole list invalid (MSG-X6F2): an earlier release
# wrote bare names, and `atr admin system post-upgrade` rewrites them (ai_tools_providers__migrate_kinds,
# providers.lib.sh). _ai_tools_conf__list_kind_table is the one place a key is tied to its prefix.

# The longest name a pair list item takes; a name may become a path component, so it is an identifier and bounded.
# shellcheck disable=SC2034  # read by the pair-list callers that use a name as a path component
readonly AI_TOOLS_CONF__PAIR_NAME_MAX=64

# ai_tools_conf__is_pair_name_valid <name> : succeed when <name> is a pair list name -- letters, digits and underscores,
#   1 to AI_TOOLS_CONF__PAIR_NAME_MAX characters, so it does not carry a separator, a dot, a glob or a space.
ai_tools_conf__is_pair_name_valid() {
    [[ "${1-}" =~ ^[A-Za-z0-9_]+$ && ${#1} -le ${AI_TOOLS_CONF__PAIR_NAME_MAX} ]]
}

# The longest portable file name: NAME_MAX, the bound every Linux filesystem holds one directory entry to.
# shellcheck disable=SC2034  # read by the callers that compose a path from a name
readonly AI_TOOLS_CONF__PORTABLE_NAME_MAX=255

# ai_tools_conf__is_portable_name_valid <name> : succeed when <name> is one path component of the POSIX portable
#   filename character set -- letters, digits, `.`, `_` and `-`, 1 to AI_TOOLS_CONF__PORTABLE_NAME_MAX bytes, not
#   opening with `-` and not `.` or `..`, matched in the C locale so a range does not take in letters outside ASCII.
#   The set is the one every filesystem, locale, archive and checksum tool reads back byte for byte: sha256sum prints
#   a name outside it escaped, a whitespace IFS splits one, a filesystem that composes Unicode renames one, a command
#   line reads a leading `-` as an option, and log.lib.sh's sanitizer reduces one for display.
ai_tools_conf__is_portable_name_valid() {
    local LC_ALL=C
    [[ "${1-}" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ && ${#1} -le ${AI_TOOLS_CONF__PORTABLE_NAME_MAX} \
        && "${1-}" != . && "${1-}" != .. ]]
}

# ai_tools_conf__read_pair_list <array-name> <file> <KEY> <value>... : ai_tools_conf__read_list for a key whose items
#   are <name>=<value> pairs, `[nis_enabled=off, deny_ptrace=on]`. Sets the array to the valid items, as written,
#   in order: a name ai_tools_conf__is_pair_name_valid accepts and one of the <value>s, matched exactly. An item that is
#   not one is reported (MSG-F6D7) and left out; a name given again is reported (MSG-R8C6) and its first value kept.
#   An invalid list sets the array empty, as ai_tools_conf__split_list_value does.
#   ai_tools_conf__pair_list_rejected_count is set to the number of items left out, and ai_tools_conf__list_invalid to 1
#   for an invalid list, so a caller for whom a left-out item is not the safe reading can refuse on it. Returns 1,
#   leaving the array untouched, for an absent key, so a caller's defaults stand. Its locals carry a prefix
#   for the reason ai_tools_conf__split's do, until the array's last write; the refused items are reported after it.
ai_tools_conf__read_pair_list() {
    local _ai_tools_conf__pair_list_out_name="$1" _ai_tools_conf__pair_list_file="$2" _ai_tools_conf__pair_list_key="$3" _ai_tools_conf__pair_list_item _ai_tools_conf__pair_list_pair_name _ai_tools_conf__pair_list_pair_value _ai_tools_conf__pair_list_allowed_value _ai_tools_conf__pair_list_value_allowed _ai_tools_conf__pair_list_kept_names=" "
    local _ai_tools_conf__pair_list_allowed_values_text=""
    shift 3
    # Joined by hand: "$*" joins on the caller's IFS, which is a newline under ai-tools.
    for _ai_tools_conf__pair_list_allowed_value in "$@"; do _ai_tools_conf__pair_list_allowed_values_text+="${_ai_tools_conf__pair_list_allowed_values_text:+, }${_ai_tools_conf__pair_list_allowed_value}"; done
    local -a _ai_tools_conf__pair_list_raw=() _ai_tools_conf__pair_list_kept=() _ai_tools_conf__pair_list_refused=() _ai_tools_conf__pair_list_repeated=()
    ai_tools_conf__pair_list_rejected_count=0
    ai_tools_conf__read_list _ai_tools_conf__pair_list_raw "${_ai_tools_conf__pair_list_file}" "${_ai_tools_conf__pair_list_key}" || return 1
    local -n _ai_tools_conf__pair_list_out="${_ai_tools_conf__pair_list_out_name}"
    for _ai_tools_conf__pair_list_item in "${_ai_tools_conf__pair_list_raw[@]+"${_ai_tools_conf__pair_list_raw[@]}"}"; do
        _ai_tools_conf__pair_list_pair_name="${_ai_tools_conf__pair_list_item%%=*}"; _ai_tools_conf__pair_list_pair_value="${_ai_tools_conf__pair_list_item#*=}"; _ai_tools_conf__pair_list_value_allowed=0
        for _ai_tools_conf__pair_list_allowed_value in "$@"; do [[ "${_ai_tools_conf__pair_list_pair_value}" == "${_ai_tools_conf__pair_list_allowed_value}" ]] && _ai_tools_conf__pair_list_value_allowed=1; done
        if [[ "${_ai_tools_conf__pair_list_item}" != *=* ]] || ! ai_tools_conf__is_pair_name_valid "${_ai_tools_conf__pair_list_pair_name}" || (( ! _ai_tools_conf__pair_list_value_allowed )); then
            _ai_tools_conf__pair_list_refused+=("${_ai_tools_conf__pair_list_item}")
            ai_tools_conf__pair_list_rejected_count=$(( ai_tools_conf__pair_list_rejected_count + 1 ))
            continue
        fi
        if [[ "${_ai_tools_conf__pair_list_kept_names}" == *" ${_ai_tools_conf__pair_list_pair_name} "* ]]; then
            _ai_tools_conf__pair_list_repeated+=("${_ai_tools_conf__pair_list_pair_name}")
            ai_tools_conf__pair_list_rejected_count=$(( ai_tools_conf__pair_list_rejected_count + 1 ))
            continue
        fi
        _ai_tools_conf__pair_list_kept_names+="${_ai_tools_conf__pair_list_pair_name} "
        _ai_tools_conf__pair_list_kept+=("${_ai_tools_conf__pair_list_item}")
    done
    _ai_tools_conf__pair_list_out=("${_ai_tools_conf__pair_list_kept[@]+"${_ai_tools_conf__pair_list_kept[@]}"}")
    # Plain names for the messages, declared once the nameref is not written again.
    local key="${_ai_tools_conf__pair_list_key}" file="${_ai_tools_conf__pair_list_file}" item pair_name
    local allowed_values_text="${_ai_tools_conf__pair_list_allowed_values_text}"
    for item in "${_ai_tools_conf__pair_list_refused[@]+"${_ai_tools_conf__pair_list_refused[@]}"}"; do
        ai_tools_conf__warn MSG-F6D7 "the pair list ${key} in ${file} has the item ${item}, which is not <name>=<value> with a value of ${allowed_values_text} -- ignored"
    done
    for pair_name in "${_ai_tools_conf__pair_list_repeated[@]+"${_ai_tools_conf__pair_list_repeated[@]}"}"; do
        ai_tools_conf__warn MSG-R8C6 "the pair list ${key} in ${file} gives ${pair_name} more than once -- the first value stands"
    done
    return 0
}

# _ai_tools_conf__list_kind_table : print "KEY<TAB>prefix" per list key that carries a kind prefix.
_ai_tools_conf__list_kind_table() {
    printf '%s\t%s\n' AI_TOOLS_AGENTS agent- AI_TOOLS_INTEGRATIONS integration- AI_TOOLS_FILTERS filter-
}

# ai_tools_conf__get_kind_prefix <KEY> : print the kind prefix <KEY>'s items carry. Returns 1, printing nothing,
#   for a key outside the table.
ai_tools_conf__get_kind_prefix() {
    local key prefix
    while IFS=$'\t' read -r key prefix; do
        [[ "${key}" == "${1-}" ]] && { printf '%s' "${prefix}"; return 0; }
    done < <(_ai_tools_conf__list_kind_table)
    return 1
}

# _ai_tools_conf__get_bare_name <prefix> <item> : print the bare name when <item> is <prefix> followed by a plain name
#   (the charset a manifest basename takes, no `..`); return 1 otherwise.
_ai_tools_conf__get_bare_name() {
    local prefix="$1" item="$2" bare
    [[ "${item}" == "${prefix}"* ]] || return 1
    bare="${item#"${prefix}"}"
    [[ "${bare}" =~ ^[A-Za-z0-9._-]+$ && "${bare}" != *..* ]] || return 1
    printf '%s' "${bare}"
}

# ai_tools_conf__read_kind_list <array-name> <file> <KEY> : ai_tools_conf__read_list for a key in the kind table,
#   which then requires every item to carry the key's prefix and sets the array to the BARE names, in order. An item
#   that does not makes the whole list invalid: the array is set EMPTY, ai_tools_conf__list_invalid
#   and ai_tools_conf__list_unprefixed are set to 1, and MSG-X6F2 names the key, the items and the command that rewrites
#   them on stderr -- the less-access reading ai_tools_conf__split_list_value gives a malformed list, for the same
#   reason. Returns 1, leaving the array untouched, for an absent key, so a caller's baseline stands; 2 for a key
#   outside the table. Its locals carry a prefix for the reason ai_tools_conf__split's do, until the array's last write.
ai_tools_conf__read_kind_list() {
    local _ai_tools_conf__kind_list_out_name="$1" _ai_tools_conf__kind_list_file="$2" _ai_tools_conf__kind_list_key="$3" _ai_tools_conf__kind_list_prefix _ai_tools_conf__kind_list_item _ai_tools_conf__kind_list_bare_name
    local -a _ai_tools_conf__kind_list_raw=() _ai_tools_conf__kind_list_bare=() _ai_tools_conf__kind_list_unprefixed=()
    ai_tools_conf__list_invalid=0 ai_tools_conf__list_unprefixed=0
    _ai_tools_conf__kind_list_prefix="$(ai_tools_conf__get_kind_prefix "${_ai_tools_conf__kind_list_key}")" || return 2
    ai_tools_conf__read_list _ai_tools_conf__kind_list_raw "${_ai_tools_conf__kind_list_file}" "${_ai_tools_conf__kind_list_key}" || return 1
    local -n _ai_tools_conf__kind_list_out="${_ai_tools_conf__kind_list_out_name}"
    if (( ai_tools_conf__list_invalid )); then
        _ai_tools_conf__kind_list_out=()
        return 0
    fi
    for _ai_tools_conf__kind_list_item in "${_ai_tools_conf__kind_list_raw[@]}"; do
        if _ai_tools_conf__kind_list_bare_name="$(_ai_tools_conf__get_bare_name "${_ai_tools_conf__kind_list_prefix}" "${_ai_tools_conf__kind_list_item}")"; then
            _ai_tools_conf__kind_list_bare+=("${_ai_tools_conf__kind_list_bare_name}")
        else
            _ai_tools_conf__kind_list_unprefixed+=("${_ai_tools_conf__kind_list_item}")
        fi
    done
    if (( ${#_ai_tools_conf__kind_list_unprefixed[@]} > 0 )); then
        _ai_tools_conf__kind_list_out=()
        ai_tools_conf__list_invalid=1
        # shellcheck disable=SC2034  # read by providers.lib.sh
        ai_tools_conf__list_unprefixed=1
        # Plain names for the message, declared once the nameref is not written again.
        local key="${_ai_tools_conf__kind_list_key}" file="${_ai_tools_conf__kind_list_file}" prefix="${_ai_tools_conf__kind_list_prefix}"
        local -a unprefixed=("${_ai_tools_conf__kind_list_unprefixed[@]}")
        ai_tools_conf__warn MSG-X6F2 "invalid list, read as the empty list -- ${key} in ${file} holds ${unprefixed[*]}, not written as ${prefix}<name>; this rewrites a bare name and names any it cannot: atr admin system post-upgrade"
        return 0
    fi
    _ai_tools_conf__kind_list_out=("${_ai_tools_conf__kind_list_bare[@]+"${_ai_tools_conf__kind_list_bare[@]}"}")
    return 0
}

# ai_tools_conf__get_kind_item <KEY> <name> : print <name> as <KEY> holds it -- with the key's prefix added to a bare
#   name, and a name already carrying it printed as given. The writer's side of ai_tools_conf__read_kind_list. Returns
#   1, printing nothing, for a key outside the table or a name that is not a plain name once the prefix is added.
ai_tools_conf__get_kind_item() {
    local key="$1" name="$2" prefix
    prefix="$(ai_tools_conf__get_kind_prefix "${key}")" || return 1
    [[ "${name}" == "${prefix}"* ]] || name="${prefix}${name}"
    _ai_tools_conf__get_bare_name "${prefix}" "${name}" >/dev/null || return 1
    printf '%s' "${name}"
}

# ai_tools_conf__find_unmigrated_items <file> : print "KEY<TAB>item" for every item a key in the kind table holds
#   without that key's prefix, in table order and then list order -- the items that make ai_tools_conf__read_kind_list
#   refuse the list. The one detection predicate: the base package's %post, install.sh, `system post-upgrade --check`
#   and both launch tiers read it. Read-only. A missing or untrusted <file>, an absent key and a list the grammar
#   refuses print nothing, since each already has a report of its own.
ai_tools_conf__find_unmigrated_items() {
    local file="$1" key prefix item
    local -a items=()
    [[ -f "${file}" ]] && ai_tools_conf__is_trusted "${file}" || return 0
    while IFS=$'\t' read -r key prefix; do
        ai_tools_conf__read_list items "${file}" "${key}" 2>/dev/null || continue
        (( ai_tools_conf__list_invalid )) && continue
        for item in "${items[@]+"${items[@]}"}"; do
            _ai_tools_conf__get_bare_name "${prefix}" "${item}" >/dev/null || printf '%s\t%s\n' "${key}" "${item}"
        done
    done < <(_ai_tools_conf__list_kind_table)
    return 0
}

# ── Sidecar files: what an upgrade preserves when it touches an operator's config ────────────
# An install that rewrites a config the operator owns leaves two kinds of copy behind, and they answer different
# questions -- neither substitutes for the other:
#
#   <name>.<YYYYMMDD>-<N>.bak   what the operator HAD. The only thing that restores their
#                               settings if a rewrite is valid but wrong, which no syntax check
#                               catches. Written only when a file is about to change.
#   <name>.<YYYYMMDD>-<N>.shipped  what they were SUPPOSED to get. Written by a from-source install
#                               that keeps a file differing from this version's, and when a merge
#                               could not run, so the hand merge has a source and a later
#                               `system post-upgrade` has the baseline an rpm would have parked
#                               as <name>.rpmnew.
#
# The date stamp makes them survive successive runs: each install adds a copy rather than overwriting the evidence
# of the last. Every copy takes a `-N` counter, starting at 1, so a .bak is never overwritten -- an operator who ran
# the installer twice in a day is exactly the one who needs the first copy -- and the day's copies sort in the order
# they were made.
#
# The two kinds accumulate differently, because they record different things. A .bak records that a run replaced
# the file, so each one is distinct evidence and every rewrite writes one. A .shipped records the baseline that was
# on offer, so ai_tools_conf__ensure_reference reuses an existing copy whose content already matches and dates a new one
# only for a baseline the directory does not hold. A host re-running the installer against an unchanged source tree
# therefore keeps one copy per DIFFERENT baseline it was offered, rather than one per run.
#
# A host meets both baselines when its install routes alternate -- an rpm upgrade over a from-source install leaves
# a .rpmnew beside an older .shipped, and the reverse leaves a newer .shipped beside an older .rpmnew -- so a reader
# that reconciles a kept file takes ONE reference, the newest copy of either kind (ai_tools_conf__find_latest_copy),
# and compares the live file with the baseline that reached the host last. That order is a reading of the clock,
# so a reader asks ai_tools_conf__find_paths_ahead_of_clock first: a file dated after now means the clock is behind,
# and the reader names the clock as the first thing to correct instead of ordering the copies under it.

# ai_tools_conf__find_sidecar_path <path> <kind> : print an UNUSED sidecar path for <path>. Returns 1 without printing
#   when the day's namespace is exhausted, so a caller never silently reuses a name. Pure except for the existence
#   tests. Public because it is the single home of the `<path>.<YYYYMMDD>-<N>.<kind>` convention: managed-assets.lib.sh
#   stamps a replaced shipped asset the same way this file stamps a replaced config, and <path> may be a directory
#   there, while providers.lib.sh stamps a managed file an uninstall moved aside. The kind names the event that produced
#   the copy -- `bak` beside a file a merge replaced, `retired` where the live path is gone -- so a reader tells the two
#   recoveries apart by the name alone.
ai_tools_conf__find_sidecar_path() {
    local file="$1" kind="$2" stamp index taken=0
    stamp="$(date +%Y%m%d)" || return 1
    # The next number is one past the highest the day already holds, so a copy made later never sorts before one made
    # earlier. An unnumbered copy, the name an earlier release gave the day's first, counts as 1.
    [[ -e "${file}.${stamp}.${kind}" ]] && taken=1
    for (( index = 1; index < 100; index++ )); do
        [[ -e "${file}.${stamp}-${index}.${kind}" ]] && taken="${index}"
    done
    (( taken < 99 )) || return 1
    printf '%s' "${file}.${stamp}-$(( taken + 1 )).${kind}"
}

# ai_tools_conf__match_permissions <target> <model> : give <target> the owner and mode of <model>, so a sidecar
#   of a mode-0640 control-plane file is never left more readable than the file it copies. Best-effort: a caller without
#   the privilege to chown still gets the copy.
ai_tools_conf__match_permissions() {
    local target="$1" model="$2" meta
    [[ -e "${model}" ]] || return 0
    meta="$(stat -c '%u:%g %a' "${model}" 2>/dev/null)" || return 0
    chown "${meta%% *}" "${target}" 2>/dev/null || true
    chmod "${meta##* }" "${target}" 2>/dev/null || true
    return 0
}

# ai_tools_conf__write_backup <file> : copy <file> to a fresh dated .bak and print that path. `cp -p` keeps mode,
#   ownership and timestamps, so the copy is a faithful restore point rather than a file the operator has
#   to re-permission. Returns 1 without printing a path when no copy was made.
ai_tools_conf__write_backup() {
    local file="$1" target
    [[ -f "${file}" ]] || return 1
    target="$(ai_tools_conf__find_sidecar_path "${file}" bak)" || return 1
    cp -p "${file}" "${target}" 2>/dev/null || return 1
    printf '%s' "${target}"
}

# ai_tools_conf__ensure_reference <deployed> <shipped> : print the .shipped sidecar beside <deployed> that holds
#   the <shipped> baseline, copying it to a fresh dated path when no existing sidecar matches it byte for byte. The copy
#   takes the DEPLOYED file's owner and mode, not the source tree's. Returns 1 without printing a path when the baseline
#   is absent or the copy fails.
ai_tools_conf__ensure_reference() {
    local deployed="$1" shipped="$2" target existing
    [[ -f "${shipped}" ]] || return 1
    for existing in "${deployed}".*.shipped; do
        [[ -f "${existing}" ]] || continue
        if cmp -s "${existing}" "${shipped}"; then
            printf '%s' "${existing}"
            return 0
        fi
    done
    target="$(ai_tools_conf__find_sidecar_path "${deployed}" shipped)" || return 1
    cp "${shipped}" "${target}" 2>/dev/null || return 1
    ai_tools_conf__match_permissions "${target}" "${deployed}"
    printf '%s' "${target}"
}

# ai_tools_conf__find_latest_copy <deployed> : print the newest baseline beside <deployed> -- the package copy
#   <deployed>.rpmnew or an installer copy <deployed>.<YYYYMMDD>[-N].shipped, whichever was modified last --
#   and succeed; fail without output where neither exists. The package copy wins a tie. Modification time is the one
#   reading both kinds carry: rpm gives a parked copy its package's build time and the installer gives its copy the time
#   it was written, so the copy that reached the host last is the newest, whichever route brought it.
ai_tools_conf__find_latest_copy() {
    local deployed="$1" candidate mtime best="" best_time=-1
    for candidate in "${deployed}.rpmnew" \
            "${deployed}".[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].shipped \
            "${deployed}".[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*.shipped; do
        [[ -f "${candidate}" ]] || continue
        mtime="$(stat -c %Y "${candidate}" 2>/dev/null)" || continue
        if (( mtime > best_time )); then best="${candidate}"; best_time="${mtime}"; fi
    done
    [[ -n "${best}" ]] || return 1
    printf '%s' "${best}"
}

# ai_tools_conf__find_paths_ahead_of_clock <path>... : print "<YYYY-MM-DD HH:MM:SS>\t<path>" for every existing path
#   whose modification time is after the system clock, and fail when there is one; succeed without output otherwise.
#   A file dated after now says the clock is behind -- a host without a battery-backed clock boots into an earlier time
#   and stays there until it reaches a time source -- and every ordering of files by date made under it is wrong,
#   so a caller that orders copies by date, or stamps a new one, asks this first and names the clock as the first thing
#   to correct. Where `date` does not print a clock at all the function succeeds, so an unreadable clock is not reported
#   as behind.
ai_tools_conf__find_paths_ahead_of_clock() {
    local now path mtime when behind=0
    now="$(date +%s 2>/dev/null)" || return 0
    for path in "$@"; do
        [[ -f "${path}" ]] || continue
        mtime="$(stat -c %Y "${path}" 2>/dev/null)" || continue
        (( mtime > now )) || continue
        when="$(date -d "@${mtime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || when="${mtime}"
        printf '%s\t%s\n' "${when}" "${path}"
        behind=1
    done
    (( behind == 0 ))
}

# ── KEY=value files: report new keys, never rewrite ──────────────────────────────────────────
# A KEY=value config is mostly DOCUMENTATION -- commented option blocks explaining each key -- and an operator's copy is
# kept across an upgrade, so a key a new version introduces arrives nowhere. The consequence differs from the JSON case
# and so does the treatment: with the present/absent grammar an absent key already means its default, so what a stale
# file loses is the operator's chance to KNOW the option exists, not the behaviour.
#
# That is why these are reported and never merged. Splicing a commented block into a file whose layout, ordering
# and local annotations are the operator's would rewrite prose for a discoverability gain, and a file that carries
# the launch allowlist or the operator list is the last one to edit unattended. The caller names the new keys and drops
# the shipped baseline beside the file; the operator merges what they want.

# ai_tools_conf__read_keys <array-name> <file> : set the named array to every KEY this file mentions, whether the key is
#   live or written as a commented-out default (`#KEY=` / `# KEY =`). Both forms count as "mentioned", which is
#   the point: a key an operator has deliberately commented out is one they have already seen, so re-announcing it every
#   upgrade would be noise. A comment indented further than one space is prose, not a default, and does not name
#   an option.
ai_tools_conf__read_keys() {
    local -n _ai_tools_conf__keys_out="$1"
    local file="$2" line key
    _ai_tools_conf__keys_out=()
    [[ -r "${file}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"       # strip leading whitespace
        if [[ "${line}" == \#* ]]; then
            line="${line#\#}"                         # a commented default is still a mention
            # ...but only when written hard against the `#` or one space in. A comment indented further is illustrative
            # prose: operator.conf's header documents the grammar with
            # lines like `#   KEY=value`, so counting those would make the minimally seeded file
            # `ai-tools-admin operators add` writes report every documented key as new.
            [[ "${line}" != "  "* ]] || continue
            line="${line#"${line%%[![:space:]]*}"}"
        fi
        [[ "${line}" == *=* ]] || continue
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"          # strip trailing whitespace
        [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        _ai_tools_conf__keys_out+=("${key}")
    done < "${file}"
    return 0
}

# ai_tools_conf__find_new_keys <array-name> <deployed> <shipped> : set the named array to every key the shipped file
#   documents that the deployed one does not mention at all. Returns 1 when there are none, so a caller can stay silent
#   in the common case.
ai_tools_conf__find_new_keys() {
    local -n _ai_tools_conf__new_out="$1"
    local deployed="$2" shipped="$3"
    local -a deployed_keys=() shipped_keys=()
    local key seen seen_key
    _ai_tools_conf__new_out=()
    ai_tools_conf__read_keys shipped_keys "${shipped}" || return 1
    ai_tools_conf__read_keys deployed_keys "${deployed}" || return 1
    for key in "${shipped_keys[@]}"; do
        seen=""
        for seen_key in "${deployed_keys[@]}"; do
            [[ "${seen_key}" == "${key}" ]] && { seen=1; break; }
        done
        [[ -n "${seen}" ]] && continue
        # A shipped file may document a key more than once; announce it once.
        for seen_key in "${_ai_tools_conf__new_out[@]}"; do
            [[ "${seen_key}" == "${key}" ]] && { seen=1; break; }
        done
        [[ -n "${seen}" ]] || _ai_tools_conf__new_out+=("${key}")
    done
    (( ${#_ai_tools_conf__new_out[@]} > 0 ))
}

# ── KEY=value files: set one key in place ────────────────────────────────────────────────────
# The one rewrite this project makes to operator.conf is a single key's value -- the OPERATORS list
# from `atr admin operators add|remove` and the AI_TOOLS_AGENTS list from the toolchain provisioning's agent choice
# (ai_tools_conf__set_list), and the provisioning's switches (ai_tools_conf__set_key). Setting a key replaces one line
# and does not splice a block in, which is what ai_tools_conf__find_new_keys leaves to the operator: the line replaced
# is the key's own -- its last live assignment, the one a reader takes, or where the file has none, the first commented
# default ai_tools_conf__read_keys counts as a mention -- so the template's commented default is rewritten IN PLACE
# under its comment block and the file keeps the shape the new-key report reads. A live line an operator added
# after the commented default is the one replaced, since rewriting the default would leave the later line winning
# the read. Every other line is copied byte for byte.

# ai_tools_conf__set_key <file> <KEY> <value> : write `KEY="value"` into <file>, replacing the line
#   _ai_tools_conf__write_line picks -- the last live `KEY=`, else the first `#KEY=` / `# KEY=` -- or appending the line
#   when none does. A missing <file> is created at mode 0644; an existing one keeps its owner and mode and is replaced
#   by a rename (_ai_tools_conf__replace_file). Verified by re-reading the key through ai_tools_conf__read. Returns 0
#   when the file now holds the value, 1 when it could not be written or does not read back, 2 for a KEY outside
#   the identifier charset or a value carrying a newline or a double quote -- either would end the line or the quoted
#   value early and write a different setting than the one asked for.
ai_tools_conf__set_key() {
    local file="$1" key="$2" value="$3"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [[ "${value}" != *$'\n'* && "${value}" != *'"'* ]] || return 2
    _ai_tools_conf__write_line "${file}" "${key}" "${key}=\"${value}\"" || return 1
    ai_tools_conf__read "${file}" "${key}" && [[ "${ai_tools_conf__value}" == "${value}" ]]
}

# ai_tools_conf__set_list <file> <KEY> [item]... : write `KEY=[a, b]` into <file> (`KEY=[]` for no items), replacing
#   the same line ai_tools_conf__set_key replaces and keeping the file's owner and mode the same way. Verified
#   by reading the list back through ai_tools_conf__read_list. Returns 0 when the file now holds the items in order, 1
#   when it could not be written or does not read back, 2 for a KEY outside the identifier charset or an item that is
#   empty or carries whitespace, a comma, a bracket, a quote or a `#` -- each would split into other items, or end
#   the list, on the read.
ai_tools_conf__set_list() {
    local file="$1" key="$2" item joined=""
    shift 2
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    for item in "$@"; do
        [[ -n "${item}" && "${item}" != *[[:space:],\[\]\"\'#]* ]] || return 2
        joined+="${joined:+, }${item}"
    done
    _ai_tools_conf__write_line "${file}" "${key}" "${key}=[${joined}]" || return 1
    local -a written=()
    ai_tools_conf__read_list written "${file}" "${key}" || return 1
    [[ "${written[*]-}" == "$*" && ${#written[@]} -eq $# ]]
}

# _ai_tools_conf__write_line <file> <KEY> <line> : replace the last live assignment of KEY in <file> (`KEY=`, whitespace
#   allowed around the key) with <line> -- or, where there is none, the first commented default (`#KEY=`, `# KEY=`) --
#   or append <line> when the file mentions neither, copying every other line byte for byte. Publishes
#   which of the three it did in AI_TOOLS_CONF__WRITE_PLACEMENT (`live`, `commented`, `appended`), so a caller tells
#   a file carrying the key's documented slot from one that predates it. A missing <file> is created at mode 0644;
#   an existing one keeps its owner and mode and is replaced by a rename (_ai_tools_conf__replace_file). Returns 1
#   when the file could not be written. The one line replacement both public writers share, so they rewrite the same
#   line of the same file.
_ai_tools_conf__write_line() {
    local file="$1" key="$2" new_line="$3" tmp line number=0 live=0 commented=0 target
    if [[ -f "${file}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            number=$(( number + 1 ))
            if [[ "${line}" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
                live="${number}"
            elif (( ! commented )) && [[ "${line}" =~ ^[[:space:]]*\#[[:space:]]?${key}[[:space:]]*= ]]; then
                commented="${number}"
            fi
        done < "${file}"
    fi
    target="${live}"
    (( target )) || target="${commented}"
    # shellcheck disable=SC2034  # read by the callers of the two public writers (ai-tools-admin's assets verbs)
    if (( live )); then AI_TOOLS_CONF__WRITE_PLACEMENT=live
    elif (( commented )); then AI_TOOLS_CONF__WRITE_PLACEMENT=commented
    else AI_TOOLS_CONF__WRITE_PLACEMENT=appended
    fi
    tmp="$(mktemp 2>/dev/null)" || return 1
    if [[ -f "${file}" ]]; then
        number=0
        while IFS= read -r line || [[ -n "${line}" ]]; do
            number=$(( number + 1 ))
            if (( number == target )); then printf '%s\n' "${new_line}"; else printf '%s\n' "${line}"; fi
        done < "${file}" > "${tmp}"
    fi
    (( target )) || printf '%s\n' "${new_line}" >> "${tmp}"
    if [[ -f "${file}" ]]; then
        if ! _ai_tools_conf__replace_file "${file}" "${tmp}"; then rm -f -- "${tmp}"; return 1; fi
    elif ! install -m 644 -- "${tmp}" "${file}" 2>/dev/null; then
        rm -f -- "${tmp}"; return 1
    fi
    rm -f -- "${tmp}"
}

# ── The project registry: ~/.config/ai-tools/project-registry, and the legacy allowed-projects ───────
# The registry is one path per line rather than KEY=value, read with the same rules as every other file here:
# a whole-line or end-of-line `#` comment, and one matched quote layer for a path that carries a space or a literal `#`.
# Every reader of the file (the launch wrapper, the CLI, the owner resolver, and each root helper that walks or labels
# a project; providers.rule.md names them) parses it here, so a line denotes one thing to all of them. A line's kind is
# its first character, written before any quote:
#
#   # ai-tools-project-registry-format: 1.0   the format marker, written as line 1
#   /home/op/project                  a project: it and its contents
#   /home/op/project   # why          an end-of-line comment: `#` after whitespace ends the entry
#   "/home/op/ai works"               quotes carry a space, and make `#` inside them literal
#   !/home/op/project/vendor          a carve-out, which may be a glob: !/home/op/*/node_modules
#   %/home/op/parked                  a parked project
#
# The registry is ~/.config/ai-tools/project-registry. A host upgraded from a release that wrote
# ~/.config/ai-tools/allowed-projects keeps reading that file while it is present under that name, under the legacy
# grammar -- allow and `!` lines, no marker -- until `atr admin system post-upgrade` writes
# `~/.config/ai-tools/project-registry` from it and renames it to a dated `.bak`. ai_tools_conf__resolve_registry
# decides which file a reader opens.
#
# A line the grammar does not recognise refuses the WHOLE file for every reader (ai_tools_conf__validate_registry):
# a reader that skipped it would read the rest of the file as the operator's intent, and a mistyped carve-out would then
# allow the subtree it was written to withhold. A refused file does not allow or cover any path, which is the direction
# every reader of this file fails in. A relative path is one such line: resolved against the reader's working directory,
# it named a different directory for each reader. Text after a closing quote, other than a comment, is another:
# the parser drops it, so `!"/home/op/p/private"x` would read as a carve-out of a path the operator did not write.
# A control byte in a path is a third: the classifier's record is tab-separated, so a tab in a path would shift
# the fields a verb decides from.

readonly AI_TOOLS_CONF__REGISTRY_FORMAT=1.0

# ai_tools_conf__get_registry_marker : print the format marker line (no newline) that the seed and the migration write
#   as line 1 of `~/.config/ai-tools/project-registry`.
ai_tools_conf__get_registry_marker() { printf '# ai-tools-project-registry-format: %s' "${AI_TOOLS_CONF__REGISTRY_FORMAT}"; }

# _ai_tools_conf__parse_registry_marker <line> : return 0 with ai_tools_conf__value set to `<major>.<minor>` when <line>
#   is a format marker -- a whole-line comment from column 0, the key fixed, one space after the colon, two decimal
#   integers -- and return 1 for any other line.
_ai_tools_conf__parse_registry_marker() {
    [[ "${1-}" =~ ^'# ai-tools-project-registry-format: '([0-9]+)'.'([0-9]+)$ ]] || return 1
    ai_tools_conf__value="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
}

# ai_tools_conf__read_registry_format <file> : print the version the first format marker in <file> names (`1.0`),
#   or `legacy` when <file> does not carry one. Returns 1 without printing for a file that is not a readable regular
#   file.
ai_tools_conf__read_registry_format() {
    local file="$1" line
    [[ -f "${file}" && -r "${file}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if _ai_tools_conf__parse_registry_marker "${line}"; then
            printf '%s' "${ai_tools_conf__value}"
            return 0
        fi
    done < "${file}"
    printf 'legacy'
}

# ai_tools_conf__read_registry_grammar <file> [<read-path>] : print the grammar <file> is read under, `legacy`
#   or `current`. The name decides for the two registry names, so a `~/.config/ai-tools/project-registry` without
#   a marker is refused as one and an `allowed-projects` carrying a marker is refused as a marker in a legacy file.
#   The file AI_TOOLS_ALLOWLIST names, and a file of any other name, take the grammar their content states, read from
#   <read-path> (default <file>): a marker makes it `current`.
ai_tools_conf__read_registry_grammar() {
    local file="$1" read_path="${2:-$1}" format
    if [[ "${file}" != "${AI_TOOLS_ALLOWLIST:-}" ]]; then
        case "${file##*/}" in
            allowed-projects) printf 'legacy'; return 0 ;;
            project-registry) printf 'current'; return 0 ;;
        esac
    fi
    format="$(ai_tools_conf__read_registry_format "${read_path}" 2>/dev/null)" || format=legacy
    if [[ "${format}" == legacy ]]; then printf 'legacy'; else printf 'current'; fi
}

# ai_tools_conf__read_registry_state <file> : print `none` when no entry of that name exists, and otherwise the grammar
#   ai_tools_conf__read_registry_grammar reads it under. The state of a file named directly, the AI_TOOLS_ALLOWLIST test
#   hook and a `--for` snapshot among them.
ai_tools_conf__read_registry_state() {
    if [[ -e "$1" || -L "$1" ]]; then ai_tools_conf__read_registry_grammar "$1"; else printf 'none'; fi
}

# ai_tools_conf__resolve_registry <config-dir> : print `<state>\t<path>\n` for the registry an operator's config
#   directory holds: `legacy` and the path of `allowed-projects` while an entry of that name exists, whether or not
#   `~/.config/ai-tools/project-registry` is beside it, since the migration renames the old file only once that file is
#   verified; else `current` and the path of `~/.config/ai-tools/project-registry` where it exists; else `none`
#   and the path it would take. A `.bak` copy is not an active name. It does not read AI_TOOLS_ALLOWLIST: the hook moves
#   the primary operator's file alone, so a caller that honours it reads that file
#   through ai_tools_conf__read_registry_state.
ai_tools_conf__resolve_registry() {
    local dir="${1%/}"
    if [[ -e "${dir}/allowed-projects" || -L "${dir}/allowed-projects" ]]; then
        printf 'legacy\t%s\n' "${dir}/allowed-projects"
    elif [[ -e "${dir}/project-registry" || -L "${dir}/project-registry" ]]; then
        printf 'current\t%s\n' "${dir}/project-registry"
    else
        printf 'none\t%s\n' "${dir}/project-registry"
    fi
}

# ai_tools_conf__parse_path_entry <line> : set ai_tools_conf__value to the entry <line> denotes and return 0; return 1
#   for a line that does not carry an entry (blank, or a whole-line comment), which is the caller's signal to skip it.
#   A leading `!` or `%` is preserved on the result, so a carve-out and a park stay distinguishable after the quotes are
#   stripped. It decides what text a line denotes and does not validate it; ai_tools_conf__validate_registry does.
ai_tools_conf__parse_path_entry() {
    local line="${1-}" kind=""
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "${line}" || "${line}" == '#'* ]] && { ai_tools_conf__value=""; return 1; }
    if [[ "${line}" == '!'* || "${line}" == '%'* ]]; then
        kind="${line:0:1}"
        line="${line:1}"
        line="${line#"${line%%[![:space:]]*}"}"
    fi
    _ai_tools_conf__parse_value "${line}"
    [[ -n "${ai_tools_conf__value}" ]] || return 1
    ai_tools_conf__value="${kind}${ai_tools_conf__value}"
    return 0
}

# _ai_tools_conf__classify_registry_line <line> <legacy|current> : set _ai_tools_conf__line_kind to the kind <line>
#   carries -- `none` (blank or a comment), `marker`, `allow`, `carve` or `park` -- and _ai_tools_conf__line_fault
#   to the reason token the grammar refuses it with, or empty. A marker's version is in ai_tools_conf__value. Results
#   travel in globals, so the validator reads them without a subshell per line.
_ai_tools_conf__classify_registry_line() {
    local line="${1-}" grammar="$2" rest quote tail
    _ai_tools_conf__line_kind=none; _ai_tools_conf__line_fault=""; ai_tools_conf__value=""
    if _ai_tools_conf__parse_registry_marker "${line}"; then
        _ai_tools_conf__line_kind=marker
        if [[ "${grammar}" == legacy ]]; then
            _ai_tools_conf__line_fault=marker-in-legacy
        elif [[ ! "${ai_tools_conf__value%%.*}" =~ ^0*1$ ]]; then
            _ai_tools_conf__line_fault=marker-unsupported
        fi
        return 0
    fi
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "${line}" || "${line}" == '#'* ]] && return 0
    rest="${line}"
    case "${line:0:1}" in
        '!')            _ai_tools_conf__line_kind=carve ;;
        '%')            _ai_tools_conf__line_kind=park ;;
        /|'"'|"'")      _ai_tools_conf__line_kind=allow ;;
        *)              _ai_tools_conf__line_fault=unknown-form; return 0 ;;
    esac
    if [[ "${_ai_tools_conf__line_kind}" == park && "${grammar}" == legacy ]]; then
        _ai_tools_conf__line_fault=park-in-legacy; return 0
    fi
    if [[ "${_ai_tools_conf__line_kind}" != allow ]]; then
        rest="${rest:1}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
    fi
    case "${rest:0:1}" in
        '"'|"'") quote="${rest:0:1}" ;;
        *)       quote="" ;;
    esac
    if [[ -n "${quote}" && "${rest:1}" != *"${quote}"* ]]; then
        _ai_tools_conf__line_fault=unmatched-quote; return 0
    fi
    if [[ -n "${quote}" ]]; then
        tail="${rest:1}"; tail="${tail#*"${quote}"}"
        tail="${tail#"${tail%%[![:space:]]*}"}"
        if [[ -n "${tail}" && "${tail}" != '#'* ]]; then
            _ai_tools_conf__line_fault=text-after-quote; return 0
        fi
    fi
    _ai_tools_conf__parse_value "${rest}"
    if [[ -z "${ai_tools_conf__value}" ]]; then
        _ai_tools_conf__line_fault=empty-entry
    elif [[ "${ai_tools_conf__value}" == *[[:cntrl:]]* ]]; then
        _ai_tools_conf__line_fault=control-character
    elif [[ "${ai_tools_conf__value}" != /* ]]; then
        _ai_tools_conf__line_fault=relative-path
    elif ai_tools_conf__has_glob_characters "${ai_tools_conf__value}"; then
        case "${_ai_tools_conf__line_kind}" in
            allow) _ai_tools_conf__line_fault=glob-on-allow ;;
            park)  _ai_tools_conf__line_fault=glob-on-park ;;
        esac
    fi
    return 0
}

# _ai_tools_conf__format_registry_fault_remedy <reason> : print what the operator writes instead of a line refused for
#   <reason>.
_ai_tools_conf__format_registry_fault_remedy() {
    case "$1" in
        unknown-form)       printf "a line is a project (/path), a carve-out (!/path), a park (%%/path) or a # comment" ;;
        relative-path)      printf 'write the absolute path' ;;
        empty-entry)        printf "write the path after the '!' or the '%%', or delete the line" ;;
        unmatched-quote)    printf 'close the quote' ;;
        text-after-quote)   printf 'end the line at the closing quote, or start a # comment after it' ;;
        control-character)  printf 'write the path without the control character, renaming the directory if its name carries one' ;;
        glob-on-allow)      printf "a glob is a carve-out alone (!/path/*); list each project by its path" ;;
        glob-on-park)       printf "a park names one project by its path; a glob is a carve-out alone (!/path/*)" ;;
        park-in-legacy)     printf "allowed-projects is read under the grammar it was written in, which has no '%%' line; write it as '!' again, then run atr admin system post-upgrade to migrate the file" ;;
        marker-in-legacy)   printf 'the format marker belongs in ~/.config/ai-tools/project-registry; delete the line, then run atr admin system post-upgrade to migrate the file' ;;
        marker-repeated)    printf 'delete the second marker' ;;
        marker-unsupported) printf 'this release reads format 1 alone; the file was written by a later release' ;;
        marker-missing)     printf 'write %s as the first line' "$(ai_tools_conf__get_registry_marker)" ;;
    esac
}

# ai_tools_conf__validate_registry <file> <legacy|current> [<read-path>] : read the whole of <file> under the grammar
#   named, and return 0 when every line is one it recognises. Both passes read <read-path> (default <file>), a reader's
#   pinned descriptor, while every message names <file>. Return 3 at the first line it refuses -- MSG-B8U2 on stderr
#   naming the file, the line number, the reason token, the line (control bytes shown as `?`) and the remedy --
#   or, for a `current` file carrying no marker, with the reason `marker-missing`. Return 1 for a file that is not
#   a readable regular file. The reasons are the line forms of the section comment turned around: unknown-form,
#   relative-path, empty-entry, unmatched-quote, text-after-quote, control-character, glob-on-allow, glob-on-park,
#   park-in-legacy, marker-in-legacy, marker-repeated and marker-unsupported. A minor version this release does not know
#   is read, since each line is validated on its own. A NUL byte refuses the file as `control-character` on any line,
#   a comment included: `read` drops the byte, so the loop would read `/a<NUL>b` as `/ab`, and a pre-pass that turns
#   each NUL into \x01 (and each \x01 into \x02, so the match names an original NUL alone) finds it first. The pre-pass
#   reads the whole file, `cat` draining what `grep -m1` leaves, because a writer closed early takes SIGPIPE and turns
#   a found byte into a failed pipeline under `pipefail`; it reads the status of `tr` and of the matcher apart, and
#   a scan that did not complete returns 1 with MSG-C6P5 on stderr, the status of a file that cannot be read.
ai_tools_conf__validate_registry() {
    local file="$1" grammar="$2" read_path="${3:-$1}" line number=0 markers=0 fault="" shown="" nul_line nul_scan
    local nul_status
    [[ -f "${read_path}" && -r "${read_path}" ]] || return 1
    nul_scan="$(set +e
        LC_ALL=C tr '\000\001' '\001\002' < "${read_path}" \
            | { LC_ALL=C grep -a -n -m1 $'\x01'; match_status=$?; cat >/dev/null || match_status=2
                exit "${match_status}"; }
        printf '%s %s' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}")"
    nul_status="${nul_scan##*$'\n'}"
    case "${nul_status}" in
        '0 0')
            nul_line="${nul_scan%$'\n'*}"
            fault=control-character; number="${nul_line%%:*}"
            nul_line="${nul_line#*:}"; shown=": ${nul_line//[[:cntrl:]]/?}" ;;
        '0 1') ;;
        *)
            ai_tools_conf__warn MSG-C6P5 "registry scan incomplete -- ${file}: the control-byte scan exited with statuses ${nul_status:-unknown} (tr, grep); no entry in this file allows a path until it can be read"
            return 1 ;;
    esac
    while [[ -z "${fault}" ]] && { IFS= read -r line || [[ -n "${line}" ]]; }; do
        number=$(( number + 1 ))
        _ai_tools_conf__classify_registry_line "${line}" "${grammar}"
        fault="${_ai_tools_conf__line_fault}"
        if [[ -z "${fault}" && "${_ai_tools_conf__line_kind}" == marker ]]; then
            markers=$(( markers + 1 ))
            (( markers == 1 )) || fault=marker-repeated
        fi
        if [[ -n "${fault}" ]]; then
            shown=": ${line//[[:cntrl:]]/?}"
        fi
    done < "${read_path}"
    if [[ -z "${fault}" && "${grammar}" == current ]] && (( markers == 0 )); then
        fault=marker-missing; number=1
    fi
    [[ -n "${fault}" ]] || return 0
    ai_tools_conf__warn MSG-B8U2 "registry line refused -- ${file} line ${number}: ${fault}${shown} -- $(_ai_tools_conf__format_registry_fault_remedy "${fault}"); no entry in this file allows a path until the line is fixed"
    return 3
}

# _ai_tools_conf__is_registry_valid <file> [<read-path>] : return 0 when <file> is a readable regular file that passes
#   ai_tools_conf__validate_registry under the grammar its name or content selects, the content read from <read-path>
#   (default <file>); a refusal is on stderr.
_ai_tools_conf__is_registry_valid() {
    local read_path="${2:-$1}"
    [[ -f "${read_path}" ]] || return 1
    ai_tools_conf__validate_registry "$1" "$(ai_tools_conf__read_registry_grammar "$1" "${read_path}")" "${read_path}"
}

# _ai_tools_conf__open_registry <file> : open <file> once and return 0 with _ai_tools_conf__registry_fd set
#   to the descriptor and _ai_tools_conf__registry_owner_uid to the owner of the inode it holds. The caller reads
#   /proc/self/fd/<fd> for every pass, so the validation and the entries are read from one inode however the name is
#   replaced in between, and closes the descriptor on each return. Return 1, with no descriptor left open, for a path
#   that is not a readable regular file or an owner `stat` does not return. The name is tested before the open,
#   since an open of a FIFO blocks until a writer appears.
_ai_tools_conf__open_registry() {
    local file="$1" registry_fd
    _ai_tools_conf__registry_fd=""; _ai_tools_conf__registry_owner_uid=""
    [[ -f "${file}" && -r "${file}" ]] || return 1
    { exec {registry_fd}< "${file}"; } 2>/dev/null || return 1
    # `stat -L` reads the inode the descriptor holds; without `-L` it reads the /proc link, which the reading process
    # owns.
    if [[ ! -f "/proc/self/fd/${registry_fd}" ]] \
            || ! _ai_tools_conf__registry_owner_uid="$(stat -L -c '%u' -- "/proc/self/fd/${registry_fd}" 2>/dev/null)"; then
        exec {registry_fd}<&-
        _ai_tools_conf__registry_owner_uid=""
        return 1
    fi
    _ai_tools_conf__registry_fd="${registry_fd}"
}

# ── Registry loading and exclusion matching (the gate's own read) ────────────────────────────
# The launch gate and each root helper that walks a project read the whole file into an allow array and an exclusion
# array and match a path against them; this is the one implementation of that read and that match, so the gate
# that refuses a launch and the walk that hands a path back cover one set of paths (providers.rule.md, ref-section-d2n3,
# states which readers and what each does with a refused read). The read validates the file first, so a refused file
# yields both arrays empty. It opens the file once (_ai_tools_conf__open_registry), as the membership readers
# and the classifier do, and validates and loads from that one inode, so a file renamed over the name in between is not
# read; what the pin does not close is a write into the same inode, which only the operator or root can make, since
# the file is the operator's at 0600 in a 0700 directory (layout.rule.md's boundary rows), and which no writer of this
# project makes, since each writes beside the file and renames. An allow entry is kept resolved
# (`realpath -e`) and dropped when it does not resolve, so a symlinked spelling or a trailing slash names the directory.
# An exclusion -- a carve-out or a park, which the gate treats alike -- is kept AS WRITTEN and, for a line without
# a glob character, its resolved form beside it, so the match is the UNION of the written and the resolved form:
# a reader matching the resolved form alone stops covering the written path the moment a component of it becomes
# a symlink, and one matching the written form alone misses an exclusion the operator spelled through one.
#
# The resolution follows a symlink only where the sandbox account can neither remove, replace nor move it: the link
# and every directory on the way to it are held by root or the file's owner, and no directory on the way has a group
# or other write bit without the sticky bit, since write on one lets the account rename the link's own directory aside.
# Any other link REFUSES THE WHOLE READ (return 2, both arrays empty, MSG-Y5N6 naming the link and the real path
# to write). The sandbox account is a group-writer on every project tree, so a link there is its to change: resolved
# through such a link, the exclusion would cover whatever the account aimed it at; left as written alone, it would stop
# covering the real path the operator's own link named the moment the account unlinks the link or puts a directory
# of its name in its place -- `alias -> private` gone, `private` is allowed again under the enclosing entry. Neither
# reading is safe, so no entry in the file allows a path until the entry is written as the real path. A link `readlink`
# does not return, and a chain past 40 links, refuse the same way. A glob stays as written, since realpath would read
# its metacharacters as a name. Every outcome of the read keeps or adds an exclusion, or withdraws every allow --
# the direction every registry read fails in. What no spelling closes is a rename of the real directory itself inside
# a tree the account co-writes: an exclusion names a path, and the owner-only mode on the directory is what keeps its
# contents from the account (secret-handling.rule.md).

# ai_tools_conf__has_glob_characters <path> : return 0 when <path> carries a glob character (`*`, `?` or `[`); such
#   an exclusion is matched as a pattern on the whole path and is never resolved.
ai_tools_conf__has_glob_characters() { [[ "${1-}" == *[*?[]* ]]; }

# _ai_tools_conf__resolve_exclusion_path <abs-path> <uid> : set ai_tools_conf__value to <abs-path> with every symlink
#   on the way followed and `.`/`..` collapsed, as realpath -m does, and return 0 when each symlink met is owned
#   by <uid> or by root and every directory on the way to it is held by <uid> or root with no group or other write bit
#   unless the sticky bit is set (the reads that make the link one the sandbox account cannot remove, replace or move
#   aside). Return 1 for a relative path, and -- with _ai_tools_conf__resolve_refusal set to the reason, naming the link
#   -- for a symlink or a directory on the way to it held by any other account, such a directory with a group or other
#   write bit and no sticky bit, a link `stat` or `readlink` does not return, more than 40 links (a loop), or
#   a directory on the way that the calling process cannot search. A component that does not exist is kept as written.
#   Root searches every directory, so for a path crossing a directory its operator cannot enter, root's report reads
#   the file as standing where that operator's gate refuses it: the report under-reports a refusal. Results travel
#   in globals rather than on stdout, so the caller reads them without a subshell.
_ai_tools_conf__resolve_exclusion_path() {
    local remaining_path="${1-}" allowlist_owner_uid="${2-}" resolved_path="" component link symlink_target
    local symlink_owner_uid symlink_count=0 ancestor_directory ancestor_owner_uid ancestor_mode checked_directories=""
    ai_tools_conf__value=""; _ai_tools_conf__resolve_refusal=""
    [[ "${remaining_path}" == /* && -n "${allowlist_owner_uid}" ]] || return 1
    remaining_path="${remaining_path#/}"
    while [[ -n "${remaining_path}" ]]; do
        component="${remaining_path%%/*}"
        remaining_path="${remaining_path#"${component}"}"; remaining_path="${remaining_path#/}"
        case "${component}" in
            ''|.) continue ;;
            ..)   resolved_path="${resolved_path%/*}"; continue ;;
        esac
        link="${resolved_path}/${component}"
        # Under a directory the reader cannot search, `[[ -L ]]` is false for a link and for an absent name alike,
        # so the read refuses rather than keep the component as written. A directory that does not exist does not hide
        # a link from any reader, and its components stay as written.
        if [[ -d "${resolved_path:-/}" && ! -x "${resolved_path:-/}" ]]; then
            _ai_tools_conf__resolve_refusal="${resolved_path:-/} is a directory uid ${EUID} cannot search, so whether ${link} is a symbolic link cannot be read"; return 1
        fi
        if [[ -L "${link}" ]]; then
            symlink_count=$(( symlink_count + 1 ))
            if (( symlink_count > 40 )); then
                _ai_tools_conf__resolve_refusal="more than 40 symbolic links are met on the way (a loop) at ${link}"; return 1
            fi
            if ! symlink_owner_uid="$(stat -c '%u' -- "${link}" 2>/dev/null)"; then
                _ai_tools_conf__resolve_refusal="${link} is a symbolic link whose owner cannot be read"; return 1
            fi
            if [[ "${symlink_owner_uid}" != "${allowlist_owner_uid}" && "${symlink_owner_uid}" != 0 ]]; then
                _ai_tools_conf__resolve_refusal="${link} is a symbolic link held by uid ${symlink_owner_uid}, not by the file's owner (uid ${allowlist_owner_uid}) or root"; return 1
            fi
            # Every directory on the way to the link, the holding one included, and each read once per call: write
            # on any of them lets the sandbox account rename the link's own directory aside, after which the written
            # path no longer exists while the real directory stays where it was. A sticky directory (/tmp) is accepted
            # with its write bits, since there the kernel lets only an entry's owner rename or unlink it, and every
            # entry on the way is held by the file's owner or root. IFS is pinned for the read: the launch wrapper
            # sources this library under IFS=$'\n\t', where the two space-separated fields would land in the uid
            # variable together and the owner comparison refuse every link.
            ancestor_directory="${resolved_path:-/}"
            while :; do
                if [[ " ${checked_directories} " != *" ${ancestor_directory} "* ]]; then
                    if ! IFS=' ' read -r ancestor_owner_uid ancestor_mode \
                            < <(stat -c '%u %a' -- "${ancestor_directory}" 2>/dev/null); then
                        _ai_tools_conf__resolve_refusal="${link} is a symbolic link under ${ancestor_directory}, whose owner and mode cannot be read"; return 1
                    fi
                    if [[ "${ancestor_owner_uid}" != "${allowlist_owner_uid}" && "${ancestor_owner_uid}" != 0 ]]; then
                        _ai_tools_conf__resolve_refusal="${link} is a symbolic link under ${ancestor_directory}, a directory held by uid ${ancestor_owner_uid}, not by the file's owner (uid ${allowlist_owner_uid}) or root"; return 1
                    fi
                    if (( 8#${ancestor_mode} & 8#022 )) && ! (( 8#${ancestor_mode} & 8#1000 )); then
                        _ai_tools_conf__resolve_refusal="${link} is a symbolic link under ${ancestor_directory}, a directory with a group or other write bit and no sticky bit (mode ${ancestor_mode}), so an account other than its owner can move the link or a directory above it"; return 1
                    fi
                    checked_directories+=" ${ancestor_directory}"
                fi
                [[ "${ancestor_directory}" == / ]] && break
                ancestor_directory="${ancestor_directory%/*}"; ancestor_directory="${ancestor_directory:-/}"
            done
            if ! symlink_target="$(readlink -- "${link}" 2>/dev/null)" || [[ -z "${symlink_target}" ]]; then
                _ai_tools_conf__resolve_refusal="${link} is a symbolic link that cannot be read"; return 1
            fi
            if [[ "${symlink_target}" == /* ]]; then resolved_path=""; symlink_target="${symlink_target#/}"; fi
            remaining_path="${symlink_target}${remaining_path:+/${remaining_path}}"
            continue
        fi
        resolved_path="${link}"
    done
    ai_tools_conf__value="${resolved_path:-/}"
}

# ai_tools_conf__load_allowlist <registry-file> <allowed-array> <excluded-array> [<kinds-array>] : fill the named arrays
#   from <registry-file> as the section comment states -- allow entries resolved; exclusions as written, plus
#   the resolved form of a glob-free one whose symlinks the sandbox account can neither remove nor replace -- and return
#   0. <kinds-array>, when named, is filled parallel to <excluded-array> with `carve` or `park` per element, so a caller
#   words a refusal from the line that matched. Every array is empty on a non-zero return: 1 when <registry-file> is
#   missing, is a directory or another non-regular file, cannot be read, or has no readable owner; 3
#   when ai_tools_conf__validate_registry refuses a line (MSG-B8U2 on stderr); 2, with MSG-Y5N6 on stderr naming
#   the entry and the link, when a glob-free exclusion meets a symlink _ai_tools_conf__resolve_exclusion_path refuses.
ai_tools_conf__load_allowlist() {
    local -a _ai_tools_conf__load_no_kinds=()
    local -n _ai_tools_conf__load_allowed="$2" _ai_tools_conf__load_excluded="$3"
    local -n _ai_tools_conf__load_kinds="${4:-_ai_tools_conf__load_no_kinds}"
    local file="${1-}" load_fd read_path allowlist_owner_uid line entry resolved kind written status=0
    _ai_tools_conf__load_allowed=(); _ai_tools_conf__load_excluded=(); _ai_tools_conf__load_kinds=()
    _ai_tools_conf__open_registry "${file}" || return 1
    load_fd="${_ai_tools_conf__registry_fd}"; allowlist_owner_uid="${_ai_tools_conf__registry_owner_uid}"
    read_path="/proc/self/fd/${load_fd}"
    _ai_tools_conf__is_registry_valid "${file}" "${read_path}" || status=$?
    while (( status == 0 )) && { IFS= read -r line || [[ -n "${line}" ]]; }; do
        ai_tools_conf__parse_path_entry "${line}" || continue
        entry="${ai_tools_conf__value}"
        case "${entry}" in
            '!'*) kind=carve ;;
            '%'*) kind=park ;;
            *)
                resolved="$(realpath -e -- "${entry}" 2>/dev/null)" || continue
                _ai_tools_conf__load_allowed+=("${resolved}")
                continue ;;
        esac
        entry="${entry:1}"
        _ai_tools_conf__load_excluded+=("${entry}"); _ai_tools_conf__load_kinds+=("${kind}")
        ai_tools_conf__has_glob_characters "${entry}" && continue
        if ! _ai_tools_conf__resolve_exclusion_path "${entry}" "${allowlist_owner_uid}"; then
            written="${line#"${line%%[![:space:]]*}"}"
            ai_tools_conf__warn MSG-Y5N6 "exclusion ${written} in ${file} cannot be resolved -- ${_ai_tools_conf__resolve_refusal}; write the exclusion as the directory's real path, since a link the sandbox account can change cannot be followed; no entry in this file allows a path until the line is fixed"
            status=2
            continue
        fi
        resolved="${ai_tools_conf__value}"
        if [[ "${resolved}" != "${entry%/}" ]]; then
            _ai_tools_conf__load_excluded+=("${resolved}"); _ai_tools_conf__load_kinds+=("${kind}")
        fi
    done < "${read_path}"
    exec {load_fd}<&-
    if (( status != 0 )); then
        _ai_tools_conf__load_allowed=(); _ai_tools_conf__load_excluded=(); _ai_tools_conf__load_kinds=()
    fi
    return "${status}"
}

# ai_tools_conf__check_registry <registry-file> : read <registry-file> as the launch gate does, through
#   ai_tools_conf__load_allowlist, and return its status (0, 1, 2 or 3), the refusal on stderr. For a report that states
#   whether a registry would stand at the gate and does not keep the entries: a grammar check alone passes a file whose
#   exclusion crosses a link the gate refuses. The read runs as the caller, so a root caller passes a file whose
#   exclusion crosses a directory the registry's operator cannot search, which that operator's gate refuses.
ai_tools_conf__check_registry() {
    # shellcheck disable=SC2034  # filled through their names by the loader, and not read
    local -a _ai_tools_conf__check_allowed=() _ai_tools_conf__check_excluded=()
    ai_tools_conf__load_allowlist "${1-}" _ai_tools_conf__check_allowed _ai_tools_conf__check_excluded
}

# ai_tools_conf__is_path_excluded <abs-path> <excluded-array> : return 0 when an entry of the named array covers
#   <abs-path>: equal to it, with a glob matched as a pattern against the whole path, or, for an entry without `*`,
#   an ancestor of it; a trailing slash on an entry is ignored. Return 1 otherwise, and for an empty array.
ai_tools_conf__is_path_excluded() {
    local -n _ai_tools_conf__match_excluded="$2"
    local path="${1-}" pat
    (( ${#_ai_tools_conf__match_excluded[@]} )) || return 1
    for pat in "${_ai_tools_conf__match_excluded[@]}"; do
        pat="${pat%/}"
        [[ "${path}" == ${pat} ]] && return 0
        if [[ "${pat}" != *'*'* && "${path}" == "${pat}/"* ]]; then return 0; fi
    done
    return 1
}

# ── Registry membership (exact-entry matching) ───────────────────────────────────────────────
# One predicate for "which lines of the registry name this path", shared by every component that asks: the launch
# wrapper's post-claim confirm, the CLI, the `--for` helper and the relabel helper. Each line is read
# through the grammar,
# so an entry written with an end-of-line comment (`/p   # why`), quotes (`"/p with space"`), or a spelling reached
# by a symlink or a trailing slash is a MATCH, where a raw `grep -qxF` against the stored line would miss it. Comparison
# is on realpath-normalized values, the same canonicalization the launch gate applies, so the confirm and the gate
# agree. A stored entry that no longer resolves cannot equal an existing target. Callers pass an existing path (a
# realpath'd project dir); membership of a path that does not exist is not asserted. A file the grammar refuses does not
# name any path.

# _ai_tools_conf__normalize_allowlist_path <path> : print <path> realpath-normalized, or <path> itself when it does not
#   resolve, so the membership readers canonicalize target and entry identically.
_ai_tools_conf__normalize_allowlist_path() { realpath -e "$1" 2>/dev/null || printf '%s' "$1"; }

# _ai_tools_conf__read_lines_naming <file> <path> <allow-array> <carve-array> <park-array> : set the three named arrays
#   to the RAW lines of <file> whose entry names <path>, one array per line kind, in one read. Every array is empty,
#   and the status 1, when <file> is missing or the grammar refuses it (the refusal on stderr).
_ai_tools_conf__read_lines_naming() {
    local -n _ai_tools_conf__naming_allow="$3" _ai_tools_conf__naming_carve="$4" _ai_tools_conf__naming_park="$5"
    local file="$1" want line entry naming_fd read_path
    _ai_tools_conf__naming_allow=(); _ai_tools_conf__naming_carve=(); _ai_tools_conf__naming_park=()
    _ai_tools_conf__open_registry "${file}" || return 1
    naming_fd="${_ai_tools_conf__registry_fd}"; read_path="/proc/self/fd/${naming_fd}"
    if ! _ai_tools_conf__is_registry_valid "${file}" "${read_path}"; then
        exec {naming_fd}<&-
        return 1
    fi
    want="$(_ai_tools_conf__normalize_allowlist_path "$2")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        ai_tools_conf__parse_path_entry "${line}" || continue
        entry="${ai_tools_conf__value}"
        case "${entry}" in
            '!'*) [[ "$(_ai_tools_conf__normalize_allowlist_path "${entry:1}")" == "${want}" ]] \
                      && _ai_tools_conf__naming_carve+=("${line}") ;;
            '%'*) [[ "$(_ai_tools_conf__normalize_allowlist_path "${entry:1}")" == "${want}" ]] \
                      && _ai_tools_conf__naming_park+=("${line}") ;;
            *)    [[ "$(_ai_tools_conf__normalize_allowlist_path "${entry}")" == "${want}" ]] \
                      && _ai_tools_conf__naming_allow+=("${line}") ;;
        esac
    done < "${read_path}"
    exec {naming_fd}<&-
    return 0
}

# ai_tools_conf__has_allowlist_entry <registry-file> <path> : return 0 when an ALLOW line of <registry-file> names
#   <path>. A carve-out or a park line is not membership.
ai_tools_conf__has_allowlist_entry() {
    local -a member_allow=() member_carve=() member_park=()
    _ai_tools_conf__read_lines_naming "$1" "$2" member_allow member_carve member_park || return 1
    (( ${#member_allow[@]} > 0 ))
}

# ai_tools_conf__has_allowlist_exclusion <registry-file> <path> : return 0 when a carve-out (`!`) or a park (`%`) line
#   names <path> exactly. Exact-path, never glob-expanding: it is the relabel helper's question, whether a line
#   withholds this very directory.
ai_tools_conf__has_allowlist_exclusion() {
    local -a member_allow=() member_carve=() member_park=()
    _ai_tools_conf__read_lines_naming "$1" "$2" member_allow member_carve member_park || return 1
    (( ${#member_carve[@]} + ${#member_park[@]} > 0 ))
}

# ai_tools_conf__read_allowlist_matching_lines <array-name> <registry-file> <path> : set the named array to every RAW
#   allow line of <registry-file> naming <path>, and return 0 when at least one did. For a caller that must DELETE
#   the line: the raw text can differ from <path> -- a comment, quotes, or a symlinked spelling -- so reconstructing
#   the line from <path> would fail to match.
ai_tools_conf__read_allowlist_matching_lines() {
    local -n _ai_tools_conf__matched="$1"
    # shellcheck disable=SC2034  # filled through its name by _ai_tools_conf__read_lines_naming
    local -a matching_carve=() matching_park=()
    _ai_tools_conf__read_lines_naming "$2" "$3" _ai_tools_conf__matched matching_carve matching_park || return 1
    (( ${#_ai_tools_conf__matched[@]} > 0 ))
}

# ai_tools_conf__read_allowlist_park_lines <array-name> <registry-file> <path> : the park counterpart of the allow
#   matcher -- set the named array to every RAW `%` line naming <path> exactly, and return 0 when at least one did.
ai_tools_conf__read_allowlist_park_lines() {
    local -n _ai_tools_conf__parked="$1"
    # shellcheck disable=SC2034  # filled through its name by _ai_tools_conf__read_lines_naming
    local -a parking_allow=() parking_carve=()
    _ai_tools_conf__read_lines_naming "$2" "$3" parking_allow parking_carve _ai_tools_conf__parked || return 1
    (( ${#_ai_tools_conf__parked[@]} > 0 ))
}

# ── Registry editing (the one implementation of a registry change) ───────────────────────────
# Three components change the registry -- the CLI on the operator's own file, ai-tools-allowlist on another operator's
# (a `--for` run), and install.sh de-registering its own checkout -- and all three write through these functions, so one
# matcher decides what a line names for every writer and every reader. The file is the agent's LAUNCH GATE: a writer
# that matched lines differently from the reader would leave a project reachable after a "removal", or park it twice.
#
# Each writer edits a `~/.config/ai-tools/project-registry` file alone. A legacy `allowed-projects` is the input
# of the migration and stays as written until `atr admin system post-upgrade` replaces it, so a writer does not mix
# the two grammars in one file. A carve-out line is the operator's own edit and no writer deletes or rewrites one.
#
# Every one of them is idempotent, verifies by RE-READING the file rather than trusting a write, and reports these
# outcomes apart:
#   0  the file now holds the intended state (including "it already did")
#   1  the edit could not be applied -- the file is missing or could not be written
#   2  the request does not apply from the CURRENT state, and no write happened
#   3  the file is a legacy `allowed-projects`, or the grammar refuses a line of it (MSG-B8U2 on stderr); no write
#   4  the path cannot be written as a registry line (add alone); no write
# The 2 cases keep the states apart: adding over a park would leave an allow line the park beats at the launch gate (a
# claim reporting success over a project no session can start in), adding over a carve-out would put two kinds on one
# path, and enabling or disabling a path the file does not name would invent an entry rather than edit one.

# _ai_tools_conf__replace_file <file> <src> : replace <file> with <src>'s contents, preserving its owner and mode.
#   Written beside it and renamed, so a concurrent reader (a launch wrapper gating a session) sees the whole old file
#   or the whole new one, never a half-written gate. The temp file is created in the file's OWN directory, which is
#   what a rename across it requires -- so this fails on a config directory the caller cannot write even when the file
#   itself is writable, and the callers report that rather than aborting on it. Shared by the registry editors
#   and by ai_tools_conf__set_key, the one rewrite of a KEY=value file.
_ai_tools_conf__replace_file() {
    local file="$1" src="$2" tmp owner mode
    owner="$(stat -c '%U:%G' "${file}" 2>/dev/null || true)"
    mode="$(stat -c '%a' "${file}" 2>/dev/null || true)"
    tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 1
    if ! cat -- "${src}" > "${tmp}" 2>/dev/null; then rm -f -- "${tmp}"; return 1; fi
    # Best-effort metadata: a root writer restores another operator's ownership, an unprivileged one is already writing
    # as the owner. A mode that will not apply is worth failing over -- this file is 0600 by design and a widened one
    # exposes an operator's project list.
    [[ -n "${owner}" ]] && chown "${owner}" "${tmp}" 2>/dev/null
    if [[ -n "${mode}" ]] && ! chmod "${mode}" "${tmp}" 2>/dev/null; then rm -f -- "${tmp}"; return 1; fi
    mv -f -- "${tmp}" "${file}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
}

# ai_tools_conf__read_allowlist_state <registry-file> <path> : print how the file answers for <path> from the lines
#   naming it: `conflict` (a carve-out and an allow or park line), `disabled` (a park line), `excluded` (a carve-out
#   line alone), `listed` (an allow line alone), or `absent` (no line, or no file). A park outranks an allow line, as it
#   does at the launch gate, so the duplicate pair reads `disabled`. A file the grammar refuses reads `invalid`, its
#   refusal on stderr, so a caller does not read a file it cannot trust as naming no line.
ai_tools_conf__read_allowlist_state() {
    local file="$1" path="$2"
    local -a state_allow=() state_carve=() state_park=()
    [[ -f "${file}" ]] || { printf 'absent'; return 0; }
    _ai_tools_conf__read_lines_naming "${file}" "${path}" state_allow state_carve state_park \
        || { printf 'invalid'; return 0; }
    if (( ${#state_carve[@]} && ${#state_allow[@]} + ${#state_park[@]} )); then printf 'conflict'
    elif (( ${#state_park[@]} ));  then printf 'disabled'
    elif (( ${#state_carve[@]} )); then printf 'excluded'
    elif (( ${#state_allow[@]} )); then printf 'listed'
    else printf 'absent'
    fi
}

# _ai_tools_conf__check_editable <registry-file> : return 0 when <registry-file> is a file in the grammar
#   of `~/.config/ai-tools/project-registry` the grammar accepts, 1 when it is not a regular file, and 3 when it is
#   legacy or a line is refused (MSG-B8U2 on stderr).
_ai_tools_conf__check_editable() {
    [[ -f "$1" ]] || return 1
    [[ "$(ai_tools_conf__read_registry_grammar "$1")" == current ]] || return 3
    ai_tools_conf__validate_registry "$1" current || return 3
}

# _ai_tools_conf__format_registry_entry <path> : print (no newline) the allow line that reads back as <path> -- <path>
#   as written, or in double quotes where it carries whitespace, `#` or `'` -- and return 0. Return 1, printing nothing,
#   for a path the grammar cannot carry: not absolute, or carrying a glob character, a control byte or `"`. The composed
#   line is put through the validator's own line check before it is printed, so a line the writer appends is one every
#   reader accepts as naming <path>; a line it refused afterwards would refuse the whole file.
_ai_tools_conf__format_registry_entry() {
    local path="${1-}" line
    [[ "${path}" == /* && "${path}" != *[[:cntrl:]\"]* ]] || return 1
    ai_tools_conf__has_glob_characters "${path}" && return 1
    line="${path}"
    [[ "${path}" == *[[:space:]\#\']* ]] && line="\"${path}\""
    _ai_tools_conf__classify_registry_line "${line}" current
    [[ "${_ai_tools_conf__line_kind}" == allow && -z "${_ai_tools_conf__line_fault}" \
        && "${ai_tools_conf__value}" == "${path}" ]] || return 1
    printf '%s' "${line}"
}

# ai_tools_conf__is_registry_path_representable <path> : return 0 when _ai_tools_conf__format_registry_entry writes
#   a line for <path>, so a caller about to create a directory refuses a name the registry cannot carry before its first
#   write.
ai_tools_conf__is_registry_path_representable() {
    _ai_tools_conf__format_registry_entry "${1-}" >/dev/null
}

# ai_tools_conf__allowlist_add <registry-file> <path> : append <path> as an allow entry, on a line of its own. A path
#   already listed is left alone (a re-claim must not duplicate a line); a parked path, and a path a carve-out line
#   names, are refused with 2, since the appended line would not take effect or would put two kinds on one path; a path
#   _ai_tools_conf__format_registry_entry cannot write is refused with 4.
ai_tools_conf__allowlist_add() {
    local file="$1" path="$2" line_break='' line rc=0
    _ai_tools_conf__check_editable "${file}" || { rc=$?; return "${rc}"; }
    case "$(ai_tools_conf__read_allowlist_state "${file}" "${path}")" in
        listed) return 0 ;;
        absent) ;;
        *)      return 2 ;;
    esac
    line="$(_ai_tools_conf__format_registry_entry "${path}")" || return 4
    # A hand-edited registry can run to EOF part-way through its last line, and every reader here keeps that entry (the
    # read loops take a final unbroken line). So the append opens a new line first: written straight, it would join
    # the two paths into a third that no project matches, dropping the claimed one from the launch gate while
    # the preceding entry changed meaning.
    [[ -n "$(tail -c 1 -- "${file}" 2>/dev/null)" ]] && line_break=$'\n'
    printf '%s%s\n' "${line_break}" "${line}" >> "${file}" 2>/dev/null || return 1
    ai_tools_conf__has_allowlist_entry "${file}" "${path}" || return 1
}

# ai_tools_conf__allowlist_remove <registry-file> <path> : delete every allow and park line naming <path>, so no park is
#   left to disable the next project claimed at that path. A carve-out line naming it stays: it is the operator's own
#   edit, and a caller names it as still in force. Removing what is not there succeeds, so an unclaim run twice is not
#   an error, and a missing file does not name the path; a registry path holding anything but a regular file returns 1.
ai_tools_conf__allowlist_remove() {
    local file="$1" path="$2" tmp line keep m rc=0
    # Names distinct from any scalar a sibling library uses: every consumer sources this file, and an array here sharing
    # a name with a local there reads as a type conflict at lint time.
    # shellcheck disable=SC2034  # filled through its name by _ai_tools_conf__read_lines_naming
    local -a doomed_lines=() kept_carve_lines=() parked_lines=()
    [[ -e "${file}" || -L "${file}" ]] || return 0
    _ai_tools_conf__check_editable "${file}" || { rc=$?; return "${rc}"; }
    _ai_tools_conf__read_lines_naming "${file}" "${path}" doomed_lines kept_carve_lines parked_lines || return 3
    doomed_lines+=("${parked_lines[@]}")
    (( ${#doomed_lines[@]} )) || return 0
    tmp="$(mktemp 2>/dev/null)" || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        keep=true
        for m in "${doomed_lines[@]}"; do
            [[ "${line}" == "${m}" ]] && { keep=false; break; }
        done
        ${keep} && printf '%s\n' "${line}"
    done < "${file}" > "${tmp}"
    if ! _ai_tools_conf__replace_file "${file}" "${tmp}"; then rm -f -- "${tmp}"; return 1; fi
    rm -f -- "${tmp}"
    case "$(ai_tools_conf__read_allowlist_state "${file}" "${path}")" in
        absent|excluded) return 0 ;;
        *)               return 1 ;;
    esac
}

# _ai_tools_conf__retag_allowlist_entry <registry-file> <path> <disable|enable> : the shared line rewrite behind the two
#   verbs. It edits the line the operator wrote IN PLACE -- the `%` goes on or comes off, and the line keeps its
#   position, its indentation and its comment -- so parking a project and restoring it leaves the file as it was, rather
#   than moving the entry to the end. A `!` line is a carve-out and is not among the lines either direction reads.
_ai_tools_conf__retag_allowlist_entry() {
    local file="$1" path="$2" op="$3" tmp line m head
    # shellcheck disable=SC2034  # filled through its name by _ai_tools_conf__read_lines_naming
    local -a retag_lines=() live_lines=() retag_carve=()
    [[ -f "${file}" ]] || return 1
    if [[ "${op}" == disable ]]; then
        _ai_tools_conf__read_lines_naming "${file}" "${path}" retag_lines retag_carve live_lines || return 3
        (( ${#retag_lines[@]} )) || return 2
        live_lines=()
    else
        _ai_tools_conf__read_lines_naming "${file}" "${path}" live_lines retag_carve retag_lines || return 3
        (( ${#retag_lines[@]} )) || return 2
    fi
    # ENABLE additionally collapses duplicates. Lifting `%/p` while an allow line for `/p` already exists would leave
    # two live entries for one path. So the FIRST line naming the path survives, un-parked, in its own position,
    # and every later line naming it is dropped: one live entry per path, which is the invariant every reader of this
    # file assumes. DISABLE does not need that rule, since parking each of several allow lines leaves them all parked,
    # which is one state and not two.
    retag_lines+=("${live_lines[@]}")
    local emitted=false
    tmp="$(mktemp 2>/dev/null)" || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        for m in "${retag_lines[@]}"; do
            [[ "${line}" == "${m}" ]] || continue
            # The kind character opens the entry, after any indentation, so the edit is made there and an indented entry
            # keeps its indentation.
            head="${line%%[![:space:]]*}"
            if [[ "${op}" == disable ]]; then
                line="${head}%${line#"${head}"}"
            elif ${emitted}; then
                continue 2                      # a later duplicate of a path already restored
            else
                line="${line#"${head}"}"
                line="${head}${line#%}"
                emitted=true
            fi
            break
        done
        printf '%s\n' "${line}"
    done < "${file}" > "${tmp}"
    if ! _ai_tools_conf__replace_file "${file}" "${tmp}"; then rm -f -- "${tmp}"; return 1; fi
    rm -f -- "${tmp}"
}

# ai_tools_conf__allowlist_disable <registry-file> <path> : park a listed project -- prefix its line with `%`.
#   The launch gate then refuses a session there while the entry, the project's permissions and its label all stay
#   as they are, nested or not. Already disabled succeeds; a path the file does not name, one a carve-out names,
#   and a conflict return 2, since there is no single entry to park.
ai_tools_conf__allowlist_disable() {
    local file="$1" path="$2" rc=0
    _ai_tools_conf__check_editable "${file}" || { rc=$?; return "${rc}"; }
    case "$(ai_tools_conf__read_allowlist_state "${file}" "${path}")" in
        disabled) return 0 ;;
        listed)   ;;
        *)        return 2 ;;
    esac
    _ai_tools_conf__retag_allowlist_entry "${file}" "${path}" disable || { rc=$?; return "${rc}"; }
    [[ "$(ai_tools_conf__read_allowlist_state "${file}" "${path}")" == disabled ]] || return 1
}

# ai_tools_conf__allowlist_enable <registry-file> <path> : restore a parked project -- delete the `%` from its line.
#   Already listed succeeds; a path the file does not name returns 2, because enabling one would be claiming it,
#   which is a different operation with a secret scan in it, and so do a carve-out and a conflict, since a `!` line is
#   the operator's own edit.
ai_tools_conf__allowlist_enable() {
    local file="$1" path="$2" rc=0
    _ai_tools_conf__check_editable "${file}" || { rc=$?; return "${rc}"; }
    case "$(ai_tools_conf__read_allowlist_state "${file}" "${path}")" in
        listed)   return 0 ;;
        disabled) ;;
        *)        return 2 ;;
    esac
    _ai_tools_conf__retag_allowlist_entry "${file}" "${path}" enable || { rc=$?; return "${rc}"; }
    [[ "$(ai_tools_conf__read_allowlist_state "${file}" "${path}")" == listed ]] || return 1
}

# ── Registry classification (one state per path) ───────────────────────────────────────────────
# Every verb that acts on a project decides from one record per path rather than from its own reading of the lines,
# so two verbs cannot disagree about what a path is. An ENTRY is an allow or park line; a carve-out line is not one,
# so a carve-out is never a project a verb can claim, remove or park. A line's path is its `realpath -e`
# where that resolves and the written path without a trailing slash otherwise, so a stale line still names its path;
# a glob carve-out does not name a single path and only blocks. The state names what the path's own lines make it,
# and `blocked` says separately whether a session can reach it: a listed project under a parked parent is listed
# and blocked.
#
#   state         the path's own lines
#   conflict      a carve-out beside an allow or park line
#   parked        a park line (an allow line beside it is the duplicate pair, which enable collapses)
#   listed        an allow line alone
#   carve-out     a carve-out line alone
#   inside        none, and an entry encloses it
#   ancestor      none, no entry encloses it, and an entry sits under it
#   unregistered  none of these
#
# The launch DECISION stays the loader and ai_tools_conf__is_path_excluded; the classifier serves the CLI's verbs,
# `projects list` and the wording of a launch refusal.

# _ai_tools_conf__read_registry_lines <file> <kinds-array> <paths-array> <raws-array> : fill three parallel arrays
#   with one element per entry-carrying line of <file>, in file order: the kind (`allow`, `park`, `carve`, or `glob`
#   for a carve-out with a glob character), the path the section comment defines (the pattern as written for a glob),
#   and the raw line. Reads the file as it is; the caller validates it first.
_ai_tools_conf__read_registry_lines() {
    local -n _ai_tools_conf__lines_kinds="$2" _ai_tools_conf__lines_paths="$3" _ai_tools_conf__lines_raws="$4"
    local file="$1" line entry kind resolved
    _ai_tools_conf__lines_kinds=(); _ai_tools_conf__lines_paths=(); _ai_tools_conf__lines_raws=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
        ai_tools_conf__parse_path_entry "${line}" || continue
        entry="${ai_tools_conf__value}"
        case "${entry}" in
            '!'*) kind=carve; entry="${entry:1}" ;;
            '%'*) kind=park;  entry="${entry:1}" ;;
            *)    kind=allow ;;
        esac
        if [[ "${kind}" == carve ]] && ai_tools_conf__has_glob_characters "${entry}"; then
            kind=glob
        else
            # A real path carrying a control byte (a link to such a name) keeps the written path: the record is
            # tab-separated, and the CLI refuses such a path before it classifies one.
            resolved="$(realpath -e -- "${entry}" 2>/dev/null || printf '%s' "${entry%/}")"
            [[ "${resolved}" == *[[:cntrl:]]* ]] && resolved="${entry%/}"
            entry="${resolved:-/}"
        fi
        _ai_tools_conf__lines_kinds+=("${kind}"); _ai_tools_conf__lines_paths+=("${entry}")
        _ai_tools_conf__lines_raws+=("${line}")
    done < "${file}"
}

# _ai_tools_conf__is_path_under <path> <parent> : return 0 when <path> is strictly inside <parent>.
_ai_tools_conf__is_path_under() { [[ "$1" != "$2" && "$1" == "${2%/}/"* ]]; }

# _ai_tools_conf__does_glob_cover <path> <pattern> : return 0 when a glob carve-out <pattern> covers <path>, matched
#   as ai_tools_conf__is_path_excluded matches it: the whole path against the pattern, or, for a pattern without `*`,
#   an ancestor.
_ai_tools_conf__does_glob_cover() {
    local path="$1" pat="${2%/}"
    # shellcheck disable=SC2053  # the unquoted side is the operator's glob, matched as a pattern
    [[ "${path}" == ${pat} ]] && return 0
    [[ "${pat}" != *'*'* && "${path}" == "${pat}/"* ]]
}

# _ai_tools_conf__get_entry_state <kind-words> : print the state the kinds naming one path give it -- `conflict`,
#   `parked`, `listed`, `carve-out` -- or `none` for no kind. <kind-words> is one argument, the kinds separated
#   by spaces, so the caller's IFS does not decide how they join.
_ai_tools_conf__get_entry_state() {
    local kinds=" ${1-} "
    if [[ "${kinds}" == *' carve '* && ( "${kinds}" == *' allow '* || "${kinds}" == *' park '* ) ]]; then printf 'conflict'
    elif [[ "${kinds}" == *' park '* ]];  then printf 'parked'
    elif [[ "${kinds}" == *' allow '* ]]; then printf 'listed'
    elif [[ "${kinds}" == *' carve '* ]]; then printf 'carve-out'
    else printf 'none'
    fi
}

# ai_tools_conf__read_registry_path_class <registry-file> <canonical-path> : print one TSV record for <path>,
#   `state own enclosing enclosing_state blocked blocked_kind nested blocked_path`, and return 0:
#     state            one of the states the section comment lists
#     own              the kinds of the lines naming the path, `allow`, `park` and `carve` joined with commas, or `none`
#     enclosing        the nearest entry strictly enclosing the path, or `-`
#     enclosing_state  that entry's own state (`listed`, `parked`, `conflict`), or `-`
#     blocked          the first line in file order, park or carve-out, whose coverage includes the path and whose own
#                      path is not the path -- the raw line, a control byte in its comment shown as `?` -- or `-`
#     blocked_kind     `park`, `carve`, `glob`, or `-`
#     nested           the number of entries strictly under the path
#     blocked_path     the path of the `blocked` line as the section comment defines it, without its kind
#                      character (the pattern as written for a glob), or `-`; a command a caller prints names this
#                      field, since `blocked` is the display form
#   A path is reachable when it is `listed` with `blocked` `-`, or `inside` a `listed` enclosing entry with `blocked`
#   `-`. Returns 1 for a file that is not a readable regular file and 3 for one the grammar refuses (MSG-B8U2
#   on stderr), printing nothing. A caller reads the record with IFS pinned to a tab.
ai_tools_conf__read_registry_path_class() {
    local file="$1" path="${2%/}" i kind line_path enclosing='-' enclosing_state='-' blocked='-' blocked_kind='-'
    local blocked_path='-' nested=0 own="" state validity=0
    local own_kinds="" class_fd read_path
    local -a class_kinds=() class_paths=() class_raws=()
    local -A kinds_of=()
    path="${path:-/}"
    _ai_tools_conf__open_registry "${file}" || return 1
    class_fd="${_ai_tools_conf__registry_fd}"; read_path="/proc/self/fd/${class_fd}"
    _ai_tools_conf__is_registry_valid "${file}" "${read_path}" || validity=$?
    (( validity == 0 )) && _ai_tools_conf__read_registry_lines "${read_path}" class_kinds class_paths class_raws
    exec {class_fd}<&-
    (( validity == 0 )) || return "${validity}"
    for i in "${!class_kinds[@]}"; do
        kind="${class_kinds[i]}"; line_path="${class_paths[i]}"
        if [[ "${kind}" == glob ]]; then
            if [[ "${blocked}" == - ]] && _ai_tools_conf__does_glob_cover "${path}" "${line_path}"; then
                blocked="${class_raws[i]}"; blocked_kind=glob; blocked_path="${line_path}"
            fi
            continue
        fi
        kinds_of["${line_path}"]+=" ${kind}"
        if [[ "${line_path}" == "${path}" ]]; then
            own_kinds+=" ${kind}"
        elif [[ "${kind}" != allow && "${blocked}" == - ]] && _ai_tools_conf__is_path_under "${path}" "${line_path}"; then
            blocked="${class_raws[i]}"; blocked_kind="${kind}"; blocked_path="${line_path}"
        fi
    done
    for line_path in "${!kinds_of[@]}"; do
        [[ " ${kinds_of[${line_path}]} " == *' allow '* || " ${kinds_of[${line_path}]} " == *' park '* ]] || continue
        if _ai_tools_conf__is_path_under "${line_path}" "${path}"; then
            nested=$(( nested + 1 ))
        elif _ai_tools_conf__is_path_under "${path}" "${line_path}" \
                && { [[ "${enclosing}" == - ]] || (( ${#line_path} > ${#enclosing} )); }; then
            enclosing="${line_path}"
        fi
    done
    [[ "${enclosing}" == - ]] || enclosing_state="$(_ai_tools_conf__get_entry_state "${kinds_of[${enclosing}]}")"
    for kind in allow park carve; do
        [[ "${own_kinds} " == *" ${kind} "* ]] && own+="${own:+,}${kind}"
    done
    state="$(_ai_tools_conf__get_entry_state "${own_kinds}")"
    if [[ "${state}" == none ]]; then
        if [[ "${enclosing}" != - ]]; then state=inside
        elif (( nested > 0 )); then state=ancestor
        else state=unregistered
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${state}" "${own:-none}" "${enclosing}" "${enclosing_state}" \
        "${blocked//[[:cntrl:]]/?}" "${blocked_kind}" "${nested}" "${blocked_path}"
}

# ai_tools_conf__list_registry_entries_under <registry-file> <canonical-path> : print `<entry-path>\t<state>` for each
#   entry strictly under <path>, once per path, in the order its first line takes in the file, and return 0. The state
#   is the entry's own (`listed`, `parked`, `conflict`). Returns 1 for a file that is not a readable regular file and 3
#   for one the grammar refuses (MSG-B8U2 on stderr), printing nothing.
ai_tools_conf__list_registry_entries_under() {
    local file="$1" path="${2%/}" i line_path validity=0
    # shellcheck disable=SC2034  # filled through its name by _ai_tools_conf__read_registry_lines
    local -a under_kinds=() under_paths=() under_raws=() under_order=()
    local -A under_kinds_of=()
    local under_fd read_path
    path="${path:-/}"
    _ai_tools_conf__open_registry "${file}" || return 1
    under_fd="${_ai_tools_conf__registry_fd}"; read_path="/proc/self/fd/${under_fd}"
    _ai_tools_conf__is_registry_valid "${file}" "${read_path}" || validity=$?
    (( validity == 0 )) && _ai_tools_conf__read_registry_lines "${read_path}" under_kinds under_paths under_raws
    exec {under_fd}<&-
    (( validity == 0 )) || return "${validity}"
    for i in "${!under_kinds[@]}"; do
        line_path="${under_paths[i]}"
        [[ "${under_kinds[i]}" == glob ]] && continue
        _ai_tools_conf__is_path_under "${line_path}" "${path}" || continue
        [[ -n "${under_kinds_of[${line_path}]+set}" ]] || under_order+=("${line_path}")
        under_kinds_of["${line_path}"]+=" ${under_kinds[i]}"
    done
    for line_path in "${under_order[@]}"; do
        [[ " ${under_kinds_of[${line_path}]} " == *' allow '* || " ${under_kinds_of[${line_path}]} " == *' park '* ]] \
            || continue
        printf '%s\t%s\n' "${line_path}" "$(_ai_tools_conf__get_entry_state "${under_kinds_of[${line_path}]}")"
    done
}

# ── The migration from allowed-projects ────────────────────────────────────────────────────────
# `atr admin system post-upgrade` alone migrates, unattended: it writes `~/.config/ai-tools/project-registry` beside
# the legacy file as the marker followed by every line unchanged, verifies the new file, and renames the old one
# to a dated `.bak`, which is the backup. Copying the lines unchanged is what makes the migration safe to run without
# the operator: every allow and `!` line means in format 1.0 what the launch gate already made of it, a `!` being
# an exclusion either way. What changes meaning is the CLI's reading of a `!` that parked a project, which format 1.0
# reads as a carve-out; the plan names each such line with the `%` spelling, and the operator changes it by hand. Until
# the rename the legacy file is the truth: a run that stops part-way leaves `allowed-projects` under its active name,
# the resolver keeps reading it, and the next run replaces whatever `~/.config/ai-tools/project-registry` it finds.

# ai_tools_conf__plan_registry_migration <legacy-file> : print one TSV row per line the migration writes: `marker`
#   with the marker line, then `keep\t<n>\t<raw>` for each line of <legacy-file> by its line number,
#   or `note\t<n>\t<raw>\t<hint>` for a plain `!` line no allow line strictly encloses -- a project parked
#   before the upgrade, or a carve-out with no project around it -- with the hint naming the `%` line that parks it
#   in format 1.0. Returns 1 for a file that is not a readable regular file and 3 for one the legacy grammar refuses
#   (MSG-B8U2 on stderr), printing nothing.
ai_tools_conf__plan_registry_migration() {
    local file="$1" line number=0 entry enclosed allow_path validity=0
    # shellcheck disable=SC2034  # filled through its name by _ai_tools_conf__read_registry_lines
    local -a plan_kinds=() plan_paths=() plan_raws=() plan_allows=()
    [[ -f "${file}" && -r "${file}" ]] || return 1
    ai_tools_conf__validate_registry "${file}" legacy || validity=$?
    (( validity == 0 )) || return "${validity}"
    _ai_tools_conf__read_registry_lines "${file}" plan_kinds plan_paths plan_raws
    for number in "${!plan_kinds[@]}"; do
        [[ "${plan_kinds[number]}" == allow ]] && plan_allows+=("${plan_paths[number]}")
    done
    printf 'marker\t0\t%s\n' "$(ai_tools_conf__get_registry_marker)"
    number=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        number=$(( number + 1 ))
        if ai_tools_conf__parse_path_entry "${line}" && [[ "${ai_tools_conf__value}" == '!'* ]] \
                && ! ai_tools_conf__has_glob_characters "${ai_tools_conf__value:1}"; then
            entry="${ai_tools_conf__value:1}"
            entry="$(realpath -e -- "${entry}" 2>/dev/null || printf '%s' "${entry%/}")"
            enclosed=false
            for allow_path in "${plan_allows[@]}"; do
                _ai_tools_conf__is_path_under "${entry}" "${allow_path}" && { enclosed=true; break; }
            done
            if ! ${enclosed}; then
                printf 'note\t%s\t%s\ta parked project is written %%%s in format 1.0\n' "${number}" "${line}" "${entry}"
                continue
            fi
        fi
        printf 'keep\t%s\t%s\n' "${number}" "${line}"
    done < "${file}"
}

# _ai_tools_conf__list_registry_entry_lines <file> : print `<kind>\t<path>` for each entry-carrying line of <file>,
#   in file order; the migration compares the two files' readings with it.
_ai_tools_conf__list_registry_entry_lines() {
    local i
    # shellcheck disable=SC2034  # filled through its name by _ai_tools_conf__read_registry_lines
    local -a listed_kinds=() listed_paths=() listed_raws=()
    _ai_tools_conf__read_registry_lines "$1" listed_kinds listed_paths listed_raws
    for i in "${!listed_kinds[@]}"; do printf '%s\t%s\n' "${listed_kinds[i]}" "${listed_paths[i]}"; done
}

# ai_tools_conf__migrate_registry <legacy-file> <destination> [<owner-uid>] : write <destination> as the format marker
#   followed by every line of <legacy-file> unchanged, then rename <legacy-file> to its dated sidecar,
#   `<legacy-file>.<YYYYMMDD>-<N>.bak` (ai_tools_conf__find_sidecar_path), print that path, and return 0. <destination>
#   is written through a temporary file in its own directory and a rename, at <legacy-file>'s owner and mode, replacing
#   a <destination> an interrupted run left; it is re-read as a valid `current` file reading the same entries
#   as <legacy-file> before the rename of the source. Refusals leave <legacy-file> as it is, with the reason
#   in AI_TOOLS_CONF__MIGRATION_REFUSAL: 2 when one `lstat` of <legacy-file> does not show a regular file (a symbolic
#   link is not followed) or, with <owner-uid> given, shows another owner or a mode other than 600; 3 when the legacy
#   grammar refuses a line (MSG-B8U2 on stderr); 1 when <legacy-file> cannot be read through (MSG-C6P5 on stderr),
#   or when a write, the verification or the rename fails, with a <destination> this run wrote removed unless
#   the rename of the source was all that failed.
# shellcheck disable=SC2034  # AI_TOOLS_CONF__MIGRATION_REFUSAL is read by the caller, ai-tools-admin's post-upgrade
ai_tools_conf__migrate_registry() {
    local source="$1" destination="$2" owner_uid="${3-}" kind uid gid mode tmp line sidecar validity=0
    AI_TOOLS_CONF__MIGRATION_REFUSAL=""
    if ! IFS=: read -r kind uid gid mode < <(stat -c '%F:%u:%g:%a' -- "${source}" 2>/dev/null); then
        AI_TOOLS_CONF__MIGRATION_REFUSAL="${source} cannot be read"; return 2
    fi
    case "${kind}" in
        'regular file'|'regular empty file') ;;
        *) AI_TOOLS_CONF__MIGRATION_REFUSAL="${source} is a ${kind}, not a regular file"; return 2 ;;
    esac
    if [[ -n "${owner_uid}" && "${uid}" != "${owner_uid}" ]]; then
        AI_TOOLS_CONF__MIGRATION_REFUSAL="${source} is held by uid ${uid}, not by the operator (uid ${owner_uid})"; return 2
    fi
    if [[ -n "${owner_uid}" && "${mode}" != 600 ]]; then
        AI_TOOLS_CONF__MIGRATION_REFUSAL="${source} is mode ${mode}, not 600"; return 2
    fi
    ai_tools_conf__validate_registry "${source}" legacy || validity=$?
    if (( validity == 1 )); then
        AI_TOOLS_CONF__MIGRATION_REFUSAL="${source} cannot be read"; return 1
    elif (( validity != 0 )); then
        AI_TOOLS_CONF__MIGRATION_REFUSAL="${source} has a line the grammar refuses"; return 3
    fi
    tmp="$(mktemp "${destination}.XXXXXX" 2>/dev/null)" || {
        AI_TOOLS_CONF__MIGRATION_REFUSAL="a file cannot be created beside ${destination}"; return 1; }
    # Root writes the operator's file, so the copy takes the source's owner; an operator running it holds it already.
    if ! { printf '%s\n' "$(ai_tools_conf__get_registry_marker)"
           while IFS= read -r line || [[ -n "${line}" ]]; do printf '%s\n' "${line}"; done < "${source}"; } \
               > "${tmp}" 2>/dev/null \
            || ! { chown "${uid}:${gid}" -- "${tmp}" 2>/dev/null || (( EUID != 0 )); } \
            || ! chmod "${mode}" -- "${tmp}" 2>/dev/null || ! mv -f -- "${tmp}" "${destination}" 2>/dev/null; then
        rm -f -- "${tmp}"
        AI_TOOLS_CONF__MIGRATION_REFUSAL="${destination} cannot be written"; return 1
    fi
    if ! ai_tools_conf__validate_registry "${destination}" current 2>/dev/null \
            || [[ "$(_ai_tools_conf__list_registry_entry_lines "${destination}")" \
                  != "$(_ai_tools_conf__list_registry_entry_lines "${source}")" ]]; then
        rm -f -- "${destination}"
        AI_TOOLS_CONF__MIGRATION_REFUSAL="${destination} does not read back as the entries of ${source}"; return 1
    fi
    if ! sidecar="$(ai_tools_conf__find_sidecar_path "${source}" bak)" || ! mv -- "${source}" "${sidecar}" 2>/dev/null; then
        AI_TOOLS_CONF__MIGRATION_REFUSAL="${source} cannot be renamed aside, so it stays the registry readers take"
        return 1
    fi
    printf '%s' "${sidecar}"
}

# ── Seed text for an operator's own config files ──────────────────────────────────────────────
# A file an operator keeps in ~/.config/ai-tools is created carrying its header and no entry, so the operator edits
# a file that states what it is rather than a blank one. The text lives here because it is written from more than one
# place -- `atr admin operators add` on any installed host, and install.sh for the account a from-source install enrols
# -- and a header written twice is a header that disagrees with itself about what the file accepts. Each function
# PRINTS; the caller places the file with the ownership and mode it needs (600, inside a 700
# directory).
#
# A seeded header is written once and no upgrade rewrites it, so it carries what the file is, the one rule a reader
# needs before writing a line, example lines, and the man page that holds the reference -- the page ships
# with the package and reaches every host on every upgrade, where a header stays as it was on the day the account was
# enrolled. tests/unit/man.sh caps the registry header and reads the page's examples
# through ai_tools_conf__parse_path_entry.

# ai_tools_conf__get_allowlist_seed : print the text a fresh `~/.config/ai-tools/project-registry` carries: the format
#   marker as line 1, then the header. It does not name any project, so a session cannot start anywhere until the CLI
#   or the operator adds an entry. The reference is ai-tools-project-registry(5).
ai_tools_conf__get_allowlist_seed() {
    printf '%s\n' \
        "$(ai_tools_conf__get_registry_marker)" \
        "# Project directories the ai-tools sandbox may work in, one per line." \
        "# A session launched by this account starts only inside a listed" \
        "# directory no '!' or '%' line covers. This file is a launch gate," \
        "# not a read boundary, and a line it cannot read refuses it whole." \
        "#" \
        "#   /home/op/project              a project and everything under it" \
        "#   !/home/op/project/vendor      a carve-out: withhold this subtree" \
        "#   %/home/op/parked              a parked project: no session starts" \
        "#   \"/home/op/ai works\"  # note   quote a path with a space or a '#'" \
        "#" \
        "# \`atr projects claim|create|clone\` register a project;" \
        "# \`atr projects disable|enable\` park and restore one;" \
        "# \`atr projects list\` reviews the file." \
        "# Full reference: \`man 5 ai-tools-project-registry\`" \
        ""
}

# ai_tools_conf__get_secret_patterns_seed : print the header a fresh secret-patterns file carries. It carries the header
#   alone, which leaves the built-in baseline in secret-patterns.lib.sh in force -- so seeding this file changes what is
#   classified as a secret only once the operator writes a pattern into it. The replace rule stays in the header
#   whatever the page says, since it is the one fact a reader needs before writing a line. The reference is
#   ai-tools-secret-patterns(5).
ai_tools_conf__get_secret_patterns_seed() {
    printf '%s\n' \
        "# Secret-name patterns for the ai-tools sandbox, one basename glob" \
        "# per line, matched case-insensitively. A file whose name matches is" \
        "# a credential: the root helpers quarantine one the agent writes" \
        "# and seal one already in a project, on your behalf." \
        "#" \
        "# A pattern listed here REPLACES the built-in baseline in the shared" \
        "# library (/usr/local/lib/ai-tools/secret-patterns.lib.sh) rather" \
        "# than adding to it. This file lists none, so the baseline classifies" \
        "# until you write a pattern; then copy the baseline entries you keep," \
        "# alongside your own." \
        "#" \
        "#   .env              *.pem             appsettings.*.json" \
        "#" \
        "# Full reference: man 5 ai-tools-secret-patterns" \
        ""
}

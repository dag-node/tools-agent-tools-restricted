#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/conf.lib.sh
# The one KEY=value grammar every ai-tools config file is read with, the trust predicate that decides whether a file may
# be read at all, and what shares the grammar and so lives beside it: the kind prefix a provider list item carries
# (ai_tools_conf_kind_list, which filters.lib.sh reads as well as providers.lib.sh), the dated config sidecars
# (`<name>.<YYYYMMDD>-<N>.{bak,shipped}`, whose stamp ai_tools_conf_sidecar_path is the single home of), the one
# in-place write of a KEY=value file (ai_tools_conf_set_key for a scalar, ai_tools_conf_set_list for a list), and every
# read AND write of allowed-projects. The settings.json hook-declaration merge, which writes through the sidecars, is
# settings-merge.lib.sh. Sourced (never executed) by operator.lib.sh, skip-dirs.lib.sh, providers.lib.sh, the launch
# wrapper, the CLI and the root helpers, so a key and an allowlist line read the same whichever component reads them.
# The grammar, the present/absent distinction the provider gating turns on, and what the trust predicate requires are
# in providers.rule.md; the allowlist state model is in cli.rule.md.
#
# Config files are PARSED, never sourced: a malformed or tampered file yields a bad value, never executed code
# in a privileged script. List splitting pins IFS locally, because the sourcing scripts run under the strict-mode
# IFS=$'\n\t', where an inherited IFS would read "a b" as one item -- for a provider allowlist, a wrong "no such
# provider" verdict.
#
# A trust refusal reports the owner uid and mode the predicate read (ai_tools_conf_untrusted_reason). That uid is
# the owner on disk only inside the initial user namespace: in any other, a host uid with no mapping reads back
# as the overflow uid 65534 while stat exits 0, so a root-owned file reads as a nobody-owned one and is refused.
# ai_tools_conf_uid_map_is_identity detects that namespace and the reason names it, so the refusal is not investigated
# as a mode or a label.

# Sourced more than once in a single shell: this library's readonly constants would abort under `set -e` on the second
# pass. Return early (an if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and trips the sourcing
# shell's `set -e`).
if [[ -n "${_AI_TOOLS_CONF_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_CONF_LIB=1

# _ai_tools_conf_warn [code] <message...> : this library's one report, on stderr. A leading message
#   code (msg.lib.sh states the form) goes on its own line ahead of the message, the shape
#   tests/lib/harness.sh's assert_msg reads; matched inline, since this library is sourced by every
#   root helper and by the sandbox account on each launch and so takes no dependency of its own.
#   The `conf: ` prefix is stated here, so a message text does not carry one.
_ai_tools_conf_warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'conf: %s\n' "$*" >&2
}

# ai_tools_conf_is_text_file <path> : succeed when <path> is a regular file that is empty or holds
#   text -- no NUL bytes, which is what `grep -I` reports a binary file by. For a file whose whole
#   content is handed to a program as prose (an agent's system prompt): the trust predicate
#   says who may have written it, this says the bytes are the kind the reader expects. It READS the
#   file, so the caller is an account that may.
ai_tools_conf_is_text_file() {
    local path="$1"
    [[ -f "${path}" ]] || return 1
    [[ -s "${path}" ]] || return 0
    LC_ALL=C grep -Iq . "${path}" 2>/dev/null
}

# ai_tools_conf_is_trusted <path> : succeed when <path> exists, is not a symlink, is owned by
#   root, and is writable by neither group nor other -- the property that makes it safe for a
#   sandbox-side process to parse or source. A symlink is refused outright rather than followed,
#   so a link planted in a writable directory cannot redirect the read at a root-owned target.
#   Applies to directories too: a group-writable directory lets a non-root writer unlink and
#   replace the root-owned file inside it, so a trusted file in an untrusted directory is not
#   trusted. Fails closed on any stat error.
ai_tools_conf_is_trusted() {
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

# ai_tools_conf_uid_map_is_identity [map-file] : succeed when this process runs in the INITIAL
#   user namespace -- the only one where an owner uid read off disk means what it says. The
#   kernel's map there is exactly one identity range over the whole uid space; any other content,
#   an empty map included, means uids are translated and fails closed with the rest. Parsing sets
#   IFS locally, since callers run under a strict IFS that would otherwise stop `read -a`
#   splitting the kernel's space-padded columns, and a map of several ranges is refused on the
#   embedded newline rather than parsed from its first line alone. <map-file> is
#   /proc/self/uid_map for a live reading (the default) and a fixture under test; it is a
#   positional argument, so no environment variable selects it.
ai_tools_conf_uid_map_is_identity() {
    local map_file="${1:-/proc/self/uid_map}" map IFS=$' \t\n'
    local -a ranges=()
    [[ -r "${map_file}" ]] || return 1
    map="$(<"${map_file}")"
    [[ "${map}" == *$'\n'* ]] && return 1
    read -r -a ranges <<< "${map}"
    (( ${#ranges[@]} == 3 )) || return 1
    [[ "${ranges[0]}" == 0 && "${ranges[1]}" == 0 && "${ranges[2]}" == 4294967295 ]]
}

# ai_tools_conf_untrusted_reason <path> : print, on one line, what ai_tools_conf_is_trusted
#   observed about a <path> it refused -- the owner uid and mode it read, against what it
#   requires -- so the refusal states what was observed. When the owner check fails outside the
#   initial user namespace the line says so: the uid read there is a translation, and ownership
#   cannot be evaluated from it. Always prints and returns 0.
ai_tools_conf_untrusted_reason() {
    local path="${1:-}" meta owner mode
    [[ -n "${path}" ]] || { printf 'no path given'; return 0; }
    [[ -L "${path}" ]] && { printf 'is a symlink'; return 0; }
    [[ -e "${path}" ]] || { printf 'does not exist'; return 0; }
    meta="$(stat -c '%u %a' "${path}" 2>/dev/null)" || { printf 'could not be stat-ed'; return 0; }
    owner="${meta%% *}"; mode="${meta##* }"
    printf 'owner=%s mode=%s, expected owner=0 with no group/other write' "${owner}" "${mode}"
    if [[ "${owner}" != 0 ]] && ! ai_tools_conf_uid_map_is_identity /proc/self/uid_map; then
        printf ' (this process is not in the initial user namespace, so the owner it reads is a translation and ownership cannot be evaluated here)'
    fi
    return 0
}

# _ai_tools_conf_strip_inline_comment <text> : set _ai_tools_conf_value to <text> with an inline
#   comment removed. `#` ends the value only where a comment conventionally starts -- at the very
#   beginning, or after whitespace -- so an interior `#` (a fragment, a C# name, a colour) stays
#   part of an unquoted value.
_ai_tools_conf_strip_inline_comment() {
    local rest="$1" kept="" head
    while [[ "${rest}" == *'#'* ]]; do
        head="${rest%%#*}"
        if [[ -z "${kept}${head}" || "${head}" == *[[:space:]] ]]; then
            _ai_tools_conf_value="${kept}${head}"
            return 0
        fi
        kept+="${head}#"
        rest="${rest#*#}"
    done
    _ai_tools_conf_value="${kept}${rest}"
}

# _ai_tools_conf_parse_value <raw> : set _ai_tools_conf_value to the value <raw> (everything after
#   the `=`) denotes -- surrounding whitespace trimmed, one matched quote layer stripped, inline
#   comment removed. A quoted value ends at its closing quote and whatever follows is discarded,
#   so `#` inside quotes stays literal. An unmatched opening quote is taken verbatim rather than
#   silently truncating the value at some later character. Sets _ai_tools_conf_value_quoted to 1
#   when the value opened with a quote and 0 otherwise, which is what ai_tools_conf_list_value
#   tells `"[a]"` from `[a]` by once the quotes are gone.
_ai_tools_conf_parse_value() {
    local value="$1" quote rest
    value="${value#"${value%%[![:space:]]*}"}"
    case "${value}" in
        '"'*) quote='"' ;;
        "'"*) quote="'" ;;
        *)    quote=''  ;;
    esac
    _ai_tools_conf_value_quoted=0
    [[ -n "${quote}" ]] && _ai_tools_conf_value_quoted=1
    if [[ -n "${quote}" ]]; then
        rest="${value#?}"
        if [[ "${rest}" == *"${quote}"* ]]; then
            _ai_tools_conf_value="${rest%%"${quote}"*}"
            return 0
        fi
        value="${rest}"
    else
        _ai_tools_conf_strip_inline_comment "${value}"
        value="${_ai_tools_conf_value}"
    fi
    _ai_tools_conf_value="${value%"${value##*[![:space:]]}"}"
}

# ai_tools_conf_read <file> <key> : set _ai_tools_conf_value to the value of the LAST assignment
#   of <key> in <file>. Returns 0 when the key is PRESENT (an empty value included), 1 when it is
#   absent or the file is unreadable -- the present-but-empty / absent distinction the fail-closed
#   allowlist gating depends on.
ai_tools_conf_read() {
    local file="$1" wanted="$2" line key found=1
    _ai_tools_conf_value=""
    _ai_tools_conf_value_quoted=0
    [[ -r "${file}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${line}" || "${line}" == '#'* || "${line}" != *=* ]] && continue
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "${key}" == "${wanted}" ]] || continue
        _ai_tools_conf_parse_value "${line#*=}"
        found=0
    done < "${file}"
    return "${found}"
}

# ai_tools_conf_yes <file> <key> : succeed when <key> is set to a yes value -- yes, true, 1 or on, in any case and with
#   or without quotes, which the grammar has already removed. No, false, 0, off, an empty value, an absent key
#   and an unreadable file are all no. A value in neither set is no as well, and is reported, so a mistyped switch
#   does not change what a launch does without a line saying so.
ai_tools_conf_yes() {
    local file="$1" key="$2"
    ai_tools_conf_read "${file}" "${key}" || return 1
    case "${_ai_tools_conf_value,,}" in
        yes|true|1|on) return 0 ;;
        no|false|0|off|"") return 1 ;;
    esac
    _ai_tools_conf_warn MSG-D2F9 "switch ${key} in ${file} is neither a yes value (yes, true, 1, on) nor a no value (no, false, 0, off) -- read as no"
    return 1
}

# ai_tools_conf_get <file> <key> : print the value of <key>, empty when absent. For a caller that
#   only wants the string; one that must tell absent from empty calls ai_tools_conf_read.
ai_tools_conf_get() {
    local status=0
    ai_tools_conf_read "$1" "$2" || status=1
    printf '%s' "${_ai_tools_conf_value}"
    return "${status}"
}

# ai_tools_conf_split <array-name> <value> : split <value> into the named array on commas and
#   whitespace, dropping empty items. IFS is set locally, so the result does not depend on the
#   caller's IFS. The splitter for a command-line argument, which does not read brackets; a list
#   read from a file goes through ai_tools_conf_list_value.
ai_tools_conf_split() {
    local -n _ai_tools_conf_split_out="$1"
    local raw="${2-}" token
    local -a tokens=()
    local IFS=$' \t\n,'
    read -ra tokens <<< "${raw}"
    _ai_tools_conf_split_out=()
    for token in "${tokens[@]}"; do
        [[ -n "${token}" ]] && _ai_tools_conf_split_out+=("${token}")
    done
    return 0
}

# ai_tools_conf_list <array-name> <file> <key> : read <key> from <file> and split it into the
#   named array, but ONLY when the key is present -- a present key REPLACES the array (an empty
#   value giving an empty array, an explicit "none"), while an absent key leaves it untouched and
#   returns 1. That is what makes an override key override: a caller seeds the array with its
#   default and calls this, and a config that omits the key keeps that default.
ai_tools_conf_list() {
    local out_name="$1" file="$2" key="$3"
    ai_tools_conf_read "${file}" "${key}" || return 1
    ai_tools_conf_list_value "${out_name}" "${_ai_tools_conf_value}" "${_ai_tools_conf_value_quoted}" \
        "${key} in ${file}"
}

# ai_tools_conf_list_value <array-name> <value> [quoted] [label] : split a list value read from
#   a file into the named array. `[a, b]` is a bracketed list, whose inside splits as
#   ai_tools_conf_split splits; any other value splits as it stands. A value with one bracket and not
#   the other, one whose quotes the parser stripped (<quoted> 1, `"[a]"`), and a bracketed one
#   carrying a quote or a further bracket inside is invalid: the array is set EMPTY, MSG-D5N5 names
#   <label> on stderr, and _ai_tools_conf_list_invalid is set to 1 (0 otherwise). Empty is the less-access
#   reading for every list that grants something -- an empty OPERATORS does not enrol any account, an
#   empty AI_TOOLS_AGENTS does not enable any agent -- where treating the key as absent would fall back to a default
#   that enables more. Returns 0 either way, since several callers run under `set -e`.
ai_tools_conf_list_value() {
    local out_name="$1" value="${2-}" quoted="${3:-0}" label="${4:-a list value}" inner reason=""
    _ai_tools_conf_list_invalid=0
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "${value}" != '['* && "${value}" != *']' ]]; then
        ai_tools_conf_split "${out_name}" "${value}"
        return 0
    fi
    inner="${value#[}"; inner="${inner%]}"
    if [[ "${value}" != '['*']' ]]; then
        reason="it has one bracket and not the other"
    elif [[ "${quoted}" == 1 ]]; then
        reason="a bracketed list is written without quotes around it"
    elif [[ "${inner}" == *[\"\'\[\]]* ]]; then
        reason="an item inside brackets carries no quote or bracket"
    fi
    if [[ -n "${reason}" ]]; then
        local -n _ai_tools_conf_list_value_out="${out_name}"
        _ai_tools_conf_list_value_out=()
        _ai_tools_conf_list_invalid=1
        _ai_tools_conf_warn MSG-D5N5 "invalid list, read as the empty list -- ${label} (${reason}): ${value}; write it as [a, b]"
        return 0
    fi
    ai_tools_conf_split "${out_name}" "${inner}"
}

# ── Kind prefixes: what a provider list item names ───────────────────────────────────────────
# An item of AI_TOOLS_AGENTS, AI_TOOLS_INTEGRATIONS or AI_TOOLS_FILTERS carries its kind as a prefix (agent-claude-code,
# integration-dotnet, filter-dotnet), so one word names one thing wherever an operator writes it: dotnet is both
# an integration and a filter set. The prefix lives in operator.conf alone -- a manifest, a fragment and a rules file
# keep the bare name, since their directory already states the kind -- so the list reader strips it and every consumer
# receives the bare name. An item without its key's prefix makes the whole list invalid (MSG-X6F2): an earlier release
# wrote bare names, and `ai-tools-admin system post-upgrade` rewrites them (ai_tools_conf_kind_migrate,
# providers.lib.sh). _ai_tools_conf_kind_table is the one place a key is tied to its prefix.

# _ai_tools_conf_kind_table : print "KEY<TAB>prefix" per list key that carries a kind prefix.
_ai_tools_conf_kind_table() {
    printf '%s\t%s\n' AI_TOOLS_AGENTS agent- AI_TOOLS_INTEGRATIONS integration- AI_TOOLS_FILTERS filter-
}

# ai_tools_conf_kind_prefix <KEY> : print the kind prefix <KEY>'s items carry. Returns 1, printing
#   nothing, for a key outside the table.
ai_tools_conf_kind_prefix() {
    local key prefix
    while IFS=$'\t' read -r key prefix; do
        [[ "${key}" == "${1-}" ]] && { printf '%s' "${prefix}"; return 0; }
    done < <(_ai_tools_conf_kind_table)
    return 1
}

# _ai_tools_conf_kind_bare <prefix> <item> : print the bare name when <item> is <prefix> followed by
#   a plain name (the charset a manifest basename takes, no `..`); return 1 otherwise.
_ai_tools_conf_kind_bare() {
    local prefix="$1" item="$2" bare
    [[ "${item}" == "${prefix}"* ]] || return 1
    bare="${item#"${prefix}"}"
    [[ "${bare}" =~ ^[A-Za-z0-9._-]+$ && "${bare}" != *..* ]] || return 1
    printf '%s' "${bare}"
}

# ai_tools_conf_kind_list <array-name> <file> <KEY> : ai_tools_conf_list for a key in the kind table,
#   which then requires every item to carry the key's prefix and sets the array to the BARE names,
#   in order. An item that does not makes the whole list invalid: the array is set EMPTY,
#   _ai_tools_conf_list_invalid and _ai_tools_conf_list_unprefixed are set to 1, and MSG-X6F2 names
#   the key, the items and the command that rewrites them on stderr -- the less-access reading
#   ai_tools_conf_list_value gives a malformed list, for the same reason. Returns 1, leaving the
#   array untouched, for an absent key, so a caller's baseline stands; 2 for a key outside the table.
ai_tools_conf_kind_list() {
    local out_name="$1" file="$2" key="$3" prefix item bare
    local -a _ai_tools_conf_kind_list_raw=() _ai_tools_conf_kind_list_bare=() unprefixed=()
    _ai_tools_conf_list_invalid=0 _ai_tools_conf_list_unprefixed=0
    prefix="$(ai_tools_conf_kind_prefix "${key}")" || return 2
    ai_tools_conf_list _ai_tools_conf_kind_list_raw "${file}" "${key}" || return 1
    local -n _ai_tools_conf_kind_list_out="${out_name}"
    if (( _ai_tools_conf_list_invalid )); then
        _ai_tools_conf_kind_list_out=()
        return 0
    fi
    for item in "${_ai_tools_conf_kind_list_raw[@]}"; do
        if bare="$(_ai_tools_conf_kind_bare "${prefix}" "${item}")"; then
            _ai_tools_conf_kind_list_bare+=("${bare}")
        else
            unprefixed+=("${item}")
        fi
    done
    if (( ${#unprefixed[@]} > 0 )); then
        _ai_tools_conf_kind_list_out=()
        _ai_tools_conf_list_invalid=1
        _ai_tools_conf_list_unprefixed=1
        _ai_tools_conf_warn MSG-X6F2 "invalid list, read as the empty list -- ${key} in ${file} holds ${unprefixed[*]}, not written as ${prefix}<name>; this rewrites a bare name and names any it cannot: sudo ai-tools-admin system post-upgrade"
        return 0
    fi
    _ai_tools_conf_kind_list_out=("${_ai_tools_conf_kind_list_bare[@]+"${_ai_tools_conf_kind_list_bare[@]}"}")
    return 0
}

# ai_tools_conf_kind_item <KEY> <name> : print <name> as <KEY> holds it -- with the key's prefix
#   added to a bare name, and a name already carrying it printed as given. The writer's side of
#   ai_tools_conf_kind_list. Returns 1, printing nothing, for a key outside the table or a name
#   that is not a plain name once the prefix is added.
ai_tools_conf_kind_item() {
    local key="$1" name="$2" prefix
    prefix="$(ai_tools_conf_kind_prefix "${key}")" || return 1
    [[ "${name}" == "${prefix}"* ]] || name="${prefix}${name}"
    _ai_tools_conf_kind_bare "${prefix}" "${name}" >/dev/null || return 1
    printf '%s' "${name}"
}

# ai_tools_conf_kind_unmigrated <file> : print "KEY<TAB>item" for every item a key in the kind table
#   holds without that key's prefix, in table order and then list order -- the items that make
#   ai_tools_conf_kind_list refuse the list. The one detection predicate: the base package's %post,
#   install.sh, `system post-upgrade --check` and both launch tiers read it. Read-only. A missing or
#   untrusted <file>, an absent key and a list the grammar refuses print nothing, since each already
#   has a report of its own.
ai_tools_conf_kind_unmigrated() {
    local file="$1" key prefix item
    local -a items=()
    [[ -f "${file}" ]] && ai_tools_conf_is_trusted "${file}" || return 0
    while IFS=$'\t' read -r key prefix; do
        ai_tools_conf_list items "${file}" "${key}" 2>/dev/null || continue
        (( _ai_tools_conf_list_invalid )) && continue
        for item in "${items[@]+"${items[@]}"}"; do
            _ai_tools_conf_kind_bare "${prefix}" "${item}" >/dev/null || printf '%s\t%s\n' "${key}" "${item}"
        done
    done < <(_ai_tools_conf_kind_table)
    return 0
}

# ── Sidecar files: what an upgrade preserves when it touches an operator's config ────────────
# An install that rewrites a config the operator owns leaves two kinds of copy behind, and they answer different
# questions -- neither substitutes for the other:
#
#   <name>.<YYYYMMDD>-<N>.bak   what the operator HAD. The only thing that restores their
#                               settings if a rewrite is valid but wrong, which no syntax check
#                               catches. Written only when a file is about to change.
#   <name>.<YYYYMMDD>-<N>.shipped  what they were SUPPOSED to get. Written when the merge could not
#                               run, or when the file is one this project refuses to rewrite
#                               unattended, so the hand merge has a source -- a host installed
#                               from the RPM has no checkout to copy from.
#
# The date stamp makes them survive successive runs: each install adds a copy rather than overwriting the evidence
# of the last. Every copy takes a `-N` counter, starting at 1, so a .bak is never overwritten -- an operator who ran
# the installer twice in a day is exactly the one who needs the first copy -- and the day's copies sort in the order
# they were made.
#
# The two kinds accumulate differently, because they record different things. A .bak records that a run replaced
# the file, so each one is distinct evidence and every rewrite writes one. A .shipped records the baseline that was
# on offer, so ai_tools_conf_reference reuses an existing copy whose content already matches and dates a new one only
# for a baseline the directory does not hold. A host re-running the installer against an unchanged source tree therefore
# keeps one copy per DIFFERENT baseline it was offered, rather than one per run.

# ai_tools_conf_sidecar_path <path> <kind> : print an UNUSED sidecar path for <path>. Returns 1
#   without printing when the day's namespace is exhausted, so a caller never silently reuses a
#   name. Pure except for the existence tests. Public because it is the single home of the
#   `<path>.<YYYYMMDD>-<N>.<kind>` convention: managed-assets.lib.sh stamps a replaced shipped
#   asset the same way this file stamps a replaced config, and <path> may be a directory there,
#   while providers.lib.sh stamps a managed file an uninstall moved aside. The kind names the event
#   that produced the copy -- `bak` beside a file a merge replaced, `retired` where the live path
#   is gone -- so a reader tells the two recoveries apart by the name alone.
ai_tools_conf_sidecar_path() {
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

# _ai_tools_conf_match_perms <target> <model> : give <target> the owner and mode of <model>, so a
#   sidecar of a mode-0640 control-plane file is never left more readable than the file it copies.
#   Best-effort: a caller without the privilege to chown still gets the copy.
_ai_tools_conf_match_perms() {
    local target="$1" model="$2" meta
    [[ -e "${model}" ]] || return 0
    meta="$(stat -c '%u:%g %a' "${model}" 2>/dev/null)" || return 0
    chown "${meta%% *}" "${target}" 2>/dev/null || true
    chmod "${meta##* }" "${target}" 2>/dev/null || true
    return 0
}

# ai_tools_conf_backup <file> : copy <file> to a fresh dated .bak and print that path. `cp -p`
#   keeps mode, ownership and timestamps, so the copy is a faithful restore point rather than a
#   file the operator has to re-permission. Returns 1 without printing a path when no copy was made.
ai_tools_conf_backup() {
    local file="$1" target
    [[ -f "${file}" ]] || return 1
    target="$(ai_tools_conf_sidecar_path "${file}" bak)" || return 1
    cp -p "${file}" "${target}" 2>/dev/null || return 1
    printf '%s' "${target}"
}

# ai_tools_conf_reference <deployed> <shipped> : print the .shipped sidecar beside <deployed> that
#   holds the <shipped> baseline, copying it to a fresh dated path when no existing sidecar matches
#   it byte for byte. The copy takes the DEPLOYED file's owner and mode, not the source tree's.
#   Returns 1 without printing a path when the baseline is absent or the copy fails.
ai_tools_conf_reference() {
    local deployed="$1" shipped="$2" target existing
    [[ -f "${shipped}" ]] || return 1
    for existing in "${deployed}".*.shipped; do
        [[ -f "${existing}" ]] || continue
        if cmp -s "${existing}" "${shipped}"; then
            printf '%s' "${existing}"
            return 0
        fi
    done
    target="$(ai_tools_conf_sidecar_path "${deployed}" shipped)" || return 1
    cp "${shipped}" "${target}" 2>/dev/null || return 1
    _ai_tools_conf_match_perms "${target}" "${deployed}"
    printf '%s' "${target}"
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

# ai_tools_conf_keys <array-name> <file> : set the named array to every KEY this file mentions,
#   whether the key is live or written as a commented-out default (`#KEY=` / `# KEY =`). Both
#   forms count as "mentioned", which is the point: a key an operator has deliberately commented
#   out is one they have already seen, so re-announcing it every upgrade would be noise. A comment
#   indented further than one space is prose, not a default, and does not name an option.
ai_tools_conf_keys() {
    local -n _ai_tools_conf_keys_out="$1"
    local file="$2" line key
    _ai_tools_conf_keys_out=()
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
        _ai_tools_conf_keys_out+=("${key}")
    done < "${file}"
    return 0
}

# ai_tools_conf_new_keys <array-name> <deployed> <shipped> : set the named array to every key the
#   shipped file documents that the deployed one does not mention at all. Returns 1 when there are
#   none, so a caller can stay silent in the common case.
ai_tools_conf_new_keys() {
    local -n _ai_tools_conf_new_out="$1"
    local deployed="$2" shipped="$3"
    local -a deployed_keys=() shipped_keys=()
    local key seen seen_key
    _ai_tools_conf_new_out=()
    ai_tools_conf_keys shipped_keys "${shipped}" || return 1
    ai_tools_conf_keys deployed_keys "${deployed}" || return 1
    for key in "${shipped_keys[@]}"; do
        seen=""
        for seen_key in "${deployed_keys[@]}"; do
            [[ "${seen_key}" == "${key}" ]] && { seen=1; break; }
        done
        [[ -n "${seen}" ]] && continue
        # A shipped file may document a key more than once; announce it once.
        for seen_key in "${_ai_tools_conf_new_out[@]}"; do
            [[ "${seen_key}" == "${key}" ]] && { seen=1; break; }
        done
        [[ -n "${seen}" ]] || _ai_tools_conf_new_out+=("${key}")
    done
    (( ${#_ai_tools_conf_new_out[@]} > 0 ))
}

# ── KEY=value files: set one key in place ────────────────────────────────────────────────────
# The one rewrite this project makes to operator.conf is a single key's value -- the OPERATORS list
# from `ai-tools-admin operators add|remove` and the AI_TOOLS_AGENTS list from the toolchain provisioning's agent choice
# (ai_tools_conf_set_list), and the provisioning's switches (ai_tools_conf_set_key). Setting a key replaces one line
# and does not splice a block in, which is what ai_tools_conf_new_keys leaves to the operator: the line replaced is
# the key's own -- its last live assignment, the one a reader takes, or where the file has none, the first commented
# default ai_tools_conf_keys counts as a mention -- so the template's commented default is rewritten IN PLACE under its
# comment block and the file keeps the shape the new-key report reads. A live line an operator added after the commented
# default is the one replaced, since rewriting the default would leave the later line winning the read. Every other line
# is copied byte for byte.

# ai_tools_conf_set_key <file> <KEY> <value> : write `KEY="value"` into <file>, replacing the line
#   _ai_tools_conf_write_line picks -- the last live `KEY=`, else the first `#KEY=` / `# KEY=` --
#   or appending the line when none does. A missing <file> is created at mode 0644; an existing one
#   keeps its owner and mode and is replaced by a rename (_ai_tools_conf_replace_file). Verified by
#   re-reading the key through ai_tools_conf_read. Returns 0 when the file now holds the value, 1
#   when it could not be written or does not read back, 2 for a KEY outside the identifier charset
#   or a value carrying a newline or a double quote -- either would end the line or the quoted
#   value early and write a different setting than the one asked for.
ai_tools_conf_set_key() {
    local file="$1" key="$2" value="$3"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [[ "${value}" != *$'\n'* && "${value}" != *'"'* ]] || return 2
    _ai_tools_conf_write_line "${file}" "${key}" "${key}=\"${value}\"" || return 1
    ai_tools_conf_read "${file}" "${key}" && [[ "${_ai_tools_conf_value}" == "${value}" ]]
}

# ai_tools_conf_set_list <file> <KEY> [item]... : write `KEY=[a, b]` into <file> (`KEY=[]` for no
#   items), replacing the same line ai_tools_conf_set_key replaces and keeping the file's owner and
#   mode the same way. Verified by reading the list back through ai_tools_conf_list. Returns 0 when
#   the file now holds the items in order, 1 when it could not be written or does not read back, 2 for
#   a KEY outside the identifier charset or an item that is empty or carries whitespace, a comma,
#   a bracket, a quote or a `#` -- each would split into other items, or end the list, on the read.
ai_tools_conf_set_list() {
    local file="$1" key="$2" item joined=""
    shift 2
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    for item in "$@"; do
        [[ -n "${item}" && "${item}" != *[[:space:],\[\]\"\'#]* ]] || return 2
        joined+="${joined:+, }${item}"
    done
    _ai_tools_conf_write_line "${file}" "${key}" "${key}=[${joined}]" || return 1
    local -a written=()
    ai_tools_conf_list written "${file}" "${key}" || return 1
    [[ "${written[*]-}" == "$*" && ${#written[@]} -eq $# ]]
}

# _ai_tools_conf_write_line <file> <KEY> <line> : replace the last live assignment of KEY in <file>
#   (`KEY=`, whitespace allowed around the key) with <line> -- or, where there is none, the first
#   commented default (`#KEY=`, `# KEY=`) -- or append <line> when the file mentions neither,
#   copying every other line byte for byte. A missing <file> is created at mode 0644; an
#   existing one keeps its owner and mode and is replaced by a rename
#   (_ai_tools_conf_replace_file). Returns 1 when the file could not be written. The one line
#   replacement both public writers share, so they rewrite the same line of the same file.
_ai_tools_conf_write_line() {
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
        if ! _ai_tools_conf_replace_file "${file}" "${tmp}"; then rm -f -- "${tmp}"; return 1; fi
    elif ! install -m 644 -- "${tmp}" "${file}" 2>/dev/null; then
        rm -f -- "${tmp}"; return 1
    fi
    rm -f -- "${tmp}"
}

# ── Path-list files (allowed-projects) ───────────────────────────────────────────────────────
# The launch allowlist is one path per line rather than KEY=value, but it is read with the SAME rules as everything
# else: a whole-line or end-of-line `#` comment, and one matched quote layer for a path that must contain a space
# or a literal `#`. Sharing the grammar is the point -- every reader of this file (the launch wrapper, the CLI,
# the owner resolver, and each root helper that walks or labels a project; providers.rule.md names them) parses it here,
# and a rule that lives in each of them separately is a rule that drifts.
#
#   /home/op/project              a path
#   /home/op/project   # why      an end-of-line comment: `#` after whitespace ends the entry
#   "/home/op/ai works"           quotes carry a space, and make `#` inside them literal
#   !/home/op/project/vendor      an exclusion; the `!` precedes the quotes: !"/a b"
#
# An entry is NOT resolved or validated here: callers canonicalize with realpath and match exclusions as globs, and this
# only decides what text the line denotes.

# ai_tools_conf_path_entry <line> : set _ai_tools_conf_value to the entry <line> denotes and
#   return 0; return 1 for a line that does not carry an entry (blank, or a whole-line comment), which
#   is the caller's signal to skip it. A leading `!` is preserved on the result, so an exclusion
#   stays distinguishable after the quotes are stripped.
ai_tools_conf_path_entry() {
    local line="${1-}" negate=""
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "${line}" || "${line}" == '#'* ]] && { _ai_tools_conf_value=""; return 1; }
    if [[ "${line}" == '!'* ]]; then
        negate='!'
        line="${line#\!}"
        line="${line#"${line%%[![:space:]]*}"}"
    fi
    _ai_tools_conf_parse_value "${line}"
    [[ -n "${_ai_tools_conf_value}" ]] || return 1
    _ai_tools_conf_value="${negate}${_ai_tools_conf_value}"
    return 0
}

# ── Allowlist membership (exact-entry matching) ──────────────────────────────────────────────
# One predicate for "is this path an entry of allowed-projects", shared by every component that asks: the launch
# wrapper's post-claim confirm, the claim/unclaim CLI (reg/unreg, project_state), and the relabel helper. They read
# the file through that grammar, so an entry written in
# that grammar -- an end-of-line comment (`/p   # why`), a quoted path (`"/p with space"`), or a
# spelling reached by a symlink or trailing slash -- is a MATCH here, where a raw `grep -qxF` against the stored line
# would miss it and report the project unlisted. Comparison is on realpath-normalized values, the same canonicalization
# the launch gate applies, so the confirm and the gate agree. A stored entry that no longer resolves cannot equal
# an existing target and is skipped (the launch wrapper drops unresolvable entries the same way). Callers pass
# an existing path (a realpath'd project dir); membership of a non-existent path is never asserted.

# _ai_tools_conf_allowlist_norm <path> : print <path> realpath-normalized, or <path> itself when
#   it does not resolve, so the two membership predicates canonicalize target and entry identically.
_ai_tools_conf_allowlist_norm() { realpath -e "$1" 2>/dev/null || printf '%s' "$1"; }

# ai_tools_conf_allowlist_has_entry <allowlist-file> <path> : return 0 when <path> matches an
#   ALLOW entry (a non-`!` line) of <allowlist-file>. Exclusion lines never count as membership.
ai_tools_conf_allowlist_has_entry() {
    local file="$1" want line entry
    want="$(_ai_tools_conf_allowlist_norm "$2")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        ai_tools_conf_path_entry "${line}" || continue
        entry="${_ai_tools_conf_value}"
        [[ "${entry}" == '!'* ]] && continue
        [[ "$(_ai_tools_conf_allowlist_norm "${entry}")" == "${want}" ]] && return 0
    done < "${file}"
    return 1
}

# ai_tools_conf_allowlist_has_exclusion <allowlist-file> <path> : return 0 when <path> matches a
#   `!` EXCLUSION entry exactly (compared without the `!`). This is exact-path, not glob: it is the
#   relabel helper's "is this dir explicitly excluded" check, which never expanded globs.
ai_tools_conf_allowlist_has_exclusion() {
    local file="$1" want line entry
    want="$(_ai_tools_conf_allowlist_norm "$2")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        ai_tools_conf_path_entry "${line}" || continue
        entry="${_ai_tools_conf_value}"
        [[ "${entry}" == '!'* ]] || continue
        [[ "$(_ai_tools_conf_allowlist_norm "${entry#\!}")" == "${want}" ]] && return 0
    done < "${file}"
    return 1
}

# ai_tools_conf_allowlist_matching_lines <array-name> <allowlist-file> <path> : set the named array
#   to every RAW line of <allowlist-file> whose ALLOW entry matches <path>, and return 0 when at
#   least one did. For a caller that must DELETE the line (unclaim, the `projects list` remediation): the raw
#   text is what a line-anchored `sed` removes, and it can differ from <path> -- a comment, quotes,
#   or a symlinked spelling -- so reconstructing the line from <path> would fail to match.
ai_tools_conf_allowlist_matching_lines() {
    local -n _ai_tools_conf_matched="$1"
    local file="$2" want line entry
    want="$(_ai_tools_conf_allowlist_norm "$3")"
    _ai_tools_conf_matched=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
        ai_tools_conf_path_entry "${line}" || continue
        entry="${_ai_tools_conf_value}"
        [[ "${entry}" == '!'* ]] && continue
        [[ "$(_ai_tools_conf_allowlist_norm "${entry}")" == "${want}" ]] && _ai_tools_conf_matched+=("${line}")
    done < "${file}"
    (( ${#_ai_tools_conf_matched[@]} > 0 ))
}

# ai_tools_conf_allowlist_exclusion_lines <array-name> <allowlist-file> <path> : the exclusion
#   counterpart of the allow matcher -- set the named array to every RAW line whose `!` entry names
#   <path> exactly (compared without the `!`), and return 0 when at least one did. Exact-path like
#   ai_tools_conf_allowlist_has_exclusion, never glob-expanding: it serves the callers that must
#   EDIT the line an operator wrote to park a project (the CLI's re-enable, its de-registration,
#   and the `--for` root helper), and a glob line does not name a single project to act on.
ai_tools_conf_allowlist_exclusion_lines() {
    local -n _ai_tools_conf_excluded="$1"
    local file="$2" want line entry
    want="$(_ai_tools_conf_allowlist_norm "$3")"
    _ai_tools_conf_excluded=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
        ai_tools_conf_path_entry "${line}" || continue
        entry="${_ai_tools_conf_value}"
        [[ "${entry}" == '!'* ]] || continue
        [[ "$(_ai_tools_conf_allowlist_norm "${entry#\!}")" == "${want}" ]] && _ai_tools_conf_excluded+=("${line}")
    done < "${file}"
    (( ${#_ai_tools_conf_excluded[@]} > 0 ))
}

# ── Allowlist editing (the one implementation of a registry change) ──────────────────────────
# An allowed-projects line has four states to move between -- absent, listed, disabled (a `!` exclusion parks it),
# and gone -- and three components change one: the CLI on the operator's own file, ai-tools-allowlist on another
# operator's (a `--for` run), and install.sh de-registering its own checkout. All three write through these functions,
# so one matcher decides what a line names for every writer and every reader. The file is the agent's LAUNCH GATE:
# a writer that matched lines differently from the reader would leave a project reachable after a "removal", or park it
# twice over.
#
# Every one of them is idempotent, verifies by RE-READING the file rather than trusting a write,
# and reports three outcomes apart:
#   0  the file now holds the intended state (including "it already did")
#   1  the edit could not be applied -- the file is missing or could not be written
#   2  the request does not apply from the CURRENT state, and no write happened
# The 2 cases are what keep the four states honest: adding over an exclusion would leave both lines
# present with the `!` still winning at the launch gate (a claim reporting success over a project
# no session can start in), and enabling or disabling a path the file does not name would invent an
# entry rather than edit one.

# _ai_tools_conf_replace_file <file> <src> : replace <file> with <src>'s contents, preserving
#   its owner and mode. Written beside it and renamed, so a concurrent reader (a launch wrapper
#   gating a session) sees the whole old file or the whole new one, never a half-written gate. The
#   temp file is created in the file's OWN directory, which is what a rename across it requires --
#   so this fails on a config directory the caller cannot write even when the file itself is
#   writable, and the callers report that rather than aborting on it. Shared by the allowlist
#   editors and by ai_tools_conf_set_key, the one rewrite of a KEY=value file.
_ai_tools_conf_replace_file() {
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

# ai_tools_conf_allowlist_state <allowlist-file> <path> : print how the file answers for <path> --
#   `disabled`, `listed`, or `absent`. An exclusion WINS over an allow entry, exactly as it does at
#   the launch gate, so a path carrying both lines reads `disabled`: no session can start there,
#   which makes it the only honest answer. This is the state a has_entry/absent reading cannot
#   express, and every verb that reports on a parked project reads it.
ai_tools_conf_allowlist_state() {
    local file="$1" path="$2"
    [[ -f "${file}" ]] || { printf 'absent'; return 0; }
    if   ai_tools_conf_allowlist_has_exclusion "${file}" "${path}"; then printf 'disabled'
    elif ai_tools_conf_allowlist_has_entry     "${file}" "${path}"; then printf 'listed'
    else printf 'absent'
    fi
}

# ai_tools_conf_allowlist_add <allowlist-file> <path> : append <path> as an allow entry, on a line
#   of its own. A path already listed is left alone (a re-claim must not duplicate a line); a
#   DISABLED path is refused with 2 rather than appended, because the appended line would not take
#   effect.
ai_tools_conf_allowlist_add() {
    local file="$1" path="$2" line_break=''
    [[ -f "${file}" ]] || return 1
    case "$(ai_tools_conf_allowlist_state "${file}" "${path}")" in
        listed)   return 0 ;;
        disabled) return 2 ;;
    esac
    # A hand-edited registry can run to EOF part-way through its last line, and every reader here keeps that entry (the
    # read loops take a final unbroken line). So the append opens a new line first: written straight, it would join
    # the two paths into a third that no project matches, dropping the claimed one from the launch gate while
    # the preceding entry changed meaning.
    [[ -n "$(tail -c 1 -- "${file}" 2>/dev/null)" ]] && line_break=$'\n'
    printf '%s%s\n' "${line_break}" "${path}" >> "${file}" 2>/dev/null || return 1
    ai_tools_conf_allowlist_has_entry "${file}" "${path}" || return 1
}

# ai_tools_conf_allowlist_remove <allowlist-file> <path> : delete every line naming <path>, allow
#   and exclusion alike, because a de-registration that left the `!` behind would park a directory
#   that no longer exists -- and silently disable the next project claimed at that path.
#   Removing what is not there succeeds: an unclaim run twice is not an error.
ai_tools_conf_allowlist_remove() {
    local file="$1" path="$2" tmp line keep m
    # Names distinct from any scalar a sibling library uses: every consumer sources this file, and an array here sharing
    # a name with a local there reads as a type conflict at lint time.
    local -a doomed_lines=() parked_lines=()
    [[ -f "${file}" ]] || return 0
    ai_tools_conf_allowlist_matching_lines  doomed_lines "${file}" "${path}" || true
    ai_tools_conf_allowlist_exclusion_lines parked_lines "${file}" "${path}" || true
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
    if ! _ai_tools_conf_replace_file "${file}" "${tmp}"; then rm -f -- "${tmp}"; return 1; fi
    rm -f -- "${tmp}"
    [[ "$(ai_tools_conf_allowlist_state "${file}" "${path}")" == absent ]] || return 1
}

# _ai_tools_conf_allowlist_retag <allowlist-file> <path> <disable|enable> : the shared line rewrite
#   behind the two verbs. It edits the line the operator wrote IN PLACE -- the `!` goes on or
#   comes off, and the line keeps its position, its indentation and its comment -- so parking a
#   project and restoring it leaves the file as it was, rather than moving the entry to the end.
_ai_tools_conf_allowlist_retag() {
    local file="$1" path="$2" op="$3" tmp line m head
    [[ -f "${file}" ]] || return 1
    local -a retag_lines=()
    if [[ "${op}" == disable ]]; then
        ai_tools_conf_allowlist_matching_lines  retag_lines "${file}" "${path}" || return 2
    else
        ai_tools_conf_allowlist_exclusion_lines retag_lines "${file}" "${path}" || return 2
    fi
    # ENABLE additionally collapses duplicates. Un-parking `!/p` while an allow line for `/p` already exists -- the pair
    # the old "append over an exclusion" bug created -- would leave two live entries for one path. So the FIRST line
    # naming the path survives, un-parked, in its own position, and every later line naming it is dropped: one live
    # entry per path, which is the invariant every reader of this file assumes. DISABLE does not need that rule, since
    # parking each of several allow lines leaves them all excluded, which is one state and not two.
    local -a live_lines=()
    if [[ "${op}" == enable ]]; then
        ai_tools_conf_allowlist_matching_lines live_lines "${file}" "${path}" || true
        retag_lines+=("${live_lines[@]}")
    fi
    local emitted=false
    tmp="$(mktemp 2>/dev/null)" || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        for m in "${retag_lines[@]}"; do
            [[ "${line}" == "${m}" ]] || continue
            if [[ "${op}" == disable ]]; then
                # Insert the '!' before the first non-blank character, so an indented entry keeps its indentation
                # and the '!' still opens the entry the grammar reads.
                head="${line%%[![:space:]]*}"
                line="${head}!${line#"${head}"}"
            elif ${emitted}; then
                continue 2                      # a later duplicate of a path already restored
            else
                # Delete the FIRST '!' -- the one that opens the entry. One in a trailing comment is left alone. A line
                # that carries none is already the allow entry and is kept as it is.
                line="${line/'!'/}"
                emitted=true
            fi
            break
        done
        printf '%s\n' "${line}"
    done < "${file}" > "${tmp}"
    if ! _ai_tools_conf_replace_file "${file}" "${tmp}"; then rm -f -- "${tmp}"; return 1; fi
    rm -f -- "${tmp}"
}

# ai_tools_conf_allowlist_disable <allowlist-file> <path> : park a listed project -- prefix its
#   line with `!`. The launch gate then refuses a session there while the entry, the project's
#   permissions and its label all stay as they are. Already disabled succeeds; a path the file does
#   not name returns 2, since there is no entry to park.
ai_tools_conf_allowlist_disable() {
    local file="$1" path="$2" rc
    case "$(ai_tools_conf_allowlist_state "${file}" "${path}")" in
        disabled) return 0 ;;
        absent)   return 2 ;;
    esac
    _ai_tools_conf_allowlist_retag "${file}" "${path}" disable || { rc=$?; return "${rc}"; }
    [[ "$(ai_tools_conf_allowlist_state "${file}" "${path}")" == disabled ]] || return 1
}

# ai_tools_conf_allowlist_enable <allowlist-file> <path> : restore a parked project -- delete the
#   `!` from its line. Already listed succeeds; a path the file does not name returns 2, because
#   enabling one would be claiming it, which is a different operation with a secret scan in it.
ai_tools_conf_allowlist_enable() {
    local file="$1" path="$2" rc
    case "$(ai_tools_conf_allowlist_state "${file}" "${path}")" in
        listed) return 0 ;;
        absent) return 2 ;;
    esac
    _ai_tools_conf_allowlist_retag "${file}" "${path}" enable || { rc=$?; return "${rc}"; }
    [[ "$(ai_tools_conf_allowlist_state "${file}" "${path}")" == listed ]] || return 1
}

# ── Seed text for an operator's own config files ──────────────────────────────────────────────
# A file an operator keeps in ~/.config/ai-tools is created carrying its header and no entry, so the operator edits
# a file that states what it is rather than a blank one. The text lives here because it is written from more than one
# place -- `ai-tools-admin operators add` on any installed host, and install.sh for the account a from-source install
# enrols -- and a header written twice is a header that disagrees with itself about what the file accepts. Each function
# PRINTS; the caller places the file with the ownership and mode it needs (600, inside a 700
# directory).
#
# A seeded header is written once and no upgrade rewrites it, so it carries what the file is, the one rule a reader
# needs before writing a line, example lines, and the man page that holds the reference -- the page ships
# with the package and reaches every host on every upgrade, where a header stays as it was on the day the account was
# enrolled. tests/unit/man.sh caps the allowlist header and reads the page's examples through ai_tools_conf_path_entry.

# ai_tools_conf_allowlist_seed : print the header a fresh allowed-projects carries. It does not
#   name any project, so a session cannot start anywhere until the CLI or the operator adds an
#   entry. The reference is ai-tools-allowed-projects(5).
ai_tools_conf_allowlist_seed() {
    printf '%s\n' \
        "# Project directories the ai-tools sandbox may work in, one per line." \
        "# A session launched by this account starts only inside a listed" \
        "# directory; a '!'-prefixed line excludes a subtree, and an exclusion" \
        "# wins. This file is a launch gate, not a read boundary." \
        "#" \
        "#   /home/op/project              allow it and everything under it" \
        "#   !/home/op/project/vendor      carve this subtree out of it" \
        "#   \"/home/op/ai works\"  # note   quote a path containing a space;" \
        "#                                 '#' starts a comment" \
        "#" \
        "# Managed by the ai-tools CLI: projects claim, projects create and" \
        "# projects clone register a project; projects disable and projects" \
        "# enable park and restore one; projects list reviews the file." \
        "# Full reference: man 5 ai-tools-allowed-projects" \
        ""
}

# ai_tools_conf_secret_patterns_seed : print the header a fresh secret-patterns file carries. It
#   carries the header alone, which leaves the built-in baseline in secret-patterns.lib.sh in
#   force -- so seeding this file changes what is classified as a secret only once the operator
#   writes a pattern into it. The replace rule stays in the header whatever the page says, since
#   it is the one fact a reader needs before writing a line. The reference is ai-tools-secret-patterns(5).
ai_tools_conf_secret_patterns_seed() {
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

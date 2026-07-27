#!/usr/bin/env bash
# /usr/local/lib/ai-tools/conf.lib.sh
# The one KEY=value grammar every ai-tools config file is read with, plus the trust predicate
# that decides whether a file may be read at all. Sourced (never executed) by operator.lib.sh,
# skip-dirs.lib.sh, and providers.lib.sh, so /etc/ai-tools/operator.conf and the provider
# manifests parse identically no matter which component reads them and the grammar cannot drift
# between consumers.
#
# Config files are PARSED, never sourced: a malformed or tampered file yields a bad value, never
# executed code in a privileged script.
#
# ── Grammar ──────────────────────────────────────────────────────────────────────────────────
# One `KEY=value` per line, the conventional shape of a shell-style config:
#
#   KEY=value                  bare value; no quotes needed
#   KEY = value                whitespace around the key and the `=` is trimmed
#   KEY="a b"  /  KEY='a b'    one optional layer of matched quotes, stripped
#   KEY=a, b  c , d            list separators are commas AND whitespace, freely mixed;
#                              runs collapse and empty items are dropped
#   KEY=value   # why          an inline comment: `#` at the start of the value, or following
#                              whitespace, ends it. Inside quotes `#` is literal, so a value
#                              that must contain one is written KEY="a#b"
#   # comment                  a whole-line comment
#   KEY=                       PRESENT with an empty value -- distinct from an absent key, which
#                              is the distinction the fail-closed provider gating turns on
#
# A repeated key takes its LAST assignment. A line with no `=` is ignored.
#
# ── IFS independence ─────────────────────────────────────────────────────────────────────────
# List splitting sets IFS locally, so a value splits into the same items regardless of the IFS
# the sourcing script runs under. Scripts here legitimately set `IFS=$'\n\t'` (the strict-mode
# idiom); a splitter inheriting that would silently read "a b" as ONE item, and for the provider
# allowlists that reads as "no such provider" -- a fail-closed but wrong verdict.
#
# ── Trust ────────────────────────────────────────────────────────────────────────────────────
# ai_tools_conf_is_trusted gates a file (or directory) the sandbox account must not be able to
# influence. It is the predicate behind the security invariant that the agent cannot widen its
# own surface: the provider manifests and their directories, operator.conf, and the session-env
# fragments all decide what a session gets, so each is honored only while it is root-owned and
# not group- or other-writable. See providers.rule.md.

# Sourced more than once in a single shell: the readonly below would abort under set -e on the
# second pass. Return early (an if-statement, not `[[ ]] && return`, which returns 1 for an unset
# guard and trips the sourcing shell's set -e).
if [[ -n "${_AI_TOOLS_CONF_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_CONF_LIB=1

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
#   silently truncating the value at some later character.
_ai_tools_conf_parse_value() {
    local value="$1" quote rest
    value="${value#"${value%%[![:space:]]*}"}"
    case "${value}" in
        '"'*) quote='"' ;;
        "'"*) quote="'" ;;
        *)    quote=''  ;;
    esac
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
#   caller's IFS.
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
#   default and calls this, and a config that says nothing about the key keeps that default.
ai_tools_conf_list() {
    local out_name="$1" file="$2" key="$3"
    ai_tools_conf_read "${file}" "${key}" || return 1
    ai_tools_conf_split "${out_name}" "${_ai_tools_conf_value}"
}

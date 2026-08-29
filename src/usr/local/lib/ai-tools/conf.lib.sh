#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
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

# ── Sidecar files: what an upgrade preserves when it touches an operator's config ────────────
# An install that rewrites a config the operator owns leaves two kinds of copy behind, and they
# answer different questions -- neither substitutes for the other:
#
#   <name>.<YYYYMMDD>.bak       what the operator HAD. The only thing that restores their
#                               settings if a rewrite is valid but wrong, which no syntax check
#                               catches. Written only when a file is actually about to change.
#   <name>.<YYYYMMDD>.shipped   what they were SUPPOSED to get. Written when the merge could not
#                               run, or when the file is one this project refuses to rewrite
#                               unattended, so the hand merge has a source -- a host installed
#                               from the RPM has no checkout to copy from.
#
# The date stamp makes them survive successive runs: each install adds a copy rather than
# overwriting the evidence of the last. A same-day second copy takes a `-N` counter, so a .bak
# is never overwritten -- an operator who ran the installer twice in a day is exactly the one
# who needs the first copy.

# ai_tools_conf_sidecar_path <path> <kind> : print an UNUSED sidecar path for <path>. Returns 1
#   without printing when the day's namespace is exhausted, so a caller never silently reuses a
#   name. Pure except for the existence tests. Public because it is the single home of the
#   `<path>.<YYYYMMDD>[-N].<kind>` convention: managed-assets.lib.sh stamps a replaced shipped
#   asset the same way this file stamps a replaced config, and <path> may be a directory there.
ai_tools_conf_sidecar_path() {
    local file="$1" kind="$2" stamp candidate index
    stamp="$(date +%Y%m%d)" || return 1
    candidate="${file}.${stamp}.${kind}"
    [[ -e "${candidate}" ]] || { printf '%s' "${candidate}"; return 0; }
    for (( index = 2; index < 100; index++ )); do
        candidate="${file}.${stamp}-${index}.${kind}"
        [[ -e "${candidate}" ]] || { printf '%s' "${candidate}"; return 0; }
    done
    return 1
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
#   file the operator has to re-permission. Returns 1 printing nothing when no copy was made.
ai_tools_conf_backup() {
    local file="$1" target
    [[ -f "${file}" ]] || return 1
    target="$(ai_tools_conf_sidecar_path "${file}" bak)" || return 1
    cp -p "${file}" "${target}" 2>/dev/null || return 1
    printf '%s' "${target}"
}

# ai_tools_conf_reference <deployed> <shipped> : copy the <shipped> baseline next to <deployed>
#   as a fresh dated .shipped and print that path. The copy takes the DEPLOYED file's owner and
#   mode, not the source tree's. Returns 1 printing nothing when no copy was made.
ai_tools_conf_reference() {
    local deployed="$1" shipped="$2" target
    [[ -f "${shipped}" ]] || return 1
    target="$(ai_tools_conf_sidecar_path "${deployed}" shipped)" || return 1
    cp "${shipped}" "${target}" 2>/dev/null || return 1
    _ai_tools_conf_match_perms "${target}" "${deployed}"
    printf '%s' "${target}"
}

# ai_tools_conf_require_jq : succeed when jq is callable. jq is a package dependency, so its
#   absence is a broken install rather than a host variation -- this reports and fails instead of
#   degrading, and callers of the JSON paths below gate on it. Deliberately NOT checked when this
#   library is sourced: the KEY=value grammar above needs no jq, and this file is sourced on every
#   launch (by ai-tools-run, as the sandbox account) and by every root helper, so a source-time
#   failure would stop a session for a reason unrelated to what it asked for.
ai_tools_conf_require_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    printf 'conf: jq not found -- it is a package dependency; reinstall ai-tools-base\n' >&2
    return 1
}

# ── JSON hook declarations ───────────────────────────────────────────────────────────────────
# An agent's settings file is kept across an upgrade, because it carries host tuning a reset
# would revert. Its HOOK DECLARATIONS are not tuning though: they are control plane that merges
# additively and that no lower-precedence layer may remove, so a version that ships a new hook
# has to get that declaration into a kept file or the hook it installed never runs.
#
# The merge adds only declarations the file lacks and leaves every other key -- the permission
# arrays it was kept for, an operator's own hook -- as written. Reporting is the caller's: this
# sets what happened and returns how it went, so the same decision can be rendered by an
# installer, a test, or a future agent's tooling without the wording living here.

# The shipped hook commands a deployed file does not declare, as "<event>: <command>". The
# command binds to $command before the membership test: inside index(), `.` is that function's
# own input -- the $have array -- so an unbound form asks whether the array contains itself and
# reports nothing wherever the event already declares a hook.
# shellcheck disable=SC2016  # jq variables, bound by --slurpfile and jq's own `as`
readonly _AI_TOOLS_CONF_HOOKS_MISSING_FILTER='
    . as $cur
    | ($shipped[0].hooks // {}) | to_entries[] as $event
    | ([ (($cur.hooks // {})[$event.key] // [])[] | (.hooks // [])[] | .command ]) as $have
    | $event.value[] | (.hooks // [])[] | .command as $command
    | select(($have | index($command)) == null)
    | "\($event.key): \($command)"'

# Append whole matcher groups whose commands are absent, so a group arrives with its matcher
# intact; a group already fully declared is left alone.
# shellcheck disable=SC2016  # jq variables, as above
readonly _AI_TOOLS_CONF_HOOKS_MERGE_FILTER='
    ($shipped[0].hooks // {}) as $ship
    | reduce ($ship | to_entries[]) as $event (
        .;
        ([ ((.hooks // {})[$event.key] // [])[] | (.hooks // [])[] | .command ]) as $have
        | reduce ($event.value[]) as $group (
            .;
            if ((([ ($group.hooks // [])[] | .command ]) - $have) | length) == 0
            then .
            else .hooks[$event.key] = ((.hooks[$event.key] // []) + [$group])
            end
          )
      )'

# ai_tools_conf_merge_hook_declarations <deployed> <shipped> : merge the shipped hook
#   declarations into <deployed>.
#     returns 0  merged      _ai_tools_conf_merge_added holds "<event>: <command>" per addition,
#                            _ai_tools_conf_merge_backup the copy of what the operator had
#     returns 1  no change   the file already declares everything shipped; nothing written
#     returns 2  refused     the file is byte-identical and _ai_tools_conf_merge_reference holds
#                            the baseline dropped for a hand merge (empty if even that failed);
#                            _ai_tools_conf_merge_reason says which check refused
#   The deployed file is never opened for writing: the merge is built in a temporary file and
#   validated as JSON before an atomic rename, so a failure at any point leaves the original.
ai_tools_conf_merge_hook_declarations() {
    local deployed="$1" shipped="$2" missing="" tmp=""
    _ai_tools_conf_merge_added=()
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
    [[ -n "${missing}" ]] || return 1

    tmp="$(mktemp "${deployed}.XXXXXX" 2>/dev/null)" || { _refuse "no temporary file could be created"; return 2; }
    if ! jq --slurpfile shipped "${shipped}" \
            "${_AI_TOOLS_CONF_HOOKS_MERGE_FILTER}" "${deployed}" > "${tmp}" 2>/dev/null \
            || ! jq -e . "${tmp}" >/dev/null 2>&1; then
        rm -f "${tmp}"
        _refuse "the merged result was not valid JSON"
        return 2
    fi

    # Keep what the operator had before replacing it: this is the only copy that restores host
    # tuning if a merge is valid JSON yet wrong, which the check above cannot catch.
    _ai_tools_conf_merge_backup="$(ai_tools_conf_backup "${deployed}")" || true
    _ai_tools_conf_match_perms "${tmp}" "${deployed}"
    mv -f "${tmp}" "${deployed}" || { rm -f "${tmp}"; _refuse "the merged file could not be moved into place"; return 2; }

    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && _ai_tools_conf_merge_added+=("${line}")
    done <<< "${missing}"
    return 0
}

# ── KEY=value files: report new keys, never rewrite ──────────────────────────────────────────
# A KEY=value config is mostly DOCUMENTATION -- commented option blocks explaining each key --
# and an operator's copy is kept across an upgrade, so a key a new version introduces arrives
# nowhere. The consequence differs from the JSON case and so does the treatment: with the
# present/absent grammar an absent key already means its default, so what a stale file loses is
# the operator's chance to KNOW the option exists, not the behaviour.
#
# That is why these are reported and never merged. Splicing a commented block into a file whose
# layout, ordering and local annotations are the operator's would rewrite prose for a
# discoverability gain, and a file that carries the launch allowlist or the operator list is the
# last one to edit unattended. The caller names the new keys and drops the shipped baseline
# beside the file; the operator merges what they want.

# ai_tools_conf_keys <array-name> <file> : set the named array to every KEY this file mentions,
#   whether the key is live or written as a commented-out default (`#KEY=` / `# KEY =`). Both
#   forms count as "mentioned", which is the point: a key an operator has deliberately commented
#   out is one they have already seen, so re-announcing it every upgrade would be noise. A comment
#   indented further than one space is prose, not a default, and mentions nothing (below).
ai_tools_conf_keys() {
    local -n _ai_tools_conf_keys_out="$1"
    local file="$2" line key
    _ai_tools_conf_keys_out=()
    [[ -r "${file}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"       # strip leading whitespace
        if [[ "${line}" == \#* ]]; then
            line="${line#\#}"                         # a commented default is still a mention
            # ...but only when written hard against the `#` or one space in. A comment indented
            # further is illustrative prose: operator.conf's header documents the grammar with
            # lines like `#   KEY=value`, so counting those would make the minimally seeded file
            # `ai-tools-admin operator add` writes report every documented key as new.
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

# ── Path-list files (allowed-projects) ───────────────────────────────────────────────────────
# The launch allowlist is one path per line rather than KEY=value, but it is read with the SAME
# rules as everything else: a whole-line or end-of-line `#` comment, and one matched quote layer
# for a path that must contain a space or a literal `#`. Sharing the grammar is the point --
# four components parse this file (the launch wrapper, the CLI, the chown helper, and the relabel
# helper), and a rule that lives in each of them separately is a rule that drifts.
#
#   /home/me/project              a path
#   /home/me/project   # why      an end-of-line comment: `#` after whitespace ends the entry
#   "/home/me/my project"         quotes carry a space, and make `#` inside them literal
#   !/home/me/project/vendor      an exclusion; the `!` precedes the quotes: !"/a b"
#
# An entry is NOT resolved or validated here: callers canonicalize with realpath and match
# exclusions as globs, and this only decides what text the line denotes.

# ai_tools_conf_path_entry <line> : set _ai_tools_conf_value to the entry <line> denotes and
#   return 0; return 1 for a line that carries no entry (blank, or a whole-line comment), which
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
# One predicate for "is this path an entry of allowed-projects", shared by every component that
# asks: the launch wrapper's post-claim confirm, the claim/unclaim CLI (reg/unreg, project_state),
# and the relabel helper. They read the file through the grammar above, so an entry written in
# that grammar -- an end-of-line comment (`/p   # why`), a quoted path (`"/p with space"`), or a
# spelling reached by a symlink or trailing slash -- is a MATCH here, where a raw `grep -qxF`
# against the stored line would miss it and report the project unlisted. Comparison is on
# realpath-normalized values, the same canonicalization the launch gate applies, so the confirm
# and the gate agree. A stored entry that no longer resolves cannot equal an existing target and
# is skipped (the launch wrapper drops unresolvable entries the same way). Callers pass an
# existing path (a realpath'd project dir); membership of a non-existent path is never asserted.

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
#   least one did. For a caller that must DELETE the line (unclaim, the --list remediation): the raw
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
#   counterpart of the matcher above -- set the named array to every RAW line whose `!` entry names
#   <path> exactly (compared without the `!`), and return 0 when at least one did. Exact-path like
#   ai_tools_conf_allowlist_has_exclusion, never glob-expanding: it serves the callers that must
#   EDIT the line an operator wrote to park a project (the CLI's re-enable, its de-registration,
#   and the --for root helper), and a glob line names no single project to act on.
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
# An allowed-projects line has four states to move between -- absent, listed, disabled (a `!`
# exclusion parks it), and gone -- and three components change one: the CLI on the operator's own
# file, ai-tools-allowlist on another operator's (a `--for` run), and install.sh de-registering its
# own checkout. Each used to carry its own edit: an append here, a `sed -i` line-deletion there, a
# read-transform-rename in the third, with their own escaping and their own idea of what a match
# is. That is the drift this section removes -- the file is the agent's LAUNCH GATE, so a writer
# that matches lines differently from the reader is a project that stays reachable after a
# "removal", or one parked twice over.
#
# Every function below is idempotent, verifies by RE-READING the file rather than trusting a write,
# and reports three outcomes apart:
#   0  the file now holds the intended state (including "it already did")
#   1  the edit could not be applied -- the file is missing or could not be written
#   2  the request does not apply from the CURRENT state, and nothing was written
# The 2 cases are what keep the four states honest: adding over an exclusion would leave both lines
# present with the `!` still winning at the launch gate (a claim reporting success over a project
# no session can start in), and enabling or disabling a path the file does not name would invent an
# entry rather than edit one.

# _ai_tools_conf_allowlist_write <file> <src> : replace <file> with <src>'s contents, preserving
#   its owner and mode. Written beside it and renamed, so a concurrent reader (a launch wrapper
#   gating a session) sees the whole old file or the whole new one, never a half-written gate. The
#   temp file is created in the file's OWN directory, which is what a rename across it requires --
#   so this fails on a config directory the caller cannot write even when the file itself is
#   writable, and the callers report that rather than aborting on it.
_ai_tools_conf_allowlist_write() {
    local file="$1" src="$2" tmp owner mode
    owner="$(stat -c '%U:%G' "${file}" 2>/dev/null || true)"
    mode="$(stat -c '%a' "${file}" 2>/dev/null || true)"
    tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 1
    if ! cat -- "${src}" > "${tmp}" 2>/dev/null; then rm -f -- "${tmp}"; return 1; fi
    # Best-effort metadata: a root writer restores another operator's ownership, an unprivileged
    # one is already writing as the owner. A mode that will not apply is worth failing over --
    # this file is 0600 by design and a widened one exposes an operator's project list.
    [[ -n "${owner}" ]] && chown "${owner}" "${tmp}" 2>/dev/null
    if [[ -n "${mode}" ]] && ! chmod "${mode}" "${tmp}" 2>/dev/null; then rm -f -- "${tmp}"; return 1; fi
    mv -f -- "${tmp}" "${file}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
}

# ai_tools_conf_allowlist_state <allowlist-file> <path> : print how the file answers for <path> --
#   `disabled`, `listed`, or `absent`. An exclusion WINS over an allow entry, exactly as it does at
#   the launch gate, so a path carrying both lines reads `disabled`: no session can start there,
#   which makes it the only honest answer. This is the third state the has_entry/absent reading
#   could not express, and every verb that used to call a parked project "not claimed" reads it.
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
    # A hand-edited registry can run to EOF part-way through its last line, and every reader here
    # keeps that entry (the read loops take a final unbroken line). So the append opens a new line
    # first: written straight, it would join the two paths into a third that names no project,
    # dropping the claimed one from the launch gate while the entry above it changed meaning.
    [[ -n "$(tail -c 1 -- "${file}" 2>/dev/null)" ]] && line_break=$'\n'
    printf '%s%s\n' "${line_break}" "${path}" >> "${file}" 2>/dev/null || return 1
    ai_tools_conf_allowlist_has_entry "${file}" "${path}" || return 1
}

# ai_tools_conf_allowlist_remove <allowlist-file> <path> : delete every line naming <path>, allow
#   and exclusion alike. Both, because a de-registration that left the `!` behind would park a
#   directory that no longer exists -- and silently disable the next project claimed at that path.
#   Removing what is not there succeeds: an unclaim run twice is not an error.
ai_tools_conf_allowlist_remove() {
    local file="$1" path="$2" tmp line keep m
    # Names distinct from any scalar a sibling library uses: every consumer sources this file, and
    # an array here sharing a name with a local there reads as a type conflict at lint time.
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
    if ! _ai_tools_conf_allowlist_write "${file}" "${tmp}"; then rm -f -- "${tmp}"; return 1; fi
    rm -f -- "${tmp}"
    [[ "$(ai_tools_conf_allowlist_state "${file}" "${path}")" == absent ]] || return 1
}

# _ai_tools_conf_allowlist_retag <allowlist-file> <path> <disable|enable> : the shared line rewrite
#   behind the two verbs below. It edits the line the operator wrote IN PLACE -- the `!` goes on or
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
    # ENABLE additionally collapses duplicates. Un-parking `!/p` while an allow line for `/p`
    # already exists -- the pair the old "append over an exclusion" bug created -- would leave two
    # live entries for one path. So the FIRST line naming the path survives, un-parked, in its own
    # position, and every later line naming it is dropped: one live entry per path, which is the
    # invariant every reader of this file assumes. DISABLE needs no such rule, since parking each
    # of several allow lines leaves them all excluded, which is one state and not two.
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
                # Insert the '!' before the first non-blank character, so an indented entry keeps
                # its indentation and the '!' still opens the entry the grammar reads.
                head="${line%%[![:space:]]*}"
                line="${head}!${line#"${head}"}"
            elif ${emitted}; then
                continue 2                      # a later duplicate of a path already restored
            else
                # Delete the FIRST '!' -- the one that opens the entry. One in a trailing comment
                # is left alone. A line that carries none is already the allow entry and is kept
                # as it is.
                line="${line/'!'/}"
                emitted=true
            fi
            break
        done
        printf '%s\n' "${line}"
    done < "${file}" > "${tmp}"
    if ! _ai_tools_conf_allowlist_write "${file}" "${tmp}"; then rm -f -- "${tmp}"; return 1; fi
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

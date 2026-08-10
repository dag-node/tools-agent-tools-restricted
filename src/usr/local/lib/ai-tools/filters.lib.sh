#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/filters.lib.sh
# Token-saving command filters: rewrite a Bash command so the tool itself produces less output,
# and strip terminal control noise from output the model is about to read. Sourced by an agent's
# hook adapter (Claude Code: agents/claude-code/filter-hook.sh), which supplies that agent's JSON
# hook contract; everything decided here is agent-agnostic.
#
# This is TOKEN ECONOMY, NOT A BOUNDARY. A rewrite decides how verbose a command is, never what
# the agent may run: the harness re-evaluates its own permission rules on the rewritten command,
# so a rewrite can neither reach past a deny rule nor silence a prompt. Every failure direction
# here -- an untrusted rules file, an unparseable line, a command the engine does not fully
# understand -- yields NO rewrite, which costs tokens and changes nothing else.
#
# ── Rules are data ───────────────────────────────────────────────────────────────────────────
# One rule set per package, /usr/local/lib/ai-tools/filters.d/<name>.rules, root-owned and
# PARSED, never sourced -- the same posture as the provider manifests. <name> is the token an
# operator writes in operator.conf AI_TOOLS_FILTERS. Four TAB-separated columns:
#
#   match       the literal leading words a command must start with ("git log")
#   action      args -- insert <payload> right after those words
#               wrap -- prepend <payload> as a wrapper command (rtk and the like)
#   blocking    words that cancel the rule when the command already carries one, so a rule never
#               overrides a flag the agent chose; commas and whitespace both separate, and a
#               lone `-` means "nothing blocks this rule"
#   payload     verbatim shell text, inserted as written -- root-owned data, so unlike the
#               agent's command it may carry quotes
#
# `#` begins a whole-line comment. A line with fewer than four columns is skipped.
#
# Payload placement is AFTER the matched words, never at the end: `git log -- src/x.c` would read
# an appended `--format=...` as a pathspec, and inserting keeps every rule clear of trailing
# pathspecs, `--`, and subcommand arguments generally.
#
# ── What may be rewritten ────────────────────────────────────────────────────────────────────
# A command is rewritten only when every character of it is in a small allowlist of letters,
# digits and `_ . / = : , + @ -` and space. Anything else -- a pipe, a redirect, a quote, a
# substitution, an escape, a glob, a newline -- passes through untouched, because inserting words
# into a command the engine has not fully parsed could change what it does. The allowlist governs
# the AGENT's command; a rule's payload is root-owned and is inserted verbatim.
#
# ── Which rule wins ──────────────────────────────────────────────────────────────────────────
# The applying rule with the most matched words, and on a tie the one loaded last. The base's own
# set (core.rules) loads first, so a provider's set can deliberately override a core rule -- how a
# wrapper like rtk takes over `git log` from the native rule.
#
# ── Enablement ───────────────────────────────────────────────────────────────────────────────
# operator.conf AI_TOOLS_FILTERS, in the shared grammar (conf.lib.sh):
#   key absent  -> every installed rule set (the default; filtering is on)
#   key present -> exactly the named sets; an EMPTY value is the kill switch, no filtering at all
#                  -- ai_tools_filter_enabled is that verdict, and an adapter gates its noise
#                  strip on it too, so the switch really does turn off every transform
# An untrusted operator.conf or filters.d is ignored, which likewise yields no filtering. Rule
# sets are not gated on provider enablement: a rule is inert unless the agent runs the command it
# matches, so the gate would buy nothing and this runs on every Bash call.

# Include guard: an if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and
# trips the sourcing shell's set -e.
if [[ -n "${_AI_TOOLS_FILTERS_LIB_LOADED:-}" ]]; then
    return 0
fi

# conf.lib.sh is REQUIRED: it carries the trust predicate that decides whether a rules file may be
# read at all, and the grammar AI_TOOLS_FILTERS is written in. Without it this file can neither
# tell a root-owned rule set from a planted one nor read the kill switch, so it defines NOTHING
# and returns non-zero -- the adapter's `source ... && declare -F` guard then filters nothing.
# shellcheck source=SCRIPTDIR/conf.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/conf.lib.sh" 2>/dev/null \
        || ! declare -F ai_tools_conf_is_trusted >/dev/null 2>&1 \
        || ! declare -F ai_tools_conf_list >/dev/null 2>&1; then
    return 1
fi
# Journald is where a tamper refusal belongs. Deliberately NOT stderr: this runs on every Bash
# call, and a per-call warning would flood the transcript with the tokens the feature exists to
# save. The deployed permissions are asserted by tests/integration/perms.sh and, as the agent, by
# tests/boundary/filters.sh.
# shellcheck source=SCRIPTDIR/log.lib.sh
source "${BASH_SOURCE[0]%/*}/log.lib.sh" 2>/dev/null || true

_AI_TOOLS_FILTERS_LIB_LOADED=1

# Deployed paths, overridable so tests drive a /tmp fixture tree without touching the real host.
# Unlike the same-named hooks in providers.lib.sh, these are readable by a caller inside a session
# (an agent's hook runs in the agent's own process, whose environment a project settings layer can
# add to), and they need no protection: an override chooses only WHERE to look, and every file
# found there still has to pass ai_tools_conf_is_trusted. Pointed anywhere the sandbox account can
# write, the directory or the file is refused and no rule loads, so the override reaches root-owned
# rules or none.
: "${AI_TOOLS_FILTERS_DIR:=/usr/local/lib/ai-tools/filters.d}"
: "${AI_TOOLS_OPERATOR_CONF:=/etc/ai-tools/operator.conf}"

# The characters a command may consist of to be eligible for rewriting. A positive allowlist, so
# a metacharacter nobody thought of is excluded by construction rather than by enumeration.
readonly _AI_TOOLS_FILTER_SAFE_COMMAND='^[A-Za-z0-9_./=:,+@ -]+$'

# The loaded rule set: one TAB-joined "match action blocking payload" record per rule, in load
# order. Populated by ai_tools_filter_rules_load, read by ai_tools_filter_rewrite.
_AI_TOOLS_FILTER_RULES=()

# _ai_tools_filter_log <message...> : record a refusal in journald when log.lib.sh loaded.
_ai_tools_filter_log() {
    declare -F ai_tools_log_warn >/dev/null 2>&1 && ai_tools_log_warn "filters: $*"
    return 0
}

# ai_tools_filter_command_is_simple <command> : succeed when <command> consists only of the
#   allowlisted characters, which is what makes inserting words into it safe. Pure, no I/O.
ai_tools_filter_command_is_simple() {
    [[ "${1-}" =~ ${_AI_TOOLS_FILTER_SAFE_COMMAND} ]]
}

# ai_tools_filter_apply_rule <command> <match> <action> <blocking> <payload> : set
#   _ai_tools_filter_result to the rewritten command and return 0 when the rule applies; return 1
#   leaving the result empty when it does not (the command does not start with <match>, it already
#   carries a blocking word, or <action> is not one this engine implements). Pure, no I/O --
#   unit-tested over the rule table.
ai_tools_filter_apply_rule() {
    local command="$1" match="$2" action="$3" blocking="$4" payload="$5"
    local -a command_words=() match_words=() blocking_tokens=()
    local IFS=' '
    _ai_tools_filter_result=""
    read -ra command_words <<< "${command}"
    read -ra match_words <<< "${match}"
    local match_length=${#match_words[@]}
    (( match_length > 0 && ${#command_words[@]} >= match_length )) || return 1

    local index
    for (( index = 0; index < match_length; index++ )); do
        [[ "${command_words[index]}" == "${match_words[index]}" ]] || return 1
    done

    # A blocking word cancels the rule, so the agent's own flag always wins over the rule's. Both
    # the bare word and its `word=value` form count, so --verbosity blocks --verbosity=quiet.
    ai_tools_conf_split blocking_tokens "${blocking}"
    local word token
    for word in "${command_words[@]:match_length}"; do
        for token in "${blocking_tokens[@]}"; do
            [[ "${token}" == '-' ]] && continue
            [[ "${word}" == "${token}" || "${word}" == "${token}="* ]] && return 1
        done
    done

    local head="${command_words[*]:0:match_length}"
    local tail="${command_words[*]:match_length}"
    case "${action}" in
        args) _ai_tools_filter_result="${head} ${payload}${tail:+ ${tail}}" ;;
        wrap) _ai_tools_filter_result="${payload} ${head}${tail:+ ${tail}}" ;;
        *)    return 1 ;;
    esac
    return 0
}

# _ai_tools_filter_load_file <file> : append every well-formed rule in <file> to
#   _AI_TOOLS_FILTER_RULES. A file that is not root-owned and non-group/other-writable is refused
#   whole: a rules file a non-root account can write decides what every command in a session
#   becomes.
_ai_tools_filter_load_file() {
    local file="$1"
    if ! ai_tools_conf_is_trusted "${file}"; then
        _ai_tools_filter_log "ignoring ${file}: not root-owned or writable by group/other"
        return 1
    fi
    local match action blocking payload
    while IFS=$'\t' read -r match action blocking payload || [[ -n "${match:-}" ]]; do
        [[ -z "${match}" || "${match}" == '#'* ]] && continue
        [[ -n "${action}" && -n "${blocking}" && -n "${payload}" ]] || continue
        _AI_TOOLS_FILTER_RULES+=("${match}"$'\t'"${action}"$'\t'"${blocking}"$'\t'"${payload}")
    done < "${file}"
    return 0
}

# _ai_tools_filter_installed_sets <array-name> : set the named array to every installed rule-set
#   name, the base's own set first so a provider's set can override one of its rules.
_ai_tools_filter_installed_sets() {
    local -n _ai_tools_filter_sets_out="$1"
    _ai_tools_filter_sets_out=()
    [[ -e "${AI_TOOLS_FILTERS_DIR}/core.rules" ]] && _ai_tools_filter_sets_out=(core)
    local rules_file set_name
    for rules_file in "${AI_TOOLS_FILTERS_DIR}"/*.rules; do
        [[ -e "${rules_file}" ]] || continue
        set_name="${rules_file##*/}"; set_name="${set_name%.rules}"
        [[ "${set_name}" == core ]] || _ai_tools_filter_sets_out+=("${set_name}")
    done
    return 0
}

# ai_tools_filter_enabled : succeed unless operator.conf carries AI_TOOLS_FILTERS with an EMPTY
#   value -- the kill switch. The rewrite path honors the switch by loading no rules; this is the
#   same verdict as a callable predicate, which an adapter gates its noise strip on, so the one
#   switch turns off every transform. A named list narrows which rule sets load, never this
#   verdict; an absent key, an absent conf, and an untrusted conf all leave filtering ON -- the
#   same fallback direction ai_tools_filter_rules_load takes, and still only ever a token cost.
ai_tools_filter_enabled() {
    local -a _ai_tools_filter_enabled_sets=()
    ai_tools_conf_is_trusted "${AI_TOOLS_OPERATOR_CONF}" || return 0
    ai_tools_conf_list _ai_tools_filter_enabled_sets "${AI_TOOLS_OPERATOR_CONF}" AI_TOOLS_FILTERS \
        || return 0
    (( ${#_ai_tools_filter_enabled_sets[@]} > 0 ))
}

# ai_tools_filter_rules_load : populate _AI_TOOLS_FILTER_RULES from the enabled rule sets. Returns
#   0 whether or not any rule loaded -- no rules simply means no rewriting.
ai_tools_filter_rules_load() {
    _AI_TOOLS_FILTER_RULES=()
    if ! ai_tools_conf_is_trusted "${AI_TOOLS_FILTERS_DIR}"; then
        [[ -e "${AI_TOOLS_FILTERS_DIR}" ]] && \
            _ai_tools_filter_log "ignoring ${AI_TOOLS_FILTERS_DIR}: not root-owned or writable by group/other"
        return 0
    fi

    # A present AI_TOOLS_FILTERS is the exact set (empty = the kill switch); absent, unreadable or
    # untrusted falls back to every installed set, which can only ever be root-owned rules.
    local -a rule_sets=()
    if ! ai_tools_conf_is_trusted "${AI_TOOLS_OPERATOR_CONF}" \
            || ! ai_tools_conf_list rule_sets "${AI_TOOLS_OPERATOR_CONF}" AI_TOOLS_FILTERS; then
        _ai_tools_filter_installed_sets rule_sets
    fi

    local set_name
    for set_name in "${rule_sets[@]}"; do
        # Allowlist the name before it becomes a path, as the manifest resolver does: rule-set
        # names are plain identifiers, so nothing here can address a file outside filters.d.
        [[ "${set_name}" =~ ^[A-Za-z0-9._-]+$ && "${set_name}" != *..* ]] || continue
        [[ -e "${AI_TOOLS_FILTERS_DIR}/${set_name}.rules" ]] || continue
        _ai_tools_filter_load_file "${AI_TOOLS_FILTERS_DIR}/${set_name}.rules" || true
    done
    return 0
}

# ai_tools_filter_rewrite <command> : print the rewritten command and return 0 when a loaded rule
#   applies and actually changes it; return 1 printing nothing otherwise (the pass-through case,
#   which is every failure direction). Call ai_tools_filter_rules_load first.
ai_tools_filter_rewrite() {
    local command="${1-}"
    [[ -n "${command}" ]] || return 1
    ai_tools_filter_command_is_simple "${command}" || return 1
    (( ${#_AI_TOOLS_FILTER_RULES[@]} > 0 )) || return 1

    local record match action blocking payload
    local best_result="" best_length=0
    local -a match_words=()
    local IFS=' '
    for record in "${_AI_TOOLS_FILTER_RULES[@]}"; do
        IFS=$'\t' read -r match action blocking payload <<< "${record}"
        read -ra match_words <<< "${match}"
        # Longest match wins; `>=` hands a tie to the later rule, which is how a provider set
        # overrides the core set it loads after.
        (( ${#match_words[@]} >= best_length )) || continue
        ai_tools_filter_apply_rule "${command}" "${match}" "${action}" "${blocking}" "${payload}" \
            || continue
        best_result="${_ai_tools_filter_result}"
        best_length=${#match_words[@]}
    done

    [[ -n "${best_result}" && "${best_result}" != "${command}" ]] || return 1
    printf '%s' "${best_result}"
}

# ai_tools_filter_strip_noise : copy stdin to stdout with terminal control noise removed -- ANSI
#   CSI and OSC sequences, stray escapes, and carriage-return redraws collapsed to the final state
#   a terminal would have shown. Byte-level noise only: no line is dropped, truncated, reordered
#   or summarized, so nothing the model would have read is lost. The one real cost is a line that
#   uses a carriage return as data rather than as a redraw (CR-only line endings), which keeps
#   only its last segment.
ai_tools_filter_strip_noise() {
    LC_ALL=C sed -E \
        -e 's|\x1b\[[0-9;:<=>?]*[ -/]*[@-~]||g' \
        -e 's|\x1b\][^\x07\x1b]*\x07||g' \
        -e 's|\x1b\][^\x07\x1b]*\x1b\\||g' \
        -e 's|\x1b||g' \
        -e 's|\r$||' \
        -e 's|.*\r||'
}

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/filters.sh
# Unit test for the token-saving command filters (filters.lib.sh). Drives the PURE verdicts --
# ai_tools_filter_command_is_simple and ai_tools_filter_apply_rule -- over their tables, then the
# loader and ai_tools_filter_rewrite over a /tmp fixture filters.d + operator.conf via the
# root-only AI_TOOLS_FILTERS_DIR / AI_TOOLS_OPERATOR_CONF hooks (the hermetic-override pattern
# providers.sh and skip-dirs.sh use).
#
# Filtering is token economy, not a boundary, so what this file pins is that every way a rule can
# fail to fit lands on PASS-THROUGH -- the command the agent wrote, unchanged. Three properties
# get their own section because a break in any of them is silent in production, and each would
# alter what a command DOES rather than how much it prints:
#   * SHAPE ALLOWLIST -- a command carrying a pipe, a redirect, a quote, a substitution or a glob
#     is not a single simple command, so inserting words into it could change what runs.
#   * THE AGENT'S FLAG WINS -- a rule cancels itself the moment the command already carries a
#     blocking word, so `git log --stat` is never rewritten into something that hides the patch.
#   * TAMPER REFUSAL -- a rules file or directory that is not root-owned and non-group/other-
#     writable is refused, because a writable rules file decides what every command becomes.
#
# No network, no session, no root risk.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/filters.lib.sh"
section "filters: command rewriting + output noise stripping (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "filters" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" \
        || ! declare -F ai_tools_filter_command_is_simple >/dev/null 2>&1 \
        || ! declare -F ai_tools_filter_apply_rule >/dev/null 2>&1 \
        || ! declare -F ai_tools_filter_rules_load >/dev/null 2>&1 \
        || ! declare -F ai_tools_filter_rewrite >/dev/null 2>&1 \
        || ! declare -F ai_tools_filter_strip_noise >/dev/null 2>&1 \
        || ! declare -F ai_tools_filter_enabled >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the filter functions"; finish; exit
fi

# --- Shape allowlist: which commands may be rewritten at all -----------------------------------
simple() {
    local desc="$1" exp_rc="$2" command="$3"
    local rc=0; ai_tools_filter_command_is_simple "${command}" || rc=$?
    if [[ "${rc}" -eq "${exp_rc}" ]]; then pass "${desc}"; else fail "${desc}: rc ${rc}, expected ${exp_rc}"; fi
}
simple "plain command is simple"                0 'git log'
simple "flags, paths and = are simple"          0 'dotnet build --nologo src/App.csproj -v:q'
simple "a pipeline is not"                      1 'git log | head -20'
simple "a redirect is not"                      1 'ls > out.txt'
simple "a command list is not"                  1 'git log; rm -rf x'
simple "a background job is not"                1 'git log & wait'
# shellcheck disable=SC2016  # the substitution metacharacters are the fixture; expanding them
# here would test a different string than the one the allowlist must reject
simple "a substitution is not"                  1 'git log $(cat x)'
# shellcheck disable=SC2016  # as above, the backquotes are the fixture
simple "a backquote is not"                     1 'git log `cat x`'
simple "a quote is not"                         1 "git log --grep='fix'"
simple "a glob is not"                          1 'ls src/*.sh'
simple "an escape is not"                       1 'git log \--stat'
simple "a newline is not"                       1 'git log
git status'
simple "empty is not"                           1 ''

# --- Pure rule application ---------------------------------------------------------------------
# ai_tools_filter_apply_rule <command> <match> <action> <blocking> <payload> -> _ai_tools_filter_result
# shellcheck disable=SC2154  # _ai_tools_filter_result is the rule engine's output variable, set
# by the sourced filters.lib.sh (which shellcheck cannot follow through the LIB path variable)
applies() {
    local desc="$1" expected="$2"; shift 2
    local rc=0; ai_tools_filter_apply_rule "$@" || rc=$?
    if [[ "${expected}" == PASSTHROUGH ]]; then
        if [[ "${rc}" -ne 0 ]]; then pass "${desc}"; else fail "${desc}: rewrote to '${_ai_tools_filter_result}', expected pass-through"; fi
    elif [[ "${rc}" -eq 0 && "${_ai_tools_filter_result}" == "${expected}" ]]; then
        pass "${desc}"
    else
        fail "${desc}: rc ${rc}, got '${_ai_tools_filter_result}', expected '${expected}'"
    fi
}
readonly LOG_BLOCK='--format,--pretty,--stat'
applies "args: payload lands after the matched words" \
    'git log --date=short -5'         'git log -5'          'git log' args "${LOG_BLOCK}" '--date=short'
applies "args: bare command takes the payload" \
    'git log --date=short'            'git log'             'git log' args "${LOG_BLOCK}" '--date=short'
applies "args: payload precedes a pathspec, never trails it" \
    'git log --date=short -- src/x.c' 'git log -- src/x.c'  'git log' args "${LOG_BLOCK}" '--date=short'
applies "args: payload may carry quotes -- it is root-owned data" \
    "git log --format='%h %s'"        'git log'             'git log' args "${LOG_BLOCK}" "--format='%h %s'"
applies "wrap: payload becomes the leading command" \
    'rtk git log -5'                  'git log -5'          'git log' wrap '-' 'rtk'
applies "blocking word cancels the rule -- the agent's flag wins" \
    PASSTHROUGH                       'git log --stat'      'git log' args "${LOG_BLOCK}" '--date=short'
applies "blocking word matches its key=value form too" \
    PASSTHROUGH                       'git log --format=%H' 'git log' args "${LOG_BLOCK}" '--date=short'
applies "a lone - blocks nothing" \
    'git log --date=short --stat'     'git log --stat'      'git log' args '-' '--date=short'
applies "a different command does not match" \
    PASSTHROUGH                       'git status'          'git log' args "${LOG_BLOCK}" '--date=short'
applies "a longer word is not a prefix match" \
    PASSTHROUGH                       'git logan'           'git log' args "${LOG_BLOCK}" '--date=short'
applies "the match must be complete" \
    PASSTHROUGH                       'git'                 'git log' args "${LOG_BLOCK}" '--date=short'
applies "an action this engine does not implement is refused" \
    PASSTHROUGH                       'git log'             'git log' pipe "${LOG_BLOCK}" 'rtk'

# --- Loader + rewrite over a /tmp fixture tree -------------------------------------------------
# Created by this root-run suite, so the fixtures are root-owned and non-group-writable: the
# trusted state. The tamper section below breaks that per case and restores it.
mktestdir
filters_dir="${TESTDIR}/filters.d"; mkdir -p "${filters_dir}"
export AI_TOOLS_FILTERS_DIR="${filters_dir}"
printf 'git log\targs\t--stat\t--date=short\ngit status\targs\t-s\t--short\n' > "${filters_dir}/core.rules"
printf '# a comment line\n\ndotnet build\targs\t-v\t--nologo -v q\n' > "${filters_dir}/dotnet.rules"
chown root:root "${filters_dir}"/*.rules; chmod 644 "${filters_dir}"/*.rules

# No operator.conf at all: the key is absent, so every installed rule set applies.
export AI_TOOLS_OPERATOR_CONF="${TESTDIR}/absent.conf"

rewrites() {
    local desc="$1" expected="$2" command="$3"
    local got="" rc=0
    got="$(ai_tools_filter_rewrite "${command}")" || rc=$?
    if [[ "${expected}" == PASSTHROUGH ]]; then
        if [[ "${rc}" -ne 0 && -z "${got}" ]]; then pass "${desc}"; else fail "${desc}: rewrote to '${got}', expected pass-through"; fi
    elif [[ "${rc}" -eq 0 && "${got}" == "${expected}" ]]; then
        pass "${desc}"
    else
        fail "${desc}: rc ${rc}, got '${got}', expected '${expected}'"
    fi
}

ai_tools_filter_rules_load
if [[ "${#_AI_TOOLS_FILTER_RULES[@]}" -eq 3 ]]; then
    pass "loader reads every installed rule set, skipping comments and blank lines"
else
    fail "loader read ${#_AI_TOOLS_FILTER_RULES[@]} rules, expected 3"
fi
rewrites "core rule applies"                'git log --date=short'          'git log'
rewrites "a provider's rule applies"        'dotnet build --nologo -v q'    'dotnet build'
rewrites "an unmatched command passes through" PASSTHROUGH                  'cargo build'
rewrites "a pipeline passes through"        PASSTHROUGH                     'git log | head'

# Longest match wins, and a provider set loaded after core overrides a core rule outright.
printf 'git\targs\t-\t--no-pager\ngit status\twrap\t-\trtk\n' > "${filters_dir}/zz-later.rules"
chown root:root "${filters_dir}/zz-later.rules"; chmod 644 "${filters_dir}/zz-later.rules"
ai_tools_filter_rules_load
rewrites "longest match wins over a shorter one" 'git log --date=short'     'git log'
rewrites "a later set overrides a core rule"     'rtk git status'           'git status'
rm -f "${filters_dir}/zz-later.rules"

# --- AI_TOOLS_FILTERS: the operator's switch ---------------------------------------------------
mk_operator     # writes TESTDIR/operator.conf and points the hook at it
set_filters() { printf 'AI_TOOLS_FILTERS=%s\n' "$1" >> "${AI_TOOLS_OPERATOR_CONF}"; }

set_filters '"core"'
ai_tools_filter_rules_load
rewrites "a named set applies"                    'git log --date=short'    'git log'
rewrites "a set left out of the list does not"    PASSTHROUGH               'dotnet build'

mk_operator; set_filters ''
ai_tools_filter_rules_load
if [[ "${#_AI_TOOLS_FILTER_RULES[@]}" -eq 0 ]]; then
    pass "an empty AI_TOOLS_FILTERS is the kill switch -- no rules load"
else
    fail "empty AI_TOOLS_FILTERS loaded ${#_AI_TOOLS_FILTER_RULES[@]} rules, expected 0"
fi
rewrites "kill switch leaves every command alone" PASSTHROUGH               'git log'

mk_operator; set_filters '"core nonexistent"'
ai_tools_filter_rules_load
rewrites "a named set with no installed file is skipped, not guessed" 'git log --date=short' 'git log'

# --- ai_tools_filter_enabled: the verdict the adapter's noise strip gates on -------------------
# The kill switch must turn off EVERY transform, so the adapter needs the switch as a callable
# verdict, not only as "no rules loaded". Every fallback direction reads enabled -- filtering is
# never more than a token cost, and the switch an untrusted conf carries is not honoured.
enabled_is() {
    local desc="$1" exp_rc="$2"
    local rc=0; ai_tools_filter_enabled || rc=$?
    if [[ "${rc}" -eq "${exp_rc}" ]]; then pass "${desc}"; else fail "${desc}: rc ${rc}, expected ${exp_rc}"; fi
}
export AI_TOOLS_OPERATOR_CONF="${TESTDIR}/absent.conf"
enabled_is "enabled when operator.conf is absent"          0
mk_operator
enabled_is "enabled when AI_TOOLS_FILTERS is absent"       0
set_filters '"core"'
enabled_is "enabled when sets are named"                   0
mk_operator; set_filters ''
enabled_is "the kill switch reports disabled"              1
chmod 666 "${AI_TOOLS_OPERATOR_CONF}"
enabled_is "an untrusted operator.conf leaves filtering on" 0
chmod 644 "${AI_TOOLS_OPERATOR_CONF}"

# --- Tamper refusal ----------------------------------------------------------------------------
# Each case breaks one input's trust, asserts the verdict moves to LESS filtering (never more or
# other), and restores it. This is the half that catches a host someone has already broken;
# tests/boundary/filters.sh is the half that catches the agent trying to break it.
mk_operator     # back to the no-AI_TOOLS_FILTERS baseline
untrusted() {
    local desc="$1" path="$2" mode="$3" owner="$4" restore_mode="$5" restore_owner="$6"
    chmod "${mode}" "${path}"; chown "${owner}" "${path}"
    ai_tools_filter_rules_load
    local rc=0; ai_tools_filter_rewrite 'git log' >/dev/null || rc=$?
    if [[ "${rc}" -ne 0 ]]; then pass "${desc}"; else fail "${desc}: still rewrote"; fi
    chmod "${restore_mode}" "${path}"; chown "${restore_owner}" "${path}"
}
untrusted "a group-writable rules file is refused" \
    "${filters_dir}/core.rules" 664 root:root 644 root:root
untrusted "a non-root-owned rules file is refused" \
    "${filters_dir}/core.rules" 644 "${PROJECTS_USER}:${PROJECTS_USER}" 644 root:root
untrusted "a group-writable filters.d is refused whole" \
    "${filters_dir}" 775 root:root 755 root:root
untrusted "a non-root-owned filters.d is refused whole" \
    "${filters_dir}" 755 "${PROJECTS_USER}:${PROJECTS_USER}" 755 root:root

# A symlinked rules file is refused rather than followed: a link planted in a writable directory
# would otherwise redirect the read at a file its planter chose.
mv "${filters_dir}/core.rules" "${TESTDIR}/real.rules"
ln -s "${TESTDIR}/real.rules" "${filters_dir}/core.rules"
ai_tools_filter_rules_load
rc=0; ai_tools_filter_rewrite 'git log' >/dev/null || rc=$?
if [[ "${rc}" -ne 0 ]]; then pass "a symlinked rules file is refused, not followed"; else fail "followed a symlinked rules file"; fi
rm -f "${filters_dir}/core.rules"; mv "${TESTDIR}/real.rules" "${filters_dir}/core.rules"

# An untrusted operator.conf falls back to the installed sets -- the baseline, which can only
# ever be root-owned rules -- rather than honouring a switch the sandbox could have written.
chmod 666 "${AI_TOOLS_OPERATOR_CONF}"
ai_tools_filter_rules_load
rewrites "an untrusted operator.conf falls back to the installed sets" 'git log --date=short' 'git log'
chmod 644 "${AI_TOOLS_OPERATOR_CONF}"

# --- Output noise stripping --------------------------------------------------------------------
# Byte-level noise only: no line is dropped, truncated or reordered.
strips() {
    local desc="$1" expected="$2" input="$3"
    local got; got="$(printf '%s' "${input}" | ai_tools_filter_strip_noise)"
    if [[ "${got}" == "${expected}" ]]; then pass "${desc}"; else fail "${desc}: got '$(_san "${got}")', expected '$(_san "${expected}")'"; fi
}
strips "SGR colour sequences are removed" \
    'red text' "$(printf '\x1b[31mred\x1b[0m text')"
strips "a multi-parameter CSI is removed" \
    'x' "$(printf '\x1b[1;32;40mx\x1b[0m')"
strips "an OSC title is removed" \
    'after' "$(printf '\x1b]0;a title\x07after')"
strips "a progress redraw collapses to its final state" \
    ' 100% done' "$(printf '  10%%\r  50%%\r 100%% done')"
strips "a CRLF line ending is not mistaken for a redraw" \
    'line' "$(printf 'line\r')"
strips "plain output is untouched" \
    'nothing to strip' 'nothing to strip'
strips "every line survives -- noise removal never drops one" \
    "$(printf 'one\ntwo\nthree')" "$(printf 'one\n\x1b[2Ktwo\nthree')"

finish

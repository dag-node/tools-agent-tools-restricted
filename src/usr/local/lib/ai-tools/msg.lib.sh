#!/usr/bin/env bash
# /usr/local/lib/ai-tools/msg.lib.sh
# Shared user-facing message formatter for the ai-tools sandbox components. Sourced
# (not executed) by the operator-facing scripts (the claude wrapper, the ai-tools
# CLI), the launch shim (claude-run), and the lifecycle hooks (session-hook.sh), so
# every refusal, prompt, and NOTICE the user reads is rendered one way: wrapped to fit
# 80 columns, with line breaks chosen so a line never ends on a preposition, article,
# or short conjunction (a TeX-style tie), and -- on a real terminal -- inside an ASCII
# frame.
#
# ── Two render modes, chosen per target file descriptor ───────────────────────
#
# TERMINAL (the target fd is a tty): the text is wrapped to <=76 columns and drawn in
# a titled box whose every line begins with '#', so the frame total stays within 80
# columns AND the whole block is a shell comment -- if a user copy-pastes it into a
# prompt nothing executes. A blank line PRECEDES every box, so consecutive boxes (and a
# box following other output) separate visually without the caller adding spacing:
#
#   #-- NOTICE ---------------------------------------------------#
#   # Reclaimed 85 agent-owned paths in the project .git tree,    #
#   # restoring ownership. Act only when git reports trouble.     #
#   #-------------------------------------------------------------#
#
# NOT A TERMINAL (piped, captured, redirected to a log, or fed to a hook's
# additionalContext): the text is emitted PLAIN and UNWRAPPED -- each caller-supplied
# line on its own line, no frame. This keeps the output grep-friendly: the test suite
# and log readers match message substrings with line-based `grep`, which a wrap could
# split across lines. The 80-column frame is a terminal nicety, not a wire format.
#
# Overrides (env): AI_TOOLS_MSG_PLAIN=1 forces plain even on a tty; AI_TOOLS_MSG_BOX=1
# forces the box even when the target is not a tty (used by the box unit test);
# AI_TOOLS_MSG_FULLWIDTH=1 pins every box to a fixed 80-column frame instead of sizing it
# to its content, so a SEQUENCE of boxes (e.g. an install flow's prompts) aligns uniformly.
#
# ── Tie-words and orphan control (typographic refinements of the wrap) ────────
#
# Wrapping treats a tie-word and the word after it as one unbreakable unit, so a line
# never ends on one. The set is articles, coordinating conjunctions, common prepositions,
# and the wh-/relative words (what, which, that, when, ...) -- the little words that read
# badly stranded at a right margin. Orphan control then rebalances the final line: when it
# would be a single unit, the previous (tie-glued) unit is pulled down onto it, so a lone
# one-word widow becomes a natural tail clause. Both apply only on the wrapped (box) path.
#
# ── Calling convention ────────────────────────────────────────────────────────
#
# The emitters take one argument PER LINE (matching the multi-line `printf '%s\n'`
# and `die` idioms they replace): ai_tools_msg_error "first line" "second line". The
# lines are the paragraphs; wrapping reflows within each, never across them. Errors,
# warnings, and notices go to stderr; info/success to stdout. ai_tools_msg_wrap is
# exposed for callers that need wrapped-but-unframed text to embed elsewhere (e.g. a
# hook's additionalContext). ai_tools_msg_block frames a multi-line guidance SCREEN that
# contains commands: flush-left lines wrap as prose, indented/blank lines stay verbatim
# (commands on one line, long ones overflowing the right border). ai_tools_msg_pick draws
# a numbered menu under such a block and echoes the chosen index, defaulting safely when no
# terminal is present -- the question companion to a block. ai_tools_msg_confirm is the
# single yes/no prompt: the standard bracketed hint with the default spelled out --
# "[Y/n] (default: Yes): " / "[y/N] (default: No): " -- on /dev/tty, returning the default
# when no terminal answers, so every yes/no question in the project renders and defaults
# one way. See each function.
#
# This library is REQUIRED by its consumers (bare-sourced under set -e, like
# safe-paths.lib.sh): ai_tools_msg_confirm carries yes/no decisions, so there is no
# per-consumer fallback -- a valid install ships the lib, and a broken one fails closed.
# The one exception is session-hook.sh, which only emits and whose sweep must run
# regardless (see its header). The emitters still only format: they never change the
# exit status of the operation whose outcome they report.

# Include guard. Consumers source this lib directly AND through safe-paths.lib.sh; the
# readonly constants below would abort a re-source under set -e, so a second source is a
# no-op instead.
if [[ -n "${_AI_TOOLS_MSG_LIB_LOADED:-}" ]]; then return 0; fi
readonly _AI_TOOLS_MSG_LIB_LOADED=1

# Decision audit trail. ai_tools_msg_confirm and ai_tools_msg_pick below record every
# yes/no answer and menu choice through the shared logger (log.lib.sh), so every user
# action taken through this library leaves ONE consistent trail: journald always, and the
# root-only file sink (/var/log/ai-tools/<component>.log) when a root caller set
# AI_TOOLS_LOG_FILE. The logger is sourced from the SIBLING file -- resolved relative to
# this one, so it works both in the source tree and installed -- and only when not already
# loaded (log.lib.sh is include-guarded, so a consumer that sources both loads it once).
# Best-effort: a missing logger degrades to no audit line, never a broken prompt, matching
# every other logging call in the project.
if ! declare -F ai_tools_log >/dev/null 2>&1; then
    # shellcheck source=SCRIPTDIR/log.lib.sh
    source "${BASH_SOURCE[0]%/*}/log.lib.sh" 2>/dev/null || true
fi

# _ai_tools_msg_audit <text...> -- emit one INFO audit line for a decision made through this
# library, tagged with the caller's AI_TOOLS_LOG_TAG. A no-op when the logger is
# unavailable; never alters the caller's exit status (logging is best-effort throughout).
_ai_tools_msg_audit() {
    declare -F ai_tools_log >/dev/null 2>&1 || return 0
    ai_tools_log info "$@"
}

# Inner text width cap so a framed line never exceeds 80 columns:
#   "# " (2) + text + " #" (2) = text + 4  =>  text <= 76.
readonly AI_TOOLS_MSG_WIDTH="${AI_TOOLS_MSG_WIDTH:-76}"

# Words a wrapped line must not END with. Lowercased, space-delimited, matched after
# stripping one trailing punctuation char. Articles + coordinating conjunctions +
# common prepositions -- the words that read badly when stranded at the right margin.
readonly _AI_TOOLS_MSG_TIES=" a an the and or nor but so yet \
of to in on at by for with from into onto upon over under above below \
between among through during before after about against along across \
around near off out up down via per as \
what which who whom whose that when where why how "

# _ai_tools_msg_is_tie <word> -- 0 (true) when <word>, lowercased and with one
# trailing punctuation char removed, is a tie-word that must not end a line.
_ai_tools_msg_is_tie() {
    local w="${1,,}"
    w="${w%[.,:;!?\"\')]}"
    [[ "${_AI_TOOLS_MSG_TIES}" == *" ${w} "* ]]
}

# ai_tools_msg_wrap <width> <text...> -- greedy word-wrap to <width> columns, honoring
# tie-words (never ends a line on one). Each input LINE is a paragraph reflowed on its
# own; blank lines are preserved. A single word/tie-unit longer than <width> (e.g. a
# path or a command) is never split -- it overflows its own line intact, since breaking
# it would defeat copy-paste. Emits the wrapped lines on stdout.
ai_tools_msg_wrap() {
    # Pin IFS to the default: this lib is sourced into callers that set their own (the
    # claude wrapper uses IFS=$'\n\t', dropping space), and the word-splitting below
    # (read -ra, $*) must split on spaces regardless, or a whole line collapses into one
    # unbreakable unit and never wraps. The per-command `IFS= read` overrides stay local.
    local IFS=$' \t\n'
    local width="$1"; shift
    local text="$*" para
    local US=$'\x1f'                 # unit separator: units hold spaces but never this
    while IFS= read -r para || [[ -n "${para}" ]]; do
        local -a words=() units=()
        read -ra words <<<"${para}"
        if (( ${#words[@]} == 0 )); then printf '\n'; continue; fi
        # Build wrap-units: glue each tie-word forward onto the next word so a unit
        # always ends on a non-tie word (or the paragraph's last word).
        local unit="" w
        for w in "${words[@]}"; do
            unit="${unit:+${unit} }${w}"
            _ai_tools_msg_is_tie "${w}" || { units+=( "${unit}" ); unit=""; }
        done
        [[ -n "${unit}" ]] && units+=( "${unit}" )
        # Greedy fill. Each line is its units joined by US, so orphan control below can
        # count and move whole units (which may themselves contain spaces).
        local -a lines=()
        local cur=""
        for unit in "${units[@]}"; do
            if [[ -z "${cur}" ]]; then
                cur="${unit}"
            elif (( ${#cur} + 1 + ${#unit} <= width )); then
                cur="${cur}${US}${unit}"
            else
                lines+=( "${cur}" ); cur="${unit}"
            fi
            if (( ${#cur} > width )); then       # lone over-long unit: emit, overflow
                lines+=( "${cur}" ); cur=""
            fi
        done
        [[ -n "${cur}" ]] && lines+=( "${cur}" )
        # Orphan control: a final line that is a single unit reads as a stranded widow.
        # Pull the previous line's last unit down onto it, provided the previous line keeps
        # at least one unit and the merged final line still fits the width. Units end on a
        # non-tie word by construction, so the shortened previous line still does not end on
        # a tie -- the no-trailing-tie guarantee is preserved.
        local n=${#lines[@]}
        if (( n >= 2 )) && [[ "${lines[n-1]}" != *"${US}"* && "${lines[n-2]}" == *"${US}"* ]]; then
            local merged="${lines[n-2]##*${US}}${US}${lines[n-1]}"
            (( ${#merged} <= width )) && { lines[n-2]="${lines[n-2]%${US}*}"; lines[n-1]="${merged}"; }
        fi
        local l
        for l in "${lines[@]}"; do printf '%s\n' "${l//${US}/ }"; done
    done <<<"${text}"
}

# _ai_tools_msg_render_box <title> <text...> -- wrap <text> and draw the titled
# '#'-bordered box on stdout. Box width tracks the longest wrapped line (capped at
# AI_TOOLS_MSG_WIDTH), widened only as needed to seat the title in the top rule.
_ai_tools_msg_render_box() {
    local title="$1"; shift
    local -a lines=()
    local l
    while IFS= read -r l || [[ -n "${l}" ]]; do
        lines+=( "${l}" )
    done < <(ai_tools_msg_wrap "${AI_TOOLS_MSG_WIDTH}" "$*")

    local cw=0
    for l in "${lines[@]}"; do (( ${#l} > cw )) && cw=${#l}; done
    local need=$(( ${#title} + 6 ))             # "#-- " + title + " " + closing "#"
    (( cw < need )) && cw=${need}
    (( cw > AI_TOOLS_MSG_WIDTH )) && cw=${AI_TOOLS_MSG_WIDTH}
    [[ "${AI_TOOLS_MSG_FULLWIDTH:-}" == 1 ]] && cw=${AI_TOOLS_MSG_WIDTH}   # fixed 80-col frame
    local tw=$(( cw + 4 ))                       # total line width incl. borders

    local head dashes pad
    if [[ -n "${title}" ]]; then head="#-- ${title} "; else head="#-"; fi
    pad=$(( tw - ${#head} - 1 )); (( pad < 0 )) && pad=0
    printf -v dashes '%*s' "${pad}" ''; dashes=${dashes// /-}
    printf '\n'                                  # leading blank: boxes self-separate
    printf '%s%s#\n' "${head}" "${dashes}"      # top rule (inset title)
    for l in "${lines[@]}"; do
        pad=$(( cw - ${#l} )); (( pad < 0 )) && pad=0
        printf '# %s%*s #\n' "${l}" "${pad}" ''  # content line
    done
    printf -v dashes '%*s' "$(( tw - 2 ))" ''; dashes=${dashes// /-}
    printf '#%s#\n' "${dashes}"                  # bottom rule
}

# ai_tools_msg <severity> <fd> <line...> -- render the lines to file descriptor <fd>.
# A tty target (and no PLAIN override) gets the box titled with the uppercased
# severity; otherwise the lines are emitted plain and unwrapped so captured/piped
# output stays grep-friendly. A formatting or write failure never alters the caller's
# exit status; a genuine write error to <fd> surfaces on stderr rather than being hidden.
ai_tools_msg() {
    local sev="$1" fd="$2"; shift 2
    local boxed=0
    if   [[ "${AI_TOOLS_MSG_BOX:-}"   == 1 ]]; then boxed=1
    elif [[ "${AI_TOOLS_MSG_PLAIN:-}" == 1 ]]; then boxed=0
    elif [[ -t "${fd}" ]];                     then boxed=1
    fi
    if (( boxed )); then
        local text="$1"; shift
        for l in "$@"; do text+=$'\n'"${l}"; done
        _ai_tools_msg_render_box "${sev^^}" "${text}" >&"${fd}" || true
    else
        printf '%s\n' "$@" >&"${fd}" || true
    fi
}

# Convenience emitters -- prefixed ai_tools_msg_* to avoid colliding with callers'
# own error()/warn(). Errors/warnings/notices to stderr; info/success to stdout.
ai_tools_msg_error()   { ai_tools_msg ERROR   2 "$@"; }
ai_tools_msg_warn()    { ai_tools_msg WARNING 2 "$@"; }
ai_tools_msg_notice()  { ai_tools_msg NOTICE  2 "$@"; }
ai_tools_msg_info()    { ai_tools_msg INFO    1 "$@"; }
ai_tools_msg_success() { ai_tools_msg OK      1 "$@"; }

# ai_tools_msg_block <title> <line...> -- frame a multi-line guidance block in the titled
# '#' box on stderr. Unlike the emitters above (which wrap every line), this preserves
# author layout: a flush-left line is wrapped as prose, while an INDENTED or BLANK line is
# kept VERBATIM -- never reflowed -- so a copy-pasteable command stays on one line and
# indentation/numbering survives. A verbatim line wider than the box OVERFLOWS past the
# right border intact rather than breaking (a long, non-separable command is kept whole).
# Every line still begins with '#', so the whole block remains a paste-safe comment. On a
# non-tty target (and under PLAIN) the lines are emitted plain, no frame.
ai_tools_msg_block() {
    local title="$1"; shift
    local boxed=0
    if   [[ "${AI_TOOLS_MSG_BOX:-}"   == 1 ]]; then boxed=1
    elif [[ "${AI_TOOLS_MSG_PLAIN:-}" == 1 ]]; then boxed=0
    elif [[ -t 2 ]];                           then boxed=1
    fi
    if (( ! boxed )); then
        printf '%s\n' "$@" >&2 2>/dev/null || true
        return 0
    fi
    # Compose the rendered lines: wrap prose, keep indented/blank verbatim.
    local -a out=()
    local line w
    for line in "$@"; do
        if [[ -z "${line}" || "${line}" == [[:space:]]* ]]; then
            out+=( "${line}" )
        else
            while IFS= read -r w || [[ -n "${w}" ]]; do
                out+=( "${w}" )
            done < <(ai_tools_msg_wrap "${AI_TOOLS_MSG_WIDTH}" "${line}")
        fi
    done
    # Box width tracks the longest NON-overflowing line, capped at the width and widened
    # only to seat the title; a verbatim line past the cap overflows and does not grow it.
    local cw=0
    for line in "${out[@]}"; do
        (( ${#line} <= AI_TOOLS_MSG_WIDTH && ${#line} > cw )) && cw=${#line}
    done
    local need=$(( ${#title} + 6 ))
    (( cw < need )) && cw=${need}
    (( cw > AI_TOOLS_MSG_WIDTH )) && cw=${AI_TOOLS_MSG_WIDTH}
    [[ "${AI_TOOLS_MSG_FULLWIDTH:-}" == 1 ]] && cw=${AI_TOOLS_MSG_WIDTH}   # fixed 80-col frame
    local tw=$(( cw + 4 )) head dashes pad
    if [[ -n "${title}" ]]; then head="#-- ${title} "; else head="#-"; fi
    pad=$(( tw - ${#head} - 1 )); (( pad < 0 )) && pad=0
    {
        printf '\n'                              # leading blank: boxes self-separate
        printf -v dashes '%*s' "${pad}" ''; dashes=${dashes// /-}
        printf '%s%s#\n' "${head}" "${dashes}"
        for line in "${out[@]}"; do
            if (( ${#line} > cw )); then
                printf '# %s\n' "${line}"             # overflow: kept whole, no right rule
            else
                pad=$(( cw - ${#line} ))
                printf '# %s%*s #\n' "${line}" "${pad}" ''
            fi
        done
        printf -v dashes '%*s' "$(( tw - 2 ))" ''; dashes=${dashes// /-}
        printf '#%s#\n' "${dashes}"
    } >&2 2>/dev/null || true
}

# ai_tools_msg_pick <default_index> <label...> -- present a numbered menu and echo the
# chosen 1-based index on stdout. The <default_index> option is annotated "(default)" and
# is the answer on empty input, an out-of-range number, or no terminal -- so an unattended
# or piped run takes the safe default (typically Cancel). The menu is drawn on /dev/tty;
# only the chosen index reaches stdout, so the caller reads it with $(...). Pairs with a
# preceding ai_tools_msg_block that lays out what each option does.
ai_tools_msg_pick() {
    local def="$1"; shift
    local n=$# i choice
    {
        printf 'Select an option:\n'
        for (( i = 1; i <= n; i++ )); do
            if (( i == def )); then
                printf '%d) %s (default)\n' "${i}" "${!i}"
            else
                printf '%d) %s\n' "${i}" "${!i}"
            fi
        done
        printf 'Enter number (default %d): ' "${def}"
    # 2>/dev/null BEFORE > /dev/tty (as in ai_tools_msg_confirm): redirections apply left to
    # right, and with no controlling terminal it is the > /dev/tty open that fails, so stderr
    # must already be silenced or the shell leaks the ENXIO complaint to the caller.
    } 2>/dev/null > /dev/tty || {
        _ai_tools_msg_audit "menu: no terminal, took default ${def}/${n} (${!def})"
        printf '%s' "${def}"; return 0
    }
    IFS= read -r choice < /dev/tty 2>/dev/null || choice=""
    [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )) || choice="${def}"
    _ai_tools_msg_audit "menu: chose ${choice}/${n} (${!choice})"
    printf '%s' "${choice}"
}

# ai_tools_msg_confirm <question> <y|n> -- the yes/no companion to ai_tools_msg_pick,
# and the ONE renderer for the project's inline yes/no prompt, in the standard bracketed
# notation with the Enter outcome spelled out:
#   "<question> [Y/n] (default: Yes): "   for a yes default
#   "<question> [y/N] (default: No): "    for a no default
# Drawn on /dev/tty and answered from /dev/tty; returns 0 for yes, 1 for no. The default
# is a REQUIRED argument: every call site states which way its question falls. Frame the
# question positively (ask about the action, never its negation) and give it the default
# that is the SAFE outcome -- Enter, and any run with no terminal, take it (opening
# /dev/tty is the honest probe: with no controlling terminal it fails ENXIO), so an
# unattended or piped run never blocks and never lands on the unsafe side.
# AI_TOOLS_ASSUME_YES=1 (unattended runs, tests) skips the prompt and answers yes ONLY
# when the default is already 'y': it fast-tracks safe-direction questions but never
# flips a default-NO question -- those always ask (or take No with no terminal). A caller
# that must pre-answer a default-NO question does it with its own explicit flag (e.g.
# ai-tools --yes, ai-tools-chown --yes), an auditable per-invocation decision.
ai_tools_msg_confirm() {
    local question="$1" def="${2:?ai_tools_msg_confirm: default (y|n) is required}" hint resp how result
    case "${def}" in
        y) hint="[Y/n] (default: Yes)" ;;
        n) hint="[y/N] (default: No)" ;;
        *) printf 'ai_tools_msg_confirm: default must be y or n, got %s\n' "${def}" >&2
           return 2 ;;
    esac
    if [[ "${def}" == "y" && "${AI_TOOLS_ASSUME_YES:-}" == 1 ]]; then
        resp="y"; how="assume-yes"
    # 2>/dev/null BEFORE > /dev/tty: redirections apply left to right, and with no
    # controlling terminal it is the > /dev/tty open itself that fails -- stderr must
    # already be silenced or the shell prints the ENXIO complaint to the caller's stderr.
    elif printf '%s %s: ' "${question}" "${hint}" 2>/dev/null > /dev/tty; then
        IFS= read -r resp < /dev/tty 2>/dev/null || resp=""
        if [[ -n "${resp}" ]]; then how="answered"; else how="default"; fi
        resp="${resp:-${def}}"
    else
        resp="${def}"; how="no-tty-default"
    fi
    if [[ "${resp}" =~ ^[yY] ]]; then result="yes"; else result="no"; fi
    # One audit line per decision, at the single yes/no chokepoint (see log.lib.sh sink).
    _ai_tools_msg_audit "confirm: ${question} -> ${result} (${how})"
    [[ "${result}" == "yes" ]]
}

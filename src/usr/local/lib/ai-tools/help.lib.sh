#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/help.lib.sh -- the command surface of ai-tools and ai-tools-admin as data, the help each one
# prints, the reading of a command line as a help request, and the discovery of the admin domains provider packages
# contribute. Sourced by ai-tools, ai-tools-admin and atr, so the help an operator reads through atr without sudo,
# the help root reads, and the dispatch that runs the commands read one table and one domain list
# (cli-grammar.rule.md).
#
# The rows are one array per program, each row five TAB-separated fields: the block it renders under, the command path
# (or the long option, for an `Options` row), the argument placeholder as the help prints it, the description,
# and the flags (`for` on a row whose usage carries `[--for OPERATOR]`, `short=h` on an option with a short form).
# A collection's bare form is its row with the argument `[list]`. The admin's domain rows are not data: they come
# from ai_tools_help__read_admin_domains at render time.
#
# A field may be empty, and TAB is a whitespace IFS character, which `read` collapses, so a row is split by parameter
# expansion and never by `read`. The list readers print `-` for an empty field for the same reason. Every split pins IFS
# locally, since ai-tools runs under IFS=$'\n\t'.
#
# conf.lib.sh is REQUIRED (ai_tools_conf__is_trusted decides which contributed domain is listed and dispatched),
# so a failed load returns non-zero with no function defined, the posture providers.lib.sh takes. providers.lib.sh is
# optional: it supplies each domain's admin_summary, and without it a domain is listed without its summary.

# Include guard: the rows are readonly, so a second source would abort under `set -e`. An if-statement, not
# `[[ ]] && return`, which returns 1 for an unset guard.
if [[ -n "${_AI_TOOLS_HELP__LOADED:-}" ]]; then
    return 0
fi

# shellcheck source=SCRIPTDIR/conf.lib.sh
if ! source "${BASH_SOURCE[0]%/*}/conf.lib.sh" 2>/dev/null \
        || ! declare -F ai_tools_conf__is_trusted >/dev/null 2>&1; then
    return 1
fi
if ! declare -F ai_tools_providers__read_provider_manifest_field >/dev/null 2>&1; then
    # shellcheck source=SCRIPTDIR/providers.lib.sh
    source "${BASH_SOURCE[0]%/*}/providers.lib.sh" 2>/dev/null || true
fi

readonly _AI_TOOLS_HELP__LOADED=1

readonly -a _AI_TOOLS_HELP__ROWS_AI_TOOLS=(
    $'Projects\tprojects\t[list]\tList the registered projects and sandbox clones\tfor'
    $'Projects\tprojects create\tDIRECTORY\tCreate a directory, initialise git, claim it\tfor'
    $'Projects\tprojects claim\tDIRECTORY\tClaim an existing directory in place\tfor'
    $'Projects\tprojects unclaim\tDIRECTORY\tRelease a project and keep its directory\tfor'
    $'Projects\tprojects remove\tDIRECTORY\tRelease a project and delete its directory\tfor'
    $'Projects\tprojects disable\tDIRECTORY\tDisable a project, so no session starts in it\tfor'
    $'Projects\tprojects enable\tDIRECTORY\tEnable a disabled project\tfor'
    $'Projects\tprojects clone\tDIRECTORY\tShallow-clone a repository into the sandbox\t'
    $'Projects\tprojects push\t[DIRECTORY]\tPush a sandbox clone\'s commits to its branch\t'
    $'Projects\tprojects lockdown\t[DIRECTORY]\tLock down secret-named files\tfor'
    $'Projects\tprojects handback\t[DIRECTORY]\tTake back ownership of files the agent wrote\tfor'
    $'Reports\tstatus\t\tShow service health and what needs attention\t'
    $'Reports\tproviders\t[list]\tList installed providers and which are enabled\t'
    $'Reports\taudit\t\tShow what was refused, rejected or stranded\t'
    $'Incident\tstop\t\tStop every agent session on this host\t'
    $'Options\t--for\tOPERATOR\tAct on another enrolled operator\'s projects\t'
    $'Options\t--help\t\tShow this help (also: atr help)\tshort=h'
    $'Options\t--version\t\tShow the installed version\t'
)
readonly -a _AI_TOOLS_HELP__ROWS_AI_TOOLS_ADMIN=(
    $'Operators\toperators\t[list]\tList the enrolled operators\t'
    $'Operators\toperators add\t[USER]\tEnrol an operator (default: the sudo caller)\t'
    $'Operators\toperators remove\tUSER\tWithdraw an operator\'s enrolment\t'
    $'SELinux\tselinux groups\t[list]\tList the core module and the optional groups\t'
    $'SELinux\tselinux groups enable\tGROUP...\tLoad prebuilt optional groups\t'
    $'SELinux\tselinux groups disable\tGROUP\tUnload a loaded group\t'
    $'System\tsystem bootstrap\t\tProvision the sandbox account and toolchain\t'
    $'System\tsystem entrypoints relabel\t\tVerify and relabel the agent entrypoints\t'
    $'System\tsystem post-upgrade\t\tReconcile the .rpmnew files an upgrade leaves\t'
    $'System\tsystem layout\t[list]\tList each installed path and what drifted\t'
    $'System\tsystem layout reconcile\t\tRestore each installed path\'s declared state\t'
    $'Assets\tassets\t[list]\tList enabled assets and pending link changes\t'
    $'Assets\tassets enable\tID...\tEnable assets, each SET/KIND/NAME\t'
    $'Assets\tassets disable\tID...\tDisable assets and remove their links\t'
    $'Assets\tassets reconcile\t\tUpdate the asset view and the agent links\t'
    $'Health\tstatus\t\tShow services, assets, entrypoints and labels\t'
    $'Incident\tstop\t\tStop every agent session on this host\t'
    $'Options\t--help\t\tShow this help (also: atr admin help)\tshort=h'
    $'Options\t--version\t\tShow the installed version\t'
)

readonly _AI_TOOLS_HELP__TITLE_AI_TOOLS="Agent Tools Restricted -- operator commands (ai-tools)"
readonly _AI_TOOLS_HELP__TITLE_AI_TOOLS_ADMIN="Agent Tools Restricted -- host administration (ai-tools-admin)"
readonly _AI_TOOLS_HELP__USAGE_AI_TOOLS="  atr [--for OPERATOR] COMMAND [ARGUMENT...] [OPTION...]
  atr admin COMMAND [ARGUMENT...] [OPTION...]"
readonly _AI_TOOLS_HELP__USAGE_AI_TOOLS_ADMIN="  atr admin COMMAND [ARGUMENT...] [OPTION...]"
readonly _AI_TOOLS_HELP__CLOSING_AI_TOOLS="A DIRECTORY of . is the directory you are in. Left out of push, lockdown or
handback, it is the claimed project the current directory belongs to.

Run as yourself, not with sudo: each command calls sudo for the steps that
need it. Host administration is atr admin, which runs as root.

More: man ai-tools · atr admin help · /var/opt/ai-tools/README.md"
readonly _AI_TOOLS_HELP__CLOSING_AI_TOOLS_ADMIN="Each command runs as root, through sudo when you are not root. Help,
--version and a bare stop ask no password. The project lifecycle is atr
without admin, run as yourself.

More: man ai-tools-admin · atr help"
readonly _AI_TOOLS_HELP__REFUSED_LINE="  (refused: a file there is not root's alone -- see the warning above)"

# _ai_tools_help__warn [code] <message...>: a finding about the admin command directory, on stderr with the
# `ai-tools-admin: warning:` prefix whichever program lists the domains, since the directory is that program's.
# A leading message code goes on its own line ahead of the message, matched inline (msg.lib.sh states the form).
_ai_tools_help__warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-admin: warning: %s\n' "$*" >&2
    return 0
}

# _ai_tools_help__rows <program> <array-name>: point the named variable at the program's rows. Returns 1 for a program
# this library does not describe.
_ai_tools_help__rows() {
    local -n _ai_tools_help_rows_out="$2"
    case "$1" in
        ai-tools)       _ai_tools_help_rows_out=("${_AI_TOOLS_HELP__ROWS_AI_TOOLS[@]}") ;;
        ai-tools-admin) _ai_tools_help_rows_out=("${_AI_TOOLS_HELP__ROWS_AI_TOOLS_ADMIN[@]}") ;;
        *)              return 1 ;;
    esac
}

# _ai_tools_help__split_row <row>: set _AI_TOOLS_HELP__BLOCK, _PATH, _ARGUMENT, _DESCRIPTION and _FLAGS from one row.
_ai_tools_help__split_row() {
    local rest="$1"
    _AI_TOOLS_HELP__BLOCK="${rest%%$'\t'*}";       rest="${rest#*$'\t'}"
    _AI_TOOLS_HELP__PATH="${rest%%$'\t'*}";        rest="${rest#*$'\t'}"
    _AI_TOOLS_HELP__ARGUMENT="${rest%%$'\t'*}";    rest="${rest#*$'\t'}"
    _AI_TOOLS_HELP__DESCRIPTION="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    _AI_TOOLS_HELP__FLAGS="${rest}"
}

# _ai_tools_help__has_flag <flags> <flag>: succeed when the space-separated <flags> carry <flag>.
_ai_tools_help__has_flag() { [[ " $1 " == *" $2 "* ]]; }

# _ai_tools_help__command_label: the `path argument` label of the row last split.
_ai_tools_help__command_label() {
    printf '%s' "${_AI_TOOLS_HELP__PATH}${_AI_TOOLS_HELP__ARGUMENT:+ ${_AI_TOOLS_HELP__ARGUMENT}}"
}

# _ai_tools_help__label_width <program>: two spaces past the longest command label among the program's command rows,
# the column every block of that program aligns its descriptions to.
_ai_tools_help__label_width() {
    local row label width=0
    local -a rows=()
    _ai_tools_help__rows "$1" rows || return 1
    for row in "${rows[@]}"; do
        _ai_tools_help__split_row "${row}"
        [[ "${_AI_TOOLS_HELP__BLOCK}" != Options ]] || continue
        label="$(_ai_tools_help__command_label)"
        (( ${#label} > width )) && width=${#label}
    done
    printf '%s' "$(( width + 2 ))"
}

# _ai_tools_help__print_row <width>: the row last split as one help line at the two-space indent.
_ai_tools_help__print_row() {
    local label short=""
    if [[ "${_AI_TOOLS_HELP__BLOCK}" == Options ]]; then
        [[ "${_AI_TOOLS_HELP__FLAGS}" =~ (^|[[:space:]])short=([a-zA-Z])($|[[:space:]]) ]] && short="${BASH_REMATCH[2]}"
        label="${_AI_TOOLS_HELP__PATH}${_AI_TOOLS_HELP__ARGUMENT:+ ${_AI_TOOLS_HELP__ARGUMENT}}"
        if [[ -n "${short}" ]]; then label="-${short}, ${label}"; else label="    ${label}"; fi
    else
        label="$(_ai_tools_help__command_label)"
    fi
    printf '  %-*s%s\n' "$1" "${label}" "${_AI_TOOLS_HELP__DESCRIPTION}"
}

# _ai_tools_help__is_known_path <program> <path>: succeed when <path> is a row's path or the leading words of one.
_ai_tools_help__is_known_path() {
    local row
    local -a rows=()
    _ai_tools_help__rows "$1" rows || return 1
    for row in "${rows[@]}"; do
        _ai_tools_help__split_row "${row}"
        [[ "${_AI_TOOLS_HELP__BLOCK}" != Options ]] || continue
        [[ "${_AI_TOOLS_HELP__PATH}" == "$2" || "${_AI_TOOLS_HELP__PATH}" == "$2 "* ]] && return 0
    done
    return 1
}

# _ai_tools_help__is_extended_path <program> <path>: succeed when another row's path extends <path> -- a collection,
# a namespace, `system layout` -- so its help is the block form.
_ai_tools_help__is_extended_path() {
    local row
    local -a rows=()
    _ai_tools_help__rows "$1" rows || return 1
    for row in "${rows[@]}"; do
        _ai_tools_help__split_row "${row}"
        [[ "${_AI_TOOLS_HELP__BLOCK}" != Options ]] || continue
        [[ "${_AI_TOOLS_HELP__PATH}" == "$2 "* ]] && return 0
    done
    return 1
}

# _ai_tools_help__find_row <program> <path>: split the command row whose path is <path>, or return 1.
_ai_tools_help__find_row() {
    local row
    local -a rows=()
    _ai_tools_help__rows "$1" rows || return 1
    for row in "${rows[@]}"; do
        _ai_tools_help__split_row "${row}"
        [[ "${_AI_TOOLS_HELP__BLOCK}" != Options && "${_AI_TOOLS_HELP__PATH}" == "$2" ]] && return 0
    done
    return 1
}

# _ai_tools_help__command_prefix <program>: what a reader types ahead of a command path.
_ai_tools_help__command_prefix() {
    case "$1" in ai-tools) printf 'atr' ;; ai-tools-admin) printf 'atr admin' ;; esac
}

# ai_tools_help__read_admin_domains <dir>: fill AI_TOOLS_HELP__ADMIN_DOMAINS with the contributed domains <dir> holds,
# in filename order, and set AI_TOOLS_HELP__ADMIN_COMMANDS_TAMPERED to 1 when an entry failed the trust predicate.
# Both are globals because the caller reads the second one, which a $(...) capture would leave in a subshell. Every
# refusal goes to stderr.
#
# A fragment is listed only while ai_tools_conf__is_trusted holds for it AND for <dir>: a group-writable directory lets
# a non-root writer replace a root-owned file in it, which here is a command root then executes. A name base owns is
# refused rather than merged, and a basename outside the domain charset is skipped before it is joined to a path, so
# a separator or a traversal cannot address a file outside <dir>. The dispatch, the full-scope bootstrap and both helps
# read this one function, so what an administrator is told and what runs cannot disagree.
#
# The two rejections are counted apart. A name this seam does not recognize (a README, a backup, a base name) is a file
# that is not a command, and the set around it is unaffected. A file that group or other may write breaks the assumption
# that only root decides what runs from <dir>, and that is what AI_TOOLS_HELP__ADMIN_COMMANDS_TAMPERED carries
# to the set-wide gate.
AI_TOOLS_HELP__ADMIN_DOMAINS=()
AI_TOOLS_HELP__ADMIN_COMMANDS_TAMPERED=0
ai_tools_help__read_admin_domains() {
    local dir="$1" fragment domain
    AI_TOOLS_HELP__ADMIN_DOMAINS=()
    AI_TOOLS_HELP__ADMIN_COMMANDS_TAMPERED=0
    [[ -d "${dir}" ]] || return 0
    if ! ai_tools_conf__is_trusted "${dir}"; then
        _ai_tools_help__warn MSG-V5S5 "ignoring every contributed command: ${dir} is a symlink, is not root-owned, or is writable by group/other"
        AI_TOOLS_HELP__ADMIN_COMMANDS_TAMPERED=1
        return 0
    fi
    for fragment in "${dir}"/*; do
        [[ -f "${fragment}" ]] || continue
        domain="${fragment##*/}"
        if [[ ! "${domain}" =~ ^[a-z][a-z0-9-]*$ ]]; then
            _ai_tools_help__warn MSG-H6J9 "skipping $(printf '%q' "${fragment}"): a contributed command is named for its provider, in bare lower-case"
            continue
        fi
        if ai_tools_help__is_base_command "${domain}"; then
            _ai_tools_help__warn MSG-U6P9 "refusing ${fragment}: '${domain}' is a command ai-tools-admin owns and no package may replace it"
            continue
        fi
        if ! ai_tools_conf__is_trusted "${fragment}"; then
            _ai_tools_help__warn MSG-D3P6 "refusing ${fragment}: it is a symlink, is not root-owned, or is writable by group/other, so what it runs is not root's decision alone"
            AI_TOOLS_HELP__ADMIN_COMMANDS_TAMPERED=1
            continue
        fi
        AI_TOOLS_HELP__ADMIN_DOMAINS+=( "${domain}" )
    done
    return 0
}

# ai_tools_help__is_base_command <name>: succeed when <name> is the first word of an admin command row, or `help`, which
# the help resolution answers ahead of the dispatch. A contributed fragment carrying one of these names is refused.
ai_tools_help__is_base_command() {
    local row
    [[ "$1" == help ]] && return 0
    for row in "${_AI_TOOLS_HELP__ROWS_AI_TOOLS_ADMIN[@]}"; do
        _ai_tools_help__split_row "${row}"
        [[ "${_AI_TOOLS_HELP__BLOCK}" != Options ]] || continue
        [[ "${_AI_TOOLS_HELP__PATH%% *}" == "$1" ]] && return 0
    done
    return 1
}

# ai_tools_help__list_commands <program>: one `path<TAB>argument<TAB>block<TAB>flags` line per command row, `-` for
# an empty field, for the readers that hold a page and the completion to the surface.
ai_tools_help__list_commands() {
    local row
    local -a rows=()
    _ai_tools_help__rows "$1" rows || return 1
    for row in "${rows[@]}"; do
        _ai_tools_help__split_row "${row}"
        [[ "${_AI_TOOLS_HELP__BLOCK}" != Options ]] || continue
        printf '%s\t%s\t%s\t%s\n' "${_AI_TOOLS_HELP__PATH}" "${_AI_TOOLS_HELP__ARGUMENT:--}" \
            "${_AI_TOOLS_HELP__BLOCK}" "${_AI_TOOLS_HELP__FLAGS:--}"
    done
}

# ai_tools_help__list_options <program>: one `long<TAB>argument<TAB>short` line per option row, `-` for an empty field.
ai_tools_help__list_options() {
    local row short
    local -a rows=()
    _ai_tools_help__rows "$1" rows || return 1
    for row in "${rows[@]}"; do
        _ai_tools_help__split_row "${row}"
        [[ "${_AI_TOOLS_HELP__BLOCK}" == Options ]] || continue
        short=-
        [[ "${_AI_TOOLS_HELP__FLAGS}" =~ (^|[[:space:]])short=([a-zA-Z])($|[[:space:]]) ]] && short="-${BASH_REMATCH[2]}"
        printf '%s\t%s\t%s\n' "${_AI_TOOLS_HELP__PATH}" "${_AI_TOOLS_HELP__ARGUMENT:--}" "${short}"
    done
}

# _ai_tools_help__render_domains <width> <admin-commands-dir>: the `Provider commands:` block, one line per trusted
# domain with its manifest's admin_summary, and the refusal line under them while the set-wide gate holds. Prints
# no line where no domain is listed. Every caller runs it in its own shell, not in a $(...), so the discovery's warnings
# reach stderr once and its globals stay set.
_ai_tools_help__render_domains() {
    local width="$1" domain summary
    ai_tools_help__read_admin_domains "$2"
    (( ${#AI_TOOLS_HELP__ADMIN_DOMAINS[@]} > 0 )) || return 0
    printf 'Provider commands:\n'
    for domain in "${AI_TOOLS_HELP__ADMIN_DOMAINS[@]}"; do
        summary=""
        declare -F ai_tools_providers__read_provider_manifest_field >/dev/null 2>&1 \
            && summary="$(ai_tools_providers__read_provider_manifest_field "${domain}" admin_summary 2>/dev/null || true)"
        printf '  %-*s%s\n' "${width}" "${domain} COMMAND" "${summary}"
    done
    (( AI_TOOLS_HELP__ADMIN_COMMANDS_TAMPERED == 0 )) || printf '%s\n' "${_AI_TOOLS_HELP__REFUSED_LINE}"
    printf '\n'
}

# ai_tools_help__render <program> [<admin-commands-dir>]: print the program's top help to stdout. The admin's carries
# its `Provider commands:` block, discovered from <admin-commands-dir> when one is given.
ai_tools_help__render() {
    local program="$1" commands_dir="${2-}" width row block="" title usage closing
    local -a rows=()
    _ai_tools_help__rows "${program}" rows || return 1
    width="$(_ai_tools_help__label_width "${program}")"
    case "${program}" in
        ai-tools)       title="${_AI_TOOLS_HELP__TITLE_AI_TOOLS}"; usage="${_AI_TOOLS_HELP__USAGE_AI_TOOLS}"
                        closing="${_AI_TOOLS_HELP__CLOSING_AI_TOOLS}" ;;
        ai-tools-admin) title="${_AI_TOOLS_HELP__TITLE_AI_TOOLS_ADMIN}"; usage="${_AI_TOOLS_HELP__USAGE_AI_TOOLS_ADMIN}"
                        closing="${_AI_TOOLS_HELP__CLOSING_AI_TOOLS_ADMIN}" ;;
    esac
    printf '%s\n\nUsage:\n%s\n' "${title}" "${usage}"
    local row_block
    for row in "${rows[@]}"; do
        _ai_tools_help__split_row "${row}"
        # The discovery splits rows of its own into the same fields, so this row's block is kept apart and the row split
        # again after it.
        row_block="${_AI_TOOLS_HELP__BLOCK}"
        if [[ "${row_block}" != "${block}" ]]; then
            if [[ "${row_block}" == Options && "${program}" == ai-tools-admin && -n "${commands_dir}" ]]; then
                printf '\n'
                _ai_tools_help__render_domains "${width}" "${commands_dir}"
                printf '%s:\n' "${row_block}"
                _ai_tools_help__split_row "${row}"
            else
                printf '\n%s:\n' "${row_block}"
            fi
            block="${row_block}"
        fi
        _ai_tools_help__print_row "${width}"
    done
    printf '\n%s\n' "${closing}"
}

# ai_tools_help__render_hint <program> <path>: print the help for <path>: the block form (the title, a `Usage:` line
# for the path, the rows under it under their headings, the `More:` line) for a path other rows extend, the command form
# (its usage line, its description as a sentence, the page entry holding its options) for a row. A path ending in `list`
# under a `[list]` row is that row's command form. Returns 1 and prints nothing for a path the rows do not
# hold.
ai_tools_help__render_hint() {
    local program="$1" path="$2" width row block="" prefix page for_usage="" title
    local -a rows=()
    _ai_tools_help__rows "${program}" rows || return 1
    prefix="$(_ai_tools_help__command_prefix "${program}")"
    page="${program}"
    if _ai_tools_help__is_extended_path "${program}" "${path}"; then
        width="$(_ai_tools_help__label_width "${program}")"
        for row in "${rows[@]}"; do
            _ai_tools_help__split_row "${row}"
            [[ "${_AI_TOOLS_HELP__PATH}" == "${path}" || "${_AI_TOOLS_HELP__PATH}" == "${path} "* ]] || continue
            _ai_tools_help__has_flag "${_AI_TOOLS_HELP__FLAGS}" for && for_usage=" [--for OPERATOR]"
        done
        case "${program}" in
            ai-tools)       title="${_AI_TOOLS_HELP__TITLE_AI_TOOLS}" ;;
            ai-tools-admin) title="${_AI_TOOLS_HELP__TITLE_AI_TOOLS_ADMIN}" ;;
        esac
        printf '%s\n\nUsage:\n  %s%s %s COMMAND [ARGUMENT...] [OPTION...]\n' "${title}" "${prefix}" "${for_usage}" "${path}"
        for row in "${rows[@]}"; do
            _ai_tools_help__split_row "${row}"
            [[ "${_AI_TOOLS_HELP__PATH}" == "${path}" || "${_AI_TOOLS_HELP__PATH}" == "${path} "* ]] || continue
            if [[ "${_AI_TOOLS_HELP__BLOCK}" != "${block}" ]]; then
                printf '\n%s:\n' "${_AI_TOOLS_HELP__BLOCK}"
                block="${_AI_TOOLS_HELP__BLOCK}"
            fi
            _ai_tools_help__print_row "${width}"
        done
        printf '\nMore: man %s · %s help\n' "${page}" "${prefix}"
        return 0
    fi
    if ! _ai_tools_help__find_row "${program}" "${path}"; then
        [[ "${path}" == *" list" ]] || return 1
        _ai_tools_help__find_row "${program}" "${path% list}" || return 1
        [[ "${_AI_TOOLS_HELP__ARGUMENT}" == "[list]" ]] || return 1
    fi
    _ai_tools_help__has_flag "${_AI_TOOLS_HELP__FLAGS}" for && for_usage=" [--for OPERATOR]"
    printf 'Usage:\n  %s%s %s [OPTION...]\n\n%s.\n\nOptions: man %s, under %s\n' \
        "${prefix}" "${for_usage}" "$(_ai_tools_help__command_label)" "${_AI_TOOLS_HELP__DESCRIPTION}" \
        "${page}" "${_AI_TOOLS_HELP__PATH}"
}

# ai_tools_help__format_help_command <program> <path>: the help command for the deepest prefix of <path> the rows hold
# -- `atr projects help`, `atr admin system layout help` -- or the program's top help command where no prefix is known.
# The caller writes the unknown-command line around it, so each emit site keeps its own message.
ai_tools_help__format_help_command() {
    local program="$1" prefix known="" candidate="" word
    local -a words=()
    prefix="$(_ai_tools_help__command_prefix "${program}")"
    IFS=' ' read -ra words <<<"$2"
    for word in "${words[@]+"${words[@]}"}"; do
        candidate="${candidate:+${candidate} }${word}"
        _ai_tools_help__is_known_path "${program}" "${candidate}" || break
        known="${candidate}"
    done
    printf '%s %shelp' "${prefix}" "${known:+${known} }"
}

# ai_tools_help__resolve_request <program> [<admin-commands-dir>] -- <arg>...: read a command line as the help contract
# reads it, over the arguments before the first `--`, and print the help target it names.
#
#   0  a help request on a path the rows hold: prints `-` for the top help, or the path
#   1  not a help request: prints nothing
#   2  a help request on an unknown path: prints the typed path through the first word that does not extend a row
#   3  the first command word is a contributed domain (ai-tools-admin, discovered from <admin-commands-dir>): prints
#      the domain, and the caller forwards the line to it
#
# `--version` in the first slot is the version and not a help request, whatever follows it. A help request is `-h`
# or `--help` in any position, or the bare word `help` where the grammar expects a command word: first (the prefix form,
# whose target is the words after it) or after a path other rows extend. The target is the leading run of command words,
# the help flags left out, consumed while each extends a path the rows hold. After a complete row a further word is
# that command's argument; after a path other rows extend it is an unknown path, except `list` under a `[list]` row,
# which names that row. An empty command line is the top help.
ai_tools_help__resolve_request() {
    local program="$1" commands_dir="" argument path="" word candidate
    local has_flag=0 has_word=0 prefix_form=0 at_first=1
    local -a words=() rows=()
    shift
    _ai_tools_help__rows "${program}" rows || return 1
    if [[ "${1-}" != -- ]]; then commands_dir="${1-}"; shift; fi
    [[ "${1-}" == -- ]] && shift
    [[ "${1-}" != --version ]] || return 1
    for argument in "$@"; do
        [[ "${argument}" != -- ]] || break
        case "${argument}" in
            -h|--help) has_flag=1 ;;
            *)         words+=("${argument}") ;;
        esac
    done
    if (( ${#words[@]} == 0 )); then
        (( has_flag == 1 || $# == 0 )) || return 1
        printf -- '-\n'; return 0
    fi
    for word in "${words[@]}"; do
        if (( at_first == 1 )) && [[ "${word}" == help ]] && (( prefix_form == 0 )); then
            prefix_form=1; has_word=1; continue
        fi
        # A first word takes the domain grammar, wider than a command word's by the digits, so a contributed domain such
        # as `agent2` reaches the discovery; every later word takes the command-word grammar.
        if [[ -z "${path}" ]]; then
            [[ "${word}" =~ ^[a-z][a-z0-9-]*$ ]] || break
        else
            [[ "${word}" =~ ^[a-z][a-z-]*$ ]] || break
        fi
        if [[ -n "${path}" ]] && _ai_tools_help__is_extended_path "${program}" "${path}"; then
            if [[ "${word}" == help ]]; then has_word=1; break; fi
        fi
        candidate="${path:+${path} }${word}"
        if _ai_tools_help__is_known_path "${program}" "${candidate}"; then
            path="${candidate}"; at_first=0; continue
        fi
        if [[ -z "${path}" ]]; then
            (( has_flag == 1 || has_word == 1 )) || return 1
            if [[ "${program}" == ai-tools-admin && -n "${commands_dir}" ]]; then
                ai_tools_help__read_admin_domains "${commands_dir}"
                local domain
                for domain in "${AI_TOOLS_HELP__ADMIN_DOMAINS[@]}"; do
                    if [[ "${domain}" == "${word}" ]]; then printf '%s\n' "${word}"; return 3; fi
                done
            fi
            printf '%s\n' "${word}"; return 2
        fi
        if _ai_tools_help__is_extended_path "${program}" "${path}"; then
            if [[ "${word}" == list ]] && _ai_tools_help__find_row "${program}" "${path}" \
                    && [[ "${_AI_TOOLS_HELP__ARGUMENT}" == "[list]" ]]; then
                path="${path} list"; break
            fi
            (( has_flag == 1 || has_word == 1 )) || return 1
            printf '%s\n' "${candidate}"; return 2
        fi
        break
    done
    (( has_flag == 1 || has_word == 1 )) || return 1
    printf '%s\n' "${path:--}"
    return 0
}

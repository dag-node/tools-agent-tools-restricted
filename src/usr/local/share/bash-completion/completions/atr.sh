# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/share/bash-completion/completions/atr -- bash completion for atr, ai-tools and ai-tools-admin. The files
# named ai-tools and ai-tools-admin beside it are links to this one, since bash-completion loads a completion
# by the name of the command being completed, and this file registers all three. `atr admin` completes
# as ai-tools-admin, read as the first word alone, as the wrapper reads it.
#
# The command words, the options each takes and the values an option or argument takes are this file's data, held
# to each program's usage() and man page by tests/unit/completion.sh. Host data -- the enrolled operators, the agent
# manifests, the contributed admin domains, the SELinux groups -- is read from the root-owned file that holds it,
# as text and through a charset, so a TAB never runs a program of this project and never sources a library
# into the shell completing it. Each name read that way is held to a lower-case charset before it reaches `compgen -W`,
# which expands the words it is given. cli-grammar.rule.md states the command surface this completes.
#
# Sourced into an interactive shell, so every name carries the module prefix, no name is readonly (a re-source must
# succeed), each function pins IFS locally, and no expansion globs.
# shellcheck shell=bash

# _ai_tools_atr__list_operators <conf> : print each name the OPERATORS key of operator.conf lists, one per line.
_ai_tools_atr__list_operators() {
    local IFS=$' \t\n' conf="$1" line value="" name
    local -a names=()
    [[ -r "${conf}" ]] || return 0
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*OPERATORS[[:space:]]*=(.*)$ ]] && value="${BASH_REMATCH[1]}"
    done < "${conf}"
    value="${value%%#*}"
    value="${value//[\[\]\"\',]/ }"
    read -ra names <<< "${value}"
    for name in "${names[@]}"; do
        [[ "${name}" =~ ^[a-z_][a-z0-9_-]*$ ]] && printf '%s\n' "${name}"
    done
    return 0
}

# _ai_tools_atr__list_names <dir> <suffix> : print each entry of <dir> ending in <suffix>, the suffix removed,
# whose remaining name is a lower-case word.
_ai_tools_atr__list_names() {
    local IFS=$' \t\n' dir="$1" suffix="$2" entry name
    [[ -d "${dir}" ]] || return 0
    while IFS= read -r entry; do
        [[ "${entry}" == *"${suffix}" ]] || continue
        name="${entry%"${suffix}"}"
        [[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] && printf '%s\n' "${name}"
    done < <(command ls -1A -- "${dir}" 2>/dev/null)
    return 0
}

# _ai_tools_atr__list_admin_domains <dir> : print each domain a provider package contributes to ai-tools-admin, less
# the names base reserves, which the dispatch refuses as a domain.
_ai_tools_atr__list_admin_domains() {
    local name
    while IFS= read -r name; do
        case "${name}" in operators|selinux|system|status|assets|help) continue ;; esac
        printf '%s\n' "${name}"
    done < <(_ai_tools_atr__list_names "$1" "")
}

# _ai_tools_atr__list_selinux_groups <all|stable> <lib> : print each optional SELinux group the registry names, or its
# stable ones alone, which are the ones `selinux groups enable` loads.
_ai_tools_atr__list_selinux_groups() {
    local IFS=$' \t\n' which="$1" lib="$2" line
    local record_re='^[[:space:]]+"([a-z][a-z0-9]*)\|.*\|(stable|experimental)"$'
    [[ -r "${lib}" ]] || return 0
    while IFS= read -r line; do
        [[ "${line}" =~ ${record_re} ]] || continue
        [[ "${which}" == stable && "${BASH_REMATCH[2]}" != stable ]] && continue
        printf '%s\n' "${BASH_REMATCH[1]}"
    done < "${lib}"
    return 0
}

# _ai_tools_atr__list_words <program> <kind> <path> : print the words of one kind the command path takes, one per line,
# where <program> is ai-tools or ai-tools-admin and <path> is the command words typed so far, space-joined. <kind> is
# `commands` (the words that extend the path), `options` (the options it takes), or `values` (the options among those
# that take the next word as their value).
_ai_tools_atr__list_words() {
    local IFS=$' \t\n' words=""
    case "$1:$2:$3" in
        ai-tools:commands:)                   words="projects providers status audit stop help" ;;
        ai-tools:commands:projects)           words="list create claim unclaim remove disable enable clone push lockdown handback" ;;
        ai-tools:commands:providers)          words="list" ;;
        ai-tools:options:)                    words="--help --version --for" ;;
        ai-tools:options:projects|ai-tools:options:projects\ list) words="--for" ;;
        ai-tools:options:projects\ create)    words="--for" ;;
        ai-tools:options:projects\ claim)     words="--yes --format --for" ;;
        ai-tools:options:projects\ unclaim)   words="--force --full --keep-entry --dry-run --yes --group --for" ;;
        ai-tools:options:projects\ remove)    words="--yes --for" ;;
        ai-tools:options:projects\ disable)   words="--for" ;;
        ai-tools:options:projects\ enable)    words="--for" ;;
        ai-tools:options:projects\ clone)     words="--from --branch --dir --yes" ;;
        ai-tools:options:projects\ lockdown)  words="--dry-run --yes --for" ;;
        ai-tools:options:projects\ handback)  words="--full --for" ;;
        ai-tools:options:audit)               words="--since" ;;
        ai-tools:options:stop)                words="--all --dry-run --yes --force" ;;
        ai-tools:values:*)                    words="--for --format --group --since --from --branch --dir" ;;
        ai-tools-admin:commands:)             words="operators selinux system status assets help" ;;
        ai-tools-admin:commands:operators)    words="list add remove" ;;
        ai-tools-admin:commands:selinux)      words="groups" ;;
        ai-tools-admin:commands:selinux\ groups) words="list enable disable" ;;
        ai-tools-admin:commands:system)       words="bootstrap entrypoints post-upgrade layout" ;;
        ai-tools-admin:commands:system\ entrypoints) words="relabel" ;;
        ai-tools-admin:commands:system\ layout) words="list reconcile" ;;
        ai-tools-admin:commands:assets)       words="list enable disable reconcile" ;;
        ai-tools-admin:options:)              words="--help --version" ;;
        ai-tools-admin:options:system\ bootstrap) words="--scope --agents" ;;
        ai-tools-admin:options:system\ post-upgrade) words="--check --all --format" ;;
        ai-tools-admin:options:system\ layout|ai-tools-admin:options:system\ layout\ list) words="--check --all --format" ;;
        ai-tools-admin:options:system\ layout\ reconcile) words="--without-rpm" ;;
        ai-tools-admin:options:assets\ enable) words="--set" ;;
        ai-tools-admin:values:*)              words="--scope --agents --format --set" ;;
    esac
    local -a list=()
    read -ra list <<< "${words}"
    (( ${#list[@]} )) && printf '%s\n' "${list[@]}"
    return 0
}

# _ai_tools_atr__is_member <word> <list>... : true when <word> is one of the list's words.
_ai_tools_atr__is_member() {
    local word="$1" member; shift
    for member in "$@"; do [[ "${member}" == "${word}" ]] && return 0; done
    return 1
}

# _ai_tools_atr__reply <word>... : set COMPREPLY to the words that complete the current word.
_ai_tools_atr__reply() {
    local IFS=$' \t\n'
    mapfile -t COMPREPLY < <(compgen -W "$*" -- "${_ai_tools_atr__cur}")
}

# _ai_tools_atr__complete_value <program> <option> : complete the value of an option that takes one.
_ai_tools_atr__complete_value() {
    local IFS=$' \t\n' head=""
    case "$1:$2" in
        ai-tools:--for)             _ai_tools_atr__reply "$(_ai_tools_atr__list_operators /etc/ai-tools/operator.conf)" ;;
        ai-tools:--group)           mapfile -t COMPREPLY < <(compgen -g -- "${_ai_tools_atr__cur}") ;;
        *:--format)                 _ai_tools_atr__reply tsv ;;
        ai-tools-admin:--scope)     _ai_tools_atr__reply minimal full ;;
        ai-tools-admin:--agents)
            # A comma-separated list: the names already typed stay, and the one after the last comma completes.
            [[ "${_ai_tools_atr__cur}" == *,* ]] && head="${_ai_tools_atr__cur%,*},"
            mapfile -t COMPREPLY < <(compgen -P "${head}" -W "$(_ai_tools_atr__list_names /usr/local/lib/ai-tools/agents.d .conf)" \
                -- "${_ai_tools_atr__cur##*,}")
            compopt -o nospace 2>/dev/null || : ;;
        *) COMPREPLY=() ;;
    esac
}

# _ai_tools_atr__complete_argument <program> <path> : complete the argument a command path takes.
_ai_tools_atr__complete_argument() {
    case "$1:$2" in
        ai-tools:projects\ list) COMPREPLY=() ;;
        ai-tools:projects\ *)
            compopt -o filenames 2>/dev/null || :
            mapfile -t COMPREPLY < <(compgen -d -- "${_ai_tools_atr__cur}") ;;
        ai-tools-admin:operators\ add) mapfile -t COMPREPLY < <(compgen -u -- "${_ai_tools_atr__cur}") ;;
        ai-tools-admin:operators\ remove) _ai_tools_atr__reply "$(_ai_tools_atr__list_operators /etc/ai-tools/operator.conf)" ;;
        ai-tools-admin:selinux\ groups\ enable) _ai_tools_atr__reply "$(_ai_tools_atr__list_selinux_groups stable /usr/local/lib/ai-tools/selinux-groups.lib.sh)" ;;
        ai-tools-admin:selinux\ groups\ disable) _ai_tools_atr__reply "$(_ai_tools_atr__list_selinux_groups all /usr/local/lib/ai-tools/selinux-groups.lib.sh)" ;;
        *) COMPREPLY=() ;;
    esac
}

# _ai_tools_atr__complete -- the completion function the three commands register. Reads COMP_WORDS and COMP_CWORD, sets
# COMPREPLY. The words before the current one decide the program (`atr admin` is ai-tools-admin) and the command path,
# which is the run of words each extending the path before it; an option's value is skipped, and a word that does not
# extend the path is an argument, after which no command word completes. `--for` is read wherever it stands, as ai-tools
# reads it.
_ai_tools_atr__complete() {
    local IFS=$' \t\n' program="${COMP_WORDS[0]##*/}" _ai_tools_atr__cur="${COMP_WORDS[COMP_CWORD]}"
    local path="" word option="" argument=0 i
    local -a words=("${COMP_WORDS[@]:1:COMP_CWORD-1}") commands=() values=() domains=()
    COMPREPLY=()
    # COMP_WORDBREAKS splits `--for=op` into three words; read the pair back as the option and the value being typed.
    if [[ "${_ai_tools_atr__cur}" == = && "${#words[@]}" -gt 0 ]]; then
        option="${words[-1]}" _ai_tools_atr__cur=""
    elif [[ "${#words[@]}" -gt 1 && "${words[-1]}" == = ]]; then
        option="${words[-2]}"
    fi
    case "${program}" in
        atr)
            program=ai-tools
            if [[ "${words[0]:-}" == admin ]]; then
                program=ai-tools-admin; words=("${words[@]:1}")
            elif [[ "${#words[@]}" -eq 0 && -z "${option}" && "${_ai_tools_atr__cur}" != -* ]]; then
                _ai_tools_atr__reply "admin $(_ai_tools_atr__list_words ai-tools commands "")"
                return 0
            fi ;;
        ai-tools|ai-tools-admin) ;;
        *) return 0 ;;
    esac
    mapfile -t values < <(_ai_tools_atr__list_words "${program}" values "")
    [[ "${program}" == ai-tools-admin ]] \
        && mapfile -t domains < <(_ai_tools_atr__list_admin_domains /usr/local/lib/ai-tools/admin-commands.d)
    if [[ -z "${option}" && "${#words[@]}" -gt 0 ]] && _ai_tools_atr__is_member "${words[-1]}" "${values[@]}"; then
        option="${words[-1]}"
    fi
    if [[ -n "${option}" ]]; then
        _ai_tools_atr__complete_value "${program}" "${option}"
        return 0
    fi
    for (( i = 0; i < ${#words[@]}; i++ )); do
        word="${words[i]}"
        if [[ "${word}" == -* ]]; then
            [[ "${word}" != *=* ]] && _ai_tools_atr__is_member "${word}" "${values[@]}" && i=$(( i + 1 ))
            continue
        fi
        [[ "${word}" == = ]] && { i=$(( i + 1 )); continue; }
        (( argument )) && continue
        mapfile -t commands < <(_ai_tools_atr__list_words "${program}" commands "${path}")
        [[ -z "${path}" ]] && commands+=("${domains[@]}")
        if _ai_tools_atr__is_member "${word}" "${commands[@]}"; then
            path="${path:+${path} }${word}"
        else
            argument=1
        fi
    done
    if [[ "${_ai_tools_atr__cur}" == -* ]]; then
        if [[ "${program}" == ai-tools-admin && -n "${path}" && "${path}" != *' '* ]] \
                && _ai_tools_atr__is_member "${path}" "${domains[@]}"; then
            _ai_tools_atr__reply --help
        else
            _ai_tools_atr__reply "$(_ai_tools_atr__list_words "${program}" options "${path}")"
        fi
        return 0
    fi
    if (( ! argument )); then
        mapfile -t commands < <(_ai_tools_atr__list_words "${program}" commands "${path}")
        [[ -z "${path}" ]] && commands+=("${domains[@]}")
        if (( ${#commands[@]} )); then
            _ai_tools_atr__reply "${commands[*]}"
            return 0
        fi
    fi
    _ai_tools_atr__complete_argument "${program}" "${path}"
}

complete -F _ai_tools_atr__complete atr ai-tools ai-tools-admin

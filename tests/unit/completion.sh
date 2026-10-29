#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/completion.sh
# Hermetic check of the bash completion for atr, ai-tools and ai-tools-admin
# (src/usr/local/share/bash-completion/completions/atr.sh). The completion carries the command surface as data of its
# own, so what goes stale is a command or an option the programs gained or renamed while the completion kept the old
# word. Four groups of checks:
#   (1) the command paths the completion offers, walked from the root, are the ones each program's usage() lists, in
#       both directions, with a path ending in `list` read as the bare collection, as each program reads it;
#   (2) every option a command's man page entry names on its tag line is offered after that command, `-y` by its long
#       form, and every option offered anywhere is one the page documents;
#   (3) each reader of host data -- the enrolled operators, the agent manifests, the contributed admin domains,
#       the SELinux groups -- yields the names its fixture holds and no name outside the charset, since `compgen -W`
#       expands the words it is given, and the SELinux reader agrees with the registry the library holds;
#   (4) typed command lines complete to the words each must offer, with the host readers stubbed, `atr admin` read
#       as ai-tools-admin and `--for` read wherever it stands.
#
# Pure text and in-process: the checkout's completion file is sourced into this shell, and no program of this project
# runs. Unprivileged, and reads the checkout alone; skips outside one.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPLETION="${ROOT}/src/usr/local/share/bash-completion/completions/atr.sh"
CLI="${ROOT}/src/usr/local/bin/ai-tools.sh"
ADMIN="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
PAGE1="${ROOT}/src/usr/local/share/man/man1/ai-tools.1"
PAGE8="${ROOT}/src/usr/local/share/man/man8/ai-tools-admin.8"
GROUPS_LIB="${ROOT}/src/usr/local/lib/ai-tools/selinux-groups.lib.sh"
section "completion: atr, ai-tools and ai-tools-admin complete the commands and options each program takes (unit)"

for file in "${COMPLETION}" "${CLI}" "${ADMIN}" "${PAGE1}" "${PAGE8}" "${GROUPS_LIB}"; do
    if [[ ! -r "${file}" ]]; then
        skip "completion" "not a source checkout (no ${file})"
        finish; exit
    fi
done
mktestdir

# shellcheck source=../../src/usr/local/share/bash-completion/completions/atr.sh
source "${COMPLETION}"
registered="$(complete -p atr ai-tools ai-tools-admin 2>/dev/null || true)"
if [[ "$(grep -c -- '-F _ai_tools_atr__complete ' <<< "${registered}")" == 3 ]]; then
    pass "sourcing the file registers the completion for atr, ai-tools and ai-tools-admin"
else
    fail "the completion is not registered for all three names: ${registered}"
fi

# ── (1) The command paths ──────────────────────────────────────────────────────────────────────
# usage_commands <script>: the command paths the script's usage() lists, man.sh's help_commands reading.
usage_commands() {
    sed -n '/^usage() {/,/^EOF$/p' "$1" \
        | sed -n 's/^    \([a-z][^ ].*\)  \+[^ ].*/\1/p' \
        | sed -E -e 's/[[:space:]]*[[<].*$//' -e 's/[[:space:]]*$//' -e 's/ [A-Z][A-Z_]*(\.\.\.)?$//' | sort -u
}
# completion_commands <program> [path]: every command path the completion offers under <path>, a leaf path ending
# in `list` printed as its collection. `help` is the bare-word spelling of `--help`, which usage() lists as the option.
completion_commands() {
    local program="$1" path="${2:-}" child children
    children="$(_ai_tools_atr__list_words "${program}" commands "${path}")"
    if [[ -z "${children}" ]]; then
        printf '%s\n' "${path% list}"
        return 0
    fi
    while IFS= read -r child; do
        [[ -z "${path}" && "${child}" == help ]] && continue
        completion_commands "${program}" "${path:+${path} }${child}"
    done <<< "${children}"
}
for pair in "ai-tools:${CLI}" "ai-tools-admin:${ADMIN}"; do
    program="${pair%%:*}" script="${pair#*:}"
    offered="$(completion_commands "${program}" | sort -u)"
    listed="$(usage_commands "${script}")"
    if [[ -z "${offered}" || -z "${listed}" ]]; then
        fail "${program}: a command set read empty (completion '${offered//$'\n'/, }', usage '${listed//$'\n'/, }')"
        continue
    fi
    missing="$(comm -13 <(printf '%s\n' "${offered}") <(printf '%s\n' "${listed}"))"
    extra="$(comm -23 <(printf '%s\n' "${offered}") <(printf '%s\n' "${listed}"))"
    [[ -z "${missing}" ]] && pass "${program}: every command its usage() lists is offered" \
        || fail "${program}: command(s) the completion does not offer: ${missing//$'\n'/, }"
    [[ -z "${extra}" ]] && pass "${program}: the completion offers no command its usage() omits" \
        || fail "${program}: command(s) the completion offers that usage() does not list: ${extra//$'\n'/, }"
done

# ── (2) The options ────────────────────────────────────────────────────────────────────────────
# read_man <page>: the page with troff's escaped hyphens flattened.
read_man() { sed 's/\\-/-/g' "$1"; }
# tag_lines <page>: `<command path><TAB><options>` for each top-level COMMANDS entry whose tag line names an option.
tag_lines() {
    read_man "$1" | awk '/^\.SH COMMANDS/{s=1; next} /^\.SH /{s=0} !s{next}
        /^\.RS/{d++; next} /^\.RE/{if (d>0) d--; next}
        /^\.TP/{if (d==0) want=1; next}
        want && /^\.(B|BR|BI) /{ want=0; line=$0; sub(/^\.(B|BR|BI) /, "", line); cmd=line; sub(/\\f.*$/, "", cmd)
            gsub(/"/, "", cmd); sub(/[[:space:]]+$/, "", cmd); opts=""
            while (match(line, /\\fB-{1,2}[a-z][a-z-]*/)) { opts=opts " " substr(line, RSTART+3, RLENGTH-3)
                line=substr(line, RSTART+RLENGTH) }
            if (opts != "") print cmd "\t" substr(opts, 2) }'
}
# documented_options <page>: every option token the page holds.
documented_options() { read_man "$1" | grep -oE '(^|[^a-z-])-{1,2}[a-z][a-z-]*' | grep -oE -- '-{1,2}[a-z][a-z-]*' | sort -u; }
for pair in "ai-tools:${PAGE1}" "ai-tools-admin:${PAGE8}"; do
    program="${pair%%:*}" page="${pair#*:}"
    tags="$(tag_lines "${page}")" problems=0 checked=0
    if [[ -z "${tags}" ]]; then
        fail "${program}: no COMMANDS entry naming an option was read from its page"
        continue
    fi
    while IFS=$'\t' read -r cmd options; do
        offered=" $(_ai_tools_atr__list_words "${program}" options "${cmd}" | tr '\n' ' ')"
        for option in ${options}; do
            [[ "${option}" == -y ]] && option=--yes
            checked=$(( checked + 1 ))
            [[ "${offered}" == *" ${option} "* ]] && continue
            fail "${program}: '${cmd}' documents ${option}, which the completion does not offer after it"
            problems=$(( problems + 1 ))
        done
    done <<< "${tags}"
    (( problems == 0 )) && pass "${program}: each option a command's tag line names is offered after it (${checked})"
    documented="$(documented_options "${page}")"
    undocumented=""
    while IFS= read -r path; do
        while IFS= read -r option; do
            [[ -n "${option}" ]] || continue
            grep -qxF -- "${option}" <<< "${documented}" || undocumented+=" ${option} (${path:-the bare command})"
        done < <(_ai_tools_atr__list_words "${program}" options "${path}"; _ai_tools_atr__list_words "${program}" values "")
    done < <(printf '\n'; completion_commands "${program}"; completion_commands "${program}" | sed -n 's/$/ list/p')
    [[ -z "${undocumented}" ]] && pass "${program}: every option the completion offers is one its page documents" \
        || fail "${program}: option(s) offered that the page does not document:${undocumented}"
done

# ── (3) The readers of host data ───────────────────────────────────────────────────────────────
# The words `compgen -W` receives are expanded, so a name carrying `$(...)`, a glob or a space is refused, and a run
# that reached the expansion would create MARKER.
MARKER="${TESTDIR}/expanded"
conf="${TESTDIR}/operator.conf"
printf '%s\n' '# OPERATORS=ignored' 'OPERATORS=early' \
    "OPERATORS=\"[alice, bob_2,svc-ci \$(touch ${MARKER}) Upper *]\"  # the enrolled operators" > "${conf}"
read_operators="$(_ai_tools_atr__list_operators "${conf}" | tr '\n' ' ')"
[[ "${read_operators}" == 'alice bob_2 svc-ci ' ]] \
    && pass "the operator reader takes the last OPERATORS line, in either list form, and refuses a name outside the charset" \
    || fail "the operator reader read [${read_operators}]"
[[ -z "$(_ai_tools_atr__list_operators "${TESTDIR}/absent.conf")" ]] \
    && pass "an absent operator.conf yields no operator" || fail "an absent operator.conf yielded a name"

domains="${TESTDIR}/admin-commands.d"
mkdir -p "${domains}"
for name in demo dotnet system help Bad.Name 'x$(id)' 'two words'; do : > "${domains}/${name}"; done
read_domains="$(_ai_tools_atr__list_admin_domains "${domains}" | sort | tr '\n' ' ')"
[[ "${read_domains}" == 'demo dotnet ' ]] \
    && pass "the domain reader lists the contributed names, less the reserved ones and any outside the charset" \
    || fail "the domain reader read [${read_domains}]"

agents="${TESTDIR}/agents.d"
mkdir -p "${agents}"
for name in acme.conf claude-code.conf README notes.conf.bak 'bad name.conf'; do : > "${agents}/${name}"; done
read_agents="$(_ai_tools_atr__list_names "${agents}" .conf | sort | tr '\n' ' ')"
[[ "${read_agents}" == 'acme claude-code ' ]] \
    && pass "the agent reader lists each manifest's name and nothing else in the directory" \
    || fail "the agent reader read [${read_agents}]"

# The registry the library holds is the reference; the reader takes the same names from the file's text.
registry_all="$(bash -c 'source "$1"; for e in "${AI_TOOLS_SELINUX_GROUPS__REGISTRY[@]}"; do printf "%s\n" "${e%%|*}"; done' \
    _ "${GROUPS_LIB}")"
registry_stable="$(bash -c 'source "$1"; for e in "${AI_TOOLS_SELINUX_GROUPS__REGISTRY[@]}"; do
    [[ "${e##*|}" == stable ]] && printf "%s\n" "${e%%|*}"; done; true' _ "${GROUPS_LIB}")"
read_all="$(_ai_tools_atr__list_selinux_groups all "${GROUPS_LIB}")"
read_stable="$(_ai_tools_atr__list_selinux_groups stable "${GROUPS_LIB}")"
if [[ -n "${registry_all}" && "${read_all}" == "${registry_all}" && "${read_stable}" == "${registry_stable}" ]]; then
    pass "the SELinux group reader yields the registry's groups, and its stable ones for enable"
else
    fail "the SELinux group reader read [${read_all//$'\n'/ }] / [${read_stable//$'\n'/ }], the registry holds [${registry_all//$'\n'/ }] / [${registry_stable//$'\n'/ }]"
fi
[[ ! -e "${MARKER}" ]] && pass "no name a reader saw was expanded" || fail "a name a reader saw was expanded"

# ── (4) Typed command lines ────────────────────────────────────────────────────────────────────
# The host readers are stubbed, so a case reads the same names on every host; the directory argument completes
# in a fixture tree.
_ai_tools_atr__list_operators() { printf '%s\n' alice svc-ci; }
_ai_tools_atr__list_admin_domains() { printf '%s\n' dotnet; }
_ai_tools_atr__list_names() { printf '%s\n' acme claude-code; }
_ai_tools_atr__list_selinux_groups() { if [[ "$1" == stable ]]; then printf 'tmpmap\n'; else printf 'tmpmap\npodman\n'; fi; }
mkdir -p "${TESTDIR}/tree/proj-a" "${TESTDIR}/tree/proj-b" "${TESTDIR}/tree/other"
: > "${TESTDIR}/tree/proj-file"

# completes <expected> <word>...: completing the last word of the line yields exactly the words of <expected>,
# compared sorted. Readline sorts a reply before it shows one, and `compgen -d` lists in the order the filesystem
# returns, which an overlay mount reverses.
completes() {
    local expected="$1" got words=(); shift
    COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); COMPREPLY=()
    ( cd "${TESTDIR}/tree" && _ai_tools_atr__complete && printf '%s\n' "${COMPREPLY[@]}" ) > "${TESTDIR}/reply"
    got="$(LC_ALL=C sort "${TESTDIR}/reply" | paste -sd ' ')"
    IFS=' ' read -ra words <<< "${expected}"
    expected="$(printf '%s\n' "${words[@]}" | LC_ALL=C sort | paste -sd ' ')"
    if [[ "${got}" == "${expected}" ]]; then
        pass "'$*' completes to [${expected}]"
    else
        fail "'$*' completes to [${got}], expected [${expected}]"
    fi
}
completes "admin projects providers status audit stop help" atr ""
completes "projects providers" atr pro
completes "projects providers status audit stop help" ai-tools ""
completes "claim clone" atr projects cl
completes "--yes --format --for" atr projects claim -
completes "tsv" atr projects claim --format ""
completes "proj-a proj-b" atr projects claim proj
completes "proj-a proj-b" atr projects claim --format tsv proj
completes "alice svc-ci" atr --for ""
completes "alice svc-ci" atr --for = ""
completes "list create claim unclaim remove disable enable clone push lockdown handback" atr --for alice projects ""
completes "" atr --for alice admin ""
completes "operators selinux system status assets help dotnet" atr admin ""
completes "operators selinux system status assets help dotnet" ai-tools-admin ""
completes "bootstrap entrypoints post-upgrade layout" atr admin system ""
completes "minimal full" ai-tools-admin system bootstrap --scope ""
completes "acme,claude-code" atr admin system bootstrap --agents acme,cl
completes "tmpmap" atr admin selinux groups enable ""
completes "tmpmap podman" atr admin selinux groups disable ""
completes "alice svc-ci" atr admin operators remove ""
completes "--check --all --format" atr admin system layout -
completes "--help" atr admin dotnet -
completes "--all --dry-run --yes --force" atr stop -
completes "" atr status ""

finish

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/assets.lib.sh
# The assets resolver: which asset of which installed set each agent session loads. AI_TOOLS_ASSETS in operator.conf
# names assets as <set>/<kind>/<name>; this library finds each set under the roots in their search order, holds it
# to its signature (assets-verify.lib.sh) and to the subset of format 1 base enforces, resolves every entry of the list
# to one state, and keeps the view -- one root-owned symlink per linked asset in <home>/<kind> -- and each enabled
# agent's links into the view current. Sourced as root by ai-tools-admin, whose `assets` verbs and `status` section are
# its callers; the conformance job sources it for ai_tools_assets__validate_set alone, which reads a tree and does not
# take an ownership input. The roots, the reason tokens, the view transaction and the per-agent rules are
# in shipped-assets.rule.md.
#
# Every reader's failure leaves an asset unlinked and reported: an untrusted or unreadable operator.conf, root, set
# or file, a verifier status other than 0, and a rule the subset refuses each resolve the entries they cover to a token
# that is not `linked`, and the next transaction removes every resolver link no input still justifies. The library reads
# a set's files as data: it does not source, execute or import one.
#
# The view transaction is ai_tools_assets__reconcile: the lock, then ai_tools_assets__plan, which reads every input
# and computes the link changes without writing, then the apply, then one record per entry and per change. `status` runs
# the plan alone. A resolver link is recognised by its target alone -- a symlink into one of the roots --
# so the seeder's managed copies share the view directories without a marker.
#
# The root-only test hooks AI_TOOLS_ASSETS_ROOTS and AI_TOOLS_ASSETS_HOME move the roots and the directory holding
# the view and the agent config directories, and managed-assets.lib.sh's AI_TOOLS_ASSETS_LOCK
# and AI_TOOLS_ASSETS_LOCK_WAIT the lock and the wait for it; each has the standing of AI_TOOLS_ASSETS_BINDINGS_DIR:
# sudo strips the name, and every consumer runs as root.

# Sourced more than once in a single shell: the readonly constants would abort under `set -e` on the second pass.
# An if-statement, not `[[ ]] && return`, which returns 1 for an unset guard and trips the sourcing shell's `set -e`.
if [[ -n "${_AI_TOOLS_ASSETS__LOADED:-}" ]]; then
    return 0
fi

# The libraries this one cannot resolve without, each required: the trust predicate and the list reader (conf),
# the allowlist sanitizer every path and detail passes on its way to a terminal or the journal (log), the record writer
# (records-tsv), the view and config-directory constants with the provider resolvers (control-plane, which loads
# providers), and the managed-copy predicates the view shares with the seeder (managed-assets). Without the provider
# resolvers the library does not know any enabled agent, which would let an asset requiring a profile an agent lacks
# link for every agent.
_ai_tools_assets__lib_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=SCRIPTDIR/conf.lib.sh
source "${_ai_tools_assets__lib_dir}/conf.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/log.lib.sh
source "${_ai_tools_assets__lib_dir}/log.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/records-tsv.lib.sh
source "${_ai_tools_assets__lib_dir}/records-tsv.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/control-plane.lib.sh
source "${_ai_tools_assets__lib_dir}/control-plane.lib.sh" 2>/dev/null || true
# shellcheck source=SCRIPTDIR/managed-assets.lib.sh
source "${_ai_tools_assets__lib_dir}/managed-assets.lib.sh" 2>/dev/null || true
for _ai_tools_assets__required_function in ai_tools_conf__is_trusted ai_tools_conf__read_list ai_tools_conf__is_portable_name_valid \
        ai_tools_log__sanitize ai_tools_log__coded ai_tools_records_tsv__write_record \
        ai_tools_records_tsv__frame_item_components ai_tools_providers__list_enabled_agents ai_tools_providers__list_installed_agents \
        ai_tools_providers__read_agent_manifest_field ai_tools_providers__list_enabled_integrations ai_tools_providers__evaluate_empty_agents \
        ai_tools_control_plane__is_agent_config_dir_valid \
        ai_tools_managed_assets__is_managed ai_tools_managed_assets__is_stale_copy ai_tools_managed_assets__link_asset_readme ai_tools_managed_assets__lock \
        ai_tools_managed_assets__unlock; do
    if ! declare -F "${_ai_tools_assets__required_function}" >/dev/null 2>&1; then
        printf 'assets: %s is not defined, so the assets resolver is not defined\n' "${_ai_tools_assets__required_function}" >&2
        unset _ai_tools_assets__required_function
        return 1
    fi
done
unset _ai_tools_assets__required_function

# The set verifier, loaded as its header asks. A load that fails does not stop this library: every set then resolves
# to set-unverified, so a reconcile still removes every resolver link rather than leaving the last run's in place.
_AI_TOOLS_ASSETS__VERIFIER_LOADED=0
# shellcheck source=SCRIPTDIR/assets-verify.lib.sh
if source "${_ai_tools_assets__lib_dir}/assets-verify.lib.sh" 2>/dev/null && declare -F ai_tools_assets_verify__verify_set >/dev/null 2>&1 \
        && declare -F ai_tools_assets_verify__is_valid_set_name >/dev/null 2>&1; then
    _AI_TOOLS_ASSETS__VERIFIER_LOADED=1
fi
unset _ai_tools_assets__lib_dir
_AI_TOOLS_ASSETS__LOADED=1

# The roots in search order: local, packaged, base. The first two hold <root>/<set>/; the base root is itself the set
# `ai-tools` when it holds a set.conf. The bindings directory is assets-verify.lib.sh's.
: "${AI_TOOLS_ASSETS_ROOTS:=/usr/local/share/ai-tools-assets /usr/share/ai-tools-assets /usr/share/ai-tools}"
: "${AI_TOOLS_ASSETS_HOME:=${CP_HOME}}"
: "${AI_TOOLS_ASSETS_BINDINGS_DIR:=/usr/local/lib/ai-tools/assets-bindings.d}"
: "${AI_TOOLS_OPERATOR_CONF:=/etc/ai-tools/operator.conf}"
# The pristine root whose <kind>/README.md is linked into each agent's kind directory, as the seeder links it.
readonly AI_TOOLS_ASSETS__README_ROOT=/usr/share/ai-tools

# The kind registry: one row per kind a set may carry, `|`-separated, its columns named in row order
# by _AI_TOOLS_ASSETS__KIND_COLUMNS. The view of a kind is <home>/<id>, which is CP_SHARED_SKILLS
# and CP_SHARED_SUBAGENTS at the default home. The root field is the manifest key naming a path outside an agent's
# config directory where it reads the kind's whole view, as codex reads /etc/codex/skills; the plan reports that path
# and does not write it. `orientation` is base's own kind and has no row, so an identifier naming it is kind-unknown.
readonly -a AI_TOOLS_ASSETS__KIND_ROWS=(
    "skills|skills|directory|skills_dir|skills.portable.v1|skills_root"
    "subagents|agents|file|subagents_dir|subagents.claude.v1|"
)
readonly -A _AI_TOOLS_ASSETS__KIND_COLUMNS=( [id]=0 [set_directory]=1 [shape]=2 [manifest_field]=3 [base_profile]=4
                                            [root_field]=5 )
# The capabilities (profile tokens) base defines. A token outside this list is capability-unknown; an agent manifest
# listing one in asset_profiles does not implement it.
readonly -a AI_TOOLS_ASSETS__CAPABILITIES=( skills.portable.v1 subagents.claude.v1 skills.dynamic.v1 )
readonly AI_TOOLS_ASSETS__DYNAMIC_CAPABILITY=skills.dynamic.v1

# The rule ids of format 1 this library is held to the publisher's validator on, the one list the conformance job
# (tools/checkers/assets-conformance.sh) selects the publisher's fixtures by: base refuses a fixture of each
# under the same id. Of frontmatter.syntax the job selects the variants the bounded reader refuses, by name.
# shellcheck disable=SC2034  # read by the conformance job
readonly -a AI_TOOLS_ASSETS__ENFORCED_RULES=(
    set.conf.missing set.conf.syntax set.conf.required-key set.conf.format set.conf.name set.conf.version
    set.conf.requires-capabilities set.conf.requires-integrations set.conf.unknown-key set.entry.unknown
    set.entry.reserved kind.shape kind.reserved name.grammar name.asset-prefix name.frontmatter frontmatter.missing
    frontmatter.required frontmatter.refused-key frontmatter.syntax body.dynamic-injection metadata.asset-conf
    file.symlink file.hardlink file.special file.size file.name file.binary release.inventory skill.entry.unknown
    skill.plugin-manifest skill.sidecar
)

# The enforced subset of format 1, under the format's rule ids. Entry names carry their type, `f` or `d`.
readonly -a _AI_TOOLS_ASSETS__SET_ENTRIES=( set.conf:f CHANGELOG.md:f README.md:f LICENSE:f LICENSES:d plugin.json:f
                                       .claude-plugin:d skills:d agents:d metadata:d )
readonly -a _AI_TOOLS_ASSETS__RELEASE_ENTRIES=( SHA256SUMS:f SHA256SUMS.asc:f )
readonly -a _AI_TOOLS_ASSETS__RESERVED_ENTRIES=( jobs libs variants llms.txt )
readonly -a _AI_TOOLS_ASSETS__RESERVED_KINDS=( jobs mcps commands instructions hooks lsps output-styles settings workflows
                                          themes monitors tools )
readonly -a _AI_TOOLS_ASSETS__SET_CONF_REQUIRED=( format name version summary license maintainers source )
readonly -a _AI_TOOLS_ASSETS__SET_CONF_OPTIONAL=( requires_base requires_integrations requires_capabilities )
readonly -a _AI_TOOLS_ASSETS__SET_CONF_LISTS=( maintainers requires_integrations requires_capabilities )
readonly -a _AI_TOOLS_ASSETS__ASSET_CONF_KEYS=( format requires_capabilities requires_integrations )
readonly -a _AI_TOOLS_ASSETS__SKILL_KEYS=( name description license compatibility metadata )
readonly -a _AI_TOOLS_ASSETS__SUBAGENT_KEYS=( name description model effort color tools disallowedTools skills maxTurns
                                         metadata )
# The entries a skill directory holds, the set the format's rule table names.
readonly -a _AI_TOOLS_ASSETS__SKILL_ENTRIES=( SKILL.md:f scripts:d references:d assets:d tests:d UPSTREAM.conf:f LICENSE:f
                                         LICENSES:d )
# file.binary's byte sequences, read under LC_ALL=C: a C0 control but tab, LF and CR, DEL, a C1 control, the bidi
# controls U+061C, U+200E, U+200F, U+202A to U+202E and U+2066 to U+2069, the byte order mark, and the lead bytes
# of a code point past U+10FFFF (F5 to FF, or F4 then 90 to BF), which glibc's iconv accepts.
readonly _AI_TOOLS_ASSETS__BINARY_BYTES='[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\xf5-\xff]|\xc2[\x80-\x9f]|\xd8\x9c|\xe2\x80[\x8e\x8f\xaa-\xae]|\xe2\x81[\xa6-\xa9]|\xef\xbb\xbf|\xf4[\x90-\xbf]'
# The bounds of the walk the verifier does not hold: directories, depth and entries in one directory. The per-file,
# file-count and payload bounds are the verifier's constants, read with the format's value as the fallback.
readonly _AI_TOOLS_ASSETS__MAX_DIRECTORIES=500
readonly _AI_TOOLS_ASSETS__MAX_DEPTH=32
readonly _AI_TOOLS_ASSETS__MAX_DIRECTORY_ENTRIES=2000
readonly _AI_TOOLS_ASSETS__SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$'

# ── Small predicates ─────────────────────────────────────────────────────────────────────────────────────────────────

# _ai_tools_assets__is_one_of <word> <member>... : succeed when <word> is one of the members.
_ai_tools_assets__is_one_of() {
    local word="$1" member
    shift
    for member in "$@"; do [[ "${member}" == "${word}" ]] && return 0; done
    return 1
}

# _ai_tools_assets__get_kind_field <kind> <column> : print the column of <kind>'s registry row that <column> names
# in _AI_TOOLS_ASSETS__KIND_COLUMNS; returns 1 for a kind without a row or a column name outside that map.
_ai_tools_assets__get_kind_field() {
    local kind="$1" column="$2" index row
    local -a columns=()
    [[ "${column}" =~ ^[a-z_]+$ && -n "${_AI_TOOLS_ASSETS__KIND_COLUMNS[${column}]+x}" ]] || return 1
    index="${_AI_TOOLS_ASSETS__KIND_COLUMNS[${column}]}"
    for row in "${AI_TOOLS_ASSETS__KIND_ROWS[@]}"; do
        IFS='|' read -r -a columns <<< "${row}"
        [[ "${columns[0]}" == "${kind}" ]] || continue
        printf '%s' "${columns[index]:-}"
        return 0
    done
    return 1
}

# _ai_tools_assets__list_kinds : print each registry kind id, one per line.
_ai_tools_assets__list_kinds() {
    local row
    for row in "${AI_TOOLS_ASSETS__KIND_ROWS[@]}"; do printf '%s\n' "${row%%|*}"; done
}

# _ai_tools_assets__is_valid_name <name> : the name grammar of the format, for a set and an asset alike --
# the verifier's set-name predicate. Fails when the verifier did not load, which the resolver has already reported
# for every set.
_ai_tools_assets__is_valid_name() {
    declare -F ai_tools_assets_verify__is_valid_set_name >/dev/null 2>&1 && ai_tools_assets_verify__is_valid_set_name "$1"
}

# _ai_tools_assets__is_capability <token> : succeed when base defines <token>.
_ai_tools_assets__is_capability() { _ai_tools_assets__is_one_of "$1" "${AI_TOOLS_ASSETS__CAPABILITIES[@]}"; }

# _ai_tools_assets__get_entry_paths <kind> <name> : print an asset's path inside its set directory, and the view entry
# name after a tab: `skills/<name>` and `<name>`, `agents/<name>.md` and `<name>.md`.
_ai_tools_assets__get_entry_paths() {
    local kind="$1" name="$2" directory
    directory="$(_ai_tools_assets__get_kind_field "${kind}" set_directory)" || return 1
    if [[ "$(_ai_tools_assets__get_kind_field "${kind}" shape)" == file ]]; then
        printf '%s/%s.md\t%s.md' "${directory}" "${name}" "${name}"
    else
        printf '%s/%s\t%s' "${directory}" "${name}" "${name}"
    fi
}

# _ai_tools_assets__sanitize_for_display <text> : <text> as a detail or a status line carries it, through the allowlist
# sanitizer and at most 200 characters, since a name inside a set or an agent's directory is whoever wrote it.
_ai_tools_assets__sanitize_for_display() { ai_tools_log__sanitize "${1:0:200}"; }

# _ai_tools_assets__is_version_at_least <installed> <required> : succeed when <installed> is a semantic version
# whose SemVer 2.0.0 precedence is equal to or higher than <required>'s. Each numeric component compares by its length
# and then its digits, which the grammar's ban on a leading zero makes exact at any length, so no component overflows
# an integer; a pre-release has lower precedence than its release, and two pre-releases compare identifier by identifier
# (_ai_tools_assets__compare_identifiers), the shorter list lower where every shared identifier is equal; build metadata
# is ignored. An installed version that is not one (`dev` in a checkout) does not satisfy any requirement, and neither
# satisfies a required one that is malformed.
_ai_tools_assets__is_version_at_least() {
    local installed="$1" required="$2" index order installed_prerelease required_prerelease
    local -a installed_components=() required_components=() installed_identifiers=() required_identifiers=()
    [[ "${required}" =~ ${_AI_TOOLS_ASSETS__SEMVER} ]] || return 1
    required_components=( "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" ); required_prerelease="${BASH_REMATCH[5]}"
    [[ "${installed}" =~ ${_AI_TOOLS_ASSETS__SEMVER} ]] || return 1
    installed_components=( "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" ); installed_prerelease="${BASH_REMATCH[5]}"
    for index in 0 1 2; do
        order="$(_ai_tools_assets__compare_identifiers "${installed_components[index]}" "${required_components[index]}")"
        [[ "${order}" == 0 ]] && continue
        [[ "${order}" == 1 ]]
        return
    done
    [[ -z "${installed_prerelease}" ]] && return 0
    [[ -z "${required_prerelease}" ]] && return 1
    IFS=. read -r -a installed_identifiers <<< "${installed_prerelease}"
    IFS=. read -r -a required_identifiers <<< "${required_prerelease}"
    for (( index = 0; index < ${#installed_identifiers[@]} && index < ${#required_identifiers[@]}; index++ )); do
        order="$(_ai_tools_assets__compare_identifiers "${installed_identifiers[index]}" "${required_identifiers[index]}")"
        [[ "${order}" == 0 ]] && continue
        [[ "${order}" == 1 ]]
        return
    done
    (( ${#installed_identifiers[@]} >= ${#required_identifiers[@]} ))
}

# _ai_tools_assets__compare_identifiers <a> <b> : print -1, 0 or 1 as <a> has lower, equal or higher precedence than <b>
# under SemVer 2.0.0: two numeric identifiers by length and then digits, a numeric one lower than an alphanumeric one,
# two alphanumeric ones by byte order.
_ai_tools_assets__compare_identifiers() {
    local a="$1" b="$2" LC_ALL=C
    if [[ "${a}" =~ ^[0-9]+$ && "${b}" =~ ^[0-9]+$ ]]; then
        if (( ${#a} != ${#b} )); then
            (( ${#a} < ${#b} )) && printf -- '-1' || printf 1
            return 0
        fi
    elif [[ "${a}" =~ ^[0-9]+$ ]]; then
        printf -- '-1'; return 0
    elif [[ "${b}" =~ ^[0-9]+$ ]]; then
        printf 1; return 0
    fi
    if [[ "${a}" == "${b}" ]]; then printf 0; elif [[ "${a}" < "${b}" ]]; then printf -- '-1'; else printf 1; fi
}

# ── The KEY=value reader of the format ───────────────────────────────────────────────────────────────────────────────
# set.conf and asset.conf are read with the format's own grammar: conf.lib.sh's grammar reads past what the format
# refuses: a line without `=`, a key given twice, a quote that does not close, text after a closing quote other than
# a `#` comment, and an empty list item. Each is a finding here, so base refuses what the publisher's validator refuses.
# The file is read as data, line by line.

# _ai_tools_assets__read_format_file <file> : read <file> into _AI_TOOLS_ASSETS__KV (key -> value),
# _AI_TOOLS_ASSETS__KV_QUOTED (key -> 1 for a quoted value), _AI_TOOLS_ASSETS__KV_KEYS (keys in file order)
# and _AI_TOOLS_ASSETS__KV_ERRORS (one message per refused
# line).
_ai_tools_assets__read_format_file() {
    local file="$1" line raw key value rest quote trailing number=0 head
    local LC_ALL=C
    declare -gA _AI_TOOLS_ASSETS__KV=() _AI_TOOLS_ASSETS__KV_QUOTED=()
    declare -ga _AI_TOOLS_ASSETS__KV_KEYS=() _AI_TOOLS_ASSETS__KV_ERRORS=()
    while IFS= read -r raw || [[ -n "${raw}" ]]; do
        number=$(( number + 1 ))
        line="${raw#"${raw%%[![:space:]]*}"}"
        [[ -z "${line}" || "${line}" == '#'* ]] && continue
        if [[ "${line}" != *=* ]]; then
            _AI_TOOLS_ASSETS__KV_ERRORS+=( "line ${number}: no \`=\`" )
            continue
        fi
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            _AI_TOOLS_ASSETS__KV_ERRORS+=( "line ${number}: '$(_ai_tools_assets__sanitize_for_display "${key}")' is not a key of letters, digits and underscores" )
            continue
        fi
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        quote=""
        [[ "${value}" == '"'* ]] && quote='"'
        [[ "${value}" == "'"* ]] && quote="'"
        if [[ -n "${quote}" ]]; then
            rest="${value:1}"
            if [[ "${rest}" != *"${quote}"* ]]; then
                _AI_TOOLS_ASSETS__KV_ERRORS+=( "line ${number}: the ${quote} quote of ${key}= does not close" )
                value="${rest%"${rest##*[![:space:]]}"}"
            else
                value="${rest%%"${quote}"*}"
                trailing="${rest#*"${quote}"}"
                trailing="${trailing#"${trailing%%[![:space:]]*}"}"
                [[ -z "${trailing}" || "${trailing}" == '#'* ]] \
                    || _AI_TOOLS_ASSETS__KV_ERRORS+=( "line ${number}: text follows the closing quote of ${key}=" )
            fi
            _AI_TOOLS_ASSETS__KV_QUOTED["${key}"]=1
        else
            # An unquoted value ends at a `#` that opens it or follows whitespace.
            if [[ "${value}" == '#'* ]]; then
                value=""
            else
                rest="${value}"; value=""
                while [[ "${rest}" == *'#'* ]]; do
                    head="${rest%%#*}"
                    if [[ "${head}" == *[[:space:]] ]]; then value+="${head}"; rest=""; break; fi
                    value+="${head}#"; rest="${rest#*#}"
                done
                value+="${rest}"
            fi
            value="${value%"${value##*[![:space:]]}"}"
            _AI_TOOLS_ASSETS__KV_QUOTED["${key}"]=0
        fi
        if [[ -n "${_AI_TOOLS_ASSETS__KV[${key}]+x}" ]]; then
            _AI_TOOLS_ASSETS__KV_ERRORS+=( "line ${number}: ${key} is given again; a key is written once" )
        else
            _AI_TOOLS_ASSETS__KV_KEYS+=( "${key}" )
        fi
        _AI_TOOLS_ASSETS__KV["${key}"]="${value}"
    done < "${file}"
}

# _ai_tools_assets__read_list <value> <quoted> : split a list value into _AI_TOOLS_ASSETS__LIST and return 0, or empty
# it, set _AI_TOOLS_ASSETS__LIST_REASON and return 1 for a value the list grammar refuses: empty, one bracket, quotes
# around brackets, a quote or a bracket inside, or an empty item. `[]` is the empty list.
_ai_tools_assets__read_list() {
    local value="$1" quoted="$2" part
    local -a parts=() words=()
    declare -ga _AI_TOOLS_ASSETS__LIST=()
    _AI_TOOLS_ASSETS__LIST_REASON=""
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "${value}" ]]; then
        _AI_TOOLS_ASSETS__LIST_REASON="it is empty; write [] for an explicit empty list"
        return 1
    fi
    if [[ "${value}" == '['* && "${value}" != *']' || "${value}" != '['* && "${value}" == *']' ]]; then
        _AI_TOOLS_ASSETS__LIST_REASON="it has one bracket and not the other"
        return 1
    fi
    if [[ "${value}" == '['* ]]; then
        if [[ "${quoted}" == 1 ]]; then
            _AI_TOOLS_ASSETS__LIST_REASON="a bracketed list is written without quotes around it"
            return 1
        fi
        value="${value:1:${#value}-2}"
        if [[ "${value}" == *[\"\'\[\]]* ]]; then
            _AI_TOOLS_ASSETS__LIST_REASON="an item inside brackets carries no quote or bracket"
            return 1
        fi
        [[ -n "${value//[[:space:]]/}" ]] || return 0
    fi
    IFS=, read -r -a parts <<< "${value},"
    for part in "${parts[@]}"; do
        if [[ -z "${part//[[:space:]]/}" ]]; then
            _AI_TOOLS_ASSETS__LIST=()
            _AI_TOOLS_ASSETS__LIST_REASON="an item between two commas is empty"
            return 1
        fi
        IFS=$' \t' read -r -a words <<< "${part}"
        _AI_TOOLS_ASSETS__LIST+=( "${words[@]}" )
    done
    return 0
}

# ── Findings ─────────────────────────────────────────────────────────────────────────────────────────────────────────
# The validator records each finding as its rule id, the reason token the resolver reads it as, the path inside the set
# (`.` for the set itself) and a detail. A set-scope finding carries set-invalid (or capability-unknown for an unknown
# capability in set.conf); an asset-scope one carries asset-invalid (or capability-unknown) and the asset it is about.

# _ai_tools_assets__reset_findings : empty the finding arrays.
_ai_tools_assets__reset_findings() {
    declare -ga _AI_TOOLS_ASSETS__FINDING_RULE=() _AI_TOOLS_ASSETS__FINDING_TOKEN=() _AI_TOOLS_ASSETS__FINDING_PATH=() _AI_TOOLS_ASSETS__FINDING_DETAIL=() \
        _AI_TOOLS_ASSETS__FINDING_ASSET=()
}

# _ai_tools_assets__record_finding <rule> <token> <path> <detail> [asset] : record one finding.
_ai_tools_assets__record_finding() {
    _AI_TOOLS_ASSETS__FINDING_RULE+=( "$1" )
    _AI_TOOLS_ASSETS__FINDING_TOKEN+=( "$2" )
    _AI_TOOLS_ASSETS__FINDING_PATH+=( "$3" )
    _AI_TOOLS_ASSETS__FINDING_DETAIL+=( "$4" )
    _AI_TOOLS_ASSETS__FINDING_ASSET+=( "${5:-}" )
}

# ── The tree ─────────────────────────────────────────────────────────────────────────────────────────────────────────

# _ai_tools_assets__walk_tree <set-dir> : the file-shape rules over the set's tree, read with lstat by one `find`
# whose exit status is read, so an enumeration that ended early is a finding and not a smaller tree. Records each
# regular file and directory the later rules read in _AI_TOOLS_ASSETS__FILES and _AI_TOOLS_ASSETS__DIRS (relative path
# -> 1), and a file over the size bound in _AI_TOOLS_ASSETS__UNREAD too, so no later rule reads its bytes. An entry
# whose name is outside the portable set is reported once and not read further, its subtree with it; a link, a special
# file and a file with a second link are reported and not recorded. find descends one level past the depth bound and no
# further, so a directory at that level stops the walk without a deeper tree being listed first. Returns 1 when the walk
# stopped at a bound (one file.size finding at the set root) or did not complete, after which no later rule
# runs.
_ai_tools_assets__walk_tree() {
    local set_dir="$1" listing record type links size depth path name parent probe walk_error walk_status=0 entry_count
    local file_max="${AI_TOOLS_ASSETS_VERIFY__FILE_MAX_BYTES:-1048576}" count_max="${AI_TOOLS_ASSETS_VERIFY__FILE_MAX_COUNT:-2000}"
    local bytes_max="${AI_TOOLS_ASSETS_VERIFY__SET_MAX_BYTES:-67108864}" files=0 directories=0 bytes=0
    local stopped=""
    local -A entries_in=() refused_prefix=()
    declare -gA _AI_TOOLS_ASSETS__FILES=() _AI_TOOLS_ASSETS__DIRS=() _AI_TOOLS_ASSETS__UNREAD=()
    listing="$(mktemp 2>/dev/null)" \
        || { _ai_tools_assets__record_finding file.special set-invalid . "no temporary file for the walk"; return 1; }
    walk_error="$( (find -P "${set_dir}" -mindepth 1 -maxdepth "$(( _AI_TOOLS_ASSETS__MAX_DEPTH + 1 ))" \
                        -printf '%y\t%n\t%s\t%d\t%P\0' > "${listing}") 2>&1 )" \
        || walk_status=$?
    if (( walk_status != 0 )); then
        rm -f -- "${listing}"
        _ai_tools_assets__record_finding file.special set-invalid . "the walk did not complete (find exit ${walk_status}): $(_ai_tools_assets__sanitize_for_display "${walk_error%%$'\n'*}")"
        return 1
    fi
    while IFS= read -r -d '' record; do
        type="${record%%$'\t'*}"; record="${record#*$'\t'}"
        links="${record%%$'\t'*}"; record="${record#*$'\t'}"
        size="${record%%$'\t'*}"; record="${record#*$'\t'}"
        depth="${record%%$'\t'*}"; path="${record#*$'\t'}"
        name="${path##*/}"
        parent=.
        [[ "${path}" == */* ]] && parent="${path%/*}"
        probe="${parent}"
        while [[ "${probe}" != . ]]; do
            [[ -n "${refused_prefix[${probe}]+x}" ]] && continue 2
            [[ "${probe}" == */* ]] && probe="${probe%/*}" || probe=.
        done
        entry_count=$(( ${entries_in[${parent}]:-0} + 1 ))
        entries_in["${parent}"]="${entry_count}"
        if (( entry_count > _AI_TOOLS_ASSETS__MAX_DIRECTORY_ENTRIES )); then
            stopped="$(_ai_tools_assets__sanitize_for_display "${parent}") holds more than ${_AI_TOOLS_ASSETS__MAX_DIRECTORY_ENTRIES} entries; the walk stopped there"
            break
        fi
        if ! ai_tools_conf__is_portable_name_valid "${name}"; then
            refused_prefix["${path}"]=1
            _ai_tools_assets__record_finding file.name set-invalid "$(_ai_tools_assets__sanitize_for_display "${path}")" "a name outside the portable file-name set A-Za-z0-9._-"
            continue
        fi
        case "${type}" in
            l)  _ai_tools_assets__record_finding file.symlink set-invalid "${path}" "a symbolic link" ;;
            d)  directories=$(( directories + 1 ))
                if (( directories > _AI_TOOLS_ASSETS__MAX_DIRECTORIES || depth > _AI_TOOLS_ASSETS__MAX_DEPTH )); then
                    stopped="more than ${_AI_TOOLS_ASSETS__MAX_DIRECTORIES} directories or ${_AI_TOOLS_ASSETS__MAX_DEPTH} levels; the walk stopped at $(_ai_tools_assets__sanitize_for_display "${path}")"
                    break
                fi
                _AI_TOOLS_ASSETS__DIRS["${path}"]=1 ;;
            f)  files=$(( files + 1 ))
                (( size <= file_max )) && bytes=$(( bytes + size )) || bytes=$(( bytes + file_max + 1 ))
                if (( files > count_max || bytes > bytes_max )); then
                    stopped="more than ${count_max} files or ${bytes_max} bytes; the walk stopped at $(_ai_tools_assets__sanitize_for_display "${path}")"
                    break
                fi
                if (( links > 1 )); then
                    _ai_tools_assets__record_finding file.hardlink set-invalid "${path}" "a file with ${links} links"
                    continue
                fi
                if (( size > file_max )); then
                    _ai_tools_assets__record_finding file.size set-invalid "${path}" "${size} bytes; a file is at most ${file_max}"
                    _AI_TOOLS_ASSETS__UNREAD["${path}"]=1
                fi
                _AI_TOOLS_ASSETS__FILES["${path}"]=1 ;;
            *)  _ai_tools_assets__record_finding file.special set-invalid "${path}" "neither a regular file nor a directory" ;;
        esac
    done < "${listing}"
    rm -f -- "${listing}"
    if [[ -n "${stopped}" ]]; then
        _ai_tools_assets__record_finding file.size set-invalid . "${stopped}"
        return 1
    fi
    return 0
}

# _ai_tools_assets__list_children <directory> <files|dirs> : print each recorded child of <directory> (a relative path,
# `.` for the set root) of that type, one per line, in byte order.
_ai_tools_assets__list_children() {
    local directory="$1" which="$2" path parent
    local LC_ALL=C
    if [[ "${which}" == files ]]; then
        for path in "${!_AI_TOOLS_ASSETS__FILES[@]}"; do
            parent=.; [[ "${path}" == */* ]] && parent="${path%/*}"
            [[ "${parent}" == "${directory}" ]] && printf '%s\n' "${path}"
        done | sort
    else
        for path in "${!_AI_TOOLS_ASSETS__DIRS[@]}"; do
            parent=.; [[ "${path}" == */* ]] && parent="${path%/*}"
            [[ "${parent}" == "${directory}" ]] && printf '%s\n' "${path}"
        done | sort
    fi
}

# _ai_tools_assets__get_entry_type <path> : print `f`, `d`, or an empty string for a path the walk did not record.
_ai_tools_assets__get_entry_type() {
    if [[ -n "${_AI_TOOLS_ASSETS__FILES[$1]+x}" ]]; then printf f
    elif [[ -n "${_AI_TOOLS_ASSETS__DIRS[$1]+x}" ]]; then printf d
    fi
}

# _ai_tools_assets__check_text <set-dir> : file.binary over every file the walk recorded within the size bound -- UTF-8
# text without a control character but tab, LF and CR, a bidi control or a byte order mark. One grep over every file
# reads _AI_TOOLS_ASSETS__BINARY_BYTES; one iconv over every file reads the rest of UTF-8's validity (an overlong form,
# a surrogate, a truncated sequence), and per file only where the batch fails. grep reading every file is what lets
# an iconv status of 1 mean invalid input rather than an unreadable file. A refused file is recorded
# in _AI_TOOLS_ASSETS__UNREAD, so no later rule reads it. A scan that did not complete is a finding at the set root.
_ai_tools_assets__check_text() {
    local set_dir="$1" path listing status=0 iconv_error
    local -a files=()
    for path in "${!_AI_TOOLS_ASSETS__FILES[@]}"; do
        [[ -n "${_AI_TOOLS_ASSETS__UNREAD[${path}]+x}" ]] || files+=( "${path}" )
    done
    (( ${#files[@]} > 0 )) || return 0
    listing="$(cd -- "${set_dir}" && LC_ALL=C grep -laP -e "${_AI_TOOLS_ASSETS__BINARY_BYTES}" -- "${files[@]}" 2>/dev/null)" \
        || status=$?
    if (( status > 1 )); then
        _ai_tools_assets__record_finding file.binary set-invalid . "the scan did not complete (grep exit ${status})"
        return 0
    fi
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        _ai_tools_assets__record_finding file.binary set-invalid "${path}" "carries a control character, a bidi control, a byte order mark or a byte outside UTF-8"
        _AI_TOOLS_ASSETS__UNREAD["${path}"]=1
    done <<< "${listing}"
    (cd -- "${set_dir}" && iconv -f UTF-8 -t UTF-8 -- "${files[@]}" >/dev/null 2>&1) && return 0
    for path in "${files[@]}"; do
        [[ -n "${_AI_TOOLS_ASSETS__UNREAD[${path}]+x}" ]] && continue
        status=0
        iconv_error="$(iconv -f UTF-8 -t UTF-8 -- "${set_dir}/${path}" 2>&1 >/dev/null)" || status=$?
        case "${status}" in
            0)  ;;
            1)  _ai_tools_assets__record_finding file.binary set-invalid "${path}" "is not UTF-8 text: $(_ai_tools_assets__sanitize_for_display "${iconv_error%%$'\n'*}")"
                _AI_TOOLS_ASSETS__UNREAD["${path}"]=1 ;;
            *)  _ai_tools_assets__record_finding file.binary set-invalid . "the UTF-8 check did not complete (iconv exit ${status})"
                return 0 ;;
        esac
    done
    return 0
}

# ── The set ──────────────────────────────────────────────────────────────────────────────────────────────────────────

# _ai_tools_assets__check_root_entries <profile> : set.entry.unknown, set.entry.reserved, kind.shape for a kind
# directory of the wrong type, and kind.reserved, over the entries the walk recorded at the set root. SHA256SUMS and its
# signature are entries of a `release` set; under `source` they are the publisher's check and are not reported here.
_ai_tools_assets__check_root_entries() {
    local profile="$1" path type spec wanted kind_dir
    local -a allowed=( "${_AI_TOOLS_ASSETS__SET_ENTRIES[@]}" )
    [[ "${profile}" == release || "${profile}" == host ]] && allowed+=( "${_AI_TOOLS_ASSETS__RELEASE_ENTRIES[@]}" )
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        type="$(_ai_tools_assets__get_entry_type "${path}")"
        wanted=""
        for spec in "${allowed[@]}"; do [[ "${spec%:*}" == "${path}" ]] && wanted="${spec##*:}"; done
        if [[ "${path}" == skills || "${path}" == agents ]]; then
            [[ "${type}" == d ]] || _ai_tools_assets__record_finding kind.shape set-invalid "${path}" "${path} is a file; the format specifies a directory"
            continue
        fi
        if [[ -n "${wanted}" ]]; then
            [[ "${type}" == "${wanted}" ]] || _ai_tools_assets__record_finding set.entry.unknown set-invalid "${path}" "${path} is of the wrong type for its name"
            continue
        fi
        [[ "${path}" == SHA256SUMS || "${path}" == SHA256SUMS.asc || "${path}" == SHA512SUMS* ]] && continue
        if _ai_tools_assets__is_one_of "${path}" "${_AI_TOOLS_ASSETS__RESERVED_ENTRIES[@]}"; then
            _ai_tools_assets__record_finding set.entry.reserved set-invalid "${path}" "${path} is reserved, and present"
            continue
        fi
        _ai_tools_assets__is_one_of "${path}" "${_AI_TOOLS_ASSETS__RESERVED_KINDS[@]}" && [[ "${type}" == d ]] && continue
        _ai_tools_assets__record_finding set.entry.unknown set-invalid "${path}" "a set directory holds set.conf, CHANGELOG.md, README.md, LICENSE, LICENSES, plugin.json, .claude-plugin, skills, agents and metadata alone"
    done < <( { _ai_tools_assets__list_children . files; _ai_tools_assets__list_children . dirs; } )
    for kind_dir in "${_AI_TOOLS_ASSETS__RESERVED_KINDS[@]}"; do
        _ai_tools_assets__is_one_of "${kind_dir}" "${_AI_TOOLS_ASSETS__RESERVED_ENTRIES[@]}" && continue
        [[ -n "${_AI_TOOLS_ASSETS__DIRS[${kind_dir}]+x}" ]] \
            && _ai_tools_assets__record_finding kind.reserved set-invalid "${kind_dir}" "${kind_dir}/ is a reserved kind, and present"
    done
    return 0
}

# _ai_tools_assets__check_set_conf <set-dir> <set-name> : the set.conf rules. Publishes what the resolver reads
# in _AI_TOOLS_ASSETS__SET_VERSION, _AI_TOOLS_ASSETS__SET_REQUIRES_BASE (empty when not declared),
# _AI_TOOLS_ASSETS__SET_CAPABILITIES and _AI_TOOLS_ASSETS__SET_INTEGRATIONS (space-joined), each read only
# where the file
# parses.
_ai_tools_assets__check_set_conf() {
    local set_dir="$1" set_name="$2" key message capability integration
    local -a missing=()
    _AI_TOOLS_ASSETS__SET_VERSION=""; _AI_TOOLS_ASSETS__SET_REQUIRES_BASE=""
    _AI_TOOLS_ASSETS__SET_CAPABILITIES=""; _AI_TOOLS_ASSETS__SET_INTEGRATIONS=""
    if [[ -z "${_AI_TOOLS_ASSETS__FILES[set.conf]+x}" ]]; then
        _ai_tools_assets__record_finding set.conf.missing set-invalid set.conf "the set directory holds no set.conf file"
        return 0
    fi
    [[ -z "${_AI_TOOLS_ASSETS__UNREAD[set.conf]+x}" ]] || return 0
    _ai_tools_assets__read_format_file "${set_dir}/set.conf"
    for message in "${_AI_TOOLS_ASSETS__KV_ERRORS[@]}"; do
        _ai_tools_assets__record_finding set.conf.syntax set-invalid set.conf "${message}"
    done
    # A list key given empty (`maintainers=`) is the list grammar's finding in the loop over the list keys.
    for key in "${_AI_TOOLS_ASSETS__SET_CONF_REQUIRED[@]}"; do
        if [[ -z "${_AI_TOOLS_ASSETS__KV[${key}]+x}" ]] \
                || { ! _ai_tools_assets__is_one_of "${key}" "${_AI_TOOLS_ASSETS__SET_CONF_LISTS[@]}" && [[ -z "${_AI_TOOLS_ASSETS__KV[${key}]//[[:space:]]/}" ]]; }; then
            missing+=( "${key}=" )
        fi
    done
    (( ${#missing[@]} == 0 )) \
        || _ai_tools_assets__record_finding set.conf.required-key set-invalid set.conf "missing or empty: ${missing[*]}"
    if [[ -n "${_AI_TOOLS_ASSETS__KV[format]+x}" ]]; then
        key="${_AI_TOOLS_ASSETS__KV[format]}"
        key="${key#"${key%%[![:space:]]*}"}"
        [[ "${key%"${key##*[![:space:]]}"}" == 1 ]] \
            || _ai_tools_assets__record_finding set.conf.format set-invalid set.conf "format=$(_ai_tools_assets__sanitize_for_display "${_AI_TOOLS_ASSETS__KV[format]}"); this release reads format 1"
    fi
    [[ -z "${_AI_TOOLS_ASSETS__KV[name]+x}" || "${_AI_TOOLS_ASSETS__KV[name]}" == "${set_name}" ]] \
        || _ai_tools_assets__record_finding set.conf.name set-invalid set.conf "name=$(_ai_tools_assets__sanitize_for_display "${_AI_TOOLS_ASSETS__KV[name]}") differs from the set directory ${set_name}"
    if [[ -n "${_AI_TOOLS_ASSETS__KV[version]+x}" ]]; then
        if [[ "${_AI_TOOLS_ASSETS__KV[version]}" =~ ${_AI_TOOLS_ASSETS__SEMVER} ]]; then
            _AI_TOOLS_ASSETS__SET_VERSION="${_AI_TOOLS_ASSETS__KV[version]}"
        else
            _ai_tools_assets__record_finding set.conf.version set-invalid set.conf "version=$(_ai_tools_assets__sanitize_for_display "${_AI_TOOLS_ASSETS__KV[version]}") is not a semantic version"
        fi
    fi
    for key in "${_AI_TOOLS_ASSETS__SET_CONF_LISTS[@]}"; do
        [[ -n "${_AI_TOOLS_ASSETS__KV[${key}]+x}" ]] || continue
        if ! _ai_tools_assets__read_list "${_AI_TOOLS_ASSETS__KV[${key}]}" "${_AI_TOOLS_ASSETS__KV_QUOTED[${key}]}"; then
            _ai_tools_assets__record_finding set.conf.syntax set-invalid set.conf "${key} is not a list (${_AI_TOOLS_ASSETS__LIST_REASON}); write it as [a, b]"
            continue
        fi
        if (( ${#_AI_TOOLS_ASSETS__LIST[@]} == 0 )) && _ai_tools_assets__is_one_of "${key}" "${_AI_TOOLS_ASSETS__SET_CONF_REQUIRED[@]}"; then
            _ai_tools_assets__record_finding set.conf.required-key set-invalid set.conf "${key}=[] is empty; a set declares at least one"
        elif [[ "${key}" == requires_capabilities ]]; then
            for capability in "${_AI_TOOLS_ASSETS__LIST[@]}"; do
                if _ai_tools_assets__is_capability "${capability}"; then
                    _AI_TOOLS_ASSETS__SET_CAPABILITIES+="${_AI_TOOLS_ASSETS__SET_CAPABILITIES:+ }${capability}"
                else
                    _ai_tools_assets__record_finding set.conf.requires-capabilities capability-unknown set.conf "$(_ai_tools_assets__sanitize_for_display "${capability}") is not a capability base defines"
                fi
            done
        elif [[ "${key}" == requires_integrations ]]; then
            for integration in "${_AI_TOOLS_ASSETS__LIST[@]}"; do
                if [[ "${integration}" =~ ^integration-[a-z][a-z0-9-]*$ ]]; then
                    _AI_TOOLS_ASSETS__SET_INTEGRATIONS+="${_AI_TOOLS_ASSETS__SET_INTEGRATIONS:+ }${integration}"
                else
                    _ai_tools_assets__record_finding set.conf.requires-integrations set-invalid set.conf "$(_ai_tools_assets__sanitize_for_display "${integration}") is not written as integration-<name>"
                fi
            done
        fi
    done
    for key in "${_AI_TOOLS_ASSETS__KV_KEYS[@]}"; do
        _ai_tools_assets__is_one_of "${key}" "${_AI_TOOLS_ASSETS__SET_CONF_REQUIRED[@]}" "${_AI_TOOLS_ASSETS__SET_CONF_OPTIONAL[@]}" && continue
        [[ "${key}" =~ ^x_[A-Za-z0-9_]+$ ]] && continue
        _ai_tools_assets__record_finding set.conf.unknown-key set-invalid set.conf "${key} is not a key this format reads; a publisher's own key is x_<key>"
    done
    [[ -n "${_AI_TOOLS_ASSETS__KV[requires_base]+x}" ]] && _AI_TOOLS_ASSETS__SET_REQUIRES_BASE="${_AI_TOOLS_ASSETS__KV[requires_base]}"
    return 0
}

# _ai_tools_assets__list_assets : append `<kind>|<name>` to _AI_TOOLS_ASSETS__ASSETS for each asset the kind directories
# hold, after the kind.shape rule over each entry: a skill is a directory holding a regular SKILL.md, a subagent
# a regular `.md` file. A README.md at a kind directory is not an asset and not reported here (the publisher's
# file.reserved-name).
_ai_tools_assets__list_assets() {
    local path
    declare -ga _AI_TOOLS_ASSETS__ASSETS=()
    if [[ -n "${_AI_TOOLS_ASSETS__DIRS[skills]+x}" ]]; then
        while IFS= read -r path; do
            [[ -n "${path}" && "${path}" != skills/README.md ]] || continue
            _ai_tools_assets__record_finding kind.shape set-invalid "${path}" "an entry under skills/ is a directory holding SKILL.md"
        done < <(_ai_tools_assets__list_children skills files)
        while IFS= read -r path; do
            [[ -n "${path}" ]] || continue
            if [[ -n "${_AI_TOOLS_ASSETS__FILES[${path}/SKILL.md]+x}" ]]; then
                _AI_TOOLS_ASSETS__ASSETS+=( "skills|${path#skills/}" )
            else
                _ai_tools_assets__record_finding kind.shape set-invalid "${path}" "a skill directory holds a regular SKILL.md file"
            fi
        done < <(_ai_tools_assets__list_children skills dirs)
    fi
    if [[ -n "${_AI_TOOLS_ASSETS__DIRS[agents]+x}" ]]; then
        while IFS= read -r path; do
            [[ -n "${path}" ]] || continue
            _ai_tools_assets__record_finding kind.shape set-invalid "${path}" "an entry under agents/ is a <name>.md file"
        done < <(_ai_tools_assets__list_children agents dirs)
        while IFS= read -r path; do
            [[ -n "${path}" && "${path}" != agents/README.md ]] || continue
            if [[ "${path}" == *.md ]]; then
                path="${path#agents/}"
                _AI_TOOLS_ASSETS__ASSETS+=( "subagents|${path%.md}" )
            else
                _ai_tools_assets__record_finding kind.shape set-invalid "${path}" "an entry under agents/ is a <name>.md file"
            fi
        done < <(_ai_tools_assets__list_children agents files)
    fi
}

# _ai_tools_assets__check_skill_entries : the structures under skills/ a consumer reads without the model choosing,
# in one pass over the walk's records in byte order. skill.plugin-manifest: a .claude-plugin directory anywhere
# under skills/, which Claude Code reads as a plugin declaring hooks and tool servers. For each listed skill whose name
# passes the grammar: skill.sidecar for agents/openai.yaml, which codex reads, and skill.entry.unknown for an entry
# _AI_TOOLS_ASSETS__SKILL_ENTRIES does not name, or names with the other type. The .claude-plugin entry and the agents
# directory holding the sidecar are reported under those two rules alone, as the format's validator reports them.
_ai_tools_assets__check_skill_entries() {
    local asset type path skill entry spec wanted
    local -A skills=()
    for asset in "${_AI_TOOLS_ASSETS__ASSETS[@]}"; do
        [[ "${asset}" == skills\|* ]] && _ai_tools_assets__is_valid_name "${asset#skills|}" && skills["${asset#skills|}"]=1
    done
    while IFS=$'\t' read -r type path; do
        [[ "${path}" == skills/?* ]] || continue
        skill="${path#skills/}"; skill="${skill%%/*}"
        if [[ "${type}" == d && "${path##*/}" == .claude-plugin ]]; then
            _ai_tools_assets__record_finding skill.plugin-manifest asset-invalid "${path}" "a .claude-plugin directory inside skills/ makes a plugin of its own" "${skill}"
            continue
        fi
        [[ -n "${skills[${skill}]+x}" ]] || continue
        if [[ "${type}" == f && "${path}" == "skills/${skill}/agents/openai.yaml" ]]; then
            _ai_tools_assets__record_finding skill.sidecar asset-invalid "${path}" "agents/openai.yaml carries a consumer's invocation policy and tool dependencies" "${skill}"
            continue
        fi
        entry="${path#skills/"${skill}"/}"
        [[ "${entry}" != "${path}" && "${entry}" != */* ]] || continue
        wanted=""
        for spec in "${_AI_TOOLS_ASSETS__SKILL_ENTRIES[@]}"; do [[ "${spec%:*}" == "${entry}" ]] && wanted="${spec##*:}"; done
        if [[ -n "${wanted}" ]]; then
            [[ "${type}" == "${wanted}" ]] \
                || _ai_tools_assets__record_finding skill.entry.unknown asset-invalid "${path}" "${entry} is of the wrong type for its name" "${skill}"
            continue
        fi
        [[ "${entry}" == .claude-plugin ]] && continue
        [[ "${entry}" == agents && "${type}" == d && -n "${_AI_TOOLS_ASSETS__FILES[skills/${skill}/agents/openai.yaml]+x}" ]] && continue
        _ai_tools_assets__record_finding skill.entry.unknown asset-invalid "${path}" "a skill directory holds SKILL.md, scripts, references, assets, tests, UPSTREAM.conf, LICENSE and LICENSES alone" "${skill}"
    done < <( { for path in "${!_AI_TOOLS_ASSETS__FILES[@]}"; do printf 'f\t%s\n' "${path}"; done
                for path in "${!_AI_TOOLS_ASSETS__DIRS[@]}"; do printf 'd\t%s\n' "${path}"; done; } | LC_ALL=C sort -t $'\t' -k 2 )
    return 0
}

# ── An asset ─────────────────────────────────────────────────────────────────────────────────────────────────────────

# _ai_tools_assets__is_plain_lexeme <text> [flow] : succeed when <text> is a plain scalar of the bounded reader's
# grammar, wherever it stands: it does not open with an indicator (| > & * ! { ? @
# ` % #, or - alone or before a space or a tab), and does not carry `:
# ` or `:` then a tab, which a YAML reader takes as a mapping, end with `:`, or carry `
# #` or a tab then `#`, which it takes as a comment. With `flow`, a flow-list item, it does not carry a comma,
# a bracket, a brace or a quote either.
_ai_tools_assets__is_plain_lexeme() {
    local text="$1"
    local LC_ALL=C
    case "${text}" in
        [\|\>\&\*\!\{\?\@\`%\#]*|-|'- '*|$'-\t'*) return 1 ;;
    esac
    case "${text}" in
        *': '*|*$':\t'*|*:|*' #'*|*$'\t#'*) return 1 ;;
    esac
    [[ -z "${2:-}" || "${text}" != *[],[{}\"\']* ]]
}

# _ai_tools_assets__is_flow_list <text> : succeed when <text>, opening with `[` and closing with `]`, is a flow list
# of the bounded reader's grammar: empty, or plain non-empty items separated by commas, each a flow-list item
# of _ai_tools_assets__is_plain_lexeme.
_ai_tools_assets__is_flow_list() {
    local rest="${1:1:${#1}-2}" item
    [[ -n "${rest//[[:space:]]/}" ]] || return 0
    while :; do
        item="${rest%%,*}"
        item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
        [[ -n "${item}" ]] && _ai_tools_assets__is_plain_lexeme "${item}" flow || return 1
        [[ "${rest}" == *,* ]] || return 0
        rest="${rest#*,}"
    done
}

# _ai_tools_assets__parse_scalar <text> : read a frontmatter value as a one-line scalar of the bounded reader's grammar
# into _AI_TOOLS_ASSETS__SCALAR and return 0, or return 1 for a value outside it. An empty value or a `#` comment alone
# is the omitted scalar, read as empty. A quoted value closes on its line, may carry a comment after it, and unescapes
# \\ and \" (double-quoted) or '' (single-quoted) alone; a plain value passes _ai_tools_assets__is_plain_lexeme and does
# not open with `[` or close with `]`, which a flow list does.
_ai_tools_assets__parse_scalar() {
    local text="$1" rest quoted="" index character
    local LC_ALL=C
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    _AI_TOOLS_ASSETS__SCALAR=""
    [[ -z "${text}" || "${text}" == '#'* ]] && return 0
    case "${text}" in
        '"'*)
            rest="${text:1}"
            for (( index = 0; index < ${#rest}; index++ )); do
                character="${rest:index:1}"
                if [[ "${character}" == \\ ]]; then
                    index=$(( index + 1 ))
                    case "${rest:index:1}" in \\|'"') quoted+="${rest:index:1}" ;; *) return 1 ;; esac
                    continue
                fi
                [[ "${character}" == '"' ]] && break
                quoted+="${character}"
            done
            (( index < ${#rest} )) || return 1
            rest="${rest:index+1}"; rest="${rest#"${rest%%[![:space:]]*}"}"
            [[ -z "${rest}" || "${rest}" == '#'* ]] || return 1
            _AI_TOOLS_ASSETS__SCALAR="${quoted}" ;;
        "'"*)
            rest="${text:1}"
            while :; do
                [[ "${rest}" == *"'"* ]] || return 1
                quoted+="${rest%%\'*}"; rest="${rest#*\'}"
                if [[ "${rest}" == "'"* ]]; then quoted+="'"; rest="${rest:1}"; continue; fi
                break
            done
            rest="${rest#"${rest%%[![:space:]]*}"}"
            [[ -z "${rest}" || "${rest}" == '#'* ]] || return 1
            _AI_TOOLS_ASSETS__SCALAR="${quoted}" ;;
        '['*|*']') return 1 ;;
        *)  _ai_tools_assets__is_plain_lexeme "${text}" || return 1
            _AI_TOOLS_ASSETS__SCALAR="${text}" ;;
    esac
    return 0
}

# _ai_tools_assets__check_frontmatter <file> <path> <kind> <name> : the frontmatter rules base enforces over an entry
# file:
# frontmatter.missing (an unreadable file, no `---` on line 1, or no closing `---` line), frontmatter.syntax (a line
# outside the bounded reader's grammar, a key given twice, a name that is not a scalar), frontmatter.refused-key (a key
# at the margin off the kind's allowlist), frontmatter.required (name or description omitted or empty)
# and name.frontmatter (the name differs from <name>). A syntax finding stops the later rules, as the format's validator
# stops them. The grammar is the format's bounded reader, narrowed where base reads an indented line: a line
# at the margin is `key: value`, whose value is a scalar of _ai_tools_assets__parse_scalar, a flow list
# of _ai_tools_assets__is_flow_list, or omitted; indented lines, at one indentation of spaces, follow a key whose value
# is omitted, as `key: scalar` lines under metadata or `- scalar` items under tools, disallowedTools and skills,
# and under no other key. Base reads the key names at the margin and the values of name and description.
#
# A line is what ends at LF, with one trailing CR read past (a CRLF file). A CR anywhere else in a line is
# frontmatter.syntax, checked before the comment skip: YAML takes a lone CR as a line break, so a consumer's parser
# reads `description: x<CR>hooks: ...` or `# note<CR>hooks: ...` as a second line carrying a key this reader would
# otherwise never see at the margin, and file.binary lets a CR through as text.
_ai_tools_assets__check_frontmatter() {
    local file="$1" path="$2" kind="$3" name="$4" line trimmed key value index shape at closing_line_index=0
    local current="" indent=""
    local LC_ALL=C
    local -a lines=() keys=() problems=()
    local -A values=() shapes=() nested=()
    if ! { mapfile -t lines < "${file}"; } 2>/dev/null; then
        _ai_tools_assets__record_finding frontmatter.missing asset-invalid "${path}" "the file could not be read" "${name}"
        return 0
    fi
    if (( ${#lines[@]} == 0 )) || [[ ! "${lines[0]}" =~ ^---[[:space:]]*$ ]]; then
        _ai_tools_assets__record_finding frontmatter.missing asset-invalid "${path}" "the file does not open with a --- frontmatter line" "${name}"
        return 0
    fi
    for (( index = 1; index < ${#lines[@]}; index++ )); do
        [[ "${lines[index]}" =~ ^---[[:space:]]*$ ]] && { closing_line_index="${index}"; break; }
    done
    if (( closing_line_index == 0 )); then
        _ai_tools_assets__record_finding frontmatter.missing asset-invalid "${path}" "the frontmatter does not close with a --- line" "${name}"
        return 0
    fi
    for (( index = 1; index < closing_line_index; index++ )); do
        line="${lines[index]%$'\r'}"; at="line $(( index + 1 ))"
        if [[ "${line}" == *$'\r'* ]]; then
            problems+=( "${at}: a carriage return inside the line, which a YAML reader takes as a line break" ); continue
        fi
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${trimmed}" || "${trimmed}" == '#'* ]] && continue
        if [[ "${line%%[![:space:]]*}" == *$'\t'* ]]; then
            problems+=( "${at}: a tab in the indentation" ); continue
        fi
        if [[ "${line}" =~ ^([A-Za-z][A-Za-z0-9_-]*):([[:space:]]+(.*))?$ ]]; then
            key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[3]}"
            value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
            [[ -n "${shapes[${key}]+x}" ]] && problems+=( "${at}: ${key} is given again" )
            keys+=( "${key}" ); values["${key}"]=""; current=""; indent=""
            if [[ -z "${value}" || "${value}" == '#'* ]]; then
                shapes["${key}"]=omitted; current="${key}"
            elif [[ "${value}" == '['* && "${value}" == *']' ]]; then
                shapes["${key}"]=list
                _ai_tools_assets__is_flow_list "${value}" || problems+=( "${at}: ${key} is not a flow list of plain, non-empty items" )
            else
                shapes["${key}"]=scalar
                if _ai_tools_assets__parse_scalar "${value}"; then
                    values["${key}"]="${_AI_TOOLS_ASSETS__SCALAR}"
                else
                    problems+=( "${at}: the value of ${key} is outside the frontmatter grammar" )
                fi
            fi
            continue
        fi
        if [[ -n "${current}" && "${line}" =~ ^(\ +)([A-Za-z][A-Za-z0-9_-]*):([[:space:]]+(.*))?$ ]]; then
            shape=map; key="${BASH_REMATCH[2]}"; value="${BASH_REMATCH[4]}"
        elif [[ -n "${current}" && "${line}" =~ ^(\ +)-[[:space:]]+(.+)$ ]]; then
            shape=list; key=""; value="${BASH_REMATCH[2]}"
        else
            problems+=( "${at} is not key: value at the margin, or an item under a key given no value" ); continue
        fi
        [[ -n "${indent}" ]] || indent="${BASH_REMATCH[1]}"
        if [[ "${BASH_REMATCH[1]}" != "${indent}" ]]; then
            problems+=( "${at}: the indentation changes inside ${current}; one level is read" ); continue
        fi
        [[ "${shapes[${current}]}" == omitted ]] && shapes["${current}"]="${shape}"
        if [[ "${shapes[${current}]}" != "${shape}" ]]; then
            problems+=( "${at}: ${current} mixes a map and a sequence" ); continue
        fi
        case "${shape}|${current}" in
            'map|metadata'|'list|tools'|'list|disallowedTools'|'list|skills') ;;
            *) problems+=( "${at}: ${current} does not take an indented ${shape}; metadata takes key: value lines, and tools, disallowedTools and skills take - items" )
               continue ;;
        esac
        if [[ -n "${key}" ]]; then
            [[ -n "${nested[${current}.${key}]+x}" ]] && problems+=( "${at}: ${current}.${key} is given again" )
            nested["${current}.${key}"]=1
        fi
        _ai_tools_assets__parse_scalar "${value}" || problems+=( "${at}: a value under ${current} is outside the frontmatter grammar" )
    done
    [[ "${shapes[name]:-scalar}" == scalar || "${shapes[name]}" == omitted ]] || problems+=( "name is not a scalar" )
    for value in "${problems[@]}"; do
        _ai_tools_assets__record_finding frontmatter.syntax asset-invalid "${path}" "$(_ai_tools_assets__sanitize_for_display "${value}")" "${name}"
    done
    (( ${#problems[@]} == 0 )) || return 0
    for key in "${keys[@]}"; do
        if [[ "${kind}" == skills ]]; then
            _ai_tools_assets__is_one_of "${key}" "${_AI_TOOLS_ASSETS__SKILL_KEYS[@]}" && continue
        else
            _ai_tools_assets__is_one_of "${key}" "${_AI_TOOLS_ASSETS__SUBAGENT_KEYS[@]}" && continue
        fi
        _ai_tools_assets__record_finding frontmatter.refused-key asset-invalid "${path}" "${key} is not on the ${kind} allowlist" "${name}"
    done
    # description is read as present alone: a list or a map is a type the format's validator checks.
    for key in name description; do
        [[ "${shapes[${key}]:-omitted}" == omitted \
            || ( "${shapes[${key}]}" == scalar && -z "${values[${key}]//[[:space:]]/}" ) ]] \
            && _ai_tools_assets__record_finding frontmatter.required asset-invalid "${path}" "${key} is missing or empty" "${name}"
    done
    value="${values[name]:-}"
    if [[ -n "${value//[[:space:]]/}" && "${value}" != "${name}" ]]; then
        _ai_tools_assets__record_finding name.frontmatter asset-invalid "${path}" "the frontmatter name $(_ai_tools_assets__sanitize_for_display "${value}") differs from ${name}" "${name}"
    fi
    return 0
}

# _ai_tools_assets__check_asset_conf <set-dir> <path> <name> : the metadata.asset-conf rule over one asset.conf,
# and set.conf.unknown-key for a key outside its table. Publishes the requirements
# in _AI_TOOLS_ASSETS__ASSET_CAPABILITIES and _AI_TOOLS_ASSETS__ASSET_INTEGRATIONS (space-joined, the known
# and well-formed items) and the tokens the file declares, however it reads, in _AI_TOOLS_ASSETS__ASSET_DECLARED --
# empty where the file does not parse, so a declaration the reader cannot read does not allow anything.
_ai_tools_assets__check_asset_conf() {
    local set_dir="$1" path="$2" name="$3" key item message format_value
    _ai_tools_assets__read_format_file "${set_dir}/${path}"
    for message in "${_AI_TOOLS_ASSETS__KV_ERRORS[@]}"; do
        _ai_tools_assets__record_finding metadata.asset-conf asset-invalid "${path}" "${message}" "${name}"
    done
    format_value="${_AI_TOOLS_ASSETS__KV[format]:-}"
    format_value="${format_value#"${format_value%%[![:space:]]*}"}"
    [[ "${format_value%"${format_value##*[![:space:]]}"}" == 1 ]] \
        || _ai_tools_assets__record_finding metadata.asset-conf asset-invalid "${path}" "format=$(_ai_tools_assets__sanitize_for_display "${_AI_TOOLS_ASSETS__KV[format]:-}"); this release reads format 1" "${name}"
    for key in requires_capabilities requires_integrations; do
        [[ -n "${_AI_TOOLS_ASSETS__KV[${key}]+x}" ]] || continue
        if ! _ai_tools_assets__read_list "${_AI_TOOLS_ASSETS__KV[${key}]}" "${_AI_TOOLS_ASSETS__KV_QUOTED[${key}]}"; then
            _ai_tools_assets__record_finding metadata.asset-conf asset-invalid "${path}" "${key} is not a list (${_AI_TOOLS_ASSETS__LIST_REASON})" "${name}"
            continue
        fi
        for item in "${_AI_TOOLS_ASSETS__LIST[@]}"; do
            if [[ "${key}" == requires_capabilities ]]; then
                (( ${#_AI_TOOLS_ASSETS__KV_ERRORS[@]} == 0 )) && _AI_TOOLS_ASSETS__ASSET_DECLARED+="${_AI_TOOLS_ASSETS__ASSET_DECLARED:+ }${item}"
                if _ai_tools_assets__is_capability "${item}"; then
                    _AI_TOOLS_ASSETS__ASSET_CAPABILITIES+="${_AI_TOOLS_ASSETS__ASSET_CAPABILITIES:+ }${item}"
                else
                    _ai_tools_assets__record_finding metadata.asset-conf capability-unknown "${path}" "$(_ai_tools_assets__sanitize_for_display "${item}") is not a capability base defines" "${name}"
                fi
            elif [[ "${item}" =~ ^integration-[a-z][a-z0-9-]*$ ]]; then
                _AI_TOOLS_ASSETS__ASSET_INTEGRATIONS+="${_AI_TOOLS_ASSETS__ASSET_INTEGRATIONS:+ }${item}"
            else
                _ai_tools_assets__record_finding metadata.asset-conf asset-invalid "${path}" "$(_ai_tools_assets__sanitize_for_display "${item}") is not written as integration-<name>" "${name}"
            fi
        done
    done
    for key in "${_AI_TOOLS_ASSETS__KV_KEYS[@]}"; do
        _ai_tools_assets__is_one_of "${key}" "${_AI_TOOLS_ASSETS__ASSET_CONF_KEYS[@]}" && continue
        [[ "${key}" =~ ^x_[A-Za-z0-9_]+$ ]] && continue
        _ai_tools_assets__record_finding set.conf.unknown-key asset-invalid "${path}" "${key} is not a key of asset.conf; a publisher's own key is x_<key>" "${name}"
    done
    return 0
}

# _ai_tools_assets__check_asset <set-dir> <set-name> <kind> <name> : every asset-scope rule of the subset over one
# asset, in the order the format checks them: name.grammar (which stops the rest), name.asset-prefix's reserved half,
# the frontmatter rules, metadata.asset-conf, and body.dynamic-injection (a scan that did not complete refuses the asset
# under that rule too). A file in _AI_TOOLS_ASSETS__UNREAD is not read, its set refused under file.size or file.binary.
# Publishes the asset's requirements in _AI_TOOLS_ASSETS__ASSET_CAPABILITIES and _AI_TOOLS_ASSETS__ASSET_INTEGRATIONS,
# and _AI_TOOLS_ASSETS__ASSET_DYNAMIC (1 when the asset declares skills.dynamic.v1).
_ai_tools_assets__check_asset() {
    local set_dir="$1" set_name="$2" kind="$3" name="$4" entry_file conf_path scan entry_read=1 IFS=$' \t\n'
    _AI_TOOLS_ASSETS__ASSET_CAPABILITIES=""; _AI_TOOLS_ASSETS__ASSET_INTEGRATIONS=""
    _AI_TOOLS_ASSETS__ASSET_DECLARED=""; _AI_TOOLS_ASSETS__ASSET_DYNAMIC=0
    entry_file="$(_ai_tools_assets__get_entry_paths "${kind}" "${name}")"; entry_file="${entry_file%%$'\t'*}"
    [[ "${kind}" == skills ]] && entry_file+="/SKILL.md"
    if ! _ai_tools_assets__is_valid_name "${name}"; then
        _ai_tools_assets__record_finding name.grammar asset-invalid "${entry_file}" "$(_ai_tools_assets__sanitize_for_display "${name}") is not 1-64 characters of a-z, 0-9 and single hyphens" "${name}"
        return 0
    fi
    if [[ "${name}" == ai-tools-* && "${set_name}" != core && "${set_name}" != ai-tools ]]; then
        _ai_tools_assets__record_finding name.asset-prefix asset-invalid "${entry_file}" "the ai-tools- prefix belongs to the sets core and ai-tools" "${name}"
    fi
    [[ -z "${_AI_TOOLS_ASSETS__UNREAD[${entry_file}]+x}" ]] || entry_read=0
    (( entry_read )) && _ai_tools_assets__check_frontmatter "${set_dir}/${entry_file}" "${entry_file}" "${kind}" "${name}"
    conf_path="metadata/${kind}/${name}/asset.conf"
    [[ -n "${_AI_TOOLS_ASSETS__FILES[${conf_path}]+x}" && -z "${_AI_TOOLS_ASSETS__UNREAD[${conf_path}]+x}" ]] \
        && _ai_tools_assets__check_asset_conf "${set_dir}" "${conf_path}" "${name}"
    local -a declared=()
    IFS=' ' read -r -a declared <<< "${_AI_TOOLS_ASSETS__ASSET_DECLARED}"
    _ai_tools_assets__is_one_of "${AI_TOOLS_ASSETS__DYNAMIC_CAPABILITY}" "${declared[@]}" && _AI_TOOLS_ASSETS__ASSET_DYNAMIC=1
    if (( entry_read && _AI_TOOLS_ASSETS__ASSET_DYNAMIC == 0 )); then
        scan=0
        _ai_tools_assets__scan_substitution "${set_dir}/${entry_file}" || scan=$?
        case "${scan}" in
            0) _ai_tools_assets__record_finding body.dynamic-injection asset-invalid "${entry_file}" "a line runs a command when the asset loads, and the asset does not declare ${AI_TOOLS_ASSETS__DYNAMIC_CAPABILITY} in ${conf_path}" "${name}" ;;
            1) ;;
            *) _ai_tools_assets__record_finding body.dynamic-injection asset-invalid "${entry_file}" "the scan did not complete (grep exit ${_AI_TOOLS_ASSETS__SCAN_STATUS})" "${name}" ;;
        esac
    fi
    return 0
}

# _ai_tools_assets__scan_substitution <file> : the load-time substitution scan over one entry file -- !`command`
# at a line start or after whitespace, and a fence whose info string's first word carries `!`, anywhere in the file,
# the frontmatter included. One grep reads both patterns, so a no-match is one complete scan. Returns 0 for a match, 1
# for none, and 2 for a scan that did not complete (an unreadable file, grep missing or failing), with grep's own status
# in _AI_TOOLS_ASSETS__SCAN_STATUS. The caller reports 2 as a finding, so a scan that failed does not read as a clean
# file.
_ai_tools_assets__scan_substitution() {
    local status=0
    LC_ALL=C grep -qaE -e '(^|[[:space:]])!`' -e '^[[:space:]]*(```+|~~~+)[[:space:]]*[^[:space:]]*!' -- "$1" 2>/dev/null \
        || status=$?
    _AI_TOOLS_ASSETS__SCAN_STATUS="${status}"
    case "${status}" in
        0|1) return "${status}" ;;
        *)   return 2 ;;
    esac
}

# ── The validator ────────────────────────────────────────────────────────────────────────────────────────────────────

# _ai_tools_assets__validate <set-dir> <set-name> <profile> : every rule of the subset over one set, into the finding
# arrays, with the assets listed in _AI_TOOLS_ASSETS__ASSETS (`<kind>|<name>`) and each asset's requirements recorded
# under that key in _AI_TOOLS_ASSETS__REQ_CAPABILITIES, _AI_TOOLS_ASSETS__REQ_INTEGRATIONS
# and _AI_TOOLS_ASSETS__REQ_DYNAMIC. Reads the tree as data and does not take an ownership input; the resolver runs
# the trust walk and the verifier ahead of it. A walk that stopped leaves the later rules
# unread.
_ai_tools_assets__validate() {
    local set_dir="$1" set_name="$2" profile="$3" asset inventory_error
    declare -ga _AI_TOOLS_ASSETS__ASSETS=()
    declare -gA _AI_TOOLS_ASSETS__REQ_CAPABILITIES=() _AI_TOOLS_ASSETS__REQ_INTEGRATIONS=() _AI_TOOLS_ASSETS__REQ_DYNAMIC=()
    _ai_tools_assets__reset_findings
    _ai_tools_assets__walk_tree "${set_dir}" || return 0
    _ai_tools_assets__check_text "${set_dir}"
    _ai_tools_assets__is_valid_name "${set_name}" \
        || _ai_tools_assets__record_finding name.grammar set-invalid . "$(_ai_tools_assets__sanitize_for_display "${set_name}") is not 1-64 characters of a-z, 0-9 and single hyphens"
    _ai_tools_assets__check_root_entries "${profile}"
    _ai_tools_assets__check_set_conf "${set_dir}" "${set_name}"
    _ai_tools_assets__list_assets
    _ai_tools_assets__check_skill_entries
    if [[ "${profile}" == release ]]; then
        if (( _AI_TOOLS_ASSETS__VERIFIER_LOADED )); then
            inventory_error="$(ai_tools_assets_verify__verify_inventory "${set_dir}" 2>&1 >/dev/null)" \
                || _ai_tools_assets__record_finding release.inventory set-invalid SHA256SUMS "$(_ai_tools_assets__sanitize_for_display "${inventory_error##*$'\n'}")"
        else
            _ai_tools_assets__record_finding release.inventory set-invalid SHA256SUMS "the inventory reader (assets-verify.lib.sh) did not load"
        fi
    fi
    for asset in "${_AI_TOOLS_ASSETS__ASSETS[@]}"; do
        _ai_tools_assets__check_asset "${set_dir}" "${set_name}" "${asset%%|*}" "${asset#*|}"
        _AI_TOOLS_ASSETS__REQ_CAPABILITIES["${asset}"]="${_AI_TOOLS_ASSETS__ASSET_CAPABILITIES}"
        _AI_TOOLS_ASSETS__REQ_INTEGRATIONS["${asset}"]="${_AI_TOOLS_ASSETS__ASSET_INTEGRATIONS}"
        _AI_TOOLS_ASSETS__REQ_DYNAMIC["${asset}"]="${_AI_TOOLS_ASSETS__ASSET_DYNAMIC}"
    done
    return 0
}

# ai_tools_assets__validate_set <set-directory> <source|release> : the subset of format 1 base enforces, over one set
# tree, as the conformance job runs it: prints each finding as `<rule>\t<path>\t<detail>` on stdout, the path relative
# to the set directory, and returns 0 with no finding, 1 with one, 2 for a profile other than those two, or a path
# that is not a directory or is a symlink. The signature is not checked here; under `release` the inventory half
# of the verifier is.
ai_tools_assets__validate_set() {
    local set_dir="${1:-}" profile="${2:-}" index
    [[ "${profile}" == source || "${profile}" == release ]] || return 2
    [[ -n "${set_dir}" && -d "${set_dir}" && ! -L "${set_dir}" ]] || return 2
    set_dir="${set_dir%/}"
    _ai_tools_assets__validate "${set_dir}" "${set_dir##*/}" "${profile}"
    for (( index = 0; index < ${#_AI_TOOLS_ASSETS__FINDING_RULE[@]}; index++ )); do
        printf '%s\t%s\t%s\n' "${_AI_TOOLS_ASSETS__FINDING_RULE[index]}" "$(_ai_tools_assets__sanitize_for_display "${_AI_TOOLS_ASSETS__FINDING_PATH[index]}")" \
            "$(_ai_tools_assets__sanitize_for_display "${_AI_TOOLS_ASSETS__FINDING_DETAIL[index]}")"
    done
    (( ${#_AI_TOOLS_ASSETS__FINDING_RULE[@]} == 0 ))
}

# ── The plan ─────────────────────────────────────────────────────────────────────────────────────────────────────────
# ai_tools_assets__plan reads every input once and publishes, without writing a file or printing a record:
#   AI_TOOLS_ASSETS__LIST_STATE        ok, absent (no operator.conf), untrusted or invalid; AI_TOOLS_ASSETS__LIST_DETAIL
#   AI_TOOLS_ASSETS__ENTRIES           the enable list's entries in order, each once
#   AI_TOOLS_ASSETS__STATE[entry]      `linked` or the reason token
#   AI_TOOLS_ASSETS__DETAIL[entry]     what the token does not say
#   _AI_TOOLS_ASSETS__KIND[entry], _AI_TOOLS_ASSETS__VIEW_NAME[entry]
#   _AI_TOOLS_ASSETS__SOURCE[entry]    the winning copy's path
#   AI_TOOLS_ASSETS__CAPS[entry]       the capabilities a linked asset declares, printed beside it
#   the actions (_AI_TOOLS_ASSETS__ACTION_*) the apply takes and the rows (AI_TOOLS_ASSETS__ROW_* and
#   _AI_TOOLS_ASSETS__ROW_*) for what it found.

# _ai_tools_assets__reset_plan : empty every plan output.
_ai_tools_assets__reset_plan() {
    AI_TOOLS_ASSETS__LIST_STATE=ok; AI_TOOLS_ASSETS__LIST_DETAIL=""
    declare -ga AI_TOOLS_ASSETS__ENTRIES=() _AI_TOOLS_ASSETS__ROOT_LIST=() _AI_TOOLS_ASSETS__AGENTS=() _AI_TOOLS_ASSETS__IDLE_AGENTS=()
    declare -gA AI_TOOLS_ASSETS__STATE=() AI_TOOLS_ASSETS__DETAIL=() _AI_TOOLS_ASSETS__KIND=() _AI_TOOLS_ASSETS__VIEW_NAME=() \
        _AI_TOOLS_ASSETS__SOURCE=() AI_TOOLS_ASSETS__CAPS=() _AI_TOOLS_ASSETS__ROOT_STATE=() _AI_TOOLS_ASSETS__SET_STATE=() \
        _AI_TOOLS_ASSETS__SET_DETAIL=() _AI_TOOLS_ASSETS__SET_ASSETS=() \
        _AI_TOOLS_ASSETS__ASSET_STATE=() _AI_TOOLS_ASSETS__ASSET_DETAIL=() _AI_TOOLS_ASSETS__ASSET_CAPS=() \
        _AI_TOOLS_ASSETS__AGENT_DIR=() _AI_TOOLS_ASSETS__AGENT_ROOT=() _AI_TOOLS_ASSETS__RECEIVES=() _AI_TOOLS_ASSETS__IMPLEMENTS=() \
        _AI_TOOLS_ASSETS__IDLE_DIR=() \
        _AI_TOOLS_ASSETS__INTEGRATIONS=() _AI_TOOLS_ASSETS__DESIRED_ID=() _AI_TOOLS_ASSETS__DIR_REPORTED=()
    declare -ga _AI_TOOLS_ASSETS__ACTION_OPERATION=() _AI_TOOLS_ASSETS__ACTION_PATH=() _AI_TOOLS_ASSETS__ACTION_TARGET=() _AI_TOOLS_ASSETS__ACTION_SUBJECT_TYPE=() \
        _AI_TOOLS_ASSETS__ACTION_ITEM=() _AI_TOOLS_ASSETS__ACTION_AGENT=() _AI_TOOLS_ASSETS__ACTION_DETAIL=() \
        AI_TOOLS_ASSETS__ROW_SEVERITY=() AI_TOOLS_ASSETS__ROW_FINDING=() _AI_TOOLS_ASSETS__ROW_SUBJECT_TYPE=() AI_TOOLS_ASSETS__ROW_SUBJECT=() \
        _AI_TOOLS_ASSETS__ROW_ITEM=() _AI_TOOLS_ASSETS__ROW_AGENT=() AI_TOOLS_ASSETS__ROW_DETAIL=()
}

# _ai_tools_assets__record_row <severity> <finding> <subject-type> <subject> <item> <agent> <detail> : record one row
# the report writes: <item> and <agent> become the item's components, the agent's empty for a view-level row.
_ai_tools_assets__record_row() {
    AI_TOOLS_ASSETS__ROW_SEVERITY+=( "$1" ); AI_TOOLS_ASSETS__ROW_FINDING+=( "$2" ); _AI_TOOLS_ASSETS__ROW_SUBJECT_TYPE+=( "$3" )
    AI_TOOLS_ASSETS__ROW_SUBJECT+=( "$4" ); _AI_TOOLS_ASSETS__ROW_ITEM+=( "$5" ); _AI_TOOLS_ASSETS__ROW_AGENT+=( "$6" )
    AI_TOOLS_ASSETS__ROW_DETAIL+=( "$7" )
}

# _ai_tools_assets__record_action <op> <path> <target> <subject-type> <item> <agent> <detail> : record one change
# the apply makes: `link` (place or repoint <path> at <target>), `unlink` (remove the symlink at <path>), `convert`
# (replace a managed copy at <path> by a link to <target>).
_ai_tools_assets__record_action() {
    _AI_TOOLS_ASSETS__ACTION_OPERATION+=( "$1" ); _AI_TOOLS_ASSETS__ACTION_PATH+=( "$2" ); _AI_TOOLS_ASSETS__ACTION_TARGET+=( "$3" )
    _AI_TOOLS_ASSETS__ACTION_SUBJECT_TYPE+=( "$4" ); _AI_TOOLS_ASSETS__ACTION_ITEM+=( "$5" ); _AI_TOOLS_ASSETS__ACTION_AGENT+=( "$6" )
    _AI_TOOLS_ASSETS__ACTION_DETAIL+=( "$7" )
}

# _ai_tools_assets__read_enable_list : the entries of AI_TOOLS_ASSETS, read while operator.conf passes the trust
# predicate. An absent file, an absent key and `[]` enable no asset; an untrusted file and an invalid list enable none
# either, and set AI_TOOLS_ASSETS__LIST_STATE for the row that names them.
_ai_tools_assets__read_enable_list() {
    local config_path="${AI_TOOLS_OPERATOR_CONF}" entry
    local -a items=()
    local -A seen=()
    if [[ ! -e "${config_path}" && ! -L "${config_path}" ]]; then
        AI_TOOLS_ASSETS__LIST_STATE=absent
        return 0
    fi
    if ! ai_tools_conf__is_trusted "${config_path}"; then
        AI_TOOLS_ASSETS__LIST_STATE=untrusted
        AI_TOOLS_ASSETS__LIST_DETAIL="$(ai_tools_conf__read_untrusted_reason "${config_path}")"
        return 0
    fi
    ai_tools_conf__read_list items "${config_path}" AI_TOOLS_ASSETS 2>/dev/null || return 0
    if [[ "${ai_tools_conf__list_invalid:-0}" == 1 ]]; then
        AI_TOOLS_ASSETS__LIST_STATE=invalid
        AI_TOOLS_ASSETS__LIST_DETAIL="AI_TOOLS_ASSETS is not a valid list, so it is read as the empty list; write it as [a, b]"
        return 0
    fi
    for entry in "${items[@]}"; do
        [[ -n "${seen[${entry}]+x}" ]] && continue
        seen["${entry}"]=1
        AI_TOOLS_ASSETS__ENTRIES+=( "${entry}" )
    done
}

# _ai_tools_assets__read_provider <reader> <file> : run one provider reader of providers.lib.sh into <file> and keep its
# status, as the walk does, so a reader that failed is told apart from one that printed an empty set. Returns 1,
# the receivers marked unknown with the reader and the first line it printed on stderr, when the reader exits non-zero
# -- after a row or before one.
_ai_tools_assets__read_provider() {
    local reader="$1" file="$2" error status=0
    error="$( ("${reader}" > "${file}") 2>&1 )" || status=$?
    (( status == 0 )) && return 0
    error="${error%%$'\n'*}"
    _ai_tools_assets__record_receivers_unknown "${reader} exited ${status}${error:+: $(_ai_tools_assets__sanitize_for_display "${error}")}"
    return 1
}

# _ai_tools_assets__record_receivers_unknown <reason> : record that the receiving agents could not be read. The first
# reason
# stands.
_ai_tools_assets__record_receivers_unknown() {
    [[ "${_AI_TOOLS_ASSETS__RECEIVERS_STATE}" == ok ]] || return 0
    _AI_TOOLS_ASSETS__RECEIVERS_STATE=unknown
    _AI_TOOLS_ASSETS__RECEIVERS_DETAIL="$1"
}

# _ai_tools_assets__read_receivers : the enabled agents and, for each, the kinds it receives, the directory it reads
# each from, the path outside its config directory where it reads a kind's whole view (the registry's root field),
# and the profiles it implements; then the installed agents that are not enabled, whose directories lose their resolver
# links. An agent receives a kind when its manifest names the kind's directory field or lists a profile of the kind
# in asset_profiles. asset_profiles absent reads as the base profile of each kind whose directory the manifest names;
# a token base does not define is not implemented.
#
# The receivers are what the capability rule is held to, so a failed read does not yield an empty set: a reader
# that exits non-zero, and an empty enabled set ai_tools_providers__evaluate_empty_agents classifies as `fault` (an
# input the trust predicate refused, a list naming agents none of which resolved) or does not classify, leave
# _AI_TOOLS_ASSETS__RECEIVERS_STATE `unknown` with the reason in _AI_TOOLS_ASSETS__RECEIVERS_DETAIL. `none` --
# AI_TOOLS_AGENTS asks for none -- is the valid empty set.
_ai_tools_assets__read_receivers() {
    local listing verdict
    _AI_TOOLS_ASSETS__RECEIVERS_STATE=ok; _AI_TOOLS_ASSETS__RECEIVERS_DETAIL=""
    if ! listing="$(mktemp 2>/dev/null)"; then
        _ai_tools_assets__record_receivers_unknown "no temporary file for the provider readers"
        return 0
    fi
    _ai_tools_assets__read_agent_lists "${listing}"
    rm -f -- "${listing}"
    # Where operator.conf is refused, the enable list is refused with it (enable-list-untrusted) and no entry asks
    # for a capability, so the empty set is read as the resolver printed it: every installed agent is not enabled
    # and loses its resolver links, the same less-access reading the list takes.
    if [[ "${_AI_TOOLS_ASSETS__RECEIVERS_STATE}" == ok && "${AI_TOOLS_ASSETS__LIST_STATE}" != untrusted ]] \
            && (( ${#_AI_TOOLS_ASSETS__AGENTS[@]} == 0 )); then
        verdict="$(ai_tools_providers__evaluate_empty_agents 2>/dev/null)" || verdict=""
        case "${verdict%%$'\t'*}" in
            none)  ;;
            fault) _ai_tools_assets__record_receivers_unknown "the enabled agents are a fault: $(_ai_tools_assets__sanitize_for_display "${verdict#*$'\t'}")" ;;
            *)     _ai_tools_assets__record_receivers_unknown "the enabled agent set is empty and ai_tools_providers__evaluate_empty_agents did not classify it" ;;
        esac
    fi
}

# _ai_tools_assets__read_agent_lists <file> : the readers _ai_tools_assets__read_receivers runs, each into <file>
# in turn; stops at the first that fails.
_ai_tools_assets__read_agent_lists() {
    local listing="$1" agent config_dir kind field directory value profiles_declared token root_path
    local -a tokens=()
    local -A enabled=()
    _ai_tools_assets__read_provider ai_tools_providers__list_enabled_agents "${listing}" || return 0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        enabled["${agent}"]=1
        _AI_TOOLS_ASSETS__AGENTS+=( "${agent}" )
        config_dir="$(ai_tools_providers__read_agent_manifest_field "${agent}" config_dir 2>/dev/null || true)"
        profiles_declared=0
        value="$(ai_tools_providers__read_agent_manifest_field "${agent}" asset_profiles 2>/dev/null)" && profiles_declared=1
        tokens=()
        (( profiles_declared )) && ai_tools_conf__split_list_value tokens "${value}" 0 "asset_profiles in the ${agent} manifest" 2>/dev/null
        while IFS= read -r kind; do
            field="$(_ai_tools_assets__get_kind_field "${kind}" manifest_field)"
            directory="$(ai_tools_providers__read_agent_manifest_field "${agent}" "${field}" 2>/dev/null || true)"
            if ai_tools_control_plane__is_agent_config_dir_valid "${config_dir}" && ai_tools_control_plane__is_agent_config_dir_valid "${directory}"; then
                _AI_TOOLS_ASSETS__AGENT_DIR["${agent}|${kind}"]="${AI_TOOLS_ASSETS_HOME}/${config_dir}/${directory}"
                _AI_TOOLS_ASSETS__RECEIVES["${agent}|${kind}"]=1
                (( profiles_declared )) || _AI_TOOLS_ASSETS__IMPLEMENTS["${agent}|$(_ai_tools_assets__get_kind_field "${kind}" base_profile)"]=1
            fi
            field="$(_ai_tools_assets__get_kind_field "${kind}" root_field)"
            if [[ -n "${field}" ]] && root_path="$(ai_tools_providers__read_agent_manifest_field "${agent}" "${field}" 2>/dev/null)" \
                    && [[ -n "${root_path}" ]]; then
                _AI_TOOLS_ASSETS__AGENT_ROOT["${agent}|${kind}"]="${root_path}"
            fi
        done < <(_ai_tools_assets__list_kinds)
        for token in "${tokens[@]}"; do
            _ai_tools_assets__is_capability "${token}" || continue
            _AI_TOOLS_ASSETS__IMPLEMENTS["${agent}|${token}"]=1
            _ai_tools_assets__get_kind_field "${token%%.*}" id >/dev/null 2>&1 && _AI_TOOLS_ASSETS__RECEIVES["${agent}|${token%%.*}"]=1
        done
    done < "${listing}"
    _ai_tools_assets__read_provider ai_tools_providers__list_installed_agents "${listing}" || return 0
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" && -z "${enabled[${agent}]+x}" ]] || continue
        _AI_TOOLS_ASSETS__IDLE_AGENTS+=( "${agent}" )
        config_dir="$(ai_tools_providers__read_agent_manifest_field "${agent}" config_dir 2>/dev/null || true)"
        while IFS= read -r kind; do
            directory="$(ai_tools_providers__read_agent_manifest_field "${agent}" "$(_ai_tools_assets__get_kind_field "${kind}" manifest_field)" 2>/dev/null || true)"
            ai_tools_control_plane__is_agent_config_dir_valid "${config_dir}" && ai_tools_control_plane__is_agent_config_dir_valid "${directory}" \
                && _AI_TOOLS_ASSETS__IDLE_DIR["${agent}|${kind}"]="${AI_TOOLS_ASSETS_HOME}/${config_dir}/${directory}"
        done < <(_ai_tools_assets__list_kinds)
    done < "${listing}"
    _ai_tools_assets__read_provider ai_tools_providers__list_enabled_integrations "${listing}" || return 0
    while IFS= read -r agent; do
        [[ -n "${agent}" ]] && _AI_TOOLS_ASSETS__INTEGRATIONS["${agent}"]=1
    done < "${listing}"
}

# _ai_tools_assets__read_roots : the roots from AI_TOOLS_ASSETS_ROOTS, each with its state: absent, trusted
# or untrusted.
_ai_tools_assets__read_roots() {
    local root
    local -a roots=()
    read -r -a roots <<< "${AI_TOOLS_ASSETS_ROOTS}"
    for root in "${roots[@]}"; do
        root="${root%/}"
        _AI_TOOLS_ASSETS__ROOT_LIST+=( "${root}" )
        if [[ ! -e "${root}" && ! -L "${root}" ]]; then
            _AI_TOOLS_ASSETS__ROOT_STATE["${root}"]=absent
        elif ai_tools_conf__is_trusted "${root}" && [[ -d "${root}" ]]; then
            _AI_TOOLS_ASSETS__ROOT_STATE["${root}"]=trusted
        else
            _AI_TOOLS_ASSETS__ROOT_STATE["${root}"]=untrusted
        fi
    done
}

# _ai_tools_assets__copy_dir <root-index> <set> : print where <set> sits under the root at <root-index>: <root>/<set>
# under the first two, the base root itself for the set `ai-tools` under the third, an empty string otherwise.
_ai_tools_assets__copy_dir() {
    local index="$1" set="$2"
    if (( index < 2 )); then
        printf '%s/%s' "${_AI_TOOLS_ASSETS__ROOT_LIST[index]}" "${set}"
    elif (( index == 2 )) && [[ "${set}" == ai-tools ]]; then
        printf '%s' "${_AI_TOOLS_ASSETS__ROOT_LIST[index]}"
    fi
}

# _ai_tools_assets__is_resolver_link <path> : succeed when <path> is a symlink whose target, read one hop, is under one
# of the roots. The view and the agents' directories tell a resolver link from every other entry by this alone.
_ai_tools_assets__is_resolver_link() {
    local target root
    [[ -L "$1" ]] || return 1
    target="$(readlink -- "$1" 2>/dev/null)" || return 1
    for root in "${_AI_TOOLS_ASSETS__ROOT_LIST[@]}"; do
        [[ "${target}" == "${root}/"* ]] && return 0
    done
    return 1
}

# ── Destinations ─────────────────────────────────────────────────────────────────────────────────────────────────────
# The directories a link is written in or removed from. The plan checks each before it plans an action there,
# and the apply checks it again after creating an absent one and before the first write under it. A directory that fails
# is reported once (view-dir-untrusted, agent-dir-untrusted), every action under it is dropped, and it is not re-owned
# or re-moded: a repair would keep whatever was placed inside it.

# _ai_tools_assets__is_dir_trusted <dir> : succeed when <dir> is a directory ai_tools_conf__is_trusted accepts:
# root-owned, not a symlink, writable by neither group nor other.
_ai_tools_assets__is_dir_trusted() { ai_tools_conf__is_trusted "$1" && [[ -d "$1" ]]; }

# _ai_tools_assets__is_config_dir_trusted <dir> : succeed when an agent's config directory is a directory, not
# a symlink, root-owned, and sticky wherever it is group- or other-writable. The directory ships 3770 root:<group>,
# so the sandbox account keeps its own state there; the sticky bit is what keeps it from renaming or unlinking an entry
# root owns.
_ai_tools_assets__is_config_dir_trusted() {
    local meta mode
    [[ -d "$1" && ! -L "$1" ]] || return 1
    meta="$(stat -c '%u %a' -- "$1" 2>/dev/null)" || return 1
    [[ "${meta%% *}" == 0 ]] || return 1
    mode="${meta##* }"
    [[ "${mode}" =~ ^[0-7]+$ ]] || return 1
    (( (8#${mode} & 8#022) == 0 || (8#${mode} & 8#1000) != 0 ))
}

# _ai_tools_assets__is_destination_trusted <view|agent> <dir> : print the first directory on the way to <dir> that is
# not a destination, and return 1; return 0 when every one is. A view directory needs the home root
# (AI_TOOLS_ASSETS_HOME) to pass _ai_tools_assets__is_dir_trusted, and itself to pass it or be absent. An agent's kind
# directory needs the home root, its config directory to pass _ai_tools_assets__is_config_dir_trusted, and itself
# to pass _ai_tools_assets__is_dir_trusted or be absent. An absent directory is the apply's to create
# (_ai_tools_assets__prepare_dir).
#
# A string check is enough here, and the reason is the modes. The plan checks a path and the apply writes by path,
# so an interval separates the two, and only a principal that can replace a component of the path can use it. Every
# directory this accepts is root-owned and not writable by the sandbox account, except the config directory, which is
# group-writable and sticky: the sticky bit refuses the account a rename or an unlink of the root-owned kind directory
# the check saw inside it. The one state the account reaches -- a name of its own at the kind directory's place, taken
# before root created the directory -- exists before the check, which refuses it. A descriptor-relative walk would close
# an interval no principal can use. A change to the config directory's mode or owner, or to the kind directory's owner,
# reopens this
# reasoning.
_ai_tools_assets__is_destination_trusted() {
    local which="$1" directory="$2"
    if ! _ai_tools_assets__is_dir_trusted "${AI_TOOLS_ASSETS_HOME}"; then
        printf '%s' "${AI_TOOLS_ASSETS_HOME}"
        return 1
    fi
    if [[ "${which}" == agent ]] && ! _ai_tools_assets__is_config_dir_trusted "${directory%/*}"; then
        printf '%s' "${directory%/*}"
        return 1
    fi
    [[ ! -e "${directory}" && ! -L "${directory}" ]] && return 0
    _ai_tools_assets__is_dir_trusted "${directory}" && return 0
    printf '%s' "${directory}"
    return 1
}

# _ai_tools_assets__read_dir_reason <dir> : what the destination predicates read of <dir>, for a row: a symlink and its
# target, absent, not a directory, or the owner uid and the mode.
_ai_tools_assets__read_dir_reason() {
    if [[ -L "$1" ]]; then
        printf 'a symlink to %s' "$(_ai_tools_assets__sanitize_for_display "$(readlink -- "$1" 2>/dev/null)")"
    elif [[ ! -e "$1" ]]; then
        printf 'absent'
    elif [[ ! -d "$1" ]]; then
        printf 'not a directory'
    else
        printf 'owner=%s mode=%s' "$(stat -c %u -- "$1" 2>/dev/null)" "$(stat -c %a -- "$1" 2>/dev/null)"
    fi
}

# _ai_tools_assets__record_dir_row <finding> <dir> <kind> <agent> <detail> : report a destination once per run,
# at attention.
_ai_tools_assets__record_dir_row() {
    [[ -z "${_AI_TOOLS_ASSETS__DIR_REPORTED[$2]+x}" ]] || return 0
    _AI_TOOLS_ASSETS__DIR_REPORTED["$2"]=1
    _ai_tools_assets__record_row attention "$1" directory "$2" "$3" "$4" "$5"
}

# _ai_tools_assets__prepare_dir <view|agent> <dir> <group> <create> : before the apply's first write under <dir>: create
# it root:<group> 0750 when <create> is 1 and no entry stands at its name, then hold it and the directories that hold it
# to _ai_tools_assets__is_destination_trusted. `install -d` over an existing directory re-owns and re-modes it,
# the repair this library does not make, so the create is guarded by the name's absence. A name taken between the plan
# and here is found by the check that follows the create. Prints the directory that fails and returns 1; returns 2
# for an absent directory left absent.
_ai_tools_assets__prepare_dir() {
    local which="$1" directory="$2" group="$3" create="$4"
    if [[ ! -e "${directory}" && ! -L "${directory}" ]]; then
        (( create )) || return 2
        install -d -o root -g "${group}" -m 0750 -- "${directory}" 2>/dev/null || true
    fi
    _ai_tools_assets__is_destination_trusted "${which}" "${directory}" || return 1
    [[ -d "${directory}" ]] || { printf '%s' "${directory}"; return 1; }
}

# _ai_tools_assets__is_set_tree_trusted <copy-dir> : succeed when the set directory and every entry under it are
# root-owned, and every entry but a symbolic link is writable by neither group nor other, read with lstat by one `find`
# whose status is read. A link is the file-shape rules' to refuse. The walk stops one level past the file-shape walk's
# depth bound: a tree deeper than that is refused by the file-shape walk that follows. Prints the reason on failure.
_ai_tools_assets__is_set_tree_trusted() {
    local set_directory="$1" offender walk_status=0
    if ! ai_tools_conf__is_trusted "${set_directory}" || [[ ! -d "${set_directory}" ]]; then
        printf '%s %s' "$(_ai_tools_assets__sanitize_for_display "${set_directory}")" "$(ai_tools_conf__read_untrusted_reason "${set_directory}")"
        return 1
    fi
    offender="$(find -P "${set_directory}" -mindepth 1 -maxdepth "$(( _AI_TOOLS_ASSETS__MAX_DEPTH + 1 ))" \
                    \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print -quit 2>/dev/null)" \
        || walk_status=$?
    if (( walk_status != 0 )); then
        printf 'the walk over %s did not complete (find exit %s)' "$(_ai_tools_assets__sanitize_for_display "${set_directory}")" "${walk_status}"
        return 1
    fi
    if [[ -n "${offender}" ]]; then
        printf '%s is not root-owned, or is writable by group or other' "$(_ai_tools_assets__sanitize_for_display "${offender}")"
        return 1
    fi
    return 0
}

# _ai_tools_assets__evaluate_set <copy-dir> <set> : resolve one set copy once per plan, through the predicates
# in the order the rule states -- the binding's presence, the trust walk, the file-shape walk, the verifier, then
# the set-scope rules and the set's own requirements. Caches the token (`ok` or the reason) and its detail
# by <copy-dir>, the requirements an asset of the set inherits, and the findings of the assets, which the per-asset
# reading consumes.
_ai_tools_assets__evaluate_set() {
    local set_directory="$1" set="$2" reason verify_error verify_status=0 index token IFS=$' \t\n'
    [[ -n "${_AI_TOOLS_ASSETS__SET_STATE[${set_directory}]+x}" ]] && return 0
    _AI_TOOLS_ASSETS__SET_STATE["${set_directory}"]=ok; _AI_TOOLS_ASSETS__SET_DETAIL["${set_directory}"]=""
    if [[ ! -e "${AI_TOOLS_ASSETS_BINDINGS_DIR}/${set}.conf" && ! -L "${AI_TOOLS_ASSETS_BINDINGS_DIR}/${set}.conf" ]]; then
        _ai_tools_assets__refuse_set "${set_directory}" set-unbound "no shipped binding names ${set} under ${AI_TOOLS_ASSETS_BINDINGS_DIR}"
        return 0
    fi
    if ! reason="$(_ai_tools_assets__is_set_tree_trusted "${set_directory}")"; then
        _ai_tools_assets__refuse_set "${set_directory}" path-untrusted "${reason}"
        return 0
    fi
    _ai_tools_assets__reset_findings
    if ! _ai_tools_assets__walk_tree "${set_directory}" || (( ${#_AI_TOOLS_ASSETS__FINDING_RULE[@]} > 0 )); then
        _ai_tools_assets__refuse_set "${set_directory}" set-invalid "${_AI_TOOLS_ASSETS__FINDING_RULE[0]}: $(_ai_tools_assets__sanitize_for_display "${_AI_TOOLS_ASSETS__FINDING_PATH[0]}"): ${_AI_TOOLS_ASSETS__FINDING_DETAIL[0]}"
        return 0
    fi
    if (( ! _AI_TOOLS_ASSETS__VERIFIER_LOADED )); then
        _ai_tools_assets__refuse_set "${set_directory}" set-unverified "the set verifier (assets-verify.lib.sh) did not load"
        return 0
    fi
    verify_error="$(ai_tools_assets_verify__verify_set "${set_directory}" "${set}" 2>&1 >/dev/null)" || verify_status=$?
    case "${verify_status}" in
        0) ;;
        1) _ai_tools_assets__refuse_set "${set_directory}" set-tampered "$(_ai_tools_assets__sanitize_for_display "${verify_error##*$'\n'}")"; return 0 ;;
        *) _ai_tools_assets__refuse_set "${set_directory}" set-unverified "$(_ai_tools_assets__sanitize_for_display "${verify_error##*$'\n'}")"; return 0 ;;
    esac
    # `host`: a release tree whose inventory the verifier has just read whole, so it is not hashed a second time.
    _ai_tools_assets__validate "${set_directory}" "${set}" host
    for (( index = 0; index < ${#_AI_TOOLS_ASSETS__FINDING_RULE[@]}; index++ )); do
        [[ -z "${_AI_TOOLS_ASSETS__FINDING_ASSET[index]}" ]] || continue
        token="${_AI_TOOLS_ASSETS__FINDING_TOKEN[index]}"
        _ai_tools_assets__refuse_set "${set_directory}" "${token}" "${_AI_TOOLS_ASSETS__FINDING_RULE[index]}: $(_ai_tools_assets__sanitize_for_display "${_AI_TOOLS_ASSETS__FINDING_PATH[index]}"): ${_AI_TOOLS_ASSETS__FINDING_DETAIL[index]}"
        return 0
    done
    local IFS=' '
    _AI_TOOLS_ASSETS__SET_ASSETS["${set_directory}"]="${_AI_TOOLS_ASSETS__ASSETS[*]-}"
    IFS=$' \t\n'
    if [[ -n "${_AI_TOOLS_ASSETS__SET_REQUIRES_BASE}" ]] \
            && ! _ai_tools_assets__is_version_at_least "${AI_TOOLS_VERSION:-dev}" "${_AI_TOOLS_ASSETS__SET_REQUIRES_BASE}"; then
        _ai_tools_assets__refuse_set "${set_directory}" requires-base "requires_base=$(_ai_tools_assets__sanitize_for_display "${_AI_TOOLS_ASSETS__SET_REQUIRES_BASE}"); the installed base is ${AI_TOOLS_VERSION:-dev}"
        return 0
    fi
    local -a tokens=()
    IFS=' ' read -r -a tokens <<< "${_AI_TOOLS_ASSETS__SET_CAPABILITIES}"
    if ! reason="$(_ai_tools_assets__is_every_capability_supported "" "${tokens[@]}")"; then
        _ai_tools_assets__refuse_set "${set_directory}" capability-unsupported "${reason}"
        return 0
    fi
    IFS=' ' read -r -a tokens <<< "${_AI_TOOLS_ASSETS__SET_INTEGRATIONS}"
    if ! reason="$(_ai_tools_assets__is_every_integration_enabled "${tokens[@]}")"; then
        _ai_tools_assets__refuse_set "${set_directory}" integration-off "${reason}"
        return 0
    fi
    # Each asset's own findings and requirements, read once here while the walk's records are current.
    _ai_tools_assets__evaluate_assets "${set_directory}"
}

# _ai_tools_assets__refuse_set <copy-dir> <token> <detail> : record a set's refusal.
_ai_tools_assets__refuse_set() {
    _AI_TOOLS_ASSETS__SET_STATE["$1"]="$2"
    _AI_TOOLS_ASSETS__SET_DETAIL["$1"]="$3"
}

# _ai_tools_assets__is_every_capability_supported <kind> <token>... : succeed when every token is implemented by every
# enabled agent receiving the kind -- <kind> empty reads each token's own kind, its first component, as at set scope.
# Prints the first token an agent lacks and the agent on failure. Fails on the first token while the receivers are
# unknown: an empty set read from a failed discovery would otherwise support every token.
_ai_tools_assets__is_every_capability_supported() {
    local kind="$1" token token_kind agent
    shift
    for token in "$@"; do
        if [[ "${_AI_TOOLS_ASSETS__RECEIVERS_STATE:-unknown}" != ok ]]; then
            printf '%s requires %s, and the receiving agents could not be read: %s' "${kind:-the set}" "${token}" \
                "${_AI_TOOLS_ASSETS__RECEIVERS_DETAIL:-no discovery ran}"
            return 1
        fi
        token_kind="${kind:-${token%%.*}}"
        for agent in "${_AI_TOOLS_ASSETS__AGENTS[@]}"; do
            [[ -n "${_AI_TOOLS_ASSETS__RECEIVES[${agent}|${token_kind}]+x}" ]] || continue
            [[ -n "${_AI_TOOLS_ASSETS__IMPLEMENTS[${agent}|${token}]+x}" ]] && continue
            printf '%s requires %s, which the enabled agent %s receiving %s does not implement' \
                "${kind:-the set}" "${token}" "${agent}" "${token_kind}"
            return 1
        done
    done
    return 0
}

# _ai_tools_assets__is_every_integration_enabled <integration-token>... : succeed when each `integration-<name>` is
# enabled; prints the first that is not.
_ai_tools_assets__is_every_integration_enabled() {
    local token
    for token in "$@"; do
        [[ -n "${_AI_TOOLS_ASSETS__INTEGRATIONS[${token#integration-}]+x}" ]] && continue
        printf '%s is not enabled in AI_TOOLS_INTEGRATIONS' "${token}"
        return 1
    done
    return 0
}

# _ai_tools_assets__evaluate_assets <copy-dir> : the state of every asset of a set that passed, keyed
# `<copy>|<kind>|<name>`: `ok`, or asset-invalid, capability-unknown, capability-unsupported or integration-off with its
# detail, from the findings and the requirements _ai_tools_assets__validate recorded over <copy-dir>, which its caller
# ran last: the set's bytes are read once.
_ai_tools_assets__evaluate_assets() {
    local set_directory="$1" asset kind name key index reason IFS=$' \t\n'
    local -a asset_rules=() tokens=() passed=() asset_tokens=() asset_paths=() asset_details=() asset_names=()
    asset_rules=( "${_AI_TOOLS_ASSETS__FINDING_RULE[@]}" ); asset_tokens=( "${_AI_TOOLS_ASSETS__FINDING_TOKEN[@]}" )
    asset_paths=( "${_AI_TOOLS_ASSETS__FINDING_PATH[@]}" ); asset_details=( "${_AI_TOOLS_ASSETS__FINDING_DETAIL[@]}" )
    asset_names=( "${_AI_TOOLS_ASSETS__FINDING_ASSET[@]}" )
    IFS=' ' read -r -a passed <<< "${_AI_TOOLS_ASSETS__SET_ASSETS[${set_directory}]}"
    for asset in "${passed[@]}"; do
        kind="${asset%%|*}"; name="${asset#*|}"; key="${set_directory}|${kind}|${name}"
        _AI_TOOLS_ASSETS__ASSET_STATE["${key}"]=ok; _AI_TOOLS_ASSETS__ASSET_DETAIL["${key}"]=""
        for (( index = 0; index < ${#asset_rules[@]}; index++ )); do
            [[ "${asset_names[index]}" == "${name}" ]] || continue
            [[ "${asset_paths[index]}" == "$(_ai_tools_assets__get_finding_path_prefix "${kind}" "${name}")"* \
                || "${asset_paths[index]}" == "metadata/${kind}/${name}/"* ]] || continue
            _AI_TOOLS_ASSETS__ASSET_STATE["${key}"]="${asset_tokens[index]}"
            _AI_TOOLS_ASSETS__ASSET_DETAIL["${key}"]="${asset_rules[index]}: $(_ai_tools_assets__sanitize_for_display "${asset_paths[index]}"): ${asset_details[index]}"
            continue 2
        done
        (( ${_AI_TOOLS_ASSETS__REQ_DYNAMIC[${asset}]:-0} )) && _AI_TOOLS_ASSETS__ASSET_CAPS["${key}"]="${AI_TOOLS_ASSETS__DYNAMIC_CAPABILITY}"
        # An asset is written in its kind's base profile, and requires the capabilities it declares beside it.
        IFS=' ' read -r -a tokens <<< "$(_ai_tools_assets__get_kind_field "${kind}" base_profile) ${_AI_TOOLS_ASSETS__REQ_CAPABILITIES[${asset}]:-}"
        if ! reason="$(_ai_tools_assets__is_every_capability_supported "${kind}" "${tokens[@]}")"; then
            _AI_TOOLS_ASSETS__ASSET_STATE["${key}"]="capability-unsupported"; _AI_TOOLS_ASSETS__ASSET_DETAIL["${key}"]="${reason}"
        elif IFS=' ' read -r -a tokens <<< "${_AI_TOOLS_ASSETS__REQ_INTEGRATIONS[${asset}]:-}" \
                && ! reason="$(_ai_tools_assets__is_every_integration_enabled "${tokens[@]}")"; then
            _AI_TOOLS_ASSETS__ASSET_STATE["${key}"]="integration-off"; _AI_TOOLS_ASSETS__ASSET_DETAIL["${key}"]="${reason}"
        fi
    done
}

# _ai_tools_assets__get_finding_path_prefix <kind> <name> : the path an asset's findings carry as their prefix:
# `skills/<name>/`,
# `agents/<name>.md`.
_ai_tools_assets__get_finding_path_prefix() {
    local path
    path="$(_ai_tools_assets__get_entry_paths "$1" "$2")"
    path="${path%%$'\t'*}"
    [[ "$1" == skills ]] && path+=/
    printf '%s' "${path}"
}

# ai_tools_assets__parse_id <identifier> : split <identifier> into AI_TOOLS_ASSETS__ID_SET, _AI_TOOLS_ASSETS__ID_KIND
# and _AI_TOOLS_ASSETS__ID_NAME. Returns 0, 1 for an identifier outside <set>/<kind>/<name> under the name grammar
# (id-malformed), 2 for a kind without a registry row (kind-unknown); AI_TOOLS_ASSETS__ID_DETAIL says which part.
ai_tools_assets__parse_id() {
    local identifier="${1-}"
    AI_TOOLS_ASSETS__ID_SET=""; _AI_TOOLS_ASSETS__ID_KIND=""; _AI_TOOLS_ASSETS__ID_NAME=""; AI_TOOLS_ASSETS__ID_DETAIL=""
    if [[ ! "${identifier}" =~ ^([^/]+)/([^/]+)/([^/]+)$ ]]; then
        AI_TOOLS_ASSETS__ID_DETAIL="an identifier is <set>/<kind>/<name>"
        return 1
    fi
    AI_TOOLS_ASSETS__ID_SET="${BASH_REMATCH[1]}"; _AI_TOOLS_ASSETS__ID_KIND="${BASH_REMATCH[2]}"; _AI_TOOLS_ASSETS__ID_NAME="${BASH_REMATCH[3]}"
    if ! _ai_tools_assets__is_valid_name "${AI_TOOLS_ASSETS__ID_SET}" || ! _ai_tools_assets__is_valid_name "${_AI_TOOLS_ASSETS__ID_NAME}"; then
        AI_TOOLS_ASSETS__ID_DETAIL="a set and a name are 1-64 characters of a-z, 0-9 and single hyphens"
        return 1
    fi
    if ! _ai_tools_assets__get_kind_field "${_AI_TOOLS_ASSETS__ID_KIND}" id >/dev/null; then
        AI_TOOLS_ASSETS__ID_DETAIL="the kinds are $(_ai_tools_assets__list_kinds | paste -sd, - | sed 's/,/, /g')"
        [[ "${_AI_TOOLS_ASSETS__ID_KIND}" == agents ]] && AI_TOOLS_ASSETS__ID_DETAIL="the identifier spells subagents where the set directory spells agents/"
        return 2
    fi
    return 0
}

# ai_tools_assets__is_binding_present <set> : succeed when a shipped binding names <set>, read as a path's presence; its
# content is the verifier's to judge.
ai_tools_assets__is_binding_present() {
    [[ -e "${AI_TOOLS_ASSETS_BINDINGS_DIR}/$1.conf" || -L "${AI_TOOLS_ASSETS_BINDINGS_DIR}/$1.conf" ]]
}

# _ai_tools_assets__resolve_entry <entry> : resolve one entry of the list to its state, its winning copy, its kind
# and its view name. The first root whose copy of the set holds the asset wins, so a local copy holding one asset
# overrides that asset alone; a copy refused at any predicate does not fall through to a lower root.
_ai_tools_assets__resolve_entry() {
    local entry="$1" status=0 index set_directory entry_path view_name first_set_directory="" key root
    ai_tools_assets__parse_id "${entry}" || status=$?
    if (( status != 0 )); then
        AI_TOOLS_ASSETS__STATE["${entry}"]="$([[ ${status} == 1 ]] && printf id-malformed || printf kind-unknown)"
        AI_TOOLS_ASSETS__DETAIL["${entry}"]="${AI_TOOLS_ASSETS__ID_DETAIL}"
        return 0
    fi
    _AI_TOOLS_ASSETS__KIND["${entry}"]="${_AI_TOOLS_ASSETS__ID_KIND}"
    entry_path="$(_ai_tools_assets__get_entry_paths "${_AI_TOOLS_ASSETS__ID_KIND}" "${_AI_TOOLS_ASSETS__ID_NAME}")"
    view_name="${entry_path#*$'\t'}"; entry_path="${entry_path%%$'\t'*}"
    _AI_TOOLS_ASSETS__VIEW_NAME["${entry}"]="${view_name}"
    if ! ai_tools_assets__is_binding_present "${AI_TOOLS_ASSETS__ID_SET}"; then
        AI_TOOLS_ASSETS__STATE["${entry}"]="set-unbound"
        AI_TOOLS_ASSETS__DETAIL["${entry}"]="no shipped binding names ${AI_TOOLS_ASSETS__ID_SET} under ${AI_TOOLS_ASSETS_BINDINGS_DIR}"
        return 0
    fi
    for (( index = 0; index < ${#_AI_TOOLS_ASSETS__ROOT_LIST[@]}; index++ )); do
        root="${_AI_TOOLS_ASSETS__ROOT_LIST[index]}"
        set_directory="$(_ai_tools_assets__copy_dir "${index}" "${AI_TOOLS_ASSETS__ID_SET}")"
        [[ -n "${set_directory}" ]] || continue
        [[ "${_AI_TOOLS_ASSETS__ROOT_STATE[${root}]}" == absent ]] && continue
        if [[ "${_AI_TOOLS_ASSETS__ROOT_STATE[${root}]}" == untrusted ]]; then
            [[ -e "${set_directory}" || -L "${set_directory}" ]] || continue
            AI_TOOLS_ASSETS__STATE["${entry}"]="path-untrusted"
            AI_TOOLS_ASSETS__DETAIL["${entry}"]="the root ${root} $(ai_tools_conf__read_untrusted_reason "${root}")"
            _AI_TOOLS_ASSETS__SOURCE["${entry}"]="${set_directory}"
            return 0
        fi
        [[ -e "${set_directory}/set.conf" || -L "${set_directory}/set.conf" ]] || continue
        [[ -n "${first_set_directory}" ]] || first_set_directory="${set_directory}"
        [[ -e "${set_directory}/${entry_path}" || -L "${set_directory}/${entry_path}" ]] || continue
        _AI_TOOLS_ASSETS__SOURCE["${entry}"]="${set_directory}/${entry_path}"
        _ai_tools_assets__evaluate_set "${set_directory}" "${AI_TOOLS_ASSETS__ID_SET}"
        if [[ "${_AI_TOOLS_ASSETS__SET_STATE[${set_directory}]}" != ok ]]; then
            AI_TOOLS_ASSETS__STATE["${entry}"]="${_AI_TOOLS_ASSETS__SET_STATE[${set_directory}]}"
            AI_TOOLS_ASSETS__DETAIL["${entry}"]="${_AI_TOOLS_ASSETS__SET_DETAIL[${set_directory}]}"
            return 0
        fi
        key="${set_directory}|${_AI_TOOLS_ASSETS__ID_KIND}|${_AI_TOOLS_ASSETS__ID_NAME}"
        if [[ -z "${_AI_TOOLS_ASSETS__ASSET_STATE[${key}]+x}" ]]; then
            AI_TOOLS_ASSETS__STATE["${entry}"]="asset-absent"
            AI_TOOLS_ASSETS__DETAIL["${entry}"]="${set_directory} does not hold a ${_AI_TOOLS_ASSETS__ID_KIND%s} named ${_AI_TOOLS_ASSETS__ID_NAME} the format reads"
            return 0
        fi
        if [[ "${_AI_TOOLS_ASSETS__ASSET_STATE[${key}]}" != ok ]]; then
            AI_TOOLS_ASSETS__STATE["${entry}"]="${_AI_TOOLS_ASSETS__ASSET_STATE[${key}]}"
            AI_TOOLS_ASSETS__DETAIL["${entry}"]="${_AI_TOOLS_ASSETS__ASSET_DETAIL[${key}]}"
            return 0
        fi
        AI_TOOLS_ASSETS__STATE["${entry}"]=linked
        AI_TOOLS_ASSETS__CAPS["${entry}"]="${_AI_TOOLS_ASSETS__ASSET_CAPS[${key}]:-}"
        AI_TOOLS_ASSETS__DETAIL["${entry}"]="from ${set_directory}"
        return 0
    done
    if [[ -n "${first_set_directory}" ]]; then
        AI_TOOLS_ASSETS__STATE["${entry}"]="asset-absent"
        AI_TOOLS_ASSETS__DETAIL["${entry}"]="no root's copy of ${AI_TOOLS_ASSETS__ID_SET} holds ${entry_path}"
    else
        AI_TOOLS_ASSETS__STATE["${entry}"]="set-absent"
        AI_TOOLS_ASSETS__DETAIL["${entry}"]="no root holds ${AI_TOOLS_ASSETS__ID_SET}/set.conf; the entry is pending its package"
    fi
}

# _ai_tools_assets__mark_name_conflicts : two linkable entries naming one kind and name from different sets are both
# name-clash.
_ai_tools_assets__mark_name_conflicts() {
    local entry other key
    local -A first=()
    for entry in "${AI_TOOLS_ASSETS__ENTRIES[@]}"; do
        [[ "${AI_TOOLS_ASSETS__STATE[${entry}]}" == linked ]] || continue
        key="${_AI_TOOLS_ASSETS__KIND[${entry}]}|${_AI_TOOLS_ASSETS__VIEW_NAME[${entry}]}"
        [[ -n "${first[${key}]+x}" ]] || { first["${key}"]="${entry}"; continue; }
        other="${first[${key}]}"
        AI_TOOLS_ASSETS__STATE["${entry}"]="name-clash"; AI_TOOLS_ASSETS__DETAIL["${entry}"]="${other} names the same ${_AI_TOOLS_ASSETS__KIND[${entry}]%s}"
        AI_TOOLS_ASSETS__STATE["${other}"]="name-clash"; AI_TOOLS_ASSETS__DETAIL["${other}"]="${entry} names the same ${_AI_TOOLS_ASSETS__KIND[${entry}]%s}"
    done
}

# _ai_tools_assets__plan_view <kind> : the view changes for one kind: a desired name absent or held by a resolver link
# with another target is linked; a resolver link whose name is not desired is unlinked; anything else at a desired name
# is view-occupied and left as it is; a temporary name holding a link the library leaves
# (_ai_tools_assets__is_own_leftover) is removed; every entry that is neither a resolver link, a copy base seeded
# (_ai_tools_assets__is_seeded_copy), the kind's README.md nor a temporary name is view-foreign and left as it is.
# Publishes the names an agent links -- the view as the apply leaves it, name -> `resolver` or `seeded` --
# in _AI_TOOLS_ASSETS__VIEW_AFTER, so a foreign entry is not linked into an agent's directory. Returns 1
# when _ai_tools_assets__is_destination_trusted refuses the view or the home root that holds it, or the view could not
# be listed: the kind is then not planned (_ai_tools_assets__record_kind_unplanned), so no link in the view
# or in an agent's directory of that kind is placed or removed.
_ai_tools_assets__plan_view() {
    local kind="$1" view="${AI_TOOLS_ASSETS_HOME}/$1" name entry target failed
    local -A present=() desired=()
    declare -gA _AI_TOOLS_ASSETS__VIEW_AFTER=()
    if ! failed="$(_ai_tools_assets__is_destination_trusted view "${view}")"; then
        _ai_tools_assets__record_kind_unplanned "${kind}" view-dir-untrusted "${failed}" \
            "$(_ai_tools_assets__read_dir_reason "${failed}"), so no link of this kind is placed or removed in the view or in an agent's directory; the directory is not repaired, since a repair would keep what was placed inside it"
        return 1
    fi
    if [[ -d "${view}" ]]; then
        if ! _ai_tools_assets__enumerate "${view}"; then
            _ai_tools_assets__record_kind_unplanned "${kind}" error "${view}" \
                "the view could not be listed (${_AI_TOOLS_ASSETS__LISTING_ERROR}), so this kind is not planned: a resolver link there that no entry justifies stays in place"
            return 1
        fi
        for name in "${_AI_TOOLS_ASSETS__LISTING[@]}"; do present["${name}"]=1; done
    fi
    for entry in "${AI_TOOLS_ASSETS__ENTRIES[@]}"; do
        [[ "${AI_TOOLS_ASSETS__STATE[${entry}]}" == linked && "${_AI_TOOLS_ASSETS__KIND[${entry}]}" == "${kind}" ]] || continue
        name="${_AI_TOOLS_ASSETS__VIEW_NAME[${entry}]}"
        if [[ -n "${present[${name}]+x}" ]] && ! _ai_tools_assets__is_resolver_link "${view}/${name}"; then
            AI_TOOLS_ASSETS__STATE["${entry}"]="view-occupied"
            if [[ -L "${view}/${name}" ]]; then
                target="a link to $(_ai_tools_assets__sanitize_for_display "$(readlink -- "${view}/${name}" 2>/dev/null)")"
            else
                target="a real entry"
            fi
            AI_TOOLS_ASSETS__DETAIL["${entry}"]="${view}/${name} is ${target} and not a resolver link; left as it is"
            continue
        fi
        desired["${name}"]="${entry}"
    done
    for name in "${!present[@]}"; do
        if [[ "${name}" =~ ^\..+\.ai-tools-assets\.tmp$ ]] && _ai_tools_assets__is_own_leftover "${view}/${name}"; then
            _ai_tools_assets__record_action unlink "${view}/${name}" "" file "${kind}/${name}" "" "a temporary name an interrupted run left"
            continue
        fi
        [[ "${name}" == README.md || -n "${desired[${name}]+x}" ]] && continue
        if _ai_tools_assets__is_resolver_link "${view}/${name}"; then
            _ai_tools_assets__record_action unlink "${view}/${name}" "" file "${kind}/${name}" "" "no enabled entry justifies it"
            continue
        fi
        if _ai_tools_assets__is_seeded_copy "${kind}" "${view}/${name}"; then
            _AI_TOOLS_ASSETS__VIEW_AFTER["${name}"]=seeded
            continue
        fi
        _ai_tools_assets__is_occupied_name "${kind}" "${name}" && continue
        _ai_tools_assets__record_row attention view-foreign file "${view}/${name}" "${kind}/${name}" "" \
            "neither a resolver link nor a copy base seeded; left as it is and not linked into an agent's directory, though an agent that reads the whole view still loads it until it is removed"
    done
    for name in "${!desired[@]}"; do
        entry="${desired[${name}]}"
        _AI_TOOLS_ASSETS__VIEW_AFTER["${name}"]=resolver
        _AI_TOOLS_ASSETS__DESIRED_ID["${kind}|${name}"]="${entry}"
        target="${_AI_TOOLS_ASSETS__SOURCE[${entry}]}"
        if [[ -n "${present[${name}]+x}" && "$(readlink -- "${view}/${name}" 2>/dev/null)" == "${target}" ]]; then
            continue
        fi
        if [[ -n "${present[${name}]+x}" ]]; then
            _ai_tools_assets__record_action link "${view}/${name}" "${target}" file "${entry}" "" "repointed at ${target}"
        else
            _ai_tools_assets__record_action link "${view}/${name}" "${target}" file "${entry}" "" "linked to ${target}"
        fi
    done
}

# _ai_tools_assets__enumerate <dir> [find-test...] : list the entries of <dir> one level down that pass the tests
# into _AI_TOOLS_ASSETS__LISTING, through one find written to a file whose status is read, as the walk does. Returns 1
# with the reason in _AI_TOOLS_ASSETS__LISTING_ERROR when find exits non-zero, after a name or before one, so a listing
# that failed is told apart from an empty directory.
_ai_tools_assets__enumerate() {
    local directory="$1" listing error status=0 name
    shift
    declare -ga _AI_TOOLS_ASSETS__LISTING=()
    _AI_TOOLS_ASSETS__LISTING_ERROR=""
    if ! listing="$(mktemp 2>/dev/null)"; then
        _AI_TOOLS_ASSETS__LISTING_ERROR="no temporary file for the listing"
        return 1
    fi
    error="$( (find -P "${directory}" -mindepth 1 -maxdepth 1 "$@" -printf '%P\0' > "${listing}") 2>&1 )" || status=$?
    if (( status != 0 )); then
        rm -f -- "${listing}"
        error="${error%%$'\n'*}"
        _AI_TOOLS_ASSETS__LISTING_ERROR="find exit ${status}${error:+: $(_ai_tools_assets__sanitize_for_display "${error}")}"
        return 1
    fi
    while IFS= read -r -d '' name; do _AI_TOOLS_ASSETS__LISTING+=( "${name}" ); done < "${listing}"
    rm -f -- "${listing}"
}

# _ai_tools_assets__record_kind_unplanned <kind> <finding> <directory> <detail> : report a view directory the plan does
# not act in: one row for the directory, once per run, at `unreadable` for an `error` and at `attention` otherwise,
# and each enabled entry of <kind> still on its way to `linked` resolved to <finding>, so no entry reads linked
# in a view this run did not
# plan.
_ai_tools_assets__record_kind_unplanned() {
    local kind="$1" finding="$2" directory="$3" detail="$4" entry
    if [[ -z "${_AI_TOOLS_ASSETS__DIR_REPORTED[${directory}]+x}" ]]; then
        _AI_TOOLS_ASSETS__DIR_REPORTED["${directory}"]=1
        _ai_tools_assets__record_row "$([[ "${finding}" == error ]] && printf unreadable || printf attention)" "${finding}" directory \
            "${directory}" "${kind}" "" "${detail}"
    fi
    for entry in "${AI_TOOLS_ASSETS__ENTRIES[@]}"; do
        [[ "${AI_TOOLS_ASSETS__STATE[${entry}]}" == linked && "${_AI_TOOLS_ASSETS__KIND[${entry}]}" == "${kind}" ]] || continue
        AI_TOOLS_ASSETS__STATE["${entry}"]="${finding}"
        AI_TOOLS_ASSETS__DETAIL["${entry}"]="${directory} is not planned this run; its row says why"
    done
}

# _ai_tools_assets__is_seeded_copy <kind> <path> : succeed when a real entry of the view is a copy base's seeder placed:
# a name in the seeder's namespace (`ai-tools-*`) and the portable set, its kind's shape (a skill a directory holding
# a regular SKILL.md, a subagent a regular `.md` file), root-owned together with every entry under it, and the managed
# marker -- an operator's in-place edit of a seeded copy included. The ownership walk's status is read, so a walk
# that failed does not make a seeded copy. Every other real entry is the view's foreign entry, which the strict rule
# does not link into an agent's directory.
_ai_tools_assets__is_seeded_copy() {
    local kind="$1" path="$2" name="${2##*/}" marker offender
    [[ ! -L "${path}" && "${name}" == ai-tools-* ]] && ai_tools_conf__is_portable_name_valid "${name}" || return 1
    if [[ "$(_ai_tools_assets__get_kind_field "${kind}" shape)" == directory ]]; then
        marker="${path}/SKILL.md"
        [[ -d "${path}" && -f "${marker}" && ! -L "${marker}" ]] || return 1
    else
        marker="${path}"
        [[ "${name}" == *.md && -f "${path}" ]] || return 1
    fi
    offender="$(find -P "${path}" ! -uid 0 -print -quit 2>/dev/null)" || return 1
    [[ -z "${offender}" ]] || return 1
    ai_tools_managed_assets__is_managed "${marker}"
}

# _ai_tools_assets__is_occupied_name <kind> <view-name> : succeed when an enabled entry of <kind> resolved
# to view-occupied at <view-name>, whose row already reports the entry at the name.
_ai_tools_assets__is_occupied_name() {
    local entry
    for entry in "${AI_TOOLS_ASSETS__ENTRIES[@]}"; do
        [[ "${AI_TOOLS_ASSETS__STATE[${entry}]}" == view-occupied && "${_AI_TOOLS_ASSETS__KIND[${entry}]}" == "$1" \
            && "${_AI_TOOLS_ASSETS__VIEW_NAME[${entry}]}" == "$2" ]] && return 0
    done
    return 1
}

# _ai_tools_assets__is_entry_untrusted <agent-dir> <entry> : succeed when a real entry in an agent's directory is not
# root-owned along its path from the agent's config directory down: the kind directory, the entry, and everything
# under it.
_ai_tools_assets__is_entry_untrusted() {
    local agent_dir="$1" path="$2" owner offender
    owner="$(stat -c %u -- "${agent_dir}" 2>/dev/null)" || return 0
    [[ "${owner}" == 0 ]] || return 0
    offender="$(find -P "${path}" ! -uid 0 -print -quit 2>/dev/null)" || return 0
    [[ -n "${offender}" ]]
}

# _ai_tools_assets__plan_agent <agent> <kind> <agent-dir> : the per-agent changes for an enabled agent's directory: each
# name of the view as the apply leaves it is linked where absent and repointed where a link into the view names another
# target; a link elsewhere and a real entry are kept and reported -- agent-occupied at an enabled asset's name, `kept`
# at any other -- a real entry not root-owned along its path additionally agent-entry-untrusted; a managed copy
# byte-identical to the seeded one is converted to a link; a link into the view whose name the view no longer holds is
# unlinked. A directory that is not a destination, or whose links could not be listed, is reported and not planned.
_ai_tools_assets__plan_agent() {
    local agent="$1" kind="$2" agent_dir="$3" view="${AI_TOOLS_ASSETS_HOME}/$2" name destination_path target item is_resolver_entry
    local -a links=()
    _ai_tools_assets__is_agent_plannable "${agent}" "${kind}" "${agent_dir}" || return 0
    _ai_tools_assets__list_agent_links "${agent}" "${kind}" "${agent_dir}" || return 0
    links=( "${_AI_TOOLS_ASSETS__LISTING[@]}" )
    for name in "${!_AI_TOOLS_ASSETS__VIEW_AFTER[@]}"; do
        destination_path="${agent_dir}/${name}"
        is_resolver_entry=0; item="${kind}/${name}"
        if [[ -n "${_AI_TOOLS_ASSETS__DESIRED_ID[${kind}|${name}]+x}" ]]; then
            is_resolver_entry=1; item="${_AI_TOOLS_ASSETS__DESIRED_ID[${kind}|${name}]}"
        fi
        if [[ -L "${destination_path}" ]]; then
            target="$(readlink -- "${destination_path}" 2>/dev/null || true)"
            [[ "${target}" == "${view}/${name}" ]] && continue
            if [[ "${target}" == "${view}/"* ]]; then
                _ai_tools_assets__record_action link "${destination_path}" "${view}/${name}" agent "${item}" "${agent}" "repointed at ${view}/${name}"
                continue
            fi
            _ai_tools_assets__record_row "$( (( is_resolver_entry )) && printf attention || printf info )" \
                "$( (( is_resolver_entry )) && printf agent-occupied || printf kept )" agent "${destination_path}" "${item}" "${agent}" \
                "the host's link to $(_ai_tools_assets__sanitize_for_display "${target}"), left as it is"
        elif [[ -e "${destination_path}" ]]; then
            if (( ! is_resolver_entry )) && [[ "${_AI_TOOLS_ASSETS__VIEW_AFTER[${name}]}" == seeded ]] \
                    && ai_tools_managed_assets__is_stale_copy "${view}/${name}" "${destination_path}"; then
                _ai_tools_assets__record_action convert "${destination_path}" "${view}/${name}" agent "${item}" "${agent}" "an identical managed copy, replaced by a link"
                continue
            fi
            _ai_tools_assets__record_row "$( (( is_resolver_entry )) && printf attention || printf info )" \
                "$( (( is_resolver_entry )) && printf agent-occupied || printf kept )" agent "${destination_path}" "${item}" "${agent}" \
                "a real entry here wins over the view's, left as it is"
            _ai_tools_assets__is_entry_untrusted "${agent_dir}" "${destination_path}" \
                && _ai_tools_assets__record_row attention agent-entry-untrusted agent "${destination_path}" "${item}" "${agent}" \
                    "not root-owned along its path, so a session can rewrite what every later session loads here"
        else
            _ai_tools_assets__record_action link "${destination_path}" "${view}/${name}" agent "${item}" "${agent}" "linked to ${view}/${name}"
        fi
    done
    _ai_tools_assets__plan_stale_links "${agent}" "${kind}" "${agent_dir}" all "${links[@]}"
}

# _ai_tools_assets__is_agent_plannable <agent> <kind> <agent-dir> : succeed when the plan may act in an agent's kind
# directory: its config directory exists and _ai_tools_assets__is_destination_trusted accepts the path. Returns 1
# without a row for a config directory that does not exist (an agent not provisioned
# yet), and after an agent-dir-untrusted row for a path that fails.
_ai_tools_assets__is_agent_plannable() {
    local agent="$1" kind="$2" agent_dir="$3" failed
    [[ -e "${agent_dir%/*}" || -L "${agent_dir%/*}" ]] || return 1
    failed="$(_ai_tools_assets__is_destination_trusted agent "${agent_dir}")" && return 0
    _ai_tools_assets__record_dir_row agent-dir-untrusted "${failed}" "${kind}" "${agent}" \
        "$(_ai_tools_assets__read_dir_reason "${failed}"), so no link of this kind is placed or removed for ${agent}; the directory is not repaired, since a repair would keep what was placed inside it"
    return 1
}

# _ai_tools_assets__list_agent_links <agent> <kind> <agent-dir> : the symbolic links in <agent-dir>
# into _AI_TOOLS_ASSETS__LISTING, empty for a directory that does not exist yet. Returns 1, after an `error` row naming
# the directory, when the listing fails.
_ai_tools_assets__list_agent_links() {
    declare -ga _AI_TOOLS_ASSETS__LISTING=()
    [[ -d "$3" && ! -L "$3" ]] || return 0
    _ai_tools_assets__enumerate "$3" -type l && return 0
    _ai_tools_assets__record_row unreadable error directory "$3" "$2" "$1" \
        "the directory could not be listed (${_AI_TOOLS_ASSETS__LISTING_ERROR}), so it is not planned: a stale link there stays in place"
    return 1
}

# _ai_tools_assets__plan_stale_links <agent> <kind> <agent-dir> <all|resolver> <link>... : unlink each of the links
# listed in <agent-dir> that points into the view at a name the view as the apply leaves it does not hold --
# and, for `resolver` (an installed agent that is not enabled), at a resolver link as well. A link to a seeded copy,
# and every other entry, is left as it is.
_ai_tools_assets__plan_stale_links() {
    local agent="$1" kind="$2" agent_dir="$3" which="$4" view="${AI_TOOLS_ASSETS_HOME}/$2" name target after
    shift 4
    for name in "$@"; do
        target="$(readlink -- "${agent_dir}/${name}" 2>/dev/null || true)"
        [[ "${target}" == "${view}/"* ]] || continue
        after="${_AI_TOOLS_ASSETS__VIEW_AFTER[${target#"${view}/"}]:-}"
        if [[ -z "${after}" || ( "${which}" == resolver && "${after}" == resolver ) ]]; then
            _ai_tools_assets__record_action unlink "${agent_dir}/${name}" "" agent "${kind}/${target#"${view}/"}" "${agent}" \
                "$([[ -z "${after}" ]] && printf 'the view does not hold a linkable entry at its name' || printf 'the agent is not enabled')"
        fi
    done
}

# _ai_tools_assets__plan_without_receivers : the plan while the receiving agents are unknown. The enable list is read
# as empty: every entry is receivers-unknown and no set is read, so the plan unlinks every resolver link in the view --
# the direction an untrusted operator.conf takes, and the one that leaves an agent reading the whole view without
# an asset no capability check covered -- and does not plan any agent's directory. One `unreadable` row names the reader
# and why.
_ai_tools_assets__plan_without_receivers() {
    local entry kind view_name status
    _AI_TOOLS_ASSETS__AGENTS=(); _AI_TOOLS_ASSETS__IDLE_AGENTS=()
    for entry in "${AI_TOOLS_ASSETS__ENTRIES[@]}"; do
        status=0
        ai_tools_assets__parse_id "${entry}" || status=$?
        if (( status == 0 )); then
            view_name="$(_ai_tools_assets__get_entry_paths "${_AI_TOOLS_ASSETS__ID_KIND}" "${_AI_TOOLS_ASSETS__ID_NAME}")"
            _AI_TOOLS_ASSETS__KIND["${entry}"]="${_AI_TOOLS_ASSETS__ID_KIND}"
            _AI_TOOLS_ASSETS__VIEW_NAME["${entry}"]="${view_name#*$'\t'}"
        fi
        AI_TOOLS_ASSETS__STATE["${entry}"]=receivers-unknown
        AI_TOOLS_ASSETS__DETAIL["${entry}"]="not linked while the receiving agents are unknown"
    done
    _ai_tools_assets__record_row unreadable receivers-unknown directory "${AI_TOOLS_AGENTS_DIR:-/usr/local/lib/ai-tools/agents.d}" "" "" \
        "${_AI_TOOLS_ASSETS__RECEIVERS_DETAIL}; the enable list reads as empty, and no agent's directory is planned"
    while IFS= read -r kind; do
        _ai_tools_assets__plan_view "${kind}" || true
    done < <(_ai_tools_assets__list_kinds)
}

# _ai_tools_assets__check_agent_root <agent> <kind> <path> : the row for the path outside <agent>'s config directory
# where its manifest says it reads <kind>'s whole view: none for a symlink to the view; agent-root-foreign at attention
# for a real directory, another file or a link elsewhere; agent-root-absent at info; and `error` at unreadable
# for a value that is not an absolute path of portable names, which is not read. The plan does not write the path.
# The agent's package places the link when it is installed (ai_tools_managed_assets__link_shared_root,
# managed-assets.lib.sh) and keeps what a host holds there, so a reconcile reaches that agent through the link alone.
_ai_tools_assets__check_agent_root() {
    local agent="$1" kind="$2" path="$3" view="${AI_TOOLS_ASSETS_HOME}/$2" rest="${3#/}" found subject_type=file valid=1
    [[ "${path}" == /?* && "${path}" != */ ]] || valid=0
    while (( valid )); do
        ai_tools_conf__is_portable_name_valid "${rest%%/*}" || valid=0
        [[ "${rest}" == */* ]] || break
        rest="${rest#*/}"
    done
    if (( ! valid )); then
        _ai_tools_assets__record_row unreadable error file "${AI_TOOLS_AGENTS_DIR:-/usr/local/lib/ai-tools/agents.d}/${agent}.conf" "${kind}" "${agent}" \
            "$(_ai_tools_assets__get_kind_field "${kind}" root_field)=$(_ai_tools_assets__sanitize_for_display "${path}") is not an absolute path of portable names, so where ${agent} reads the ${kind} view is not read"
        return 0
    fi
    if [[ -L "${path}" ]]; then
        found="$(readlink -- "${path}" 2>/dev/null || true)"
        [[ "${found}" == "${view}" ]] && return 0
        found="a link to $(_ai_tools_assets__sanitize_for_display "${found}")"
    elif [[ -d "${path}" ]]; then
        found="a real directory"; subject_type=directory
    elif [[ -e "${path}" ]]; then
        found="a file that is not a directory"
    else
        _ai_tools_assets__record_row info agent-root-absent directory "${path}" "${kind}" "${agent}" \
            "absent; the ${agent} agent's package links it to ${view} when it is installed"
        return 0
    fi
    _ai_tools_assets__record_row attention agent-root-foreign "${subject_type}" "${path}" "${kind}" "${agent}" \
        "${found} where ${agent} reads the whole ${kind} view, which the reconcile does not write, so an enable, a disable or a set upgrade does not reach ${agent} through it; move it aside and reinstall the ${agent} agent's package, which links it to ${view}"
}

# ai_tools_assets__plan : read every input and compute the view transaction's changes, without writing. Safe to run
# without the lock, which `status` does: it reads.
ai_tools_assets__plan() {
    local entry kind agent
    _ai_tools_assets__reset_plan
    _ai_tools_assets__read_enable_list
    _ai_tools_assets__read_roots
    _ai_tools_assets__read_receivers
    if [[ "${_AI_TOOLS_ASSETS__RECEIVERS_STATE}" != ok ]]; then
        _ai_tools_assets__plan_without_receivers
        return 0
    fi
    for entry in "${AI_TOOLS_ASSETS__ENTRIES[@]}"; do
        _ai_tools_assets__resolve_entry "${entry}"
    done
    _ai_tools_assets__mark_name_conflicts
    while IFS= read -r kind; do
        _ai_tools_assets__plan_view "${kind}" || continue
        for agent in "${_AI_TOOLS_ASSETS__AGENTS[@]}"; do
            [[ -n "${_AI_TOOLS_ASSETS__AGENT_DIR[${agent}|${kind}]+x}" ]] || continue
            _ai_tools_assets__plan_agent "${agent}" "${kind}" "${_AI_TOOLS_ASSETS__AGENT_DIR[${agent}|${kind}]}"
        done
        for agent in "${_AI_TOOLS_ASSETS__IDLE_AGENTS[@]}"; do
            [[ -n "${_AI_TOOLS_ASSETS__IDLE_DIR[${agent}|${kind}]+x}" ]] || continue
            _ai_tools_assets__is_agent_plannable "${agent}" "${kind}" "${_AI_TOOLS_ASSETS__IDLE_DIR[${agent}|${kind}]}" || continue
            _ai_tools_assets__list_agent_links "${agent}" "${kind}" "${_AI_TOOLS_ASSETS__IDLE_DIR[${agent}|${kind}]}" || continue
            _ai_tools_assets__plan_stale_links "${agent}" "${kind}" "${_AI_TOOLS_ASSETS__IDLE_DIR[${agent}|${kind}]}" resolver \
                "${_AI_TOOLS_ASSETS__LISTING[@]}"
        done
    done < <(_ai_tools_assets__list_kinds)
    while IFS= read -r kind; do
        for agent in "${_AI_TOOLS_ASSETS__AGENTS[@]}"; do
            [[ -n "${_AI_TOOLS_ASSETS__AGENT_ROOT[${agent}|${kind}]+x}" ]] || continue
            _ai_tools_assets__check_agent_root "${agent}" "${kind}" "${_AI_TOOLS_ASSETS__AGENT_ROOT[${agent}|${kind}]}"
        done
    done < <(_ai_tools_assets__list_kinds)
    return 0
}

# ── The apply and the report ─────────────────────────────────────────────────────────────────────────────────────────

# _ai_tools_assets__place_link <path> <target> <group> : point <path> at <target> through one rename(2): the link is
# made at `.<name>.ai-tools-assets.tmp` beside it, owned root:<group>, and renamed over the name, so a reader listing
# the directory sees the old target or the new one and never a missing name. An entry already at the temporary name is
# removed only when it is a link this library leaves (_ai_tools_assets__is_own_leftover); any other occupant -- a file,
# a directory, a link elsewhere -- is kept and the placement refused, since the directory's own rule keeps an entry
# the library did not place. `ln -s` does not follow or truncate an existing name, so an occupant that arrives
# after the check fails the placement. Returns 1, with the reason in _AI_TOOLS_ASSETS__PLACE_ERROR and the temporary
# name removed where it is the link this call made, when a step fails.
_ai_tools_assets__place_link() {
    local path="$1" target="$2" group="$3" temporary
    temporary="${path%/*}/.${path##*/}.ai-tools-assets.tmp"
    _AI_TOOLS_ASSETS__PLACE_ERROR=""
    if [[ -e "${temporary}" || -L "${temporary}" ]]; then
        if ! _ai_tools_assets__is_own_leftover "${temporary}"; then
            _AI_TOOLS_ASSETS__PLACE_ERROR="${temporary} holds $(_ai_tools_assets__read_occupant "${temporary}"), which this command did not leave; left as it is"
            return 1
        fi
        rm -f -- "${temporary}" 2>/dev/null
    fi
    if ln -s -- "${target}" "${temporary}" 2>/dev/null && chown -h "root:${group}" -- "${temporary}" 2>/dev/null \
            && mv -Tf -- "${temporary}" "${path}" 2>/dev/null; then
        return 0
    fi
    _ai_tools_assets__is_own_leftover "${temporary}" && rm -f -- "${temporary}" 2>/dev/null
    _AI_TOOLS_ASSETS__PLACE_ERROR="a step of the placement failed"
    return 1
}

# _ai_tools_assets__is_own_leftover <path> : succeed when <path> is a symbolic link this library leaves at a temporary
# name when a run stops between its create and its rename: a link into one of the roots (a view link) or into a view
# directory (an agent's link).
_ai_tools_assets__is_own_leftover() {
    local target kind
    [[ -L "$1" ]] || return 1
    _ai_tools_assets__is_resolver_link "$1" && return 0
    target="$(readlink -- "$1" 2>/dev/null)" || return 1
    for kind in $(_ai_tools_assets__list_kinds); do
        [[ "${target}" == "${AI_TOOLS_ASSETS_HOME}/${kind}/"* ]] && return 0
    done
    return 1
}

# _ai_tools_assets__read_occupant <path> : what stands at <path>, for a detail: a link and its target, a directory,
# a file with more than one link, or a file.
_ai_tools_assets__read_occupant() {
    local links
    links="$(stat -c %h -- "$1" 2>/dev/null)" || links=1
    if [[ -L "$1" ]]; then
        printf 'a link to %s' "$(_ai_tools_assets__sanitize_for_display "$(readlink -- "$1" 2>/dev/null)")"
    elif [[ -d "$1" ]]; then
        printf 'a directory'
    elif [[ "${links}" =~ ^[0-9]+$ ]] && (( links > 1 )); then
        printf 'a file with %s links' "${links}"
    else
        printf 'a file'
    fi
}

# _ai_tools_assets__apply <group> : take every change the plan computed, in order -- the view first, then the agents'
# links -- each reported as a row: `linked` or `unlinked` at info, or `write-failed` at attention with the entry it was
# for left unlinked. A view link that failed is not linked into an agent's directory. Before its first write
# in a directory the apply holds it to _ai_tools_assets__is_destination_trusted, creating an absent view or agent kind
# directory root:<group> 0750 first (_ai_tools_assets__prepare_dir); a directory that fails does not take a write,
# and an enabled entry whose view link it held reads view-dir-untrusted. restorecon runs over every link placed. Sets
# _AI_TOOLS_ASSETS__WRITE_FAILED to 1 when a change did not take, and _AI_TOOLS_ASSETS__UNLINK_FAILED to 1
# when a removal did not, so the report does not claim it.
_ai_tools_assets__apply() {
    local group="$1" index op path target stype item agent detail directory kind
    local -a placed=()
    local -A failed_view=() untrusted_view=() directory_state=()
    _AI_TOOLS_ASSETS__WRITE_FAILED=0; _AI_TOOLS_ASSETS__UNLINK_FAILED=0
    for kind in $(_ai_tools_assets__list_kinds); do
        _ai_tools_assets__can_apply_in_dir view "${AI_TOOLS_ASSETS_HOME}/${kind}" "${kind}" "" "${group}" 1 || true
    done
    for (( index = 0; index < ${#_AI_TOOLS_ASSETS__ACTION_OPERATION[@]}; index++ )); do
        op="${_AI_TOOLS_ASSETS__ACTION_OPERATION[index]}"; path="${_AI_TOOLS_ASSETS__ACTION_PATH[index]}"; target="${_AI_TOOLS_ASSETS__ACTION_TARGET[index]}"
        stype="${_AI_TOOLS_ASSETS__ACTION_SUBJECT_TYPE[index]}"; item="${_AI_TOOLS_ASSETS__ACTION_ITEM[index]}"; agent="${_AI_TOOLS_ASSETS__ACTION_AGENT[index]}"
        detail="${_AI_TOOLS_ASSETS__ACTION_DETAIL[index]}"
        if [[ "${stype}" == agent && "${op}" != unlink && -n "${failed_view[${target}]+x}" ]]; then
            continue
        fi
        directory="${path%/*}"; kind="${item%/*}"; kind="${kind##*/}"
        if ! _ai_tools_assets__can_apply_in_dir "$([[ "${stype}" == file ]] && printf view || printf agent)" "${directory}" \
                "${kind}" "${agent}" "${group}" "$([[ "${op}" == unlink ]] && printf 0 || printf 1)"; then
            if [[ "${stype}" == file && "${op}" != unlink ]]; then
                failed_view["${path}"]=1
                untrusted_view["${path}"]=1
            fi
            continue
        fi
        case "${op}" in
            link|convert)
                if [[ "${op}" == convert ]] && ! rm -rf -- "${path}" 2>/dev/null; then
                    _ai_tools_assets__record_failure "${stype}" "${path}" "${item}" "${agent}" "the managed copy could not be removed"
                    continue
                fi
                if _ai_tools_assets__place_link "${path}" "${target}" "${group}"; then
                    placed+=( "${path}" )
                    _ai_tools_assets__record_row info linked "${stype}" "${path}" "${item}" "${agent}" "${detail}"
                else
                    [[ "${stype}" == file ]] && failed_view["${path}"]=1
                    _ai_tools_assets__record_failure "${stype}" "${path}" "${item}" "${agent}" "the link to ${target} could not be placed: ${_AI_TOOLS_ASSETS__PLACE_ERROR}"
                fi ;;
            unlink)
                if [[ -L "${path}" ]] && rm -f -- "${path}" 2>/dev/null; then
                    _ai_tools_assets__record_row info unlinked "${stype}" "${path}" "${item}" "${agent}" "${detail}"
                elif [[ -e "${path}" || -L "${path}" ]]; then
                    _AI_TOOLS_ASSETS__UNLINK_FAILED=1
                    _ai_tools_assets__record_failure "${stype}" "${path}" "${item}" "${agent}" \
                        "the link could not be removed, so the asset stays reachable through it"
                fi ;;
        esac
    done
    if (( ${#placed[@]} > 0 )); then
        restorecon -- "${placed[@]}" >/dev/null 2>&1 || true
    fi
    for agent in "${_AI_TOOLS_ASSETS__AGENTS[@]}"; do
        for kind in $(_ai_tools_assets__list_kinds); do
            directory="${_AI_TOOLS_ASSETS__AGENT_DIR[${agent}|${kind}]:-}"
            [[ -n "${directory}" ]] || continue
            _ai_tools_assets__can_apply_in_dir agent "${directory}" "${kind}" "${agent}" "${group}" 0 || continue
            ai_tools_managed_assets__link_asset_readme "${AI_TOOLS_ASSETS__README_ROOT}/${kind}/README.md" "${directory}" "${group}" \
                >/dev/null 2>&1 || true
        done
    done
    for (( index = 0; index < ${#AI_TOOLS_ASSETS__ENTRIES[@]}; index++ )); do
        item="${AI_TOOLS_ASSETS__ENTRIES[index]}"
        [[ "${AI_TOOLS_ASSETS__STATE[${item}]}" == linked ]] || continue
        path="${AI_TOOLS_ASSETS_HOME}/${_AI_TOOLS_ASSETS__KIND[${item}]}/${_AI_TOOLS_ASSETS__VIEW_NAME[${item}]}"
        if [[ -n "${untrusted_view[${path}]+x}" ]]; then
            AI_TOOLS_ASSETS__STATE["${item}"]="view-dir-untrusted"
            AI_TOOLS_ASSETS__DETAIL["${item}"]="${path%/*} failed its check before the link was placed; its row says why"
        elif [[ -n "${failed_view[${path}]+x}" ]]; then
            AI_TOOLS_ASSETS__STATE["${item}"]="write-failed"
            AI_TOOLS_ASSETS__DETAIL["${item}"]="the view link at ${path} could not be placed"
        fi
    done
}

# _ai_tools_assets__can_apply_in_dir <view|agent> <dir> <kind> <agent> <group> <create> : succeed when the apply may
# write in <dir>, deciding once per directory and run through _ai_tools_assets__prepare_dir; the verdict is kept
# in the caller's directory_state. A directory that fails is reported once (view-dir-untrusted, agent-dir-untrusted);
# an absent one left absent fails without a row.
_ai_tools_assets__can_apply_in_dir() {
    local which="$1" directory="$2" kind="$3" agent="$4" group="$5" create="$6" failed status=0
    case "${directory_state[${directory}]:-}" in
        ok) return 0 ;;
        untrusted) return 1 ;;
    esac
    failed="$(_ai_tools_assets__prepare_dir "${which}" "${directory}" "${group}" "${create}")" || status=$?
    case "${status}" in
        0) directory_state["${directory}"]=ok; return 0 ;;
        2) return 1 ;;
    esac
    directory_state["${directory}"]=untrusted
    _ai_tools_assets__record_dir_row "${which}-dir-untrusted" "${failed:-${directory}}" "${kind}" "${agent}" \
        "$(_ai_tools_assets__read_dir_reason "${failed:-${directory}}") when the apply reached it, so no link was placed or removed there; the directory is not repaired, since a repair would keep what was placed inside it"
    return 1
}

# _ai_tools_assets__record_failure <subject-type> <path> <item> <agent> <detail> : report a change that did not take.
_ai_tools_assets__record_failure() {
    _AI_TOOLS_ASSETS__WRITE_FAILED=1
    _ai_tools_assets__record_row attention write-failed "$1" "$2" "$3" "$4" "$5"
}

# _ai_tools_assets__get_entry_subject <entry> : the view path an entry's row is about, or operator.conf for an entry
# whose kind has no row.
_ai_tools_assets__get_entry_subject() {
    if [[ -n "${_AI_TOOLS_ASSETS__KIND[$1]+x}" ]]; then
        printf '%s/%s/%s' "${AI_TOOLS_ASSETS_HOME}" "${_AI_TOOLS_ASSETS__KIND[$1]}" "${_AI_TOOLS_ASSETS__VIEW_NAME[$1]}"
    else
        printf '%s' "${AI_TOOLS_OPERATOR_CONF}"
    fi
}

# _ai_tools_assets__format_entry_detail <entry> : the detail an entry's row and status line carry, the capability
# a linked asset declares appended.
_ai_tools_assets__format_entry_detail() {
    local detail="${AI_TOOLS_ASSETS__DETAIL[$1]:-}"
    [[ -n "${AI_TOOLS_ASSETS__CAPS[$1]:-}" ]] && detail+="; requires ${AI_TOOLS_ASSETS__CAPS[$1]}"
    printf '%s' "${detail}"
}

# _ai_tools_assets__write_row <code> <severity> <finding> <subject-type> <subject> <item> <agent> <detail> : one record
# of the stream, the item framed from <item> and, for a per-agent row, <agent>. An attention or unreadable row is also
# logged under its code. An item that does not frame is written as an empty item rather than dropped.
_ai_tools_assets__write_row() {
    local code="$1" severity="$2" finding="$3" stype="$4" subject="$5" item="$6" agent="$7" detail="$8" framed=""
    if [[ -n "${agent}" ]]; then
        ai_tools_records_tsv__frame_item_components framed "${item}" "${agent}" || framed=""
    elif [[ -n "${item}" ]]; then
        ai_tools_records_tsv__frame_item_components framed "${item}" || framed=""
    fi
    ai_tools_records_tsv__write_record "" "${code}" "${severity}" "${finding}" "${stype}" "" "${framed}" "${subject}" \
        "${detail}" || true
    case "${severity}" in
        attention)  ai_tools_log__coded warning "${code}" "${finding} ${item}${agent:+ (${agent})} ${subject}: ${detail}" ;;
        unreadable) ai_tools_log__coded error "${code}" "${finding} ${item}${agent:+ (${agent})} ${subject}: ${detail}" ;;
    esac
}

# _ai_tools_assets__report <code> : the record stream for a plan, and the apply when one ran: the enable-list row
# where the list could not be read, one row per entry in list order (`linked` at ok, `error` at unreadable, any other
# token at attention), then each row the plan and the apply recorded.
_ai_tools_assets__report() {
    local code="$1" entry index detail
    case "${AI_TOOLS_ASSETS__LIST_STATE}" in
        untrusted)
            if (( ${_AI_TOOLS_ASSETS__UNLINK_FAILED:-0} )); then
                detail="${AI_TOOLS_ASSETS__LIST_DETAIL}; a resolver link that could not be removed stays, each named in a write-failed row"
            else
                detail="${AI_TOOLS_ASSETS__LIST_DETAIL}; every resolver link is removed"
            fi
            _ai_tools_assets__write_row "${code}" attention enable-list-untrusted file "${AI_TOOLS_OPERATOR_CONF}" "" "" \
                "${detail}" ;;
        invalid)
            _ai_tools_assets__write_row "${code}" attention id-malformed file "${AI_TOOLS_OPERATOR_CONF}" AI_TOOLS_ASSETS "" \
                "${AI_TOOLS_ASSETS__LIST_DETAIL}" ;;
    esac
    for entry in "${AI_TOOLS_ASSETS__ENTRIES[@]}"; do
        if [[ "${AI_TOOLS_ASSETS__STATE[${entry}]}" == linked ]]; then
            _ai_tools_assets__write_row "${code}" ok linked file "$(_ai_tools_assets__get_entry_subject "${entry}")" "${entry}" "" \
                "$(_ai_tools_assets__format_entry_detail "${entry}")"
        else
            _ai_tools_assets__write_row "${code}" "$([[ "${AI_TOOLS_ASSETS__STATE[${entry}]}" == error ]] && printf unreadable || printf attention)" \
                "${AI_TOOLS_ASSETS__STATE[${entry}]}" file "$(_ai_tools_assets__get_entry_subject "${entry}")" "${entry}" "" \
                "$(_ai_tools_assets__format_entry_detail "${entry}")"
        fi
    done
    for (( index = 0; index < ${#AI_TOOLS_ASSETS__ROW_SEVERITY[@]}; index++ )); do
        _ai_tools_assets__write_row "${code}" "${AI_TOOLS_ASSETS__ROW_SEVERITY[index]}" "${AI_TOOLS_ASSETS__ROW_FINDING[index]}" \
            "${_AI_TOOLS_ASSETS__ROW_SUBJECT_TYPE[index]}" "${AI_TOOLS_ASSETS__ROW_SUBJECT[index]}" "${_AI_TOOLS_ASSETS__ROW_ITEM[index]}" \
            "${_AI_TOOLS_ASSETS__ROW_AGENT[index]}" "${AI_TOOLS_ASSETS__ROW_DETAIL[index]}"
    done
}

# ── The transaction ──────────────────────────────────────────────────────────────────────────────────────────────────

# ai_tools_assets__reconcile <group> : the view transaction. Takes the assets lock (ai_tools_managed_assets__lock,
# managed-assets.lib.sh) before any input is read -- a level of it where its caller already holds it -- and holds it
# to the end, plans, applies, and writes one record per enable-list entry and per row found, under the reconcile code.
# Returns 0; 1 when a change did not take (each one reported) or the lock could not be taken (no input read and no link
# changed, MSG-M8T9). The records' severities fold into ai_tools_records_base__get_exit_status for the caller.
ai_tools_assets__reconcile() {
    local group="${1:?}" status=0
    ai_tools_managed_assets__lock || return 1
    ai_tools_assets__plan
    _ai_tools_assets__apply "${group}"
    _ai_tools_assets__reconcile_report MSG-Z3P6 "assets reconcile: an enable-list entry's state, or a link the view transaction placed, removed or found"
    (( _AI_TOOLS_ASSETS__WRITE_FAILED == 0 )) || status=1
    ai_tools_managed_assets__unlock
    return "${status}"
}

# _ai_tools_assets__reconcile_report <code> <situation> : the report a reconcile writes, under the code naming its
# situation.
_ai_tools_assets__reconcile_report() {
    _ai_tools_assets__report "$1"
}

# ai_tools_assets__build_enable_snapshot <set> : resolve every asset of <set> as `enable --set` snapshots it,
# from the first root holding <set>/set.conf. Publishes AI_TOOLS_ASSETS__SNAPSHOT_STATE (the set's token, `ok` when it
# may be enabled), AI_TOOLS_ASSETS__SNAPSHOT_DETAIL, and AI_TOOLS_ASSETS__SNAPSHOT_IDS
# and AI_TOOLS_ASSETS__SNAPSHOT_TOKENS: each asset's identifier and its state, `ok` or the reason. A set that is absent,
# unbound, untrusted, invalid at set scope, tampered, unverified or requiring an unknown capability is refused; the host
# conditions -- requires-base, an unsupported capability, an integration that is off -- are not, and reconcile reports
# them.
ai_tools_assets__build_enable_snapshot() {
    local set="$1" index set_directory root key asset state
    declare -ga AI_TOOLS_ASSETS__SNAPSHOT_IDS=() AI_TOOLS_ASSETS__SNAPSHOT_TOKENS=()
    AI_TOOLS_ASSETS__SNAPSHOT_STATE="set-absent"; AI_TOOLS_ASSETS__SNAPSHOT_DETAIL="no root holds ${set}/set.conf"
    _ai_tools_assets__reset_plan
    _ai_tools_assets__read_roots
    _ai_tools_assets__read_receivers
    if ! ai_tools_assets__is_binding_present "${set}"; then
        AI_TOOLS_ASSETS__SNAPSHOT_STATE="set-unbound"
        AI_TOOLS_ASSETS__SNAPSHOT_DETAIL="no shipped binding names ${set} under ${AI_TOOLS_ASSETS_BINDINGS_DIR}"
        return 0
    fi
    for (( index = 0; index < ${#_AI_TOOLS_ASSETS__ROOT_LIST[@]}; index++ )); do
        root="${_AI_TOOLS_ASSETS__ROOT_LIST[index]}"
        set_directory="$(_ai_tools_assets__copy_dir "${index}" "${set}")"
        [[ -n "${set_directory}" && "${_AI_TOOLS_ASSETS__ROOT_STATE[${root}]}" != absent ]] || continue
        if [[ "${_AI_TOOLS_ASSETS__ROOT_STATE[${root}]}" == untrusted ]]; then
            [[ -e "${set_directory}" || -L "${set_directory}" ]] || continue
            AI_TOOLS_ASSETS__SNAPSHOT_STATE="path-untrusted"
            AI_TOOLS_ASSETS__SNAPSHOT_DETAIL="the root ${root} $(ai_tools_conf__read_untrusted_reason "${root}")"
            return 0
        fi
        [[ -e "${set_directory}/set.conf" || -L "${set_directory}/set.conf" ]] || continue
        _ai_tools_assets__evaluate_set "${set_directory}" "${set}"
        state="${_AI_TOOLS_ASSETS__SET_STATE[${set_directory}]}"
        case "${state}" in
            ok|requires-base|capability-unsupported|integration-off) ;;
            *)  AI_TOOLS_ASSETS__SNAPSHOT_STATE="${state}"; AI_TOOLS_ASSETS__SNAPSHOT_DETAIL="${_AI_TOOLS_ASSETS__SET_DETAIL[${set_directory}]}"
                return 0 ;;
        esac
        # A set refused on a requirement stopped before its assets were read; read them now for the asset-scope rules.
        [[ "${state}" == ok ]] || _ai_tools_assets__evaluate_assets "${set_directory}"
        # shellcheck disable=SC2034  # read by ai-tools-admin.sh
        AI_TOOLS_ASSETS__SNAPSHOT_STATE=ok
        # shellcheck disable=SC2034  # read by ai-tools-admin.sh
        AI_TOOLS_ASSETS__SNAPSHOT_DETAIL="from ${set_directory}"
        local -a passed=()
        IFS=' ' read -r -a passed <<< "${_AI_TOOLS_ASSETS__SET_ASSETS[${set_directory}]}"
        for asset in "${passed[@]}"; do
            key="${set_directory}|${asset}"
            AI_TOOLS_ASSETS__SNAPSHOT_IDS+=( "${set}/${asset%%|*}/${asset#*|}" )
            AI_TOOLS_ASSETS__SNAPSHOT_TOKENS+=( "${_AI_TOOLS_ASSETS__ASSET_STATE[${key}]:-asset-invalid}" )
        done
        return 0
    done
}

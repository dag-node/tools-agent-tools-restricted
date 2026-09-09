#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/man.sh
# Hermetic sync test between this project's man pages and what each documents: ai-tools(1)
# against the CLI's usage(), ai-tools-admin(8) against the admin helper's, ai-tools-providers(5)
# against the shipped manifests, allowed-projects(5) and secret-patterns(5) against the header
# each file is seeded with and the parser its examples must load in, and operator.conf(5)
# and custom-claude-endpoint.conf(5) against the keys their shipped templates mention. It closes
# by holding every config header this project writes to the fixed-width rule (72 columns, no line
# ending on a tie word). In the two command pairs the page and the help are not copies of each
# other -- usage() is orientation while the page is the reference -- so equality of their whole
# option sets is the wrong contract and is what made slimming the help impossible.
#
# ai-tools(1), four checks:
#   (1) the VERB sets match in both directions;
#   (2) every long option usage() names anywhere is documented in the page;
#   (3) every long option the page's OPTIONS section documents is one a CLI parser
#       accepts -- the direction that catches an option outliving its parser;
#   (4) the .TH version field is present -- @AI_TOOLS_VERSION@ in the repo source, a version
#       number on an RPM install, `dev` on a source install of an unstamped tree.
#
# ai-tools-admin(8), the same three relations over a surface spelled in bare words rather than
# long options (.claude/rules/cli-grammar.rule.md), so what is compared is the COMMAND PATH --
# `selinux groups enable`, three tokens -- rather than a single flag:
#   (1) the command sets match in both directions;
#   (2) every token of every documented command is one a dispatch `case` arm accepts, which is
#       what catches a page still naming a command after the dispatch renamed it. The admin
#       helper dispatches through nested `case` statements rather than one flat parser, so the
#       arms are collected across all of them and matched per token;
#   (3) the same .TH version field.
#
# Pure text comparison of the source files -- no root, no install dependency, and neither command
# is executed (the CLI's bootstrap gate fail-closes on an unprovisioned host and the admin helper
# refuses a non-root caller, so neither can be run for its help output here). Validates the repo
# sources directly, falling back to the installed pair outside a checkout (a page may be gzipped
# there).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# read_man <page>: the page text with troff's escaped hyphens (\-\-project\-claim) flattened, so
# every extraction below matches plain option and command spellings.
read_man() {
    case "$1" in
        *.gz) zcat "$1" ;;
        *)    cat  "$1" ;;
    esac | sed 's/\\-/-/g'
}

# usage_text <script>: the command's user-facing help, bounded to its heredoc
# (usage() { cat <<EOF ... EOF }). Both commands render their help from one.
usage_text() { sed -n '/^usage() {/,/^EOF$/p' "$1" 2>/dev/null; }

# man_section <page> <NAME>: the body of one .SH section, bounded by the next .SH.
man_section() { read_man "$1" | awk -v s=".SH $2" '$0==s{f=1;next} /^\.SH /{f=0} f'; }

# th_version <page> <NAME>: PASS when the .TH line still carries a version field. The contract is
# that the field is PRESENT, not that it looks like a release. Three values are all correct: the
# repo source carries the @AI_TOOLS_VERSION@ token, an RPM install carries a version number, and a
# source install of an unstamped tree carries `dev` -- which is exactly what `--version` reports
# there, and what ai_tools_msg_version passes through deliberately. Enumerating the shapes rejected
# `dev`, so the check failed or passed according to how the HOST was provisioned rather than
# according to anything about the page. It asserts what it always meant: the field is non-empty.
#
# The page is read into a here-string rather than piped into `grep -q`, and that is load-bearing
# under this file's `set -o pipefail`: `grep -q` exits the moment it matches, and the .TH line is
# line 5 of a 24 KB page, so the writer upstream is still mid-page and dies of SIGPIPE. pipefail
# then reports 141 for a pipeline whose grep succeeded, and the check fails at random -- about
# half the time here, near-always on the EL container runners. A here-string is fully written
# before grep starts, so there is no early reader to race. Do not "simplify" it back to a pipe.
th_version() {
    local page="$1" name="$2"
    if grep -qE "^\.TH ${name} [0-9] .*\"ai-tools [^\"[:space:]][^\"]*\"" <<<"$(read_man "${page}")"; then
        pass "${name} man page .TH carries the version token/substitution"
    else
        # Name the file: this check reads the repo source when there is one and the installed copy
        # otherwise, and which of the two it got is the first thing worth knowing on a failure.
        fail "${name} man page .TH lost its version field (read ${page})"
    fi
}

# ── ai-tools(1) ─────────────────────────────────────────────────────────────────
CLI="${ROOT}/src/usr/local/bin/ai-tools.sh"
MAN="${ROOT}/src/usr/local/share/man/man1/ai-tools.1"
[[ -r "${CLI}" ]] || CLI="/usr/local/bin/ai-tools"
if [[ ! -r "${MAN}" ]]; then
    MAN="/usr/local/share/man/man1/ai-tools.1"
    [[ -r "${MAN}" ]] || MAN="/usr/local/share/man/man1/ai-tools.1.gz"
fi
section "man page: ai-tools(1) in sync with the CLI help (unit)"

check_cli_page() {
    if [[ ! -r "${CLI}" || ! -r "${MAN}" ]]; then
        skip "ai-tools man sync" "CLI or man page not found in src/ or install paths"
        return 0
    fi
    if [[ -z "$(usage_text "${CLI}")" ]]; then
        fail "could not extract the usage() heredoc from ${CLI}"
        return 0
    fi

    # ── (1) The verb sets, both directions ──────────────────────────────────────────
    # usage() lists one verb per line, indented four spaces and starting with its long option
    # (the flag block below it is indented two, so it is excluded by that indent alone).
    local help_verbs man_verbs undocumented unlisted help_opts man_opts missing parsed_opts stale
    help_verbs="$(usage_text "${CLI}" | grep -E '^    --[a-z]' | grep -oE -- '--[a-z][a-z-]+' | sort -u)"
    # In the page a verb is the FIRST long option on the .B/.BR line opening each TOP-LEVEL .TP
    # entry under COMMANDS. Three things must not be read as verbs: the rest of that opening
    # line (the verb's own flags), the prose below it (which names other verbs), and the nested
    # .TP entries inside an .RS/.RE block, which are that verb's per-flag reference and are
    # where a per-verb option belongs -- under the verb it applies to, not in a flat list that
    # separates it from the only command it means anything for. Hence the depth counter.
    man_verbs="$(man_section "${MAN}" COMMANDS \
        | awk '/^\.RS/{d++; next} /^\.RE/{if (d>0) d--; next}
               /^\.TP/{if (d==0) want=1; next}
               want && /^\.(B|BR|BI) /{
                 if (match($0, /--[a-z][a-z-]+/)) print substr($0, RSTART, RLENGTH); want=0 }' \
        | sort -u)"

    if [[ -z "${help_verbs}" || -z "${man_verbs}" ]]; then
        fail "could not extract a verb set (help='${help_verbs//$'\n'/ }' man='${man_verbs//$'\n'/ }')"
    else
        undocumented="$(comm -23 <(printf '%s\n' "${help_verbs}") <(printf '%s\n' "${man_verbs}"))"
        if [[ -z "${undocumented}" ]]; then
            pass "every verb in the CLI help has a COMMANDS entry in ai-tools(1)"
        else
            fail "verb(s) in the help with no man COMMANDS entry: $(tr '\n' ' ' <<<"${undocumented}")"
        fi
        unlisted="$(comm -13 <(printf '%s\n' "${help_verbs}") <(printf '%s\n' "${man_verbs}"))"
        if [[ -z "${unlisted}" ]]; then
            pass "ai-tools(1) documents no verb the CLI help omits"
        else
            fail "verb(s) in man COMMANDS but not the help: $(tr '\n' ' ' <<<"${unlisted}")"
        fi
    fi

    # ── (2) Every option the help names is documented somewhere in the page ─────────
    # This is what keeps the cross-verb flag lines (-y/--yes, -n/--dry-run, --for) honest: the
    # help may name fewer options than the page, never more.
    help_opts="$(usage_text "${CLI}" | grep -oE -- '--[a-z][a-z-]+' | sort -u)"
    man_opts="$(read_man "${MAN}" | grep -oE -- '--[a-z][a-z-]+' | sort -u)"
    missing="$(comm -23 <(printf '%s\n' "${help_opts}") <(printf '%s\n' "${man_opts}"))"
    if [[ -z "${missing}" ]]; then
        pass "every option the CLI help names is documented in ai-tools(1)"
    else
        fail "option(s) in the CLI help but not the man page: $(tr '\n' ' ' <<<"${missing}")"
    fi

    # ── (3) Every documented option is one a parser accepts ─────────────────────────
    # The direction that replaces the old "the help must name it too", which is what made moving
    # an option out of the help fail as a stale man entry. What actually goes stale is an option
    # the page still documents after its parser stopped accepting it, so the page is checked
    # against the parsers instead. It covers every option the page names, wherever it names it --
    # the OPTIONS section, a verb's nested .RS block, or a verb line -- since all three document
    # something a caller is invited to type. A long option counts as accepted when it appears in
    # a case-arm position anywhere in the CLI: immediately followed by ')', '|', or '='.
    parsed_opts="$(grep -oE -- '--[a-z][a-z-]+[)|=]' "${CLI}" | sed 's/.$//' | sort -u)"
    if [[ -z "${parsed_opts}" || -z "${man_opts}" ]]; then
        fail "could not extract the parser or man option set"
    else
        stale="$(comm -23 <(printf '%s\n' "${man_opts}") <(printf '%s\n' "${parsed_opts}"))"
        if [[ -z "${stale}" ]]; then
            pass "every option ai-tools(1) documents is accepted by a CLI parser"
        else
            fail "ai-tools(1) documents option(s) no CLI parser accepts: $(tr '\n' ' ' <<<"${stale}")"
        fi
    fi

    # ── (4) The version slot the deploys substitute ─────────────────────────────────
    th_version "${MAN}" AI-TOOLS
}
check_cli_page

# ── ai-tools-admin(8) ───────────────────────────────────────────────────────────
ADMIN="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
ADMIN_MAN="${ROOT}/src/usr/local/share/man/man8/ai-tools-admin.8"
[[ -r "${ADMIN}" ]] || ADMIN="/usr/local/libexec/ai-tools/ai-tools-admin"
if [[ ! -r "${ADMIN_MAN}" ]]; then
    ADMIN_MAN="/usr/local/share/man/man8/ai-tools-admin.8"
    [[ -r "${ADMIN_MAN}" ]] || ADMIN_MAN="/usr/local/share/man/man8/ai-tools-admin.8.gz"
fi
section "man page: ai-tools-admin(8) in sync with the admin help (unit)"

check_admin_page() {
    if [[ ! -r "${ADMIN}" || ! -r "${ADMIN_MAN}" ]]; then
        skip "ai-tools-admin man sync" "helper or man page not found in src/ or install paths"
        return 0
    fi
    if [[ -z "$(usage_text "${ADMIN}")" ]]; then
        fail "could not extract the usage() heredoc from ${ADMIN}"
        return 0
    fi

    # ── (1) The command sets, both directions ───────────────────────────────────────
    # usage() lists one command per line, indented four spaces, as `<path><padding><description>`.
    # The path is everything before the first run of two or more spaces, minus any argument
    # placeholder -- `operators add [user]` is the command `operators add`. The option lines
    # (--help, --version) share that indent and are excluded by the leading letter, since a
    # command in this grammar is a bare word.
    local help_cmds man_cmds undocumented unlisted arms cmd token unknown=()
    help_cmds="$(usage_text "${ADMIN}" \
        | sed -n 's/^    \([a-z][^ ].*\)  \+[^ ].*/\1/p' \
        | sed -e 's/[[:space:]]*[[<].*$//' -e 's/[[:space:]]*$//' | sort -u)"
    # In the page a command is the .B line opening each TOP-LEVEL .TP entry under COMMANDS, up to
    # its first argument placeholder (`\fR[\fIuser\fR]`), which the same .B line carries so the
    # tag renders as one unit.
    man_cmds="$(man_section "${ADMIN_MAN}" COMMANDS \
        | awk '/^\.RS/{d++; next} /^\.RE/{if (d>0) d--; next}
               /^\.TP/{if (d==0) want=1; next}
               want && /^\.(B|BR|BI) /{ sub(/^\.(B|BR|BI) /, ""); sub(/\\f.*$/, "");
                 gsub(/"/, ""); sub(/[[:space:]]+$/, ""); if ($0 != "") print; want=0 }' \
        | sort -u)"

    if [[ -z "${help_cmds}" || -z "${man_cmds}" ]]; then
        fail "could not extract a command set (help='${help_cmds//$'\n'/, }' man='${man_cmds//$'\n'/, }')"
    else
        undocumented="$(comm -23 <(printf '%s\n' "${help_cmds}") <(printf '%s\n' "${man_cmds}"))"
        if [[ -z "${undocumented}" ]]; then
            pass "every command in the admin help has a COMMANDS entry in ai-tools-admin(8)"
        else
            fail "command(s) in the help with no man COMMANDS entry: $(tr '\n' '/' <<<"${undocumented}")"
        fi
        unlisted="$(comm -13 <(printf '%s\n' "${help_cmds}") <(printf '%s\n' "${man_cmds}"))"
        if [[ -z "${unlisted}" ]]; then
            pass "ai-tools-admin(8) documents no command the admin help omits"
        else
            fail "command(s) in man COMMANDS but not the help: $(tr '\n' '/' <<<"${unlisted}")"
        fi
    fi

    # ── (2) Every documented command is one the dispatch accepts ────────────────────
    # The direction with teeth, and the admin counterpart of the CLI's stale-option check: what
    # goes stale is a command the page still documents after the dispatch renamed it. The helper
    # splits its dispatch across nested `case` statements -- one per domain and collection -- so
    # a whole path never appears in a single arm. Each TOKEN of a documented path must therefore
    # be an arm somewhere in the helper, which catches the rename (`postupgrade` -> `post-upgrade`
    # leaves the old token matching no heading) without asserting where in the nesting it sits.
    arms="$(grep -oE '^[[:space:]]+[a-z][a-z0-9-]*\)' "${ADMIN}" | tr -d ' )' | sort -u)"
    if [[ -z "${arms}" || -z "${man_cmds}" ]]; then
        fail "could not extract the dispatch arms or the man command set"
    else
        while read -r cmd; do
            [[ -n "${cmd}" ]] || continue
            for token in ${cmd}; do
                grep -qx -- "${token}" <<<"${arms}" || unknown+=("${cmd} (${token})")
            done
        done <<<"${man_cmds}"
        if [[ "${#unknown[@]}" -eq 0 ]]; then
            pass "every command ai-tools-admin(8) documents is accepted by a dispatch arm"
        else
            fail "ai-tools-admin(8) documents command(s) the dispatch does not accept: ${unknown[*]}"
        fi
    fi

    # ── (3) The version slot the deploys substitute ─────────────────────────────────
    th_version "${ADMIN_MAN}" AI-TOOLS-ADMIN
}
check_admin_page

# ── ai-tools-providers(5) ───────────────────────────────────────────────────────
# The provider manifests carry a pointer to this page and no key documentation of their own, so
# the page is the only statement of what a key means. Two directions keep it honest: every key a
# shipped manifest sets is documented under KEYS, and every key documented there is one some
# shipped manifest sets -- a documented key no manifest uses is a stale entry or a typo, and a
# used key the page lacks is an operator reading a file the manual does not explain. Keys are
# read with the same parser the tooling uses (ai_tools_conf_keys), so a commented default counts
# the way it counts everywhere else.
PROVIDERS_MAN="${ROOT}/src/usr/local/share/man/man5/ai-tools-providers.5"
MANIFEST_DIRS=( "${ROOT}/src/usr/local/lib/ai-tools/agents.d" "${ROOT}/src/usr/local/lib/ai-tools/integrations.d" )
CONF_LIB="${ROOT}/src/usr/local/lib/ai-tools/conf.lib.sh"
if [[ ! -r "${PROVIDERS_MAN}" ]]; then
    PROVIDERS_MAN="/usr/local/share/man/man5/ai-tools-providers.5"
    [[ -r "${PROVIDERS_MAN}" ]] || PROVIDERS_MAN="/usr/local/share/man/man5/ai-tools-providers.5.gz"
    MANIFEST_DIRS=( /usr/local/lib/ai-tools/agents.d /usr/local/lib/ai-tools/integrations.d )
    CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"
fi
section "man page: ai-tools-providers(5) in sync with the shipped manifests (unit)"

check_providers_page() {
    if [[ ! -r "${PROVIDERS_MAN}" ]]; then
        skip "providers page" "ai-tools-providers.5 not found in the repo or installed"; return
    fi
    # shellcheck source=/dev/null
    if ! source "${CONF_LIB}" 2>/dev/null || ! declare -F ai_tools_conf_keys >/dev/null 2>&1; then
        skip "providers page key sync" "conf.lib.sh not loadable from ${CONF_LIB}"; return
    fi
    # Documented keys: the tag line after each .TP under KEYS, where the whole tag is one key
    # token. Bold words in the running prose (a command, a value) are not tags and are not keys.
    mapfile -t documented < <(man_section "${PROVIDERS_MAN}" KEYS \
        | awk 'prev==".TP"{print} {prev=$0}' \
        | grep -oE '^\.B[IR]? [a-z][a-z0-9_]*$' | awk '{print $2}' | sort -u)
    # Used keys: the union over every shipped manifest.
    local -a used=() keys=() dir manifest key
    for dir in "${MANIFEST_DIRS[@]}"; do
        for manifest in "${dir}"/*.conf; do
            [[ -e "${manifest}" ]] || continue
            ai_tools_conf_keys keys "${manifest}"
            used+=( "${keys[@]}" )
        done
    done
    mapfile -t used < <(printf '%s\n' "${used[@]}" | sort -u)
    (( ${#used[@]} > 0 )) || { skip "providers page key sync" "no shipped manifest found"; return; }

    local missing=0
    for key in "${used[@]}"; do
        if printf '%s\n' "${documented[@]}" | grep -qx "${key}"; then :
        else fail "manifest key '${key}' is set by a shipped manifest but not documented under KEYS"; missing=1; fi
    done
    (( missing )) || pass "every key a shipped manifest sets is documented under KEYS (${#used[@]} keys)"
    local stale=0
    for key in "${documented[@]}"; do
        if printf '%s\n' "${used[@]}" | grep -qx "${key}"; then :
        else fail "KEYS documents '${key}', which no shipped manifest sets"; stale=1; fi
    done
    (( stale )) || pass "every key documented under KEYS is set by a shipped manifest"

    th_version "${PROVIDERS_MAN}" AI-TOOLS-PROVIDERS
}
check_providers_page

# ── The seeded operator files: allowed-projects(5), secret-patterns(5) ──────────
# The header each *_seed function in conf.lib.sh prints is written into an operator's file once,
# at enrolment, and no upgrade rewrites it -- so the reference lives in the page,
# which the package replaces on every upgrade, and the header stays a pointer. check_seed_header holds
# that shape for both files: the header is short (the cap is what stops it regrowing into a second
# reference), it names its page, and it is comment-only, so a seeded file registers no entry.
# Each page then has its EXAMPLES read through the parser its file is read with, so an example
# the manual shows is one the file accepts, and its .TH version field checked.
readonly SEED_HEADER_MAX_LINES=15

# man5_path <name>: the repo page, or the installed page (possibly gzipped) outside a checkout.
man5_path() {
    local page="${ROOT}/src/usr/local/share/man/man5/$1.5"
    [[ -r "${page}" ]] || page="/usr/local/share/man/man5/$1.5"
    [[ -r "${page}" ]] || page="/usr/local/share/man/man5/$1.5.gz"
    printf '%s' "${page}"
}
# man_examples <page>: the lines inside every .EX/.EE block of <page>, with troff's no-op
# escape (\&) removed so a line the page had to protect from macro expansion reads as written.
man_examples() {
    read_man "$1" | awk '/^\.EX/{on=1;next} /^\.EE/{on=0} on' | sed 's/^\\&//'
}

# check_seed_header <seed-fn> <page-name>: the three shape checks on a seeded header.
check_seed_header() {
    local seed="$1" name="$2" header lines
    if ! declare -F "${seed}" >/dev/null 2>&1; then
        skip "${name} seed header" "${seed} not defined by ${CONF_LIB}"; return
    fi
    header="$("${seed}")"
    lines="$(grep -c . <<< "${header}")"
    if (( lines <= SEED_HEADER_MAX_LINES )); then
        pass "the seeded ${name} header is a pointer (${lines} lines, cap ${SEED_HEADER_MAX_LINES})"
    else
        fail "the seeded ${name} header has grown to ${lines} lines (cap ${SEED_HEADER_MAX_LINES}): a reference belongs in ${name}(5)"
    fi
    if grep -q "man 5 ${name}" <<< "${header}"; then
        pass "the seeded ${name} header names its page (man 5 ${name})"
    else
        fail "the seeded ${name} header does not name 'man 5 ${name}'"
    fi
    if grep -qvE '^(#|$)' <<< "${header}"; then
        fail "the seeded ${name} header carries a line that is not a comment -- it would register an entry"
    else
        pass "the seeded ${name} header registers no entry"
    fi
}

ALLOWLIST_MAN="$(man5_path allowed-projects)"
section "man page: allowed-projects(5) and the seeded allowlist header (unit)"
check_allowlist_page() {
    if [[ ! -r "${ALLOWLIST_MAN}" ]]; then
        skip "allowed-projects page" "allowed-projects.5 not found in the repo or installed"; return
    fi
    # shellcheck source=/dev/null
    if ! source "${CONF_LIB}" 2>/dev/null || ! declare -F ai_tools_conf_path_entry >/dev/null 2>&1; then
        skip "allowed-projects seed header" "conf.lib.sh not loadable from ${CONF_LIB}"; return
    fi
    check_seed_header ai_tools_conf_allowlist_seed allowed-projects

    # Every entry-shaped example -- a path, an exclusion, or a quoted path -- parses as an entry;
    # the CLI invocations in the same blocks are not entries and are not read.
    local -a examples=(); local line bad=0
    mapfile -t examples < <(man_examples "${ALLOWLIST_MAN}" | grep -E '^[/!"]' || true)
    if (( ${#examples[@]} == 0 )); then
        fail "allowed-projects(5) EXAMPLES carry no entry-shaped line to check"
    else
        for line in "${examples[@]}"; do
            # shellcheck disable=SC2154  # _ai_tools_conf_value is set by ai_tools_conf_path_entry in the sourced library
            if ai_tools_conf_path_entry "${line}" && [[ "${_ai_tools_conf_value}" == /* || "${_ai_tools_conf_value}" == '!/'* ]]; then :
            else fail "allowed-projects(5) example does not parse as an entry: ${line}"; bad=1; fi
        done
        (( bad )) || pass "every entry-shaped EXAMPLES line in allowed-projects(5) parses through the shared grammar (${#examples[@]} lines)"
    fi
    th_version "${ALLOWLIST_MAN}" ALLOWED-PROJECTS
}
check_allowlist_page

SECRET_MAN="$(man5_path secret-patterns)"
SECRET_LIB="${ROOT}/src/usr/local/lib/ai-tools/secret-patterns.lib.sh"
[[ -r "${SECRET_LIB}" ]] || SECRET_LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"
section "man page: secret-patterns(5) and the seeded patterns header (unit)"
check_secret_patterns_page() {
    if [[ ! -r "${SECRET_MAN}" ]]; then
        skip "secret-patterns page" "secret-patterns.5 not found in the repo or installed"; return
    fi
    # shellcheck source=/dev/null
    if ! source "${CONF_LIB}" 2>/dev/null || ! source "${SECRET_LIB}" 2>/dev/null \
            || ! declare -F ai_tools_load_secret_patterns >/dev/null 2>&1; then
        skip "secret-patterns seed header" "conf.lib.sh or secret-patterns.lib.sh not loadable"; return
    fi
    check_seed_header ai_tools_conf_secret_patterns_seed secret-patterns

    # The page's example patterns load as patterns: the pattern-shaped lines of EXAMPLES (not
    # the CLI invocations) are written to a file, read through the library's own loader, and must
    # come back one for one, each a basename glob with no '/'.
    local -a examples=() loaded=(); local pattern bad=0 file
    mapfile -t examples < <(man_examples "${SECRET_MAN}" | grep -vE '^(ai-tools|#|$)' || true)
    if (( ${#examples[@]} == 0 )); then
        fail "secret-patterns(5) EXAMPLES carry no pattern line to check"; return
    fi
    file="$(mktemp)"
    printf '%s\n' "${examples[@]}" > "${file}"
    AI_TOOLS_SECRET_PATTERNS_FILE="${file}" ai_tools_load_secret_patterns
    loaded=( "${AI_TOOLS_SECRET_PATTERNS[@]}" )
    rm -f "${file}"
    _AI_TOOLS_PATTERNS_LOADED=""
    for pattern in "${examples[@]}"; do
        [[ "${pattern}" == */* ]] && { fail "secret-patterns(5) example carries a '/', which a basename glob never matches: ${pattern}"; bad=1; }
    done
    if (( ${#loaded[@]} != ${#examples[@]} )); then
        fail "secret-patterns(5) EXAMPLES: ${#examples[@]} pattern lines loaded as ${#loaded[@]} patterns"; bad=1
    fi
    (( bad )) || pass "every pattern line in secret-patterns(5) EXAMPLES loads through the shared matcher (${#examples[@]} patterns)"
    th_version "${SECRET_MAN}" SECRET-PATTERNS
}
check_secret_patterns_page

# ── The shipped config templates: operator.conf(5), custom-claude-endpoint.conf(5) ──────────────
# Each template is %config(noreplace), so a prose change to it reaches an upgraded host only
# as an .rpmnew the operator reconciles by hand; the reference lives in the page and the template keeps
# a brief line per option beside its commented default. check_config_page holds the two
# in lockstep: every key the template mentions is documented under OPTIONS, and every documented
# option is one the template mentions -- read with ai_tools_conf_keys, the same "mentioned"
# predicate `system post-upgrade` announces a new option by, so the test and the upgrade report
# cannot disagree.
CONFIG_TEMPLATES="${ROOT}/src/etc/ai-tools"
[[ -d "${CONFIG_TEMPLATES}" ]] || CONFIG_TEMPLATES="/etc/ai-tools"

# check_config_page <page-name> <config-file> <TH-NAME>
check_config_page() {
    local name="$1" file="$2" th="$3" page key
    page="$(man5_path "${name}")"
    if [[ ! -r "${page}" || ! -r "${file}" ]]; then
        skip "${name} page" "page or template not found (${page}, ${file})"; return
    fi
    # shellcheck source=/dev/null
    if ! source "${CONF_LIB}" 2>/dev/null || ! declare -F ai_tools_conf_keys >/dev/null 2>&1; then
        skip "${name} page key sync" "conf.lib.sh not loadable from ${CONF_LIB}"; return
    fi
    local -a documented=() used=()
    # The tag line after each .TP or .TQ under OPTIONS, where the tag opens with the key token.
    mapfile -t documented < <(man_section "${page}" OPTIONS \
        | awk 'prev==".TP"||prev==".TQ"{print} {prev=$0}' \
        | grep -oE '^\.B[IR]? [A-Z][A-Z0-9_]*' | awk '{print $2}' | sort -u)
    ai_tools_conf_keys used "${file}"
    mapfile -t used < <(printf '%s\n' "${used[@]}" | sort -u)
    (( ${#used[@]} > 0 )) || { fail "${name}: the template mentions no key"; return; }
    local missing=0 stale=0
    for key in "${used[@]}"; do
        printf '%s\n' "${documented[@]}" | grep -qx "${key}" \
            || { fail "${name}(5): the template mentions '${key}', which OPTIONS does not document"; missing=1; }
    done
    (( missing )) || pass "${name}(5) documents every key the template mentions (${#used[@]} keys)"
    for key in "${documented[@]}"; do
        printf '%s\n' "${used[@]}" | grep -qx "${key}" \
            || { fail "${name}(5) documents '${key}', which the template does not mention"; stale=1; }
    done
    (( stale )) || pass "every option ${name}(5) documents is one the template mentions"
    th_version "${page}" "${th}"
}
section "man page: the shipped config templates in sync with their pages (unit)"
check_config_page operator.conf "${CONFIG_TEMPLATES}/operator.conf" OPERATOR.CONF
check_config_page custom-claude-endpoint.conf "${CONFIG_TEMPLATES}/endpoints/custom-claude-endpoint.conf" CUSTOM-CLAUDE-ENDPOINT.CONF

# ── Config headers are fixed-width text ───────────────────────────────────────────────────────
# An operator reads a config file in a terminal, where nothing reflows it, so every header this
# project writes -- the two seeds and the two shipped templates -- holds to 72 columns and carries
# no comment line ending on a word that ties to the next one. The rule is the checker's
# --config-header mode (the ai-tools-technical-docs skill); this runs it over the four.
section "config headers: 72 columns, no line ending on a tie word (unit)"
PROSE_CHECK=""
for candidate in \
    "${ROOT}/src/usr/share/ai-tools/skills/ai-tools-technical-docs/prose-check.py" \
    "/usr/share/ai-tools/skills/ai-tools-technical-docs/prose-check.py" \
    "/opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py"; do
    [[ -r "${candidate}" ]] && { PROSE_CHECK="${candidate}"; break; }
done
check_config_headers() {
    if [[ -z "${PROSE_CHECK}" ]] || ! command -v python3 >/dev/null 2>&1; then
        skip "config header format" "prose-check.py or python3 not available"; return
    fi
    # shellcheck source=/dev/null
    if ! source "${CONF_LIB}" 2>/dev/null || ! declare -F ai_tools_conf_allowlist_seed >/dev/null 2>&1; then
        skip "config header format" "conf.lib.sh not loadable from ${CONF_LIB}"; return
    fi
    local dir out rc=0
    dir="$(mktemp -d)"
    ai_tools_conf_allowlist_seed > "${dir}/allowed-projects"
    ai_tools_conf_secret_patterns_seed > "${dir}/secret-patterns"
    out="$(python3 "${PROSE_CHECK}" --config-header "${dir}/allowed-projects" "${dir}/secret-patterns" \
        "${CONFIG_TEMPLATES}/operator.conf" "${CONFIG_TEMPLATES}/endpoints/custom-claude-endpoint.conf" 2>&1)" || rc=$?
    rm -rf "${dir}"
    if (( rc == 0 )); then
        pass "the two seeded headers and the two shipped templates hold to 72 columns with no tie-word line end"
    else
        fail "a config header breaks the width or tie rule:"$'\n'"${out}"
    fi
}
check_config_headers

finish

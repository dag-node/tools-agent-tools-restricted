#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/man.sh
# Hermetic sync test between this project's two man pages and the help text of the command each
# documents: ai-tools(1) against the CLI's usage(), and ai-tools-admin(8) against the admin
# helper's. In both pairs the page and the help are no longer copies of each other -- usage() is
# orientation while the page is the reference -- so equality of their whole option sets is the
# wrong contract and is what used to make slimming the help impossible.
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

finish

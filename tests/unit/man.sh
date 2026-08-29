#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/man.sh
# Hermetic sync test between ai-tools(1) and the CLI's own help. The two surfaces are no
# longer copies of each other -- usage() is orientation (verbs and the cross-verb flags)
# while the page is the reference (every per-verb option) -- so equality of their whole
# option sets is the wrong contract and is what used to make slimming the help impossible.
# Four checks replace it:
#   (1) the VERB sets match in both directions;
#   (2) every long option usage() names anywhere is documented in the page;
#   (3) every long option the page's OPTIONS section documents is one a CLI parser
#       accepts -- the direction that catches an option outliving its parser;
#   (4) the .TH version field is present -- @AI_TOOLS_VERSION@ in the repo source, a version
#       number on an RPM install, `dev` on a source install of an unstamped tree.
# Pure text comparison of the two source files -- no root, no install dependency, no CLI
# execution (the CLI's bootstrap gate fail-closes on an unprovisioned host, so it cannot be
# run for its help output here). Validates the repo sources directly, falling back to the
# installed CLI + man page outside a checkout (the man page may be gzipped there).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${ROOT}/src/usr/local/bin/ai-tools.sh"
MAN="${ROOT}/src/usr/local/share/man/man1/ai-tools.1"
[[ -r "${CLI}" ]] || CLI="/usr/local/bin/ai-tools"
if [[ ! -r "${MAN}" ]]; then
    MAN="/usr/local/share/man/man1/ai-tools.1"
    [[ -r "${MAN}" ]] || MAN="/usr/local/share/man/man1/ai-tools.1.gz"
fi
section "man page: ai-tools(1) in sync with the CLI help (unit)"

if [[ ! -r "${CLI}" || ! -r "${MAN}" ]]; then
    skip "ai-tools man sync" "CLI or man page not found in src/ or install paths"
    finish; exit
fi

# read_man: the page text with troff's escaped hyphens (\-\-project\-claim) flattened, so
# every extraction below matches plain option spellings.
read_man() {
    case "${MAN}" in
        *.gz) zcat "${MAN}" ;;
        *)    cat  "${MAN}" ;;
    esac | sed 's/\\-/-/g'
}

# usage_text: the CLI's user-facing help, bounded to its heredoc (usage() { cat <<EOF ... EOF }).
usage_text() { sed -n '/^usage() {/,/^EOF$/p' "${CLI}" 2>/dev/null; }

# man_section <NAME>: the body of one .SH section, bounded by the next .SH.
man_section() { read_man | awk -v s=".SH $1" '$0==s{f=1;next} /^\.SH /{f=0} f'; }

if [[ -z "$(usage_text)" ]]; then
    fail "could not extract the usage() heredoc from ${CLI}"
    finish; exit
fi

# ── (1) The verb sets, both directions ──────────────────────────────────────────
# usage() lists one verb per line, indented four spaces and starting with its long option
# (the flag block below it is indented two, so it is excluded by that indent alone).
help_verbs="$(usage_text | grep -E '^    --[a-z]' | grep -oE -- '--[a-z][a-z-]+' | sort -u)"
# In the page a verb is the FIRST long option on the .B/.BR line opening each TOP-LEVEL .TP
# entry under COMMANDS. Three things must not be read as verbs: the rest of that opening
# line (the verb's own flags), the prose below it (which names other verbs), and the nested
# .TP entries inside an .RS/.RE block, which are that verb's per-flag reference and are
# where a per-verb option belongs -- under the verb it applies to, not in a flat list that
# separates it from the only command it means anything for. Hence the depth counter.
man_verbs="$(man_section COMMANDS \
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
help_opts="$(usage_text | grep -oE -- '--[a-z][a-z-]+' | sort -u)"
man_opts="$(read_man | grep -oE -- '--[a-z][a-z-]+' | sort -u)"
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
# The contract is that the field is PRESENT, not that it looks like a release. Three values are
# all correct: the repo source carries the @AI_TOOLS_VERSION@ token, an RPM install carries a
# version number, and a source install of an unstamped tree carries `dev` -- which is exactly what
# `ai-tools --version` reports there, and what ai_tools_msg_version passes through deliberately.
# Enumerating the shapes rejected `dev`, so the check failed or passed according to how the HOST
# was provisioned rather than according to anything about the page. It now asserts what it always
# meant: the field is non-empty.
if read_man | grep -qE '^\.TH AI-TOOLS 1 .*"ai-tools [^"[:space:]][^"]*"'; then
    pass "man page .TH carries the version token/substitution"
else
    # Name the file: this check reads the repo source when there is one and the installed copy
    # otherwise, and which of the two it got is the first thing worth knowing on a failure.
    fail "man page .TH lost its version field (read ${MAN})"
fi

finish

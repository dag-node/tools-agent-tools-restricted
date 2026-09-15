#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/generators/option-spellings.sh -- generate docs/option-spellings.md from the CLI's OPTION_SPELLINGS table.
# The page is derived, never authored: every row is read off src/usr/local/bin/ai-tools.sh by text, so the spelling
# an operator reads and the one the CLI rewrites have one home. `rows` is the same read, for tests/unit/cli-verbs.sh,
# which holds every value to a dispatched command and the committed page to the table.
#
#     bash tools/generators/option-spellings.sh generate   rewrite the page from the table
#     bash tools/generators/option-spellings.sh print      write the page to stdout
#     bash tools/generators/option-spellings.sh rows       one `<option><TAB><command>` line per table row
#     bash tools/generators/option-spellings.sh stale      exit 1 when the committed page differs from the table
#
# An empty read is a hard error: the table has moved or changed shape, and a page with no rows would read as a CLI
# with no option spellings.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="src/usr/local/bin/ai-tools.sh"
PAGE="docs/option-spellings.md"
cd "${ROOT}"

# rows: the table's rows, one `[key]="value"` line each between the declaration and its closing parenthesis.
rows() {
    local out
    out="$(awk '
        /^declare -rA OPTION_SPELLINGS=\(/ { on=1; next }
        on && /^\)/ { exit }
        on && match($0, /^[ \t]*\[[^]]+\]="[^"]*"$/) {
            key=$0; sub(/^[ \t]*\[/, "", key); sub(/\].*$/, "", key)
            value=$0; sub(/^[^"]*"/, "", value); sub(/"$/, "", value)
            printf "%s\t%s\n", key, value
        }' "${CLI}")"
    if [[ -z "${out}" ]]; then
        echo "option-spellings: no OPTION_SPELLINGS row read from ${CLI}" >&2
        return 1
    fi
    printf '%s\n' "${out}"
}

# render: the page. A token is shown as an operator types it -- `ai-tools` and the command for a command, the option
# alone for the two short options and the long one `-g` stands for -- and the columns are padded to the widest cell,
# so the table reads aligned in the source as well as rendered.
render() {
    cat <<'MARKDOWN'
<!-- GENERATED from src/usr/local/bin/ai-tools.sh (OPTION_SPELLINGS) by tools/generators/option-spellings.sh; do not edit this
     file. Change a row in the table and run `bash tools/generators/option-spellings.sh generate`; tests/unit/cli-verbs.sh
     regenerates the page and fails on a difference. -->
MARKDOWN
    # The generated-file marker is printed rather than written in the heredoc: the checker reads it as a whole line
    # only, and a heredoc line carrying it would mark this tool's own comments as generated too.
    printf '<!-- %s -->\n' 'prose-check: ignore-file'
    cat <<'MARKDOWN'
# Option spellings and the commands they run

`ai-tools` spells a command as a bare word: a collection and its verb (`ai-tools projects claim`), or one word for
the host (`ai-tools status`), with `--` reserved for an option. That is the preferred form, and the option spelling
each command had in earlier releases is kept for compatibility: it is rewritten to the command ahead of every check,
prints one notice, [MSG-W3W8](../src/usr/local/bin/ai-tools.sh), naming the preferred form, and exits as that command
does, so a script written against an earlier release runs unchanged.

MARKDOWN
    rows | awk -F'\t' '
        function shown(token) {
            # A short option and the long option it stands for are typed alone; every other token is a command.
            if (token ~ /^-[A-Za-z]$/ || token == "--group") return "`" token "`"
            return "`ai-tools " token "`"
        }
        function dashes(n,   s) { s = ""; while (n-- > 0) s = s "-"; return s }
        {
            option[NR] = shown($1); preferred[NR] = shown($2)
            if (length(option[NR]) > w1) w1 = length(option[NR])
            if (length(preferred[NR]) > w2) w2 = length(preferred[NR])
        }
        END {
            h1 = "Option spelling"; h2 = "Preferred form"
            if (length(h1) > w1) w1 = length(h1)
            if (length(h2) > w2) w2 = length(h2)
            printf "| %-*s | %-*s |\n", w1, h1, w2, h2
            printf "|%s|%s|\n", dashes(w1 + 2), dashes(w2 + 2)
            for (i = 1; i <= NR; i++) printf "| %-*s | %-*s |\n", w1, option[i], w2, preferred[i]
        }'
    cat <<'MARKDOWN'

`-g` is the short form `ai-tools projects unclaim` took for `--group`, and `-V` the short form of `--version`; each
is rewritten wherever it stands.

`ai-tools --relabel` is not in the table: the entrypoint reconcile is `sudo ai-tools-admin system entrypoints relabel`,
a root command this CLI refuses to run, so that spelling prints the command and exits 2 instead of running it.
MARKDOWN
}

command="${1:-print}"
case "${command}" in
    rows)     rows ;;
    print)    render ;;
    generate) mkdir -p "$(dirname "${PAGE}")"; render > "${PAGE}" ;;
    stale)
        if ! render | diff -q - "${PAGE}" >/dev/null; then
            echo "${PAGE} is stale; run: bash tools/generators/option-spellings.sh generate" >&2
            exit 1
        fi ;;
    *)
        echo "usage: bash tools/generators/option-spellings.sh generate|print|rows|stale" >&2
        exit 2 ;;
esac

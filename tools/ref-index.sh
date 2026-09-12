#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/ref-index.sh -- run the skill's ref-index.py over this repository. The tracked files it
# reads and the index it writes are named here once, for the pre-commit hook, the unit test,
# and a developer's own run; the tool itself is generic and takes both as arguments.
#
#     bash tools/ref-index.sh generate          retire what the tree dropped, then rewrite
#                                               .claude/references.md from the tree
#     bash tools/ref-index.sh check             report every reference finding in the tree,
#                                               and every message string carrying a link
#     bash tools/ref-index.sh messages          report a message string carrying a URL, a Markdown
#                              [<file>...]      link, or an HTML anchor; the tree, or the files given
#     bash tools/ref-index.sh stale             exit 1 when the committed index differs from the tree
#     bash tools/ref-index.sh relink            rewrite every reftag link in the tree's documents
#     bash tools/ref-index.sh kinds             list the kinds and code families a reftag may name
#     bash tools/ref-index.sh new <family>      mint a reftag whose id is unique across the tree,
#                              [--count N]      the retired file, and the wip tickets; N of them,
#                                               distinct from each other too
#     bash tools/ref-index.sh where <reftag>    print the target's live file:line and span
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${ROOT}/src/usr/share/ai-tools/skills/ai-tools-technical-docs/ref-index.py"
INDEX=".claude/references.md"
# Retired reftags: `generate` records what the tree dropped before it rewrites the index, and
# `new` and `check` read the file, so an id that reached a log line is never drawn again. Each row
# carries the release it was retired at, so a row is dropped by hand once that release is a few
# stable releases behind.
RETIRED=".claude/.referenced.md"
# ai-tools-messages(7) is generated FROM this index and names every message code in it, so reading
# it back would cite all of them and empty the "documented in" pointer of its meaning.
GENERATED_PAGE="src/usr/local/share/man/man7/ai-tools-messages.7"
RELEASE="$(cat "${ROOT}/packaging/VERSION" 2>/dev/null || true)"
# The wip repository beside this one holds tickets that show reftags ahead of minting them; `new`
# reads them when the checkout is present, so an id shown in a ticket is not drawn for another use.
WIP_ISSUES="${ROOT}/../tools-agent-tools-restricted-wip/issues"
cd "${ROOT}"

# Every tracked text file. The index, the retired file, and the generated message page each name
# every reftag they hold, so none of the three is read, and neither is a key, an image, or a
# compiled policy module.
files() {
    git ls-files ":!${INDEX}" ":!${RETIRED}" ":!${GENERATED_PAGE}" \
        | grep -v -e '\.asc$' -e '\.png$' -e '\.pp$'
}
mint_files() { files; if [[ -d "${WIP_ISSUES}" ]]; then find "${WIP_ISSUES}" -name '*.md' -type f; fi; }

# What a runtime message may not carry: a URL, a Markdown link, or an HTML anchor. The rule is
# the skill's -- output carries a reftag, which resolves through the index, where a link is
# unresolvable in `journalctl` and ages faster than the code -- and this check is REPOSITORY-side
# because it reads a message string: `prose-check.py` skips a quoted span by design, and knowing
# that a code in the first argument makes an emit call is repository knowledge that the shipped
# tools do not carry.
#
# Matching reads the ASCII DELIMITER a link needs -- a scheme's `://`, a `mailto:`, a Markdown
# `[text](target)`, an `<a>` tag -- which is what makes it complete: a URI permits most of Unicode
# in a host or a path, while every scheme is spelled in ASCII whatever follows it. An enumeration
# of the characters would leave a gap the delimiter does not. A non-ASCII URL is
# doubly unusable in a log line in any case: `ai_tools_log_sanitize` reduces a message
# to printable ASCII before either sink, so its bytes reach the journal as `?`.
MESSAGE_LINK='[a-zA-Z][a-zA-Z0-9+.-]*://|mailto:|www\.[^ ]|\[[^]]*\]\([^)]*\)|</?[aA][ 	>]'

# message_rows [<file>...]: one `code<TAB>file<TAB>message` record per message target, read
# from a fresh scan, so a message added since the last `generate` is read as it stands. A name may
# carry an escaped pipe, so the row is split on its unescaped pipes alone: the escape is parked
# on a byte no row contains, the row is split, and the byte restored.
message_rows() {
    { if (( $# )); then printf '%s\n' "$@"; else files; fi; } \
        | xargs python3 "${TOOL}" generate \
        | awk '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /MSG-/ {
            row = $0
            gsub(/\\\|/, "\001", row)
            if (split(row, f, /\|/) < 7) next
            if (match(trim(f[3]), /MSG-[A-Z][0-9][A-Z][0-9]/) == 0) next
            code = substr(trim(f[3]), RSTART, RLENGTH)
            message = trim(f[4]); gsub(/\001/, "|", message)
            printf("%s\t%s\t%s\n", code, trim(f[5]), message)
        }'
}

# message_links [<file>...]: report each message carrying a link, and return 1 when any did.
# The index records a message by its file, so the line is resolved from the first occurrence
# of the code in that file -- the emit call, which is where the string is written.
message_links() {
    local code file message line findings=0
    while IFS=$'\t' read -r code file message; do
        [[ "${message}" =~ ${MESSAGE_LINK} ]] || continue
        line="$(grep -n -m1 -F -- "${code}" "${file}" 2>/dev/null | cut -d: -f1)"
        printf '%s:%s: message-link [%s] -- the message carries a URL, a Markdown link, or an '\
'HTML anchor, which a reader of the output cannot resolve; print the code alone, and cite the '\
'link from a document, where a URI- reftag defines it once\n' "${file}" "${line:-0}" "${code}"
        findings=$((findings + 1))
    done < <(message_rows "$@")
    if (( findings )); then
        printf '\n%d message-link finding(s). See the ai-tools-technical-docs skill.\n' "${findings}"
        return 1
    fi
}

command="${1:-check}"
shift || true
case "${command}" in
    generate)
        files | xargs python3 "${TOOL}" retire --index "${INDEX}" --retired "${RETIRED}" --release "${RELEASE}"
        files | xargs python3 "${TOOL}" generate --out "${INDEX}" ;;
    check)
        # Both halves run, and the status is the worse of the two: a reference finding must not
        # hide a message carrying a link, or either one fixed alone would read as a clean tree.
        status=0
        files | xargs python3 "${TOOL}" check --retired "${RETIRED}" || status=$?
        message_links || status=$?
        exit "${status}" ;;
    messages) message_links "$@" ;;
    relink)   files | xargs python3 "${TOOL}" relink ;;
    stale)
        if ! files | xargs python3 "${TOOL}" generate --at "${INDEX}" | diff -q - "${INDEX}" >/dev/null; then
            echo "${INDEX} is stale; run: bash tools/ref-index.sh generate" >&2
            exit 1
        fi ;;
    kinds)    python3 "${TOOL}" kinds ;;
    new)      mint_files | xargs python3 "${TOOL}" new "$@" --index "${INDEX}" --retired "${RETIRED}" ;;
    where)    python3 "${TOOL}" where "$@" --index "${INDEX}" ;;
    *)
        echo "usage: bash tools/ref-index.sh generate|check|messages [<file>...]|stale|relink|kinds|new <family>|where <reftag>" >&2
        exit 2 ;;
esac

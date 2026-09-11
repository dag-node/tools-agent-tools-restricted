#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/ref-index.sh -- run the skill's ref-index.py over this repository. The tracked files it
# reads and the index it writes are named here once, for the pre-commit hook, the unit test,
# and a developer's own run; the tool itself is generic and takes both as arguments.
#
#     bash tools/ref-index.sh generate          retire what the tree dropped, then rewrite
#                                               .claude/references.md from the tree
#     bash tools/ref-index.sh check             report every reference finding in the tree
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
RELEASE="$(cat "${ROOT}/packaging/VERSION" 2>/dev/null || true)"
# The wip repository beside this one holds tickets that show reftags ahead of minting them; `new`
# reads them when the checkout is present, so an id shown in a ticket is not drawn for another use.
WIP_ISSUES="${ROOT}/../tools-agent-tools-restricted-wip/issues"
cd "${ROOT}"

# Every tracked text file. The index and the retired file cite every reftag, so neither is read,
# and neither is a key, an image, or a compiled policy module.
files() { git ls-files ":!${INDEX}" ":!${RETIRED}" | grep -v -e '\.asc$' -e '\.png$' -e '\.pp$'; }
mint_files() { files; if [[ -d "${WIP_ISSUES}" ]]; then find "${WIP_ISSUES}" -name '*.md' -type f; fi; }

command="${1:-check}"
shift || true
case "${command}" in
    generate)
        files | xargs python3 "${TOOL}" retire --index "${INDEX}" --retired "${RETIRED}" --release "${RELEASE}"
        files | xargs python3 "${TOOL}" generate --out "${INDEX}" ;;
    check)    files | xargs python3 "${TOOL}" check --retired "${RETIRED}" ;;
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
        echo "usage: bash tools/ref-index.sh generate|check|stale|relink|kinds|new <family>|where <reftag>" >&2
        exit 2 ;;
esac

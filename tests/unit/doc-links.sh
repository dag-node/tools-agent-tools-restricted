#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/doc-links.sh
# Holds packaging/rewrite-doc-links.py, the %build step that points the installed documentation's links at the release
# tag, to what the installed copy needs. The first section drives the script over a fixture tree: a link into a rule,
# a reference definition into the source, a link to another page, an absolute URL, a page anchor and a link inside
# a fenced block, with the tag a final and a prerelease build take, and a link that leaves the tree, which refuses
# the run and leaves every file as it was. The second runs it over a copy of the checkout's docs/ and README.md
# and reads every rewritten URL back against the checkout: each names a tracked file, each `#ref-` anchor is defined
# there, and no relative link left in the copy leaves docs/ or README.md. Skipped outside a checkout that carries
# the script. The second section is also skipped outside a git checkout: the selftest image copies only part of the tree
# and leaves out the files the documentation links to, so the read-back runs in CI's dev-tools job instead.
#
# Hermetic: every tree it writes is in the test's own /tmp testdir. Pure text, so it does not need privilege of its own.
#
# The fixture text carries reftag-shaped anchors that are content, so the tree-wide reftag check does not read this file
# (the marker on the next line).
# ref-index: ignore-file
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT}/packaging/rewrite-doc-links.py"
BASE="https://github.com/example/repo"
section "doc-links: the installed documentation's links reach the release tag (unit)"

if ! command -v python3 >/dev/null 2>&1; then
    skip "doc-links" "python3 not available"; finish; exit
fi
if [[ ! -r "${SCRIPT}" ]]; then
    skip "doc-links" "not a checkout (no ${SCRIPT})"; finish; exit
fi

mktestdir

# ── A fixture tree: what is rewritten, and what is left as written ────────────────────────────
FIX="${TESTDIR}/fixture"
mkdir -p "${FIX}/docs/projects"
cat > "${FIX}/docs/projects/page.md" <<'MARKDOWN'
The rule is [ref-section-a1b2](../../.claude/rules/cli.rule.md#ref-section-a1b2).
A sibling is [Claim](claim.md), and a jump is [below](#below).
An outside site is [example](https://example.invalid/x).

[FN-A1B2]: ../../src/usr/local/bin/ai-tools.sh "the CLI"

```text
[kept](../../.claude/rules/cli.rule.md)
```
MARKDOWN
printf 'See [the docs](docs/projects/page.md) and [the licence](LICENSE).\n' > "${FIX}/README.md"

if out="$(python3 -I "${SCRIPT}" --base "${BASE}" --version 1.2.3 "${FIX}" 2>&1)"; then
    pass "a final build rewrites the tree: ${out}"
else
    fail "a final build exited non-zero: ${out}"
fi
page="$(cat "${FIX}/docs/projects/page.md")"
if [[ "${page}" == *"(${BASE}/blob/v1.2.3/.claude/rules/cli.rule.md#ref-section-a1b2)"* ]]; then
    pass "a link into a rule names the rule at v1.2.3, its anchor kept"
else
    fail "the rule link was not rewritten to the tag: ${page}"
fi
if [[ "${page}" == *"[FN-A1B2]: ${BASE}/blob/v1.2.3/src/usr/local/bin/ai-tools.sh \"the CLI\""* ]]; then
    pass "a reference definition into the source is rewritten, its title kept"
else
    fail "the reference definition was not rewritten: ${page}"
fi
if [[ "${page}" == *"[Claim](claim.md)"* && "${page}" == *"[below](#below)"* \
       && "${page}" == *"(https://example.invalid/x)"* ]]; then
    pass "a link to a page, a page anchor and an absolute URL are left as written"
else
    fail "a link the installed tree resolves was rewritten: ${page}"
fi
if [[ "${page}" == *$'```text\n[kept](../../.claude/rules/cli.rule.md)\n```'* ]]; then
    pass "a link inside a fenced block is left as written"
else
    fail "the fenced block was rewritten: ${page}"
fi
readme="$(cat "${FIX}/README.md")"
if [[ "${readme}" == *"(docs/projects/page.md)"* && "${readme}" == *"(${BASE}/blob/v1.2.3/LICENSE)"* ]]; then
    pass "README.md keeps its link into docs/ and points the licence at the tag"
else
    fail "README.md was rewritten wrongly: ${readme}"
fi

printf '[r](../.claude/rules/x.rule.md)\n' > "${FIX}/docs/rc.md"
python3 -I "${SCRIPT}" --base "${BASE}" --version 1.2.3 --release 0.rc4 "${FIX}" >/dev/null 2>&1 || true
if [[ "$(cat "${FIX}/docs/rc.md")" == *"/blob/v1.2.3-rc.4/.claude/rules/x.rule.md"* ]]; then
    pass "the Release 0.rc4 a prerelease build takes names the v1.2.3-rc.4 tag"
else
    fail "a prerelease build did not name its tag: $(cat "${FIX}/docs/rc.md")"
fi

ESC="${TESTDIR}/escape"
mkdir -p "${ESC}/docs"
printf '[in](../.claude/rules/x.rule.md)\n[out](../../elsewhere.md)\n' > "${ESC}/docs/page.md"
before="$(cat "${ESC}/docs/page.md")"
if python3 -I "${SCRIPT}" --base "${BASE}" --version 1.2.3 "${ESC}" >/dev/null 2>&1; then
    fail "a link that leaves the source tree did not refuse the run"
else
    if [[ "$(cat "${ESC}/docs/page.md")" == "${before}" ]]; then
        pass "a link that leaves the source tree refuses the run and leaves every file as it was"
    else
        fail "a refused run changed a file: $(cat "${ESC}/docs/page.md")"
    fi
fi

# ── The checkout: every rewritten URL names a tracked file and a defined anchor ───────────────
if [[ ! -e "${ROOT}/.git" ]]; then
    skip "the checkout's documentation links" "not a git checkout"; finish; exit
fi
COPY="${TESTDIR}/checkout"
mkdir -p "${COPY}"
cp -r "${ROOT}/docs" "${ROOT}/README.md" "${COPY}/"
if out="$(python3 -I "${SCRIPT}" --base "${BASE}" --version 0.0.0 "${COPY}" 2>&1)"; then
    pass "the checkout's documentation rewrites: ${out}"
else
    fail "the checkout's documentation refused: ${out}"
fi
if findings="$(python3 -I - "${ROOT}" "${COPY}" "${BASE}/blob/v0.0.0/" <<'PYTHON'
import os, re, sys
root, copy, prefix = sys.argv[1:]
url = re.compile(re.escape(prefix) + r'([^)\s#"]+)(#[^)\s"]*)?')
link = re.compile(r'\]\(([^)\s#]+)')
for directory, _, names in os.walk(copy):
    for name in names:
        if not name.endswith(".md"):
            continue
        path = os.path.join(directory, name)
        page = os.path.relpath(path, copy)
        text = open(path, encoding="utf-8").read()
        for match in url.finditer(text):
            target, anchor = match.group(1), (match.group(2) or "")[1:]
            full = os.path.join(root, target)
            if not os.path.exists(full):
                print(f"{page}: {target} is not in the checkout")
            elif anchor.startswith("ref-") and f'id="{anchor}"' not in open(full, errors="replace").read():
                print(f"{page}: {target}#{anchor} is not defined there")
        for match in link.finditer(text):
            target = match.group(1)
            if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", target) or target.startswith("/"):
                continue
            resolved = os.path.normpath(os.path.join(os.path.dirname(page), target))
            if not (resolved in ("README.md", "docs") or resolved.startswith("docs/")):
                print(f"{page}: {target} still leaves the installed tree")
PYTHON
)"; then
    if [[ -z "${findings}" ]]; then
        pass "every rewritten link names a file and an anchor the checkout holds, and none left leaves the tree"
    else
        fail "the installed links do not all resolve:"$'\n'"${findings}"
    fi
else
    fail "the read-back of the rewritten checkout did not run"
fi

finish

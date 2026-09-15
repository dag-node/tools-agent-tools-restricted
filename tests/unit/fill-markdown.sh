#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/fill-markdown.sh
# Unit test for tools/formatters/fill-markdown.py, the Markdown filler, and tools/formatters/verify-reflow.py, the gate
# that proves a reflow changed line breaks alone. The filler and the gate are pinned in one file because a defect
# in either looks the same from outside: a filler that damages a shape the gate does not read passes, and a filler
# that silently copies a region through leaves a clean gate and an unformatted file. So one fixture carries every shape
# found by rehearsing the filler on real pages, and each is driven from both ends -- the filler must reflow the fixture
# to a state the gate passes and the checker's `--wrap` finds complete, and each defect class, injected by hand, must be
# reported by the gate. A second run must leave the file as the first left it, and `--lines` must confine a reflow
# to the blocks it names. The one class the gate cannot see -- a split code span leaves the token stream unchanged -- is
# asserted on the filler's output instead. The tree's own pages are reflowed into the testdir and held to the same three
# properties, skipped outside a checkout. The reader every formatter shares (`tools/formatters/text_file.py`) is pinned
# here: each shape it refuses -- a control or a bidi character, a NUL, a carriage return, a byte that is not UTF-8,
# a byte-order mark, a symlink, a FIFO -- is reported with its reason and left byte-identical while the clean file
# beside it is filled; a column or a range that is not one is a usage error; and the gate refuses a base copy that is
# not text without printing a token of it, and a path resolving outside the tree. A repo dev tool, not a deployed
# artifact, so it runs from the checkout. The fixture holds a reftag as text, so the tree-wide reference check does not
# read this file (the marker on the next line).
# ref-index: ignore-file
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILLER="${ROOT}/tools/formatters/fill-markdown.py"
GATE="${ROOT}/tools/formatters/verify-reflow.py"
PC="${ROOT}/src/usr/share/ai-tools/skills/ai-tools-technical-docs/prose-check.py"
section "fill-markdown: the Markdown filler and the reflow gate (unit)"

if [[ ! -r "${FILLER}" || ! -r "${GATE}" ]]; then
    skip "fill-markdown" "tools not found under ${ROOT}/tools"; finish; exit
fi
if ! command -v python3 >/dev/null 2>&1; then
    skip "fill-markdown" "python3 not available"; finish; exit
fi

mktestdir
WIDTH=70
mkdir -p "${TESTDIR}/base"
f="${TESTDIR}/f.md"
# Every shape the filler must fill or leave alone; each `detects` case names the real page its shape was found on.
# The URL is the one token wider than the column, so the dash after it lands first on a line unless the filler refuses
# that break. The span paragraph is measured: at 70 columns a greedy break lands inside each of its three spans (the
# first opens at column 62, the second is wider than the column, the third follows a tie word), and the two lines
# after it close their span on the column and one past it.
cat > "${TESTDIR}/base/f.md" <<'FIXTURE'
---
name: fixture
x-ai-tools-managed: true
description: >
  A long frontmatter value whose keys must stay one per line, because a skill is loaded by this
  field and a rule is scoped by its paths list.
---

# Shapes

<!-- A multi-line HTML comment whose continuation lines are prose-shaped and must
     not be reflowed into the paragraph that follows, as the comment is one unit.
     Third line of the same comment. -->

A plain paragraph long enough that a filler will certainly want to rewrap it at a narrow column.

Prose naming `<!--` and `-->` mid-line, which is a sentence about a comment rather than a comment,
and must not make the filler copy the rest of the file through untouched.

Prose that names a fenced block inline, writing the ```bash marker mid-sentence, which a wrap must
not move to the start of a line.

![](https://example.invalid/a-destination-long-enough-to-fill-a-line-on-its-own) - a dash after a wide token
that must not open a list item when the wrap lands it first on a line.

~~~markdown
# Nested fence

```bash
ai-tools-admin system entrypoints relabel /opt/ai-tools/versions/node/v22/bin/claude
```

Prose inside the outer fence that must not be touched even though it is long enough to wrap.
~~~

```bash
ai-tools-admin operators add "$name" 2>&1 > /dev/null
cat <<EOF > /etc/ai-tools/operator.conf
OPERATORS="$name"
EOF
```

A command shown indented, which is a code block and not a paragraph:

    sudo ai-tools audit --since '2 days ago' --and-a-tail-long-enough-to-wrap-if-read-as-prose

- A list item whose first line is long enough to need rewrapping at a narrow column.

  An indented continuation paragraph inside that same list item, also long enough to wrap.

- A second item mentioning <name> and <you> and <operator> as placeholders.

-   A wide marker whose continuation paragraph sits at four spaces, which is not code here.

    The continuation paragraph under the wide marker, long enough to be rewrapped at the column.

    ```text
    a fenced block inside the item, whose margin line must not end the list for the next block
    ```

    A continuation paragraph after the fence, still the item's and long enough to be rewrapped.

<a id="ref-table-q4w8"></a>**A reftag caption on its own line**

| column | meaning |
|---|---|
| `<path>` | a long table row that must not be touched by any filler at all, ever |

> [!NOTE]
> A blockquote paragraph long enough to be rewrapped under its prefix by a filler at a narrow column.

The label probe is cheap. <!-- prose-check: ignore: a deliberate example the checker skips as a line -->
The line after the marker, long enough to be rewrapped at a narrow column on its own.

Spans stay whole: a sentence long enough to reach the column `ai-tools status` is named, then a
span wider than the column on a line of its own,
`sudo ai-tools-admin selinux groups enable tmpmap apphost localipc buildexec`, then the tie
rule beside a span, so that no line ends on the `750 root:root` mode of the pin.

A command key is one word, so a reflow moves it down whole rather than breaking it apart: this
line has no room left for ai-tools.projects.remove.inplace by the time the sentence has run
this far.

A span closing at this column stays: `ai-tools projects claim --yes .`

A span closing at this column shifts: `ai-tools projects claim --yes .`

Final paragraph.
FIXTURE

reflow() {  # reflow: the fixture, freshly copied from its base, through the filler at WIDTH
    cp "${TESTDIR}/base/f.md" "${f}"
    python3 "${FILLER}" --width "${WIDTH}" "${f}" >/dev/null
}
gate() {  # gate: exit 0 when the gate passes the fixture against its base, leaving the report in OUT
    OUT="$(cd "${TESTDIR}" && python3 "${GATE}" --against "${TESTDIR}/base" f.md 2>&1)"
}

# (1) The filler reflows the fixture to a state the gate passes.
if reflow && gate; then
    pass "the fixture reflows to a state the gate passes"
else
    fail "the gate reports the reflowed fixture: $(head -3 <<<"${OUT}")"
fi

# (2) ...and the checker finds complete: a filler that copies a region through leaves a clean gate and an over-width
# line, which is how one class hid. The checker is the oracle, so the two tools agree on what is measured.
left="$(python3 "${PC}" --wrap --width "${WIDTH}" "${f}" 2>&1 | grep -c 'document-width' || true)"
if [[ "${left}" -eq 0 ]]; then
    pass "every measured line is within ${WIDTH} columns after the reflow (checker --wrap)"
else
    fail "${left} line(s) still over ${WIDTH}: $(python3 "${PC}" --wrap --width "${WIDTH}" "${f}" 2>&1 | grep -A1 document-width | head -4)"
fi

# (3) Idempotent.
cp "${f}" "${TESTDIR}/once.md"
python3 "${FILLER}" --width "${WIDTH}" "${f}" >/dev/null
if cmp -s "${f}" "${TESTDIR}/once.md"; then
    pass "a second run is a no-op"
else
    fail "a second run changed the file: $(diff "${TESTDIR}/once.md" "${f}" | head -4)"
fi

# (4) Each defect class, injected into the reflowed fixture, is reported by the gate. The `present` text is a line
# the reflow leaves stable, so a STALE verdict means the fixture no longer holds the shape rather than that the gate
# missed it. detects <class> <found on> <present> <broken>
detects() {
    local name="$1" found_on="$2" present="$3" broken="$4"
    reflow
    if ! grep -qzF -- "${present}" "${f}"; then
        fail "${name}: STALE, the reflowed fixture no longer holds its shape [${found_on}]"
        return
    fi
    python3 - "${f}" "${present}" "${broken}" <<'PY'
import pathlib, sys
path, present, broken = sys.argv[1:]
path = pathlib.Path(path)
path.write_text(path.read_text().replace(present, broken, 1))
PY
    if gate; then
        fail "${name}: the gate MISSED the defect [${found_on}]"
    else
        pass "${name}: reported by the gate [${found_on}]"
    fi
}
detects "frontmatter collapsed" "SKILL.md, the rule files, AGENTS.md" \
    $'x-ai-tools-managed: true\ndescription: >' 'x-ai-tools-managed: true description: >'
detects "nested fence, inner command split" "SKILL.md" \
    'ai-tools-admin system entrypoints relabel /opt/ai-tools/versions/node/v22/bin/claude' \
    $'ai-tools-admin system entrypoints relabel\n/opt/ai-tools/versions/node/v22/bin/claude'
detects "multi-line HTML comment refilled" "CLAUDE.md, AGENTS.md" \
    $'<!-- A multi-line HTML comment whose continuation lines are prose-shaped and must\n     not be reflowed' \
    $'<!-- A multi-line HTML comment whose continuation lines are\nprose-shaped and must not be reflowed'
detects "list continuation de-indented" "cli.rule.md" \
    '  An indented continuation paragraph' 'An indented continuation paragraph'
detects "two paragraphs merged" "any page" $'# Shapes\n\n<!--' $'# Shapes\n<!--'
# The backticked spans are fixture content, not shell substitutions.
# shellcheck disable=SC2016
detects "table row rewrapped" "any page with a table" \
    '| `<path>` | a long table row that must not be touched by any filler at all, ever |' \
    $'| `<path>` | a long table row that must not\n  be touched by any filler at all, ever |'
detects "a word changed" "any page" 'A plain paragraph' 'A simple paragraph'
detects "quote prefix dropped on a continuation line" "docs/session-stop.md" \
    $'its prefix\n> by a filler' $'its prefix\nby a filler'
detects "alert line merged into its paragraph" "docs/project-lifecycle.md" \
    $'> [!NOTE]\n> A blockquote' '> [!NOTE] A blockquote'
detects "list marker respaced" "wip notes" '-   A wide marker' '- A wide marker'
detects "a wrap invented a list item" "wip notes" \
    $'on-its-own) -\na dash after' $'on-its-own)\n- a dash after'
detects "indented code block rewrapped" "wip issues" \
    $'    sudo ai-tools audit --since \'2 days ago\' --and-a-tail' \
    $'    sudo ai-tools audit --since \'2 days ago\'\n    --and-a-tail'
detects "ignore-marker line rewrapped" "docs/entrypoint-verification.md" \
    'The label probe is cheap. <!-- prose-check: ignore:' $'The label probe is cheap.\n<!-- prose-check: ignore:'

# (5) `--lines` confines the reflow to the blocks meeting a range: the plain paragraph is named
# and wraps, the paragraph after it is not and comes back byte-identical.
plain="$(grep -n '^A plain paragraph' "${TESTDIR}/base/f.md" | cut -d: -f1)"
cp "${TESTDIR}/base/f.md" "${f}"
python3 "${FILLER}" --width "${WIDTH}" --lines "${plain}-${plain}" "${f}" >/dev/null
# shellcheck disable=SC2016
if grep -q '^A plain paragraph long enough that a filler will certainly want$' "${f}" \
        && grep -qF 'Prose naming `<!--` and `-->` mid-line, which is a sentence about a comment rather than a comment,' "${f}"; then
    pass "--lines fills the named block and leaves the next one as written"
else
    fail "--lines did not scope the reflow: $(diff "${TESTDIR}/base/f.md" "${f}" | head -6)"
fi

# (6) A break never falls inside a code span: the literal a span holds is what `git grep` finds,
# and only on one line. The gate cannot see this class, so the filler is held to it directly:
# each span whole on one line, the one wider than the column run over on a line of its own, the
# one closing on the column left there, and the one closing past it moved down whole.
reflow
span_whole() {  # span_whole <literal>: PASS when the reflowed fixture holds the literal on one line
    if [[ "$(grep -c -F -- "$1" "${f}")" -ge 1 ]]; then pass "code span whole on one line: $1"
    else fail "code span split across lines: $1"; fi
}
span_whole 'ai-tools status'
span_whole '750 root:root'
# A test's command key (tests/lib/cli-spelling.sh) carries hyphens and dots, and no backtick marks it, so it rests
# on the same rule from the other side: a break falls between words, never inside one. What it costs if it does not is
# the suite's own notation, which `git grep` then finds on no line. The fixture leaves the tail of a line too short
# to hold the key, so a filler that broke on a hyphen or a dot would split it there.
if [[ "$(grep -c -F -- 'ai-tools.projects.remove.inplace' "${f}")" -eq 1 ]]; then
    pass "a command key is one word: the reflow moves it down whole rather than breaking it"
else
    fail "a command key was broken by the reflow: $(grep -n 'remove' "${f}")"
fi
# shellcheck disable=SC2016
if grep -qxF -- '`sudo ai-tools-admin selinux groups enable tmpmap apphost localipc buildexec`,' "${f}"; then
    pass "a span wider than the column runs over on a line of its own"
else
    fail "a span wider than the column was split or shared a line: $(grep -n 'selinux groups' "${f}")"
fi
# shellcheck disable=SC2016
if grep -qxF -- 'A span closing at this column stays: `ai-tools projects claim --yes .`' "${f}"; then
    pass "a span closing on the column stays on its line"
else
    fail "a span closing on the column was moved: $(grep -n 'closing at the column stays' "${f}")"
fi
# shellcheck disable=SC2016
if grep -qxF -- 'A span closing at this column shifts:' "${f}" \
        && [[ "$(grep -cxF -- '`ai-tools projects claim --yes .`' "${f}")" -eq 1 ]]; then
    pass "a span closing one column past it moves down whole"
else
    fail "a span closing one column past it was split or left: $(grep -n 'projects claim' "${f}")"
fi

# (7) The tree's own pages: every agent-facing page at 120 and every human-facing page at 79
# reflows to a state the gate passes, the checker finds complete, and a second run leaves alone.
if ! git -C "${ROOT}" rev-parse --show-toplevel >/dev/null 2>&1; then
    skip "real pages" "not a git checkout"
else
    real_pages() {  # real_pages <label> <width> <ls-files pattern...>
        local label="$1" width="$2"; shift 2
        local pages page base work
        mapfile -t pages < <(git -C "${ROOT}" ls-files "$@")
        base="${TESTDIR}/${label}-base"; work="${TESTDIR}/${label}-work"
        for page in "${pages[@]}"; do
            mkdir -p "${base}/$(dirname "${page}")" "${work}/$(dirname "${page}")"
            cp "${ROOT}/${page}" "${base}/${page}"; cp "${ROOT}/${page}" "${work}/${page}"
        done
        ( cd "${work}" && python3 "${FILLER}" --width "${width}" "${pages[@]}" >/dev/null )
        if ( cd "${work}" && python3 "${GATE}" --against "${base}" "${pages[@]}" >/dev/null 2>&1 ); then
            pass "${label}: ${#pages[@]} pages reflow at ${width} to a state the gate passes"
        else
            fail "${label}: the gate reports a page: $(cd "${work}" && python3 "${GATE}" --against "${base}" "${pages[@]}" 2>&1 | grep FAIL | head -2)"
        fi
        local over
        over="$(cd "${work}" && { python3 "${PC}" --wrap "${pages[@]}" 2>&1 | grep -c 'document-width' || true; })"
        if [[ "${over}" -eq 0 ]]; then
            pass "${label}: no measured line is left over its column"
        else
            fail "${label}: ${over} line(s) left over the column: $(cd "${work}" && python3 "${PC}" --wrap "${pages[@]}" 2>&1 | grep -A1 document-width | head -4)"
        fi
        cp -r "${work}" "${work}.once"
        ( cd "${work}" && python3 "${FILLER}" --width "${width}" "${pages[@]}" >/dev/null )
        if diff -r "${work}" "${work}.once" >/dev/null; then
            pass "${label}: a second run is a no-op"
        else
            fail "${label}: a second run changed a page: $(diff -r "${work}" "${work}.once" | head -4)"
        fi
    }
    real_pages agent 120 'CLAUDE.md' '*.rule.md' '*/skills/*.md' '*/orientation/*.md'
    real_pages human 79 'README.md' 'CONTRIBUTING.md' 'SECURITY.md' 'CODE_OF_CONDUCT.md' 'CHANGELOG.md' \
        'docs/*.md' 'selinux/*.md' 'packaging/*.md' 'tests/*.md' 'src/usr/share/ai-tools/subagents/*.md'
fi

# (8) A file that is not plain text is refused: reported with the reason and the line, left byte-identical, and the run
# exits 1 while the clean file named beside it is filled. Each shape is a way a rewrap would move what the formatter
# cannot see, or write where it did not read. The reader is `tools/formatters/text_file.py`, shared with the other
# formatters, so the set is pinned once here; the comment filler and the table aligner each pin one shape of it
# through their own
# front.
refused() {  # refused <label> <file> <reason>: <file> is refused with <reason> and left as it was
    local label="$1" file="$2" reason="$3" out rc=0
    [[ -f "${file}" ]] && cp "${file}" "${file}.before"
    cp "${TESTDIR}/base/f.md" "${f}"
    out="$(timeout 20 python3 "${FILLER}" --width "${WIDTH}" -- "${file}" "${f}" 2>&1)" || rc=$?
    if [[ "${rc}" -eq 1 ]] && grep -qF -- "fill-markdown: refused ${file}: ${reason}" <<<"${out}" \
            && { [[ ! -f "${file}" ]] || cmp -s "${file}" "${file}.before"; } \
            && ! cmp -s "${f}" "${TESTDIR}/base/f.md"; then
        pass "refused and left as it was: ${label}"
    else
        fail "not refused as expected (rc ${rc}): ${label}: ${out}"
    fi
}
printf 'a line with an escape sequence \033[31mred\033[0m in it\n' > "${TESTDIR}/escape.md"
printf 'a line with a NUL\0in it\n' > "${TESTDIR}/nul.md"
printf 'a CRLF line\r\nand another\r\n' > "${TESTDIR}/crlf.md"
printf 'a line with a bidi override \342\200\256 in it\n' > "${TESTDIR}/bidi.md"
printf 'a Latin-1 byte \351 in it\n' > "${TESTDIR}/latin1.md"
printf '\357\273\277a page opening with a byte-order mark\n' > "${TESTDIR}/bom.md"
printf 'a zero-width\342\200\213space\n' > "${TESTDIR}/zwsp.md"
printf 'a C1 control \302\233 in it\n' > "${TESTDIR}/c1.md"
ln -s "${TESTDIR}/base/f.md" "${TESTDIR}/link.md"
mkfifo "${TESTDIR}/fifo.md"
refused "an escape sequence"       "${TESTDIR}/escape.md" "line 1 holds U+001B (a control character)"
refused "a NUL byte"               "${TESTDIR}/nul.md"    "holds a NUL byte at offset 17, so it is not text"
refused "a carriage return"        "${TESTDIR}/crlf.md"   "line 1 holds a carriage return"
refused "a bidi override"          "${TESTDIR}/bidi.md"   "line 1 holds U+202E (RIGHT-TO-LEFT OVERRIDE)"
refused "a byte that is not UTF-8" "${TESTDIR}/latin1.md" "is not UTF-8 at byte 15 (line 1)"
refused "a byte-order mark"        "${TESTDIR}/bom.md"    "opens with a byte-order mark"
refused "a zero-width space"       "${TESTDIR}/zwsp.md"   "line 1 holds U+200B (ZERO WIDTH SPACE)"
refused "a C1 control"             "${TESTDIR}/c1.md"     "line 1 holds U+009B (a control character)"
refused "a symlink"                "${TESTDIR}/link.md"   "is a symlink"
refused "a FIFO"                   "${TESTDIR}/fifo.md"   "is not a regular file"

# (9) A column under one, and a range out of order, at line 0, or not a number, are usage errors: exit 2, and nothing
# written.
usage_error() {  # usage_error <label> <argument>...: exit 2, the fixture untouched
    local label="$1" rc=0
    shift
    cp "${TESTDIR}/base/f.md" "${f}"
    python3 "${FILLER}" "$@" -- "${f}" >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq 2 ]] && cmp -s "${f}" "${TESTDIR}/base/f.md"; then
        pass "usage error, nothing written: ${label}"
    else
        fail "usage error not raised (rc ${rc}): ${label}"
    fi
}
usage_error "a column of 0"           --width 0
usage_error "a range out of order"    --width "${WIDTH}" --lines 5-3
usage_error "a range at line 0"       --width "${WIDTH}" --lines 0
usage_error "a range that is not one" --width "${WIDTH}" --lines 3-x

# (10) The gate reads both copies through the same reader, and confines a path to the tree and to the base directory:
# a base copy that is not plain text fails with the reason and no token of it is printed, and a path resolving outside
# the tree is refused rather than read.
mkdir -p "${TESTDIR}/base2"
printf 'a token \033[31mred\033[0m here\n' > "${TESTDIR}/base2/g.md"
printf 'a token red here\n' > "${TESTDIR}/g.md"
rc=0; OUT="$(cd "${TESTDIR}" && python3 "${GATE}" --against "${TESTDIR}/base2" g.md 2>&1)" || rc=$?
if [[ "${rc}" -eq 1 ]] && grep -q 'FAIL g.md: refused, line 1 holds U+001B' <<<"${OUT}" \
        && ! grep -q 'red' <<<"${OUT}"; then
    pass "the gate fails a base copy that is not plain text, printing no token of it"
else
    fail "the gate read the base copy (rc ${rc}): ${OUT}"
fi
rc=0; OUT="$(cd "${TESTDIR}/base" && python3 "${GATE}" --against "${TESTDIR}/base2" ../g.md 2>&1)" || rc=$?
if [[ "${rc}" -eq 1 ]] && grep -q 'FAIL ../g.md: refused, resolves outside' <<<"${OUT}"; then
    pass "the gate refuses a path resolving outside the tree"
else
    fail "the gate read outside the tree (rc ${rc}): ${OUT}"
fi

finish

#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# ref-index.py -- the cross-reference tool for the reftags the skill's "A reference names a reftag,
# not a position" section defines. It ships beside the SKILL.md stating the grammar, versioned
# with it, and it does not carry a repository path: the files to read and the index to write
# are arguments.
#
# Seeded assets are mode 640, so run it through its interpreter:
#
#     python3 /opt/ai-tools/skills/ai-tools-technical-docs/ref-index.py <command> ...
#
# A REFTAG is a prefix, a dash, and an ID of the form letter, digit, letter, digit (`c8b2`;
# 67,600 of them), which keeps a plain word or number out of the id position. `new` draws from
# the 33,856 whose every character is unmistakable (MINT_LETTERS, MINT_DIGITS): an id is read
# aloud, retyped, and grepped, and `1` beside `l` or `0` beside `O` costs a search that misses
# its target. Every one of the 67,600 stays VALID, so an id minted before this narrowing, or by
# hand, is a well-formed id. The id is drawn
# at random, so a reader does not read an order into it, and one id names one thing
# across ALL families, whatever the prefix; two things are never related by sharing an id.
# A match is always the full reftag, prefix and dash included, with a word boundary on each
# side: an id alone, or a dash and an id, is a shape generated names and key material take
# too. Two cases. Lowercase names a place in a document, by its kind, and renders
# as a link: `ref-section-g3g4`, `ref-table-z4m9`,
# `ref-diagram-u2s6`, `ref-listing-u7y5` (the kinds are PROSE_KINDS, and `kinds` prints them).
# UPPERCASE names a key living in code, in output, or in a registry, found by a search
# on the token: `FN-Q2H8` (a function doc), `NOTE-A5H9` (a comment note), `MSG-F6Z3` (a runtime
# message), `URI-Q4Q6` (a resource identifier). Every prefix ends in a dash, so a search
# for the prefix cannot run into the id.
#
# A TARGET is where the referent lives, and its current location is discovered on every run:
#
#   heading        a heading closed by an anchor: `## Two project models <a id="ref-section-b8e6"></a>`
#   caption        an anchor and a bold caption on the line before the block it names:
#                  `<a id="ref-table-z4m9"></a>**Altitudes and who owns which fact**`; a table
#                  is followed by a table row, a listing by a fence, any other kind by a block
#   FN, NOTE       a source line carrying the token, a colon, and the name: `# FN-Q2H8: chown_path`
#   MSG            the emit call: the token, then the quoted message it labels,
#                  `die MSG-F6Z3 "not a claimed project"`; the name is the message's first line,
#                  and the word before the token is recorded as the emitter. A quoted string that
#                  opens with an expansion (`"$out"`) does not name a message, so that site is a
#                  reference, which is how a test cites a code beside the output it captured
#   URI            one Markdown link definition line: `[URI-Q4Q6]: https://example.invalid "name"`
#
# A REFERENCE in a document is the inline link `[ref-section-p7r3](../x.md#ref-section-p7r3)`.
# The link text is the reftag and the parenthesised DESTINATION is generated: the path, relative
# to the citing file, plus the anchor for a document target; the file alone for a code target
# (a line fragment would change on every edit); and the URI for a URI. `check` compares every
# destination with where the target now is, and `relink` rewrites it. A reference in a source
# file is the bare token.
#
# A reftag exists for a citation from ANOTHER file. Within one file a section is cited by its
# title as a jump link, `[Title](#its-slug)`, since a reader takes the file in one pass
# and a reftag inside it is a detour, so `check` reports a same-file reftag reference
# and `relink` leaves it as written. A jump link whose heading has left the file is reported
# with the hint to cite the reftag, which is how a file reconciles a section that moved out.
# The index's "cited by" column is empty for a reftag no file cites, which is how an uncited
# one is seen.
#
# A fenced block and a backticked span are not read as targets or references: a document
# stating the grammar shows reftags it does not define. A reftag seen ONLY there is an EXAMPLE,
# and is indexed as one, so its id stays reserved and a real reftag never takes it. A line
# carrying `ref-index: ignore` is not read either, and a file carrying `ref-index: ignore-file`
# as a whole comment line is not read at all, which is how a test file holds its fixtures; `new`
# still reads every file raw, so an id in a fixture is reserved too.
#
# WHEN A FINDING IS THE DEFECT, REPORT IT. A finding that names a shape this grammar allows, or
# whose hint sends a reader to the wrong remedy, is a bug here rather than in the tree. Measure it
# and propose the change to this tool and to the SKILL.md grammar together; see that file's "When
# the tool is the defect".
#
# A reftag that leaves the tree is RETIRED, never freed: `retire` moves each index row whose
# target is gone into a second file, with the date, and `new` draws against that file too. A
# message code lands in a durable audit trail, so an id re-minted for another situation would
# make an old journal line resolve to the wrong one. `check --retired` reports a retired reftag
# defined again as `resurrected`.
#
# Commands:
#
#   generate FILE... [--out PATH]   the index: one row per target or example (id, reftag
#                                   as a link, name, file, cited by, emitter), sorted by file
#                                   and position. The id is the first column, so a search
#                                   for it reads a fixed place on every line. No line numbers:
#                                   a stored one changes on every edit earlier in the file.
#                                   `--at` names the path the links are computed from; a copy
#                                   written elsewhere is then compared with the committed one.
#   retire FILE... --index --retired  append to the retired file each index row whose reftag
#        [--release VERSION]        the files no longer define, dated and stamped with the
#                                   release given; run before `generate`, which is stateless
#                                   and would drop the row without a trace
#   kinds                           the registry: each kind and code family, its reftag form,
#                                   and what it names, so a writer picks one without reading
#                                   this file
#   new FAMILY [FILE...] [--index]  a fresh reftag, its id unique against the index, the
#        [--retired]                retired file, and every token in the files given.
#                                   `--count N` prints N of them, distinct from each other
#                                   too, since a mint is recorded nowhere and separate calls
#                                   draw against the same set until the first is written
#   where TOKEN [FILE...] [--index] the target's live `file:line` and the lines it spans
#   relink FILE...                  rewrite every destination in the Markdown files given
#   check FILE... [--retired]       report a duplicate reftag or id, an undefined or same-file
#                                   reference, a misplaced anchor, a caption with no block
#                                   following it, a destination that is missing or stale,
#                                   a relative link whose file or heading is gone, and a
#                                   retired reftag defined again; exit 1 on any report

import argparse
import datetime
import os
import re
import secrets
import string
import sys

# The registry of document kinds: what a lowercase reftag may name, and what each kind is.
# The skill names this registry and does not copy it; `kinds` prints it.
PROSE_KINDS = {
    "section": "hierarchical division of the document: chapter, section, subsection",
    "table": "tabular arrangement of data in rows and columns, usually captioned",
    "diagram": "visual schematic of concepts, structures, relationships, or processes",
    "listing": "code block, source snippet, or plain pseudocode listing",
    "figure": "numbered floating container for visual material: diagrams, images, charts",
    "equation": "mathematical formula or expression, typically numbered",
    "algorithm": "numbered formal presentation of an algorithm or structured pseudocode",
    "chart": "graphical data visualization: bar, pie, line, or area chart",
    "graph": "plot showing relationships or data points",
    "image": "raster or vector visual: photograph, illustration, screenshot, rendering",
    "picture": "illustrative or photographic image, a type of figure",
    "scheme": "sequential or process-oriented visual, as in chemistry and engineering",
    "theorem": "formal mathematical or logical statement",
    "lemma": "supporting proposition proved for use in a larger theorem",
    "definition": "formal definition of a term or concept",
    "proof": "structured demonstration of a theorem, lemma, or proposition",
    "appendix": "supplementary material after the main body of the document",
    "footnote": "ancillary note at the bottom of the page",
    "caption": "descriptive title or explanation accompanying a figure, table, or similar element",
    "list": "ordered, unordered, or definition-style enumeration of items",
    "callout": "highlighted box or sidebar for notes, tips, warnings, or important remarks",
    "abstract": "concise summary of the document's content and contributions",
    "bibliography": "list of cited references and sources",
    "nomenclature": "list of symbols, abbreviations, units, or notation used in the document",
}
CODE_FAMILIES = {
    "fn": ("FN-", "a function's doc comment, in a source file"),
    "note": ("NOTE-", "a comment note, in a source file"),
    "msg": ("MSG-", "a runtime message, inside the string a program emits"),
    "uri": ("URI-", "a resource identifier, defined once on a Markdown link definition line"),
}
CODE_KINDS = ("FN", "NOTE", "MSG")
FAMILIES = {kind: f"ref-{kind}-" for kind in PROSE_KINDS}
FAMILIES.update({family: prefix for family, (prefix, _) in CODE_FAMILIES.items()})
# The id form, in each case: an uppercase family's id is the same shape in capitals,
# and the two compare equal once lowercased.
LOWER_ID = r"[a-z][0-9][a-z][0-9]"
UPPER_ID = r"[A-Z][0-9][A-Z][0-9]"
# What `new` DRAWS from, which is narrower than what the two forms ACCEPT: `i`, `l`, `o` and the
# digits they read as are left out, so a minted id survives being read aloud, retyped, or grepped
# from a screenshot. 23 x 8 x 23 x 8 = 33,856 of the 67,600, and an id already in the tree that
# uses a dropped character stays valid: the narrowing applies to the draw, and the two id forms
# accept exactly what they accepted before.
MINT_LETTERS = "abcdefghjkmnpqrstuvwxyz"
MINT_DIGITS = "23456789"
# Redraws before an id space is called exhausted. Far past the point where the tree's reftags
# could crowd 33,856 ids, so reaching it means the form is too small rather than the draw unlucky.
MINT_ATTEMPTS = 10000

PROSE_TOKEN = r"ref-(?:" + "|".join(PROSE_KINDS) + r")-" + LOWER_ID
URI_TOKEN = r"URI-" + UPPER_ID
CODE_TOKEN = r"(?:" + "|".join(CODE_KINDS) + r")-" + UPPER_ID
TOKEN = re.compile(rf"(?<![\w-])({PROSE_TOKEN}|{URI_TOKEN}|{CODE_TOKEN})(?![\w-])")
RAW_TOKEN = re.compile(rf"(?<![\w-])(?:{PROSE_TOKEN}|{URI_TOKEN}|{CODE_TOKEN})(?![\w-])",
                       re.I)

ANCHOR = re.compile(rf'<a id="({PROSE_TOKEN})"></a>')
HEADING_TARGET = re.compile(rf'^(#{{1,6}})\s+(.*?)\s*<a id="({PROSE_TOKEN})"></a>\s*$')
CAPTION_TARGET = re.compile(rf'^\s*<a id="({PROSE_TOKEN})"></a>\s*\*\*(.+?)\*\*\s*$')
URI_TARGET = re.compile(rf'^\s*\[({URI_TOKEN})\]:\s*(\S+)(?:\s+"(.*)")?\s*$')
CODE_TARGET = re.compile(rf"((?:FN|NOTE)-{UPPER_ID}):[ \t]+(.*)")
# A message target is the emit call: the token, then the quoted message it labels. The name is
# the message's first line, so a string opening with an expansion does not name a message and
# its site reads as a reference; the word before the token is the emitter, recorded for the index.
MSG_TARGET = re.compile(rf"(MSG-{UPPER_ID})[ \t]+(['\"])(?!\$)(.*)")
EMITTER = re.compile(r"([\w.-]+)\s*$")
LINK_SITE = re.compile(rf"\[({PROSE_TOKEN}|{URI_TOKEN}|{CODE_TOKEN})\]\(([^)]*)\)")
BARE_SITE = re.compile(rf"\[({PROSE_TOKEN}|{URI_TOKEN}|{CODE_TOKEN})\]")

FENCE = re.compile(r"^\s*(```|~~~)")
BACKTICK_SPAN = re.compile(r"`[^`]*`")
TABLE_ROW = re.compile(r"^\s*\|")
HEADING = re.compile(r"^(#{1,6})\s")
COMMENT_LINE = re.compile(r"^\s*(#|//|/\*|\*|--|;|<!--|\"\"\")")
BASH_FUNCTION = re.compile(r"^\s*(?:function\s+)?[A-Za-z_][\w-]*\s*\(\)\s*\{?\s*$|^\s*function\s+\w+")
# An index or retired-file row: the id, the reftag (linked or bare), then the remaining cells.
INDEX_ROW = re.compile(r"^\|\s*(" + LOWER_ID + r")\s*\|\s*(?:\[([^\]]+)\]\([^)]*\)|(\S+))\s*\|(.*)\|\s*$")
MARKDOWN = (".md",)
# The line marker is read outside a backticked span, and the file marker only as the whole
# content of a comment line, so a document describing the markers is still read.
IGNORE_LINE = "ref-index: ignore"
IGNORE_FILE = re.compile(r"^\s*(?:#|//|<!--|;|--)?\s*ref-index: ignore-file\s*(?:-->)?\s*$")
EXAMPLE = "example"

INDEX_HEADER = """# Cross-reference index

Generated by `ref-index.py generate` from the tree; regenerate it, do not edit it. The first
column is the id alone, so a search for it reads a fixed place on every line; a reftag resolves
here to its name, its file, and the files that cite it, and `ref-index.py where <reftag>` prints
the live line. A row named `example` reserves an id a document shows without defining it. The
emitter column carries, for a message code, the word that emits it.

<!-- prose-check: ignore-file -->
Each name is copied from the target it indexes, so a writing finding here names prose this file
cannot fix -- a message code's name is a runtime string, and rewording one is a code change.

| Id | Reftag | Name | File | Cited by | Emitter |
|---|---|---|---|---|---|
"""

RETIRED_HEADER = """# Retired cross-references

Written by `ref-index.py retire`: each row is a reftag the index held and the tree no longer
defines, with the date it was retired and the release the tree was at, so a row's age is counted
in releases. The minter reads it, so an id that reached a log line or a document is never drawn
again, and an old line still resolves to what it named. History, not current state: a session
does not read it.

<!-- prose-check: ignore-file -->
Its names are copied from the targets the tree once held, like the index beside it.

| Id | Reftag | Name | File | Cited by | Emitter | Removed | Release |
|---|---|---|---|---|---|---|---|
"""

# A document's own navigation -- a contents line, a jump to one of its sections -- and its links
# to other files are ordinary Markdown links, `[text](#slug)` and `[text](path#slug)`, and do
# not take a reftag: the text is the title, and the slug is the one the renderer derives
# from the heading. `check` verifies each one resolves, since a renamed heading breaks
# a contents line silently. The slug rule is GitHub's: lowercase, punctuation dropped, spaces
# to hyphens, a repeated slug numbered. An explicit `<a id="x">` or `<a name="x">` is an anchor
# too.
INLINE_LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HTML_ANCHOR = re.compile(r'<a\s+(?:id|name)="([^"]+)"')
HTML_TAG = re.compile(r"<[^>]+>")
_anchor_cache = {}


class Target:
    __slots__ = ("reftag", "name", "path", "line", "url", "example", "emitter")

    def __init__(self, reftag, name, path, line, url=None, example=False, emitter=""):
        self.reftag, self.name, self.path, self.line = reftag, name, path, line
        self.url, self.example, self.emitter = url, example, emitter


def message_name(quote, rest):
    """The message's first line: the text up to the quote that closes it, or the whole rest."""
    end = rest.find(quote)
    return (rest if end < 0 else rest[:end]).strip()


def is_markdown(path):
    return path.endswith(MARKDOWN)


def family_of(reftag):
    """`ref-table-z4m9` -> `table`, `URI-Q4Q6` -> `URI`, `FN-Q2H8` -> `FN`."""
    parts = reftag.split("-")
    return parts[1] if parts[0] == "ref" else parts[0]


def id_of(reftag):
    return reftag.rsplit("-", 1)[1].lower()


def read_lines(path):
    """The lines of `path`, or None with a message on stderr when it cannot be read."""
    try:
        with open(path, errors="ignore") as handle:
            return handle.read().splitlines()
    except OSError as exc:
        print(f"ref-index: cannot read {path}: {exc}", file=sys.stderr)
        return None


def ignored_file(lines):
    return any(IGNORE_FILE.match(line) for line in lines)


def readable_lines(path, lines, blank_spans=True):
    """Yield (line number, line) outside a fenced block, backticked spans blanked by default.

    A fence is a Markdown construct, so only a document toggles on one; a source file's every
    line is read. A heading slug keeps the text of a span, so the slug reader asks for the raw
    line.
    """
    if ignored_file(lines):
        return
    fenced = False
    for number, line in enumerate(lines, 1):
        if is_markdown(path) and FENCE.match(line):
            fenced = not fenced
            continue
        blanked = BACKTICK_SPAN.sub(" ", line)
        if not fenced and IGNORE_LINE not in blanked:
            yield number, blanked if blank_spans else line


def quoted_tokens(path, lines):
    """Yield (line number, reftag) for each token inside a fenced block or a backticked span."""
    if ignored_file(lines):
        return
    fenced = False
    for number, line in enumerate(lines, 1):
        if is_markdown(path) and FENCE.match(line):
            fenced = not fenced
            continue
        spans = [line] if fenced else BACKTICK_SPAN.findall(line)
        for span in spans:
            for match in TOKEN.finditer(span):
                yield number, match.group(1)


def target_name(pattern, group, lines, number, blanked):
    """The name `pattern` captures, read from the raw line so a backticked span keeps its text.

    A span is blanked before a target is matched, so that a reftag shown in backticks is not read
    as one; the name is what the heading or caption says, and `` `SANDBOX_USER` `` is part of it.
    """
    raw = pattern.match(lines[number - 1])
    return (raw.group(group) if raw else blanked).strip()


def followed_by_block(lines, number, kind):
    """Whether the first non-blank line after line `number` opens the block the kind names."""
    for line in lines[number:]:
        if line.strip():
            if kind == "table":
                return bool(TABLE_ROW.match(line))
            if kind == "listing":
                return bool(FENCE.match(line))
            return True
    return False


def scan(paths):
    """Discover every target, example, and reference in the paths.

    Returns (targets by reftag, duplicates, references, misplaced anchors), where an example
    is a target flagged as one, and a reference is (path, line number, reftag, destination
    or None, whether the site is a document link).
    """
    targets, duplicates, references, misplaced, quoted = {}, [], [], [], []
    for path in paths:
        lines = read_lines(path)
        if lines is None:
            continue
        quoted.extend((path, number, reftag) for number, reftag in quoted_tokens(path, lines))
        for number, text in readable_lines(path, lines):
            found = []
            if is_markdown(path):
                heading = HEADING_TARGET.match(text)
                caption = CAPTION_TARGET.match(text)
                uri = URI_TARGET.match(text)
                if heading:
                    found.append(Target(heading.group(3), target_name(
                        HEADING_TARGET, 2, lines, number, heading.group(2)), path, number))
                elif caption:
                    found.append(Target(caption.group(1), target_name(
                        CAPTION_TARGET, 2, lines, number, caption.group(2)), path, number))
                    if not followed_by_block(lines, number, family_of(caption.group(1))):
                        misplaced.append((path, number, caption.group(1)))
                elif uri:
                    found.append(Target(uri.group(1), uri.group(3) or uri.group(2), path, number,
                                        url=uri.group(2)))
                for anchor in ANCHOR.finditer(text):
                    if not (heading or caption):
                        misplaced.append((path, number, anchor.group(1)))
                text = "" if uri else ANCHOR.sub(" ", text)
                for site in LINK_SITE.finditer(text):
                    references.append((path, number, site.group(1), site.group(2), True))
                text = LINK_SITE.sub(" ", text)
                for site in BARE_SITE.finditer(text):
                    references.append((path, number, site.group(1), None, True))
                text = BARE_SITE.sub(" ", text)
                for site in TOKEN.finditer(text):
                    references.append((path, number, site.group(1), None, True))
            else:
                for match in MSG_TARGET.finditer(text):
                    emitter = EMITTER.search(text[:match.start()])
                    found.append(Target(match.group(1), message_name(match.group(2), match.group(3)),
                                        path, number, emitter=emitter.group(1) if emitter else ""))
                text = MSG_TARGET.sub(" ", text)
                for match in CODE_TARGET.finditer(text):
                    name = match.group(2).strip().rstrip("\\\"' ")
                    found.append(Target(match.group(1), name, path, number))
                text = CODE_TARGET.sub(" ", text)
                for site in TOKEN.finditer(text):
                    references.append((path, number, site.group(1), None, False))
            for target in found:
                if target.reftag in targets:
                    duplicates.append((path, number, target.reftag, targets[target.reftag]))
                else:
                    targets[target.reftag] = target
    cited = {reftag for _, _, reftag, _, _ in references}
    for path, number, reftag in quoted:
        if reftag not in targets and reftag not in cited:
            targets[reftag] = Target(reftag, EXAMPLE, path, number, example=True)
    return targets, duplicates, references, misplaced


def duplicate_ids(targets):
    """Yield (target, earlier target) for each id shared by two reftags of different kinds."""
    by_id = {}
    for target in sorted(targets.values(), key=lambda t: (t.path, t.line)):
        earlier = by_id.setdefault(id_of(target.reftag), target)
        if earlier is not target:
            yield target, earlier


def destination(citing_path, target):
    """The parenthesised destination a reference in `citing_path` carries for `target`."""
    if target.url is not None:
        return target.url
    fragment = f"#{target.reftag}" if family_of(target.reftag) in PROSE_KINDS else ""
    if os.path.normpath(citing_path) == os.path.normpath(target.path):
        return fragment
    relative = os.path.relpath(target.path, os.path.dirname(citing_path) or ".")
    return relative + fragment


def same_file_detour(citing_path, target):
    """Whether citing `target` from `citing_path` is a reftag pointing into its own document."""
    return (family_of(target.reftag) in PROSE_KINDS
            and os.path.normpath(citing_path) == os.path.normpath(target.path))


def span(lines, target):
    """How many lines the target covers, by the syntax of its kind."""
    start = target.line - 1
    family = family_of(target.reftag)
    if family == "URI" or target.example:
        return 1
    # A `#` comment in a source file looks like a heading, so the heading rule is read
    # for a document target only.
    if family in PROSE_KINDS and HEADING.match(lines[start]):
        level = len(HEADING.match(lines[start]).group(1))
        for offset, line in enumerate(lines[start + 1:], 1):
            match = HEADING.match(line)
            if match and len(match.group(1)) <= level:
                return offset
        return len(lines) - start
    if family in PROSE_KINDS:
        fenced, count = False, 1
        for line in lines[start + 1:]:
            count += 1
            if FENCE.match(line):
                if fenced:
                    return count
                fenced = True
            elif not fenced and not line.strip() and count > 2:
                return count - 1
        return count
    if family == "MSG":
        count = 1
        for line in lines[start:]:
            if not line.rstrip().endswith("\\"):
                return count
            count += 1
        return count
    end = start
    while end + 1 < len(lines) and COMMENT_LINE.match(lines[end + 1]):
        end += 1
    if family == "FN" and end + 1 < len(lines) and BASH_FUNCTION.match(lines[end + 1]):
        for offset, line in enumerate(lines[end + 1:], end + 1):
            if line.startswith("}"):
                return offset - start + 1
    return end - start + 1


def slug(text):
    """GitHub's heading slug for `text`, before the numbering of a repeat."""
    text = HTML_TAG.sub("", text).strip().lower()
    text = re.sub(r"[^\w\s-]", "", text.replace("`", ""))
    return re.sub(r"\s", "-", text)


def anchors_of(path):
    """Every fragment a link into `path` may carry: heading slugs and explicit anchors."""
    if path in _anchor_cache:
        return _anchor_cache[path]
    found, seen = set(), {}
    lines = read_lines(path) or []
    for _, text in readable_lines(path, lines, blank_spans=False):
        heading = HEADING.match(text)
        if heading:
            base = slug(text[heading.end():])
            found.add(base if base not in seen else f"{base}-{seen[base]}")
            seen[base] = seen.get(base, 0) + 1
        found.update(HTML_ANCHOR.findall(text))
    _anchor_cache[path] = found
    return found


def link_findings(paths):
    """Yield (path, line, target, reason) for each relative link that does not resolve."""
    for path in paths:
        if not is_markdown(path):
            continue
        lines = read_lines(path)
        if lines is None:
            continue
        for number, text in readable_lines(path, lines):
            text = LINK_SITE.sub(" ", text)
            for match in INLINE_LINK.finditer(text):
                target = match.group(1)
                if "://" in target or target.startswith(("mailto:", "/", "<")):
                    continue
                file_part, _, fragment = target.partition("#")
                resolved = path if not file_part else os.path.normpath(
                    os.path.join(os.path.dirname(path) or ".", file_part))
                if file_part and not os.path.exists(resolved):
                    yield path, number, target, f"{resolved} does not exist"
                elif fragment and is_markdown(resolved) and fragment not in anchors_of(resolved):
                    hint = ("; if the section moved to another file, cite its reftag"
                            if not file_part else "")
                    yield path, number, target, f"no heading or anchor #{fragment} in {resolved}{hint}"


def read_index(path):
    """{reftag: (id, name, file, cited by, ...)} from an index or a retired file: the row's cells
    after the reftag, in order, so a retired row carries its date last. None when unreadable."""
    lines = read_lines(path)
    if lines is None:
        return None
    entries = {}
    for row in map(INDEX_ROW.match, lines):
        if row:
            cells = [cell.strip() for cell in row.group(4).split("|")]
            entries[row.group(2) or row.group(3)] = (row.group(1), *cells)
    return entries


def read_retired(path):
    """{reftag: row} from the retired file, or an empty dict when the path is unset or absent."""
    if not path or not os.path.exists(path):
        return {}
    return read_index(path) or {}


def command_generate(args):
    targets, _, references, _ = scan(args.paths)
    cited = {}
    for path, _, reftag, _, _ in references:
        cited.setdefault(reftag, set()).add(path)
    index_path = args.at or args.out or "references.md"
    rows = []
    for target in sorted(targets.values(), key=lambda t: (t.path, t.line)):
        shown = (target.reftag if target.example
                 else f"[{target.reftag}]({destination(index_path, target)})")
        rows.append(f"| {id_of(target.reftag)} | {shown} | {target.name} | {target.path} "
                    f"| {', '.join(sorted(cited.get(target.reftag, ())))} | {target.emitter} |")
    text = INDEX_HEADER + "".join(row + "\n" for row in rows)
    if args.out:
        with open(args.out, "w") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    return 0


def command_retire(args):
    """Append to the retired file each index row whose reftag the files no longer define.

    Reads the committed index rather than the tree's last state, so it runs before `generate`
    rewrites the index; a row already retired is left as it is, and the file is created with
    its header on the first retirement.
    """
    entries = read_index(args.index)
    if entries is None:
        return 2
    targets = scan(args.paths)[0]
    retired = read_retired(args.retired)
    today = datetime.date.today().isoformat()
    rows = []
    for reftag, cells in entries.items():
        if reftag in targets or reftag in retired:
            continue
        # The index row's cells after the id, restored to the index's column count; a row from an
        # older index without the emitter column takes an empty one.
        body = list(cells[1:]) + [""] * (4 - len(cells[1:]))
        rows.append(f"| {cells[0]} | {reftag} | {' | '.join(body[:4])} | {today} | {args.release} |")
        print(f"retired {reftag} ({cells[1]}) from {cells[2]}")
    if not rows:
        return 0
    text = "" if os.path.exists(args.retired) else RETIRED_HEADER
    with open(args.retired, "a") as handle:
        handle.write(text + "".join(row + "\n" for row in rows))
    return 0


def command_kinds(args):
    """Print the registry: each kind and code family, its reftag form, and what it names."""
    width = max(map(len, FAMILIES))
    for kind, description in PROSE_KINDS.items():
        print(f"{kind:<{width}}  {FAMILIES[kind]}<id>  {description}")
    for family, (prefix, description) in CODE_FAMILIES.items():
        print(f"{family:<{width}}  {prefix}<ID>  {description}")
    return 0


def fresh_id(taken):
    """An id of the form letter, digit, letter, digit that none of `taken` already uses.

    `secrets.choice` draws each character from a system CSPRNG, without the modulo bias a
    remainder of a random integer would carry. Redrawing is what keeps the id unique, so the
    attempts are bounded: an id space this one cannot draw from is REPORTED rather than spun on.
    """
    for _ in range(MINT_ATTEMPTS):
        drawn = "".join(secrets.choice(alphabet) for alphabet in
                        (MINT_LETTERS, MINT_DIGITS, MINT_LETTERS, MINT_DIGITS))
        if drawn not in taken:
            return drawn
    return None


def command_new(args):
    prefix = FAMILIES.get(args.family.lower())
    if not prefix:
        print(f"ref-index: {args.family} is not a kind or a code family; `kinds` lists them",
              file=sys.stderr)
        return 2
    if args.count < 1:
        print(f"ref-index: --count is how many reftags to print, so it is 1 or more, "
              f"not {args.count}", file=sys.stderr)
        return 2
    taken = set()
    if os.path.exists(args.index):
        taken.update(entry[0] for entry in (read_index(args.index) or {}).values())
    # A retired id stays taken: an old log line or document still names it.
    taken.update(entry[0] for entry in read_retired(args.retired).values())
    # Every token in every file, raw: an id in a fixture, a fence, or a span is reserved too.
    for path in args.paths:
        for line in read_lines(path) or []:
            taken.update(id_of(match.group(0)) for match in RAW_TOKEN.finditer(line))
    # Each id joins the taken set as it is drawn, so one call's reftags differ from each other as
    # well as from the tree's. Minting a batch and writing it afterwards is then safe: the command
    # does not record an id, so ids drawn by separate calls are only distinct once the first is
    # written.
    minted = []
    for _ in range(args.count):
        drawn = fresh_id(taken)
        if drawn is None:
            print(f"ref-index: no free id left after {MINT_ATTEMPTS} draws against "
                  f"{len(taken)} taken; widen the id form before minting more", file=sys.stderr)
            return 1
        taken.add(drawn)
        minted.append(prefix + (drawn.upper() if prefix.isupper() else drawn))
    # Printed once the whole batch is drawn, so a run that cannot complete does not print a reftag
    # for a writer to place: the mint is recorded nowhere, and a half-batch reads as a whole one.
    print("\n".join(minted))
    return 0


def command_where(args):
    reftag = args.token
    if not TOKEN.fullmatch(reftag):
        print(f"ref-index: {reftag} is not a reftag", file=sys.stderr)
        return 2
    if args.paths:
        targets = scan(args.paths)[0]
    else:
        entries = read_index(args.index)
        if entries is None:
            return 2
        if reftag not in entries:
            print(f"ref-index: {reftag} is not in {args.index}; regenerate the index",
                  file=sys.stderr)
            return 1
        targets = scan([entries[reftag][2]])[0]
    target = targets.get(reftag)
    if target is None:
        print(f"ref-index: {reftag} has no target; regenerate the index", file=sys.stderr)
        return 1
    lines = read_lines(target.path) or []
    print(f"{target.path}:{target.line} ({span(lines, target)} lines) {target.name}")
    return 0


def command_relink(args):
    targets = scan(args.paths)[0]
    for path in args.paths:
        if not is_markdown(path):
            continue
        lines = read_lines(path)
        if lines is None or ignored_file(lines):
            continue
        changed, fenced, out = False, False, []
        for line in lines:
            if FENCE.match(line):
                fenced = not fenced
            if fenced or FENCE.match(line):
                out.append(line)
                continue

            def rewrite(match):
                target = targets.get(match.group(1))
                # An undefined, example, or same-file reftag is a `check` finding, left as written.
                if target is None or target.example or same_file_detour(path, target):
                    return match.group(0)
                return f"[{match.group(1)}]({destination(path, target)})"

            # A bare `[reftag]` is given its destination; a `[reftag](...)` has it rewritten.
            # The bare form is matched only where no `(` follows, so a link is not rewritten
            # twice.
            new = LINK_SITE.sub(rewrite, line)
            new = re.sub(BARE_SITE.pattern + r"(?!\()", rewrite, new)
            changed = changed or new != line
            out.append(new)
        if changed:
            with open(path, "w") as handle:
                handle.write("\n".join(out) + "\n")
            print(f"relinked {path}")
    return 0


def command_check(args):
    targets, duplicates, references, misplaced = scan(args.paths)
    count = 0
    for path, number, reftag, first in duplicates:
        count += 1
        # Three remedies, because a repeat is as often deliberate as it is a mistake: a fixture
        # DRIVING an emitter carries the definition shape without defining anything, and a message
        # two processes must both emit is one situation that shares one code.
        print(f"{path}:{number}: duplicate [{reftag}] -- also defined at {first.path}:{first.line}; "
              f"mint a fresh reftag with `new`, mark a test fixture `ref-index: ignore`, "
              f"or emit a deliberate twin's code from a format string so it reads as a citation")
    for target, earlier in duplicate_ids(targets):
        count += 1
        print(f"{target.path}:{target.line}: duplicate-id [{target.reftag}] -- the id is "
              f"{earlier.reftag} at {earlier.path}:{earlier.line}; an id is unique across kinds")
    for path, number, reftag in misplaced:
        count += 1
        print(f"{path}:{number}: misplaced [{reftag}] -- an anchor closes a heading line, or "
              f"opens a bold caption on the line before the block it names")
    retired = read_retired(args.retired)
    for target in sorted(targets.values(), key=lambda t: (t.path, t.line)):
        if target.reftag in retired and not target.example:
            count += 1
            print(f"{target.path}:{target.line}: resurrected [{target.reftag}] -- retired as "
                  f"{retired[target.reftag][1]!r}; a retired id stays taken, so mint a fresh "
                  f"reftag with `new`")
    for path, number, reftag, link, in_document in references:
        target = targets.get(reftag)
        if target is None or target.example:
            count += 1
            print(f"{path}:{number}: undefined [{reftag}] -- no target defines it; label the "
                  f"referent, or delete the reference")
            continue
        if not in_document:
            continue
        # A URI's definition line is not rendered, so citing it from its own file is not
        # a detour; the same-file rule is for a place in the document.
        if same_file_detour(path, target):
            count += 1
            print(f"{path}:{number}: same-file [{reftag}] -- a reftag is for another file; cite "
                  f"the section by its title: [{target.name}](#{slug(target.name)})")
            continue
        expected = destination(path, target)
        if link is None:
            count += 1
            print(f"{path}:{number}: missing [{reftag}] -- write [{reftag}]({expected})")
        elif link.strip() != expected:
            count += 1
            print(f"{path}:{number}: stale [{reftag}] -- the target is at {target.path}; write "
                  f"[{reftag}]({expected}), or run `relink`")
    for path, number, target, reason in link_findings(args.paths):
        count += 1
        print(f"{path}:{number}: link [{target}] -- {reason}")
    if count:
        print(f"\n{count} finding(s). See the ai-tools-technical-docs skill.")
    return 1 if count else 0


def main():
    parser = argparse.ArgumentParser(description="index and check cross-reference reftags")
    commands = parser.add_subparsers(dest="command", required=True)
    index_help = "the index file (default: .claude/references.md)"

    generate = commands.add_parser("generate", help="write the index from the files")
    generate.add_argument("--out", metavar="PATH", help="the index file (default: stdout)")
    generate.add_argument("--at", metavar="PATH",
                          help="the path the index lives at, when the links are computed for a "
                               "copy written elsewhere (default: --out)")
    generate.add_argument("paths", nargs="+", help="files to read")
    generate.set_defaults(run=command_generate)

    retired_help = "the retired-reftag file (default: none read)"
    retire = commands.add_parser("retire", help="record each index row the files no longer "
                                                "define in the retired file")
    retire.add_argument("paths", nargs="+", help="files to read")
    retire.add_argument("--index", metavar="PATH", default=".claude/references.md", help=index_help)
    retire.add_argument("--retired", metavar="PATH", required=True,
                        help="the retired-reftag file, created on the first retirement")
    retire.add_argument("--release", metavar="VERSION", default="",
                        help="the release the tree is at, recorded on each row (default: empty)")
    retire.set_defaults(run=command_retire)

    kinds = commands.add_parser("kinds", help="print the kinds and code families, with what "
                                              "each names")
    kinds.set_defaults(run=command_kinds)

    new = commands.add_parser("new", help="print a fresh reftag of a kind or code family")
    new.add_argument("family", help="a kind or a code family; `kinds` lists them")
    new.add_argument("paths", nargs="*", help="files whose ids the new one must not repeat")
    new.add_argument("--count", metavar="N", type=int, default=1,
                     help="how many to print, each distinct from the others (default: 1)")
    new.add_argument("--index", metavar="PATH", default=".claude/references.md", help=index_help)
    new.add_argument("--retired", metavar="PATH", help=retired_help)
    new.set_defaults(run=command_new)

    where = commands.add_parser("where", help="print file:line and span of a reftag's target")
    where.add_argument("token")
    where.add_argument("paths", nargs="*", help="files to read instead of the index")
    where.add_argument("--index", metavar="PATH", default=".claude/references.md", help=index_help)
    where.set_defaults(run=command_where)

    relink = commands.add_parser("relink", help="rewrite every destination in the documents")
    relink.add_argument("paths", nargs="+", help="files to read; the documents among them are rewritten")
    relink.set_defaults(run=command_relink)

    check = commands.add_parser("check", help="report a duplicate, undefined, misplaced, missing, "
                                              "stale, or resurrected reference")
    check.add_argument("paths", nargs="+", help="files to read")
    check.add_argument("--retired", metavar="PATH", help=retired_help)
    check.set_defaults(run=command_check)

    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())

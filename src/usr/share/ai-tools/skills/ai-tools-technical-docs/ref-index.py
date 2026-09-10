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
# 67,600 ids), which keeps a plain word or number out of the id position. The id is drawn
# at random, so a reader does not read an order into it, and one id names one thing
# across ALL families, whatever the prefix; two things are never related by sharing an id.
# A match is always the full reftag, prefix and dash included, with a word boundary on each
# side: an id alone, or a dash and an id, is a shape generated names and key material take
# too. Two cases. Lowercase names a place in a document, by its kind, and renders
# as a link: `ref-section-m2g0`, `ref-table-z4m9`,
# `ref-diagram-u2s6`, `ref-listing-c7k0` (the kinds are PROSE_KINDS, and `kinds` prints them).
# UPPERCASE names a key living in code, in output, or in a registry, found by a search
# on the token: `FN-T6I7` (a function doc), `NOTE-A9S0` (a comment note), `MSG-N1H8` (a runtime
# message), `URI-G7O3` (a resource identifier). Every prefix ends in a dash, so a search
# for the prefix cannot run into the id.
#
# A TARGET is where the referent lives, and its current location is discovered on every run:
#
#   heading        a heading closed by an anchor: `## Two project models <a id="ref-section-b8e6"></a>`
#   caption        an anchor and a bold caption on the line before the block it names:
#                  `<a id="ref-table-z4m9"></a>**Altitudes and who owns which fact**`; a table
#                  is followed by a table row, a listing by a fence, any other kind by a block
#   FN, NOTE, MSG  a source line carrying the token, a colon, and the name: `# FN-T6I7: chown_path`,
#                  or the token inside the emitted string for a message
#   URI            one Markdown link definition line: `[URI-G7O3]: https://example.invalid "name"`
#
# A REFERENCE in a document is the inline link `[ref-section-h9l8](../x.md#ref-section-h9l8)`.
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
# Commands:
#
#   generate FILE... [--out PATH]   the index: one row per target or example (id, reftag
#                                   as a link, name, file, cited by), sorted by file
#                                   and position. The id is the first column, so a search
#                                   for it reads a fixed place on every line. No line numbers:
#                                   a stored one changes on every edit earlier in the file.
#                                   `--at` names the path the links are computed from; a copy
#                                   written elsewhere is then compared with the committed one.
#   kinds                           the registry: each kind and code family, its reftag form,
#                                   and what it names, so a writer picks one without reading
#                                   this file
#   new FAMILY [FILE...] [--index]  a fresh reftag, its id unique against the index and every
#                                   token in the files given
#   where TOKEN [FILE...] [--index] the target's live `file:line` and the lines it spans
#   relink FILE...                  rewrite every destination in the Markdown files given
#   check FILE...                   report a duplicate reftag or id, an undefined or same-file
#                                   reference, a misplaced anchor, a caption with no block
#                                   following it, a destination that is missing or stale,
#                                   and a relative link whose file or heading is gone; exit 1
#                                   on any report

import argparse
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
CODE_TARGET = re.compile(rf"({CODE_TOKEN}):[ \t]+(.*)")
LINK_SITE = re.compile(rf"\[({PROSE_TOKEN}|{URI_TOKEN}|{CODE_TOKEN})\]\(([^)]*)\)")
BARE_SITE = re.compile(rf"\[({PROSE_TOKEN}|{URI_TOKEN}|{CODE_TOKEN})\]")

FENCE = re.compile(r"^\s*(```|~~~)")
BACKTICK_SPAN = re.compile(r"`[^`]*`")
TABLE_ROW = re.compile(r"^\s*\|")
HEADING = re.compile(r"^(#{1,6})\s")
COMMENT_LINE = re.compile(r"^\s*(#|//|/\*|\*|--|;|<!--|\"\"\")")
BASH_FUNCTION = re.compile(r"^\s*(?:function\s+)?[A-Za-z_][\w-]*\s*\(\)\s*\{?\s*$|^\s*function\s+\w+")
INDEX_ROW = re.compile(r"^\|\s*(" + LOWER_ID + r")\s*\|\s*(?:\[([^\]]+)\]\([^)]*\)|(\S+))\s*\|"
                       r"\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*$")
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
the live line. A row named `example` reserves an id a document shows without defining it.

| Id | Reftag | Name | File | Cited by |
|---|---|---|---|---|
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
    __slots__ = ("reftag", "name", "path", "line", "url", "example")

    def __init__(self, reftag, name, path, line, url=None, example=False):
        self.reftag, self.name, self.path, self.line = reftag, name, path, line
        self.url, self.example = url, example


def is_markdown(path):
    return path.endswith(MARKDOWN)


def family_of(reftag):
    """`ref-table-z4m9` -> `table`, `URI-G7O3` -> `URI`, `FN-T6I7` -> `FN`."""
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
    """{reftag: (id, name, file, cited by)} from an index file, or None when it cannot be read."""
    lines = read_lines(path)
    if lines is None:
        return None
    entries = {}
    for row in map(INDEX_ROW.match, lines):
        if row:
            entries[row.group(2) or row.group(3)] = (row.group(1), row.group(4), row.group(5),
                                                     row.group(6))
    return entries


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
                    f"| {', '.join(sorted(cited.get(target.reftag, ())))} |")
    text = INDEX_HEADER + "".join(row + "\n" for row in rows)
    if args.out:
        with open(args.out, "w") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    return 0


def command_kinds(args):
    """Print the registry: each kind and code family, its reftag form, and what it names."""
    width = max(map(len, FAMILIES))
    for kind, description in PROSE_KINDS.items():
        print(f"{kind:<{width}}  {FAMILIES[kind]}<id>  {description}")
    for family, (prefix, description) in CODE_FAMILIES.items():
        print(f"{family:<{width}}  {prefix}<ID>  {description}")
    return 0


def command_new(args):
    prefix = FAMILIES.get(args.family.lower())
    if not prefix:
        print(f"ref-index: {args.family} is not a kind or a code family; `kinds` lists them",
              file=sys.stderr)
        return 2
    taken = set()
    if os.path.exists(args.index):
        taken.update(entry[0] for entry in (read_index(args.index) or {}).values())
    # Every token in every file, raw: an id in a fixture, a fence, or a span is reserved too.
    for path in args.paths:
        for line in read_lines(path) or []:
            taken.update(id_of(match.group(0)) for match in RAW_TOKEN.finditer(line))
    while True:
        fresh = "".join(secrets.choice(alphabet) for alphabet in
                        (string.ascii_lowercase, string.digits, string.ascii_lowercase, string.digits))
        if fresh not in taken:
            break
    print(prefix + (fresh.upper() if prefix.isupper() else fresh))
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
        print(f"{path}:{number}: duplicate [{reftag}] -- also defined at {first.path}:{first.line}; "
              f"mint a fresh reftag with `new`")
    for target, earlier in duplicate_ids(targets):
        count += 1
        print(f"{target.path}:{target.line}: duplicate-id [{target.reftag}] -- the id is "
              f"{earlier.reftag} at {earlier.path}:{earlier.line}; an id is unique across kinds")
    for path, number, reftag in misplaced:
        count += 1
        print(f"{path}:{number}: misplaced [{reftag}] -- an anchor closes a heading line, or "
              f"opens a bold caption on the line before the block it names")
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

    kinds = commands.add_parser("kinds", help="print the kinds and code families, with what "
                                              "each names")
    kinds.set_defaults(run=command_kinds)

    new = commands.add_parser("new", help="print a fresh reftag of a kind or code family")
    new.add_argument("family", help="a kind or a code family; `kinds` lists them")
    new.add_argument("paths", nargs="*", help="files whose ids the new one must not repeat")
    new.add_argument("--index", metavar="PATH", default=".claude/references.md", help=index_help)
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
                                              "or stale reference")
    check.add_argument("paths", nargs="+", help="files to read")
    check.set_defaults(run=command_check)

    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Reflow the paragraphs of a Markdown page at a column, leaving every other block as written.

```bash
python3 tools/fill-markdown.py --width N [--lines A-B,C-D] <file>...
```

The Markdown half of the formatter `tools/format.sh` fronts, beside `tools/fill-comments.sh` for a
source comment. It rewrites each file in place and prints one line per file. `--lines` names
1-based inclusive line ranges and confines the reflow to the blocks meeting one, which is how the
front door fills only what a diff touched.

Filled, with its structure kept: a paragraph under its own leading indent, a list item and its
continuation lines under a hanging indent the width of the marker, and a blockquote paragraph
under its `> ` prefix. Three rules decide where a break falls. Two are shared with the comment
filler: no line ends on a tie word (the list is read from tools/emacs/ai-tools-fill.el, its one
home), and no line begins with a token that opens a block, since a wrap that moves a fence, a
pipe, a heading mark or a list marker to a line start invents the block. The third is shared with
the checker: no break falls inside an inline code span (the span is the checker's
`BACKTICK_SPAN`, read from prose-check.py, its one home), since a span holds a literal -- a
command line, an owner and mode, a flag with its operand -- that `grep` finds only on one line;
a span wider than the column runs the line over on its own, as the checker's width rule expects.

Left as written, because a line break inside is intentional: YAML frontmatter; a fenced block,
closed only by its own character at its own length or longer, so a nested fence holds; an HTML
comment from a `<!--` at a line start to its `-->`; an indented code block; a table row; an ATX
heading; a thematic break or setext underline; a link reference definition; an `<a>` anchor
line; a `[!NOTE]` alert line; a line ending in two spaces; and a line carrying
`prose-check: ignore`, which the checker skips as a line. The HTML set is the comment and the
anchor rather than CommonMark's block-tag table, because a token opening with `<` in this tree is
a placeholder (`<name>`, `<operator>`) that the full table reads as a tag and strands.

A column is counted in code points; every non-ASCII character this tree uses is one column wide.
"""
import argparse
import importlib.util
import pathlib
import re
import sys

TOOLS = pathlib.Path(__file__).resolve().parent
TIE_LIST = TOOLS / "emacs" / "ai-tools-fill.el"
CHECKER = TOOLS.parent / "src/usr/share/ai-tools/skills/ai-tools-technical-docs/prose-check.py"
IGNORE_MARKER = "prose-check: ignore"
CODE_INDENT = 4

# The marker keeps the spaces it was written with: its width is the item's content indent.
ITEM = re.compile(r"^(\s*)([-*+] +|\d+[.)] +)(\S.*)$")
FENCE_MARK = re.compile(r"^\s*(`{3,}|~{3,})")
COMMENT_OPEN, COMMENT_CLOSE = re.compile(r"^\s*<!--"), "-->"
FRONTMATTER = re.compile(r"^---\s*$")
QUOTE = re.compile(r"^(\s*(?:>\s?)+)(.*)$")
ALERT = re.compile(r"^\[![A-Z]+\]\s*$")
HARD_BREAK = re.compile(r"\S {2,}$")
# A line that is its own block: copied through, and it ends the run before it.
BLOCK = re.compile(r"^\s*(?:\||#{1,6} |(?:[-*_][ \t]*){3,}$|=+\s*$|\[[^\]]+\]:|<(?:!|\?|/?a\b))")
# A token that opens a block when it is first on a line.
LINE_START_BLOCK = re.compile(
    r"^(?:`{3,}|~{3,}|\||#{1,6}$|#{1,6}\W|[-*+]$|[-*_]{3,}$|=+$|\d+[.)]$|>|<!--|<a\b|</a>)")


def tie_words():
    """The tie-word set, read from the comment filler's `ai-tools-tie-words`; exits when absent."""
    try:
        text = TIE_LIST.read_text()
    except OSError as exc:
        sys.exit(f"fill-markdown: cannot read the tie list: {exc}")
    match = re.search(r"\(defconst ai-tools-tie-words\s*'\(((?:\s*\"[a-z]+\")+)\s*\)", text)
    words = set(re.findall(r'"([a-z]+)"', match.group(1))) if match else set()
    if len(words) < 10:
        sys.exit(f"fill-markdown: no tie list in {TIE_LIST}")
    return words


def code_span_pattern():
    """The checker's `BACKTICK_SPAN`, the one statement of what a code span is; exits when absent."""
    try:
        spec = importlib.util.spec_from_file_location("prose_check", CHECKER)
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        return checker.BACKTICK_SPAN
    except (OSError, AttributeError, ImportError) as exc:
        sys.exit(f"fill-markdown: cannot read the code-span rule from {CHECKER}: {exc}")


TIES = tie_words()
BACKTICK_SPAN = code_span_pattern()


def units(text):
    """`text`'s whitespace-separated words, with the words of one code span joined into a unit.

    A break falls only between units, so a span stays on one line; its inner whitespace is
    joined as the words around it are, one space, which is what the gate's token stream reads.
    """
    spans = [(match.start(), match.end()) for match in BACKTICK_SPAN.finditer(text)]
    out, previous = [], None
    for word in re.finditer(r"\S+", text):
        inside = previous is not None and any(
            start < word.start() and end > previous for start, end in spans)
        if inside:
            out[-1] = out[-1] + " " + word.group(0)
        else:
            out.append(word.group(0))
        previous = word.end()
    return out


def is_tie(word):
    """Whether a line may not end on `word`: a tie word not closing a sentence (the filler's rule)."""
    if re.search(r"[.!?]$", word):
        return False
    return re.sub(r"[,;:)\"'`]+$", "", word).lower() in TIES


def wrap(words, first, cont, width):
    """`words` (the units of `units()`) as lines at `width`, under the prefix `first` then `cont`.

    A break moves earlier while the line would end on a tie word, and while the next line would
    begin with a block-opening token; each rule stops before it empties the line it trims. Where
    the block rule cannot be met that way -- the token follows one too wide to share a line -- the
    line runs over the column instead, since a wider line is a line and an invented block is not.
    A code span is one unit, so it runs over the same way when it alone exceeds the column.
    """
    lines, current = [], []
    for word in words:
        prefix = first if not lines else cont
        if current and len(prefix) + len(" ".join(current + [word])) > width:
            tail = []
            while len(current) > 1 and is_tie(current[-1]):
                tail.insert(0, current.pop())
            following = tail + [word]
            while len(current) > 1 and LINE_START_BLOCK.match(following[0]):
                following.insert(0, current.pop())
            if LINE_START_BLOCK.match(following[0]):
                current.extend(following)
                continue
            lines.append(prefix + " ".join(current))
            current = following
        else:
            current.append(word)
    if current:
        lines.append((first if not lines else cont) + " ".join(current))
    return lines


def boundary(line):
    """Whether `line` cannot continue a paragraph run: blank, or a block of its own."""
    return (not line.strip() or bool(ITEM.match(line)) or bool(BLOCK.match(line))
            or bool(FENCE_MARK.match(line)) or bool(COMMENT_OPEN.match(line))
            or bool(QUOTE.match(line)) or IGNORE_MARKER in line or bool(HARD_BREAK.search(line))
            or bool(ALERT.match(line.strip())))


def run_end(source, start):
    """The index after the run of paragraph lines beginning at `start`."""
    index = start
    while index < len(source) and not boundary(source[index]):
        index += 1
    return index


def quote_end(source, start, prefix):
    """The index after the run of blockquote lines at `start` sharing `prefix`."""
    index = start
    while index < len(source):
        match = QUOTE.match(source[index])
        if not match or match.group(1) != prefix or boundary(match.group(2)):
            break
        index += 1
    return index


def touches(start, end, ranges):
    """Whether the source lines [start, end) meet a `--lines` range; every run does with none."""
    return ranges is None or any(low <= end and high >= start + 1 for low, high in ranges)


def reflow(source, width, ranges=None):
    """`source` (a list of lines) reflowed at `width`; returns (lines, blocks filled)."""
    out, index, filled = [], 0, 0
    fence, fence_prefix = None, ""
    # Four spaces open an indented code block outside a list; inside one they are a continuation
    # paragraph under a wide marker. `listed` holds from a list item to the next line at the
    # margin, the rule `prose-check.py` reads a document with.
    listed = False
    if source and FRONTMATTER.match(source[0]):
        out.append(source[0])
        index = 1
        while index < len(source):
            out.append(source[index])
            index += 1
            if FRONTMATTER.match(out[-1]):
                break

    def fill(start, end, words, first, cont):
        nonlocal filled
        if touches(start, end, ranges):
            out.extend(wrap(words, first, cont, width))
            filled += 1
        else:
            out.extend(source[start:end])

    while index < len(source):
        line = source[index]
        quoted = QUOTE.match(line)
        body = line[len(fence_prefix):] if fence is not None and line.startswith(fence_prefix) else line
        mark = FENCE_MARK.match(body)
        indent_width = len(line) - len(line.lstrip(" "))
        if fence is None and not mark:  # a fence and its content leave the state alone
            if ITEM.match(line):
                listed = True
            elif line.strip() and indent_width < 2:
                listed = False
        if fence is not None:
            out.append(line)
            if mark and mark.group(1)[0] == fence[0] and len(mark.group(1)) >= len(fence):
                fence = None
            index += 1
        elif FENCE_MARK.match(line) or (quoted and FENCE_MARK.match(quoted.group(2))):
            fence_prefix = quoted.group(1) if quoted else ""
            fence = FENCE_MARK.match(line[len(fence_prefix):]).group(1)
            out.append(line)
            index += 1
        elif COMMENT_OPEN.match(line):
            while index < len(source):
                out.append(source[index])
                index += 1
                if COMMENT_CLOSE in out[-1]:
                    break
        elif quoted:
            prefix, rest = quoted.groups()
            if boundary(rest):
                out.append(line)
                index += 1
            else:
                end = quote_end(source, index + 1, prefix)
                words = units(" ".join(QUOTE.match(l).group(2) for l in source[index:end]))
                fill(index, end, words, prefix, prefix)
                index = end
        elif ITEM.match(line):
            indent, marker, rest = ITEM.match(line).groups()
            end = run_end(source, index + 1)
            words = units(" ".join([rest, *source[index + 1:end]]))
            fill(index, end, words, indent + marker, indent + " " * len(marker))
            index = end
        elif boundary(line) or (indent_width >= CODE_INDENT and not listed):
            out.append(line)  # blank, a block of its own, or an indented code block
            index += 1
        else:
            indent = line[:indent_width]
            end = run_end(source, index + 1)
            fill(index, end, units(" ".join(source[index:end])), indent, indent)
            index = end
    return out, filled


def parse_ranges(text):
    """`A-B,C-D` as a list of (A, B) pairs, 1-based and inclusive; `A` alone is one line."""
    ranges = []
    for part in text.split(","):
        if not part:
            continue
        low, _, high = part.partition("-")
        ranges.append((int(low), int(high or low)))
    return ranges


def main():
    parser = argparse.ArgumentParser(description="reflow Markdown paragraphs at a column")
    parser.add_argument("--width", type=int, required=True, help="the column to wrap at")
    parser.add_argument("--lines", metavar="RANGES",
                        help="fill only the blocks meeting these 1-based line ranges, `A-B,C-D`")
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    ranges = parse_ranges(args.lines) if args.lines else None
    status = 0
    for path in args.paths:
        try:
            text = pathlib.Path(path).read_text()
        except OSError as exc:
            print(f"fill-markdown: cannot read {path}: {exc}", file=sys.stderr)
            status = 1
            continue
        lines, filled = reflow(text.split("\n"), args.width, ranges)
        joined = "\n".join(lines)
        if joined != text:
            pathlib.Path(path).write_text(joined)
        print(f"{path}: {filled} block(s) filled at {args.width} columns")
    return status


if __name__ == "__main__":
    sys.exit(main())

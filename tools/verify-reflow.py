#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Prove that a reflow changed line breaks and left the text alone.

```bash
python3 tools/verify-reflow.py --base <revision> [--repo P] [--] <path>...
python3 tools/verify-reflow.py --against <dir> [--] <path>...
```

Reads each path at the base (a git revision, or the same relative path under `--against`) and in
the tree, and reports the first difference in three comparisons. Passing all three says the only
change is where the lines break, which is what lets a reflow commit be reviewed in bulk instead
of hunk by hunk:

1. The PROTECTED LINES, line for line: YAML frontmatter, a fenced block with its fences, an HTML
   comment from a `<!--` at a line start to its `-->`, a table row, an alert line, an indented
   code block, and a line carrying `prose-check: ignore`. A line break inside one is intentional,
   so a difference is a defect in the filler. The fence rule is CommonMark's (a fence closes on
   its own character at its own length or longer) rather than a toggle, since a toggle reads
   the ```` ```bash ```` inside a `~~~markdown` block as a close and agrees with a filler that
   made the same mistake.
2. The TOKEN STREAM: every line split on whitespace, so a changed, dropped, added, or reordered
   word is reported with its position.
3. The BLOCK SIGNATURES: the leading whitespace, quote prefix and list marker of the first line
   of every blank-separated block, how many of its lines carry another quote prefix, and how
   many open with a block marker. Their count catches a merged or split paragraph, which the
   token stream cannot see because every token survives; their values catch a dropped indent, a
   dropped quote prefix, a respaced marker, or a list item or heading a wrap invented by moving
   its marker to a line start, none of which it can see because it splits on whitespace and
   reads past a `>`.

Exits 0 when every path passes and 1 otherwise, printing the path, the check that failed, and the
position. A path the base does not hold is reported as skipped rather than as a pass. Both copies
are read through `tools/text_file.py`, so a copy that is not plain text is reported as a failure
with its reason and no token of it reaches the terminal; a path that resolves outside the tree or
the base directory is refused the same way. This is the mechanical half of the reflow gate;
`prose-check.py --kept` is the other half and judges a REWRITE, which a reflow that passes here
has not made.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

import text_file

GIT_TIMEOUT = 60
FENCE_MARK = re.compile(r"^\s*(`{3,}|~{3,})")
TABLE = re.compile(r"^\s*\|")
COMMENT_OPEN, COMMENT_CLOSE = re.compile(r"^\s*<!--"), "-->"
FRONTMATTER = re.compile(r"^---\s*$")
IGNORE_MARKER = "prose-check: ignore"
# A blockquote's prefix is structure, not a token: a filled quote carries it on every new line,
# so the tokens are read past it and the block signature records it instead.
QUOTE = re.compile(r"^(\s*(?:>\s?)+)(.*)$")
ALERT = re.compile(r"^\[![A-Z]+\]\s*$")
# A list marker with the spaces after it: its width is the item's content indent, so a marker
# respaced is a structure change and is part of the block signature.
ITEM = re.compile(r"^\s*([-*+] +|\d+[.)] +)\S")
# A token that opens a block at a line start. A wrap that moves one there invents the block, and
# the token stream cannot see it, so the count of such lines is part of each block's signature.
MARKER_LINE = re.compile(r"^\s*(?:[-*+] |\d+[.)] |#{1,6} |\||`{3,}|~{3,}|<!--)")

Signature = tuple[str, int, int]
Partition = tuple[list[str], list[str], list[Signature]]


def quote_parts(line: str) -> tuple[str, str]:
    """(quote prefix, the rest) of `line`; the prefix is empty outside a blockquote."""
    match = QUOTE.match(line)
    return (match.group(1), match.group(2)) if match else ("", line)


def partition(text: str) -> Partition:
    """`text` as (protected lines, tokens, block signatures).

    A block signature is the leading whitespace, quote prefix and list marker of a
    blank-separated block's first line, the count of its lines carrying a different quote prefix,
    and the count of its lines opening with a block marker, so a quote prefix a filler dropped on
    a continuation line, a marker it respaced, or a list item, heading, row or fence a wrap
    invented mid-block is a difference here.
    """
    protected: list[str] = []
    tokens: list[str] = []
    blocks: list[list] = []
    fence, in_comment, block = None, False, None
    # An indented code block is protected whole: four spaces after a blank line, outside a list,
    # where the same indent is a continuation paragraph the filler may fill (the reading
    # `prose-check.py` and `tools/fill-markdown.py` share).
    listed, in_code = False, False
    lines = text.split("\n")
    front = 0
    if lines and FRONTMATTER.match(lines[0]):
        front = 1
        while front < len(lines) and not FRONTMATTER.match(lines[front]):
            front += 1
        front = min(front + 1, len(lines))
        protected.extend(lines[:front])
    for line in lines[front:]:
        quote, rest = quote_parts(line)
        mark = FENCE_MARK.match(rest)
        if fence is None and not mark:  # a fence and its content leave the state alone
            if ITEM.match(rest):
                listed = True
            elif line.strip() and len(line) - len(line.lstrip(" ")) < 2:
                listed = False
        if fence is not None:
            protected.append(line)
            if mark and mark.group(1)[0] == fence[0] and len(mark.group(1)) >= len(fence):
                fence = None
        elif mark:
            protected.append(line)
            fence = mark.group(1)
        elif in_comment:
            protected.append(line)
            in_comment = COMMENT_CLOSE not in line
        elif COMMENT_OPEN.match(line):
            protected.append(line)
            in_comment = COMMENT_CLOSE not in line
        elif TABLE.match(rest) or IGNORE_MARKER in line or ALERT.match(rest.strip()):
            protected.append(line)
        elif in_code or (block is None and not listed and line.startswith("    ")):
            protected.append(line)
            in_code = True
        if not line.strip():
            block, in_code = None, False
            continue
        if block is None:
            item = ITEM.match(rest)
            head = line[:len(line) - len(line.lstrip(" "))] + quote + (item.group(1) if item else "")
            block = [head, quote, 0, 0]
            blocks.append(block)
        elif quote != block[1]:
            block[2] += 1
        block[3] += bool(MARKER_LINE.match(rest))
        tokens.extend(rest.split())
    return protected, tokens, [(head, lazy, markers) for head, _, lazy, markers in blocks]


def first_difference(left: list, right: list) -> int | None:
    """The index of the first differing element, or None when one is a prefix of the other."""
    for index, (a, b) in enumerate(zip(left, right)):
        if a != b:
            return index
    return None


def context(tokens: list, index: int, width: int = 6) -> str:
    """The elements of `tokens` around `index`, joined for a report line."""
    return " ".join(str(token) for token in tokens[max(0, index - width):index + width])


def inside(root: pathlib.Path, path: str) -> pathlib.Path:
    """`path` under `root`, or `text_file.Refused` where it resolves outside `root`."""
    resolved = (root / path).resolve()
    if root != resolved and root not in resolved.parents:
        raise text_file.Refused(path, f"resolves outside {root}")
    return resolved


def base_text(repo: pathlib.Path, revision: str | None, against: pathlib.Path | None,
              path: str) -> str | None:
    """The base copy of `path`, or None where the base does not hold it."""
    if against is not None:
        try:
            return text_file.read(str(inside(against, path)))[0]
        except FileNotFoundError:
            return None
    shown = subprocess.run(
        ["git", "-C", str(repo), "show", "--end-of-options", f"{revision}:./{path}"],
        capture_output=True, stdin=subprocess.DEVNULL, timeout=GIT_TIMEOUT, check=False)
    return None if shown.returncode else text_file.decode(f"{revision}:{path}", shown.stdout)


def verify(repo: pathlib.Path, revision: str | None, against: pathlib.Path | None,
           path: str) -> tuple[str, str] | None:
    """(check, detail) for the first failing check on `path`, or None when the reflow is pure."""
    try:
        tree = inside(repo, path)
        base = base_text(repo, revision, against, path)
        if base is None:
            return "skipped", f"the base does not hold {path}"
        before = partition(base)
        after = partition(text_file.read(str(tree))[0])
    except text_file.Refused as exc:
        return "refused", exc.reason
    except OSError as exc:
        return "unreadable", exc.strerror
    for name, old, new in (("protected line", before[0], after[0]),
                           ("token", before[1], after[1]),
                           ("block signature", before[2], after[2])):
        index = first_difference(old, new)
        if index is not None:
            return name, (f"position {index}\n"
                          f"      base: {context(old, index)}\n"
                          f"      tree: {context(new, index)}")
        if len(old) != len(new):
            longer, side = (old, "base") if len(old) > len(new) else (new, "tree")
            return name, (f"{side} has {abs(len(old) - len(new))} more, from position "
                          f"{min(len(old), len(new))}\n"
                          f"      {context(longer, min(len(old), len(new)))}")
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="prove a reflow changed only line breaks")
    base = parser.add_mutually_exclusive_group(required=True)
    base.add_argument("--base", dest="revision", metavar="REVISION",
                      help="the revision the reflow started from")
    base.add_argument("--against", metavar="DIR", help="read the base copies under DIR instead")
    parser.add_argument("--repo", default=".", help="the tree holding the reflowed paths")
    parser.add_argument("paths", nargs="+", metavar="PATH")
    args = parser.parse_args(argv)
    repo = pathlib.Path(args.repo).resolve()
    against = pathlib.Path(args.against).resolve() if args.against else None

    failed = skipped = passed = 0
    for path in args.paths:
        result = verify(repo, args.revision, against, path)
        if result is None:
            passed += 1
        elif result[0] == "skipped":
            skipped += 1
            print(f"SKIP {path}: {result[1]}")
        elif result[0] in ("refused", "unreadable"):
            failed += 1
            print(f"FAIL {path}: {result[0]}, {result[1]}")
        else:
            failed += 1
            print(f"FAIL {path}: {result[0]} differs at {result[1]}")
    print(f"{passed} pure reflow(s), {failed} failure(s), {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

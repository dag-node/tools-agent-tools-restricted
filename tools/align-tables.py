#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Align the cells of a pipe-separated table written inside comments.

```bash
python3 tools/align-tables.py check <file>...
python3 tools/align-tables.py fix <file>...
```

`check` names each table whose cells do not line up and exits 1; `fix` rewrites them in place.
A clean `check` is the statement that a `fix` would leave every line as it is.

A column is as wide as the widest of its cells and of the widths its rows were already written
at, so a cell too wide for the column widens every other row rather than being squeezed -- the
repair a reader expects, and the one a majority vote gets backwards -- while a column padded
wider than its content keeps that padding.

The tables are the ones this tree writes: a truth table in a file header, its cells separated by
`|`, its first cell carrying the comment prefix instead of a border, and a rule line of `-` and
`+` under the heading. A cell keeps the alignment it was written with -- left, centred, or right
-- read from the spaces around it, with two rules over it: the row before the rule line is the
heading and is centred over the column it names, and a column of numbers is right, which is
where a reader looks for a count. `column -t` re-pads a body but left-aligns every cell and knows
neither the rule line nor the comment prefix; `table.el` reads a fully bordered grid; an org
table needs a leading `|`. Hence this.

Left alone: a Markdown table (GFM renders it, and this tree writes it compact), a line inside a
fenced block, and a run of one table line, since one row has no second to line up with.
`tools/emacs/ai-tools-fill.el` leaves a comment table as written, so the filler and this tool do
not fight over one.
"""
import argparse
import pathlib
import re
import sys

# The comment marker, then the indent inside it: the indent belongs to the table rather than to
# the prefix, since a row may sit deeper than the row before it and the block keeps one prefix.
COMMENT = re.compile(r"^(\s*(?:#+|//+|;;+))( *)(.*)$")
RULE = re.compile(r"^[-=+\s]+$")
NUMBER = re.compile(r"[-+]?\d+(?:\.\d+)?%?$")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})")


def parts(line):
    """(marker, indent, body) of a comment line, or None where `line` is not one."""
    match = COMMENT.match(line)
    return (match.group(1), match.group(2), match.group(3)) if match else None


def is_rule(body):
    """Whether `body` is a rule line: `-`, `=` and `+` alone, with a separator in it."""
    return bool(RULE.match(body)) and ("+" in body or set(body.strip()) <= {"-", "="})


def split_row(body):
    """`body`'s cells: on `+` where the line is a rule and carries one, on `|` otherwise."""
    return body.split("+") if is_rule(body) and "+" in body else body.split("|")


def carries_table(line):
    """Whether `line` is a comment line holding a table row or its rule."""
    read = parts(line)
    return bool(read) and ("|" in read[2] or (is_rule(read[2]) and "+" in read[2]))


def numeric_column(cells):
    """Whether `cells` are a column of numbers: one number at least, and no other content.

    A `-` placeholder and an empty cell are neither, so a column of counts with a gap in it is
    still a column of counts.
    """
    content = [cell.strip() for cell in cells if cell.strip() not in ("", "-")]
    return bool(content) and all(NUMBER.match(cell) for cell in content)


def alignment(cell):
    """Where `cell` holds its content: `left`, `right`, or `center`."""
    left, right = len(cell) - len(cell.lstrip(" ")), len(cell) - len(cell.rstrip(" "))
    if not cell.strip() or (left <= 1 and right <= 1):
        return "left"
    if left > 1 and right > 1:
        return "center"
    return "right" if left > right else "left"


def center(text, width):
    """`text` centred in `width`, an odd space falling right so the text sits nearer the left."""
    left = (width - len(text)) // 2
    return " " * left + text + " " * (width - len(text) - left)


def render(cell, width, how, first, rule):
    """`cell`'s content in a field of `width`, under alignment `how`.

    The first field does not carry a separator before it, so it is one column narrower than the rest:
    content and one space, against a space, content and a space.
    """
    if rule:
        return ("=" if "=" in cell else "-") * (width + (1 if first else 2))
    text = cell.strip()
    placed = {"center": center(text, width), "right": text.rjust(width)}.get(how, text.ljust(width))
    return placed + " " if first else " " + placed + " "


def separator_columns(line):
    """The columns `line` carries a `|` or a `+` at."""
    return {index for index, char in enumerate(line) if char in "|+"}


def is_table(rows):
    """Whether `rows` are a table: two lines in a row sharing a separator column.

    A pipe in prose -- a pipeline in an example, a sed address, an alternation -- lands where the
    line before it has none, which is the reading `tools/emacs/ai-tools-fill.el` protects a table
    by and the one that keeps a paragraph out of this tool.
    """
    columns = [separator_columns(row) for row in rows]
    return any(before & after for before, after in zip(columns, columns[1:]))


def table_blocks(lines):
    """Yield (start, end) for each run of two or more comment lines carrying a table."""
    start, marker, fence = None, None, None
    for index, line in enumerate(lines + [""]):
        mark = FENCE.match(line)
        if fence is not None:
            if mark and mark.group(1)[0] == fence[0] and len(mark.group(1)) >= len(fence):
                fence = None
            continue
        if mark:
            fence = mark.group(1)
            continue
        held = carries_table(line)
        if held and (start is None or parts(line)[0] == marker):
            if start is None:
                start, marker = index, parts(line)[0]
            continue
        if start is not None and index - start > 1 and is_table(lines[start:index]):
            yield start, index
        start, marker = (index, parts(line)[0]) if held else (None, None)


def widths(rows, rules):
    """The width of each column: its widest cell, and the widest field its rows were written at.

    Keeping the written width is what makes a repair minimal -- a column padded wider than its
    content stays as it is, and only a column a cell overflows grows.
    """
    width = [0] * max(len(row) for row in rows)
    for row, rule in zip(rows, rules):
        for column, cell in enumerate(row):
            content = 0 if rule else len(cell.strip())
            written = len(cell.rstrip()) - (1 if column == 0 else 2)
            width[column] = max(width[column], content, written)
    return width


def aligned(lines, start, end):
    """The block rewritten with one width per column, each cell under its own alignment."""
    read = [parts(line) for line in lines[start:end]]
    indent = min(len(one[1]) for one in read)
    prefix = read[0][0] + " " * indent
    bodies = [" " * (len(one[1]) - indent) + one[2] for one in read]
    rows = [split_row(body) for body in bodies]
    rules = [is_rule(body) for body in bodies]
    width = widths(rows, rules)

    ruled = next((index for index, rule in enumerate(rules) if rule), None)
    heading = ruled - 1 if ruled else None
    body_rows = [row for index, (row, rule) in enumerate(zip(rows, rules))
                 if not rule and index != heading]
    numeric = [numeric_column([row[column] for row in body_rows if column < len(row)])
               for column in range(len(width))]

    out = []
    for index, (row, rule) in enumerate(zip(rows, rules)):
        fields = []
        for column, cell in enumerate(row):
            how = ("center" if index == heading else
                   "right" if numeric[column] else alignment(cell))
            fields.append(render(cell, width[column], how, column == 0, rule))
        out.append((prefix + ("+" if rule else "|").join(fields)).rstrip())
    return out


def realign(text):
    """(the text with every comment table aligned, the line ranges that were not)."""
    lines = text.split("\n")
    out, off = list(lines), []
    for start, end in table_blocks(lines):
        fixed = aligned(lines, start, end)
        if fixed != lines[start:end]:
            off.append((start + 1, end))
            out[start:end] = fixed
    return "\n".join(out), off


def main():
    parser = argparse.ArgumentParser(description="align the cells of a comment's table")
    parser.add_argument("action", choices=("check", "fix"))
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    status = 0
    for path in args.paths:
        try:
            text = pathlib.Path(path).read_text()
        except (OSError, UnicodeDecodeError) as exc:
            print(f"align-tables: cannot read {path}: {exc}", file=sys.stderr)
            status = 1
            continue
        fixed, off = realign(text)
        for first, last in off:
            print(f"{path}:{first}: table cells do not line up (lines {first}-{last})")
        if not off:
            continue
        if args.action == "fix":
            pathlib.Path(path).write_text(fixed)
        else:
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""tests/lib/pipefail-readers.py <file>... : report each pipeline whose last stage may exit before its producer does.

The rule this reads a tree for is the early-exit reader bullet of `.claude/rules/shellcheck.rule.md`
(ref-section-d9x2): under `pipefail` such a pipeline returns 141 on input that matched. `tests/unit/pipefail-readers.sh`
runs it over the shell files of a checkout and holds a fixture that proves each shape on known input.

Prints one line per finding, `<file>:<line>: <reader>: <the stage>`, and exits 1 when it printed any, else 0. A file
whose quoting the scanner cannot follow to the end is itself a finding (`unparsed`), so a file it could not read does
not count as clean.

What it reads as shell: a `*.yml` file's `run:` blocks, every other file whole, and the quoted body of a `bash -c`
or `sh -c` argument. What it reports: a stage that follows a `|` and is `grep` with `-q`, `-l`, `-L` or `-m`, `head`,
`sed` with a `q` command, `awk` with `exit`, or `read`. One shape is outside it: `head -c` with a stage after it,
the bounded read of a stream too large to capture, whose status its caller discards. Text inside quotes, a comment
or a here-document body is not shell; a `|` with no whitespace on either side is a `case` alternation.
"""
import re
import sys

GREP_NAMES = {"grep", "egrep", "fgrep", "ugrep"}
GREP_LONG = ("--quiet", "--silent", "--max-count", "--files-with-matches", "--files-without-match")
SED_QUIT = re.compile(r"""(?:^|[;{}\s0-9$/!,'"])[qQ][0-9]*\s*(?:[;}'"\s]|$)""")
HEREDOC = re.compile(r"""<<(-?)[ \t]*(?:\\?([A-Za-z_][A-Za-z0-9_]*)|'([^'\n]+)'|"([^"\n]+)")""")
SHELL_C = re.compile(r"(?:^|[\s/])(?:ba)?sh\s+(?:-[A-Za-z]+\s+)*-[A-Za-z]*c\s+$")
RUN_KEY = re.compile(r"^(\s*)(?:-\s+)?run:\s*(.*)$")
MASKED = "\x00"


class Unparsed(Exception):
    """The scanner reached the end of the text inside a quote, a substitution or a here-document."""


def mask_shell(text):
    """Return (mask, depth, bodies) for shell source `text`.

    mask[i] is text[i] where that character is shell syntax and MASKED where it is quoted, a comment,
    arithmetic or a here-document body; depth[i] is the number of open substitutions and subshells
    at i; bodies lists (offset, source) for each `bash -c '...'` argument. Raises Unparsed.
    """
    n = len(text)
    mask = list(text)
    depth = [-1] * n
    bodies = []
    opened = []         # the offset of each open double quote that starts a `bash -c` body, else -1
    stack = []          # 'P' subshell or substitution, 'D' double quote, 'A' arithmetic, 'a' paren inside arithmetic
    pending = []        # here-documents opened on this line: (delimiter, strip_tabs)
    i = 0

    def hide(a, b):
        for k in range(a, min(b, n)):
            if mask[k] != "\n":
                mask[k] = MASKED

    while i < n:
        c = text[i]
        top = stack[-1] if stack else "C"
        depth[i] = sum(1 for s in stack if s == "P")
        if c == "\n" and pending and top != "D":
            # The bodies of the here-documents this line opened, in order, each up to its delimiter line.
            j = i + 1
            for delimiter, strip_tabs in pending:
                while True:
                    if j >= n:
                        raise Unparsed(f"here-document {delimiter} is not closed")
                    end = text.find("\n", j)
                    end = n if end < 0 else end
                    line = text[j:end]
                    hide(j, end)
                    j = end + 1
                    if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                        break
            pending = []
            i = j
            continue
        if c == "\\" and i + 1 < n:
            if text[i + 1] != "\n":
                hide(i, i + 2)
            else:
                mask[i] = mask[i + 1] = " "     # a continuation joins the two lines of one stage
            i += 2
            continue
        if top == "D":
            if c == '"':
                stack.pop()
                mask[i] = MASKED
                start = opened.pop()
                if start >= 0:
                    bodies.append((start, text[start:i]))
            elif text.startswith("$((", i):
                stack.append("A"); hide(i, i + 3); i += 3; continue
            elif text.startswith("$(", i):
                stack.append("P"); i += 2; continue
            else:
                hide(i, i + 1)
            i += 1
            continue
        if top in ("A", "a"):
            if text.startswith("$(", i) and not text.startswith("$((", i):
                stack.append("P"); i += 2; continue
            if c == "(":
                stack.append("a")
            elif c == ")":
                closing = stack.pop()
                if closing == "A" and text.startswith("))", i):
                    hide(i, i + 2); i += 2; continue
            elif c == '"':
                stack.append("D"); opened.append(-1)
            hide(i, i + 1)
            i += 1
            continue
        # Shell syntax: the top level, a subshell or a substitution.
        if c == "'":
            ansi = i > 0 and text[i - 1] == "$"
            j = i + 1
            while j < n and text[j] != "'":
                j += 2 if ansi and text[j] == "\\" else 1
            if j >= n:
                raise Unparsed("a single-quoted string is not closed")
            if not ansi and SHELL_C.search(text[max(0, i - 48):i]):
                bodies.append((i + 1, text[i + 1:j]))
            hide(i, j + 1)
            i = j + 1
            continue
        if c == '"':
            stack.append("D"); mask[i] = MASKED
            opened.append(i + 1 if SHELL_C.search(text[max(0, i - 48):i]) else -1)
            i += 1
            continue
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;(|&"):
            end = text.find("\n", i)
            end = n if end < 0 else end
            hide(i, end)
            i = end
            continue
        if text.startswith("$((", i):
            stack.append("A"); hide(i, i + 3); i += 3; continue
        if text.startswith("((", i) and (i == 0 or text[i - 1] in " \t\n;&|!"):
            stack.append("A"); hide(i, i + 2); i += 2; continue
        if text.startswith("$(", i):
            stack.append("P"); i += 2; continue
        if c == "(":
            stack.append("P")
        elif c == ")":
            if top == "P":      # a `)` with no opener is a case pattern's
                stack.pop()
                depth[i] = sum(1 for s in stack if s == "P")
        elif text.startswith("<<<", i):
            i += 3
            continue
        elif text.startswith("<<", i):
            m = HEREDOC.match(text, i)
            if m:
                pending.append((m.group(2) or m.group(3) or m.group(4), m.group(1) == "-"))
                i = m.end()
                continue
        i += 1
    if stack or pending:
        raise Unparsed("the text ends inside " + ("a here-document" if pending else
                                                    {"D": "a double-quoted string", "P": "a substitution or subshell",
                                                     "A": "an arithmetic expansion", "a": "an arithmetic expansion"}[stack[-1]]))
    for k in range(n):      # a character the loop stepped over is at the depth of the one before it
        if depth[k] < 0:
            depth[k] = depth[k - 1] if k else 0
    return "".join(mask), depth, bodies


def reader_of(stage, masked_stage):
    """Return the early-exit reader `stage` runs, or None. `masked_stage` is the same span with quoted text hidden."""
    words = masked_stage.split()
    while words and (words[0] in ("command", "builtin", "exec") or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=\S*", words[0])):
        words.pop(0)
    if not words:
        return None
    name = words[0].rsplit("/", 1)[-1]
    if name in GREP_NAMES:
        for word in words[1:]:
            if word == "--":
                break
            if word.startswith("--"):
                if word.split("=", 1)[0] in GREP_LONG:
                    return f"{name} {word.split('=', 1)[0]}"
            elif word.startswith("-") and MASKED not in word:
                for flag in "qlLm":
                    if flag in word[1:]:
                        return f"{name} -{flag}"
        return None
    if name == "head" or name == "read":
        return name
    if name in ("sed", "gsed") and SED_QUIT.search(stage.split(None, 1)[1] if len(stage.split(None, 1)) > 1 else ""):
        return "sed q"
    if name in ("awk", "gawk", "mawk") and re.search(r"\bexit\b", stage):
        return "awk exit"
    return None


def scan(text, first_line=1):
    """Return [(line, reader, stage)] for shell source `text`, whose first line is numbered `first_line`."""
    mask, depth, bodies = mask_shell(text)
    n = len(text)
    findings = []
    for i, c in enumerate(mask):
        if c != "|" or mask[i - 1:i] == "|" or mask[i + 1:i + 2] == "|":
            continue
        before, after = mask[i - 1:i], mask[i + 1:i + 2]
        if not (before in ("", " ", "\t", "\n") or after in ("", " ", "\t", "\n", "&")):
            continue
        level = depth[i]
        j = i + 1 + (after == "&")
        while j < n and mask[j] in " \t\n":
            j += 1
        start = j
        last = True
        while j < n:
            if depth[j] < level or (depth[j] == level and mask[j] in ";&\n)"):
                break
            if depth[j] == level and mask[j] == "|":
                last = mask[j + 1:j + 2] == "|"
                break
            j += 1
        reader = reader_of(text[start:j], mask[start:j])
        if reader == "head" and not last and re.search(r"\s(-c|--bytes)", mask[start:j]):
            continue
        if reader:
            findings.append((first_line + text.count("\n", 0, i), reader, " ".join(text[start:j].split())))
    for offset, body in bodies:
        findings.extend(scan(body, first_line + text.count("\n", 0, offset)))
    return sorted(set(findings))


def workflow_shell(text):
    """Return `text` with every line outside a workflow's `run:` blocks blanked, so line numbers hold."""
    out = []
    block_indent = None
    for line in text.split("\n"):
        if block_indent is not None:
            if not line.strip() or len(line) - len(line.lstrip()) > block_indent:
                out.append(line)
                continue
            block_indent = None
        m = RUN_KEY.match(line)
        if m and re.fullmatch(r"[|>][-+]?", m.group(2).strip()):
            block_indent = len(m.group(1)) + (2 if line.lstrip().startswith("-") else 0)
            out.append("")
        elif m and m.group(2).strip():
            out.append(" " * (len(line) - len(m.group(2))) + m.group(2))
        else:
            out.append("")
    return "\n".join(out)


def main(paths):
    found = False
    for path in paths:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            if path.endswith((".yml", ".yaml")):
                text = workflow_shell(text)
            for line, reader, stage in scan(text):
                found = True
                print(f"{path}:{line}: {reader}: {stage}")
        except (OSError, Unparsed) as error:
            found = True
            print(f"{path}:0: unparsed: {error}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

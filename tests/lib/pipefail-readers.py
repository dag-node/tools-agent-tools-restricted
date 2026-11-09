#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""tests/lib/pipefail-readers.py <file>... : report each stage after a pipe that may exit before its producer does.

The rule this reads a tree for is `.claude/rules/shellcheck.rule.md`'s *A reader that exits early fails its pipeline*
(ref-section-d9x2). `tests/unit/pipefail-readers.sh` runs it over the shell files of a checkout and holds the fixture
that proves each shape on known input.

Prints one line per finding, `<file>:<line>: <reader>: <the stage>`, and exits 1 when it printed any, else 0. A file
whose quoting the scanner cannot follow to the end is itself a finding (`unparsed`), so a file it could not read does
not count as clean. An error of the scanner's own exits 2 with the error on stderr.

What it reads as shell: a `*.yml` file's `run:` blocks, every other file whole, and the body of a `bash -c` or `sh -c`
argument, joined from its quoted pieces where one quote closes and the next opens (`'source "'"${lib}"'"; ...'`).
What it reports: a stage that follows a `|` and is `grep` with `-q`, `-l`, `-L` or `-m`, `head`,
`sed` with a `q` command, `awk` with `exit`, or `read`, except `head -c` with a stage after it in a pipeline
whose status `|| true` or `|| :` discards. Text inside quotes, a comment or a here-document body is not shell,
and neither is a `|` between the patterns of a `case` arm or inside `[[ ]]`.
"""
import re
import shlex
import sys

GREP_NAMES = {"grep", "egrep", "fgrep", "ugrep"}
GREP_LONG = ("--quiet", "--silent", "--max-count", "--files-with-matches", "--files-without-match")
SED_QUIT = re.compile(r"""(?:^|[;{}\s0-9$/!,'"])[qQ][0-9]*\s*(?:[;}'"\s]|$)""")
HEREDOC = re.compile(r"""<<(-?)[ \t]*(?:\\?([A-Za-z_][A-Za-z0-9_]*)|'([^'\n]+)'|"([^"\n]+)")""")
SHELL_C = re.compile(r"(?:^|[\s/])(?:ba)?sh\s+(?:-[A-Za-z]+\s+)*-[A-Za-z]*c\s+$")
RUN_KEY = re.compile(r"^(\s*)(?:-\s+)?run:\s*(.*)$")
CASE_WORD = re.compile(r"case(?=[ \t])")
IN_WORD = re.compile(r"in(?=[ \t\n])")
ESAC_WORD = re.compile(r"esac(?![A-Za-z0-9_])")
COMMAND_OPENERS = {"then", "do", "else", "elif", "if", "while", "until", "!", "time"}
GREP_TAKES_ARGUMENT = "efABCDd"
DISCARDED = re.compile(r"\s*\|\|\s*(?:true|:)(?=[\s;)&]|$)")
MASKED = "\x00"


class Unparsed(Exception):
    """The scanner reached the end of the text inside a quote, a substitution or a here-document."""


def mask_shell(text):
    """Return (mask, depth, bodies) for shell source `text`.

    mask[i] is text[i] where that character is shell syntax and MASKED where it is quoted, a comment,
    arithmetic, a here-document body, or an operator of a `case` pattern or of `[[ ]]`; depth[i] is
    the number of open substitutions and subshells at i; bodies lists (offset, source) for each
    `bash -c '...'` argument, its quoted pieces joined with their quotes removed. Raises Unparsed.
    """
    n = len(text)
    mask = list(text)
    depth = [-1] * n
    bodies = []
    opened = []         # for each open double quote, the `bash -c` body it is a piece of, else None
    awaited = None      # the body whose last piece closed where the next quote opens
    origins = []        # the offset at which each entry of `stack` opened
    origins_of_piece = []   # the offset of the first character of each open double-quoted piece of a body
    stack = []          # 'P' subshell or substitution, 'D' double quote, 'B' `${ }`, 'A' arithmetic, 'a' paren inside it
    pending = []        # here-documents opened on this line: (delimiter, strip_tabs)
    frames = [new_frame()]      # one per shell level: the top, then each open substitution or subshell
    i = 0

    def open_shell():
        stack.append("P"); origins.append(i)
        frames.append(new_frame())

    def body_at(at, starts):
        """Return the body the quote at `at` opens or continues, else None. `starts` is false for an ANSI-C quote."""
        nonlocal awaited
        body, awaited = awaited, None
        if body is not None and body["end"] == at:
            return body
        if starts and SHELL_C.search(text[max(0, at - 48):at]):
            return {"offset": at + 1, "pieces": [], "end": -1}
        return None

    def close_piece(body, piece, end):
        """Add `piece` to `body`, and list the body unless a quote opens at `end`, where the argument goes on."""
        nonlocal awaited
        body["pieces"].append(piece)
        body["end"] = end
        if text[end:end + 1] in ("'", '"'):
            awaited = body
        else:
            bodies.append((body["offset"], "".join(body["pieces"])))

    def is_command_position(at):
        before = text[:at].rstrip(" \t")
        if not before or before[-1] in "\n;&|({)":
            return True
        return re.search(r"(\S+)$", before).group(1) in COMMAND_OPENERS

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
                stack.pop(); origins.pop()
                mask[i] = MASKED
                body = opened.pop()
                if body is not None:
                    close_piece(body, text[origins_of_piece.pop():i], i + 1)
            elif text.startswith("$((", i):
                stack.append("A"); origins.append(i); hide(i, i + 3); i += 3; continue
            elif text.startswith("$(", i):
                open_shell(); i += 2; continue
            elif text.startswith("${", i):
                stack.append("B"); origins.append(i); hide(i, i + 2); i += 2; continue
            else:
                hide(i, i + 1)
            i += 1
            continue
        if top == "B":
            # Inside `${ }` a quote opens a quoted span of its own, whatever quote the expansion sits in.
            if c == "}":
                stack.pop(); origins.pop()
            elif c == '"':
                stack.append("D"); origins.append(i); opened.append(None)
            elif c == "'":
                ansi = text[i - 1] == "$"
                j = i + 1
                while j < n and text[j] != "'":
                    j += 2 if ansi and text[j] == "\\" else 1
                closing = text.find("}", i)
                if j < n and (ansi or closing < 0 or j < closing):     # else an apostrophe in the expansion's word
                    hide(i, j + 1); i = j + 1; continue
            elif text.startswith("$((", i):
                stack.append("A"); origins.append(i); hide(i, i + 3); i += 3; continue
            elif text.startswith("$(", i):
                open_shell(); i += 2; continue
            elif text.startswith("${", i):
                stack.append("B"); origins.append(i); hide(i, i + 2); i += 2; continue
            hide(i, i + 1)
            i += 1
            continue
        if top in ("A", "a"):
            if text.startswith("$(", i) and not text.startswith("$((", i):
                open_shell(); i += 2; continue
            if c == "(":
                stack.append("a"); origins.append(i)
            elif c == ")":
                closing = stack.pop(); origins.pop()
                if closing == "A" and text.startswith("))", i):
                    hide(i, i + 2); i += 2; continue
            elif c == '"':
                stack.append("D"); origins.append(i); opened.append(None)
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
            body = body_at(i, not ansi)
            if body is not None:
                close_piece(body, text[i + 1:j], j + 1)
            hide(i, j + 1)
            i = j + 1
            continue
        if c == '"':
            stack.append("D"); origins.append(i); mask[i] = MASKED
            opened.append(body_at(i, True))
            if opened[-1] is not None:
                origins_of_piece.append(i + 1)
            i += 1
            continue
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;(|&"):
            end = text.find("\n", i)
            end = n if end < 0 else end
            hide(i, end)
            i = end
            continue
        if text.startswith("$((", i):
            stack.append("A"); origins.append(i); hide(i, i + 3); i += 3; continue
        if text.startswith("$(", i):
            frames[-1]["pattern_start"] = False
            open_shell(); i += 2; continue
        if text.startswith("${", i):
            frames[-1]["pattern_start"] = False
            stack.append("B"); origins.append(i); hide(i, i + 2); i += 2; continue
        frame = frames[-1]
        at_word = i == 0 or text[i - 1] in " \t\n;&|()"
        if frame["test"]:
            # Inside `[[ ]]` an operator is the test's own: a regex alternation, a grouping, `<`, `&&`.
            if at_word and text.startswith("]]", i) and text[i + 2:i + 3] in ("", " ", "\t", "\n", ";", ")", "&", "|"):
                frame["test"] = False
                i += 2
            else:
                if c in "|()&;<>":
                    hide(i, i + 1)
                i += 1
            continue
        if frame["pattern"]:
            # Between `in` or `;;` and the `)` that ends a case arm's patterns.
            if c in " \t\n":
                i += 1
                continue
            if at_word and ESAC_WORD.match(text, i):
                frame["cases"] -= 1
                frame["pattern"] = False
                i += 4
                continue
            if c in "(|)":
                hide(i, i + 1)
                if c == "(" and not frame["pattern_start"]:
                    frame["pattern_groups"] += 1        # an extglob group; a leading `(` is the arm's optional one
                elif c == ")" and frame["pattern_groups"]:
                    frame["pattern_groups"] -= 1
                elif c == ")":
                    frame["pattern"] = False
                    mask[i] = ";"                       # the arm's commands start a new pipeline
                frame["pattern_start"] = False
                i += 1
                continue
            frame["pattern_start"] = False
            i += 1
            continue
        if at_word and text.startswith("[[", i) and text[i + 2:i + 3] in (" ", "\t", "\n"):
            frame["test"] = True
            i += 2
            continue
        if at_word and CASE_WORD.match(text, i) and is_command_position(i):
            frame["cases_pending"] += 1
            i += 4
            continue
        if frame["cases_pending"] and at_word and IN_WORD.match(text, i):
            frame["cases_pending"] -= 1
            frame["cases"] += 1
            frame.update(pattern=True, pattern_start=True, pattern_groups=0)
            i += 2
            continue
        if frame["cases"] and (text.startswith(";;", i) or text.startswith(";&", i)):
            frame.update(pattern=True, pattern_start=True, pattern_groups=0)
            i += 3 if text.startswith(";;&", i) else 2
            continue
        if frame["cases"] and at_word and ESAC_WORD.match(text, i):
            frame["cases"] -= 1
            i += 4
            continue
        if text.startswith("((", i) and (i == 0 or text[i - 1] in " \t\n;&|!"):
            stack.append("A"); origins.append(i); hide(i, i + 2); i += 2; continue
        if c == "(":
            open_shell()
        elif c == ")":
            if top == "P":
                stack.pop(); origins.pop()
                frames.pop()
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
    if pending:
        raise Unparsed(f"here-document {pending[0][0]} is not closed")
    if stack:
        kind = {"D": "a double-quoted string", "P": "a substitution or subshell", "B": "a parameter expansion",
                "A": "an arithmetic expansion", "a": "an arithmetic expansion"}[stack[-1]]
        raise Unparsed(f"the text ends inside {kind} opened on line {text.count(chr(10), 0, origins[-1]) + 1}")
    for k in range(n):      # a character the loop stepped over is at the depth of the one before it
        if depth[k] < 0:
            depth[k] = depth[k - 1] if k else 0
    return "".join(mask), depth, bodies


def new_frame():
    """Return the `case` and `[[ ]]` state of one shell level."""
    return {"cases_pending": 0, "cases": 0, "pattern": False, "pattern_start": False, "pattern_groups": 0, "test": False}


def find_early_exit_reader(stage, masked_stage):
    """Return the early-exit reader `stage` runs, or None. `masked_stage` is the same span with quoted text hidden."""
    try:
        words = shlex.split(stage)      # the words as the shell passes them, so a quoted option reads as an option
    except ValueError:
        words = masked_stage.split()
    while words and (words[0] in ("command", "builtin", "exec") or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=\S*", words[0])):
        words.pop(0)
    if not words:
        return None
    name = words[0].rsplit("/", 1)[-1]
    if name in GREP_NAMES:
        index = 1
        while index < len(words) and words[index] != "--":
            word = words[index]
            index += 1
            if word.startswith("--"):
                if word.split("=", 1)[0] in GREP_LONG:
                    return f"{name} {word.split('=', 1)[0]}"
            elif word.startswith("-"):
                for position, flag in enumerate(word[1:], start=1):
                    if flag in "qlLm":
                        return f"{name} -{flag}"
                    if flag in GREP_TAKES_ARGUMENT:     # the rest of the word, or the next word, is its argument
                        index += position == len(word) - 1
                        break
        return None
    if name == "head" or name == "read":
        return name
    if name in ("sed", "gsed") and SED_QUIT.search(stage.split(None, 1)[1] if len(stage.split(None, 1)) > 1 else ""):
        return "sed q"
    if name in ("awk", "gawk", "mawk") and re.search(r"\bexit\b", stage):
        return "awk exit"
    return None


def stage_end(mask, depth, pipe):
    """Return (start, end, last) for the stage after the `|` at `pipe`: its span, and whether it ends its pipeline."""
    n = len(mask)
    level = depth[pipe]
    j = pipe + 1 + (mask[pipe + 1:pipe + 2] == "&")
    while j < n and mask[j] in " \t\n":
        j += 1
    start = j
    while j < n:
        if depth[j] < level or (depth[j] == level and mask[j] in ";&\n)"):
            break
        if depth[j] == level and mask[j] == "|":
            return start, j, mask[j + 1:j + 2] == "|"
        j += 1
    return start, j, True


def is_status_discarded(mask, depth, pipe):
    """Succeed when `|| true` or `|| :` follows the pipeline holding the `|` at `pipe`, or the substitution it ends."""
    _, end, last = stage_end(mask, depth, pipe)
    while not last:
        _, end, last = stage_end(mask, depth, end)
    while end < len(mask) and mask[end] in (")", MASKED):
        end += 1
    return DISCARDED.match(mask, end) is not None


def find_early_exit_readers(text, first_line=1):
    """Return [(line, reader, stage)] for shell source `text`, whose first line is numbered `first_line`."""
    mask, depth, bodies = mask_shell(text)
    findings = []
    for i, c in enumerate(mask):
        if c != "|" or mask[i - 1:i] in ("|", ">") or mask[i + 1:i + 2] == "|":
            continue
        start, j, last = stage_end(mask, depth, i)
        reader = find_early_exit_reader(text[start:j], mask[start:j])
        if (reader == "head" and not last and re.search(r"\s(-c|--bytes)", mask[start:j])
                and is_status_discarded(mask, depth, i)):
            continue
        if reader:
            findings.append((first_line + text.count("\n", 0, i), reader, " ".join(text[start:j].split())))
    for offset, body in bodies:
        findings.extend(find_early_exit_readers(body, first_line + text.count("\n", 0, offset)))
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
            for line, reader, stage in find_early_exit_readers(text):
                found = True
                print(f"{path}:{line}: {reader}: {stage}")
        except (OSError, Unparsed) as error:
            found = True
            print(f"{path}:0: unparsed: {error}")
    return 1 if found else 0


if __name__ == "__main__":
    try:
        status = main(sys.argv[1:])
    except Exception as error:  # the scanner's own defect: exit apart from the findings' status
        print(f"pipefail-readers: {type(error).__name__}: {error}", file=sys.stderr)
        status = 2
    sys.exit(status)

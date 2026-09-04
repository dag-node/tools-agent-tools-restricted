#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# prose-check.py -- reports the rhetorical figures this skill rules out, as file:line, so the
# final-pass checklist runs mechanically instead of by eye. It ships beside the SKILL.md it
# enforces, so the rule and its check are versioned together.
#
# Seeded assets are mode 640, so run it through its interpreter:
#
#     python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py <file>...
#
# Three modes. `--staged` reads the added lines of the git index, which is what a pre-commit
# hook runs; `--message` reads a commit message, an artifact this standard covers like any
# other; named paths are read whole, for a sweep.
# Source files contribute their comments and docstrings, Markdown and man pages every line. The
# patterns match English, so they carry to any codebase.
#
# Checks read rejoined SENTENCES rather than raw lines. Wrapped prose puts the guard clause of an
# absolute on the next line, and the shape checks compare the two halves of a pivot, so both need
# the whole sentence to report anything worth reading.
#
# `--all` adds the four shape checks. Each one greps a sub-shape of its rule -- the half a regex
# can see -- because the rules themselves are about meaning: "an absolute with no guard in the
# same sentence" and "a clause mirrored across a pivot" are not properties of any word list. A
# vocabulary grep for them reported correct prose on most of what it flagged when it was sampled
# against this repository, so each check now carries a second condition:
#
#   unbacked-absolute  the sentence holds an absolute AND no subordinating conjunction, since a
#                      guard clause is what those conjunctions introduce.
#   mirrored-clause    a word stem repeats across `rather than` / `instead of`, which is the
#                      mirror itself; a plain contrast puts different words on each side.
#   definitional       a head noun repeats across `is not a`, which is the restatement that makes
#                      the sentence a definition instead of a description.
#   history            the past-tense markers only. `no longer` describes a current state as often
#                      as a change, so it is left to the reader.
#
# A line carrying `prose-check: allow` is skipped, which is how a style guide keeps the labelled
# bad examples it has to contain.

import argparse
import re
import subprocess
import sys

ALLOW_MARKER = "prose-check: allow"

# Any third-person verb before `no`, rather than a list of them: an enumerated list finds only
# the verbs whoever wrote it thought of, and this construction takes every transitive verb in the
# language. Two exclusions keep the suggestion honest. `is`/`was`/`has` carry the existential
# "there is no X", which reads plainly and has no mechanical rewrite; `means`/`implies` negate a
# following clause rather than an object, so "no operator means no ownership" wants "means there
# is no ownership" instead. The object stop-list drops the fixed adverbials.
FRONTED_QUANTIFIER = re.compile(
    r"\b(?!is\b|was\b|has\b|means\b|implies\b)([a-z]{3,}s)"
    r"\s+no\s+(?!longer\b|one\b|matter\b|doubt\b)([a-z][a-z-]*)")

# Each entry is (name, pattern, hint). The hint is what to write instead, since a report naming
# only the defect leaves the reader to rediscover the fix on every hit.
DEFAULT_CHECKS = [
    ("fronted-quantifier", FRONTED_QUANTIFIER, None),  # hint derived; see suggest()
    ("nothing", re.compile(r"\bnothing\b"), "name the absent input"),
]

# Third-person singular endings that need more than a dropped "s".
_ES_ENDINGS = ("sses", "shes", "ches", "xes", "zes", "oes")


def base_form(verb):
    """The base form of a third-person singular verb: carries -> carry, passes -> pass."""
    if verb.endswith("ies"):
        return verb[:-3] + "y"
    if verb.endswith(_ES_ENDINGS):
        return verb[:-2]
    return verb[:-1]


def suggest(name, match, static_hint):
    """What to write instead, derived from the match where the fix is mechanical."""
    if name == "fronted-quantifier":
        verb, obj = match.group(1), match.group(2)
        # `a` or `any` is a claim about arity, so the code decides: one parameter takes the
        # article, a variadic one pluralizes under `any`, an uncountable object takes neither.
        return f"`does not {base_form(verb)} a/any {obj}`"
    return static_hint


# A subordinating conjunction is how a guard clause attaches, so a sentence carrying one has
# somewhere for the guard to be and is left to the reader.
GUARD = re.compile(r"\b(so|because|since|unless|when|while|until|once|only|if|where|after"
                   r"|before|without|through|via|whenever|as long as)\b")
ABSOLUTE = re.compile(r"\b(never|always|cannot)\b")

MIRROR_PIVOT = re.compile(r"\b(rather than|instead of)\b")
DEFINITIONAL_PIVOT = re.compile(r"\b(?:is|are) not (?:a|an|the)\b")

# Four characters is the shortest prefix that separates the stems this repository uses
# (`stop`/`stay`, `read`/`real`) while still tying `costs` to `costing` and `control` to
# `controls`. Words of three letters or fewer carry no stem worth matching.
WORD = re.compile(r"[a-z][a-z-]{3,}")
# Words each side of the pivot. Five is what separates a mirror from a sentence that happens to
# reuse its own subject: `a verb on ai-tools-admin rather than a binary of its own` repeats
# `binary` from six words back, and that repeat is the topic, not a mirrored clause.
MIRROR_WINDOW = 5


def stems(text, limit=None):
    """The four-character stems of the words in `text`, optionally the first or last `limit`."""
    words = WORD.findall(text.lower())
    if limit is not None:
        words = words[-limit:] if limit > 0 else words[:-limit]
    return {word[:4] for word in words}


def mirrored(sentence, pivot):
    """True when a word stem repeats across `pivot`, which is the mirror the rule names.

    `costs you a label rather than costing the sweep a target` repeats `cost`; `shipped in the
    package rather than downloaded` does not share a stem and is a plain contrast.
    """
    match = pivot.search(sentence)
    if not match:
        return None
    left = stems(sentence[:match.start()], MIRROR_WINDOW)
    right = stems(sentence[match.end():], -MIRROR_WINDOW)
    return match if left & right else None


def unbacked_absolute(sentence):
    """An absolute in a sentence with no subordinating conjunction to hang a guard on."""
    match = ABSOLUTE.search(sentence)
    return match if match and not GUARD.search(sentence) else None


EXTRA_CHECKS = [
    ("mirrored-clause", lambda s: mirrored(s, MIRROR_PIVOT),
     "state the fact once, in one direction"),
    ("definitional", lambda s: mirrored(s, DEFINITIONAL_PIVOT), "describe the mechanism"),
    ("unbacked-absolute", unbacked_absolute, "name the guard in the same sentence"),
    ("history", re.compile(r"\b(used to|previously|was changed|formerly)\b"),
     "state current behaviour"),
    ("filler", re.compile(r"\b(simply|obviously|clearly|basically|naturally|effectively"
                          r"|actually|essentially|robust|elegant|powerful|flexible)\b"),
     "cut it"),
]

PROSE_WHOLE_FILE = (".md", ".1", ".5", ".8")


MESSAGE = "<message>"  # the path a commit message is reported under

# A line that carries its own prose and does not continue onto the next one: a Markdown heading
# or table row, a man-page macro. Joining a table would let a guard word in one row suppress a
# finding in another.
STANDALONE = re.compile(r"^\s*(\||#{1,6}\s|\.[A-Za-z])")
FENCE = re.compile(r"^\s*(```|~~~)")
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")


LINE_COMMENT = re.compile(r"^\s*(#(?!!)|//+|\*(?!/))\s?")
TRIPLE_QUOTE = re.compile(r'"""|\'\'\'')


def source_prose(line, state):
    """The prose a source line carries, and the block state after it.

    A source file contributes its comments AND its docstrings: `#`, `//`, a `/* */` block, and a
    triple-quoted Python string are all places the artifacts this standard covers live. The marker
    is dropped so the sentences rejoin cleanly.
    """
    if state:  # inside a docstring or a /* */ block; state holds its closing delimiter
        end = line.find(state)
        if end < 0:
            return LINE_COMMENT.sub("", line), state
        return LINE_COMMENT.sub("", line[:end]), None
    stripped = line.strip()
    quote = TRIPLE_QUOTE.match(stripped)
    if quote:
        delimiter = quote.group(0)
        body = stripped[len(delimiter):]
        return (body.split(delimiter)[0], None) if delimiter in body else (body, delimiter)
    if stripped.startswith("/*"):
        body = stripped[2:]
        return (body.split("*/")[0], None) if "*/" in body else (body, "*/")
    return (LINE_COMMENT.sub("", line), None) if LINE_COMMENT.match(line) else (None, None)


def prose_lines(source):
    """Yield (path, line number, raw line, prose or None), holding block state per file.

    A document or man page contributes every line. A commit message inverts the source rule -- its
    body is prose and its `#` lines are the template git strips.
    """
    last_path, state = None, None
    for path, number, line in source:
        if path != last_path:
            last_path, state = path, None
        if path == MESSAGE:
            yield path, number, line, None if line.lstrip().startswith("#") else line
        elif path.endswith(PROSE_WHOLE_FILE):
            yield path, number, line, line
        else:
            text, state = source_prose(line, state)
            yield path, number, line, text


def block_sentences(path, lines):
    """Split one joined block into sentences, each reported at the line it starts on."""
    if not path or not lines:
        return
    joined, offsets = "", []
    for number, text in lines:
        if joined:
            joined += " "
        offsets.append((len(joined), number))
        joined += text.strip()
    position = 0
    for part in SENTENCE_SPLIT.split(joined):
        part = part.strip()
        if not part:
            continue
        start = joined.index(part, position)
        yield path, max(n for offset, n in offsets if offset <= start), part
        position = start + len(part)


def sentences(source):
    """Yield (path, line number, sentence) with wrapped prose rejoined.

    A block ends at a blank line, a line carrying no prose, a standalone line, or a change of
    file. Fenced code in a document is skipped: it is not the author's prose.
    """
    block_path, block, fenced = None, [], False
    for path, number, line, text in prose_lines(source):
        if text is not None and path.endswith(PROSE_WHOLE_FILE):
            if FENCE.match(line):
                fenced = not fenced
                text = None
            elif fenced:
                text = None
        if text is not None and ALLOW_MARKER in line:
            text = None
        standalone = bool(text and text.strip() and STANDALONE.match(text))
        if not (text and text.strip()) or path != block_path or standalone:
            yield from block_sentences(block_path, block)
            block_path, block = path, []
        if not (text and text.strip()):
            continue
        if standalone:
            yield from block_sentences(path, [(number, text)])
            continue
        block.append((number, text))
    yield from block_sentences(block_path, block)


def staged_lines():
    """Yield (path, line number, line) for every line this commit adds, from the index."""
    diff = subprocess.run(
        ["git", "diff", "--cached", "-U0", "--no-color", "--diff-filter=ACM"],
        capture_output=True, text=True, check=False).stdout
    path, number = None, 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path, number = line[6:], 0
        elif line.startswith("@@"):
            hunk = re.search(r"\+(\d+)", line)
            number = int(hunk.group(1)) - 1 if hunk else 0
        elif line.startswith("+") and not line.startswith("+++") and path:
            number += 1
            yield path, number, line[1:]


def file_lines(paths):
    """Yield (path, line number, line) for every line of every readable path."""
    for path in paths:
        try:
            with open(path, errors="ignore") as handle:
                for number, line in enumerate(handle, 1):
                    yield path, number, line.rstrip("\n")
        except OSError as exc:
            print(f"prose-check: cannot read {path}: {exc}", file=sys.stderr)


BACKTICK_SPAN = re.compile(r"`[^`]*`")
QUOTED_SPAN = re.compile(r"`[^`]*`|\"[^\"]*\"")


def author_prose(path, text):
    """The sentence with the spans that are not the author's own prose blanked out.

    A backticked span is a code reference in either kind of file. A double-quoted span is a
    quotation in a DOCUMENT -- most often the labelled bad example a style guide has to contain --
    so documents drop it too. A comment keeps its quoted text, because a message template quoted
    in a comment is prose this standard covers.
    """
    span = QUOTED_SPAN if path.endswith(PROSE_WHOLE_FILE) else BACKTICK_SPAN
    # " -- " rather than a space: a removed span must still separate the words around it, or
    # `takes \x60--for\x60 no target` fuses into a phrase the patterns then match.
    return span.sub(" -- ", text)


def findings(source, checks):
    for path, number, sentence in sentences(source):
        subject = author_prose(path, sentence)
        for name, check, hint in checks:
            match = check.search(subject) if hasattr(check, "search") else check(subject)
            if match:
                yield path, number, name, match.group(0), suggest(name, match, hint), sentence


def main():
    parser = argparse.ArgumentParser(
        description="report prose figures the writing standard rules out")
    parser.add_argument("--staged", action="store_true",
                        help="check the lines this commit adds")
    parser.add_argument("--message", metavar="FILE",
                        help="check a commit message; template comments skipped")
    parser.add_argument("--all", action="store_true",
                        help="add the shape checks")
    parser.add_argument("paths", nargs="*", help="files to read whole")
    args = parser.parse_args()

    modes = [args.staged, bool(args.message), bool(args.paths)]
    if sum(1 for mode in modes if mode) != 1:
        parser.error("give exactly one of --staged, --message FILE, or one or more paths")

    checks = DEFAULT_CHECKS + (EXTRA_CHECKS if args.all else [])
    if args.staged:
        source = staged_lines()
    elif args.message:
        source = ((MESSAGE, number, line.rstrip("\n"))
                  for number, line in enumerate(open(args.message, errors="ignore"), 1))
    else:
        source = file_lines(args.paths)

    count = 0
    for path, number, name, token, hint, text in findings(source, checks):
        count += 1
        print(f"{path}:{number}: {name} [{token}] -- {hint}")
        print(f"    {text[:110]}")
    if count:
        print(f"\n{count} finding(s). See the ai-tools-technical-docs skill; "
              f"mark a deliberate example with '{ALLOW_MARKER}'.")
    return 1 if count else 0


if __name__ == "__main__":
    sys.exit(main())

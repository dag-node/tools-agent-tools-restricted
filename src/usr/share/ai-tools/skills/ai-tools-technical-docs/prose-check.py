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
# Shell files contribute their comment lines, Markdown and man pages every line. The patterns
# match English, so they carry to any codebase.
#
# The default checks are the two that scored above 95% precision when sampled against this
# repository. `--all` adds four more that report correct prose often enough to need a reader on
# every hit -- `cannot` scored 0 of 6, because the rule it implements ("with no guard named in the
# same sentence") is not a property a regex can see.
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
        return f"`does not {base_form(verb)} any {obj}`"
    return static_hint


EXTRA_CHECKS = [
    ("mirrored-clause", re.compile(r"\brather than\b"), "state the fact once, in one direction"),
    ("definitional", re.compile(r"\bis not (a|an|the)\b|\bis no\b"), "describe the mechanism"),
    ("unbacked-absolute", re.compile(r"\b(never|always|cannot)\b"),
     "name the guard in the same sentence"),
    ("history", re.compile(r"\b(used to|previously|no longer|was changed)\b"),
     "state current behaviour"),
    ("filler", re.compile(r"\b(simply|obviously|clearly|basically|naturally|effectively"
                          r"|actually|essentially|robust|elegant|powerful|flexible)\b"),
     "cut it"),
]

PROSE_WHOLE_FILE = (".md", ".1", ".5", ".8")


MESSAGE = "<message>"  # the path a commit message is reported under


def is_prose_line(path, line):
    """True when this line carries prose: any line of a document, a comment in a script.

    A commit message inverts the script rule -- its body is prose and its `#` lines are the
    template git strips -- so it is passed under its own path and tested here.
    """
    if path == MESSAGE:
        return not line.lstrip().startswith("#")
    if path.endswith(PROSE_WHOLE_FILE):
        return True
    stripped = line.lstrip()
    return stripped.startswith("#") and not stripped.startswith("#!")


def staged_lines():
    """Yield (path, line) for every line this commit adds, from the index."""
    diff = subprocess.run(
        ["git", "diff", "--cached", "-U0", "--no-color", "--diff-filter=ACM"],
        capture_output=True, text=True, check=False).stdout
    path = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
        elif line.startswith("+") and not line.startswith("+++") and path:
            yield path, line[1:]


def file_lines(paths):
    """Yield (path, line) for every line of every readable path."""
    for path in paths:
        try:
            with open(path, errors="ignore") as handle:
                for line in handle:
                    yield path, line.rstrip("\n")
        except OSError as exc:
            print(f"prose-check: cannot read {path}: {exc}", file=sys.stderr)


BACKTICK_SPAN = re.compile(r"`[^`]*`")
QUOTED_SPAN = re.compile(r"`[^`]*`|\"[^\"]*\"")


def author_prose(path, line):
    """The line with the spans that are not the author's own prose blanked out.

    A backticked span is a code reference in either kind of file. A double-quoted span is a
    quotation in a DOCUMENT -- most often the labelled bad example a style guide has to contain --
    so documents drop it too. A comment keeps its quoted text, because a message template quoted
    in a comment is prose this standard covers.
    """
    span = QUOTED_SPAN if path.endswith(PROSE_WHOLE_FILE) else BACKTICK_SPAN
    # " -- " rather than a space: a removed span must still separate the words around it, or
    # `takes \x60--for\x60 no target` fuses into a phrase the patterns then match.
    return span.sub(" -- ", line)


def findings(source, checks):
    for path, line in source:
        if ALLOW_MARKER in line or not is_prose_line(path, line):
            continue
        subject = author_prose(path, line)
        for name, pattern, hint in checks:
            match = pattern.search(subject)
            if match:
                yield path, name, match.group(0), suggest(name, match, hint), line.strip()


def main():
    parser = argparse.ArgumentParser(
        description="report prose figures the writing standard rules out")
    parser.add_argument("--staged", action="store_true",
                        help="check the lines this commit adds")
    parser.add_argument("--message", metavar="FILE",
                        help="check a commit message; template comments skipped")
    parser.add_argument("--all", action="store_true",
                        help="add the lower-precision checks")
    parser.add_argument("paths", nargs="*", help="files to read whole")
    args = parser.parse_args()

    modes = [args.staged, bool(args.message), bool(args.paths)]
    if sum(1 for m in modes if m) != 1:
        parser.error("give exactly one of --staged, --message FILE, or one or more paths")

    checks = DEFAULT_CHECKS + (EXTRA_CHECKS if args.all else [])
    if args.staged:
        source = staged_lines()
    elif args.message:
        source = ((MESSAGE, line.rstrip("\n")) for line in open(args.message, errors="ignore"))
    else:
        source = file_lines(args.paths)

    count = 0
    for path, name, token, hint, text in findings(source, checks):
        count += 1
        print(f"{path}: {name} [{token}] -- {hint}")
        print(f"    {text[:110]}")
    if count:
        print(f"\n{count} finding(s). See the ai-tools-technical-docs skill; "
              f"mark a deliberate example with '{ALLOW_MARKER}'.")
    return 1 if count else 0


if __name__ == "__main__":
    sys.exit(main())

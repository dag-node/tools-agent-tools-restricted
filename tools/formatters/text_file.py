#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Read and write the files a formatter rewrites, refusing what is not plain text.

```bash
python3 tools/formatters/text_file.py [--] <file>...
```

The one reader and writer of `tools/formatters/fill-markdown.py`, `tools/formatters/align-tables.py` and
`tools/formatters/verify-reflow.py`, and the vetting `tools/formatters/fill-comments.sh` runs over each file before
Emacs sees it, so every formatter refuses the same file for the same reason and rewrites only
what it read whole. The command line vets each path and exits 1 when one is refused, naming it
on stderr; a formatter runs the same check through `read()`.

A file is refused, and left as it is, when it is not what a formatter can read as text:

- a symlink, or anything but a regular file -- a formatter writes back where it read, and a link
  would carry that write outside the tree;
- larger than `MAX_BYTES`;
- holding a NUL byte, or bytes that are not UTF-8, or opening with a byte-order mark;
- holding a carriage return, so a CRLF file is never rewritten with mixed line ends;
- holding a character the Unicode database files under Other -- a control character other than tab
  and newline (an escape sequence starts with one), a format character (a bidi override,
  a zero-width joiner, a soft hyphen), a surrogate, a private-use or an unassigned code point -- or
  a line or paragraph separator. Each is invisible or changes how the text around it reads, and a
  formatter that rewraps such a line moves what it cannot see.

Refused rather than stripped, so the file is looked at. A write refuses the same text, and a file
that changed between the read and the write, so a formatter never writes over an edit it did not
read.
"""
from __future__ import annotations

import argparse
import errno
import os
import re
import stat
import sys
import unicodedata

MAX_BYTES = 4 * 1024 * 1024
"""The largest file a formatter reads: forty times the largest text file this tree holds."""

_ASCII_OFFENDER = re.compile(r"[^\t\n\x20-\x7e]")
# What a refused category is called where the character has no name of its own.
_CATEGORY = {"Cc": "a control character", "Cf": "a format character", "Cs": "a surrogate",
             "Co": "a private-use character", "Cn": "an unassigned code point",
             "Zl": "a line separator", "Zp": "a paragraph separator"}


class Refused(Exception):
    """A path a formatter does not read or write, with the reason, as `refused <path>: <reason>`."""

    def __init__(self, path: str, reason: str) -> None:
        super().__init__(f"refused {path}: {reason}")
        self.path, self.reason = path, reason


def offending_character(text: str) -> str | None:
    """The reason `text` is refused, or None where every character is one a formatter reads.

    Named with its line, its code point and its Unicode name, so the byte is found without a hex
    dump: `line 12 holds U+202E (RIGHT-TO-LEFT OVERRIDE)`.
    """
    if "\r" in text:
        return f"line {_line_of(text, text.index(chr(13)))} holds a carriage return"
    if text.isascii():
        match = _ASCII_OFFENDER.search(text)
        found = match.start() if match else None
    else:
        found = next((index for index, char in enumerate(text)
                      if (unicodedata.category(char)[0] == "C" and char not in "\t\n")
                      or unicodedata.category(char) in ("Zl", "Zp")), None)
    if found is None:
        return None
    char = text[found]
    name = unicodedata.name(char, _CATEGORY.get(unicodedata.category(char), "unreadable"))
    return f"line {_line_of(text, found)} holds U+{ord(char):04X} ({name})"


def _line_of(text: str, index: int) -> int:
    """The 1-based line `index` falls on in `text`."""
    return text.count("\n", 0, index) + 1


def decode(path: str, data: bytes) -> str:
    """`data` as text, or `Refused` naming `path` and what makes the bytes unreadable as text."""
    if len(data) > MAX_BYTES:
        raise Refused(path, f"is {len(data)} bytes, over the {MAX_BYTES} a formatter reads")
    if b"\0" in data:
        offset = data.index(b"\0")
        raise Refused(path, f"holds a NUL byte at offset {offset}, so it is not text")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        line = data.count(b"\n", 0, exc.start) + 1
        raise Refused(path, f"is not UTF-8 at byte {exc.start} (line {line})") from None
    if text.startswith("\ufeff"):
        raise Refused(path, "opens with a byte-order mark")
    reason = offending_character(text)
    if reason is not None:
        raise Refused(path, reason)
    return text


def _open(path: str, flags: int) -> tuple[int, os.stat_result]:
    """`path` opened with `flags` and never through a symlink, with its stat; `Refused` otherwise.

    Opened without blocking, so a FIFO is refused as not regular instead of waiting for its writer;
    on the regular file that passes, the flag has no effect.
    """
    try:
        descriptor = os.open(
            path, flags | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as exc:
        if exc.errno == errno.ELOOP or os.path.islink(path):
            raise Refused(path, "is a symlink") from None
        if exc.errno == errno.ENXIO:
            raise Refused(path, "is not a regular file") from None
        raise
    seen = os.fstat(descriptor)
    if not stat.S_ISREG(seen.st_mode):
        os.close(descriptor)
        raise Refused(path, "is not a regular file")
    return descriptor, seen


def read(path: str) -> tuple[str, os.stat_result]:
    """`path`'s text and the stat it was read at, for `write()`; `Refused` where it is not text.

    An unreadable path raises the `OSError` as it is, since that is a permission or a missing
    file rather than a refusal.
    """
    descriptor, seen = _open(path, os.O_RDONLY)
    try:
        if seen.st_size > MAX_BYTES:
            raise Refused(path, f"is {seen.st_size} bytes, over the {MAX_BYTES} a formatter reads")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            data = handle.read(MAX_BYTES + 1)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return decode(path, data), seen


def write(path: str, text: str, seen: os.stat_result) -> None:
    """Write `text` over `path` in place, keeping its inode, owner, mode and ACL.

    `seen` is the stat `read()` returned: a file whose identity, size or modification time moved
    since then was edited by someone else, and is refused rather than overwritten. The text is
    vetted as a read would vet it.
    """
    reason = offending_character(text)
    if reason is not None:
        raise Refused(path, f"the formatted text {reason}")
    data = text.encode("utf-8")
    if len(data) > MAX_BYTES:
        raise Refused(path, f"the formatted text is {len(data)} bytes, over {MAX_BYTES}")
    descriptor, now = _open(path, os.O_WRONLY)
    try:
        if (now.st_dev, now.st_ino, now.st_size, now.st_mtime_ns) != (
                seen.st_dev, seen.st_ino, seen.st_size, seen.st_mtime_ns):
            raise Refused(path, "changed since it was read")
        written = 0
        while written < len(data):
            written += os.write(descriptor, data[written:])
        os.ftruncate(descriptor, len(data))
    finally:
        os.close(descriptor)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="refuse a file a formatter must not rewrite")
    parser.add_argument("paths", nargs="+", metavar="FILE")
    args = parser.parse_args(argv)
    status = 0
    for path in args.paths:
        try:
            read(path)
        except Refused as exc:
            print(exc, file=sys.stderr)
            status = 1
        except OSError as exc:
            print(f"cannot read {path}: {exc.strerror}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())

# SPDX-License-Identifier: AGPL-3.0-only
"""Rewrite the links an installed documentation page cannot resolve to the release's tag on the repository.

The package installs `docs/` and `README.md` alone of the source tree, so a page's relative link
to a rule, `CLAUDE.md` or a source file resolves in a checkout and on GitHub and not under
`/usr/share/doc/ai-tools`. The spec runs this over the build tree's copy before `%doc` collects it, and each such link
becomes the same path, anchor kept, at `<base>/blob/<tag>/`, so an installed link reaches the version installed.
A link that stays inside the installed tree, an absolute URL, a page anchor, and a link inside a fenced code block are
left as written. A checkout is never edited, since `ref-index.sh` checks and relinks the relative form there.

    `python3 -I packaging/rewrite-doc-links.py --base <url> --version <X.Y.Z> [--release <rpm-release>] <root>`

<root> is the tree holding `docs/` and `README.md`. The tag is `v<version>`, or `v<version>-rc.<N>` for the Release
`0.rc<N>` a prerelease build takes (`.github/workflows/ci.yml`). Exits 0 with a line naming the count and the URL
prefix on stdout, 2 for a usage error, and 1 when a link resolves outside <root>, which no tag can serve; the files
are then left as they were.
"""

import argparse
import os
import re
import sys

# An inline link or image, `[text](target)` or `![alt](target "title")`, and a reference definition,
# `[label]: target "title"`. The target ends at whitespace or the closing parenthesis.
INLINE = re.compile(r"(\]\()([^)\s]+)")
DEFINITION = re.compile(r"^(\s{0,3}\[[^\]]+\]:\s*)(\S+)", re.M)
FENCE = re.compile(r"^\s{0,3}(```|~~~)")
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def tag_for(version, release):
    """Return the git tag the build's sources were cut from: `v<version>`, or `v<version>-rc.<N>` for `0.rc<N>`."""
    match = re.fullmatch(r"0\.rc(\d+)", release or "")
    return f"v{version}-rc.{match.group(1)}" if match else f"v{version}"


def rewrite_target(target, page, prefix, outside):
    """Return <target> as the installed page <page> reaches it: unchanged, or the URL under <prefix>."""
    if not target or target.startswith(("#", "/")) or SCHEME.match(target):
        return target
    path, hash_sign, anchor = target.partition("#")
    resolved = os.path.normpath(os.path.join(os.path.dirname(page), path))
    if resolved == ".." or resolved.startswith("../"):
        outside.append(f"{page}: {target}")
        return target
    if resolved in ("README.md", "docs") or resolved.startswith("docs/"):
        return target
    return f"{prefix}{resolved}{hash_sign}{anchor}"


def rewrite_page(text, page, prefix, outside):
    """Return <text> with every link outside a fenced block rewritten, and the number rewritten."""
    out, count, fenced = [], 0, False
    for line in text.splitlines(keepends=True):
        if FENCE.match(line):
            fenced = not fenced
        if fenced or FENCE.match(line):
            out.append(line)
            continue

        def inline(match):
            nonlocal count
            new = rewrite_target(match.group(2), page, prefix, outside)
            count += new != match.group(2)
            return match.group(1) + new

        def definition(match):
            nonlocal count
            new = rewrite_target(match.group(2), page, prefix, outside)
            count += new != match.group(2)
            return match.group(1) + new

        out.append(DEFINITION.sub(definition, INLINE.sub(inline, line)))
    return "".join(out), count


def main():
    parser = argparse.ArgumentParser(description="rewrite installed-docs links that leave the installed tree")
    parser.add_argument("--base", required=True, help="the repository URL, https://github.com/<owner>/<repo>")
    parser.add_argument("--version", required=True, help="the package Version")
    parser.add_argument("--release", default="", help="the rpm_release the build was given, if any")
    parser.add_argument("root", help="the tree holding docs/ and README.md")
    args = parser.parse_args()

    prefix = f"{args.base.rstrip('/')}/blob/{tag_for(args.version, args.release)}/"
    pages = ["README.md"] if os.path.isfile(os.path.join(args.root, "README.md")) else []
    for directory, _, names in os.walk(os.path.join(args.root, "docs")):
        pages += [os.path.relpath(os.path.join(directory, name), args.root) for name in names if name.endswith(".md")]

    rewritten, outside, total = {}, [], 0
    for page in sorted(pages):
        with open(os.path.join(args.root, page), encoding="utf-8") as handle:
            text = handle.read()
        new, count = rewrite_page(text, page, prefix, outside)
        if count:
            rewritten[page] = new
            total += count
    if outside:
        sys.stderr.write("links that resolve outside the source tree:\n" + "".join(f"  {o}\n" for o in outside))
        return 1
    for page, new in rewritten.items():
        with open(os.path.join(args.root, page), "w", encoding="utf-8") as handle:
            handle.write(new)
    print(f"rewrote {total} documentation link(s) to {prefix}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

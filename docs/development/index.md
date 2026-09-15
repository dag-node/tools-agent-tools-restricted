# Development

**Development** · [Release](release.md) — [all docs](../index.md)

Working on `ai-tools` itself: where the setup, the checks and the commit
conventions are written down, and how a change reaches a signed package.

[CONTRIBUTING.md](../../CONTRIBUTING.md) is the entry point for a change —
development setup, running the tests, the linters, commit style,
and what a pull request is expected to carry. The documentation conventions are
there too, and the rules a coding agent loads live beside the code they
describe, under `.claude/rules/`.

[Release](release.md) is the process on top of that: the branch model, the tag
and version grammar, and the commands for each step. One rule shapes the rest —
the distribution channel is a function of the tag rather than of the branch,
so a bare `vX.Y.Z` and a pre-release tag land in different places from the same
branch.

[RPM packaging](../rpm-packaging.md) covers the package set, the scriptlets,
and the build, which a maintainer reads together with the release process.

# Contributing

Setting up a checkout, running the checks a pull request is expected to pass,
and the conventions for commits, documentation, and branches.

## Before you start

This is a security-sensitive project — it runs an autonomous coding agent
under a locked-down system account with a defined trust boundary (see
`CLAUDE.md`). Changes that touch confinement (SELinux policy, sudoers,
the handback socket, ownership handoff, secret detection) get read more
carefully than everything else; explain the security reasoning in the PR
description, not just the mechanism.

## Development setup

From a source checkout:

```bash
sudo ./install.sh install              # the wrapper, helpers, systemd units
sudo ai-tools-admin system bootstrap   # the sandbox account's Node toolchain
```

`install.sh` is the last of four steps, and it stops until the first three have
run. [`docs/install/from-source.md`](docs/install/from-source.md) has all four,
for a host without the RPM.

Optional, recommended for regular contributors:

```bash
make -C packaging hooks          # enable the local git hooks (non-blocking reminders)
```

A per-clone developer opt-in: it sets `core.hooksPath` to `.githooks`
and quiets git's ignored-hook advice for sandbox-account commits. Two hooks
come with it, and neither blocks a commit: a `commit-msg` changelog reminder,
and a `pre-commit` prose report over the lines the commit adds
(`prose-check.py`, shipped with the `ai-tools-technical-docs` skill). None
of this ships in the RPM — the package builds only from `src/`, `docs/`,
the spec, and the compiled policy.

## Running the tests

```bash
sudo tests/run.sh [unit|integration|boundary|all]
```

Run via `sudo`, not as `root` directly — the harness derives the unprivileged
project user from `SUDO_USER`. What each category proves and what a host needs
before it runs are in [`docs/tests/index.md`](docs/tests/index.md); how a test
is written is in `.claude/rules/tests.rule.md`.

For a full package-build, install, and confined-launch smoke test
in a throwaway container: `make -C packaging rpmtest-rocky9` (or
`rpmtest-rocky10`).

## Linting

Shell sources lint under ShellCheck 0.10 — the version the baseline
in `.claude/rules/shellcheck.rule.md` is defined against — with the repo's
`.shellcheckrc`. The baseline covers `src/**/*.sh` plus `install.sh`:

```bash
find src -name '*.sh' -print0 | xargs -0 shellcheck
shellcheck install.sh
```

Extending lint coverage to `tests/`, `selinux/`, or `packaging/` means
verifying the directory lints clean and updating the rule file
and `.github/workflows/ci.yml` together. That workflow runs both the lint
and the container smoke test on every push and pull request.

## Commit style

Commit messages follow `type(scope): summary` (`feat`, `fix`, `docs`, `test`,
`chore`, `refactor`) — check `git log` for examples. Keep the "why"
in the body, not the title.

### AI-assisted commits

Commits in this repository frequently carry a `Co-Authored-By` trailer naming
an AI model. This records how the change was produced. It does not assert
copyright: model output is not separately copyrightable and Anthropic does not
claim rights in it. Every commit is authored, reviewed, and signed
off by a human contributor, whose CLA covers the contribution in full.

## Documentation

`CLAUDE.md` plus `.claude/rules/*.rule.md` are the reference docs for how each
component works; a rule file's `paths:` frontmatter scopes it to the source it
describes. If a change alters behavior a rule file documents, update the rule
file in the same PR — the two are meant to stay in sync, and a mismatch is
treated as a bug in whichever one didn't get updated. The pages
under [`docs/`](docs/index.md) are the operator's tier instead, and change
when a command, a configuration key, or a guarantee does.

A reference into another file names a reftag rather than a position;
the grammar is in the `ai-tools-technical-docs` skill,
and `.claude/references.md` is the generated index. After adding, moving,
or deleting a labelled target or a reference, regenerate the index and check
the tree:

```bash
bash tools/generators/ref-index.sh generate
bash tools/generators/ref-index.sh check
```

The pre-commit hook reports a stale index and any reference finding,
and the unit suite fails on either.

## Pull requests

Branch from `develop`, not `main`, using `<type>/<id>-<name>` — the type
from [Commit style](#commit-style), then a lowercase id and a short slug,
so `feat/atr-260625-rpm-package` — and target `develop` when opening the PR.
A change of one or two commits with no breaking change lands straight
on `develop` instead.

Give the PR an explicit title, in the same `type(scope): summary` form
as a commit subject. Left blank it is GitHub's, derived from the branch name,
and the merge commit keeps that derivation for good.

The full branch model, tag grammar, and release process (RCs, channels,
rehearsal) are in [`docs/development/release.md`](docs/development/release.md).

## License

All contributions are made under the project's license, `AGPL-3.0-only` (see
`LICENSE`). By submitting a change, you agree it may be distributed under those
terms, and a Contributor License Agreement — handled by [CLA
Assistant](https://cla-assistant.io/) when you open a pull request — covers it.

Some files in the tree are under other licenses. Each one states
which in an `SPDX-License-Identifier` header, and `REUSE.toml` supplies
the license and copyright for every file that does not. Add the header when you
add a file.

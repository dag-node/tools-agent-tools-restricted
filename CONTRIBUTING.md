# Contributing

## Before you start

This is a security-sensitive project — it runs an autonomous coding agent under a
locked-down system account with a defined trust boundary (see `CLAUDE.md`). Changes
that touch confinement (SELinux policy, sudoers, the handback socket, ownership
handoff, secret detection) get read more carefully than everything else; explain the
security reasoning in the PR description, not just the mechanism.

## License

All contributions are made under the project's license, AGPL-3.0-or-later (see
`LICENSE`). By submitting a change, you agree it may be distributed under those terms.

## Development setup

From a source checkout:

    sudo ./install.sh install        # deploys the wrapper, helpers, systemd units
    sudo ai-tools-bootstrap          # provisions the sandbox account's Node toolchain

See the root `README.md`'s manual install steps if you're working without the RPM.

Optional, recommended for regular contributors:

    make -C packaging hooks          # enable the local git hooks (a non-blocking changelog reminder)

A per-clone developer opt-in: it sets `core.hooksPath` to `.githooks` and quiets git's
ignored-hook advice for sandbox-account commits. None of this ships in the RPM — the
package builds only from `src/`, `docs/`, the spec, and the compiled policy.

## Running the tests

    sudo tests/run.sh [unit|integration|boundary|all]

Run via `sudo`, not as `root` directly — the harness checks `SUDO_USER`. The three
categories (see `.claude/rules/tests.rule.md`): `unit` (hermetic, no live daemon),
`integration` (deployed perms/sudoers/wrapper/handback/systemd), `boundary` (confinement
checks run as the sandbox account). `all` runs every category.

For a full package-build + install + confined-launch smoke test in a throwaway
container:

    make -C packaging rpmtest-rocky9     # or rpmtest-rocky10

## Linting

Shell sources lint under ShellCheck 0.10 (the version the baseline in
`.claude/rules/shellcheck.rule.md` is defined against) with the repo's `.shellcheckrc`.
The baseline covers `src/**/*.sh` plus `install.sh`:

    find src -name '*.sh' -print0 | xargs -0 shellcheck
    shellcheck install.sh

Extending lint coverage to `tests/`, `selinux/`, or `packaging/` means verifying the
directory lints clean and updating the rule file and `.github/workflows/ci.yml`
together.

`.github/workflows/ci.yml` runs both the lint and the container smoke test on every
push and pull request.

## Commit style

Commit messages follow `type(scope): summary` (`feat`, `fix`, `docs`, `test`, `chore`,
`refactor`) — check `git log` for examples. Keep the "why" in the body, not the title.

## Documentation

`CLAUDE.md` plus `.claude/rules/*.rule.md` are the reference docs for how each
component works; a rule file's `paths:` frontmatter scopes it to the source it
describes. If a change alters behavior a rule file documents, update the rule file in
the same PR — the two are meant to stay in sync, and a mismatch is treated as a bug in
whichever one didn't get updated.

## Pull requests

Branch from `develop`, not `main`, using `feature/<ticket-num>-<feature-name>` (e.g.
`feature/260625-rpm-package`) — and target `develop` when opening the PR. The full branch
model, tag grammar, and release process (RCs, channels, rehearsal) are in
[`docs/branching-and-release.md`](docs/branching-and-release.md).

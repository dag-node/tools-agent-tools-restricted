# Branching and release

How a change travels from a feature branch to a signed RPM on `rpm.dagnode.com` — the branch
model, the tag/version grammar, and the exact commands for each step. Pipeline mechanics
(signing, verification, the dag-node/rpm publish) are specified in
[rpm-packaging.md](rpm-packaging.md) and `.github/workflows/ci.yml`; this doc is the process
guideline on top of them.

## The one rule that decides everything else

**The channel is a function of the tag, never of the branch.** A bare `vX.Y.Z` tag publishes to
stable; a `vX.Y.Z-rc.N` tag publishes a GitHub prerelease; no tag publishes nothing. Branches
only decide where commits land — `develop` for integration, `main` as the last-released state.
The publish side (`repository_dispatch` to dag-node/rpm) only ever sees the tag, so nothing else
could carry the decision.

## Flow

```
      feature/<ticket>-<name>
                |
                | PR -> develop; the operator merges manually
                v
             develop <--------------------------------------------.
                |                                                 |
                |  every push: shellcheck + rpm-selftest (EL9+10) |
                |  snapshot RPMs, Release: 0.<run>.git<sha>       |  fixes during
                |  (workflow artifacts only, never published)     |  stabilization
                |                                                 |
                |  tag vX.Y.Z-rc.N on develop                     |
                |  (packaging/VERSION already bumped to X.Y.Z)    |
                v                                                 |
      +---------------------+          red                        |
      |  release job (RC)   | ------------------------------------'
      |  build+sign+verify  |
      +---------------------+
                | green
                v
      GitHub prerelease: RPMs X.Y.Z-0.rcN            == testing channel
                |
                |  last RC is green: finalize %changelog,
                |  merge develop -> main (the ONE merge per release),
                |  tag vX.Y.Z on main
                v
      +---------------------+
      | release job (final) |
      | build+sign+verify   |
      +---------------------+
                |
                v
      GitHub Release: RPMs X.Y.Z-1                   == stable channel
      + notify dag-node/rpm -> rpm.dagnode.com


      (any time, any branch)
      workflow_dispatch -> rehearsal: the full build+sign+verify path runs,
      publish steps are skipped, signed output lands as a workflow artifact
```

Tag shape, RPM `Release`, and destination at a glance:

| Trigger              | RPM Version-Release   | Published to                                    |
|----------------------|-----------------------|-------------------------------------------------|
| push / PR (no tag)   | `X.Y.Z-0.<run>.git<sha>` | workflow artifact only                       |
| `workflow_dispatch`  | `X.Y.Z-0.<run>.rehearsal.git<sha>` | workflow artifact only (rehearsal)  |
| tag `vX.Y.Z-rc.N`    | `X.Y.Z-0.rcN`         | GitHub **prerelease**                           |
| tag `vX.Y.Z`         | `X.Y.Z-1`             | GitHub Release + `rpm.dagnode.com` (stable)     |

The `Release` prefixes are the Fedora pre-release convention: rpm's version comparison ranks
`0.<run>.git<sha>` and `0.rcN` below the final `1`, so a host that installed an RC upgrades
cleanly to the final via ordinary `dnf`, and a real release always outranks any snapshot.

## For developers

```bash
git switch develop && git pull
git switch -c feature/260718-my-change
# ...work, commit...
git push -u origin feature/260718-my-change   # open a PR targeting develop
```

Branches are cut from `develop` and named `feature/<ticket>-<name>`; PRs target `develop`, and
the operator merges them manually. Every push runs `shellcheck` and the full `rpm-selftest`
matrix and uploads snapshot RPMs as workflow artifacts, so a build off any commit is
inspectable without cutting a release. Do not push `v*` tags — a tag ruleset restricts tag
creation to maintainers, because under the rule above a tag *is* a release decision.

There are no standing `release/X.Y` branches. Cut one only when stabilization must diverge —
holding X.Y for release while `develop` moves on to X.Y+1, or hotfixing an old minor.

## For maintainers: cutting a release

### 0. Rehearse after touching the pipeline

```bash
gh workflow run ci.yml --ref develop
```

A `workflow_dispatch` run executes the real release path — clean build, in-container signing of
real RPMs, `podman cp` extraction, runner-side `rpmkeys -Kv` verification — with the publish
steps (`Create GitHub Release`, the dag-node/rpm notify) skipped, and uploads the signed output
as a workflow artifact. Use it whenever `ci.yml`, `sign-rpms.sh`, or `packaging/` change: it
proves the plumbing without version identity or publish. It is not a substitute for an RC —
a rehearsal tests the pipeline, an RC tests a release candidate.

### 1. Cut a release candidate (tag on `develop`)

```bash
echo 0.6.3 > packaging/VERSION
git commit -am "chore(release): bump VERSION to 0.6.3"
git push
git tag v0.6.3-rc.1 && git push origin v0.6.3-rc.1
```

An RC carries the *next* version (SemVer: `0.6.3-rc.1` sorts above the released `0.6.2` and
below the eventual `0.6.3`). `check-version.sh` verifies the tag's base `X.Y.Z` against
`packaging/VERSION` but relaxes the `%changelog` match — RC notes aren't finalized. The release
job builds `0.6.3-0.rc1`, signs and verifies it, and publishes a GitHub **prerelease**; the
stable repo never sees it. Install an RC by downloading the prerelease zip. Fixes land on
`develop` as normal commits, followed by `rc.2`, `rc.3`, … — no `main` merges, no re-tags.

### 2. Finalize (the one merge to `main`)

```bash
# on develop, pointing at the last green RC commit:
vi packaging/ai-tools.spec        # finalize the %changelog entry for 0.6.3
git commit -am "chore(release): finalize %changelog for 0.6.3"
git push
git switch main && git pull
git merge develop
git push
git tag v0.6.3 && git push origin v0.6.3
```

The final tag points at the last green RC's content plus only the `%changelog` finalization —
no functional commits slip in between `rc.N` and final, so what ships is what the RC tested
(the RPM is rebuilt because `0.rcN` and `1` are different `Release` values, but from the same
source). `check-version.sh` enforces the full tag = `VERSION` = newest-`%changelog` agreement.
The job builds `0.6.3-1`, signs, verifies, publishes the GitHub Release, and notifies
dag-node/rpm, which rebuilds `rpm.dagnode.com`. This merge is the only `develop` → `main`
merge of the release.

### 3. Open the next cycle

```bash
git switch develop
echo 0.6.4 > packaging/VERSION
git commit -am "chore(release): bump VERSION to 0.6.4"
git push
```

After the final release publishes, bump `packaging/VERSION` on `develop` to the next
anticipated version. Dev/snapshot RPMs (`Release: 0.<n>.git<sha>`) then sort above the last
release and below the next one; left at the released number, a newer snapshot sorts as an
older package.

### If the release job goes red

The job is fail-closed and idempotent: signing or verification failure stops it before anything
is public, and re-running the workflow refreshes release assets (`gh release upload --clobber`)
and re-fires the notify rather than duplicating. A tag/`VERSION`/`%changelog` mismatch is fixed
by committing the correction and re-tagging; a pipeline defect is fixed on `develop`, proven
with a rehearsal, then released as the next `rc.N` — never by iterating merges to `main`.

## Guardrails behind the process

Signing is mandatory and preflight-checked before anything builds; fork PRs never see the
signing secret (the release job runs only on tags and `workflow_dispatch`); `v*` tag creation
is restricted to maintainers by a ruleset. Details in
[rpm-packaging.md](rpm-packaging.md#signing-and-distribution).

Rehearsal RPMs are signed with the real key, so they carry the distinct Release
`0.<run>.rehearsal.git<sha>` — a leaked rehearsal artifact can never share a NEVRA with, and
so never impersonate, a published `X.Y.Z-1` package.

One-time setup (repo admin), in GitHub Settings:

- **Rules → Rulesets → New tag ruleset** — enforcement *Active*, target tags matching `v*`,
  restrict *creation*, *update*, and *deletion*, bypass list *Repository admin* only. The tag
  is the entire release authority under the rule above, so it gets `main`-level protection.
- **Actions → General** — default workflow permissions *Read repository contents* (the
  release job requests `contents: write` explicitly); leave "Allow GitHub Actions to create
  and approve pull requests" off; require approval for workflow runs from all outside
  collaborators. Actions permissions: *Allow dag-node, and select non-dag-node, actions* with
  only *Allow actions created by GitHub* checked (every action used is `actions/*`), and
  *Require actions to be pinned to a full-length commit SHA* on — set org-wide so every
  dag-node repo inherits both. In the org's *Fork pull request workflows in private and
  internal repositories* block, disable *Run workflows from fork pull requests* — the org has
  no private repos taking fork contributions, and disabling the parent pins the write-token
  and secrets sub-options off for every repo admin.
- **Advanced Security** — enable secret scanning and push protection.

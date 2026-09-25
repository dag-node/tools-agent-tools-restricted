# Branching and release

[Development](index.md) · **Release** — [all docs](../index.md)

How a change travels from a feature branch to a signed RPM on `rpm.dagnode.com`
— the branch model, the tag/version grammar, and the exact commands for each
step. Pipeline mechanics (signing, verification, the dag-node/rpm publish) are
specified in [RPM packaging](../rpm-packaging.md)
and `.github/workflows/ci.yml`; this doc is the process guideline on top
of them.

## The one rule that decides everything else

**The channel is a function of the tag, never of the branch.** A bare `vX.Y.Z`
tag publishes to stable; a `vX.Y.Z-rc.N` tag publishes a GitHub prerelease;
an untagged push does not publish anything. Branches only decide where commits
land — `develop` for integration, `main` as the last-released state.
The publish side (`repository_dispatch` to dag-node/rpm) only ever sees
the tag, so no other input could carry the decision.

## Flow

```
      feat/atr-yyMMdd-<name>
                |
                | PR -> develop; the operator merges manually
                v
             develop <--------------------------------------------.
                |                                                 |
                |  every push: shellcheck, typesafe-client,       |
                |  rpm-selftest (EL9+10); snapshot RPMs,          |
                |  Release: 0.<run>.git<sha>                      |  fixes during
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


      (a published X.Y.Z needs a fix)
      fix/<id>-<name>, cut from the tag vX.Y.Z
                |  proven green BEFORE the PR merges
                |  last commit: VERSION + %changelog for X.Y.Z+1
                v
             main -> tag vX.Y.Z+1 -> stable, then merge main back
                                     into develop


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

The `Release` prefixes are the Fedora pre-release convention: rpm's version
comparison ranks `0.<run>.git<sha>` and `0.rcN` under the final `1`, so a host
that installed an RC upgrades cleanly to the final via ordinary `dnf`,
and a real release always outranks any snapshot.

## For developers

```bash
git switch develop && git pull
git switch -c feat/atr-260718-my-change
# ...work, commit...
git push -u origin feat/atr-260718-my-change   # open a PR targeting develop
```

Branches are cut from `develop` and named `<type>/<id>-<name>`, lowercase
throughout and without spaces, so a case-sensitive tool has one spelling
to match. `<type>` is the Conventional Commits type the branch's commits carry
— `feat`, `fix`, `docs`, `chore` — so the branch and its commits are spelled
from one vocabulary. `<id>` is a three-letter project prefix, a dash,
and a sequence — canonically `ABC-123` where a tracker mints the number,
and `ATR-260729` where none does, as here, the sequence being the short
two-digit-year datestamp the branch was cut. Without a tracker the id dates
the work rather than identifying it: branches cut the same day carry the same
one, and what separates them is the whole branch name. A branch spells the id
lowercased; every other reference to it — a PR body, a commit trailer, a wip
filename — keeps the canonical form. `<name>` is a short kebab-case summary,
so `feat/atr-260729-selinux-optional-groups`. Use a maximum of 60 characters
for the whole branch name, type and separators included. PRs target `develop`,
and the operator merges them manually. A change of one or two commits with no
`BREAKING CHANGE` footer lands straight on `develop`; a branch and a PR are
for work large enough that the review round trip pays for itself.

```bash
git commit -a --fixup=<commit>
git rebase --autosquash develop
```

A fix to a commit that has not been pushed goes into that commit. `--fixup`
records the fix against `<commit>` and the rebase folds it in, so the branch
reaches review without a `fix` commit for a defect no one else received. Git
2.44 and later apply `--autosquash` without an interactive rebase. A pushed
commit takes a `fix` commit of its own.

Give the PR an explicit title, in the same Conventional Commits form
as a commit subject:

```bash
gh pr create --title "feat(selinux): ship the optional policy groups compiled"
```

The merge commit then carries where the work came from on its first line
and what it does on its second:

```text
Merge pull request #163 from dag-node/feat/atr-260729-selinux-optional-groups
feat(selinux): ship the optional policy groups compiled
```

The type and the id are already on that first line, spelled as the branch
spells them, so the title's job is the other half — what the change does,
in about 72 characters, the length a commit subject takes here. GitHub's own
views join the two lines without a separator, where a repeated branch name
reads as one run-on string.

Left untyped, the title is GitHub's own: it derives one from the branch name —
first character uppercased, every other lowercased, each hyphen a space,
the slash kept — and the merge commit keeps
`Feat/atr 260729 selinux optional groups` for good.

Every pull request, and every push to `develop` or `main`, runs `shellcheck`
and the full `rpm-selftest` matrix and uploads snapshot RPMs as workflow
artifacts, so a proposed change is inspectable without cutting a release. Do
not push `v*` tags — a tag ruleset restricts tag creation to maintainers,
because under [The one rule that decides everything
else](#the-one-rule-that-decides-everything-else) a tag *is* a release
decision.

There are no standing `release/X.Y` branches, and [Patching a released
version](#patching-a-released-version) needs none: `main` already tracks
the newest release. Cut one when a consumer cannot move to X.Y+1 — a support
commitment, a contract, a deployment pinned to a minor. Patches for that line
are then cut from `release/X.Y` and tagged there, and the fix goes forward
into `develop` as well so the next minor carries it; `main` goes on tracking
the newest release. The pipeline does not change for any of it, since
the channel follows the tag and not the branch.

## For maintainers: cutting a release

### 0. Rehearse after touching the pipeline

```bash
gh workflow run ci.yml --ref develop
```

A `workflow_dispatch` run executes the real release path — clean build,
in-container signing of real RPMs, `podman cp` extraction, runner-side
`rpmkeys -Kv` verification — with the publish steps (`Create GitHub Release`,
the dag-node/rpm notify) skipped, and uploads the signed output as a workflow
artifact. Use it whenever `ci.yml`, `sign-rpms.sh`, or `packaging/` change: it
proves the plumbing without version identity or publish. It is not a substitute
for an RC — a rehearsal tests the pipeline, an RC tests a release candidate.

### 1. Cut a release candidate (tag on `develop`)

```bash
echo 0.6.3 > packaging/VERSION
git commit -am "chore(release): bump VERSION to 0.6.3"
git push
git tag v0.6.3-rc.1 && git push origin v0.6.3-rc.1
```

An RC carries the *next* version (SemVer: `0.6.3-rc.1` sorts after the released
`0.6.2` and before the eventual `0.6.3`). `check-version.sh` verifies the tag's
base `X.Y.Z` against `packaging/VERSION` but relaxes the `%changelog` match —
RC notes aren't finalized. The release job builds `0.6.3-0.rc1`, signs
and verifies it, and publishes a GitHub **prerelease**; the stable repo never
sees it. Install an RC by downloading the prerelease zip. Fixes land
on `develop` as normal commits, followed by `rc.2`, `rc.3`, … — no `main`
merges, no re-tags.

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

The final tag points at the last green RC's content plus only the `%changelog`
finalization — no functional commits slip in between `rc.N` and final,
so what ships is what the RC tested (the RPM is rebuilt because `0.rcN` and `1`
are different `Release` values, but from the same source). `check-version.sh`
enforces the full tag = `VERSION` = newest-`%changelog` agreement. The job
builds `0.6.3-1`, signs, verifies, publishes the GitHub Release, and notifies
dag-node/rpm, which rebuilds `rpm.dagnode.com`. This merge is the only
`develop` → `main` merge of the release.

### 3. Open the next cycle

```bash
git switch develop
echo 0.6.4 > packaging/VERSION
git commit -am "chore(release): bump VERSION to 0.6.4"
git push
```

After the final release publishes, bump `packaging/VERSION` on `develop`
to the next anticipated version. Dev/snapshot RPMs (`Release: 0.<n>.git<sha>`)
then sort after the last release and before the next one; left at the released
number, a newer snapshot sorts as an older package.

## Patching a released version

```bash
git switch -c fix/ATR-260922-agent-package-repair v0.19.0
# ...fix, commit, prove it...
git push -u origin fix/ATR-260922-agent-package-repair   # the PR targets main
```

A fix to something already published is cut from the release **tag** and its PR
targets `main`, not `develop`, which by then carries the next minor.
After the merge, tag `vX.Y.Z+1` on `main`: the release job publishes it exactly
as it does any final tag, and `check-version.sh` holds it to the same
agreement.

Three rules decide whether that costs one patch or two.

**Prove the fix before the merge, not after.** A patch branch earns the full
suite green and its own CI run — every push builds the `rpm-selftest` matrix —
and, where the fix is about the state of an installed host, an install
on a real one. A branch merged unproven costs a second branch to finish
the job, and leaves `main` carrying half a fix in between. Tag only once `main`
is what you mean to ship: the tag is what publishes, so a tag that has to move
afterwards is the outcome this ordering exists to avoid.

**The `%changelog` commit is the last one on the branch**, as it is for a final
tag in [2. Finalize](#2-finalize-the-one-merge-to-main). It records
what the release contains, which is not known until the fix is complete;
written first, it is amended by every commit after it, and the entry the tag
carries is whatever the last amendment happened to leave. Put the `VERSION`
bump in that same commit, so one commit carries the whole release identity.

**Merge `main` back into `develop` as the closing step**, then into any live
feature branch. `develop` is where the next release is built, so a patch it
never receives is a fix the next minor silently drops. Expect one conflict
class: the patch edits a source file that editorial work on `develop` has
rewritten around, and the two collide in that file's comment header — keep
`develop`'s wording and the patch's behaviour.

### If the release job goes red

The job is fail-closed and idempotent: signing or verification failure stops it
before anything is public, and re-running the workflow refreshes release assets
(`gh release upload --clobber`) and re-fires the notify rather than
duplicating. A tag/`VERSION`/`%changelog` mismatch is fixed by committing
the correction and re-tagging; a pipeline defect is fixed on `develop`, proven
with a rehearsal, then released as the next `rc.N` — never by iterating merges
to `main`.

## Guardrails behind the process

Signing is mandatory and preflight-checked before anything builds; fork PRs
never see the signing secret (the release job runs only on tags
and `workflow_dispatch`); `v*` tag creation is restricted to maintainers
by a ruleset. Details
in [ref-section-a6s8](../rpm-packaging.md#ref-section-a6s8).

Rehearsal RPMs are signed with the real key, so they carry the distinct Release
`0.<run>.rehearsal.git<sha>` — a leaked rehearsal artifact can never share
a NEVRA with, and so never impersonate, a published `X.Y.Z-1` package.

One-time setup (repo admin), in GitHub Settings:

- **Rules → Rulesets → New tag ruleset** — enforcement *Active*, target tags
  matching `v*`, restrict *creation*, *update*, and *deletion*, bypass list
  *Repository admin* only. The tag is the entire release authority
  under that one rule, so it gets `main`-level protection.
- **Actions → General** — default workflow permissions *Read repository
  contents* (the release job requests `contents: write` explicitly); leave
  "Allow GitHub Actions to create and approve pull requests" off; require
  approval for workflow runs from all outside collaborators. Actions
  permissions: *Allow dag-node, and select non-dag-node, actions* with only
  *Allow actions created by GitHub* checked (every action used is `actions/*`),
  and *Require actions to be pinned to a full-length commit SHA* on — set
  org-wide so every dag-node repo inherits both. In the org's *Fork pull
  request workflows in private and internal repositories* block, disable *Run
  workflows from fork pull requests* — the org has no private repos taking fork
  contributions, and disabling the parent pins the write-token and secrets
  sub-options off for every repo admin.
- **Advanced Security** — enable secret scanning and push protection.

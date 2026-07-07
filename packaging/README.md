# ai-tools RPM test harness

Build the ai-tools RPMs on Rocky Linux and run the whole admin → operator → agent workflow in a throwaway container.

## Quick start

```bash
make -C packaging rpmtest-rocky9
```

That one target builds the four RPMs from the working tree, installs the `ai-tools` metapackage from a local repo (so `dnf` pulls `ai-tools-base`, `ai-tools-nodejs`, and `claude-code-restricted` through its `Requires`), boots `systemd` as PID 1, and runs `container-selftest.sh`. The selftest walks the documented Quick-start end to end — `ai-tools-bootstrap`, `ai-tools-admin operator add`, `ai-tools --project-claim`, `tests/run.sh all`, and an auth-free confined `claude --version` session — then calls `systemctl exit` with the aggregate status, so the command exits non-zero if any phase fails. Use `rpmtest-rocky10` for Rocky 10.

## Reading the result

```text
══════════════════════════════════════════════════════════════
# SELFTEST SUMMARY
══════════════════════════════════════════════════════════════
PASS        Metapackage pulled the three subpackages
PASS        ai-tools-bootstrap (nvm + Node + claude; linger + timer)
PASS        ai-tools-admin operator add tester
PASS        operator claims the project (allowlist + ACL + safedir + label)
PASS        tests/run.sh all
PASS        confined session launches (claude --version through the wrapper)
...
##### ai-tools container selftest: ALL PHASES PASSED #####
```

Each phase prints its command and a green `PASS` or red `FAIL(<code>)` as it runs, and the summary block reprints them at the end; `tests/run.sh` additionally reprints any failing test file's `FAIL` lines. The container's exit code is the aggregate, so `echo $?` after the run (or CI) sees pass/fail without scraping the log.

## Run it by hand

```bash
podman build -t ai-tools-rpmbase:el9 -f packaging/RpmBase.Containerfile \
    --build-arg BASE_IMAGE=quay.io/rockylinux/rockylinux:9.7-minimal .
podman build -t ai-tools-rpmtest:el9 -f packaging/Rocky9.Containerfile .
podman run --rm -t --systemd=always ai-tools-rpmtest:el9
```

`RpmBase.Containerfile` is the shared recipe, parameterized by `BASE_IMAGE`; `Rocky9.Containerfile` is a thin pin (`FROM ai-tools-rpmbase:el9`) where any EL9-only tweak would go. `--systemd=always` tells Podman to run the image's `/sbin/init` as PID 1, which the handback socket and the sandbox account's `systemd --user` manager need. Add `--privileged` if your runtime cannot mount cgroups for that user manager. To poke around instead of running the selftest, start it detached (`podman run -d --systemd=always …`) and `podman exec -it <id> bash`.

## Customize

```bash
make -C packaging rpmtest-rocky10 OCI=docker EL10_BASE=quay.io/rockylinux/rockylinux:10-minimal
```

`OCI` selects the build/run tool (default `podman`); `EL9_BASE`/`EL10_BASE` override the base image. The selftest itself reads `OPERATOR` (default `tester`), `PROJECT` (default `/home/tester/proj`), and `RUN_TESTS` (default `1`); because it runs from a `systemd` unit rather than the container's main process, change these in `ai-tools-selftest.service`'s `Environment=` or invoke `/usr/local/bin/ai-tools-selftest` directly via `podman exec`.

## Releasing

A release is triggered by a git tag, never by a plain push to a branch — nothing
publishes automatically off an ordinary commit:

1. Decide the new version (semver `MAJOR.MINOR.PATCH`) and set it in
   `packaging/VERSION`, the single source of truth this Makefile and the spec
   both read (see `docs/rpm-packaging.md`'s Build section). Commit and push it.
2. Tag that same commit `vX.Y.Z` — the `v` prefix matters, `.github/workflows/ci.yml`
   only fires the release job on `v*.*.*` — and push the tag:

       git tag v0.2.0
       git push origin v0.2.0

3. CI takes it from there. `shellcheck` and `rpm-selftest` (the full container
   selftest above, both EL9 and EL10) run against the tagged commit first; only
   once both pass does the `release` job verify the tag matches
   `packaging/VERSION`, rebuild clean RPMs (`RPM_RELEASE` left unset, so
   `Release: 1` applies rather than the dev/snapshot Release every other CI run
   gets), and publish a GitHub Release with those RPMs attached and
   auto-generated notes (`gh release create --generate-notes`).

A tag that does not match `packaging/VERSION` fails the release job immediately
with an explicit error instead of publishing a mismatched release — bump the
file first, then tag.

## Scope

A container validates packaging and dependency resolution, the install scriptlets, the `bootstrap` toolchain, operator enrolment, project claim, the test suite's DAC and `systemd` parts, and a DAC-confined launch. It does **not** validate SELinux-enforcing confinement: `getenforce` reports `Disabled` in a container, so `%post` skips `semodule` and the `ai_tools_t` domain transition never fires. This harness is the fast, repeatable pre-check; the enforcing-host `dnf install` + `sudo tests/run.sh all` remains the real gate. ⚠️ The test image also adds a NOPASSWD sudoers drop-in for the operator user — convenience for the unattended run, not part of the shipped model; the sandbox account `ai-tools` still holds no sudo grant, which the selftest re-checks.

## Files

`RpmBase.Containerfile` (shared recipe), `Rocky9.Containerfile` / `Rocky10.Containerfile` (per-distro pins), `container-selftest.sh` (the workflow), `ai-tools-selftest.service` (the boot-time runner). The package itself is built by `make rpm` (see the `Makefile`); for the security model and the manual install flow read the repository [`README.md`](../README.md) and [`docs/rpm-packaging.md`](../docs/rpm-packaging.md).

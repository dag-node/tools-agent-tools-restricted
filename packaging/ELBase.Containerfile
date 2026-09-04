# SPDX-License-Identifier: AGPL-3.0-only
# Shared base recipe for the EL (Rocky/RHEL) ai-tools RPM test image. All the common build/test
# logic lives here, parameterized by the EL base image; the per-distro files (Rocky9.Containerfile,
# Rocky10.Containerfile) are thin pins over the image this builds, so no line below is repeated.
# Rocky 9/10 minimal both ship microdnf and the same package names installed below, so this recipe
# builds unchanged across them.
#
# Fedora is not built from THIS recipe, but only because the base images and dnf front-end differ:
# it has its own FedoraLatestBase.Containerfile. The helper tree lives at ai_libexecdir
# (/usr/local/libexec/ai-tools), which the Fedora bin/sbin merge leaves untouched, so the earlier
# /usr/local/sbin-vs-/usr/local/bin file conflict no longer exists -- one layout serves both.
#
# Build a distro image (two steps; the Makefile wraps them as `rpmtest-rocky9` / `-rocky10`):
#   podman build -t ai-tools-rpmbase:el9 -f packaging/ELBase.Containerfile \
#       --build-arg BASE_IMAGE=quay.io/rockylinux/rockylinux:9.7-minimal .
#   podman build -t ai-tools-rpmtest:el9 -f packaging/Rocky9.Containerfile .
#   podman run --rm -t --systemd=always ai-tools-rpmtest:el9
#       # add --privileged if your runtime cannot mount cgroups for the --user manager
#
# Boots systemd as PID 1; the oneshot ai-tools-selftest.service runs the full
# admin/operator/agent Quick-start workflow and `systemctl exit`s with the aggregate status,
# so `podman run` returns non-zero on any failure. See packaging/container-selftest.sh.
#
# SCOPE: a container validates packaging + dependency resolution, the install scriptlets
# (minus SELinux), the bootstrap toolchain, operator enrolment, project claim, the test
# suite's DAC/systemd parts, and a DAC-confined `claude --version` session. It does NOT
# validate SELinux-enforcing confinement: `getenforce` is Disabled in a container, so %post
# skips `semodule` and the ai_tools_t transition is never exercised -- that needs the
# enforcing host. This harness is the fast, repeatable pre-check; the box test is the gate.

# The EL base image to build on. The per-distro files supply this via the Makefile; building
# this file directly requires --build-arg BASE_IMAGE=... (no default, so the distro is explicit).
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Empty (the spec's own default Release "1") for a real release; the Makefile's rpmtest-rockyN
# targets forward their own RPM_RELEASE here so a CI dev build's snapshot Release lands on the
# RPMs this image produces too -- see packaging/Makefile and the spec's Release: line.
ARG RPM_RELEASE=""

# Build + test tooling. Rocky 9 and 10 minimal both ship microdnf; add dnf (readable dependency
# resolution), the rpm build chain + systemd-rpm-macros (for %systemd_*/%sysusers/%_userunitdir),
# createrepo_c (a local repo so the metapackage resolves its subpackage Requires), systemd as
# PID 1, and the utilities the workflow uses (script/runuser from util-linux, getenforce from
# libselinux-utils, git/curl for bootstrap + claim).
#
# dbus-broker provides the per-user D-Bus the sandbox account's `systemd --user` manager needs;
# the -minimal images omit it, and without it logind cannot sustain a lingering --user instance
# across session open/close, so the nvm-update timer drops out from under the toolchain. On a
# full host it is present already; the test image installs it to match.
# rpm-sign + gnupg2 are baked in here, NOT dnf-installed at sign time: the release workflow
# runs sign-rpms.sh in this image with the signing key in the environment, and no package
# scriptlet may ever execute while that secret is present.
# No package below comes from the `extras` repo; disable it so a flaky refresh can't abort the install.
RUN sed -i '/^\[extras\]/,/^\[/ s/^enabled=1$/enabled=0/' /etc/yum.repos.d/*.repo \
    && microdnf -y install \
        dnf rpm-build rpm-sign gnupg2 systemd-rpm-macros make sed tar gzip findutils createrepo_c \
        systemd dbus-broker sudo shadow-utils passwd util-linux procps-ng libselinux-utils \
        git curl which glibc-langpack-en \
    && microdnf clean all

# Source tree for `make rpm` + the test suite. Copy the build inputs explicitly (a
# .containerignore at the context root drops .git, packaging/rpmbuild, and tarballs). Only the
# prebuilt policy packages are needed from selinux/ -- the core ai_tools.pp plus each stable
# group's ai_tools_<group>.pp, which the Makefile CONTENT and the spec consume; experimental
# groups ship no .pp.
#
# The build context is the maintainer's working tree, where locally compiled experimental groups
# sit beside the shipped ones, so each prebuilt package is named: the image then holds exactly the
# audited, stable set. That naming is also what the Makefile's POLICY_PP relies on here, since the
# image has no git index to read. Keep it in step with the shipped set in packaging/Makefile, the
# spec %install loop, and .gitignore.
#
# The policy sources come too, as the corresponding source a GPL .pp is conveyed with (GPLv2 s.3);
# a glob is exact for them because .gitignore covers only *.pp.
COPY src                            /opt/ai-tools-src/src
COPY docs                           /opt/ai-tools-src/docs
COPY selinux/policy/ai_tools.pp         /opt/ai-tools-src/selinux/policy/
COPY selinux/policy/ai_tools_tmpmap.pp  /opt/ai-tools-src/selinux/policy/
COPY selinux/policy/Makefile            /opt/ai-tools-src/selinux/policy/
COPY selinux/policy/*.te                /opt/ai-tools-src/selinux/policy/
COPY selinux/policy/*.if                /opt/ai-tools-src/selinux/policy/
COPY selinux/policy/*.fc                /opt/ai-tools-src/selinux/policy/
COPY tests                          /opt/ai-tools-src/tests
COPY packaging                      /opt/ai-tools-src/packaging
# The licence set `make dist` bundles: LICENSE, the LICENSES/ SPDX texts, and the REUSE.toml
# that maps files to them. All three are in the Makefile CONTENT, so all three must be here or
# `make dist` fails to stat one.
COPY LICENSE                        /opt/ai-tools-src/LICENSE
COPY LICENSES                       /opt/ai-tools-src/LICENSES
COPY REUSE.toml                     /opt/ai-tools-src/REUSE.toml
COPY README.md                      /opt/ai-tools-src/README.md
WORKDIR /opt/ai-tools-src

# Build every RPM the spec defines, publish them as a local repo, and install the METAPACKAGE
# only -- dnf pulls ai-tools-base (hard Requires) plus the ai-tools-agents / ai-tools-integration
# umbrellas and their members (weak Recommends), proving the dependency graph (the transaction
# table dnf prints is the evidence). install_weak_deps is forced on so the pull is deterministic
# regardless of the base image's dnf config; it is spelled `=1` (not `=True`) and the command
# carries no `-v` so the same install line stays portable to dnf5 (dnf5 rejects `-v` and prefers
# the numeric boolean), which the future FedoraLatestBase recipe reuses. Then enable the units
# that must be live at boot for the selftest (preset policy may leave them off in a minimal image).
#
# The post-install assertion is derived from the BUILT set rather than a hand-kept package list:
# every subpackage the spec produced must resolve from the metapackage alone, so a subpackage
# added later is covered here without touching this file -- and a member whose weak dependency
# never resolves fails the build instead of passing unnoticed.
RUN set -eux; \
    rm -rf packaging/rpmbuild packaging/*.tar.gz; \
    make -C packaging rpm RPM_RELEASE="${RPM_RELEASE}"; \
    mkdir -p /tmp/ai-repo; \
    cp packaging/rpmbuild/RPMS/noarch/*.rpm /tmp/ai-repo/; \
    createrepo_c /tmp/ai-repo; \
    printf '[ai-tools-local]\nname=ai-tools-local\nbaseurl=file:///tmp/ai-repo\nenabled=1\ngpgcheck=0\n' \
        > /etc/yum.repos.d/ai-tools-local.repo; \
    dnf -y --setopt=install_weak_deps=1 install ai-tools; \
    rpm -q $(rpm -qp --qf '%{NAME}\n' /tmp/ai-repo/*.rpm | sort -u)
# The handback socket is intentionally NOT enabled by hand here: the package's own preset
# (85-ai-tools.preset, applied by %systemd_post) is what enables it, so container-selftest.sh's
# is-enabled/is-active checks genuinely exercise the RPM's enablement rather than a manual one.

# A non-root login user to enrol as the operator. The NOPASSWD drop-in is TEST-ONLY: it lets
# the unattended selftest run the operator's password-prompting sudo helpers (project claim,
# lockdown, …). It does NOT relax the agent's confinement -- the sandbox account ai-tools does
# not hold a sudo grant, which the selftest re-checks.
RUN useradd -m -s /bin/bash tester \
    && printf 'tester ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/zz-test-operator \
    && chmod 0440 /etc/sudoers.d/zz-test-operator

# Selftest payload + the oneshot unit that runs it on boot.
RUN install -m 0755 packaging/container-selftest.sh /usr/local/bin/ai-tools-selftest \
    && install -m 0644 packaging/ai-tools-selftest.service /etc/systemd/system/ai-tools-selftest.service \
    && systemctl enable ai-tools-selftest.service

# Run systemd as PID 1 so the handback socket and the sandbox --user manager come up and the
# selftest unit fires. (OPERATOR/PROJECT/RUN_TESTS default inside the script; to customise a
# run, edit the unit's Environment= or invoke /usr/local/bin/ai-tools-selftest via podman exec.)
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]

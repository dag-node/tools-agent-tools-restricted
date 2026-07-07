# Shared base recipe for the ai-tools RPM test image. All the common build/test logic lives
# here, parameterized by the EL base image; the per-distro files (Rocky9.Containerfile,
# Rocky10.Containerfile) are thin pins over the image this builds, so nothing below is repeated.
#
# Build a distro image (two steps; the Makefile wraps them as `rpmtest-rocky9` / `-rocky10`):
#   podman build -t ai-tools-rpmbase:el9 -f packaging/RpmBase.Containerfile \
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
RUN microdnf -y install \
        dnf rpm-build systemd-rpm-macros make sed tar gzip findutils createrepo_c \
        systemd dbus-broker sudo shadow-utils passwd util-linux procps-ng libselinux-utils \
        git curl which glibc-langpack-en \
    && microdnf clean all

# Source tree for `make rpm` + the test suite. Copy the build inputs explicitly (a
# .containerignore at the context root drops .git, packaging/rpmbuild, and tarballs). Only the
# prebuilt ai_tools.pp is needed from selinux/ -- the Makefile CONTENT and the spec consume just
# that file, and the rest of the tree holds a root-owned policy/tmp scratch dir an unprivileged
# build context cannot read.
COPY src                      /opt/ai-tools-src/src
COPY docs                     /opt/ai-tools-src/docs
COPY selinux/policy/ai_tools.pp /opt/ai-tools-src/selinux/policy/ai_tools.pp
COPY tests                    /opt/ai-tools-src/tests
COPY packaging                /opt/ai-tools-src/packaging
COPY README.md                /opt/ai-tools-src/README.md
WORKDIR /opt/ai-tools-src

# Build the four RPMs from the tree, publish them as a local repo, and install the METAPACKAGE
# only -- dnf pulls ai-tools-base / -nodejs / claude-code-restricted via Requires, proving the
# dependency graph (the verbose transaction table is the evidence). Then enable the units that
# must be live at boot for the selftest (preset policy may leave them off in a minimal image).
RUN set -eux; \
    rm -rf packaging/rpmbuild packaging/*.tar.gz; \
    make -C packaging rpm RPM_RELEASE="${RPM_RELEASE}"; \
    mkdir -p /tmp/ai-repo; \
    cp packaging/rpmbuild/RPMS/noarch/*.rpm /tmp/ai-repo/; \
    createrepo_c /tmp/ai-repo; \
    printf '[ai-tools-local]\nname=ai-tools-local\nbaseurl=file:///tmp/ai-repo\nenabled=1\ngpgcheck=0\n' \
        > /etc/yum.repos.d/ai-tools-local.repo; \
    dnf -y -v install ai-tools; \
    rpm -q ai-tools ai-tools-base ai-tools-nodejs claude-code-restricted; \
    systemctl enable ai-tools-handback.socket

# A non-root login user to enrol as the operator. The NOPASSWD drop-in is TEST-ONLY: it lets
# the unattended selftest run the operator's password-prompting sudo helpers (project claim,
# lockdown, …). It does NOT relax the agent's confinement -- the sandbox account ai-tools holds
# no sudo grant, which the selftest re-checks.
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

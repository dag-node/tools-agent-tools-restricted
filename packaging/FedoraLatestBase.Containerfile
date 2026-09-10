# SPDX-License-Identifier: AGPL-3.0-only
# Native Fedora ai-tools RPM smoke-test image (the Fedora counterpart of ELBase.Containerfile).
# Build + run with `make -C packaging rpmtest-fedora`. The intent: validate packaging against
# Fedora (upstream RHEL/CentOS) and produce Fedora-specific RPMs, separately from the shipped
# EL9/EL10 stack that ELBase builds.
#
# Why Fedora needs its own recipe rather than a BASE_IMAGE arg on ELBase: only the base image and a
# build detail differ, not the install layout. The earlier blocker -- Fedora's F42 bin/sbin merge
# (/usr/local/sbin -> /usr/local/bin) collided the root helper DIRECTORY with the CLI FILE at one
# path -- is gone: the helper tree lives at ai_libexecdir (/usr/local/libexec/ai-tools), which the
# merge does not touch, so one layout serves EL and Fedora. Fedora ships dnf5 (rejects `-v`,
# prefers `--setopt=install_weak_deps=1`); the build step uses that portable form, identical
# to ELBase.
#
# SCOPE: like the EL smoke test, a container validates packaging + dependency resolution, the
# install scriptlets (minus SELinux load), the bootstrap toolchain, operator enrolment, project
# claim, and the DAC/systemd test parts. It does NOT validate SELinux-enforcing confinement
# (`getenforce` is Disabled in a container, so %post skips `semodule`) -- but building the RPM here
# compiles the policy modules against Fedora's current headers, as each EL image does against its
# own, so a policy that no longer compiles on Fedora's moving refpolicy fails the image. Enforcing
# load/transition still needs a real Fedora host.

FROM quay.io/fedora/fedora-minimal:latest

# Empty for a real release; the Makefile's rpmtest-fedora target forwards RPM_RELEASE so a CI dev
# build's snapshot Release lands on these RPMs too (mirrors ELBase / the spec Release: line).
ARG RPM_RELEASE=""

# The same build + test tooling ELBase installs (mostly identical package names on fedora-minimal,
# which ships microdnf/dnf5), selinux-policy-devel + policycoreutils for the policy compile among
# them. dbus-broker backs the sandbox account's `systemd --user` manager, rpm-build/createrepo_c
# build and serve the local repo, and the util-linux/procps-ng/libselinux tools back the selftest.
# One Fedora packaging difference from EL: fedora-minimal splits script(1) out of util-linux into
# util-linux-script, and the selftest runs `claude --version` under `script` to give it a PTY, so it
# is named explicitly here (EL's util-linux bundles it). Kept in step with ELBase's install layer.
RUN microdnf -y install \
        dnf rpm-build rpm-sign gnupg2 systemd-rpm-macros make sed tar gzip findutils createrepo_c \
        selinux-policy-devel policycoreutils \
        systemd dbus-broker sudo shadow-utils passwd util-linux util-linux-script procps-ng \
        libselinux-utils git curl which glibc-langpack-en \
    && microdnf clean all

# Source tree for `make rpm` + the test suite, copied exactly as ELBase does (a .containerignore at
# the context root drops .git, packaging/rpmbuild, and tarballs): from selinux/ the policy sources
# and the script deriving which modules ship, and no .pp -- the spec compiles them in this image.
COPY src                            /opt/ai-tools-src/src
COPY docs                           /opt/ai-tools-src/docs
COPY selinux/policy/shipped-modules.sh  /opt/ai-tools-src/selinux/policy/
COPY selinux/policy/Makefile        /opt/ai-tools-src/selinux/policy/
COPY selinux/policy/*.te            /opt/ai-tools-src/selinux/policy/
COPY selinux/policy/*.if            /opt/ai-tools-src/selinux/policy/
COPY selinux/policy/*.fc            /opt/ai-tools-src/selinux/policy/
COPY tests                          /opt/ai-tools-src/tests
COPY packaging                      /opt/ai-tools-src/packaging
COPY LICENSE                        /opt/ai-tools-src/LICENSE
COPY LICENSES                       /opt/ai-tools-src/LICENSES
COPY REUSE.toml                     /opt/ai-tools-src/REUSE.toml
COPY README.md                      /opt/ai-tools-src/README.md
WORKDIR /opt/ai-tools-src

# Build every RPM the spec defines, publish them as a local repo, and install the METAPACKAGE only
# -- dnf pulls ai-tools-base (hard Requires) plus the weak agents/integration umbrellas, proving the
# dependency graph. install_weak_deps is forced on for a deterministic pull, spelled `=1` and with
# no `-v` so the line is dnf5-native. The post-install assertion is derived from the BUILT set, so a
# subpackage added later is covered without touching this file. The policy compile runs inside
# rpmbuild's %build here -- a policy that does not compile against Fedora's refpolicy fails the
# image.
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

# A non-root login user to enrol as the operator. The NOPASSWD drop-in is TEST-ONLY (lets the
# unattended selftest run the operator's password-prompting sudo helpers); it does NOT relax the
# agent's confinement -- the sandbox account does not hold a sudo grant, which the selftest re-checks.
RUN useradd -m -s /bin/bash tester \
    && printf 'tester ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/zz-test-operator \
    && chmod 0440 /etc/sudoers.d/zz-test-operator

# Selftest payload + the oneshot unit that runs it on boot.
RUN install -m 0755 packaging/container-selftest.sh /usr/local/bin/ai-tools-selftest \
    && install -m 0644 packaging/ai-tools-selftest.service /etc/systemd/system/ai-tools-selftest.service \
    && systemctl enable ai-tools-selftest.service

# Run systemd as PID 1 so the handback socket and the sandbox --user manager come up and the
# selftest unit fires.
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]

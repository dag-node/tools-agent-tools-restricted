# SPDX-License-Identifier: AGPL-3.0-only
# STUB -- a starting-point base image for FUTURE Fedora CI, not yet wired into the Makefile or
# the CI workflow. The intent: build unstable/experimental features against Fedora (upstream
# RHEL/CentOS) and produce Fedora-specific RPMs, separately from the shipped EL9/EL10 stack that
# ELBase.Containerfile builds.
#
# Why Fedora needs its own recipe rather than a BASE_IMAGE arg on ELBase: Fedora merges
# /usr/local/sbin into /usr/local/bin (the F42 SbinMerge). The spec installs the root helpers as a
# DIRECTORY at ai_sbindir (/usr/local/sbin/ai-tools) and the CLI as a FILE at ai_bindir
# (/usr/local/bin/ai-tools); merged, both canonicalize to /usr/local/bin/ai-tools -- a directory
# and a regular file at one path -- so rpm refuses the transaction with a file conflict. Those
# paths are load-bearing and hardcoded (SELinux file-contexts, sudoers, helper lookups; see the
# "Install paths are LITERAL /usr/local/*" note in the spec and CLAUDE.md), so making them coexist
# under a merged /usr/local is a path-layout rework, tracked separately.
#
# Fedora ships dnf5 (rejects `-v`, prefers `--setopt=install_weak_deps=1`); ELBase's build step
# already uses that portable form, so the RPM-build/install logic can be lifted from there once the
# path conflict is resolved.
#
# TO MAKE THIS USABLE, once the path rework lands: add the COPY of the source tree and the
# make-rpm / local-repo / metapackage-install / unit-enable steps from ELBase.Containerfile, a
# Fedora overlay + a `rpmtest-fedora` Makefile target, and a Fedora leg in .github/workflows/ci.yml.
FROM quay.io/fedora/fedora-minimal:latest

# The same build + test tooling ELBase installs; the package names are identical on fedora-minimal,
# which ships microdnf (dnf5). dbus-broker backs the sandbox account's `systemd --user` manager,
# rpm-build/createrepo_c build and serve the local repo, and the util-linux/procps-ng/libselinux
# tools back the selftest. Kept in step with ELBase's install layer.
RUN microdnf -y install \
        dnf rpm-build rpm-sign gnupg2 systemd-rpm-macros make sed tar gzip findutils createrepo_c \
        systemd dbus-broker sudo shadow-utils passwd util-linux procps-ng libselinux-utils \
        git curl which glibc-langpack-en \
    && microdnf clean all

# The source COPY, RPM build, repo publish, metapackage install, and selftest wiring are
# deliberately absent -- see the TO MAKE THIS USABLE note above. Building this file today yields a
# tooling base only.

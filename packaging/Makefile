# SPDX-License-Identifier: AGPL-3.0-only
# Build the ai-tools source tarball and RPMs. Run from this directory (packaging/).
#   make dist            build the source tarball from the working tree
#   make rpm             build the binary RPMs (metapackage, base, the agents/integration umbrellas + members)
#   make srpm            build the source RPM
#   make clean           remove build artifacts
#   make rpmtest-rocky9  build + run the Rocky 9 RPM smoke-test container (see *.Containerfile)
#   make rpmtest-rocky10 build + run the Rocky 10 RPM smoke-test container
#   make rpmtest-fedora  build + run the native Fedora RPM smoke-test container
#
# The tarball is built from the WORKING TREE (not `git archive`), so it includes
# not-yet-committed sources during development.
#
# RPM_RELEASE overrides the spec's Release (default "1", a final vX.Y.Z release): CI passes
# 0.<run>.git<sha> for dev/snapshot builds and 0.rcN for vX.Y.Z-rc.N prerelease tags -- the
# leading "0." ranks both below any final release: make rpm RPM_RELEASE=0.42.gitabcdef1

NAME    = ai-tools
VERSION := $(shell cat VERSION)
TARBALL = $(NAME)-$(VERSION).tar.gz
ROOT    = $(CURDIR)/..
TOPDIR  = $(CURDIR)/rpmbuild
RPM_RELEASE ?=
RELEASE_DEFINE = $(if $(RPM_RELEASE),--define "rpm_release $(RPM_RELEASE)",)

# Tracked + working-tree sources the spec consumes, relative to the repo root.
#
# POLICY_PP is the set of prebuilt policy packages the spec installs: the core ai_tools.pp plus
# each STABLE group's ai_tools_<group>.pp. It reads the git index, so it holds exactly the
# committed packages -- the tarball feeds the SRPM, and only the audited, shipped policy belongs
# in a published artifact. Experimental groups are compiled locally and gitignored, so the index
# is what distinguishes them. In a tree with no index (the container build runs this Makefile
# inside an image whose context excludes .git) the wildcard applies instead; that image's COPY
# names the stable packages one by one, so both paths yield the same set.
POLICY_PP = $(or $(shell git -C $(ROOT) ls-files 'selinux/policy/*.pp' 2>/dev/null),\
                 $(patsubst $(ROOT)/%,%,$(wildcard $(ROOT)/selinux/policy/*.pp)))

# POLICY_SRC is the corresponding source for those .pp: the policy text and the Makefile that
# compiles it. A .pp is GPL-2.0-or-later, and GPLv2 section 3 conveys a binary only together with
# its source, counting the scripts that control compilation as part of that source. Shipping both
# in the tarball keeps the SRPM self-sufficient for every distribution channel, including an
# offline release archive that reaches its recipient with no network.
#
# A wildcard is exact here: .gitignore covers *.pp alone, so every policy source in the tree is
# tracked. install-selinux.sh is not source in this sense -- it loads and installs a compiled
# module rather than controlling compilation, and holds no refpolicy content (it is AGPL-3.0-only,
# per its SPDX header).
POLICY_SRC = $(patsubst $(ROOT)/%,%,$(wildcard $(ROOT)/selinux/policy/*.te \
                                               $(ROOT)/selinux/policy/*.if \
                                               $(ROOT)/selinux/policy/*.fc \
                                               $(ROOT)/selinux/policy/*.te.draft \
                                               $(ROOT)/selinux/policy/Makefile))

# Each subpackage carries its own licence text via %license, and the GPL policy subpackage conveys
# the GPL text with the binary it covers, so both LICENSE and LICENSES/ are payload.
CONTENT = src docs $(POLICY_PP) $(POLICY_SRC) \
          packaging/$(NAME).spec packaging/$(NAME).sysusers packaging/VERSION README.md \
          LICENSE LICENSES REUSE.toml

# Container smoke test: the shared ELBase recipe parameterized by an EL base image, then a
# thin per-distro overlay (see ELBase.Containerfile). OCI tool + EL bases are overridable. Fedora
# is not yet a `rpmtest-*` target: the helper tree now lives at ai_libexecdir
# (/usr/local/libexec/ai-tools), which the F42 bin/sbin merge leaves untouched, so the old file
# conflict is resolved and a native Fedora build is unblocked -- but its image/target/CI leg are
# not wired yet. FedoraLatestBase.Containerfile is the stub that future Fedora CI will build on.
OCI         ?= podman
EL9_BASE    ?= quay.io/rockylinux/rockylinux:9.7-minimal
EL10_BASE   ?= quay.io/rockylinux/rockylinux:10-minimal
# FedoraLatestBase pins fedora-minimal:latest internally (single distro, no BASE_IMAGE arg).
# Extra flags passed to every `OCI build`. Set BUILD_FLAGS=--no-cache to force a clean rebuild
# when a content-addressed COPY cache hit would otherwise reuse an RPM built from older sources.
BUILD_FLAGS ?=

.PHONY: all dist srpm rpm clean rpmbase-el9 rpmbase-el10 rpmtest-rocky9 rpmtest-rocky10 \
        rpmtest-fedora check-version changelog hooks

all:
	@echo "make dist | srpm | rpm | clean | rpmbase-el9 | rpmbase-el10 | rpmtest-rocky9 | rpmtest-rocky10 | rpmtest-fedora"
	@echo "     check-version | changelog | hooks"

# Assert VERSION, the newest %changelog entry, and (with TAG=vX.Y.Z) a tag all agree. The
# release build runs this at tag time; run it by hand before tagging to catch a missing entry.
check-version:
	@bash $(CURDIR)/check-version.sh $(TAG)

# Draft a %changelog block for the current VERSION from commits since the last tag, to stdout
# for curation (see change-docs). Prints nothing to the spec -- paste and edit the result.
changelog:
	@bash $(CURDIR)/changelog-draft.sh

# Opt in (once per clone) to the local git hooks in .githooks -- a non-blocking commit-msg
# reminder to complete the %changelog on a "bump version" commit, and a non-blocking pre-commit
# report of the prose figures the ai-tools-technical-docs skill rules out in the lines a commit
# adds. Also silence
# git's ignored-hook advice: the sandbox account commits under the SELinux ai_tools_t domain,
# which has no execute on the project-tree ai_tools_project_t label, so git skips the hook and
# nags about it on every agent commit. That skip is the confinement working (the operator, who
# runs the release-tag commits, executes the hook fine), so the advice is pure noise here.
hooks:
	git -C $(ROOT) config core.hooksPath .githooks
	git -C $(ROOT) config advice.ignoredHook false
	@echo "git hooks enabled (core.hooksPath=.githooks)"

# The shared base image alone: builds the RPMs inside it (via its own `make rpm`, so
# RPM_RELEASE flows through -- see ELBase.Containerfile) and installs the metapackage, with
# no test overlay and no `run`. rpmtest-rockyN below layers the selftest on top of this; CI's
# release job targets this directly to get clean release RPMs without re-running the full
# selftest a prior CI job already passed on the same commit.
rpmbase-el9:
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmbase:el9 -f $(CURDIR)/ELBase.Containerfile --build-arg BASE_IMAGE=$(EL9_BASE) --build-arg RPM_RELEASE=$(RPM_RELEASE) $(ROOT)

rpmbase-el10:
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmbase:el10 -f $(CURDIR)/ELBase.Containerfile --build-arg BASE_IMAGE=$(EL10_BASE) --build-arg RPM_RELEASE=$(RPM_RELEASE) $(ROOT)

# The distro overlay on top of the base image, run with systemd as PID 1 so the selftest
# fires and returns the container's exit status.
rpmtest-rocky9: rpmbase-el9
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmtest:el9 -f $(CURDIR)/Rocky9.Containerfile $(ROOT)
	$(OCI) run --rm -t --systemd=always --ulimit core=0 ai-tools-rpmtest:el9

rpmtest-rocky10: rpmbase-el10
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmtest:el10 -f $(CURDIR)/Rocky10.Containerfile $(ROOT)
	$(OCI) run --rm -t --systemd=always --ulimit core=0 ai-tools-rpmtest:el10

# Native Fedora smoke test. Unlike the EL pair, FedoraLatestBase is a complete runnable image
# (single distro, its own FROM and ENTRYPOINT), so there is no separate base/overlay split -- build
# it and run it directly. Building it also exercises the spec's `%if 0%{?fedora}` source .pp compile.
rpmtest-fedora:
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmtest:fedora -f $(CURDIR)/FedoraLatestBase.Containerfile --build-arg RPM_RELEASE=$(RPM_RELEASE) $(ROOT)
	$(OCI) run --rm -t --systemd=always --ulimit core=0 ai-tools-rpmtest:fedora

# The tarball asserts its own GPL compliance: a .pp travels only with the policy source it was
# compiled from. Both lists are globs, and a glob that matches nothing yields a tarball that looks
# well-formed and conveys a GPL binary with no source, so the counts are checked rather than
# assumed -- comparing the archive against the inputs, so adding a policy module needs no edit here.
dist:
	tar czf $(TARBALL) -C $(ROOT) \
	    --transform 's,^,$(NAME)-$(VERSION)/,' \
	    --exclude='.git' --exclude='*.tar.gz' --exclude='rpmbuild' \
	    $(CONTENT)
	@pp=$$(tar tzf $(TARBALL) | grep -cE 'selinux/policy/[^/]+\.pp$$'); \
	 src=$$(tar tzf $(TARBALL) | grep -cE 'selinux/policy/[^/]+\.(te|if|fc)$$'); \
	 fail() { echo "$(TARBALL): $$1" >&2; rm -f $(TARBALL); exit 1; }; \
	 [ "$$pp" -gt 0 ] \
	    || fail "no prebuilt policy package -- %install needs ai_tools.pp"; \
	 [ "$$src" -gt 0 ] \
	    || fail "conveys $$pp GPL .pp with no policy source -- GPLv2 s.3"
	@echo "built $(TARBALL)"

rpm: dist
	mkdir -p $(TOPDIR)
	rpmbuild -bb $(NAME).spec \
	    --define "_topdir $(TOPDIR)" \
	    --define "_sourcedir $(CURDIR)" \
	    $(RELEASE_DEFINE)
	@echo "RPMs under $(TOPDIR)/RPMS/"

srpm: dist
	mkdir -p $(TOPDIR)
	rpmbuild -bs $(NAME).spec \
	    --define "_topdir $(TOPDIR)" \
	    --define "_sourcedir $(CURDIR)" \
	    $(RELEASE_DEFINE)

clean:
	rm -f $(TARBALL)
	rm -rf $(TOPDIR)

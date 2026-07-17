# Build the ai-tools source tarball and RPMs. Run from this directory (packaging/).
#   make dist            build the source tarball from the working tree
#   make rpm             build the binary subpackage RPMs (base / nodejs / claude-code-restricted)
#   make srpm            build the source RPM
#   make clean           remove build artifacts
#   make rpmtest-rocky9  build + run the Rocky 9 RPM smoke-test container (see *.Containerfile)
#   make rpmtest-rocky10 build + run the Rocky 10 RPM smoke-test container
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
CONTENT = src docs selinux/policy/ai_tools.pp \
          packaging/$(NAME).spec packaging/$(NAME).sysusers packaging/VERSION README.md

# Container smoke test: the shared RpmBase recipe parameterized by an EL base image, then a
# thin per-distro overlay (see RpmBase.Containerfile). OCI tool + EL bases are overridable.
OCI       ?= podman
EL9_BASE  ?= quay.io/rockylinux/rockylinux:9.7-minimal
EL10_BASE ?= quay.io/rockylinux/rockylinux:10-minimal
# Extra flags passed to every `OCI build`. Set BUILD_FLAGS=--no-cache to force a clean rebuild
# when a content-addressed COPY cache hit would otherwise reuse an RPM built from older sources.
BUILD_FLAGS ?=

.PHONY: all dist srpm rpm clean rpmbase-el9 rpmbase-el10 rpmtest-rocky9 rpmtest-rocky10 \
        check-version changelog hooks

all:
	@echo "make dist | srpm | rpm | clean | rpmbase-el9 | rpmbase-el10 | rpmtest-rocky9 | rpmtest-rocky10"
	@echo "     check-version | changelog | hooks"

# Assert VERSION, the newest %changelog entry, and (with TAG=vX.Y.Z) a tag all agree. The
# release build runs this at tag time; run it by hand before tagging to catch a missing entry.
check-version:
	@bash $(CURDIR)/check-version.sh $(TAG)

# Draft a %changelog block for the current VERSION from commits since the last tag, to stdout
# for curation (see change-docs). Prints nothing to the spec -- paste and edit the result.
changelog:
	@bash $(CURDIR)/changelog-draft.sh

# Opt in (once per clone) to the local git hooks in .githooks -- currently a non-blocking
# commit-msg reminder to complete the %changelog on a "bump version" commit. Also silence
# git's ignored-hook advice: the sandbox account commits under the SELinux ai_tools_t domain,
# which has no execute on the project-tree ai_tools_project_t label, so git skips the hook and
# nags about it on every agent commit. That skip is the confinement working (the operator, who
# runs the release-tag commits, executes the hook fine), so the advice is pure noise here.
hooks:
	git -C $(ROOT) config core.hooksPath .githooks
	git -C $(ROOT) config advice.ignoredHook false
	@echo "git hooks enabled (core.hooksPath=.githooks)"

# The shared base image alone: builds the RPMs inside it (via its own `make rpm`, so
# RPM_RELEASE flows through -- see RpmBase.Containerfile) and installs the metapackage, with
# no test overlay and no `run`. rpmtest-rockyN below layers the selftest on top of this; CI's
# release job targets this directly to get clean release RPMs without re-running the full
# selftest a prior CI job already passed on the same commit.
rpmbase-el9:
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmbase:el9 -f $(CURDIR)/RpmBase.Containerfile --build-arg BASE_IMAGE=$(EL9_BASE) --build-arg RPM_RELEASE=$(RPM_RELEASE) $(ROOT)

rpmbase-el10:
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmbase:el10 -f $(CURDIR)/RpmBase.Containerfile --build-arg BASE_IMAGE=$(EL10_BASE) --build-arg RPM_RELEASE=$(RPM_RELEASE) $(ROOT)

# The distro overlay on top of the base image, run with systemd as PID 1 so the selftest
# fires and returns the container's exit status.
rpmtest-rocky9: rpmbase-el9
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmtest:el9 -f $(CURDIR)/Rocky9.Containerfile $(ROOT)
	$(OCI) run --rm -t --systemd=always ai-tools-rpmtest:el9

rpmtest-rocky10: rpmbase-el10
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmtest:el10 -f $(CURDIR)/Rocky10.Containerfile $(ROOT)
	$(OCI) run --rm -t --systemd=always ai-tools-rpmtest:el10

dist:
	tar czf $(TARBALL) -C $(ROOT) \
	    --transform 's,^,$(NAME)-$(VERSION)/,' \
	    --exclude='.git' --exclude='*.tar.gz' --exclude='rpmbuild' \
	    $(CONTENT)
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

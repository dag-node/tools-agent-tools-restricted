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

NAME    = ai-tools
VERSION = 0.1.0
TARBALL = $(NAME)-$(VERSION).tar.gz
ROOT    = $(CURDIR)/..
TOPDIR  = $(CURDIR)/rpmbuild

# Tracked + working-tree sources the spec consumes, relative to the repo root.
CONTENT = src docs selinux/policy/ai_tools.pp \
          packaging/$(NAME).spec packaging/$(NAME).sysusers README.md

# Container smoke test: the shared RpmBase recipe parameterized by an EL base image, then a
# thin per-distro overlay (see RpmBase.Containerfile). OCI tool + EL bases are overridable.
OCI       ?= podman
EL9_BASE  ?= quay.io/rockylinux/rockylinux:9.7-minimal
EL10_BASE ?= quay.io/rockylinux/rockylinux:10-minimal
# Extra flags passed to every `OCI build`. Set BUILD_FLAGS=--no-cache to force a clean rebuild
# when a content-addressed COPY cache hit would otherwise reuse an RPM built from older sources.
BUILD_FLAGS ?=

.PHONY: all dist srpm rpm clean rpmtest-rocky9 rpmtest-rocky10

all:
	@echo "make dist | srpm | rpm | clean | rpmtest-rocky9 | rpmtest-rocky10"

# Two builds per distro: the shared base for the chosen EL image, then the distro overlay; then
# run it with systemd as PID 1 so the selftest fires and returns the container's exit status.
rpmtest-rocky9:
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmbase:el9 -f $(CURDIR)/RpmBase.Containerfile --build-arg BASE_IMAGE=$(EL9_BASE) $(ROOT)
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmtest:el9 -f $(CURDIR)/Rocky9.Containerfile $(ROOT)
	$(OCI) run --rm -t --systemd=always ai-tools-rpmtest:el9

rpmtest-rocky10:
	$(OCI) build $(BUILD_FLAGS) -t ai-tools-rpmbase:el10 -f $(CURDIR)/RpmBase.Containerfile --build-arg BASE_IMAGE=$(EL10_BASE) $(ROOT)
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
	    --define "_sourcedir $(CURDIR)"
	@echo "RPMs under $(TOPDIR)/RPMS/"

srpm: dist
	mkdir -p $(TOPDIR)
	rpmbuild -bs $(NAME).spec \
	    --define "_topdir $(TOPDIR)" \
	    --define "_sourcedir $(CURDIR)"

clean:
	rm -f $(TARBALL)
	rm -rf $(TOPDIR)

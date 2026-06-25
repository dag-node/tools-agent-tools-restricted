# Build the ai-tools source tarball and RPMs. Run from this directory (packaging/).
#   make dist   build the source tarball from the working tree
#   make rpm    build the binary subpackage RPMs (base / nodejs / claude-code-restricted)
#   make srpm   build the source RPM
#   make clean  remove build artifacts
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

.PHONY: all dist srpm rpm clean

all:
	@echo "make dist | srpm | rpm | clean"

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

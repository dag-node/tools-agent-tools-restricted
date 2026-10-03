# SPDX-License-Identifier: AGPL-3.0-only
# Fedora 44 ai-tools RPM test image: a thin pin over the shared RpmBase recipe, which carries all
# the common build/test logic. Build with `make -C packaging rpmtest-fedora44`, or manually build
# the base first with BASE_IMAGE=quay.io/fedora/fedora-minimal:44 and
# EXTRA_PACKAGES=util-linux-script (see RpmBase.Containerfile), then this overlay. The base is
# pinned to the release the .fc44 dist tag names, so the policy modules the image compiles are
# built against the policy headers of the host they are served to.
FROM ai-tools-rpmbase:fc44
LABEL ai-tools.test.distro="quay.io/fedora/fedora-minimal:44"

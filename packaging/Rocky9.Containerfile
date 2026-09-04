# SPDX-License-Identifier: AGPL-3.0-only
# Rocky Linux 9 ai-tools RPM test image: a thin pin over the shared ELBase recipe, which
# carries all the common build/test logic. Build with `make -C packaging rpmtest-rocky9`, or
# manually build the base first with BASE_IMAGE=quay.io/rockylinux/rockylinux:9.7-minimal
# (see ELBase.Containerfile), then this overlay. Stock Rocky 9 does not require distro-specific
# adjustment, so this is just the per-distro tag + a hook for any future EL9-only tweak.
FROM ai-tools-rpmbase:el9
LABEL ai-tools.test.distro="quay.io/rockylinux/rockylinux:9-minimal"

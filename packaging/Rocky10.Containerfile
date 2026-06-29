# Rocky Linux 10 ai-tools RPM test image: a thin pin over the shared RpmBase recipe, which
# carries all the common build/test logic. Build with `make -C packaging rpmtest-rocky10`, or
# manually build the base first with BASE_IMAGE=quay.io/rockylinux/rockylinux:10-minimal
# (see RpmBase.Containerfile), then this overlay.
#
# EL10 note: the base ships dnf5 (with a microdnf compatibility command) and the same package
# names RpmBase installs. If an EL10 package name diverges or an extra repo must be enabled, add
# the `RUN microdnf -y install …` here -- this overlay is the place for EL10-only adjustments,
# so RpmBase stays distro-agnostic.
FROM ai-tools-rpmbase:el10
LABEL ai-tools.test.distro="quay.io/rockylinux/rockylinux:10-minimal"

# SPDX-License-Identifier: AGPL-3.0-only
# The upgrade transaction selftest: the published release FROM_VERSION installed from the signed repository as an
# operator installs it, then this tree's RPMs, built in the rpmbase image RPMBASE, applied over it by
# ai-tools-upgrade-selftest on boot under a live systemd. UPGRADE_SCENARIO names the host the upgrade starts from;
# packaging/container-upgrade-selftest.sh states each. Built and run by `make rpmupgrade-<distro>` (packaging/Makefile).
ARG BASE_IMAGE
ARG RPMBASE
FROM ${RPMBASE} AS built

FROM ${BASE_IMAGE}
ARG FROM_VERSION
ARG UPGRADE_SCENARIO
# The same mirror list RpmBase.Containerfile sets, for the same reason: the default mirrorlist answers slowly from CI.
RUN sed -i \
        -e 's|^#baseurl=http://dl.rockylinux.org/\$contentdir/\(.*\)|baseurl=https://dl.rockylinux.org/$contentdir/\1 https://rocky-linux-us-central1.production.gcp.mirrors.ctrliq.cloud/pub/rocky/\1 https://ftp.sh.cvut.cz/rocky/\1 https://rockylinux.anexia.at/\1 https://ftp.fau.de/rockylinux/\1|' \
        -e 's|^mirrorlist=https://mirrors.rockylinux.org/|#&|' \
        /etc/yum.repos.d/*.repo \
    && sed -i '/^\[extras\]/,/^\[/ s/^enabled=1$/enabled=0/' /etc/yum.repos.d/*.repo \
    && microdnf -y install dnf systemd dbus-broker sudo shadow-utils util-linux procps-ng findutils gawk grep \
        gnupg2 curl \
    && microdnf clean all
# The published release, through the commands the front page gives an operator.
RUN rpm --import https://rpm.dagnode.com/RPM-GPG-KEY-dag-node \
    && dnf -y install https://rpm.dagnode.com/dagnode-release-latest.noarch.rpm \
    && dnf -y --setopt=install_weak_deps=1 install "ai-tools-${FROM_VERSION}" \
    && rpm -q "ai-tools-base-${FROM_VERSION}"
# This tree's build as a local repository the selftest enables for the upgrade alone.
COPY --from=built /tmp/ai-repo /tmp/ai-repo
RUN printf '[ai-tools-local]\nname=ai-tools-local\nbaseurl=file:///tmp/ai-repo\nenabled=0\ngpgcheck=0\n' \
        > /etc/yum.repos.d/ai-tools-local.repo \
    && printf 'FROM_VERSION=%s\nUPGRADE_SCENARIO=%s\n' "${FROM_VERSION}" "${UPGRADE_SCENARIO}" > /etc/ai-tools-upgrade-selftest.conf
COPY packaging/container-upgrade-selftest.sh /usr/local/bin/ai-tools-upgrade-selftest
COPY packaging/ai-tools-upgrade-selftest.service /etc/systemd/system/ai-tools-upgrade-selftest.service
RUN chmod 0755 /usr/local/bin/ai-tools-upgrade-selftest && systemctl enable ai-tools-upgrade-selftest.service
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]

# Build ai_tools policy modules (policy source lives here, under selinux/policy/).
#
# The refpolicy Makefile compiles every *.te file in this directory into its
# own *.pp. Target individual modules by name or build all at once:
#
#   make                             # all *.te -> *.pp
#   make ai_tools.pp                 # core (always loaded)
#   make ai_tools_systemd.pp         # optional: systemctl, journalctl
#   make ai_tools_pkgmgmt.pp         # optional: rpm, dnf RPM database
#   make ai_tools_netadmin.pp        # optional: firewall-cmd, nmcli D-Bus
#   make ai_tools_podman.pp          # optional: podman/buildah, container storage
#   make ai_tools_tmpmap.pp          # optional: mmap of the agent's own /tmp files
#   make ai_tools_apphost.pp         # optional: execute .NET apphost/JIT code from memfd
#   make clean
#
# Use install-selinux.sh (one level up, at selinux/) rather than semodule directly:
#   sudo ../install-selinux.sh install
#   sudo ../install-selinux.sh enable-group <name>
#   sudo ../install-selinux.sh list-groups
#
# Requires: sudo dnf install selinux-policy-devel

include /usr/share/selinux/devel/Makefile

#!/usr/bin/env bash
# selinux/avc-analyze.sh -- collect the ai_tools_t AVCs logged since the last
# avc-testsuite.sh run and split them into NEW (candidates to fold into the policy)
# vs EXPECTED BOUNDARY (the accesses ai_tools.te deliberately dontaudit's -- they
# must stay denied, NOT be added). RUN AS ROOT (it reads the audit log).
#
# Usage:
#   sudo ./avc-analyze.sh                       # from the marker avc-testsuite.sh wrote
#   sudo ./avc-analyze.sh -ts "06/01/2026 02:40:00"   # explicit start
#   sudo ./avc-analyze.sh -ts today
#
# The privilege split is deliberate: the agent (ai_tools_t) exercises the surface
# but cannot read /var/log/audit; xd (root) does the analysis. So the two halves
# are two scripts, not one.

set -uo pipefail
IFS=$'\n\t'

readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MARKER="${DIR}/.avc-last-run"
readonly SUBJ="ai_tools_t"

[[ "${EUID}" -eq 0 ]] || { echo "avc-analyze: run with sudo (reads /var/log/audit)" >&2; exit 1; }
command -v ausearch    >/dev/null || { echo "avc-analyze: ausearch not found (audit pkg)" >&2; exit 1; }
command -v audit2allow >/dev/null || { echo "avc-analyze: audit2allow not found (policycoreutils-devel)" >&2; exit 1; }

# Flags: --suggest appends the (verbose) audit2allow -R policy proposal; off by
# default so the report stays short. Must precede -ts (which consumes the rest).
SUGGEST=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --suggest)  SUGGEST=1; shift ;;
    -h|--help)  echo "usage: $0 [--suggest] [-ts <when>]"; exit 0 ;;
    *)          echo "avc-analyze: unknown flag '$1'" >&2; exit 1 ;;
  esac
done

# Resolve the start time: -ts <arg...> wins, else the marker file, else 'today'.
TS=""
if [[ "${1:-}" == "-ts" ]]; then
  shift; TS="${*:-}"
elif [[ -r "${MARKER}" ]]; then
  TS="$(cat "${MARKER}")"
fi
[[ -n "${TS}" ]] || TS="today"

echo "avc-analyze: subject=${SUBJ}  since='${TS}'"
echo

RAW="$(ausearch -m AVC -su "${SUBJ}" -ts ${TS} 2>/dev/null)"
if [[ -z "${RAW}" ]]; then
  cat <<EOF
avc-analyze: NO ai_tools_t AVCs since '${TS}'.

  Three readings -- distinguish them before celebrating:
   (a) GOOD: the policy already covers everything the suite exercised; or
   (b) BAD:  claude ran UNCONFINED, so nothing was attributed to ai_tools_t; or
   (c) BAD:  the exerciser ran OUTSIDE this window -- before '${TS}', or (for
       avc-denials.sh) before the root side held 'semodule -DB'. Boundary
       denials are dontaudit'd, so without -DB active DURING the probe they are
       blocked but never logged, and anything before the marker is not searched.

  Rule out (b):
     ps -eo label,cmd | grep '[c]laude'      # must show ...:ai_tools_t:...
  If it shows unconfined_t, the claude.exe entrypoint lost its ai_tools_exec_t
  label -- see avc-testsuite.sh's preflight message -- fix it, restart claude,
  and re-run the suite.

  Rule out (c): run the exerciser AFTER this marker and, for avc-denials.sh,
  WHILE the root side is waiting (dontaudit disabled): start
  'sudo avc-denials.sh' first, run the probe during its wait, then press Enter.

  An empty log only means "clean" once (a) is confirmed.
EOF
  exit 0
fi

# Target types/patterns the policy intentionally keeps DENIED (dontaudit in ai_tools.te).
# Three categories:
#   1. Named types -- home dirs, config, container storage, MTA, specific ports
#   2. Any *_port_t EXCEPT http_port_t -- the only outbound port the core allows
#   3. Other-domain /proc reads -- dev="proc" with a non-ai_tools tcontext
#      (domain_dontaudit_read_all_domains_state covers these; they appear as
#       tcontext=<daemon_t> but are NOT in the named list above)
# Core boundary types (dontaudit'd -- actively silenced because they are operational
# noise with no security value in the audit log).
# Extended boundary types (section 6 in ai_tools.te -- dontaudit rules are COMMENTED so
# breach attempts ARE logged; listed here so avc-analyze classifies them as EXPECTED
# BOUNDARY rather than NEW when they appear, giving the operator a clear signal that the
# policy is working correctly rather than misreporting them as unclassified gaps).
# This is a CLASSIFICATION regex only -- it tags log lines, never grants/denies anything,
# so it is safe to carry type names that do not exist on every distro. Several types vary
# by selinux-policy version, so BOTH spellings are listed: etc_sudoers_t (RHEL 9 full
# policy; some builds use etc_t, whose reads are already allowed and so never denied) and
# user_runtime_t|user_tmp_t (/run/user/<uid> -- user_runtime_t on standard RHEL 9,
# user_tmp_t on this UEK build). See the portability note in ai_tools.te section (6).
readonly BOUNDARY_NAMED_RE='(user_home_t|user_home_dir_t|home_root_t|config_home_t|container_file_t|sendmail_exec_t|ssh_port_t|smtp_port_t|mysqld_port_t|postgresql_port_t|usb_device_t|shadow_t|etc_sudoers_t|admin_home_t|user_runtime_t|user_tmp_t|system_dbusd_var_run_t|syslogd_var_run_t|container_var_run_t|sysctl_t|sysctl_kernel_t|memory_device_t|fixed_disk_device_t|user_cron_spool_t|system_cron_spool_t|systemd_unit_file_t)'

# Target types granted ONLY by an optional policy group (systemd / pkgmgmt /
# netadmin / podman), all DISABLED by default. With the core module alone these
# accesses are correctly denied -- that is the group being off, not a hole in the
# core policy -- so they are EXPECTED, not NEW. Enabling the matching group
# (install-selinux.sh enable-group <name>) is what would allow them. Mapping:
#   systemd  -> systemd_systemctl_exec_t, journalctl_exec_t, systemd_unit_file_t
#   pkgmgmt  -> rpm_exec_t, rpm_var_lib_t
#   netadmin -> firewalld_t, NetworkManager_t   (firewall-cmd/nmcli D-Bus chat)
#   podman   -> container_runtime_exec_t        (container_file_t is BOUNDARY above:
#                                                core dontaudit's it regardless)
readonly GROUP_DISABLED_RE='(systemd_systemctl_exec_t|journalctl_exec_t|systemd_unit_file_t|rpm_exec_t|rpm_var_lib_t|firewalld_t|NetworkManager_t|container_runtime_exec_t)'

# One line per denial, from the raw AVC records.
LINES="$(printf '%s\n' "${RAW}" | grep -E '^type=AVC|avc:.*denied' || true)"

# Build the boundary set from the three categories, deduplicated.
# Category 1: known named types.
_b1="$(printf '%s\n' "${LINES}" | grep -E "tcontext=[^ ]*:${BOUNDARY_NAMED_RE}:" || true)"
# Category 2: any *_port_t that is NOT http_port_t.
_b2="$(printf '%s\n' "${LINES}" | grep -E 'tcontext=[^ ]*:[a-z_]+_port_t:' | grep -Ev 'tcontext=[^ ]*:http_port_t:' || true)"
# Category 3: other-domain /proc reads (dev="proc", tcontext not ai_tools_t).
_b3="$(printf '%s\n' "${LINES}" | grep -E 'dev="proc"' | grep -Ev 'tcontext=[^ ]*:ai_tools_t:' || true)"

boundary="$(printf '%s\n' "${_b1}" "${_b2}" "${_b3}" | sort -u | grep -v '^$' || true)"

# Group-disabled set: lines hitting a GROUP_DISABLED_RE type, MINUS anything
# already claimed by boundary (boundary wins, so each line lands in one bucket --
# e.g. a /proc read of NetworkManager_t stays boundary, its D-Bus chat is group).
_g="$(printf '%s\n' "${LINES}" | grep -E "tcontext=[^ ]*:${GROUP_DISABLED_RE}:" || true)"
groupdis="$(comm -23 <(printf '%s\n' "${_g}" | sort -u | grep -v '^$') \
                     <(printf '%s\n' "${boundary}" | sort -u | grep -v '^$') | grep -v '^$' || true)"

# Everything intentionally denied (boundary + group-disabled), to subtract from NEW.
excluded="$(printf '%s\n' "${boundary}" "${groupdis}" | sort -u | grep -v '^$' || true)"

# NEW = everything that is neither boundary nor group-disabled.
new="$(comm -23 <(printf '%s\n' "${LINES}" | sort -u | grep -v '^$') <(printf '%s\n' "${excluded}" | sort) | grep -v '^$' || true)"

hr() { printf '%s\n' "------------------------------------------------------------"; }
cnt() { [[ -z "$1" ]] && { echo 0; return; }; printf '%s\n' "$1" | grep -c '^'; }

echo "counts: boundary=$(cnt "${boundary}")  group-disabled=$(cnt "${groupdis}")  NEW=$(cnt "${new}")  (NEW must be 0 to pass)"
echo

hr
echo "EXPECTED BOUNDARY denials (keep DENIED -- already dontaudit'd; do NOT add):"
hr
if [[ -n "${boundary}" ]]; then
  printf '%s\n' "${boundary}" | sed -E 's/.*(comm="[^"]*").*(tcontext=[^ ]*).*(tclass=[^ ]*).*/  \2  \3  \1/' | sort -u
else
  echo "  (none seen this run)"
fi
echo

hr
echo "EXPECTED GROUP-DISABLED denials (optional group is off -- enable-group <name>"
echo "to allow; do NOT fold into the core module):"
hr
if [[ -n "${groupdis}" ]]; then
  printf '%s\n' "${groupdis}" | sed -E 's/.*(comm="[^"]*").*(tcontext=[^ ]*).*(tclass=[^ ]*).*/  \2  \3  \1/' | sort -u
else
  echo "  (none seen this run)"
fi
echo

hr
echo "NEW / UNCLASSIFIED denials (review -- fold genuine NEEDS into ai_tools.te):"
hr
if [[ -n "${new}" ]]; then
  printf '%s\n' "${new}" | sed -E 's/.*(comm="[^"]*").*(tcontext=[^ ]*).*(tclass=[^ ]*).*/  \2  \3  \1/' | sort -u
else
  echo "  (none -- policy covers everything the suite exercised that is not boundary)"
fi
echo

if [[ "${SUGGEST}" -eq 1 ]]; then
  hr
  echo "audit2allow -R suggestion for the FULL set (boundary AND group-disabled items"
  echo "included -- do NOT paste blindly; boundary rules belong as dontaudit, and"
  echo "group-disabled rules belong in their group module, not the core allow set):"
  hr
  printf '%s\n' "${RAW}" | audit2allow -R 2>/dev/null || echo "  (audit2allow produced nothing)"
  echo
else
  echo "(re-run with --suggest for the audit2allow -R policy proposal over the full set)"
  echo
fi
echo "avc-analyze: fold only the NEW genuine needs into ai_tools.te (prefer the refpolicy"
echo "interfaces audit2allow -R names), rebuild with 'install-selinux.sh install', re-run"
echo "the suite, and repeat until NEW is empty."

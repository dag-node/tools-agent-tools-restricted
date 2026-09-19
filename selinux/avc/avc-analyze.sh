#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# selinux/avc/avc-analyze.sh -- collect the ai_tools_t AVCs logged since the last avc-testsuite.sh run and sort them
# into four buckets: EXPECTED BOUNDARY (an access the policy refuses on purpose -- silenced by a dontaudit, or left
# visible as a breach attempt -- and grants no allow rule for), EXPECTED GROUP-DISABLED (accesses only an optional
# policy group would allow, so the fix is enable-group, not a core change), BENIGN PROBE (a call whose refusal changes
# nothing the caller does, classified and left audited), and NEW (the candidates to fold into the policy). NEW must be 0
# to pass. RUN AS ROOT (it reads the audit log).
#
# Usage:
#   sudo ./avc-analyze.sh                             # from the marker avc-testsuite.sh wrote
#   sudo ./avc-analyze.sh -ts 06/01/2026 02:40:00     # explicit start
#   sudo ./avc-analyze.sh -ts today
#   sudo ./avc-analyze.sh -ts today -te 06/01/2026 03:10:00   # bound the far end too
#
# THE MARKER IS THE EXERCISER'S START, NOT THE SESSION'S. avc-testsuite.sh writes it when it runs, which is one turn
# into the session -- so everything the agent did at startup (the launcher's own re-exec, its version and locale
# probing) precedes the marker and is NOT searched. Sweeping a whole session means passing -ts from before it started;
# -te then keeps a later session's denials, or the analyst's own, out of the set.
#
# The privilege split is deliberate: the agent (ai_tools_t) exercises the surface but cannot read /var/log/audit; <you>
# (root) does the analysis. So the two halves are two scripts, not one.

set -uo pipefail
IFS=$'\n\t'

readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MARKER="${DIR}/.avc-last-run"
readonly SUBJ="ai_tools_t"

[[ "${EUID}" -eq 0 ]] || { echo "avc-analyze: run with sudo (reads /var/log/audit)" >&2; exit 1; }
command -v ausearch    >/dev/null || { echo "avc-analyze: ausearch not found (audit pkg)" >&2; exit 1; }
command -v audit2allow >/dev/null || { echo "avc-analyze: audit2allow not found (policycoreutils-devel)" >&2; exit 1; }

# Flags: `--suggest` appends the (verbose) `audit2allow -R` policy proposal; off by default so the report stays short.
SUGGEST=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --suggest)  SUGGEST=1; shift ;;
    -h|--help)  echo "usage: $0 [--suggest] [-ts <when>] [-te <when>]"; exit 0 ;;
    *)          echo "avc-analyze: unknown flag '$1'" >&2; exit 1 ;;
  esac
done

# Resolve the window. ausearch takes a timestamp as TWO argv words -- `-ts <date> <time>` -- and refuses the single
# "MM/DD/YYYY HH:MM:SS" token the marker holds with "Hour, Minute, and Second are required". Each end is therefore
# collected as an ARRAY, and the marker is split on spaces (this script's IFS excludes the space, so an unquoted
# expansion of it stays one word -- the shape that made a refused search read as a clean one). A keyword such as `today`
# or `recent` is one word and passes through as itself.
TS_ARGV=()
TE_ARGV=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -ts) shift; while [[ $# -gt 0 && "$1" != -* ]]; do TS_ARGV+=("$1"); shift; done ;;
    -te) shift; while [[ $# -gt 0 && "$1" != -* ]]; do TE_ARGV+=("$1"); shift; done ;;
    *)   echo "avc-analyze: unexpected argument '$1'" >&2; exit 1 ;;
  esac
done

if [[ ${#TS_ARGV[@]} -eq 0 && -r "${MARKER}" ]]; then
  IFS=' ' read -r -a TS_ARGV < "${MARKER}"
fi
[[ ${#TS_ARGV[@]} -gt 0 ]] || TS_ARGV=(today)

TS_SHOW="$(IFS=' '; printf '%s' "${TS_ARGV[*]}")"
TE_SHOW="$(IFS=' '; printf '%s' "${TE_ARGV[*]:-}")"
TE_NOTE=""
[[ -n "${TE_SHOW}" ]] && TE_NOTE="  until='${TE_SHOW}'"

echo "avc-analyze: subject=${SUBJ}  since='${TS_SHOW}'${TE_NOTE}"
echo

# The search, with its stderr KEPT. ausearch exits non-zero both for "no records matched" (its own `<no matches>`)
# and for a window it could not parse, and the two read identically once the message is discarded -- a refused search
# then reports as a policy that covers everything. Only the first is an empty result; anything else aborts here.
ERR="$(mktemp)"
trap 'rm -f "${ERR}"' EXIT
AUSEARCH_ARGV=(-m AVC -su "${SUBJ}" -ts "${TS_ARGV[@]}")
[[ ${#TE_ARGV[@]} -gt 0 ]] && AUSEARCH_ARGV+=(-te "${TE_ARGV[@]}")
RAW="$(ausearch "${AUSEARCH_ARGV[@]}" 2>"${ERR}")"
rc=$?
if [[ "${rc}" -ne 0 ]] && ! grep -qx '<no matches>' "${ERR}"; then
  {
    echo "avc-analyze: ausearch exited ${rc} -- the window was NOT searched, so this is not a clean result:"
    sed 's/^/  /' "${ERR}"
    echo "  command: ausearch ${AUSEARCH_ARGV[*]}"
  } >&2
  exit 1
fi
if [[ -z "${RAW}" ]]; then
  cat <<EOF
avc-analyze: NO ai_tools_t AVCs since '${TS_SHOW}'.

  Three readings -- distinguish them before celebrating:
   (a) GOOD: the policy already covers everything the suite exercised; or
   (b) BAD:  the agent ran UNCONFINED, so nothing was attributed to ai_tools_t; or
   (c) BAD:  the exerciser ran OUTSIDE this window -- before '${TS_SHOW}', or (for
       avc-denials.sh) before the root side held 'semodule -DB'. Boundary
       denials are dontaudit'd, so without -DB active DURING the probe they are
       blocked but never logged, and anything before the marker is not searched.

  Rule out (b):
     ps -eo label,cmd | grep -E '[c]laude|[c]odex'   # must show ...:ai_tools_t:...
  If it shows unconfined_t, the agent's entrypoint lost its ai_tools_exec_t
  label -- see avc-testsuite.sh's preflight message -- fix it, restart the agent,
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
#       tcontext=<daemon_t> but are NOT in the named optional-group list)
# Core boundary types (dontaudit'd -- actively silenced because they are operational noise with no security value
# in the audit log). Extended boundary types (section 6 in ai_tools.te -- dontaudit rules are COMMENTED so breach
# attempts ARE logged; listed here so avc-analyze classifies them as EXPECTED BOUNDARY rather than NEW when they appear,
# giving the operator a clear signal that the policy is working correctly rather than misreporting them as unclassified
# gaps). This is a CLASSIFICATION regex only -- it tags log lines, never grants/denies anything, so it is safe to carry
# type names that do not exist on every distro. Several types vary by selinux-policy version, so BOTH spellings are
# listed: etc_sudoers_t (RHEL 9 full policy; some builds use etc_t, whose reads are already allowed and so never denied)
# and user_runtime_t|user_tmp_t (/run/user/<uid> -- user_runtime_t on standard RHEL 9, user_tmp_t on this UEK build).
# See the portability note in ai_tools.te section (6). sudo_exec_t and semanage_exec_t are the privilege tools
# themselves: reaching either is the escalation attempt section (6) is written to keep visible, and the agent half
# probes both deliberately (the explicit sudo -> chown step, and `semodule -l` behind each optional-group check).
# Without them here a run of the suite reports its own probes as unclassified gaps.
readonly BOUNDARY_NAMED_RE='(user_home_t|user_home_dir_t|home_root_t|config_home_t|container_file_t|sendmail_exec_t|sudo_exec_t|semanage_exec_t|ssh_port_t|smtp_port_t|mysqld_port_t|postgresql_port_t|usb_device_t|shadow_t|etc_sudoers_t|admin_home_t|user_runtime_t|user_tmp_t|system_dbusd_var_run_t|syslogd_var_run_t|container_var_run_t|sysctl_t|sysctl_kernel_t|memory_device_t|fixed_disk_device_t|user_cron_spool_t|system_cron_spool_t|systemd_unit_file_t)'

# Target types granted ONLY by an optional policy group (systemd / pkgmgmt /
# netadmin / podman), all DISABLED by default. With the core module alone these
# accesses are correctly denied -- that is the group being off, not a hole in the
# core policy -- so they are EXPECTED, not NEW. Enabling the matching group
# (install-selinux.sh enable-group <name>) is what would allow them. Mapping:
#   systemd  -> systemd_systemctl_exec_t, journalctl_exec_t, systemd_unit_file_t
#   pkgmgmt  -> rpm_exec_t, rpm_var_lib_t
#   netadmin -> firewalld_t, NetworkManager_t   (firewall-cmd/nmcli D-Bus chat)
#   podman   -> container_runtime_exec_t        (container_file_t is a BOUNDARY type:
#                                                core dontaudit's it regardless)
# tmpmap is handled separately (_g2): its type, ai_tools_tmp_t, is core-granted for read/write, so it is matched
# on the `map` PERMISSION, not the type alone. apphost is handled separately (_g3): the core does not grant a permission
# on tmpfs_t:file, so the whole memfd surface the .NET JIT/apphost touches (write to size it, map, and the defining
# execute) is that group -- matched on the tmpfs_t:file TYPE. localipc and buildexec are handled separately (_g4):
# the .NET runtime's sockets/FIFOs under tmp/home, getsid, and executing a built binary from the project tree -- matched
# on those classes/perms, which the base grants nowhere.
readonly GROUP_DISABLED_RE='(systemd_systemctl_exec_t|journalctl_exec_t|systemd_unit_file_t|rpm_exec_t|rpm_var_lib_t|firewalld_t|NetworkManager_t|container_runtime_exec_t)'

# One line per denial, from the raw AVC records.
LINES="$(printf '%s\n' "${RAW}" | grep -E '^type=AVC|avc:.*denied' || true)"

# Build the boundary set from the three categories, deduplicated. Category 1: known named types.
_b1="$(printf '%s\n' "${LINES}" | grep -E "tcontext=[^ ]*:${BOUNDARY_NAMED_RE}:" || true)"
# Category 2: any *_port_t that is NOT http_port_t.
_b2="$(printf '%s\n' "${LINES}" | grep -E 'tcontext=[^ ]*:[a-z_]+_port_t:' | grep -Ev 'tcontext=[^ ]*:http_port_t:' || true)"
# Category 3: other-domain /proc reads (dev="proc", tcontext not ai_tools_t).
_b3="$(printf '%s\n' "${LINES}" | grep -E 'dev="proc"' | grep -Ev 'tcontext=[^ ]*:ai_tools_t:' || true)"

boundary="$(printf '%s\n' "${_b1}" "${_b2}" "${_b3}" | sort -u | grep -v '^$' || true)"

# Group-disabled set: lines hitting a GROUP_DISABLED_RE type, MINUS anything already claimed by boundary (boundary wins,
# so each line lands in one bucket -- e.g. a /proc read of NetworkManager_t stays boundary, its D-Bus chat is group).
_g="$(printf '%s\n' "${LINES}" | grep -E "tcontext=[^ ]*:${GROUP_DISABLED_RE}:" || true)"
# tmpmap group: the `map` permission on the sandbox's own /tmp files. ai_tools_tmp_t is a core-granted type
# (read/write/create), so match on the permission -- only a `map` denial here is the disabled group. An execute denial
# on it stays NEW (deliberately never granted; /tmp is noexec regardless).
_g2="$(printf '%s\n' "${LINES}" | grep -E 'tcontext=[^ ]*:ai_tools_tmp_t:' | grep -E 'denied.*\bmap\b' || true)"
# apphost group: any access to a tmpfs (memfd) file. Unlike ai_tools_tmp_t, tmpfs_t:file is NOT core-granted at all --
# so the whole surface .NET's JIT/apphost needs (write to size the memfd, map both mappings, execute the PROT_EXEC one)
# is denied while the group is off, and all of it is this group. Match on the TYPE, so a core-only run does not misfile
# the write/map denials as NEW; `execute` is the highest-risk perm and the reason it is gated. (The graduation-to-stable
# step scopes the grant to a private memfd type, at which point this matches that type instead of the shared tmpfs_t.)
_g3="$(printf '%s\n' "${LINES}" | grep -E 'tcontext=[^ ]*:tmpfs_t:file' || true)"
# localipc + buildexec: three disjoint signals the base grants nowhere -- the .NET runtime's unix sockets / debug FIFOs
# (created under tmp_t or ai_tools_home_t) and getsid (process getsession), both localipc; and executing a native binary
# built in the project tree, buildexec (file execute/execmod/execute_no_trans on ai_tools_project_build_t, the type it
# grants, and on ai_tools_project_t, which it does not -- output that landed outside the layout module's directories,
# or a hook, is denied with the group ON too, and still files here rather than as NEW; `map` on either type is
# core-granted, so it is not a signal).
_g4a="$(printf '%s\n' "${LINES}" | grep -E 'tclass=(sock_file|fifo_file)' | grep -E 'denied.*\bcreate\b' || true)"
_g4b="$(printf '%s\n' "${LINES}" | grep -E 'denied[^}]*\bgetsession\b' || true)"
_g4c="$(printf '%s\n' "${LINES}" | grep -E 'tcontext=[^ ]*:ai_tools_project(_build)?_t:' | grep -E 'denied.*\b(execute|execmod|execute_no_trans)\b' || true)"
# connectto to the domain's own unix stream sockets (the MTP test-host IPC): the base grants create_stream_socket_perms
# on self but not connectto, so this is localipc too.
_g4d="$(printf '%s\n' "${LINES}" | grep -E 'tclass=unix_stream_socket' | grep -E 'denied.*\bconnectto\b' || true)"
_g4="$(printf '%s\n' "${_g4a}" "${_g4b}" "${_g4c}" "${_g4d}" | grep -v '^$' || true)"
_g="$(printf '%s\n' "${_g}" "${_g2}" "${_g3}" "${_g4}" | grep -v '^$' || true)"
groupdis="$(comm -23 <(printf '%s\n' "${_g}" | sort -u | grep -v '^$') \
                     <(printf '%s\n' "${boundary}" | sort -u | grep -v '^$') | grep -v '^$' || true)"

# Benign session-start probes: an access the agent, or the login shell it opens, makes ONCE per session
# and whose refusal changes nothing the caller does, because the caller falls back. They are classified here
# and deliberately LEFT AUDITED rather than dontaudit'd in ai_tools.te section (4): that section silences a flood,
# and the measured rate of these is 3-4 records per session start with none per command afterwards, while a dontaudit
# would also hide a later agent release that starts making the same call in a loop.
#
#   hostname_exec_t -- stock /etc/profile resolves HOSTNAME as hostnamectl, then /usr/bin/hostname, then `uname -n`.
#                      The login shell every agent's shell tool opens runs it, and the third form answers. Not
#                      agent-specific: it fires identically for every agent.
#   usr_t + watch   -- codex arms an inotify watch on the account's home root at startup. Refused; the session
#                      is unaffected. Matched on the PERMISSION, since usr_t reads are core-granted and a usr_t denial
#                      of any other permission is a real finding.
#   install(1)      -- `install` sets the context of the file it just created. The type_transition already gave it
#                      ai_tools_project_t, so the relabel is refused and `install` still exits 0 with the file
#                      correctly labelled (verified for -m, a plain copy, and -D). Matched on the COMMAND as well as
#                      the permission, so a chcon/setfattr attempt to relabel a project file -- an escalation signal --
#                      stays NEW. comm is an analyst's aid, not a control: the access is denied either way.
readonly PROBE_NAMED_RE='(hostname_exec_t)'
_p1="$(printf '%s\n' "${LINES}" | grep -E "tcontext=[^ ]*:${PROBE_NAMED_RE}:" || true)"
_p2="$(printf '%s\n' "${LINES}" | grep -E 'tcontext=[^ ]*:usr_t:' | grep -E 'denied[^}]*\bwatch\b' || true)"
_p3="$(printf '%s\n' "${LINES}" | grep -E 'tcontext=[^ ]*:ai_tools_project_t:' \
        | grep -E 'denied[^}]*\brelabelfrom\b' | grep -F 'comm="install"' || true)"
probe="$(printf '%s\n' "${_p1}" "${_p2}" "${_p3}" | sort -u | grep -v '^$' || true)"

# Everything intentionally denied (boundary + group-disabled + benign probe), to subtract from NEW.
excluded="$(printf '%s\n' "${boundary}" "${groupdis}" "${probe}" | sort -u | grep -v '^$' || true)"

# NEW = everything that is neither boundary, group-disabled, nor a classified probe.
new="$(comm -23 <(printf '%s\n' "${LINES}" | sort -u | grep -v '^$') <(printf '%s\n' "${excluded}" | sort) | grep -v '^$' || true)"

hr() { printf '%s\n' "------------------------------------------------------------"; }
cnt() { [[ -z "$1" ]] && { echo 0; return; }; printf '%s\n' "$1" | grep -c '^'; }

# One denial per line, reduced to the three fields a classification turns on. `comm=` is quoted, or HEX-ENCODED
# when the process name holds a space (`comm=6E6F...` for "notify-rs inotify"), and a field-position match on the quoted
# form alone reprints a hex line whole -- so the printed set stops matching the counts above it. Field names are read
# by name rather than by position, and a denial carrying no comm at all still prints.
fmt() {
  awk '{ c=""; t=""; k="";
         for (i = 1; i <= NF; i++) {
           if ($i ~ /^comm=/)     c = $i;
           if ($i ~ /^tcontext=/) t = $i;
           if ($i ~ /^tclass=/)   k = $i;
         }
         if (t == "") next;
         printf "  %s  %s  %s\n", t, k, (c == "" ? "comm=?" : c) }' | sort -u
}

echo "counts: boundary=$(cnt "${boundary}")  group-disabled=$(cnt "${groupdis}")  probe=$(cnt "${probe}")  NEW=$(cnt "${new}")  (NEW must be 0 to pass)"
echo

hr
echo "EXPECTED BOUNDARY denials (keep DENIED -- silenced in section (4), or left"
echo "visible by section (6) as a breach attempt; do NOT add):"
hr
if [[ -n "${boundary}" ]]; then
  printf '%s\n' "${boundary}" | fmt
else
  echo "  (none seen this run)"
fi
echo

hr
echo "EXPECTED GROUP-DISABLED denials (optional group is off -- enable-group <name>"
echo "to allow; do NOT fold into the core module):"
hr
if [[ -n "${groupdis}" ]]; then
  printf '%s\n' "${groupdis}" | fmt
else
  echo "  (none seen this run)"
fi
echo

hr
echo "BENIGN PROBE denials (left audited on purpose -- the caller falls back and the"
echo "rate is per session, not per command; do NOT grant and do NOT dontaudit):"
hr
if [[ -n "${probe}" ]]; then
  printf '%s\n' "${probe}" | fmt
else
  echo "  (none seen this run)"
fi
echo

hr
echo "NEW / UNCLASSIFIED denials (review -- fold genuine NEEDS into ai_tools.te):"
hr
if [[ -n "${new}" ]]; then
  printf '%s\n' "${new}" | fmt
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
  printf '%s\n' "${RAW}" | audit2allow -R || echo "  (audit2allow produced nothing)"
  echo
else
  echo "(re-run with --suggest for the audit2allow -R policy proposal over the full set)"
  echo
fi
echo "avc-analyze: fold only the NEW genuine needs into ai_tools.te (prefer the refpolicy"
echo "interfaces audit2allow -R names), rebuild with 'install-selinux.sh install', re-run"
echo "the suite, and repeat until NEW is empty."

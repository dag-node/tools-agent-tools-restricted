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

  Two very different readings -- distinguish them before celebrating:
   (a) GOOD: the policy already covers everything the suite exercised; or
   (b) BAD:  claude ran UNCONFINED, so nothing was attributed to ai_tools_t.

  Rule out (b):
     ps -eo label,cmd | grep '[c]laude'      # must show ...:ai_tools_t:...
  If it shows unconfined_t, the claude.exe entrypoint lost its ai_tools_exec_t
  label -- see avc-testsuite.sh's preflight message -- fix it, restart claude,
  and re-run the suite. An empty log only means "clean" once (a) is confirmed.
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
readonly BOUNDARY_NAMED_RE='(user_home_t|user_home_dir_t|home_root_t|config_home_t|container_file_t|sendmail_exec_t|ssh_port_t|smtp_port_t|mysqld_port_t|postgresql_port_t)'

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

# NEW = everything that is NOT in the boundary set.
new="$(comm -23 <(printf '%s\n' "${LINES}" | sort) <(printf '%s\n' "${boundary}" | sort) | grep -v '^$' || true)"

hr() { printf '%s\n' "------------------------------------------------------------"; }

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
echo "NEW / UNCLASSIFIED denials (review -- fold genuine NEEDS into ai_tools.te):"
hr
if [[ -n "${new}" ]]; then
  printf '%s\n' "${new}" | sed -E 's/.*(comm="[^"]*").*(tcontext=[^ ]*).*(tclass=[^ ]*).*/  \2  \3  \1/' | sort -u
else
  echo "  (none -- policy covers everything the suite exercised that is not boundary)"
fi
echo

hr
echo "audit2allow -R suggestion for the FULL set (boundary items included -- do NOT"
echo "paste blindly; the boundary rules above belong as dontaudit, not allow):"
hr
printf '%s\n' "${RAW}" | audit2allow -R 2>/dev/null || echo "  (audit2allow produced nothing)"
echo
echo "avc-analyze: fold only the NEW genuine needs into ai_tools.te (prefer the refpolicy"
echo "interfaces audit2allow -R names), rebuild with 'install-selinux.sh install', re-run"
echo "the suite, and repeat until NEW is empty."

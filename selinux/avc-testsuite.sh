#!/usr/bin/env bash
# selinux/avc-testsuite.sh -- exercise the ai_tools_t surface so a PERMISSIVE
# bring-up logs the full AVC set for audit2allow. RUN AS THE AGENT (claude, the
# ai-tools UID) from inside an approved project dir -- the kernel only attributes
# AVCs to ai_tools_t when the calling process is in that domain.
#
# Pairs with selinux/avc-analyze.sh, which you run as root afterwards to turn the
# logged denials into policy (it reads the start marker this script writes).
#
# Flow:
#   1. (in an approved project, inside a confined claude)  bash selinux/avc-testsuite.sh
#   2. (as <you>, root)                                       sudo selinux/avc-analyze.sh
#
# PREFLIGHT GUARD: if this process is NOT in ai_tools_t the script ABORTS. Running
# it unconfined produces ZERO ai_tools_t AVCs, so `ausearch -su ai_tools_t` would
# come back empty and you'd wrongly conclude the policy is complete. The usual
# cause is the claude.exe entrypoint not being labelled ai_tools_exec_t (so the
# unconfined_t->ai_tools_t transition never fired) -- the guard tells you how to
# fix it. The module ships permissive, so nothing here is ever blocked; it is only
# logged.

set -uo pipefail   # NOT -e: several steps below are EXPECTED to fail (denied
                   # connects, missing tools); we never want that to abort the run.
IFS=$'\n\t'

readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MARKER="${DIR}/.avc-last-run"
readonly SCRATCH="$(pwd)/.avc-scratch"
readonly SECRETS="${SCRATCH}/secrets"      # left for the Stop sweep to quarantine

note() { printf '\033[1;36m[avc]\033[0m %s\n' "$*"; }
step() { printf '\033[1;33m--- %s\033[0m\n' "$*"; }

########################################
# Preflight: must be confined, must be in a labelled project
########################################

ctx="$(id -Z 2>/dev/null || true)"
case "${ctx}" in
  *:ai_tools_t:*) note "confined OK -- running as ${ctx}" ;;
  *)
    cat >&2 <<EOF
[avc] ABORT: this process is '${ctx:-<no SELinux context>}', not ai_tools_t.

      Nothing here would be logged against ai_tools_t, so the bring-up would be
      empty and misleading. The agent is running UNCONFINED -- the
      unconfined_t -> ai_tools_t transition did not fire. Almost always the
      claude.exe entrypoint lost its ai_tools_exec_t label. Fix, as root:

        exe=\$(ls -d /opt/ai-tools/.nvm/versions/node/*/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe)
        restorecon -v "\$exe"
        ls -Z "\$exe"      # MUST show ai_tools_exec_t -- verify, do not assume

      Then fully EXIT claude and relaunch (so sudo execs the now-labelled ELF):

        ps -eo label,cmd | grep '[c]laude'   # MUST show ai_tools_t

      Re-run this script once that holds.
EOF
    exit 2
    ;;
esac

proj_ctx="$(ls -Zd . 2>/dev/null | awk '{print $1}')"
case "${proj_ctx}" in
  *:ai_tools_project_t:*) note "project label OK -- $(pwd) is ${proj_ctx}" ;;
  *) note "WARNING: $(pwd) is '${proj_ctx}', not ai_tools_project_t."
     note "         File ops will log denials against the wrong type. Label it with"
     note "         'install-selinux.sh relabel' (after adding it to allowed-projects)." ;;
esac

########################################
# Start marker -- the exact instant analysis should look from. ausearch -ts wants
# 'MM/DD/YYYY HH:MM:SS'. avc-analyze.sh reads this file.
########################################

START="$(date '+%m/%d/%Y %H:%M:%S')"
printf '%s\n' "${START}" > "${MARKER}" 2>/dev/null \
  || note "could not write marker ${MARKER} (pass -ts to avc-analyze.sh manually)"
note "start marker: ${START}  ->  ${MARKER}"
echo

# Fresh scratch (rerunnable; ai-tools is group-writer on the project dir so it can
# unlink any <you>:<you> secret a previous Stop sweep quarantined here).
rm -rf "${SCRATCH}" 2>/dev/null || true
mkdir -p "${SECRETS}"

########################################
# 1. CREATE -- via the Bash tool (redirect / touch / cp / install). These carry no
#    file_path, so only the Stop sweep hands them back: this is the gap the sweep
#    exists to cover, and it exercises file-create on ai_tools_project_t.
########################################
step "create (redirect, touch, cp, install)"
echo "hello from avc-testsuite" > "${SCRATCH}/created-by-redirect.txt"
touch "${SCRATCH}/created-by-touch.txt"
cp "${SCRATCH}/created-by-redirect.txt" "${SCRATCH}/copied.txt"
install -m 0644 /dev/null "${SCRATCH}/created-by-install.txt" 2>/dev/null || true
mkdir -p "${SCRATCH}/subdir/nested"        # dir create + parent walk
ln -sf created-by-redirect.txt "${SCRATCH}/a-symlink"   # lnk_file create

########################################
# 2. MODIFY -- in-place edits (the awkward case: sed -i rewrites via a temp+rename).
########################################
step "modify (append, sed -i in place)"
printf 'appended line\n' >> "${SCRATCH}/created-by-redirect.txt"
sed -i 's/hello/HELLO/' "${SCRATCH}/created-by-redirect.txt" 2>/dev/null || true

########################################
# 3. PRIVATE TEMP -- files under /tmp should relabel to ai_tools_tmp_t via the
#    type_transition, not generic tmp_t.
########################################
step "private temp (/tmp -> ai_tools_tmp_t)"
t="$(mktemp /tmp/avc-test.XXXXXX 2>/dev/null || echo /tmp/avc-test.fallback)"
echo "scratch" > "${t}" 2>/dev/null || true
mkdir -p "/tmp/avc-test.d.$$" 2>/dev/null || true
rm -f "${t}"; rmdir "/tmp/avc-test.d.$$" 2>/dev/null || true

########################################
# 4. GIT -- a throwaway repo UNDER the project (so it is ai_tools_project_t too).
#    Covers index.lock create/rename/unlink, object writes, ref updates, AND the
#    requested `git mv`. Isolated from the real repo's history. Push is out of scope.
########################################
step "git (init, add, commit, mv, log, branch, diff, status)"
gitrepo="${SCRATCH}/throwaway-repo"
mkdir -p "${gitrepo}"
(
  cd "${gitrepo}" || exit 0
  git init -q . 2>/dev/null
  git config user.email "avc@localhost" 2>/dev/null
  git config user.name  "avc testsuite" 2>/dev/null
  git config commit.gpgsign false 2>/dev/null
  printf 'one\n' > alpha.txt
  git add alpha.txt 2>/dev/null
  git commit -qm "add alpha" 2>/dev/null
  git mv alpha.txt beta.txt 2>/dev/null            # <-- the git mv path
  printf 'two\n' >> beta.txt
  git add beta.txt 2>/dev/null
  git commit -qm "rename + extend" 2>/dev/null
  git status  >/dev/null 2>&1
  git diff HEAD~1 >/dev/null 2>&1
  git log --oneline >/dev/null 2>&1
  git branch avc-branch >/dev/null 2>&1
  git rev-parse HEAD >/dev/null 2>&1
)
note "git exercise done (history stayed inside ${gitrepo})"

########################################
# 5. SECRET QUARANTINE -- drop secret-named files and LEAVE them. The Stop sweep
#    (sandbox-sweep.sh) runs `sudo ai-tools-chown`, which quarantines them to
#    <you>:<you> 600 and logs a NOTICE -- exercising the sudo->root-helper + secret path.
#    Left on purpose; the next run's rm -rf above cleans them.
########################################
step "secret quarantine (.env, *.key left for the Stop sweep)"
printf 'API_TOKEN=avc-fake-not-a-real-secret\n' > "${SECRETS}/.env"
printf -- '-----BEGIN FAKE KEY-----\navc\n-----END FAKE KEY-----\n' > "${SECRETS}/test.key"
note "left ${SECRETS}/{.env,test.key} -- Stop sweep should quarantine them to <you>:<you> 600"

########################################
# 6. NETWORK ALLOWED -- DNS + outbound 443 (http_port_t). Policy grants this.
########################################
step "network ALLOWED (DNS + https/443)"
if command -v curl >/dev/null 2>&1; then
  curl -sS --max-time 6 -o /dev/null -I https://api.anthropic.com/ 2>/dev/null \
    && note "https reachable (expected: allowed)" \
    || note "https probe returned non-zero (network/offline ok -- the connect() still logged)"
else
  note "curl not present; skipping the allowed-network probe"
fi

########################################
# 7. NETWORK DISALLOWED -- connect to a NON-http port (127.0.0.1:22, ssh_port_t).
#    The SELinux port-type check fires on connect() whether or not anything
#    listens, with no packets leaving the box. This denial is the BOUNDARY: it
#    should stay denied (avc-analyze.sh classifies it as expected, not foldable).
########################################
step "network DISALLOWED (127.0.0.1:22, ssh_port_t -- expect a denial)"
timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' 2>/dev/null \
  && note "connect to :22 succeeded at DAC level (SELinux still logged the port check)" \
  || note "connect to :22 refused/denied (expected) -- the ai_tools_t->ssh_port_t AVC is logged"

########################################
# 8. SUDO -> CHOWN HELPER (explicit -- exercises PAM+setuid path now, not only
#    at turn end via the Stop sweep). Creates an agent-owned file then calls
#    ai-tools-chown directly to log the sudo/PAM/capability surface in THIS run.
########################################
step "sudo -> ai-tools-chown (explicit PAM path)"
sudo_test="${SCRATCH}/sudo-chown-test.txt"
printf 'sudo chown test\n' > "${sudo_test}"
if sudo /usr/local/sbin/ai-tools/chown "${sudo_test}" 2>/dev/null; then
    note "ai-tools-chown OK -- sudo+PAM surface exercised (setuid/chown/dac_read_search logged)"
else
    note "ai-tools-chown non-zero (path outside allowlist, or helper not at /usr/local/sbin)"
fi

########################################
# 9. OPTIONAL GROUP SURFACES
#    If a group is loaded, exercise its core path so the bring-up loop covers
#    the extra surface before enforcing. Silently skipped when not loaded.
########################################
step "optional group surfaces (each skipped if group not loaded)"

semodule -l 2>/dev/null | grep -q '^ai_tools_systemd' && {
    note "systemd group loaded -- exercising systemctl + journalctl"
    systemctl --no-pager status 2>/dev/null | head -3 || true
    journalctl --no-pager -n 3 2>/dev/null | head -3 || true
} || note "systemd group not loaded -- skip (enable-group systemd to cover it)"

semodule -l 2>/dev/null | grep -q '^ai_tools_pkgmgmt' && {
    note "pkgmgmt group loaded -- exercising rpm -qa"
    rpm -qa --queryformat '%{NAME}\n' 2>/dev/null | head -5 || true
} || note "pkgmgmt group not loaded -- skip (enable-group pkgmgmt to cover it)"

semodule -l 2>/dev/null | grep -q '^ai_tools_netadmin' && {
    note "netadmin group loaded -- exercising firewall-cmd"
    firewall-cmd --list-zones 2>/dev/null | head -3 || true
} || note "netadmin group not loaded -- skip (enable-group netadmin to cover it)"

semodule -l 2>/dev/null | grep -q '^ai_tools_podman' && {
    note "podman group loaded -- exercising podman info"
    podman info 2>/dev/null | head -5 || true
} || note "podman group not loaded -- skip (enable-group podman to cover it)"

########################################
# Cleanup + next step
########################################
echo
rm -rf "${SCRATCH}/throwaway-repo" "${SCRATCH}"/*.txt "${SCRATCH}/subdir" "${SCRATCH}/a-symlink" 2>/dev/null || true
# (SECRETS left in place on purpose for the Stop sweep; cleaned on next run.)

note "DONE. Exercised: create, modify, temp, git(+mv), secret-quarantine, net allow/deny."
cat <<EOF

Next -- as <you> (root), turn the logged denials into policy:

    sudo ${DIR}/avc-analyze.sh

  or equivalently, by hand:

    sudo ausearch -m AVC -su ai_tools_t -ts "${START}" | audit2allow -R

  The secret-quarantine NOTICE lands at THIS turn's end (Stop sweep), so let the
  turn finish before analysing. Re-run this script + analyze until avc-analyze.sh
  reports only the expected boundary denials (and none under 'NEW').
EOF

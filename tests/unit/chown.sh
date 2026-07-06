#!/usr/bin/env bash
# tests/unit/chown.sh
# Hermetic unit tests for the deployed ai-tools-chown helper: it acts only on agent
# (SANDBOX_USER)-owned paths, hands ordinary ones back to <projects-user>:SANDBOX_GROUP with
# world bits stripped, quarantines secret-named ones to <projects-user>:<projects-user> 600,
# honors '!' exclusions, refuses paths outside the allowlist, and is TOCTOU-safe (pinned fd,
# refuses symlink redirection). Installed helper against a /tmp testdir with a dummy
# allowlist. This test stays out of /var/log to keep its hermetic boundary; the audit-log
# FILE's ownership and mode are pinned in perms.sh (the written log line itself is not asserted).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/sbin/ai-tools/ai-tools-chown"
section "ai-tools-chown: handback + secret quarantine + guards (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-chown" "not installed at ${HELPER}"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"; excl="${proj}/vendor"
mkdir -p "${proj}" "${excl}"
chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${proj}" "${excl}"   # pre-existing project dirs
chmod 0755 "${TESTDIR}" "${proj}" "${excl}"                       # traversable for the EACCES check
mk_allowlist "${proj}" "!${excl}"

# Run the validator the way the hook does: detached from any tty, stdin from /dev/null, so
# it takes its non-interactive apply branch. Captures stderr for the NOTICE assertions.
run() { setsid "${HELPER}" "$1" < /dev/null > /dev/null 2>"${2:-/dev/null}" || true; }

# (1) A path outside the allowlist is left untouched. The reactive hook handler runs per
# written file, so an out-of-allowlist path is a graceful skip (exit 0, no hand-back) rather
# than a hard error: the file stays SANDBOX_USER-owned, never chowned to the operator.
out="${TESTDIR}/outside"; : > "${out}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${out}"; chmod 644 "${out}"
"${HELPER}" "${out}" < /dev/null > /dev/null 2>&1 || true
if [[ "$(stat -c '%U:%G' "${out}")" == "${SANDBOX_USER}:${SANDBOX_GROUP}" ]]; then
    pass "leaves an out-of-allowlist path untouched (no hand-back)"
else
    fail "acted on an out-of-allowlist path: now $(stat -c '%U:%G' "${out}")"
fi

# (2) Ordinary agent-written file -> projects-user:SANDBOX_GROUP, world bits stripped.
ord="${proj}/note.txt"; : > "${ord}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${ord}"; chmod 0644 "${ord}"
run "${ord}"
if [[ "$(stat -c '%U:%G' "${ord}")" == "${PROJECTS_USER}:${SANDBOX_GROUP}" && "$(perm "${ord}")" == 640 ]]; then
    pass "ordinary agent file -> ${PROJECTS_USER}:${SANDBOX_GROUP} 640 (644 -> 640)"
else
    fail "ordinary file ended $(stat -c '%U:%G' "${ord}") $(perm "${ord}")"
fi

# (3) Secret-named agent files are quarantined to the projects user's PRIVATE group, 600,
#     with a NOTICE; representative names incl. an upper-case match.
sec_ok=true
for name in .env.local id_ed25519 server.key cert.pem .pgpass ID_ED25519; do
    s="${proj}/${name}"; : > "${s}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${s}"; chmod 0644 "${s}"
    err="${TESTDIR}/err"; run "${s}" "${err}"
    if [[ "$(stat -c '%U:%G' "${s}")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${s}")" == 600 ]] \
            && grep -qi 'notice' "${err}"; then
        :
    else
        sec_ok=false
        fail "secret ${name}: $(stat -c '%U:%G' "${s}") $(perm "${s}") (want ${PROJECTS_USER}:${PROJECTS_GROUP} 600 + NOTICE)"
    fi
done
${sec_ok} && pass "secret-named files -> ${PROJECTS_USER}:${PROJECTS_GROUP} 600 + NOTICE (incl. upper-case)"

# (4) The agent genuinely cannot read a quarantined secret.
qs="${proj}/.env.local"
if ! sudo -u "${SANDBOX_USER}" cat "${qs}" < /dev/null > /dev/null 2>&1; then
    pass "the agent cannot read the quarantined secret (EACCES)"
else
    fail "the agent could still read ${qs} after quarantine"
fi

# (5) A user-owned secret (not agent-written) is left untouched -- no false breach.
us="${proj}/.npmrc"; : > "${us}"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${us}"; chmod 0640 "${us}"
err="${TESTDIR}/err2"; run "${us}" "${err}"
if [[ "$(stat -c '%U:%G' "${us}")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${us}")" == 640 ]] \
        && ! grep -qi 'notice' "${err}"; then
    pass "a user-owned secret is left untouched (no false breach NOTICE)"
else
    fail "user-owned secret altered: $(stat -c '%U:%G' "${us}") $(perm "${us}")"
fi

# (6) '!'-excluded subtree: an agent file there keeps its ownership.
ex="${excl}/build.out"; : > "${ex}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${ex}"
run "${ex}"
if [[ "$(stat -c '%U:%G' "${ex}")" == "${SANDBOX_USER}:${SANDBOX_GROUP}" ]]; then
    pass "'!'-excluded subtree: ownership preserved"
else
    fail "excluded file was handed back: $(stat -c '%U:%G' "${ex}")"
fi

# (7) A directory the agent created -> projects-user:SANDBOX_GROUP, world stripped, group rwx kept.
dp="${proj}/made"; mkdir "${dp}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${dp}"; chmod 0755 "${dp}"
run "${dp}"
if [[ "$(stat -c '%U:%G' "${dp}")" == "${PROJECTS_USER}:${SANDBOX_GROUP}" && "$(perm "${dp}")" == 770 ]]; then
    pass "agent-created dir -> ${PROJECTS_USER}:${SANDBOX_GROUP} 770 (755 -> 770)"
else
    fail "dir ended $(stat -c '%U:%G' "${dp}") $(perm "${dp}")"
fi

# (8) A user-owned dir (not agent-created) is left untouched (dir-owner guard).
ud="${proj}/userdir"; mkdir "${ud}"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${ud}"; chmod 0700 "${ud}"
run "${ud}"
if [[ "$(stat -c '%U:%G' "${ud}")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${ud}")" == 700 ]]; then
    pass "a user-owned dir is left untouched (dir-owner guard)"
else
    fail "user-owned dir modified: $(stat -c '%U:%G' "${ud}") $(perm "${ud}")"
fi

# (9) A hardlinked file (nlink>1) is left untouched.
hp="${proj}/hard"; : > "${hp}"; ln "${hp}" "${proj}/hardlink"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${hp}"
run "${hp}"
if [[ "$(stat -c '%U:%G' "${hp}")" == "${SANDBOX_USER}:${SANDBOX_GROUP}" ]]; then
    pass "a hardlinked file (nlink>1) is left untouched"
else
    fail "hardlinked file was handed back: $(stat -c '%U:%G' "${hp}")"
fi

# (10) Symlink redirection out of the tree is refused; the outside victim is untouched.
victim="${TESTDIR}/victim"; : > "${victim}"; chown root:root "${victim}"; chmod 0600 "${victim}"
vbefore="$(stat -c '%U:%G %a' "${victim}")"
sl="${proj}/link"; ln -s "${victim}" "${sl}"
run "${sl}"
if [[ "$(stat -c '%U:%G %a' "${victim}")" == "${vbefore}" && -L "${sl}" ]]; then
    pass "symlink to an outside victim is refused; victim untouched (${vbefore})"
else
    fail "symlink redirection modified the outside victim: now $(stat -c '%U:%G %a' "${victim}")"
fi

# (11) Symlinked PARENT: a link INSIDE the project pointing at an outside directory cannot
# smuggle an out-of-allowlist file into handback. realpath -e canonicalises the whole path
# (parents included), so a hand-back of proj/evildir/loot -- where evildir -> an outside dir --
# resolves to the real outside path, which is not under any allowlisted project and is left
# untouched. Distinct from (10), which redirects the FINAL component.
outdir="${TESTDIR}/outside_dir"; mkdir -p "${outdir}"
loot="${outdir}/loot"; : > "${loot}"; chown root:root "${loot}"; chmod 0600 "${loot}"
lbefore="$(stat -c '%U:%G %a' "${loot}")"
ln -s "${outdir}" "${proj}/evildir"           # symlinked parent inside the project
run "${proj}/evildir/loot"
if [[ "$(stat -c '%U:%G %a' "${loot}")" == "${lbefore}" ]]; then
    pass "symlinked parent cannot smuggle an out-of-allowlist file into handback (loot untouched)"
else
    fail "symlinked parent redirected handback onto an outside file: now $(stat -c '%U:%G %a' "${loot}")"
fi

finish

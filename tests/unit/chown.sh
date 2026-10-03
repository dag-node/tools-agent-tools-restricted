#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/chown.sh
# Hermetic unit tests for the deployed ai-tools-chown helper: it acts only on agent (SANDBOX_USER)-owned paths, hands
# ordinary ones back to <projects-user>:SANDBOX_GROUP with world bits stripped, quarantines secret-named ones
# to <projects-user>:<projects-user> 600, honors '!' exclusions, refuses paths outside the allowlist, and is TOCTOU-safe
# (pinned fd, refuses symlink redirection, takes the owner and mode from the pinned inode, also under a live
# `renameat2(RENAME_EXCHANGE)` race). Installed helper against a /tmp testdir with a dummy allowlist. This test stays
# out of /var/log to keep its hermetic boundary; the audit-log FILE's ownership and mode are pinned in perms.sh (the
# written log line itself is not asserted).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-chown"
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

# Run the validator the way the hook does: detached from any tty, stdin from /dev/null, so it takes its non-interactive
# apply branch. Captures stderr for the NOTICE assertions.
run() { setsid "${HELPER}" "$1" < /dev/null > /dev/null 2>"${2:-/dev/null}" || true; }

# (1) A path outside the allowlist is left untouched. The reactive hook handler runs per written file,
# so an out-of-allowlist path is a graceful skip (exit 0, no hand-back) rather than a hard error: the file stays
# SANDBOX_USER-owned, never chowned to the operator.
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

# (2a) A data file the Write tool stamped group-executable (0670, no ACL) -> the stray group execute is stripped while
# group write is kept (owner has no execute, so it is not a script).
gx="${proj}/data.bin"; : > "${gx}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${gx}"; chmod 0670 "${gx}"
run "${gx}"
if [[ "$(perm "${gx}")" == 660 ]]; then
    pass "data file with stray group execute -> 660 (670 -> 660, execute stripped, write kept)"
else
    fail "stray-exec data file ended $(perm "${gx}") (want 660)"
fi

# (2b) A genuine script the agent wrote (owner rwx) keeps its group r-x -- owner-execute marks it executable,
# so handback strips only world and leaves 750.
scr="${proj}/run.sh"; : > "${scr}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${scr}"; chmod 0755 "${scr}"
run "${scr}"
if [[ "$(perm "${scr}")" == 750 ]]; then
    pass "agent script -> 750 (755 -> 750, group r-x kept)"
else
    fail "script ended $(perm "${scr}") (want 750)"
fi

# (2c) On an ACL'd file the strip targets the MASK only: an agent data file whose mask is rwx
# (the mask-execute that surfaces as `-rw-rwx---+`) drops to mask rw, so the operator group keeps
# read+WRITE and the agent can still edit it next turn -- only execute is removed.
if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
    am="${proj}/acl.txt"; : > "${am}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${am}"; chmod 0660 "${am}"
    setfacl -m "g:${SANDBOX_GROUP}:rwx" "${am}"                 # forces mask rwx (shows -rw-rwx---+)
    run "${am}"
    am_mask="$(getfacl -pc "${am}" 2>/dev/null | grep '^mask::' || true)"
    if [[ "${am_mask}" == "mask::rw-" ]]; then
        pass "ACL'd data file: mask rwx -> rw (execute stripped, write preserved)"
    else
        fail "ACL'd file mask ended '${am_mask}' (want mask::rw-)"
    fi
else
    skip "ai-tools-chown ACL mask case" "setfacl/getfacl not available"
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
# The NOTICE's identity, asserted by code on the last run's output: the wording above is content (that a breach was
# reported at all), the code is which situation reported it.
assert_msg MSG-A6D8 "$(cat "${err}")" "the breach NOTICE carries its message code"

# (4) The agent cannot read a quarantined secret -- asserted against the deployed file rather than inferred from its
# mode.
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
        && ! grep -qi 'notice' "${err}" && ! grep -qxF -- MSG-A6D8 "${err}"; then
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

# (11) Argument handling: `--yes` (the batch caller's per-path-prompt skip) is accepted and applies the same hand-back;
# an unknown option or a second path is rejected (usage, rc 2).
by="${proj}/batch.txt"; : > "${by}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${by}"; chmod 0644 "${by}"
setsid "${HELPER}" --yes "${by}" < /dev/null > /dev/null 2>&1 || true
if [[ "$(stat -c '%U:%G' "${by}")" == "${PROJECTS_USER}:${SANDBOX_GROUP}" ]]; then
    pass "--yes applies the hand-back (batch mode)"
else
    fail "--yes run left ${by} at $(stat -c '%U:%G' "${by}")"
fi
badopt_rc=0; "${HELPER}" --frob "${by}" < /dev/null > /dev/null 2>&1 || badopt_rc=$?
twoarg_rc=0; "${HELPER}" "${by}" "${by}" < /dev/null > /dev/null 2>&1 || twoarg_rc=$?
if [[ "${badopt_rc}" == 2 && "${twoarg_rc}" == 2 ]]; then
    pass "unknown option and extra path are usage errors (rc 2)"
else
    fail "argument validation wrong (unknown-opt rc=${badopt_rc}, two-path rc=${twoarg_rc})"
fi

# (12) Symlinked PARENT: a link INSIDE the project pointing at an outside directory cannot smuggle an out-of-allowlist
# file into handback. `realpath -e` canonicalises the whole path (parents included), so a hand-back of proj/evildir/loot
# -- where evildir -> an outside dir -- resolves to the real outside path, which is not under any allowlisted project
# and is left untouched. Distinct from (10), which redirects the FINAL component.
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

# (13) The owner the apply acts on is the pinned inode's, not the path string's. The helper reads owner and mode
# through the path before it pins the inode, and a rename exchange can answer those reads from a decoy. The interactive
# prompt sits between the reads and the pin, so a pty pauses the helper there and the test makes the inode
# operator-owned before answering yes: the apply must refuse. The control run answers yes without the change and must
# hand back, which proves the prompt route reached the apply. pty_apply <path> <change-owner-to-or-empty>: run
# the helper on a pty, wait for its prompt, optionally chown the path, answer yes. Prints "prompted" once the prompt was
# seen.
pty_apply() {
    python3 -I - "${HELPER}" "$1" "${2-}" <<'PY'
import os, pty, select, sys, time
helper, path, new_owner = sys.argv[1], sys.argv[2], sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.execv(helper, [helper, path])
seen, deadline = b"", time.monotonic() + 15
while b"Apply?" not in seen and time.monotonic() < deadline:
    if select.select([fd], [], [], 0.5)[0]:
        try:
            seen += os.read(fd, 4096)
        except OSError:
            break
if b"Apply?" in seen:
    print("prompted")
    if new_owner:
        user, group = new_owner.split(":")
        import grp, pwd
        os.chown(path, pwd.getpwnam(user).pw_uid, grp.getgrnam(group).gr_gid)
    os.write(fd, b"y\n")
deadline = time.monotonic() + 15
while time.monotonic() < deadline:
    if os.waitpid(pid, os.WNOHANG)[0]:
        break
    try:
        if select.select([fd], [], [], 0.5)[0]:
            os.read(fd, 4096)
    except OSError:
        pass
else:
    os.kill(pid, 9)
PY
}
if command -v python3 >/dev/null 2>&1; then
    ctl="${proj}/pinned-control.txt"; : > "${ctl}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${ctl}"; chmod 0644 "${ctl}"
    ctl_seen="$(pty_apply "${ctl}" "")"
    swp="${proj}/pinned-swap.txt"; : > "${swp}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${swp}"; chmod 0644 "${swp}"
    swp_seen="$(pty_apply "${swp}" "${PROJECTS_USER}:${PROJECTS_GROUP}")"
    if [[ "${ctl_seen}" != prompted || "${swp_seen}" != prompted ]]; then
        fail "pinned-owner check: the helper did not prompt on a pty (control '${ctl_seen}', swap '${swp_seen}')"
    elif [[ "$(stat -c '%U:%G %a' "${ctl}")" != "${PROJECTS_USER}:${SANDBOX_GROUP} 640" ]]; then
        fail "pinned-owner control: a confirmed apply left $(stat -c '%U:%G %a' "${ctl}") (want ${PROJECTS_USER}:${SANDBOX_GROUP} 640)"
    elif [[ "$(stat -c '%U:%G %a' "${swp}")" == "${PROJECTS_USER}:${PROJECTS_GROUP} 644" ]]; then
        pass "an inode no longer agent-owned at the pin is refused (owner and mode read from the descriptor)"
    else
        fail "the apply acted on an inode the pin found operator-owned: now $(stat -c '%U:%G %a' "${swp}")"
    fi
else
    skip "pinned-owner check" "python3 not installed"
fi

# (14) The same check under a live rename exchange. The helper reads the identity, then the owner and mode,
# through separate path lookups, and a racer swapping the path with a decoy can answer them from different inodes
# before the pin. The decoy is an operator-owned 755 file, so a run that pinned it on the agent file's owner read would
# hand the operator's file to the agent group, and a run that pinned the agent's 674 file on the decoy's mode read would
# leave it 670 (the script plan) where its own reads give 660. Neither outcome may occur in any run. The window is a few
# lookups wide, so this is a stress check that catches a regression with some probability per run; case (13) is
# the deterministic one. A run that hands the agent file back is required, which proves the racer left the apply
# reachable.
# race_exchange <a> <b>: swap <a> and <b> with renameat2(RENAME_EXCHANGE) until killed. `exec` makes the background
# job's pid the racer's own, so the kill stops it; a racer left running would swap the next run's fixture during setup.
race_exchange() {
    exec python3 -I - "$1" "$2" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
a, b = (os.fsencode(p) for p in sys.argv[1:3])
while True:
    if libc.renameat2(-100, a, -100, b, 2) != 0:
        sys.exit("renameat2: " + os.strerror(ctypes.get_errno()))
PY
}
if command -v python3 >/dev/null 2>&1; then
    rp="${proj}/race.txt"; rq="${proj}/race-decoy.txt"
    runs=150 handed=0 left=0 racer_errors=0 mixed=""
    for (( n = 0; n < runs; n++ )); do
        rm -f "${rp}" "${rq}"
        : > "${rp}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${rp}"; chmod 0674 "${rp}"
        : > "${rq}"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${rq}"; chmod 0755 "${rq}"
        agent_ino="$(stat -c %i "${rp}")"
        race_exchange "${rp}" "${rq}" 2>"${TESTDIR}/racer.err" &
        racer=$!
        run "${rp}"
        kill "${racer}" 2>/dev/null || true
        wait "${racer}" 2>/dev/null || true
        if kill -0 "${racer}" 2>/dev/null; then
            fail "rename-exchange race: the racer outlived its kill in run ${n}, so later runs would not be read"
            break
        fi
        [[ -s "${TESTDIR}/racer.err" ]] && racer_errors=$(( racer_errors + 1 ))
        # The racer stopped at an arbitrary point, so a name may hold either inode: each is identified by its number,
        # read with its owner and mode in one stat.
        for f in "${rp}" "${rq}"; do
            read -r ino state_owner state_mode < <(stat -c '%i %U:%G %a' "${f}")
            state="${state_owner} ${state_mode}"
            if [[ "${ino}" == "${agent_ino}" ]]; then
                case "${state}" in
                    "${SANDBOX_USER}:${SANDBOX_GROUP} 674") left=$(( left + 1 )) ;;
                    "${PROJECTS_USER}:${SANDBOX_GROUP} 660") handed=$(( handed + 1 )) ;;
                    *) mixed+="run ${n}: agent file ${state}; " ;;
                esac
            elif [[ "${state}" != "${PROJECTS_USER}:${PROJECTS_GROUP} 755" ]]; then
                mixed+="run ${n}: operator decoy ${state}; "
            fi
        done
    done
    rm -f "${rp}" "${rq}"
    if (( racer_errors > 0 )); then
        fail "rename-exchange race: the racer failed in ${racer_errors} run(s): $(head -n1 "${TESTDIR}/racer.err")"
    elif [[ -n "${mixed}" ]]; then
        fail "rename-exchange race: an apply mixed two inodes -- ${mixed}"
    elif (( handed == 0 )); then
        fail "rename-exchange race: no run handed the agent file back in ${runs}, so the apply was never reached"
    else
        pass "rename-exchange race: ${runs} runs, ${handed} handed back, ${left} refused, none acted on a mixed read"
    fi
else
    skip "rename-exchange race" "python3 not installed"
fi

# A present secret-patterns file the loader refuses to read refuses the handback (exit 1, under the library's code):
# the path stays sandbox-owned, where a classification on a set the operator did not write would hand it back. Driven
# through the loader's file hook at a directory, the one unreadable state root meets on any host; case (2) is
# the control, the same shape of path handed back when the file reads.
unread="${proj}/unread.txt"; : > "${unread}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${unread}"; chmod 0644 "${unread}"
mkdir -p "${TESTDIR}/patterns-dir"
rc=0
err="$(AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-dir" setsid "${HELPER}" "${unread}" < /dev/null 2>&1 >/dev/null)" || rc=$?
if (( rc == 1 )) && [[ "$(stat -c '%U:%G' "${unread}")" == "${SANDBOX_USER}:${SANDBOX_GROUP}" ]]; then
    pass "an unreadable secret-patterns file refuses the handback (exit 1) and leaves the path sandbox-owned"
else
    fail "an unreadable secret-patterns file: rc=${rc}, path is $(stat -c '%U:%G' "${unread}") (want 1, ${SANDBOX_USER}:${SANDBOX_GROUP})"
fi
assert_msg MSG-S4T9 "${err}" "the refusal names the unreadable file under the library's code"

finish

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/lockdown.sh
# Hermetic unit tests for the deployed ai-tools-lockdown helper: the PROACTIVE secret sweep. Unlike ai-tools-chown
# (reactive, agent-owned paths only), lockdown locks down EVERY secret-named path under an allowed project -- including
# pre-existing user-owned ones the agent could otherwise read -- setting files 600, directories 700, owner <you>:<you>.
# It operates on the CWD (not a path arg), honours the same allowlist + '!'-exclusions + skip list, refuses to run
# as the sandbox account, and applies through a pinned fd. Run against a /tmp testdir with a dummy allowlist
# (AI_TOOLS_ALLOWLIST override) as root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-lockdown"
section "ai-tools-lockdown: proactive secret sweep (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-lockdown" "not installed at ${HELPER}"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"
mkdir -p "${proj}/secrets" "${proj}/vendor" "${proj}/.git"
chmod 0755 "${TESTDIR}" "${proj}"

# Pre-existing, user-owned fixtures -- the case ai-tools-chown's owner guard skips, since it acts only on a path
# the sandbox account currently owns, which is what lockdown exists to cover. Secret-named file + dir, an ordinary file,
# a secret under a '!'-excluded subtree, and a secret under a skipped (.git) tree.
mk_secret() { : > "$1"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "$1"; chmod 0644 "$1"; }
mk_secret "${proj}/.env"                                            # secret file
chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${proj}/secrets"; chmod 0755 "${proj}/secrets"  # secret dir
: > "${proj}/secrets/inner"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${proj}/secrets/inner"
mk_secret "${proj}/README.md" && chmod 0644 "${proj}/README.md"     # ordinary (non-secret name)
mk_secret "${proj}/vendor/.npmrc"                                   # secret under '!'-excluded
mk_secret "${proj}/.git/id_rsa"                                     # secret under skipped .git
# A secret carrying the residue a file born inside a claimed tree would have: the project's inherited group ACL entry.
# chmod alone only masks it, so the lock has to remove it. Kept on its own fixture because `setfacl -m` recalculates
# the mask, which moves the visible mode bits.
residue_acl=false
if command -v setfacl >/dev/null 2>&1; then
    mk_secret "${proj}/residue.key"
    if setfacl -m "group:${SANDBOX_GROUP}:rwX" "${proj}/residue.key" 2>/dev/null; then
        residue_acl=true
    fi
fi
# Owner-only, NON-secret fixtures: the paths an operator seals by MODE rather than by name, which no pattern reaches.
# Built in the real order -- the ACL arrives by inheritance first, the operator's chmod comes after -- so the entry is
# present but masked, as on a path created inside a claimed tree.
seal_fx=false
if command -v setfacl >/dev/null 2>&1; then
    mkdir -p "${proj}/privatedir"
    : > "${proj}/notes.txt"
    chown -R "${PROJECTS_USER}:${SANDBOX_GROUP}" "${proj}/privatedir" "${proj}/notes.txt"
    if setfacl -m "group:${SANDBOX_GROUP}:rwX" \
            "${proj}/privatedir" "${proj}/notes.txt" 2>/dev/null; then
        setfacl -d -m "group:${SANDBOX_GROUP}:rwX" "${proj}/privatedir" 2>/dev/null || true
        seal_fx=true
    fi
    chmod 2700 "${proj}/privatedir"
    chmod 0600 "${proj}/notes.txt"
fi
# A sandbox clone as ai-tools.projects.clone hands it to the secret gate: owner-only throughout, since the CLI runs
# the clone under a pinned `umask 077`; grouped to the sandbox account by the setgid clone area; carrying a checked-in
# secret and a depth-one directory.
clone="${TESTDIR}/clone"
mkdir -p "${clone}/src"
: > "${clone}/.env"
chown -R "${PROJECTS_USER}:${SANDBOX_GROUP}" "${clone}"
chmod 2700 "${clone}" "${clone}/src"
chmod 0600 "${clone}/.env"
mk_allowlist "${proj}" "!${proj}/vendor" "${clone}"

# Run the deployed helper in <cwd> (it acts on pwd), non-interactive (`--yes`), never aborting the suite. Captures
# combined output to <outfile>; sets the global LD_RC to its exit code.
run_ld() {  # <cwd> <outfile> [args...]
    local cwd="$1" out="$2"; shift 2
    ( cd "${cwd}" && "${HELPER}" "$@" ) < /dev/null > "${out}" 2>&1 && LD_RC=0 || LD_RC=$?
}

# (1) Dry-run reports the secret but does not change a path.
out="${TESTDIR}/dry"
run_ld "${proj}" "${out}" --dry-run
if [[ "$(stat -c '%U:%G' "${proj}/.env")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/.env")" == 644 ]] \
        && grep -q "${proj}/.env" "${out}"; then
    pass "dry-run lists the secret and makes no changes (.env stays ${PROJECTS_USER}:${PROJECTS_GROUP} 644)"
else
    fail "dry-run altered .env or did not report it: $(stat -c '%U:%G' "${proj}/.env") $(perm "${proj}/.env")"
fi

# (1b) The dry run covers the SEAL pass too, not just the secret lock. An apply strips residue
#      from paths sealed by MODE, so a preview that showed only the secret half would understate
#      what the operator is about to authorize -- and the seal half is the one that touches paths
#      they never named. Each hit says what it carries, and the tree is byte-for-byte untouched:
#      setgid still set, group still the sandbox's, ACL entry still there.
if ${seal_fx}; then
    if grep -q 'privatedir' "${out}" \
            && [[ "$(stat -c '%a %G' "${proj}/privatedir")" == "2700 ${SANDBOX_GROUP}" ]] \
            && getfacl -c -- "${proj}/privatedir" 2>/dev/null | grep -q "^group:${SANDBOX_GROUP}:"; then
        pass "dry-run reports the seal pass and strips nothing (privatedir keeps setgid, group and ACL)"
    else
        fail "dry-run seal preview missing or it mutated privatedir: $(stat -c '%a %G' "${proj}/privatedir")"
    fi
else
    skip "dry-run seal preview" "ACL fixture unavailable"
fi

# (2) Apply: lock down the tree.
run_ld "${proj}" "${TESTDIR}/apply" --yes
if [[ "${LD_RC}" -ne 0 ]]; then
    fail "lockdown --yes exited ${LD_RC}: $(cat "${TESTDIR}/apply")"
fi

# (2a) Secret file -> <you>:<you> 600. The owner's OWN group, not the sandbox group: at 600 the
#      group does not grant access either way, but leaving it as SANDBOX_GROUP would hand the file back
#      to the agent the moment the mode was widened. Same target ai-tools-chown uses on write.
if [[ "$(stat -c '%U:%G' "${proj}/.env")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/.env")" == 600 ]]; then
    pass "secret file -> ${PROJECTS_USER}:${PROJECTS_GROUP} 600 (agent read revoked)"
else
    fail "secret file ended $(stat -c '%U:%G' "${proj}/.env") $(perm "${proj}/.env")"
fi

# (2b) Secret directory -> <you>:<you> 700.
if [[ "$(stat -c '%U:%G' "${proj}/secrets")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/secrets")" == 700 ]]; then
    pass "secret dir -> ${PROJECTS_USER}:${PROJECTS_GROUP} 700"
else
    fail "secret dir ended $(stat -c '%U:%G' "${proj}/secrets") $(perm "${proj}/secrets")"
fi

# (2c) A locked secret does not keep a sandbox ACL entry: chmod 600 masks the inherited entry but does
#      not remove it, so widening the mode later would re-expose the secret.
if ${residue_acl}; then
    if getfacl -c -- "${proj}/residue.key" 2>/dev/null | grep -q "^group:${SANDBOX_GROUP}:"; then
        fail "a locked secret still carries a group:${SANDBOX_GROUP} ACL entry"
    else
        pass "a locked secret's inherited group:${SANDBOX_GROUP} ACL entry is removed"
    fi
    if [[ "$(perm "${proj}/residue.key")" == 600 ]]; then
        pass "stripping the entry leaves the locked secret at 600 (mask not recalculated)"
    else
        fail "locked secret ended $(perm "${proj}/residue.key"), expected 600"
    fi
else
    skip "locked-secret ACL strip" "setfacl unavailable"
fi

# (2c) Ordinary file is left untouched.
if [[ "$(stat -c '%U:%G' "${proj}/README.md")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/README.md")" == 644 ]]; then
    pass "ordinary (non-secret) file is left untouched"
else
    fail "ordinary file altered: $(stat -c '%U:%G' "${proj}/README.md") $(perm "${proj}/README.md")"
fi

# (2d) '!'-excluded secret is skipped.
if [[ "$(stat -c '%U:%G' "${proj}/vendor/.npmrc")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/vendor/.npmrc")" == 644 ]]; then
    pass "'!'-excluded secret is left untouched"
else
    fail "excluded secret was locked: $(stat -c '%U:%G' "${proj}/vendor/.npmrc") $(perm "${proj}/vendor/.npmrc")"
fi

# (2e) Secret under a skipped tree (.git) is left untouched.
if [[ "$(stat -c '%U:%G' "${proj}/.git/id_rsa")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${proj}/.git/id_rsa")" == 644 ]]; then
    pass "secret under a skipped tree (.git) is left untouched"
else
    fail "skipped-tree secret was locked: $(stat -c '%U:%G' "${proj}/.git/id_rsa") $(perm "${proj}/.git/id_rsa")"
fi

# (3) A non-allowlisted CWD is refused (non-zero), and its secret is untouched.
mk_secret "${TESTDIR}/.env"                       # TESTDIR itself is NOT in the allowlist
run_ld "${TESTDIR}" "${TESTDIR}/refuse" --yes
if [[ "${LD_RC}" -ne 0 ]] && [[ "$(perm "${TESTDIR}/.env")" == 644 ]]; then
    pass "refuses a non-allowlisted CWD (non-zero, nothing changed)"
else
    fail "non-allowlisted CWD not refused (rc=${LD_RC}) or .env changed: $(cat "${TESTDIR}/refuse")"
fi
assert_msg MSG-K8Z6 "$(cat "${TESTDIR}/refuse")" "the refusal names the unresolved project by its code"

# (4) Refuses to run as the sandbox account (guard fires before any change). A fresh secret
#     created for this case stays untouched.
mk_secret "${proj}/fresh.key"
( cd "${proj}" && SUDO_USER="${SANDBOX_USER}" "${HELPER}" --yes ) < /dev/null > "${TESTDIR}/asagent" 2>&1 \
    && agent_rc=0 || agent_rc=$?
# The mode is what distinguishes "refused" from "locked" here: a locked secret is now owned <you>:<you> too,
# so ownership alone no longer tells the two apart.
if [[ "${agent_rc}" -ne 0 ]] \
        && [[ "$(perm "${proj}/fresh.key")" == 644 ]] \
        && [[ "$(stat -c '%U:%G' "${proj}/fresh.key")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" ]]; then
    pass "refuses to run as the sandbox account (no changes made)"
else
    fail "did not refuse the sandbox account (rc=${agent_rc}) or fresh.key changed: $(cat "${TESTDIR}/asagent")"
fi
assert_msg MSG-M8A8 "$(cat "${TESTDIR}/asagent")" "the sandbox-account refusal carries its code"

# (5) The seal pass: a NON-secret path the operator sealed by mode has its residue stripped even
#     though no pattern matches its name, so a path sealed after the claim is cleaned up here
#     rather than waiting for the next claim. Asserted on the run from (2).
if ${seal_fx}; then
    dm="$(stat -c '%a' "${proj}/privatedir")"
    if (( (8#${dm} & 8#2000) == 0 )) && [[ "$(perm "${proj}/privatedir")" == 700 ]]; then
        pass "a sealed non-secret dir loses its setgid bit and keeps mode 700"
    else
        fail "sealed dir ended mode ${dm}, expected setgid cleared and 700"
    fi
    if [[ "$(stat -c '%G' "${proj}/privatedir")" != "${SANDBOX_GROUP}" ]]; then
        pass "a sealed non-secret dir is moved off group ${SANDBOX_GROUP}"
    else
        fail "a sealed dir is still group ${SANDBOX_GROUP}"
    fi
    if getfacl -c -- "${proj}/privatedir" 2>/dev/null \
            | grep -q "^\(default:\)\?group:${SANDBOX_GROUP}:"; then
        fail "a sealed dir kept its sandbox ACL entries"
    else
        pass "a sealed dir's access and default sandbox ACL entries are removed"
    fi
    if [[ "$(perm "${proj}/notes.txt")" == 600 ]] \
            && ! getfacl -c -- "${proj}/notes.txt" 2>/dev/null \
                 | grep -q "^group:${SANDBOX_GROUP}:"; then
        pass "a sealed non-secret file is stripped and stays 600"
    else
        fail "sealed file ended $(perm "${proj}/notes.txt") $(stat -c '%U:%G' "${proj}/notes.txt")"
    fi
else
    skip "owner-only seal pass" "setfacl unavailable"
fi

# (6) The seal enumeration leaves the target directory itself alone. The CLI's pinned `umask 077` makes a clone
#     owner-only throughout, so with the root on the seal list an apply on a tip commit holding a secret would clear
#     the root's setgid bit and move its group off the sandbox account's -- and normalize_clone restores the mode
#     bits, not the group, so the agent would be refused at the root of a clone reported ready. The root keeps its
#     mode and group, the pass does not descend into it (the depth-one directory keeps both too), and the secret
#     inside is still locked.
run_ld "${clone}" "${TESTDIR}/clone-apply" --yes
if [[ "${LD_RC}" -ne 0 ]]; then
    fail "lockdown --yes on the clone exited ${LD_RC}: $(cat "${TESTDIR}/clone-apply")"
fi
if [[ "$(stat -c '%a %G' "${clone}")" == "2700 ${SANDBOX_GROUP}" ]]; then
    pass "an owner-only clone root keeps its setgid bit and group ${SANDBOX_GROUP} (the target is not sealed)"
else
    fail "the clone root ended $(stat -c '%a %G' "${clone}"), expected 2700 ${SANDBOX_GROUP}"
fi
if [[ "$(stat -c '%a %G' "${clone}/src")" == "2700 ${SANDBOX_GROUP}" ]]; then
    pass "the pass does not descend into an owner-only root (the depth-one dir keeps setgid and group)"
else
    fail "the depth-one dir ended $(stat -c '%a %G' "${clone}/src"), expected 2700 ${SANDBOX_GROUP}"
fi
if [[ "$(stat -c '%U:%G' "${clone}/.env")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" && "$(perm "${clone}/.env")" == 600 ]]; then
    pass "the secret inside the owner-only clone is still locked to ${PROJECTS_USER}:${PROJECTS_GROUP} 600"
else
    fail "the clone's secret ended $(stat -c '%U:%G' "${clone}/.env") $(perm "${clone}/.env")"
fi

# (7) `--gate`, the claim's one call: stdout carries every secret-matching path NUL-terminated and no other byte, since
#     the claim reads it back as the list it keeps out of the clone's shared access; the page on stderr names each path
#     relative to the project and closes on one summary line. Without a terminal the question takes its default, yes.
#     A tree with no secret leaves stdout empty, including the line the helper prints when there is no path to act
#     on. `--dry-run` beside it is refused before the scan, since a dry run exits 0 with the paths listed and none
#     locked; `--gate` is left out of the helper's usage text and is refused the same way when typed.
gate="${proj}/gatecase"
mkdir -p "${gate}"; : > "${gate}/.env"; : > "${gate}/plain.txt"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${gate}"; chmod 0755 "${gate}"; chmod 0644 "${gate}/.env" "${gate}/plain.txt"
run_gate() {  # <cwd> -- the helper under --gate with no terminal: stdout to gate.out, stderr to gate.err, exit to LD_RC
    ( cd "$1" && setsid -w "${HELPER}" --gate ) < /dev/null > "${TESTDIR}/gate.out" 2> "${TESTDIR}/gate.err" \
        && LD_RC=0 || LD_RC=$?
}
run_gate "${gate}"
if (( LD_RC == 0 )) && cmp -s "${TESTDIR}/gate.out" <(printf '%s\0' "${gate}/.env"); then
    pass "--gate writes the secret-matching path to stdout NUL-terminated, and no other byte"
else
    fail "--gate stdout: rc=${LD_RC}: $(od -c "${TESTDIR}/gate.out" | head -3)"
fi
if grep -qE '^ +\[file\] \.env$' "${TESTDIR}/gate.err" && grep -q 'locked 1 path(s)' "${TESTDIR}/gate.err" \
        && [[ "$(perm "${gate}/.env")" == 600 ]]; then
    pass "--gate lists the path relative to the project, locks it without a terminal, and summarizes in one line"
else
    fail "--gate page or lock: $(perm "${gate}/.env"): $(tr '\n' '|' < "${TESTDIR}/gate.err")"
fi
rm -f "${gate}/.env"
run_gate "${gate}"
if (( LD_RC == 0 )) && [[ ! -s "${TESTDIR}/gate.out" ]]; then
    pass "--gate over a tree with no secret writes nothing to stdout"
else
    fail "--gate with no secret: rc=${LD_RC}: $(od -c "${TESTDIR}/gate.out" | head -3)"
fi
: > "${gate}/.env"; chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${gate}/.env"; chmod 0644 "${gate}/.env"
( cd "${gate}" && setsid -w "${HELPER}" --gate --dry-run ) < /dev/null > "${TESTDIR}/gate.out" 2> "${TESTDIR}/gate.err" \
    && LD_RC=0 || LD_RC=$?
assert_msg MSG-G8S6 "$(cat "${TESTDIR}/gate.err")" "--gate with --dry-run is refused"
if (( LD_RC == 2 )) && [[ ! -s "${TESTDIR}/gate.out" && "$(perm "${gate}/.env")" == 644 ]]; then
    pass "--gate with --dry-run exits 2 with no path written and no file changed"
else
    fail "--gate --dry-run: rc=${LD_RC}, .env $(perm "${gate}/.env"): $(od -c "${TESTDIR}/gate.out" | head -2)"
fi
# A dry run neither changes a path nor asks, so `--yes` beside it is refused with the usage status, not ignored.
( cd "${gate}" && "${HELPER}" --dry-run --yes ) < /dev/null > "${TESTDIR}/gate.err" 2>&1 && LD_RC=0 || LD_RC=$?
assert_msg MSG-P5P8 "$(cat "${TESTDIR}/gate.err")" "--dry-run with --yes is refused"
if (( LD_RC == 2 )) && [[ "$(perm "${gate}/.env")" == 644 ]]; then
    pass "--dry-run with --yes exits 2 and changes no file"
else
    fail "--dry-run --yes: rc=${LD_RC}, .env $(perm "${gate}/.env")"
fi
# A secret the lock cannot take -- hardlinked, so a chmod would reach its other name outside the tree -- is named,
# and the run exits non-zero: the claim's gate grants access only on 0, so a tree holding it is not opened.
ln "${gate}/.env" "${TESTDIR}/env-second-name"
run_gate "${gate}"
assert_msg MSG-T2J8 "$(cat "${TESTDIR}/gate.err")" "an unlocked secret-matching path fails the run"
if (( LD_RC == 1 )) && grep -q 'not locked: .env' "${TESTDIR}/gate.err" && [[ "$(perm "${gate}/.env")" == 644 ]]; then
    pass "--gate over a hardlinked secret names it, leaves it as it was, and exits 1"
else
    fail "--gate over a hardlinked secret: rc=${LD_RC}: $(tr '\n' '|' < "${TESTDIR}/gate.err")"
fi
rm -f "${TESTDIR}/env-second-name"

# (8) `--full`, the clone's half of the gate: the walk has no skip list, so a secret under a skip-listed directory is
#     found and locked, where `--gate` alone skips the directory -- which the claim in place may, since its own walks
#     skip it too, and the clone's normalize may not, since it opens every directory it does not prune.
full="${proj}/fullcase"
mkdir -p "${full}/node_modules"; : > "${full}/node_modules/.env"; : > "${full}/plain.txt"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${full}"
chmod 0755 "${full}" "${full}/node_modules"; chmod 0644 "${full}/node_modules/.env" "${full}/plain.txt"
run_gate "${full}"
if (( LD_RC == 0 )) && [[ ! -s "${TESTDIR}/gate.out" && "$(perm "${full}/node_modules/.env")" == 644 ]]; then
    pass "--gate skips a secret under node_modules (the skip list the claim's walks share)"
else
    fail "--gate over node_modules: rc=${LD_RC}, .env $(perm "${full}/node_modules/.env"): $(od -c "${TESTDIR}/gate.out" | head -2)"
fi
( cd "${full}" && setsid -w "${HELPER}" --gate --full ) < /dev/null > "${TESTDIR}/gate.out" 2> "${TESTDIR}/gate.err" \
    && LD_RC=0 || LD_RC=$?
if (( LD_RC == 0 )) && cmp -s "${TESTDIR}/gate.out" <(printf '%s\0' "${full}/node_modules/.env") \
        && [[ "$(perm "${full}/node_modules/.env")" == 600 ]]; then
    pass "--gate --full finds and locks the secret under node_modules, and writes its path to stdout"
else
    fail "--gate --full over node_modules: rc=${LD_RC}, .env $(perm "${full}/node_modules/.env"): $(tr '\n' '|' < "${TESTDIR}/gate.err")"
fi

finish

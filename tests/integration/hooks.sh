#!/usr/bin/env bash
# tests/integration/hooks.sh
# Integration: the live ownership-handback hooks end-to-end (PostToolUse, Stop sweep,
# SessionStart reclaim). Each hook delegates to the handback socket daemon, which execs
# ai-tools-chown with its OWN environment -- so the AI_TOOLS_ALLOWLIST test override does NOT
# reach it (it is stripped by sudo/the daemon, by design); the helper reads the REAL
# allowlist. The fixtures therefore live in a self-cleaning subdir INSIDE the project this
# suite is run from, reusing that project's existing allowlist entry (the session runs in it).
# They cannot use /tmp: /tmp and /var/tmp are polyinstantiated per session by pam_namespace
# (root/adm exempt), so a /tmp fixture is invisible to the hook's own `sudo -u ai-tools`
# session (a private, empty /tmp instance) -- the hand-back would silently no-op. The test
# SKIPS when its run-dir is not allowlisted. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly hook="/opt/ai-tools/.claude/post-tool-hook.sh"
readonly sweep="/opt/ai-tools/.claude/session-hook.sh"
readonly REAL_ALLOWLIST="${PROJECTS_HOME}/.config/ai-tools/allowed-projects"
readonly SOCK="/run/ai-tools/handback.sock"

section "Ownership-handback hooks end-to-end (integration)"

if [[ ! -x "${hook}" || ! -x "${sweep}" ]]; then
    skip "handback hooks" "hooks not installed under /opt/ai-tools/.claude"; finish; exit
fi
if [[ ! -S "${SOCK}" ]]; then
    skip "handback hooks" "handback socket ${SOCK} not present (daemon not started?)"; finish; exit
fi

# ── Fixtures inside the already-allowlisted run-dir project ──────────────────────
# REPO is the project this suite is run from (tests/integration/hooks.sh -> ../..). The
# daemon-exec'd helper validates each path against the REAL allowlist, so the fixtures must
# sit under an allowlisted path -- and this project already is one (the session runs in it).
# Confirm that against the real allowlist (mirroring the wrapper's allow-match: an entry that
# equals REPO or is an ancestor of it), and SKIP rather than mutate the allowlist if not.
readonly REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
covered=false
if [[ -r "${REAL_ALLOWLIST}" ]]; then
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        [[ -z "${entry}" || "${entry}" == '#'* || "${entry}" == '!'* ]] && continue
        d="$(realpath -e "${entry}" 2>/dev/null)" || continue
        if [[ "${REPO}" == "${d}" || "${REPO}" == "${d}"/* ]]; then covered=true; break; fi
    done < "${REAL_ALLOWLIST}"
fi
if ! ${covered}; then
    skip "handback hooks" "run-dir ${REPO} is not in the real allowlist -- run this suite from a claimed project"
    finish; exit
fi

# A self-cleaning fixture dir inside the project. Born under the project's group so the agent
# (which traverses the project tree via group ai-tools) can reach it.
proj="$(mktemp -d "${REPO}/.handback-test.XXXXXX")"
_cleanup+=("${proj}")
chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${proj}"
chmod 0755 "${proj}"

# Under SELinux enforcing the confined chown helper can only act on an ai_tools_project_t
# tree. The project usually already carries that label (it is claimed); set it on the fixture
# explicitly so the test holds even if the project's label has lapsed. Root sets it directly
# (no sudo/password). A failure here (module not loaded) is surfaced by the assertions below.
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    chcon -R -t ai_tools_project_t "${proj}" 2>/dev/null \
        || skip "project label" "could not set ai_tools_project_t on ${proj} (module not loaded?)"
fi

# ── PostToolUse: immediate Write/Edit handback ───────────────────────────────────
run_hook() {  # $1 = file_path
    printf '{"tool_input":{"file_path":"%s"}}' "$1" \
        | timeout 15 setsid sudo -u "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" "${hook}" \
            > /dev/null 2>&1 || true
}

# (A) An agent-owned ordinary file is handed back to <projects-user>:SANDBOX_GROUP.
hk="${proj}/note.txt"; : > "${hk}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${hk}"; chmod 0600 "${hk}"
run_hook "${hk}"
if [[ "$(stat -c '%U:%G' "${hk}")" == "${PROJECTS_USER}:${SANDBOX_GROUP}" ]]; then
    pass "PostToolUse hands an agent-owned file back to ${PROJECTS_USER}:${SANDBOX_GROUP}"
else
    fail "PostToolUse did not hand back ${hk}: $(stat -c '%U:%G' "${hk}") (want ${PROJECTS_USER}:${SANDBOX_GROUP})"
fi

# (B) A secret-named agent file is routed to the projects user's PRIVATE group 600 (agent
#     access revoked).
hs="${proj}/.env"; : > "${hs}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${hs}"; chmod 0600 "${hs}"
run_hook "${hs}"
if [[ "$(stat -c '%U:%G' "${hs}")" == "${PROJECTS_USER}:${PROJECTS_GROUP}" ]]; then
    pass "PostToolUse routes a secret-named file to ${PROJECTS_USER}:${PROJECTS_GROUP} (agent revoked)"
else
    fail "secret-named file ended $(stat -c '%U:%G' "${hs}") (want ${PROJECTS_USER}:${PROJECTS_GROUP})"
fi

# (C) A directory the write newly created is normalized to <projects-user>:SANDBOX_GROUP 770
#     (world stripped, group rwx kept). Parent is the project root (projects-user-owned), so
#     exactly the new dir is normalized and the upward walk stops there.
hd="${proj}/made"; mkdir "${hd}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${hd}"; chmod 0755 "${hd}"
hdf="${hd}/file"; : > "${hdf}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${hdf}"; chmod 0600 "${hdf}"
run_hook "${hdf}"
if [[ "$(stat -c '%U:%G' "${hd}")" == "${PROJECTS_USER}:${SANDBOX_GROUP}" && "$(perm "${hd}")" == 770 ]]; then
    pass "PostToolUse normalizes a newly-created parent dir to ${PROJECTS_USER}:${SANDBOX_GROUP} 770"
else
    fail "PostToolUse did not normalize ${hd}: $(stat -c '%U:%G' "${hd}") $(perm "${hd}") (want ${PROJECTS_USER}:${SANDBOX_GROUP} 770)"
fi

# (D) Static pin: an allowlist pre-check in the hook (which the agent cannot satisfy) would
#     silently disable handback, so the hook keeps no ALLOWLIST reference in code (comments
#     naming it are stripped first).
if grep -vE '^[[:space:]]*#' "${hook}" | grep -q 'ALLOWLIST'; then
    fail "hook has a non-comment ALLOWLIST reference -- the silently-disabling pre-check may be back"
else
    pass "hook code has no ALLOWLIST pre-check (delegates enforcement to ai-tools-chown)"
fi

# ── Stop: turn-end sweep of Bash-created files ───────────────────────────────────
run_sweep() {  # $1 = cwd
    printf '{"cwd":"%s"}' "$1" \
        | timeout 30 setsid sudo -u "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" "${sweep}" \
            > /dev/null 2>&1 || true
}
section "Stop sweep: turn-end catch of Bash-created files"
rm -f /opt/ai-tools/.claude/.sweep-marker 2>/dev/null || true   # force a full scan
sw="${proj}/bash-made"; : > "${sw}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${sw}"; chmod 0644 "${sw}"
run_sweep "${proj}"
if [[ "$(stat -c '%U:%G' "${sw}")" == "${PROJECTS_USER}:${SANDBOX_GROUP}" ]]; then
    pass "Stop sweep hands back a Bash-created (agent-owned) file"
else
    fail "Stop sweep did not hand back ${sw}: $(stat -c '%U:%G' "${sw}") (want ${PROJECTS_USER}:${SANDBOX_GROUP})"
fi

# ── SessionStart: unbounded reclaim of interrupted-session leftovers ──────────────
section "SessionStart reclaim: unbounded recovery of leftovers"
run_sweep_ss() {  # $1 = cwd  $2 = source
    printf '{"cwd":"%s","source":"%s"}' "$1" "$2" \
        | timeout 30 setsid sudo -u "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" "${sweep}" session-start \
            > /dev/null 2>&1 || true
}

# (A) Unbounded: a marker NEWER than the leftover must NOT stop the reclaim. Stamp the marker
#     to now, then make the file older so a bounded (-newer) pass would skip it.
: > /opt/ai-tools/.claude/.sweep-marker 2>/dev/null || true
sleep 1
ssf="${proj}/leftover"; : > "${ssf}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${ssf}"; chmod 0644 "${ssf}"
touch -d '1 hour ago' "${ssf}"
run_sweep_ss "${proj}" startup
if [[ "$(stat -c '%U:%G' "${ssf}")" == "${PROJECTS_USER}:${SANDBOX_GROUP}" ]]; then
    pass "SessionStart (startup) reclaims a leftover older than the marker (unbounded)"
else
    fail "SessionStart did not reclaim ${ssf}: $(stat -c '%U:%G' "${ssf}") (want ${PROJECTS_USER}:${SANDBOX_GROUP})"
fi

# (B) Source gating: compact/clear stay within a live process, so the pass is a no-op.
ssf2="${proj}/live-write"; : > "${ssf2}"; chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${ssf2}"; chmod 0644 "${ssf2}"
run_sweep_ss "${proj}" compact
if [[ "$(stat -c '%U:%G' "${ssf2}")" == "${SANDBOX_USER}:${SANDBOX_GROUP}" ]]; then
    pass "SessionStart (compact) is a no-op (leaves live-session writes to the Stop sweep)"
else
    fail "SessionStart (compact) unexpectedly changed ${ssf2}: $(stat -c '%U:%G' "${ssf2}")"
fi

finish

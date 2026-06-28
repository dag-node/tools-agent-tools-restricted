#!/usr/bin/env bash
# /usr/local/bin/ai-tools-selftest  (test image only)
# Automated admin/operator/agent smoke test for the ai-tools RPMs, run once on boot by
# ai-tools-selftest.service after the system instance is up (the handback socket and the
# sandbox account's --user manager need a live systemd, so this cannot run at image-build
# time). It walks the documented Quick-start workflow end to end, reports per-phase results,
# then stops the container with the aggregate status via `systemctl exit`.
#
# What a container CAN validate here: package dependency resolution (the ai-tools
# metapackage pulling the three subpackages), the install scriptlets minus SELinux, the
# bootstrap toolchain, operator enrolment, project claim, the test suite's DAC/systemd
# parts, and a DAC-confined `claude --version` session.
# What it CANNOT: SELinux-enforcing confinement. `getenforce` is Disabled in a container,
# so %post skips `semodule` and the ai_tools_t domain transition is not exercised -- that
# still needs the enforcing host. Phases note this where relevant.
#
# Env (set by the Containerfile, override at `podman run -e`):
#   OPERATOR   the non-root login user enrolled as the operator (default: tester)
#   PROJECT    the project directory the operator claims and launches in
#   RUN_TESTS  "1" to run tests/run.sh all (default 1)
#   SRC_DIR    the source checkout that holds tests/ (default /opt/ai-tools-src)

set -uo pipefail

OPERATOR="${OPERATOR:-tester}"
PROJECT="${PROJECT:-/home/${OPERATOR}/proj}"
RUN_TESTS="${RUN_TESTS:-1}"
SRC_DIR="${SRC_DIR:-/opt/ai-tools-src}"

# ── reporting ────────────────────────────────────────────────────────────────
declare -a RESULTS=()
rc_total=0

banner() { printf '\n\033[1;36m══════════════════════════════════════════════════════════════\n# %s\n══════════════════════════════════════════════════════════════\033[0m\n' "$*"; }
note()   { printf '\033[1;33m• %s\033[0m\n' "$*"; }

# phase <label> <command...> : run verbosely, record PASS/FAIL, never abort the run.
phase() {
    local label="$1"; shift
    banner "${label}"
    printf '\033[2m$ %s\033[0m\n' "$*"
    if "$@"; then
        RESULTS+=("PASS        ${label}")
        printf '\033[1;32m→ PASS: %s\033[0m\n' "${label}"
    else
        local st=$?
        RESULTS+=("FAIL(${st})  ${label}")
        printf '\033[1;31m→ FAIL(%s): %s\033[0m\n' "${st}" "${label}"
        rc_total=1
    fi
}

# as_operator <cmd...> : run a command in a fresh login shell of the operator, so it picks
# up the ai-ops group membership `operator add` just granted (a stale shell would not).
as_operator() { runuser -l "${OPERATOR}" -c "$*"; }

# ── environment dump ─────────────────────────────────────────────────────────
banner "Environment"
set -x
grep -E '^(NAME|VERSION)=' /etc/os-release || true
rpm -q ai-tools ai-tools-base ai-tools-nodejs claude-code-restricted || true
getenforce || echo "getenforce: unavailable (no SELinux in container -> DAC-only test)"
id "${OPERATOR}"
systemctl is-system-running || true
set +x

# ── installed-artifact + dependency checks ───────────────────────────────────
# The metapackage's job is to pull the three subpackages; prove all four are present.
phase "Metapackage pulled the three subpackages" \
    bash -c 'rpm -q ai-tools-base ai-tools-nodejs claude-code-restricted >/dev/null'

phase "Handback socket is active (system instance up)" \
    systemctl is-active --quiet ai-tools-handback.socket

phase "Core helpers + wrapper installed on PATH" \
    bash -c 'command -v claude && command -v ai-tools && command -v ai-tools-admin && command -v ai-tools-bootstrap'

phase "safedir + reclaim helpers present (the late spec additions)" \
    bash -c 'test -x /usr/local/sbin/ai-tools/ai-tools-safedir && test -x /usr/local/sbin/ai-tools/ai-tools-reclaim'

# ── toolchain provisioning (network) ─────────────────────────────────────────
# Run at runtime, not build: under a live systemd, bootstrap enables the sandbox account's
# linger and the nvm-update.timer in its own --user instance. Idempotent (reuses an existing
# nvm/Node), so a re-run is cheap.
phase "ai-tools-bootstrap (nvm + Node + claude; linger + timer)" \
    ai-tools-bootstrap

phase "claude launcher symlink resolves to the nvm-installed binary" \
    bash -c 'test -L /opt/ai-tools/bin/claude && readlink -f /opt/ai-tools/bin/claude | grep -q "/versions/node/"'

# The timer enablement is the root-provisioned wants symlink under the sandbox home (the
# only place a confined session may not write); checking it on disk is robust without
# entering the user manager. tests/run.sh's systemd.sh is the authoritative coverage.
phase "nvm-update.timer enabled in the ai-tools --user instance" \
    test -L /opt/ai-tools/.config/systemd/user/timers.target.wants/nvm-update.timer

# ── operator enrolment ───────────────────────────────────────────────────────
phase "ai-tools-admin operator add ${OPERATOR}" \
    ai-tools-admin operator add "${OPERATOR}"

phase "${OPERATOR} is in ai-ops + listed in operator.conf" \
    bash -c "id -nG '${OPERATOR}' | tr ' ' '\n' | grep -qx ai-ops && grep -q '${OPERATOR}' /etc/ai-tools/operator.conf"

# ── project claim ────────────────────────────────────────────────────────────
mkdir -p "${PROJECT}"; chown "${OPERATOR}:${OPERATOR}" "${PROJECT}"
as_operator "cd '${PROJECT}' && git init -q" || true
# The project sits inside the operator's home (mode 700), which the sandbox account cannot
# traverse, so claude-run -- re-checking the project dir AS the agent -- would see it as missing.
# Grant the sandbox account traverse-only (no read) on the home, mirroring the operator-set
# `user:ai-tools:--x` ACL a real host carries for in-place claims under a private home.
setfacl -m "u:ai-tools:--x" "/home/${OPERATOR}"

# Drive the claim non-interactively: AI_TOOLS_ASSUME_YES=1 is the CLI's own assume-yes hook for its
# default-yes prompts (claim confirm, .git normalization), so it proceeds without a controlling tty.
phase "operator claims the project (allowlist + ACL + safedir + label)" \
    as_operator "AI_TOOLS_ASSUME_YES=1 ai-tools --project-claim '${PROJECT}'"

phase "project is in the operator's allowlist" \
    bash -c "grep -q '${PROJECT}' /home/${OPERATOR}/.config/ai-tools/allowed-projects"

# OCI image layers do not carry POSIX ACLs, so the sandbox-area ai-ops ACL the base %post applies
# at image-build time is dropped from the committed layer (a container limitation, like SELinux).
# On a real host %post applies it at install and it persists; re-assert it at runtime so perms.sh's
# ACL check exercises the same state a real install has.
banner "Re-assert sandbox-area ai-ops ACL (OCI layers drop build-time ACLs)"
setfacl -m  g:ai-ops:r-x /var/opt/ai-tools \
    && setfacl -m  g:ai-ops:rwx /var/opt/ai-tools/sandbox-projects \
    && setfacl -d -m g:ai-ops:rwX /var/opt/ai-tools/sandbox-projects \
    && setfacl -m  g:ai-ops:r-- /var/opt/ai-tools/README.md \
    && note "sandbox ACL re-applied" || note "sandbox ACL re-apply failed (continuing)"

# ── the project test suite (DAC + systemd parts; SELinux parts no-op/skip) ────
if [[ "${RUN_TESTS}" == "1" && -f "${SRC_DIR}/tests/run.sh" ]]; then
    # run.sh insists on sudo (EUID 0 + SUDO_USER). Go through the operator's NOPASSWD sudo,
    # which sets SUDO_USER=<operator> itself, exercising the real invocation path.
    phase "tests/run.sh all" \
        as_operator "sudo bash '${SRC_DIR}/tests/run.sh' all"
else
    note "tests/run.sh skipped (RUN_TESTS=${RUN_TESTS} or sources absent)"
fi

# ── confined session smoke test (auth-free) ──────────────────────────────────
# `claude --version` flows wrapper -> ai-ops gate -> allowlist -> sudo -> claude-run ->
# `systemd-run --user --pty -- claude.exe --version`, so it exercises the whole confined
# launch without an API key. `script` provides a controlling tty for the wrapper's
# /dev/tty probe and claude-run's --pty; `timeout` guards a hung update check.
phase "confined session launches (claude --version through the wrapper)" \
    as_operator "cd '${PROJECT}' && script -qec 'timeout 90 claude --version' /dev/null"

# ── agent-side boundary spot check (the confinement that holds under DAC) ─────
# Prove the sandbox account cannot sudo and is not in ai-ops -- the DAC half of the model.
phase "sandbox account has no sudo and is not an operator" \
    bash -c '! id -nG ai-tools | tr " " "\n" | grep -qx ai-ops && ! runuser -l ai-tools -s /bin/bash -c "sudo -n true" 2>/dev/null'

# ── summary + exit ───────────────────────────────────────────────────────────
banner "SELFTEST SUMMARY"
printf '%s\n' "${RESULTS[@]}"
if [[ "${rc_total}" -eq 0 ]]; then
    printf '\n\033[1;32m##### ai-tools container selftest: ALL PHASES PASSED #####\033[0m\n'
else
    printf '\n\033[1;31m##### ai-tools container selftest: FAILURES ABOVE #####\033[0m\n'
fi

# Stop the systemd payload and surface the aggregate status as the container exit code,
# so `podman run` returns non-zero on failure (CI-friendly).
note "stopping container with exit code ${rc_total}"
systemctl exit "${rc_total}" 2>/dev/null || { systemctl halt --no-block; exit "${rc_total}"; }

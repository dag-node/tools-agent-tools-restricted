#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/helper-path.sh
# Hermetic check that every load-bearing reference to the root helper directory agrees on ONE
# path, and that the pre-0.10.0 location (/usr/local/sbin/ai-tools) survives nowhere.
#
# The gap this closes: the helper tree's absolute path is a security anchor repeated across
# security-critical surfaces that are NOT built from a shared constant -- the sudoers root rule,
# the SELinux file-context, the systemd ExecStart, and the CLI/wrapper helper lookups. A partial
# rename that updates some but not all fails closed at runtime (a stranded literal resolves to
# helper-not-found -> refusal, never a bypass), but it still breaks the host. So the agreement is
# asserted here, statically, before it ships.
#
# The canonical path is single-sourced from the spec's %global ai_libexecdir; every other anchor
# must match it. Pure text over the repo sources; skips outside a checkout.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "helper directory path is single and consistent (unit)"

if [[ ! -d "${ROOT}/src" ]]; then
    skip "helper path consistency" "not a source checkout (no ${ROOT}/src)"
    finish; exit
fi

OLD_PATH="/usr/local/sbin/ai-tools"

# Canonical helper dir from the spec %global (the build-time single source).
helperdir="$(sed -n 's/^%global ai_libexecdir[[:space:]]\+//p' "${ROOT}/packaging/ai-tools.spec" | head -1)"
if [[ -z "${helperdir}" ]]; then
    fail "could not read %global ai_libexecdir from packaging/ai-tools.spec"
    finish; exit 1
fi
pass "canonical helper dir from spec: ${helperdir}"

# Each load-bearing anchor must name exactly <helperdir>/ai-tools-relabel-agent (or the dir), and
# the root sudoers rule exactly <helperdir>/ai-tools-stop.
want_agent="${helperdir}/ai-tools-relabel-agent"
want_stop="${helperdir}/ai-tools-stop"

check_contains() {
    local label="$1" file="$2" needle="$3"
    if [[ ! -r "${ROOT}/${file}" ]]; then
        fail "${label}: ${file} not readable"; return
    fi
    if grep -qF -- "${needle}" "${ROOT}/${file}"; then
        pass "${label} references ${needle}"
    else
        fail "${label}: ${file} does not reference ${needle}"
    fi
}

# The sudoers root rule (fixed, non-glob target) must name the canonical stop path, and the
# systemd watcher the canonical relabel-agent path; the SELinux fcontext must scope the canonical
# dir. Both properties of the stop rule are load-bearing: a stranded path leaves the incident
# ladder's stop rung needing a password no unattended detector can answer, and a lost trailing ""
# would widen a NOPASSWD root rule from the bare command to any argument it takes.
check_contains "sudoers stop rule" \
    "src/etc/sudoers.d/ai-tools" "${want_stop} \"\""
check_contains "systemd relabel.service ExecStart" \
    "src/usr/lib/systemd/system/ai-tools-relabel.service" "ExecStart=${want_agent}"
check_contains "SELinux fcontext helper-tree rule" \
    "selinux/policy/ai_tools.fc" "${helperdir}(/.*)?"
check_contains "SELinux fcontext handback entrypoint" \
    "selinux/policy/ai_tools.fc" "${helperdir}/ai-tools-handback"

# No stale pre-0.10.0 path anywhere in the shipped tree, packaging, or policy -- except the
# migration/cleanup code that intentionally names the OLD location to remove it. Build-artifact
# trees are skipped: rpmbuild unpacks the tarball under packaging/rpmbuild (a nested copy of the
# spec and install.sh), and the refpolicy Makefile leaves intermediates under selinux/policy/tmp;
# neither is a source the lint should read, and a deployed source tree (the container's
# /opt/ai-tools-src) carries them beside the real sources.
allow_old='^(install\.sh|packaging/ai-tools\.spec|tests/unit/helper-path\.sh):'
mapfile -t stale < <(
    grep -rn --exclude-dir=.git --exclude-dir=rpmbuild --exclude-dir=tmp -- "${OLD_PATH}" \
        "${ROOT}/src" "${ROOT}/selinux" "${ROOT}/packaging" "${ROOT}/install.sh" 2>/dev/null \
        | sed "s#${ROOT}/##" | grep -vE "${allow_old}" || true
)
if (( ${#stale[@]} == 0 )); then
    pass "no stale ${OLD_PATH} reference outside migration code"
else
    for line in "${stale[@]}"; do
        fail "stale old helper path: ${line}"
    done
fi

finish

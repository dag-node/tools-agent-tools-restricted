#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/admin-commands.sh
# Hermetic unit test for the contributed-command seam: the domains a provider package adds to
# ai-tools-admin, discovered under admin-commands.d rather than enumerated in the dispatch.
#
# What is driven here is a dispatch that execs a file AS ROOT, so every assertion is about a way
# that discovery could go wrong in the widening direction. A fragment is honored only while it and
# its directory are root-owned and writable by neither group nor other, and a fragment claiming a
# name base owns is refused rather than merged -- so this file drives each of those states and
# asserts the command surface comes out SMALLER and the refusal is reported. The positive cases are
# the other half of the same contract: a trusted fragment is exec'd with the remaining arguments,
# and it is listed in --help with the summary its manifest declares, since a help that named
# something the dispatch would not run (or the reverse) is the failure the one discovery function
# exists to prevent.
#
# Drives the DEPLOYED helper against fixtures in the testdir through AI_TOOLS_ADMIN_COMMANDS_DIR
# and AI_TOOLS_INTEGRATIONS_DIR, both root-only path hooks (like AI_TOOLS_POSTUPGRADE_ROOT): the
# host's own admin-commands.d is never read, and every file written is inside the testdir. Run as
# root -- the fixtures must be root-owned to be trusted at all, which is the point.
#
# The boundary half of this pair is in tests/boundary/providers.sh: the agent cannot write the
# deployed directory or any fragment in it, so it cannot reach the states driven here.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-admin"

section "ai-tools-admin: contributed command domains (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "contributed commands" "not installed at ${HELPER}"; finish; exit
fi

mktestdir
CMD_DIR="${TESTDIR}/admin-commands.d"
MANIFEST_DIR="${TESTDIR}/integrations.d"
MARKER="${TESTDIR}/ran"

# Each case starts from an empty pair of fixture directories, so no case inherits another's.
reset_fixtures() {
    rm -rf "${CMD_DIR}" "${MANIFEST_DIR}" "${MARKER}"
    install -d -o root -g root -m 755 "${CMD_DIR}" "${MANIFEST_DIR}"
}

# write_fragment <name> [mode] : a fragment that records the arguments it was exec'd with, so a
# test can tell "dispatched" from "listed" and can read back what reached it.
write_fragment() {
    local name="$1" mode="${2:-750}"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\necho "fragment %s ran"\n' \
        "${MARKER}" "${name}" > "${CMD_DIR}/${name}"
    chown root:root "${CMD_DIR}/${name}"
    chmod "${mode}" "${CMD_DIR}/${name}"
}

# write_manifest <name> <summary> : the provider manifest carrying the domain's --help line.
write_manifest() {
    printf 'default_enable=no\nadmin_summary=%s\n' "$2" > "${MANIFEST_DIR}/$1.conf"
    chown root:root "${MANIFEST_DIR}/$1.conf"
    chmod 644 "${MANIFEST_DIR}/$1.conf"
}

# run_admin <args...> : the deployed helper against the fixture directories. Publishes `out` and
# `STATUS` as globals rather than printing, so both survive -- a $(...) capture would run the whole
# call in a subshell and leave the exit status behind in it. stdout and stderr are merged
# deliberately: a refusal belongs in what the administrator sees, and every assertion below reads
# the run as one transcript.
STATUS=0
out=""
run_admin() {
    STATUS=0
    env AI_TOOLS_ADMIN_COMMANDS_DIR="${CMD_DIR}" \
        AI_TOOLS_INTEGRATIONS_DIR="${MANIFEST_DIR}" \
        "${HELPER}" "$@" < /dev/null > "${TESTDIR}/out" 2>&1 || STATUS=$?
    out="$(cat "${TESTDIR}/out")"
}

# ── a trusted fragment dispatches, and carries its arguments ────────────────────────────────
reset_fixtures
write_fragment demo
write_manifest demo "the demo provider"
run_admin demo tools install pkg-a pkg-b

if [[ "${out}" == *"fragment demo ran"* ]]; then
    pass "a trusted fragment is exec'd for its own domain"
else
    fail "a trusted fragment did not run: ${out}"
fi
if [[ -f "${MARKER}" && "$(cat "${MARKER}")" == "tools install pkg-a pkg-b" ]]; then
    pass "the domain's own arguments reach the fragment unchanged"
else
    fail "arguments did not reach the fragment: $(cat "${MARKER}" 2>/dev/null)"
fi

# ── --help lists the domain and the summary its manifest declares ───────────────────────────
run_admin --help
if [[ "${out}" == *"demo <command>"* && "${out}" == *"the demo provider"* ]]; then
    pass "--help lists the installed domain with its manifest summary"
else
    fail "--help did not list the domain and its summary: ${out}"
fi

# A domain whose manifest omits the summary is still listed: the fragment's presence is what
# creates the command, and a missing description must not hide one that dispatches.
reset_fixtures
write_fragment nosummary
run_admin --help
if [[ "${out}" == *"nosummary <command>"* ]]; then
    pass "a domain with no admin_summary is still listed"
else
    fail "a domain with no manifest summary went unlisted: ${out}"
fi

# ── an untrusted fragment is skipped and reported ───────────────────────────────────────────
# Group-writable is the state that matters: the file is still root-owned, so only the mode
# separates it from the case above, and it must be enough on its own.
reset_fixtures
write_fragment tampered 770
run_admin tampered
if [[ ! -f "${MARKER}" ]]; then
    pass "a group-writable fragment is not exec'd"
else
    fail "a group-writable fragment ran"
fi
if [[ "${out}" == *"not root-owned or is writable by group/other"* ]]; then
    pass "the untrusted fragment is reported, not silently dropped"
else
    fail "no report for the untrusted fragment: ${out}"
fi
if [[ "${STATUS}" -eq 2 ]]; then
    pass "an untrusted domain is an unknown command (exit 2)"
else
    fail "expected exit 2 for the untrusted domain, got ${STATUS}"
fi

# A fragment owned by anyone but root is refused on ownership alone, with a safe mode.
reset_fixtures
write_fragment notroot 750
chown "${PROJECTS_USER}" "${CMD_DIR}/notroot"
run_admin notroot
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 2 ]]; then
    pass "a fragment owned by the operator is refused"
else
    fail "a non-root-owned fragment was dispatched (exit ${STATUS})"
fi

# ── an untrusted DIRECTORY refuses every contributed command ────────────────────────────────
# A group-writable directory lets a non-root writer unlink a root-owned fragment and put its own
# in that name, so the whole set goes -- not just the file that was replaced.
reset_fixtures
write_fragment demo
chmod 775 "${CMD_DIR}"
run_admin demo
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 2 ]]; then
    pass "a group-writable directory refuses every contributed command"
else
    fail "a fragment in a group-writable directory was dispatched (exit ${STATUS})"
fi
if [[ "${out}" == *"ignoring every contributed command"* ]]; then
    pass "the untrusted directory is reported"
else
    fail "no report for the untrusted directory: ${out}"
fi
chmod 755 "${CMD_DIR}"

# ── a fragment claiming a base name is refused, and the base command still runs ─────────────
# The name base owns must keep meaning what this page documents, whoever installs what.
reset_fixtures
write_fragment system
run_admin system
if [[ ! -f "${MARKER}" ]]; then
    pass "a fragment named for a base command is not exec'd"
else
    fail "a fragment claiming 'system' shadowed the base command"
fi
if [[ "${out}" == *"system takes a resource or a verb"* ]]; then
    pass "'system' still reaches base's own dispatch"
else
    fail "'system' did not reach base's dispatch: ${out}"
fi
run_admin --help
if [[ "${out}" == *"is a command ai-tools-admin owns"* ]]; then
    pass "the reserved-name refusal is reported"
else
    fail "no report for the fragment claiming a base name: ${out}"
fi

# `status` is reserved before it is implemented, so a provider cannot take the name first.
reset_fixtures
write_fragment status
run_admin status
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 2 ]]; then
    pass "a fragment claiming the reserved 'status' name is refused"
else
    fail "a fragment claimed 'status' (exit ${STATUS})"
fi

# ── a name that is not a bare lower-case word never becomes a path ──────────────────────────
reset_fixtures
write_fragment demo
printf '#!/bin/sh\ntouch "%s"\n' "${MARKER}" > "${CMD_DIR}/Bad.Name"
chown root:root "${CMD_DIR}/Bad.Name"; chmod 750 "${CMD_DIR}/Bad.Name"
run_admin --help
if [[ "${out}" != *"Bad.Name <command>"* ]]; then
    pass "a fragment whose name is not a bare lower-case word is not a domain"
else
    fail "an out-of-charset fragment name was listed as a domain: ${out}"
fi

# The dispatch matches a discovered domain, so a caller-supplied path never reaches the exec.
run_admin ../../../bin/sh
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 2 ]]; then
    pass "a path-shaped command name is an unknown command, never a path"
else
    fail "a path-shaped command name was dispatched (exit ${STATUS})"
fi

# ── a trusted fragment that is not executable is listed, and says so when run ────────────────
# The two are separate questions: the listing is what --help can see as any caller, and the exec
# bit is what the dispatch needs. A fragment that cannot run is a broken install, not an unknown
# command, so it exits 1 naming the package rather than 2 naming the surface.
reset_fixtures
write_fragment inert 640
run_admin --help
if [[ "${out}" == *"inert <command>"* ]]; then
    pass "a non-executable fragment is still listed as a domain"
else
    fail "a non-executable fragment went unlisted: ${out}"
fi
run_admin inert
if [[ "${STATUS}" -eq 1 && "${out}" == *"not executable"* ]]; then
    pass "dispatching a non-executable fragment fails naming the package"
else
    fail "expected a not-executable failure (exit 1), got ${STATUS}: ${out}"
fi

# ── an absent directory is simply a host with no contributed commands ────────────────────────
reset_fixtures
rm -rf "${CMD_DIR}"
run_admin --help
if [[ "${STATUS}" -eq 0 && "${out}" == *"system post-upgrade"* && "${out}" != *"Providers"* ]]; then
    pass "a host with no admin-commands.d prints the base surface and no refusal"
else
    fail "an absent directory was not silent (exit ${STATUS}): ${out}"
fi

finish

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/admin-commands.sh
# Hermetic unit test for the contributed-command seam: the domains a provider package adds to
# ai-tools-admin, discovered under admin-commands.d rather than enumerated in the dispatch.
#
# What is driven here is a dispatch that execs a file AS ROOT, so every assertion is about a way
# that discovery could go wrong in the widening direction. A fragment is honored only while it and
# its directory are root-owned and writable by neither group nor other; a fragment claiming a name
# base owns is refused rather than merged; one entry that is not root's alone refuses the whole
# set; and a file that does not declare itself a command of this seam is not run as one. This file
# drives each of those states and asserts the command surface comes out SMALLER and the refusal is
# reported. The positive cases are the other half of the same contract: a trusted, declared
# fragment is exec'd with the remaining arguments, and it is listed in --help with the summary its
# manifest declares, since a help that named something the dispatch would not run (or the reverse)
# is the failure the one discovery function exists to prevent.
#
# Drives the DEPLOYED helper against fixtures through AI_TOOLS_ADMIN_COMMANDS_DIR and
# AI_TOOLS_INTEGRATIONS_DIR, both root-only path hooks (like AI_TOOLS_POSTUPGRADE_ROOT): the host's
# own admin-commands.d is never read, and every file written is inside a directory this run
# created. Run as root -- the fixtures must be root-owned to be trusted at all, which is the point.
#
# The fixtures must also be EXECUTABLE, which is why they are not unconditionally in the harness's
# /tmp testdir: /tmp is mounted noexec on a hardened host, where a fragment created there passes
# every ownership check and then cannot be exec'd -- failing the positive cases for a property of
# the mount rather than of the code. The testdir is used when it can execute and a directory beside
# the operator's home otherwise, the same reason integration/hooks.sh keeps its fixtures out of
# /tmp; either way the tree is removed on exit.
#
# The boundary half of this pair is in tests/boundary/providers.sh: the agent cannot write the
# deployed directory or any fragment in it, so it cannot reach the states driven here.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-admin"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

section "ai-tools-admin: contributed command domains (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "contributed commands" "not installed at ${HELPER}"; finish; exit
fi

# exec_capable <dir>: succeed when a file created in <dir> can actually be run from it. Probes
# rather than reading mount options, so it answers for whatever combination of noexec, SELinux
# label and filesystem applies here.
exec_capable() {
    local probe="$1/.exec-probe.$$" ok=1
    printf '#!/bin/sh\nexit 0\n' > "${probe}" 2>/dev/null || return 1
    chmod 0700 "${probe}"
    "${probe}" >/dev/null 2>&1 && ok=0
    rm -f "${probe}"
    return "${ok}"
}

mktestdir
FIXTURE_ROOT="${TESTDIR}"
if ! exec_capable "${TESTDIR}"; then
    FIXTURE_ROOT="$(mktemp -d "${PROJECTS_HOME}/.ai-tools-admin-test.XXXXXX")"
    chmod 0755 "${FIXTURE_ROOT}"
    on_teardown rm -rf "${FIXTURE_ROOT}"
fi
CMD_DIR="${FIXTURE_ROOT}/admin-commands.d"
MANIFEST_DIR="${FIXTURE_ROOT}/integrations.d"
MARKER="${FIXTURE_ROOT}/ran"

if ! exec_capable "${FIXTURE_ROOT}"; then
    skip "contributed commands" "no exec-capable directory for the fixtures (${FIXTURE_ROOT})"
    finish; exit
fi

# Each case starts from an empty pair of fixture directories, so no case inherits another's.
reset_fixtures() {
    rm -rf "${CMD_DIR}" "${MANIFEST_DIR}" "${MARKER}"
    install -d -o root -g root -m 755 "${CMD_DIR}" "${MANIFEST_DIR}"
}

# write_fragment <name> [mode] [declared-name] : a fragment that records the arguments it was
# exec'd with, so a test can tell "dispatched" from "listed" and read back what reached it. It
# carries a complete, conforming interface declaration -- the state a correctly packaged command is
# in; a case that drives one malformed field rewrites that line afterwards with sed, so what it
# asserts is the one field it changed.
write_fragment() {
    local name="$1" mode="${2:-750}" declared="${3:-$1}"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        "# ai-tools-admin-command: ${declared}" \
        '# ai-tools-admin-api-min-version: 1.0' \
        '# ai-tools-admin-verbs: bootstrap status' \
        "printf '%s\\n' \"\$*\" > ${MARKER}" \
        "echo \"fragment ${name} ran\"" > "${CMD_DIR}/${name}"
    chown root:root "${CMD_DIR}/${name}"
    chmod "${mode}" "${CMD_DIR}/${name}"
}

# declare_line <name> <key> <value> : rewrite one declaration of an already-written fragment.
declare_line() {
    sed -i "s|^# ai-tools-admin-$2:.*|# ai-tools-admin-$2: $3|" "${CMD_DIR}/$1"
}

# drop_line <name> <key> : remove one declaration entirely.
drop_line() {
    sed -i "/^# ai-tools-admin-$2:/d" "${CMD_DIR}/$1"
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
        "${HELPER}" "$@" < /dev/null > "${FIXTURE_ROOT}/out" 2>&1 || STATUS=$?
    out="$(cat "${FIXTURE_ROOT}/out")"
}

# ── a trusted fragment dispatches, and carries its arguments ────────────────────────────────
reset_fixtures
write_fragment demo
write_manifest demo "the demo provider"
run_admin demo tools install pkg-a pkg-b

if [[ "${out}" == *"fragment demo ran"* ]]; then
    pass "a trusted, declared fragment is exec'd for its own domain"
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
    fail "a domain whose manifest omits the summary went unlisted: ${out}"
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
if [[ "${out}" == *"is a symlink, is not root-owned, or is writable by group/other"* ]]; then
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

# ── one untrusted fragment refuses the whole set ────────────────────────────────────────────
# The set-wide gate, and the assertion that carries it: a fragment nobody tampered with, in a
# directory that also holds one that is not root's alone, does NOT run. Per-file skipping alone
# would run this one and leave the other in place, with no finding obliging the administrator to act.
reset_fixtures
write_fragment good
write_fragment weak 766
run_admin good
if [[ ! -f "${MARKER}" ]]; then
    pass "a sound fragment is refused while a neighbour is not root's alone"
else
    fail "a sound fragment ran beside a group/other-writable one"
fi
if [[ "${STATUS}" -eq 1 && "${out}" == *"refusing every contributed command"* ]]; then
    pass "the set-wide refusal fails the command (exit 1) and says so"
else
    fail "expected the set-wide refusal (exit 1), got ${STATUS}: ${out}"
fi
if [[ "${out}" == *"reinstall the package owning it"* ]]; then
    pass "the refusal names the remedy: reinstall the owning package"
else
    fail "the set-wide refusal gave no remedy: ${out}"
fi
# The help stays one answer with the dispatch rather than offering a command that refuses.
run_admin --help
if [[ "${out}" == *"refused:"* ]]; then
    pass "--help says the contributed commands are refused"
else
    fail "--help listed domains it would refuse to run: ${out}"
fi

# A file whose NAME is not a domain is a different finding: it is not a command, and the set
# around it still runs.
reset_fixtures
write_fragment demo
printf 'notes\n' > "${CMD_DIR}/README.md"
chown root:root "${CMD_DIR}/README.md"; chmod 644 "${CMD_DIR}/README.md"
run_admin demo
if [[ -f "${MARKER}" ]]; then
    pass "a non-command file beside a fragment does not refuse the set"
else
    fail "a README refused the whole set: ${out}"
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

# ── a fragment must declare itself a command of this seam ───────────────────────────────────
# The declaration is what makes a fragment self-identifying, so a root-owned executable that
# merely ends up in this directory is not run as a command.
reset_fixtures
printf '#!/usr/bin/env bash\ntouch "%s"\n' "${MARKER}" > "${CMD_DIR}/undeclared"
chown root:root "${CMD_DIR}/undeclared"; chmod 750 "${CMD_DIR}/undeclared"
run_admin undeclared
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 1 && "${out}" == *"does not declare"* ]]; then
    pass "an undeclared executable in the directory is not run as a command"
else
    fail "an undeclared executable was dispatched (exit ${STATUS}): ${out}"
fi

# One provider's command copied under another provider's name declares the name it was written
# for, not the one it is installed as, so it is refused.
reset_fixtures
write_fragment impostor 750 demo
run_admin impostor
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 1 && "${out}" == *"does not declare"* ]]; then
    pass "a fragment declaring another domain's name is refused"
else
    fail "a fragment installed under a name it does not declare ran (exit ${STATUS}): ${out}"
fi

# A non-script -- the declaration cannot be read from one, and the seam runs interpreted files.
reset_fixtures
printf 'not a script\n' > "${CMD_DIR}/binary"
chown root:root "${CMD_DIR}/binary"; chmod 750 "${CMD_DIR}/binary"
run_admin binary
if [[ "${STATUS}" -eq 1 && "${out}" == *"not a script"* ]]; then
    pass "a file with no shebang is not run as a command"
else
    fail "a file with no shebang was dispatched (exit ${STATUS}): ${out}"
fi

# ── the interface floor a fragment declares ─────────────────────────────────────────────────
# The declared version is what the fragment NEEDS, so the direction of every case here is what
# makes an old third-party command keep working: a floor at or below what this tool implements
# runs, and only a floor above it is refused.
reset_fixtures
write_fragment old
declare_line old api-min-version "1.0"
run_admin old
if [[ -f "${MARKER}" ]]; then
    pass "a fragment declaring the oldest floor runs on this interface"
else
    fail "a 1.0 fragment did not run: ${out}"
fi

reset_fixtures
write_fragment ahead
declare_line ahead api-min-version "1.7"
run_admin ahead
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 1 && "${out}" == *"upgrade ai-tools-base"* ]]; then
    pass "a fragment needing a newer minor is refused, naming the side to upgrade"
else
    fail "a fragment needing a newer interface ran (exit ${STATUS}): ${out}"
fi

reset_fixtures
write_fragment othermajor
declare_line othermajor api-min-version "2.0"
run_admin othermajor
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 1 && "${out}" == *"different major is a different contract"* ]]; then
    pass "a fragment needing another major is refused as an incompatible contract"
else
    fail "a fragment declaring another major ran (exit ${STATUS}): ${out}"
fi

reset_fixtures
write_fragment shapeless
declare_line shapeless api-min-version "one"
run_admin shapeless
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 1 && "${out}" == *"not <major>.<minor>"* ]]; then
    pass "an interface floor that is not <major>.<minor> is refused"
else
    fail "a malformed interface floor ran (exit ${STATUS}): ${out}"
fi

reset_fixtures
write_fragment nofloor
drop_line nofloor api-min-version
run_admin nofloor
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 1 && "${out}" == *"declares no"*"api-min-version"* ]]; then
    pass "a fragment declaring no interface floor is refused"
else
    fail "a fragment with no interface floor ran (exit ${STATUS}): ${out}"
fi

# ── the declared verb list ──────────────────────────────────────────────────────────────────
reset_fixtures
write_fragment noverbs
drop_line noverbs verbs
run_admin noverbs
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 1 && "${out}" == *"declares no"*"verbs"* ]]; then
    pass "a fragment declaring no verbs is refused"
else
    fail "a fragment with no declared verbs ran (exit ${STATUS}): ${out}"
fi

reset_fixtures
write_fragment shoutyverb
declare_line shoutyverb verbs "Bootstrap"
run_admin shoutyverb
if [[ ! -f "${MARKER}" && "${STATUS}" -eq 1 && "${out}" == *"a verb is a bare lower-case word"* ]]; then
    pass "a declared verb outside the command charset is refused"
else
    fail "a malformed verb list ran (exit ${STATUS}): ${out}"
fi

# ── a fragment claiming a base name is refused, and the base command still runs ─────────────
# The name base owns must keep meaning what ai-tools-admin(8) documents, whoever installs what.
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

# `status` was reserved before it was implemented, and now that base answers it the reservation is
# what makes the shadowing attempt land on BASE's command rather than the fragment's. The exit
# status is not asserted: the real report exits non-zero on a host with something broken, and this
# is a check about which code ran, not about this host's health.
reset_fixtures
write_fragment status
run_admin status
if [[ ! -f "${MARKER}" && "${out}" == *"ai-tools host status"* ]]; then
    pass "a fragment claiming 'status' is refused and base's own command answers instead"
else
    fail "a fragment reached the dispatch for 'status' (exit ${STATUS}): ${out}"
fi

# The base command takes no argument, and says so rather than ignoring one: a report that quietly
# dropped what it was asked about would read as an answer to the question.
run_admin status --everything
if [[ "${STATUS}" -eq 2 && "${out}" == *"takes no arguments"* ]]; then
    pass "status refuses an argument with exit 2 rather than reporting on the whole host"
else
    fail "status accepted an argument (exit ${STATUS}): ${out}"
fi

# Every name the top-level dispatch answers must be reserved, or a provider could contribute a
# domain that --help lists and the dispatch silently shadows.
arms="$(awk '/^case "\$1" in/{f=1} f' "${HELPER}" | grep -oE '^    [a-z][a-z0-9-]*\)' | tr -d ' )')"
reserved="$(grep -oE '^readonly -a BASE_COMMANDS=\(.*\)' "${HELPER}" | sed -e 's/.*(//' -e 's/).*//')"
unreserved=()
for arm in ${arms}; do
    grep -qw -- "${arm}" <<<"${reserved}" || unreserved+=("${arm}")
done
if [[ -z "${arms}" || -z "${reserved}" ]]; then
    fail "could not extract the dispatch arms or the reserved names"
elif [[ "${#unreserved[@]}" -eq 0 ]]; then
    pass "every top-level dispatch arm is a reserved base name"
else
    fail "dispatch arm(s) a provider could claim: ${unreserved[*]}"
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

# ── system bootstrap: only the scopes it defines ────────────────────────────────────────────
# Every case here is REJECTED before the provisioning helper is reached, which is what makes them
# drivable: a scope this parser mis-read would otherwise provision the host mid-test. The default
# and --scope full are not driven for that reason -- they install software over the network.
reset_fixtures
run_admin system bootstrap --scope full-ish
if [[ "${STATUS}" -eq 2 && "${out}" == *"unknown scope"* ]]; then
    pass "an unknown --scope value is rejected before anything is provisioned"
else
    fail "expected exit 2 for an unknown scope, got ${STATUS}: ${out}"
fi
run_admin system bootstrap --scope
if [[ "${STATUS}" -eq 2 && "${out}" == *"--scope takes a value"* ]]; then
    pass "--scope with no value is rejected"
else
    fail "expected exit 2 for a valueless --scope, got ${STATUS}: ${out}"
fi
run_admin system bootstrap full
if [[ "${STATUS}" -eq 2 && "${out}" == *"unknown argument"* ]]; then
    pass "a bare positional scope is rejected, so the switch spelling is the only one"
else
    fail "expected exit 2 for a positional scope, got ${STATUS}: ${out}"
fi

# ── system bootstrap --scope full: the loop that runs contributed commands unattended ───────
# Driven by SOURCING the helper and calling the loop with the enabled-integration resolver stubbed
# -- the shape tests/unit/admin-operator-add.sh uses, and possible because the helper's root check
# and dispatch are both guarded for it. Reaching this loop through the command would first run the
# real provisioning helper, which installs software over the network.
#
# The contract asserted is that every enabled integration is ATTEMPTED and each outcome named
# before the run fails: an administrator provisioning a host wants every result, not the first
# thing that went wrong. `failing` is listed first, so a loop that stopped at it would leave the
# two after it unreported.
reset_fixtures
write_fragment failing
printf 'exit 1\n' >> "${CMD_DIR}/failing"
write_fragment withboot
write_fragment noboot
declare_line noboot verbs "status"
# shellcheck disable=SC2016  # $1 is the inner shell's own positional, passed after the `_`
env AI_TOOLS_ADMIN_COMMANDS_DIR="${CMD_DIR}" AI_TOOLS_INTEGRATIONS_DIR="${MANIFEST_DIR}" \
    bash -c 'source "$1"
             ai_tools_enabled_integrations() { printf "%s\n" failing withboot noboot absent; }
             bootstrap_integrations' _ "${HELPER}" \
    > "${FIXTURE_ROOT}/out" 2>&1 && STATUS=0 || STATUS=$?
out="$(cat "${FIXTURE_ROOT}/out")"

if [[ "${out}" == *"fragment withboot ran"* ]]; then
    pass "full scope runs an enabled integration's own bootstrap"
else
    fail "the integration after a failing one was not attempted: ${out}"
fi
if [[ "${out}" == *"failing: its bootstrap failed"* ]]; then
    pass "a failing integration is named rather than aborting the run"
else
    fail "a failing integration was not named: ${out}"
fi
if [[ "${out}" == *"noboot: declares no bootstrap verb"* ]]; then
    pass "an integration that declares no bootstrap is skipped from its declaration alone"
else
    fail "an integration without a bootstrap verb was not reported as such: ${out}"
fi
if [[ "${out}" == *"absent: contributes no command"* ]]; then
    pass "an enabled integration that contributes no command is reported, not an error"
else
    fail "an enabled integration with no fragment was mishandled: ${out}"
fi
if [[ "${STATUS}" -eq 1 ]]; then
    pass "full scope exits non-zero once an integration has failed"
else
    fail "expected exit 1 after a failed integration, got ${STATUS}"
fi

# ── every fragment this repo ships declares itself ──────────────────────────────────────────
# The packaging half: a shipped command that lost its declaration would be refused on the host
# rather than here, and only after an administrator typed it.
shipped_dir="${ROOT}/src/usr/local/lib/ai-tools/admin-commands.d"
if [[ ! -d "${shipped_dir}" ]]; then
    skip "shipped fragments declare themselves" "not a source checkout"
else
    undeclared=()
    for shipped in "${shipped_dir}"/*.sh; do
        [[ -e "${shipped}" ]] || continue
        name="${shipped##*/}"; name="${name%.sh}"
        header="$(head -n 20 "${shipped}")"
        grep -qxF -- "# ai-tools-admin-command: ${name}" <<<"${header}" \
            || undeclared+=("${name} (command)")
        grep -qE '^# ai-tools-admin-api-min-version: [0-9]+\.[0-9]+$' <<<"${header}" \
            || undeclared+=("${name} (api-min-version)")
        grep -qE '^# ai-tools-admin-verbs: [a-z]' <<<"${header}" \
            || undeclared+=("${name} (verbs)")
    done
    if [[ "${#undeclared[@]}" -eq 0 ]]; then
        pass "every command fragment in src/ carries a complete interface declaration"
    else
        fail "shipped fragment(s) with an incomplete declaration: ${undeclared[*]}"
    fi
fi

finish

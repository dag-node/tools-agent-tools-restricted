#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/wrapper.sh
# Integration: the deployed launch wrapper (/usr/local/bin/claude). Exercises the ai-ops
# operator gate, the allowlist gate, and the symlink-existence guard against the REAL
# installed wrapper, hermetically: the wrapper keys its allowlist off ${HOME}, so the test
# points HOME at a /tmp testdir with a controlled allowed-projects (no dependency on the
# operator's real allowlist, and the install dir is deliberately NOT approved by install.sh).
# Every wrapper run is detached via setsid so the wrapper's /dev/tty claim prompt can never
# fire -- the test never claims a project as a side effect. Run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly wrapper="/usr/local/bin/claude"
section "Wrapper allowlist gate + symlink resolution (integration)"

if [[ ! -x "${wrapper}" ]]; then
    skip "wrapper integration" "wrapper not installed at ${wrapper}"; finish; exit
fi

mktestdir
# A hermetic HOME with a controlled allowlist: approve one temp project dir, leave a sibling
# unapproved. The home tree is owned by the projects user so the wrapper (run as that user)
# reads its own allowlist.
home="${TESTDIR}/home"
approved="${TESTDIR}/approved"
unapproved="${TESTDIR}/unapproved"
# An excluded subdir UNDER the approved parent: the allowlist approves ${approved} but carves
# ${approved}/secret back out with a '!' rule, exactly as ai-tools-chown honours it.
excluded="${approved}/secret"
mkdir -p "${home}/.config/ai-tools" "${approved}" "${unapproved}" "${excluded}"
printf '%s\n' "${approved}" "!${excluded}" > "${home}/.config/ai-tools/allowed-projects"
chmod -R 0755 "${home}" "${approved}" "${unapproved}"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${home}" "${approved}" "${unapproved}"

# Run the deployed wrapper as the projects user with the hermetic HOME, from $1 as cwd,
# detached (setsid) so no /dev/tty prompt can fire. HOME is set via `env` (the command sudo
# execs), not a sudo command-line assignment, so it reaches the wrapper regardless of sudo's
# env_reset/set_home handling -- the wrapper keys its allowlist off ${HOME}. Echoes combined
# stdout+stderr.
#
# The probe args are two-fold on purpose: a SOLE --version/--help is the wrapper's
# print-and-exit pass-through and legitimately skips the CWD gates under test, so a second
# dummy argument keeps the gates in the path; --version stays first so that if a gate ever
# regresses and the session launches, claude prints/errors and exits fast instead of
# hanging the suite on an interactive session.
run_wrapper() {  # $1 = cwd
    ( cd "$1" && setsid sudo -u "${PROJECTS_USER}" -- env HOME="${home}" \
        "${wrapper}" --version --gate-probe < /dev/null 2>&1 || true )
}

# (0) Operator gate: the wrapper refuses anyone not in the ai-ops group BEFORE it reaches the
#     allowlist. The sandbox account is never an ai-ops member (ai-tools-run enforces this), so
#     running the wrapper as it must be refused with the operator message -- and must NOT reach
#     the allowlist gate ("no session started"), proving the gate short-circuits first. The
#     subsequent operator runs (1)-(3), which DO reach the allowlist, are the positive case.
gate_out="$( cd "${home}" && setsid sudo -u "${SANDBOX_USER}" -- env HOME="${home}" \
    "${wrapper}" --version --gate-probe < /dev/null 2>&1 || true )"
if printf '%s' "${gate_out}" | grep -qE "not an ai-tools operator|member of the ai-ops"; then
    pass "wrapper refuses a non-operator (sandbox account) at the ai-ops gate"
else
    fail "wrapper did NOT refuse a non-operator at the ai-ops gate (output: ${gate_out})"
fi
if printf '%s' "${gate_out}" | grep -qE "no session started|allowlist not found"; then
    fail "wrapper reached the allowlist gate as a non-operator -- the ai-ops gate must run first"
else
    pass "wrapper short-circuits at the ai-ops gate before the allowlist check"
fi

# The allowlist-gate cases (1)-(3) exercise the wrapper PAST its symlink guard, which
# needs the provisioned toolchain's bin/claude symlink; without it every run stops at
# "claude symlink not found" before the gate under test.
if [[ ! -L "/opt/ai-tools/bin/claude" ]]; then
    skip "wrapper allowlist-gate cases (1)-(3)" "toolchain not provisioned -- run: sudo ai-tools-bootstrap"
else

# (1) An unapproved cwd is blocked at the allowlist gate. With no tty the wrapper never
#     draws the menu at all -- it takes Cancel in its own have_tty branch -- and the refusal
#     reads "no session started -- ... is not set up for the agent" (or "allowlist not found"
#     when the list file is missing). That phrase proves the BLOCK and is deliberately
#     distinct from the approved-but-not-claimed path's "not fully claimed".
out="$(run_wrapper "${unapproved}")"
if printf '%s' "${out}" | grep -qE "no session started|allowlist not found"; then
    pass "wrapper blocks execution from an unapproved directory"
else
    fail "wrapper did NOT block an unapproved directory (output: ${out})"
fi

# (1a) Cancelling names BOTH commands. The screen the menu sits under carries none (it states
#      each choice once, in the menu), so the refusal is the only place they appear -- an
#      operator who cancels, or whose run has no terminal, must still be told what to run.
if printf '%s' "${out}" | grep -qF -- '--sandbox-create' \
        && printf '%s' "${out}" | grep -qF -- '--project-claim'; then
    pass "the cancel path names both --sandbox-create and --project-claim"
else
    fail "the cancel path did not name both setup commands (output: ${out})"
fi

# (1b) The print-and-exit pass-through: a SOLE --version from that same unapproved cwd is
#      deliberately NOT gated -- it carries no project surface, so the wrapper launches the
#      confined session with the sandbox home as WorkingDirectory and claude prints its
#      version. Asserts the refusal is absent and a version string came back.
pv_out="$( cd "${unapproved}" && setsid sudo -u "${PROJECTS_USER}" -- env HOME="${home}" \
    "${wrapper}" --version < /dev/null 2>&1 || true )"
if printf '%s' "${pv_out}" | grep -qE "no session started|allowlist not found"; then
    fail "sole --version was gated on the CWD -- the pass-through regressed (output: ${pv_out})"
elif printf '%s' "${pv_out}" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    pass "sole --version passes through from an unapproved cwd and prints the version"
else
    fail "sole --version did not yield a version string (output: ${pv_out})"
fi

# (2) An approved cwd passes the allowlist gate. It then stops at the downstream claim guard
#     (the temp dir is approved but not group-claimed) -- that path says "not fully claimed",
#     never "no session started", so asserting the allowlist refusal is ABSENT still
#     distinguishes it.
out2="$(run_wrapper "${approved}")"
if printf '%s' "${out2}" | grep -qE "no session started|allowlist not found"; then
    fail "wrapper incorrectly blocked an approved directory (output: ${out2})"
else
    pass "wrapper passes the allowlist gate for an approved directory"
fi

# (2b) A '!'-excluded subdir under the approved parent is refused (trust-chain step 2: never a
#      '!'-excluded CWD). Exclusions override allows, so launching from ${approved}/secret must
#      be blocked with the "excluded by '!' rule" refusal even though its parent is approved.
out_excl="$(run_wrapper "${excluded}")"
if printf '%s' "${out_excl}" | grep -qi "excluded by"; then
    pass "wrapper refuses a '!'-excluded subdir of an approved project"
else
    fail "wrapper did NOT refuse a '!'-excluded CWD (output: ${out_excl})"
fi

# (2c) The two halves of --project-disable meet HERE, and nowhere else: the verb's whole promise
#      is that a parked project cannot be launched in, and that is this gate's decision, not the
#      CLI's. Both sides are covered apart -- the CLI writes the line (tests/integration/cli.sh),
#      the wrapper honours a '!' CWD (2b above) -- so what this asserts is that they agree about
#      the same file: the CLI's own edit, read back by the deployed wrapper.
#
#      Driven through the CLI as the operator against this fixture registry, so nothing here
#      touches the operator's real one (see the note on the two lookup routes below). The pair
#      edits one line of the caller's own allowlist and reaches no root helper, so there is no
#      password prompt.
cli=/usr/local/bin/ai-tools
if [[ ! -x "${cli}" ]]; then
    skip "disabled project refused at launch" "${cli} not installed"
else
    # The two readers reach the same file by DIFFERENT routes, and a test that steers only one of
    # them silently drives the operator's real registry: the wrapper keys its allowlist off
    # ${HOME}, while the CLI resolves the invoking user's home through `getent passwd` -- on
    # purpose, so nothing in the environment can redirect a registry write. So the CLI is pointed
    # at the fixture with AI_TOOLS_ALLOWLIST, the root-only hook the rest of the suite uses, and
    # HOME is kept as well so both agree on the file.
    fixture_allowlist="${home}/.config/ai-tools/allowed-projects"
    run_cli() {  # $@ = CLI args, run as the operator against the fixture registry
        setsid sudo -u "${PROJECTS_USER}" -- env HOME="${home}" \
            AI_TOOLS_ALLOWLIST="${fixture_allowlist}" \
            "${cli}" "$@" < /dev/null 2>&1 || true
    }
    # The park assertion is ANCHORED to a whole line. A substring test for "!${approved}" also
    # matches the fixture's own carve-out line (!${approved}/secret), so it would pass whether or
    # not the verb did anything -- and then the launch assertion below fails with no clue why.
    disable_out="$(run_cli --project-disable "${approved}")"
    if grep -qi 'unknown command' <<<"${disable_out}"; then
        # A deployed CLI older than this test: an environment fact, not a defect to report as one.
        skip "disabled project refused at launch" "the installed ai-tools has no --project-disable"
    elif ! grep -qxF "!${approved}" "${fixture_allowlist}"; then
        fail "--project-disable did not park the entry: $(printf '%s' "${disable_out}" | awk 'NF' | tail -3 | tr '\n' ' ')"
    else
        pass "--project-disable parks the approved project in the wrapper's own allowlist"

        out_disabled="$(run_wrapper "${approved}")"
        if printf '%s' "${out_disabled}" | grep -qi "disabled"; then
            pass "the launch gate refuses a project the CLI disabled (the verb's whole promise)"
        else
            fail "wrapper did NOT refuse a CLI-disabled project (output: ${out_disabled})"
        fi
        # The refusal has to name the way back, or the operator's next move is a claim over a
        # project that is already claimed -- which is what the not-yet-claimed screen would invite.
        if printf '%s' "${out_disabled}" | grep -qF -- '--project-enable'; then
            pass "and it names --project-enable rather than offering a claim"
        else
            fail "the refusal did not name --project-enable: ${out_disabled}"
        fi

        # And back: re-enabling must restore the launch, or the pair is a one-way door. This is
        # the same assertion as (2) above, made after a park/restore round trip rather than on a
        # fresh allowlist -- so an edit that left the line subtly different (moved, requoted,
        # duplicated) shows up as a project that no longer launches.
        enable_out="$(run_cli --project-enable "${approved}")"
        out_reenabled="$(run_wrapper "${approved}")"
        if printf '%s' "${out_reenabled}" | grep -qE "no session started|allowlist not found|excluded by|disabled"; then
            fail "wrapper still blocked the project after --project-enable (enable: $(printf '%s' "${enable_out}" | awk 'NF' | tail -2 | tr '\n' ' ')) (launch: ${out_reenabled})"
        else
            pass "the launch gate accepts it again after --project-enable"
        fi
    fi
fi

# (3) End-to-end symlink resolution on that same approved run: the deployed
#     /opt/ai-tools/bin/claude resolves through a package dir the user cannot stat, so an
#     `-e` existence guard would mis-report the link as missing. The wrapper must NOT.
if printf '%s' "${out2}" | grep -q "symlink not found"; then
    fail "wrapper falsely reports the claude symlink missing (output: ${out2})"
else
    pass "wrapper does not falsely report the claude symlink missing"
fi

fi  # toolchain provisioned (bin/claude symlink present)

# ── Symlink-existence guard: -L, not -e ──────────────────────────────────────────
#
# The wrapper must test link existence with `[[ -L ]]`, not `[[ -e ]]`: -e dereferences the
# full chain (bin/claude -> versioned bin/claude -> .../claude-code/bin/claude.exe), and the
# package dir is mode 700 owned by the agent, so the invoking user cannot stat the final
# target (EACCES) and -e would report a valid link as missing. -L tests the link itself.
section "Wrapper symlink-existence guard (-L not -e)"

# (A) Reproduce the hazard hermetically: a symlink chain whose final target sits behind a
#     dir the invoking user cannot enter. -L must still see the link even though -e cannot
#     stat through to the target.
fx="${TESTDIR}/fx"
mkdir -p "${fx}/pkg"
chmod 755 "${fx}"                                 # let the projects user traverse to the link
chmod 700 "${fx}/pkg"                             # root-owned 700: blocks the final stat
: > "${fx}/pkg/claude.exe"
ln -s "${fx}/pkg/claude.exe" "${fx}/versioned"    # npm symlink analogue
ln -s "${fx}/versioned"      "${fx}/link"         # stable link -> versioned -> pkg/claude.exe

l_ok=false; e_ok=false
sudo -u "${PROJECTS_USER}" test -L "${fx}/link" && l_ok=true
sudo -u "${PROJECTS_USER}" test -e "${fx}/link" && e_ok=true
if ${l_ok} && ! ${e_ok}; then
    pass "symlink with unreadable target: -L detects it, -e does not"
elif ! ${l_ok}; then
    fail "fixture broken: -L failed to detect the symlink as ${PROJECTS_USER}"
else
    skip "hazard demo" "final target is readable to ${PROJECTS_USER}; EACCES path not exercised"
fi

# (B) Pin the deployed wrapper to -L: a revert to -e reintroduces the bug.
if grep -Eq '!\s*-L\s+"\$\{CLAUDE_LINK\}"' "${wrapper}"; then
    pass "wrapper guards CLAUDE_LINK with -L"
elif grep -Eq '!\s*-e\s+"\$\{CLAUDE_LINK\}"' "${wrapper}"; then
    fail "wrapper uses -e on CLAUDE_LINK -- reintroduces false 'symlink not found' bug"
else
    fail "wrapper has no recognisable CLAUDE_LINK existence guard"
fi

# ── Fail-closed on a missing safety library ──────────────────────────────────────
#
# The wrapper sources safe-paths.lib.sh and MUST refuse to start if it (or its guard
# functions) cannot load -- a fail-open no-op stub would launch with the protected-path guard
# off (the exact fail-open the project removed, [[fail-closed-everywhere]]). Prove it on the
# real wrapper body: copy it, repoint SAFE_PATHS_LIB at a nonexistent file, and confirm the
# copy refuses before doing anything. The check runs before the operator/allowlist gates, so
# it fires regardless of who runs it or from where.
section "Wrapper fails closed when the safety library is unloadable"
brk="${TESTDIR}/claude-broken"
sed 's#^readonly SAFE_PATHS_LIB=.*#readonly SAFE_PATHS_LIB="/nonexistent/ai-tools/safe-paths.lib.sh"#' \
    "${wrapper}" > "${brk}"
# Run the copy via `bash <file>`, not by executing it: TESTDIR is under /tmp, which a hardened
# host mounts noexec (and the tmp label blocks execve under confinement), so a direct exec fails
# with EACCES before the wrapper's own logic runs. `bash <file>` reads it as a script, exercising
# the fail-closed branch regardless of the mount options or the file's SELinux type.
fc_out="$(setsid bash "${brk}" --version < /dev/null 2>&1 || true)"
if grep -qi 'cannot load the launch safety library' <<<"${fc_out}"; then
    pass "wrapper refuses to start when safe-paths.lib.sh cannot load (fail closed)"
else
    fail "wrapper did NOT fail closed on a missing safety library (output: ${fc_out})"
fi

# ── The wrapper actually CONSULTS the protected-paths backstop ───────────────────
#
# safe-paths.sh unit-tests the library in isolation; this proves the deployed wrapper calls it
# on the launch CWD. Allowlist a protected system directory in the hermetic HOME (the
# mis-configuration the backstop exists to catch) and launch from it: the wrapper must refuse
# with the protected-path message even though the allowlist "approves" it. The operator gate
# runs first, so if this environment's operator is not in ai-ops the run is intercepted there --
# skip rather than misreport.
section "Wrapper consults the protected-paths backstop (defense in depth)"
printf '%s\n' "/etc" > "${home}/.config/ai-tools/allowed-projects"
pp_out="$(run_wrapper /etc)"
if grep -qiE 'not an ai-tools operator|member of the ai-ops' <<<"${pp_out}"; then
    skip "wrapper protected-path consult" "operator gate intercepts (test operator not in ai-ops here)"
elif grep -qi 'protected system directory' <<<"${pp_out}"; then
    pass "wrapper refuses to launch in an allowlisted-but-protected system directory (/etc)"
else
    fail "wrapper did NOT invoke the protected-paths backstop on /etc (output: ${pp_out})"
fi

finish

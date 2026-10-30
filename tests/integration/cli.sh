#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/cli.sh
# Integration: the ai-tools management CLI. The CLI edits the allowlist as the PROJECTS user (and registers git
# safe.directory through the ai-tools-safedir root helper); it must refuse to run as the sandbox account for every verb
# (the agent must not manage its own allowlist), and as root for every verb that WRITES OPERATOR-OWNED STATE (it would
# write the registries with the wrong owner) while accepting the ones that write none -- the four reports, which root
# reaches because ai-tools.audit's trail is 700 root:root, and ai-tools.stop, whose helper requires root. Asserts
# that split in both directions, that the projects user passes the guard, the operator preflight and the per-verb "not
# a claimed project" refusals, and -- over a FIXTURE allowlist + gitconfig (the AI_TOOLS_ALLOWLIST / AI_TOOLS_GITCONFIG
# root-only test hooks, so it never reads the operator's real registry) -- the full ai-tools.projects.list
# reconciliation render: every entry class, every Suggested-cleanup class, and that the loop reaches its Maintenance
# footer past an early stale/protected entry. Run as root via sudo.
#
# No case spells a command: each names a key that tests/lib/cli-spelling.sh turns into the tokens the deployed CLI
# accepts, so a respelling of the command surface edits that table alone (the same rule cli-flags.sh follows). A result
# line carries the key too, since a label naming a command by its spelling is a second place the respelling would have
# to reach. A section heading and a comment are prose and name the command as an operator types it.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/cli-spelling.sh"

# Every fixture registry is written in the format this release reads, the marker first: one without it is
# the allowed-projects an earlier release wrote, which every verb but the listing refuses.
readonly REG_MARKER="# ai-tools-project-registry-format: 1.0"
require_root

readonly CLI="/usr/local/bin/ai-tools"

# spell <key>: fill CLI_ARGV with the command the key names, or end the run -- a mistyped key must not drive the bare
# binary and pass a refusal case for the wrong reason.
spell() { cli_cmd "$1" || exit 2; }

# refused <label> <code> [expected-status]: the CLI run this call follows must have exited non-zero --
# at <expected-status> where one is given -- and named the situation with <code>. Reads the `rc` and `out` globals every
# case in this file sets. The exit status is asserted beside the code because a refusal printed at exit 0 is one
# a calling script reads as success. The label comes FIRST so the code sits in a later argument, which the reference
# index reads as a citation rather than as a second definition of it (messaging.rule.md).
refused() {
    local label="$1" code="$2" want="${3:-}"
    if (( rc == 0 )); then
        fail "${label}: the CLI exited 0 where it must refuse: ${out}"
    elif [[ -n "${want}" ]] && (( rc != want )); then
        fail "${label}: expected exit ${want}, got ${rc}: ${out}"
    else
        assert_msg "${code}" "${out}" "${label}"
    fi
}

section "CLI principal guard (root reads only; the sandbox account is refused outright)"

if [[ ! -x "${CLI}" ]]; then
    skip "CLI principal guard" "not installed at ${CLI}"; finish; exit
fi

# (1a) Every verb that WRITES OPERATOR-OWNED STATE must refuse root before the first write. One per family, since
# the guard keys on the verb: a claim, a clone, and the per-project helper verbs.
for key in ai-tools.projects.claim ai-tools.projects.unclaim ai-tools.projects.clone ai-tools.projects.lockdown ai-tools.projects.handback; do
    spell "${key}"
    out="$("${CLI}" "${CLI_ARGV[@]}" 2>&1)" && rc=0 || rc=$?
    refused "CLI refuses root on ${key} (would write registries with the wrong owner)" MSG-H6W7
done

# (1b) The verbs that write no operator state are the carve-out: ai-tools.audit needs root by construction (its trail is
# 700 root:root), and refusing it left the verb unreachable from BOTH sides on a host whose only operator does not hold
# a general sudo grant. Asserted on the refusal text rather than the exit status: ai-tools.audit and ai-tools.status
# both exit non-zero to REPORT something, which is not a refusal.
for key in ai-tools.audit ai-tools.status ai-tools.projects.list ai-tools.providers; do
    spell "${key}"
    out="$("${CLI}" "${CLI_ARGV[@]}" 2>&1)" || true
    if ! grep -qxF -- MSG-H6W7 <<<"${out}"; then
        pass "CLI accepts root on the read-only report ${key}"
    else
        fail "CLI wrongly refused root on the read-only report ${key}: ${out}"
    fi
done

# ai-tools.stop is in that set too and is the one member that ACTS, so it is asserted through a REFUSAL it reaches only
# past the principal guard: an unknown option, which cmd_stop's argument loop rejects with the documented usage code
# BEFORE the sudo that would reach the root helper. Driving the bare command here would terminate every session
# on the host -- including the one running this suite -- so the assertion is that root got as far as the option loop,
# not that a stop ran.
spell ai-tools.stop
out="$("${CLI}" "${CLI_ARGV[@]}" --bogus 2>&1)" && rc=0 || rc=$?
refused "CLI accepts root on ai-tools.stop (reached the option loop, no session signalled)" MSG-B7K4 2

# (1b') --relabel moved to ai-tools-admin, and the pointer that says so answers AHEAD of the principal guard. Driven
# as ROOT for exactly that reason: this is the caller who typed the `sudo ai-tools --relabel` the older release notes
# print, and a pointer sitting behind the guard would answer them with the list of verbs root may run instead. Exit 2 is
# the documented code for a rejected command line.
out="$("${CLI}" --relabel 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -eq 2 ]] && grep -q 'atr admin system entrypoints relabel' <<<"${out}"; then
    pass "CLI points root at the moved relabel command, ahead of the principal guard"
else
    fail "CLI did not point at 'atr admin system entrypoints relabel' (rc=${rc}): ${out}"
fi

# (1c) --for stays refused for root in EITHER argument order: root is not in OPERATORS, so an entry written for it names
# an owner no ownership helper can resolve. The trailing form is the one a $1-keyed guard would miss, which is
# why the check runs after --for is separated out.
spell ai-tools.projects.list
for order in lead trail; do
    if [[ "${order}" == lead ]]; then
        out="$("${CLI}" "$(cli_flag for)" "${PROJECTS_USER}" "${CLI_ARGV[@]}" 2>&1)" && rc=0 || rc=$?
    else
        out="$("${CLI}" "${CLI_ARGV[@]}" "$(cli_flag for)" "${PROJECTS_USER}" 2>&1)" && rc=0 || rc=$?
    fi
    refused "CLI refuses root on the listing with a ${order}ing --for (--for needs an enrolled invoker)" MSG-H6W7
done

# (2) Running as the sandbox account must be refused -- the agent must not manage its own allowlist. The CLI is 755
# root:root, so the agent can exec it; the guard, not the perms, is what stops it.
if ! command -v runuser >/dev/null 2>&1; then
    skip "CLI sandbox-account guard" "runuser unavailable"
else
    spell ai-tools.projects.list
    out="$(runuser -u "${SANDBOX_USER}" -- "${CLI}" "${CLI_ARGV[@]}" 2>&1)" && rc=0 || rc=$?
    refused "CLI refuses to run as the sandbox account ${SANDBOX_USER}" MSG-Q6Q8

    # (3) The legitimate principal (the projects user) clears the guard -- the refusal is scoped to root and the agent,
    # not a blanket block. HOME is set explicitly so the CLI finds the allowlist under the projects user's config
    # regardless of runuser's env.
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" "${CLI}" "${CLI_ARGV[@]}" 2>&1)" || true
    if ! grep -qiE 'do not run as root|refusing to run as the sandbox account' <<<"${out}"; then
        pass "the projects user (${PROJECTS_USER}) passes the principal guard"
    else
        fail "the projects user was wrongly blocked by the principal guard: ${out}"
    fi
fi

# ── atr: the installed short command ──────────────────────────────────────────────────────────
# `atr` is a spelling of the two programs, so these rows spell it as typed: the spelling is what they are about. They
# sit ahead of the bootstrap gate: `--version` is exempt from it and the admin rows run as root, so neither needs
# an agent. The installed wrapper resolves sudo by name, so a recording shim first on its PATH is what it execs;
# the shim row proves the argv the installed file hands sudo, not the host's sudo policy, which the operator rows drive.
section "atr: the installed short command runs ai-tools, and atr admin runs ai-tools-admin"
readonly ATR=/usr/local/bin/atr ADMIN=/usr/local/libexec/ai-tools/ai-tools-admin
if [[ ! -x "${ATR}" ]]; then
    skip_required "atr" "the deployed ${CLI} predates atr (install this version to cover it)"
elif ! command -v runuser >/dev/null 2>&1; then
    skip_required "atr" "runuser unavailable to run it as ${PROJECTS_USER}"
else
    [[ "$(stat -c '%a %U:%G' "${ATR}")" == '755 root:root' && "$(sed -n '3p' "${ATR}")" == '# /usr/local/bin/atr --'* ]] \
        && pass "${ATR} is 0755 root:root and carries the marker line" \
        || fail "${ATR}: $(stat -c '%a %U:%G' "${ATR}"), third line: $(sed -n '3p' "${ATR}")"
    [[ -L /usr/sbin/atr && "$(readlink -f /usr/sbin/atr)" == "${ATR}" ]] \
        && pass "/usr/sbin/atr is a symlink resolving to ${ATR}" \
        || fail "/usr/sbin/atr: $(ls -ld /usr/sbin/atr 2>&1)"
    for stub in "man1/atr.1:.so man1/ai-tools.1" "man8/atr.8:.so man8/ai-tools-admin.8"; do
        page="$(compgen -G "/usr/local/share/man/${stub%%:*}" || compgen -G "/usr/local/share/man/${stub%%:*}.gz" || true)"
        so_line=""
        [[ -n "${page}" ]] && so_line="$(zcat -f -- "${page}" | sed -n '/^\.\\"/d;p;q')"
        [[ -n "${page}" && "${so_line}" == "${stub#*:}" ]] \
            && pass "${page} is the stub '${stub#*:}'" \
            || fail "the ${stub%%:*} stub: ${page:-absent}, first request: ${so_line:-none}"
    done
    want="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" "${CLI}" --version 2>&1)" || true
    got="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" "${ATR}" --version 2>&1)" || true
    [[ -n "${want}" && "${got}" == "${want}" ]] && pass "atr --version as ${PROJECTS_USER} prints what ai-tools --version prints" \
        || fail "atr --version: '${got}', ai-tools --version: '${want}'"
    want="$("${ADMIN}" --version 2>&1)" || true
    got="$("${ATR}" admin --version 2>&1)" || true
    [[ -n "${want}" && "${got}" == "${want}" ]] && pass "atr admin --version as root prints what ai-tools-admin --version prints, with no notice" \
        || fail "atr admin --version: '${got}', ai-tools-admin --version: '${want}'"
    want_rc=0; "${ADMIN}" status >/dev/null 2>&1 || want_rc=$?
    got_rc=0; "${ATR}" admin status >/dev/null 2>&1 || got_rc=$?
    (( got_rc == want_rc )) && pass "atr admin status as root exits as ai-tools-admin status does (${want_rc})" \
        || fail "atr admin status exited ${got_rc}, ai-tools-admin status ${want_rc}"

    # The shim needs a directory where a 0755 file is executable, which a noexec /tmp is not, and runs as the projects
    # user, so the status file root writes for it takes 0644 whatever umask the run inherited.
    shim_dir=""
    mk_fixture_dir shim_dir "${PROJECTS_HOME}" atr-shim 2>/dev/null || shim_dir=""
    if [[ -z "${shim_dir}" ]]; then
        skip_required "the installed atr's sudo argv" "no fixture directory beside ${PROJECTS_HOME}"
    else
        chmod 0755 "${shim_dir}"
        # 99 is the shim's own "status file unreadable", which neither row expects.
        cat > "${shim_dir}/sudo" <<EOF
#!/bin/bash
printf '%s\0' "\$@" > "${shim_dir}/argv"
read -r status 2>/dev/null < "${shim_dir}/status" || status=99
exit "\${status}"
EOF
        chmod 0755 "${shim_dir}/sudo"; printf '0\n' > "${shim_dir}/status"; chmod 0644 "${shim_dir}/status"
        chown "${PROJECTS_USER}" "${shim_dir}"
        # shim_run : the installed atr as the projects user with the shim first on PATH; sets rc, out and err.
        shim_run() {
            rm -f "${shim_dir}/argv" "${shim_dir}/err"
            rc=0
            out="$(runuser -u "${PROJECTS_USER}" -- env -i HOME="${PROJECTS_HOME}" PATH="${shim_dir}:/usr/bin:/bin" \
                "${ATR}" admin system bootstrap --agents 'a b' '' -- x 2> "${shim_dir}/err")" || rc=$?
            err="$(cat "${shim_dir}/err"; printf x)"; err="${err%x}"
        }
        shim_run
        mapfile -d '' -t argv < "${shim_dir}/argv" 2>/dev/null || argv=()
        expected=( -- "${ADMIN}" system bootstrap --agents 'a b' '' -- x )
        if [[ "${#argv[@]}" == "${#expected[@]}" && "$(printf '%s\x1f' "${argv[@]}")" == "$(printf '%s\x1f' "${expected[@]}")" \
              && "${err}" == $'atr admin: runs as root through sudo\n' && -z "${out}" && "${rc}" == 0 ]]; then
            pass "the installed atr hands sudo '-- ${ADMIN}' and each argument as one field, after the one notice line"
        else
            fail "the installed atr's sudo argv: [$(printf '%s|' "${argv[@]}")] rc=${rc} stderr=[${err}] stdout=[${out}]"
        fi
        printf '7\n' > "${shim_dir}/status"
        shim_run
        (( rc == 7 )) && pass "the installed atr exits 7 when sudo does" || fail "sudo exited 7, the installed atr exited ${rc}"
    fi
fi

# Every section from here on drives a project verb past the CLI's bootstrap gate, which refuses while no enabled agent
# has a launcher link (the harness's provisioned_agent read): one skip names that state and the command that ends it.
if ! provisioned_agent; then skip_unprovisioned "CLI project verbs"; finish; exit; fi

# (4) Operator preflight: a user NOT in OPERATORS is refused on an operator-acting command, BEFORE any registry write.
# Point the CLI at a temp operator.conf listing a bogus operator (not the projects user) and run ai-tools.projects.claim
# as the projects user -- require_operator must refuse.
if command -v runuser >/dev/null 2>&1; then
    section "CLI operator preflight (OPERATORS membership)"
    mktestdir
    chmod 755 "${TESTDIR}"
    tconf="${TESTDIR}/operator.conf"
    mk_operator_conf "${tconf}" nobody-operator
    proj="${TESTDIR}/proj"; mkdir -p "${proj}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${proj}"
    # An empty FIXTURE allowlist (AI_TOOLS_ALLOWLIST test hook) so the mutating-verb refusals classify against it, never
    # the operator's real registry -- and a regression that wrote past a refusal would touch this throwaway file,
    # which the next assertion inspects.
    emptyal="${TESTDIR}/empty-allowlist"; printf '%s\n' "${REG_MARKER}" > "${emptyal}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${emptyal}"

    spell ai-tools.projects.claim
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${tconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
            "${CLI}" "${CLI_ARGV[@]}" "${proj}" 2>&1)" && rc=0 || rc=$?
    refused "operator-acting command refused for a non-OPERATORS user, up front" MSG-X6U2
    if grep -q '^[^#]' "${emptyal}" || grep -qi 'registry: added' <<<"${out}"; then
        fail "refused claim still wrote to the allowlist: ${out}"
    else
        pass "refused claim wrote no registry state (gate precedes registry writes)"
    fi

    # (5) The informational commands stay open to that same non-operator user.
    spell ai-tools.help
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${tconf}" "${CLI}" "${CLI_ARGV[@]}" 2>&1)" || true
    if grep -qi 'manage the projects a sandboxed coding agent may work in' <<<"${out}"; then
        pass "--help stays open to a non-operator user"
    else
        fail "--help was blocked for a non-operator: ${out}"
    fi
    # The bare word is the same command, so it prints the same summary; the spelling is what this case is about.
    help_option_out="${out}"
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${tconf}" "${CLI}" help 2>&1)" && rc=0 || rc=$?
    if (( rc == 0 )) && [[ "${out}" == "${help_option_out}" ]]; then
        pass "the bare word help prints what --help prints"
    else
        fail "help (exit ${rc}) differs from --help: ${out}"
    fi

    # (6) ai-tools.projects.unclaim classifies its target against allowed-projects: a directory that no entry covers
    # AND that has no ai-tools ownership or group is REFUSED, before any registry/filesystem change. The testdir path is
    # not in the (real) allowlist and is freshly created, so it classifies as unrelated-and-clean -- the one outcome
    # with no remedy to offer (a tree carrying the fingerprint is instead pointed at --force). Runs as an OPERATOR (conf
    # lists the projects user) so classification runs past the operator gate; under setsid so any prompt takes its
    # non-interactive default rather than blocking.
    oconf="${TESTDIR}/op-self.conf"
    mk_operator_conf "${oconf}" "${PROJECTS_USER}"
    lone="${TESTDIR}/not-a-project"; mkdir -p "${lone}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lone}"
    spell ai-tools.projects.unclaim
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
            setsid "${CLI}" "${CLI_ARGV[@]}" "${lone}" 2>&1)" && rc=0 || rc=$?
    refused "ai-tools.projects.unclaim refuses a directory that is neither a claimed project nor an ancestor of one" MSG-P8W2

    # (6b) A project root owned by a third party is REFUSED, not claimed. The claim's setgid and ACL helpers act only
    # on paths held by the resolved operator or the sandbox account, so such a tree takes neither grant while
    # the registries and the label still apply -- a claim that reports ✓ having given the agent no way into the project.
    # The refusal has to precede the first registry write, so the fixture allowlist is inspected afterwards as well.
    if id nobody >/dev/null 2>&1; then
        printf '%s\n' "${REG_MARKER}" > "${emptyal}"
        foreignproj="${TESTDIR}/foreign-proj"; mkdir -p "${foreignproj}"
        chown nobody:nobody "${foreignproj}"
        spell ai-tools.projects.claim
        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
                setsid "${CLI}" "${CLI_ARGV[@]}" "${foreignproj}" 2>&1)" && rc=0 || rc=$?
        refused "ai-tools.projects.claim refuses a project root owned by a third party" MSG-U8G4
        if grep -q "chown -R ${PROJECTS_USER} ${foreignproj}" <<<"${out}"; then
            pass "the refusal names the chown that makes the tree claimable"
        else
            fail "the refusal did not name the chown remedy: $(brief "${out}" 'chown')"
        fi
        if grep -q '^[^#]' "${emptyal}"; then
            fail "refused claim still wrote to the allowlist: $(cat "${emptyal}")"
        else
            pass "the owner refusal precedes every registry write"
        fi
    else
        skip "third-party-owned claim root" "user 'nobody' not present"
    fi

    # brief <captured-output> [pattern]  -- a SHORT diagnostic for a FAIL message. The flows here print thirty-odd lines
    # of headline blocks and per-step results, and interpolating all of that into a failure line buries the one thing
    # that explains it -- especially in the runner's end-of-run summary, which reprints FAIL lines and is unreadable if
    # each is a screenful. With a <pattern> it shows the lines the assertion is actually about; without one, the last
    # three non-empty lines, which is where a refusal or a die() lands. Joined with " ~ " so the message stays a single
    # line.
    brief() {
        local text="$1" pat="${2:-}" sel=""
        [[ -n "${pat}" ]] && sel="$(grep -iE -- "${pat}" <<<"${text}" | head -n 3)"
        [[ -n "${sel}" ]] || sel="$(awk 'NF' <<<"${text}" | tail -n 3)"
        awk '{printf "%s%s", sep, $0; sep=" ~ "}' <<<"${sel}"
    }

    # (6c) ai-tools.projects.create is a real verb, not an alias, so its refusals are asserted where the old alias had
    # none. Every one of them must leave NO RESIDUE behind -- no directory, no registry entry -- which is what makes
    # "recover with ai-tools.projects.claim" the only recovery path it needs.
    printf '%s\n' "${REG_MARKER}" > "${emptyal}"
    create_cli() {
        local -a argv
        cli_cmd ai-tools.projects.create || exit 2
        argv=("${CLI_ARGV[@]}")
        runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
            setsid "${CLI}" "${argv[@]}" "$@" 2>&1
    }

    # A path is REQUIRED: the cwd always exists, so a defaulted create could only ever refuse.
    out="$(create_cli)" && rc=0 || rc=$?
    refused "ai-tools.projects.create refuses to run without a path" MSG-A7D3

    # An EXISTING directory is refused, naming the verb that does claim one. This is the line between the two verbs:
    # a create that quietly claimed what was already there would make them interchangeable, and only one of them grants
    # an agent access to an existing tree.
    exists="${TESTDIR}/already-here"; mkdir -p "${exists}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${exists}"
    out="$(create_cli "${exists}")" && rc=0 || rc=$?
    assert_msg MSG-T4B9 "${out}" "ai-tools.projects.create refuses an existing directory"
    if [[ ${rc} -ne 0 ]] && grep -qF -- "$(cli_cmd_text ai-tools.projects.claim)" <<<"${out}"; then
        pass "ai-tools.projects.create refuses an existing directory, naming ai-tools.projects.claim"
    else
        fail "ai-tools.projects.create did not refuse an existing directory (rc=${rc}): $(brief "${out}")"
    fi

    # ONE directory is created, never a path of them: a parent that does not exist is refused rather than built. This is
    # what keeps a mistyped path from becoming a silently manufactured tree with a claimed project inside it.
    out="$(create_cli "${TESTDIR}/no/such/parent/proj")" && rc=0 || rc=$?
    # By code: the missing-parent refusal (MSG-J3R8), not the path-exists one (MSG-T4B9).
    assert_msg MSG-J3R8 "${out}" "ai-tools.projects.create refuses a missing parent"
    if [[ ${rc} -ne 0 ]] && [[ ! -e "${TESTDIR}/no" ]]; then
        pass "ai-tools.projects.create refuses a missing parent and creates none of it"
    else
        fail "ai-tools.projects.create did not refuse a missing parent (rc=${rc}): $(brief "${out}")"
    fi

    # A directory whose name ends in a line feed, beside its sibling without one. A bare `$(...)` capture of the parent
    # strips the line feed, so `twin<LF>/new` would be created under the sibling `twin` and claimed there. Every capture
    # keeps it, so the create reaches the control-character refusal (MSG-V8Z5) before its first write, and creates
    # neither directory. The control is that capture, made as the operator, reading the sibling.
    twin="${TESTDIR}/twin"; twin_lf="${TESTDIR}/twin"$'\n'
    mkdir -- "${twin}" "${twin_lf}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${twin}" "${twin_lf}"
    stripped="$(runuser -u "${PROJECTS_USER}" -- realpath -e -- "${twin_lf}" 2>/dev/null)" || stripped=""
    if [[ "${stripped}" == "${twin}" ]]; then
        note "control: a bare capture of the line-feed directory reads its sibling" "${stripped}"
    else
        fail "control: a bare capture of ${twin}<LF> read '${stripped}' (want ${twin}) -- the row below proves nothing"
    fi
    out="$(create_cli "${twin_lf}/new")" && rc=0 || rc=$?
    refused "ai-tools.projects.create refuses a parent whose name ends in a line feed" MSG-V8Z5 1
    if [[ ! -e "${twin}/new" && ! -e "${twin_lf}/new" ]]; then
        pass "the line-feed parent creates neither ${twin}/new nor its twin"
    else
        fail "the line-feed parent created a directory: $(ls -A "${twin}" "${twin_lf}" 2>&1)"
    fi
    # The line-feed directory itself exists: the control-character refusal precedes the existence check, so the path is
    # refused under its own code and is not printed by the existence refusal.
    out="$(create_cli "${twin_lf}")" && rc=0 || rc=$?
    refused "ai-tools.projects.create refuses an existing path holding a line feed under its own code" MSG-V8Z5 1
    if grep -qx "MSG-T4B9" <<<"${out}"; then
        fail "the existing line-feed path reached the existence refusal: $(brief "${out}")"
    else
        pass "the existing line-feed path is not reported as an existing path"
    fi

    # A path whose last component is a symbolic link is refused by the name typed (MSG-G7D3), dangling or not:
    # the create resolving the leaf would otherwise make and claim the directory a dangling link points at, and a link
    # to a directory that exists is refused by name rather than as the path it leads to. A trailing slash does not
    # change which component is the leaf.
    link_target_dir="${TESTDIR}/link-target"; mkdir -p "${link_target_dir}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${link_target_dir}"
    ln -s "${link_target_dir}/absent" "${TESTDIR}/dangling"
    ln -s "${exists}" "${TESTDIR}/to-existing"
    for leaf_link in "${TESTDIR}/dangling" "${TESTDIR}/dangling/" "${TESTDIR}/to-existing"; do
        out="$(create_cli "${leaf_link}")" && rc=0 || rc=$?
        refused "ai-tools.projects.create refuses ${leaf_link#"${TESTDIR}/"}, a symbolic-link leaf" MSG-G7D3 1
    done
    if [[ ! -e "${link_target_dir}/absent" && -L "${TESTDIR}/dangling" && -z "$(ls -A "${exists}")" ]]; then
        pass "a symbolic-link leaf creates nothing where the link points, and the link is left in place"
    else
        fail "a symbolic-link leaf created a directory or lost the link: $(ls -lA "${link_target_dir}" "${exists}" 2>&1)"
    fi

    # A location under a directory the operator cannot enter is refused by name (MSG-D4Z6) before anything is created:
    # the claim reads the tree as the operator, and both existence checks read such a path as absent. The existing
    # directory behind the seal is the case that tells the two apart: read as absent, it would take the missing-parent
    # refusal (MSG-J3R8), and `projects claim` would report it as a path not found.
    sealed="${TESTDIR}/sealed"; mkdir -p "${sealed}/inner"; chmod 0700 "${sealed}"
    if [[ -d "${sealed}/inner" ]] && ! runuser -u "${PROJECTS_USER}" -- test -x "${sealed}"; then
        out="$(create_cli "${sealed}/inner/proj")" && rc=0 || rc=$?
        refused "ai-tools.projects.create refuses a location under a directory the operator cannot enter" MSG-D4Z6 1
        if [[ ! -e "${sealed}/inner/proj" ]] && grep -qF "${sealed}" <<<"${out}"; then
            pass "the refusal names the directory the operator cannot enter, and nothing was created"
        else
            fail "the unreachable-location refusal did not name ${sealed} or left a directory: $(brief "${out}")"
        fi
        out="$(create_cli "${sealed}/inner")" && rc=0 || rc=$?
        refused "ai-tools.projects.create refuses an existing directory it cannot see behind a sealed parent" MSG-D4Z6 1
        spell ai-tools.projects.claim
        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
                setsid "${CLI}" "${CLI_ARGV[@]}" "${sealed}/inner" 2>&1)" && rc=0 || rc=$?
        refused "ai-tools.projects.claim refuses a project under a directory the operator cannot enter" MSG-D4Z6 1

        # A symbolic link inside the sealed directory, leading out of it. `realpath -m` run as the operator cannot stat
        # the link and collapses `link/../..` lexically, so the sealed directory leaves the path and a create would make
        # ${TESTDIR}/new, a directory nobody named. The control shows the collapse; root reads through the seal
        # and follows the link, so it is run as the operator.
        mkdir -p "${TESTDIR}/elsewhere/deep/deeper"
        ln -s "${TESTDIR}/elsewhere/deep/deeper" "${sealed}/link"
        through="${sealed}/link/../../new"
        collapsed="$(runuser -u "${PROJECTS_USER}" -- realpath -m -- "${through}" 2>/dev/null)" || collapsed=""
        if [[ "${collapsed}" == "${TESTDIR}/new" ]]; then
            note "control: realpath -m as the operator collapses the path past the sealed directory" "${collapsed}"
        else
            fail "control: realpath -m as the operator printed '${collapsed}' (want ${TESTDIR}/new) -- the rows below prove nothing"
        fi
        out="$(create_cli "${through}")" && rc=0 || rc=$?
        refused "ai-tools.projects.create refuses a path through a link inside a directory the operator cannot enter" \
            MSG-D4Z6 1
        if [[ ! -e "${TESTDIR}/new" && ! -e "${TESTDIR}/elsewhere/new" ]] \
                && grep -qF "cannot enter ${sealed} as" <<<"${out}"; then
            pass "the refusal names the sealed directory the link sits in, and nothing was created"
        else
            fail "the refusal did not name ${sealed} or a directory was created: $(brief "${out}")"
        fi
        spell ai-tools.projects.claim
        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
                setsid "${CLI}" "${CLI_ARGV[@]}" "${through}" 2>&1)" && rc=0 || rc=$?
        refused "ai-tools.projects.claim refuses a path through a link inside a directory the operator cannot enter" \
            MSG-D4Z6 1

        # A component that does not exist, or one that is a file, ends the kernel's lookup there, so the `..` after it
        # never reaches the sealed directory: the create refuses the parent it cannot resolve (MSG-J3R8) and the claim
        # reports a path not found, neither naming ${sealed}. A walk over the lexically collapsed form would name it,
        # and under `--for` offer a traverse grant on a directory that is not the cause.
        : > "${TESTDIR}/regular"
        for through in "${TESTDIR}/missing/../sealed/new" "${TESTDIR}/regular/../sealed/new"; do
            out="$(create_cli "${through}")" && rc=0 || rc=$?
            refused "ai-tools.projects.create refuses ${through#"${TESTDIR}/"} as a parent it cannot resolve" MSG-J3R8 1
            if [[ ! -e "${sealed}/new" ]] && ! grep -qF "cannot enter ${sealed}" <<<"${out}"; then
                pass "the refusal of ${through#"${TESTDIR}/"} does not name ${sealed}, and nothing was created"
            else
                fail "the refusal of ${through#"${TESTDIR}/"} named ${sealed} or a directory was created: $(brief "${out}")"
            fi
        done
        spell ai-tools.projects.claim
        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
                setsid "${CLI}" "${CLI_ARGV[@]}" "${TESTDIR}/missing/../sealed/new" 2>&1)" && rc=0 || rc=$?
        if (( rc != 0 )) && grep -qF "path not found" <<<"${out}" && ! grep -qx "MSG-D4Z6" <<<"${out}"; then
            pass "ai-tools.projects.claim reports missing/../sealed/new as a path not found, not as unreachable"
        else
            fail "ai-tools.projects.claim over missing/../sealed/new (rc=${rc}): $(brief "${out}")"
        fi

        # A blocker whose own name ends in a line feed is named whole: the walk returns its result in a variable,
        # so the sanitized name the refusal prints ends in the sanitizer's `?` for the line feed, not in the sibling's
        # name.
        blocked_lf="${TESTDIR}/blocked"$'\n'; mkdir -p -- "${blocked_lf}/inner"; chmod 0700 "${blocked_lf}"
        out="$(create_cli "${blocked_lf}/inner/proj")" && rc=0 || rc=$?
        refused "ai-tools.projects.create refuses a location under a sealed directory whose name ends in a line feed" \
            MSG-D4Z6 1
        if grep -qF "cannot enter ${TESTDIR}/blocked? as" <<<"${out}" && [[ ! -e "${blocked_lf}/inner/proj" ]]; then
            pass "the refusal names the line-feed directory whole, and nothing was created"
        else
            fail "the refusal did not name ${TESTDIR}/blocked<LF> whole: $(brief "${out}")"
        fi

        # The case the walk follows a link for: a link in a directory the operator enters, leading into the sealed one.
        # `test -e` cannot stat it, so the walk resolves it and still names ${sealed}; passes before and after.
        ln -s "${sealed}/inner" "${TESTDIR}/alias"
        out="$(create_cli "${TESTDIR}/alias/new")" && rc=0 || rc=$?
        refused "ai-tools.projects.create refuses a link leading into a directory the operator cannot enter" MSG-D4Z6 1
        if [[ ! -e "${sealed}/inner/new" ]] && grep -qF "cannot enter ${sealed} as" <<<"${out}"; then
            pass "the refusal follows the link and names ${sealed}, and nothing was created"
        else
            fail "the refusal over the link did not name ${sealed} or a directory was created: $(brief "${out}")"
        fi
        # The same link as the claim's own path: the link is the leaf, so the walk must read the leaf to name ${sealed},
        # and not report the path as not found.
        spell ai-tools.projects.claim
        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
                setsid "${CLI}" "${CLI_ARGV[@]}" "${TESTDIR}/alias" 2>&1)" && rc=0 || rc=$?
        refused "ai-tools.projects.claim refuses a link leaf leading into a directory the operator cannot enter" \
            MSG-D4Z6 1
        if grep -qF "cannot enter ${sealed} as" <<<"${out}" && ! grep -qF "path not found" <<<"${out}"; then
            pass "the claim's refusal over the link leaf names ${sealed}, not a path not found"
        else
            fail "the claim's refusal over the link leaf did not name ${sealed}: $(brief "${out}")"
        fi
    else
        fail "the sealed-parent fixture did not set up: ${sealed} is enterable by ${PROJECTS_USER} or inner is missing"
    fi

    # The protected-paths backstop on the target: a create must not be able to MANUFACTURE a protected directory. Exits
    # 3, the backstop's own code. Driven against a protected path this host does not have; if it has all of them there
    # is no path to assert and the case skips.
    protected=""
    for p in /efi /lost+found /libx32 /lib32 /srv /media; do
        [[ -e "${p}" ]] || { protected="${p}"; break; }
    done
    if [[ -n "${protected}" ]]; then
        out="$(create_cli "${protected}")" && rc=0 || rc=$?
        if [[ ${rc} -eq 3 ]] && [[ ! -e "${protected}" ]]; then
            pass "ai-tools.projects.create refuses a protected target (exit 3, nothing created)"
        else
            fail "ai-tools.projects.create did not refuse protected ${protected} with exit 3 (rc=${rc}): $(brief "${out}")"
        fi
    else
        skip "ai-tools.projects.create protected-target refusal" "this host has every protected path already"
    fi

    # Atomic on refusal: no refused verb may have written a registry entry. The fixture allowlist is the one
    # a regression would touch.
    if grep -q '^[^#]' "${emptyal}"; then
        fail "a refused ai-tools.projects.create wrote to the allowlist: $(cat "${emptyal}")"
    else
        pass "every refused ai-tools.projects.create left the allowlist untouched"
    fi

    # THE HAPPY PATH. Every preceding assertion is a refusal, which together can be satisfied by a verb that acts on no
    # path at all -- so the one run that has to actually work is asserted too, end to end and unattended. It runs
    # under setsid with NO -y (the verb has none): a create that still asked something would block here and be killed
    # by the file timeout, which is the regression this also guards.
    crwork="${TESTDIR}/create-work"; mkdir -p "${crwork}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${crwork}"; chmod 755 "${crwork}"
    printf '%s\n' "${REG_MARKER}" > "${emptyal}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${emptyal}"
    newproj="${crwork}/newproject"
    # The exit status depends on whether this environment can authenticate for the claim's root helpers. Under setsid
    # there is no terminal to type a password at, so the claim reports that it could not finish and exits 1;
    # where the suite's sudo does not require a password it exits 0. Both are correct, and both are asserted --
    # what must never happen is the third outcome this replaced, where every root step failed and the flow still closed
    # on a success mark.
    out="$(create_cli "${newproj}")" && rc=0 || rc=$?
    if [[ -d "${newproj}" ]] && { [[ ${rc} -eq 0 ]] \
            || { [[ ${rc} -eq 1 ]] && grep -qi 'the claim did not complete' <<<"${out}"; }; }; then
        pass "ai-tools.projects.create creates the project and reports the claim outcome honestly"
    else
        fail "ai-tools.projects.create neither completed nor reported why (rc=${rc}): $(brief "${out}")"
    fi
    # The two must not co-occur: a claim that reports steps it could not apply has not claimed.
    if grep -qi 'did not complete' <<<"${out}" && grep -q '✓ claimed' <<<"${out}"; then
        fail "the claim reported both an incomplete state and success: $(brief "${out}" 'did not complete|claimed')"
    else
        pass "the claim never reports success alongside steps it could not apply"
    fi
    if [[ -d "${newproj}/.git" ]] && [[ -f "${newproj}/README.md" ]] \
            && grep -qxF '# newproject' "${newproj}/README.md"; then
        pass "ai-tools.projects.create initializes git and writes a README naming the directory"
    else
        fail "ai-tools.projects.create left an incomplete tree: $(ls -A "${newproj}" 2>&1)"
    fi
    if grep -qxF "${newproj}" "${emptyal}"; then
        pass "ai-tools.projects.create registers the new project in allowed-projects"
    else
        fail "ai-tools.projects.create did not register the project: $(cat "${emptyal}")"
    fi
    # The tree it makes is owned by the operator, which is what the claim's own owner guard requires -- a create
    # that produced a root-owned tree would claim no path and say so.
    if [[ "$(stat -c '%U' "${newproj}")" == "${PROJECTS_USER}" ]]; then
        pass "ai-tools.projects.create leaves the tree owned by the operator it acts for"
    else
        fail "the created tree is owned by $(stat -c '%U' "${newproj}"), not ${PROJECTS_USER}"
    fi
    # The secret scan is skipped on an empty tree, so a create must never reach ai-tools-lockdown. Asserted
    # on that helper specifically, NOT on the absence of any password prompt: the claim legitimately sudo's for safedir,
    # setgid, setfacl and relabel, since group ownership cannot be changed to a group the operator is not in without
    # root.
    if ! grep -q 'ai-tools-lockdown' <<<"${out}" \
            && ! grep -qi 'scan for secret-named files' <<<"${out}"; then
        pass "ai-tools.projects.create never reaches the secret scan (nothing in the tree to scan)"
    else
        fail "ai-tools.projects.create ran the secret scan on a tree it had just created: $(brief "${out}" 'lockdown|secret-named')"
    fi

    # No path it seeds may be owner-only. Under a umask of 077 the directory would be born 0700, README.md 0600,
    # and .git 0700/0600 -- and an owner-only path is one the claim's helpers honour as a seal and skip, so the verb
    # would produce a registered project whose README the agent cannot read and whose git it cannot use, having reported
    # that it normalized both. This is the assertion that fails on a umask-077 host if any of those modes is inherited.
    _sealed=""
    for _p in "${newproj}" "${newproj}/README.md" "${newproj}/.git" "${newproj}/.git/config"; do
        [[ -e "${_p}" ]] || continue
        (( (8#$(stat -c '%a' "${_p}") & 077) == 0 )) && _sealed+=" ${_p}($(stat -c '%a' "${_p}"))"
    done
    if [[ -z "${_sealed}" ]]; then
        pass "ai-tools.projects.create seeds nothing owner-only (reachable whatever the host umask)"
    else
        fail "ai-tools.projects.create seeded owner-only path(s) the claim will skip:${_sealed}"
    fi
    # Matched on the NOTICE's own title, not on the phrase "owner-only": the create prints that phrase itself when it
    # explains the modes it set on a umask-077 host, so a looser grep asserts the opposite of what it means on exactly
    # the hosts this case exists for.
    if ! grep -qi 'this project directory is owner-only' <<<"${out}"; then
        pass "the claim does not report the new project as out of the agent's reach"
    else
        fail "the created project was claimed as owner-only: $(brief "${out}" 'owner-only')"
    fi

    # (6d) ai-tools.projects.remove.inplace deletes, so every assertion here is that it did NOT. Its authorization is
    # an exact allowlist entry alone: there is no --force, and an unattended run never reaches the deletion because both
    # the default-NO confirm and the typed-name challenge decline with no terminal (these run under setsid, so that is
    # the path being
    # driven).
    remove_cli() {
        local -a argv
        cli_cmd ai-tools.projects.remove.inplace || exit 2
        argv=("${CLI_ARGV[@]}")
        runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${rmal}" \
            setsid "${CLI}" "${argv[@]}" "$@" 2>&1
    }
    # The fixture registry lives in a directory the PROJECTS user owns, not in TESTDIR itself (root-owned): unreg_allow
    # rewrites the allowlist with `sed -i`, which writes its temporary file into the file's own DIRECTORY,
    # so a root-owned parent fails the removal even though the file is writable. That is the same shape as the real
    # layout, where the allowlist sits in the operator's own 0700 ~/.config/ai-tools.
    regdir="${TESTDIR}/registries"; mkdir -p "${regdir}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${regdir}"; chmod 700 "${regdir}"
    rmal="${regdir}/remove-allowlist"
    # The project fixtures live under a directory the PROJECTS user OWNS, because removing a project ends by unlinking
    # it from its parent -- which needs write permission there, not on the project. Root-owned TESTDIR would fail
    # that, which is a real refusal (asserted on its own case) rather than the case these are for.
    rmwork="${TESTDIR}/work"; mkdir -p "${rmwork}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${rmwork}"; chmod 755 "${rmwork}"
    rmproj="${rmwork}/rm-proj"; mkdir -p "${rmproj}/sub"
    rmnested="${rmproj}/inner"; mkdir -p "${rmnested}"
    rmother="${rmwork}/rm-other"; mkdir -p "${rmother}"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmproj}" "${rmother}"

    # An unregistered path is refused: the registry entry is the authorization, so a tree no registry names claimed is
    # not this verb's to delete.
    printf '%s\n' "${REG_MARKER}" "${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli "${rmother}")" && rc=0 || rc=$?
    assert_msg MSG-P8Y8 "${out}" "ai-tools.projects.remove.inplace refuses an unregistered path"
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmother}" ]]; then
        pass "ai-tools.projects.remove.inplace refuses an unregistered path, deleting nothing"
    else
        fail "ai-tools.projects.remove.inplace did not refuse an unregistered path (rc=${rc}): $(brief "${out}")"
    fi

    # A path INSIDE a claimed project is refused, naming the project that is the real target.
    out="$(remove_cli "${rmproj}/sub")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmproj}/sub" ]] && grep -qF "${rmproj}" <<<"${out}"; then
        pass "ai-tools.projects.remove.inplace refuses a path inside a project, naming the project"
    else
        fail "ai-tools.projects.remove.inplace did not refuse a descendant (rc=${rc}): $(brief "${out}")"
    fi
    assert_msg MSG-T5A3 "${out}" "the refusal is the inside-a-project one"

    # An ancestor of claimed projects is refused and pointed at ai-tools.projects.unclaim: this verb removes one
    # registered project, never a directory that merely contains some.
    out="$(remove_cli "${rmwork}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmproj}" ]] && grep -qF -- "$(cli_cmd_text ai-tools.projects.unclaim)" <<<"${out}"; then
        pass "ai-tools.projects.remove.inplace refuses an ancestor of claimed projects"
    else
        fail "ai-tools.projects.remove.inplace did not refuse an ancestor (rc=${rc}): $(brief "${out}")"
    fi
    assert_msg MSG-F4D8 "${out}" "the refusal is the unregistered-ancestor one"

    # An exact entry that CONTAINS another claimed project is refused. Deleting it would take the nested one with it
    # and leave that project registered, git-trusted and labelled at a path that no longer exists.
    printf '%s\n' "${REG_MARKER}" "${rmproj}" "${rmnested}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli "${rmproj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmnested}" ]] && grep -qF "${rmnested}" <<<"${out}"; then
        pass "ai-tools.projects.remove.inplace refuses a project containing another claimed project, naming it"
    else
        fail "ai-tools.projects.remove.inplace did not refuse a project with a nested claim (rc=${rc}): $(brief "${out}")"
    fi
    assert_msg MSG-Q3R9 "${out}" "the refusal is the registered-entry-contains-projects one"

    # There is no --force: the flag that reaches an unregistered tree on unclaim must not become a way to delete one
    # here.
    printf '%s\n' "${REG_MARKER}" "${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli --force "${rmother}")" && rc=0 || rc=$?
    assert_msg MSG-S6Q5 "${out}" "ai-tools.projects.remove.inplace has no --force, refused ahead of classification"
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmother}" ]]; then
        pass "ai-tools.projects.remove.inplace has no --force (an unregistered tree stays undeletable by it)"
    else
        fail "ai-tools.projects.remove.inplace accepted or mishandled --force (rc=${rc}): $(brief "${out}")"
    fi

    # The path is required with or without -y, so no run deletes whatever directory it started in. The refusal is
    # a rejected command line, exit 2.
    for remove_args in "" "-y"; do
        # shellcheck disable=SC2086  # the empty case does not pass an argument
        out="$(cd "${rmproj}" && remove_cli ${remove_args})" && rc=0 || rc=$?
        assert_msg MSG-K7D9 "${out}" "ai-tools.projects.remove.inplace ${remove_args:-without -y} refuses to inherit the current directory"
        if [[ ${rc} -eq 2 ]] && [[ -d "${rmproj}" ]]; then
            pass "ai-tools.projects.remove.inplace ${remove_args:-without -y} needs a path: exit 2, the project left in place"
        else
            fail "ai-tools.projects.remove.inplace ${remove_args:-without -y} did not require a path (rc=${rc}): $(brief "${out}")"
        fi
    done

    # And the property the whole gate exists for: a registered project, correctly targeted, is still NOT deleted without
    # a terminal -- the confirm takes its No default and the challenge has no default to take. The allowlist entry must
    # survive too, since the registries are torn down before the deletion.
    out="$(remove_cli "${rmproj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmproj}" ]] && grep -qF "${rmproj}" "${rmal}"; then
        pass "ai-tools.projects.remove.inplace deletes nothing with no terminal (confirm and challenge both decline)"
    else
        fail "ai-tools.projects.remove.inplace acted without a terminal (rc=${rc}, dir gone or de-registered): $(brief "${out}")"
    fi

    # The verb does not run git over the tree. .git/config is the agent's to write, and a ref read as the operator
    # that meets a missing object fetches it from a promisor remote with the transport that file names -- so the fixture
    # has the exploit's shape: a partial clone whose HEAD object is gone and whose core.sshCommand writes a marker.
    # The control makes that read directly and shows the marker appear; the verb, run to its no-terminal decline, leaves
    # it absent. Runtime half alone: the agent writing .git/config is reachable by design (cli.rule.md, Remove).
    rmrepo="${rmwork}/rm-repo"; mkdir -p "${rmrepo}"
    if git -C "${rmrepo}" init -q 2>/dev/null \
            && git -C "${rmrepo}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one 2>/dev/null; then
        rmmarker="${rmwork}/git-ran"
        printf 'touch %s\nexit 1\n' "${rmmarker}" > "${rmwork}/ssh-stub"
        rmhead="$(git -C "${rmrepo}" rev-parse HEAD)"
        git -C "${rmrepo}" update-ref refs/remotes/origin/main "${rmhead}"
        git -C "${rmrepo}" config remote.origin.url ssh://nowhere.invalid/up
        git -C "${rmrepo}" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
        git -C "${rmrepo}" config remote.origin.promisor true
        git -C "${rmrepo}" config remote.origin.partialclonefilter blob:none
        git -C "${rmrepo}" config extensions.partialClone origin
        git -C "${rmrepo}" config core.sshCommand "bash ${rmwork}/ssh-stub"
        git -C "${rmrepo}" branch --set-upstream-to=origin/main >/dev/null 2>&1
        rm -f "${rmrepo}/.git/objects/${rmhead:0:2}/${rmhead:2}"
        chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmrepo}" "${rmwork}/ssh-stub"
        runuser -u "${PROJECTS_USER}" -- git -C "${rmrepo}" rev-list --count '@{u}..HEAD' >/dev/null 2>&1 || true
        if [[ -e "${rmmarker}" ]]; then
            pass "control: a rev-list over the armed clone runs the configured transport"
            rm -f "${rmmarker}"
            printf '%s\n' "${REG_MARKER}" "${rmrepo}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
            out="$(remove_cli "${rmrepo}")" && rc=0 || rc=$?
            if [[ ! -e "${rmmarker}" ]] && [[ -d "${rmrepo}" ]]; then
                pass "ai-tools.projects.remove.inplace runs no git over the tree (the configured transport did not run)"
            else
                fail "ai-tools.projects.remove.inplace ran git over the tree (marker present: $([[ -e "${rmmarker}" ]] && echo yes || echo no), rc=${rc}): $(brief "${out}")"
            fi
        else
            fail "control: the armed clone did not run the configured transport, so the case proves nothing"
        fi
    else
        skip "ai-tools.projects.remove.inplace runs no git over the tree" "git unavailable"
    fi

    # The deletability pre-flight, which is what keeps a removal from stopping partway. A directory the acting owner can
    # neither write nor enter is the realistic blocker (a sandbox-owned 0700 left by a session), and it must refuse
    # the WHOLE removal up front with the tree still intact -- not delete as far as it can and report a failure.
    if id nobody >/dev/null 2>&1; then
        rmblocked="${rmwork}/rm-blocked"; mkdir -p "${rmblocked}/locked"
        chown "${PROJECTS_USER}:${PROJECTS_USER}" "${rmblocked}"
        chown nobody:nobody "${rmblocked}/locked"; chmod 0700 "${rmblocked}/locked"
        printf '%s\n' "${REG_MARKER}" "${rmblocked}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
        out="$(remove_cli -y "${rmblocked}")" && rc=0 || rc=$?
        if [[ ${rc} -ne 0 ]] && [[ -d "${rmblocked}/locked" ]] \
                && grep -qF -- "$(cli_cmd_text ai-tools.projects.handback) $(cli_flag full)" <<<"${out}" \
                && grep -qF "${rmblocked}" "${rmal}"; then
            pass "ai-tools.projects.remove.inplace refuses an undeletable tree up front, intact and still registered"
        else
            fail "ai-tools.projects.remove.inplace did not stop on the deletability pre-flight (rc=${rc}): $(brief "${out}")"
        fi
    else
        skip "ai-tools.projects.remove.inplace deletability pre-flight" "user 'nobody' not present"
    fi

    # AI_TOOLS_ASSUME_YES MUST NOT DELETE ANYTHING. This is the highest-consequence property the verb has
    # and the easiest to regress: the variable is a legitimate thing for an operator to export for unattended runs
    # of every other command, and if it reached either of this verb's two questions it would silently delete whole
    # projects on a host where nobody typed -y. It cannot: the confirm's default is NO (the lib only fast-tracks
    # default-YES questions) and the challenge has no default at all. Asserted with the variable set AND a terminal
    # absent, which is exactly how an unattended run arrives.
    printf '%s\n' "${REG_MARKER}" "${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    spell ai-tools.projects.remove.inplace
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${rmal}" \
            AI_TOOLS_ASSUME_YES=1 \
            setsid "${CLI}" "${CLI_ARGV[@]}" "${rmproj}" 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmproj}" ]] && grep -qF "${rmproj}" "${rmal}"; then
        pass "AI_TOOLS_ASSUME_YES does not delete a project (neither prompt is fast-trackable)"
    else
        fail "AI_TOOLS_ASSUME_YES deleted or deregistered a project (rc=${rc}): $(brief "${out}")"
    fi

    # A protected path as the removal target: exit 3, whatever the allowlist says. The scenario is an operator (or
    # a script) reaching for a home root or a system directory -- the allowlist is hand-editable, so the backstop has
    # to stand on its own. Both are driven with -y, the only mode that can reach a deletion unattended, and the entry is
    # planted deliberately so the classification would otherwise ACCEPT the target. The home case is included only
    # in the /home/<user> shape the home-root rule covers by construction. Elsewhere it is skipped rather than assumed:
    # this drives -y against a planted entry, so a host where the assumption did not hold would be pointing a real
    # removal at a real home. /etc is on the protected list unconditionally.
    _protected_targets=(/etc)
    [[ "${PROJECTS_HOME}" =~ ^/home/[^/]+$ ]] && _protected_targets+=("${PROJECTS_HOME}")
    for _bad in "${_protected_targets[@]}"; do
        printf '%s\n' "${REG_MARKER}" "${_bad}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
        out="$(remove_cli -y "${_bad}")" && rc=0 || rc=$?
        if [[ ${rc} -eq 3 ]] && [[ -d "${_bad}" ]]; then
            pass "ai-tools.projects.remove.inplace refuses the protected path ${_bad} (exit 3) even when listed"
        else
            fail "ai-tools.projects.remove.inplace did not refuse protected ${_bad} with exit 3 (rc=${rc}): $(brief "${out}")"
        fi
    done

    # -y must not bypass the classification. The scripted-removal mistake is a -y run pointed at a path that is not
    # a claimed project; the flag pre-answers the two prompts alone.
    printf '%s\n' "${REG_MARKER}" "${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli -y "${rmother}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmother}" ]]; then
        pass "-y does not bypass the registry check (an unlisted path is still refused)"
    else
        fail "-y deleted an unregistered path (rc=${rc}): $(brief "${out}")"
    fi

    # A parent the acting owner cannot write must REFUSE, and this is the case with the worst failure mode if it is
    # missed: `rm -rf` needs write permission on the directory it unlinks the project FROM, not on the project, so rm
    # descends, deletes every file successfully, and fails only on the top directory -- leaving an empty husk that is
    # already deregistered. The fixture is a project owned by the operator directly inside the root-owned testdir,
    # which is exactly that shape. Both the tree AND its contents must survive.
    rmpar="${TESTDIR}/rm-parent"; mkdir -p "${rmpar}/sub"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmpar}"
    printf '%s\n' "${REG_MARKER}" "${rmpar}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli -y "${rmpar}")" && rc=0 || rc=$?
    # By code: the unwritable-parent refusal (MSG-H3F6), raised before the walk begins.
    assert_msg MSG-H3F6 "${out}" "ai-tools.projects.remove.inplace refuses an unwritable parent"
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmpar}/sub" ]] \
            && grep -qF "${rmpar}" "${rmal}"; then
        pass "ai-tools.projects.remove.inplace deleted none of the tree and kept the entry"
    else
        fail "ai-tools.projects.remove.inplace did not refuse an unwritable parent (rc=${rc}, contents gone: $([[ -d "${rmpar}/sub" ]] && echo no || echo yes)): $(brief "${out}" 'parent directory')"
    fi

    # A registry the removal cannot rewrite must REFUSE, not delete. The allowlist entry is the agent's launch gate,
    # so deleting the tree past a failed de-registration would strand a registration that is still standing -- exactly
    # what this verb's teardown order exists to prevent. The fixture puts the allowlist in the ROOT-owned testdir:
    # `sed -i` writes its temporary file into the file's own directory, so the rewrite fails while the file itself stays
    # writable, which is also how this fails on a real host.
    rmstuck="${rmwork}/rm-stuck"; mkdir -p "${rmstuck}"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmstuck}"
    stuckal="${TESTDIR}/stuck-allowlist"
    printf '%s\n' "${REG_MARKER}" "${rmstuck}" > "${stuckal}"; chown "${PROJECTS_USER}" "${stuckal}"
    spell ai-tools.projects.remove.inplace
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${stuckal}" \
            setsid "${CLI}" "${CLI_ARGV[@]}" -y "${rmstuck}" 2>&1)" && rc=0 || rc=$?
    assert_msg MSG-K8S2 "${out}" "ai-tools.projects.remove.inplace refuses to delete when the allowlist entry cannot be removed"
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmstuck}" ]]; then
        pass "ai-tools.projects.remove.inplace refuses to delete when the allowlist entry cannot be removed"
    else
        fail "ai-tools.projects.remove.inplace acted past a failed de-registration (rc=${rc}): $(brief "${out}")"
    fi

    # Teardown order: registries before the tree. Driven with -y, which is the one path that reaches the deletion
    # without a terminal, over a project that IS fully deletable. Both halves are asserted -- the tree is gone
    # AND the allowlist entry with it -- because the ordering guarantee is only meaningful if the deletion actually ran.
    rmgo="${rmwork}/rm-go"; mkdir -p "${rmgo}/sub"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmgo}"
    printf '%s\n' "${REG_MARKER}" "${rmgo}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    # The tree must be gone and deregistered. The exit status depends on the environment: on an enforcing host
    # the SELinux label removal needs a password this run cannot supply, so a cleanup step fails and the verb exits 1
    # while still having removed the project. Both are correct; what is asserted is that a run with failures does NOT
    # close on a success mark.
    out="$(remove_cli -y "${rmgo}")" && rc=0 || rc=$?
    if [[ ! -e "${rmgo}" ]] && ! grep -qF "${rmgo}" "${rmal}" \
            && { [[ ${rc} -eq 0 ]] \
                 || { [[ ${rc} -eq 1 ]] && grep -qxF -- MSG-S6V2 <<<"${out}"; }; }; then
        pass "ai-tools.projects.remove.inplace -y deregisters and then deletes (registries first, tree last)"
    else
        fail "ai-tools.projects.remove.inplace -y did not complete (rc=${rc}, dir exists: $([[ -e "${rmgo}" ]] && echo yes || echo no)): $(brief "${out}")"
    fi
    if grep -q '✓ removed' <<<"${out}" && grep -qxF -- MSG-S6V2 <<<"${out}"; then
        fail "the removal showed a success mark alongside failed cleanup: $(brief "${out}" 'removed|cleanup')"
    else
        pass "the removal reserves its success mark for a run with no failures"
    fi

    # (7) ai-tools.projects.list renders the reconciliation view deterministically over a FIXTURE allowlist + gitconfig
    # (AI_TOOLS_ALLOWLIST / AI_TOOLS_GITCONFIG), so it never reads the operator's real registry. Every entry class
    # and every Suggested-cleanup class is asserted. The stale and protected entries sit EARLY, so a passing
    # Maintenance/orphan assertion also proves the reconcile loop no longer aborts mid-list under set -e when a trailing
    # conditional returns 1.
    lst="${TESTDIR}/list"; mkdir -p \
        "${lst}/partial" "${lst}/eol-comment" "${lst}/quoted dir" \
        "${lst}/glob-parent" "${lst}/excluded-live" "${lst}/orphan" "${lst}/parked/child"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${lst}"
    lal="${TESTDIR}/list-allowlist"
    cat > "${lal}" <<EOF
${REG_MARKER}
# a header comment, ignored
${lst}/stale-gone
/etc
${lst}/partial
${lst}/eol-comment    # main repo
"${lst}/quoted dir"
!${lst}/excluded-live
!${lst}/excluded-stale-gone
%${lst}/parked
${lst}/parked/child
EOF
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lal}"
    lgc="${TESTDIR}/list-gitconfig"
    cat > "${lgc}" <<EOF
[safe]
	directory = ${lst}/partial
	directory = ${lst}/orphan
	directory = /opt/ai-tools
EOF
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lgc}"

    spell ai-tools.projects.list
    lout="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${lal}" \
            AI_TOOLS_GITCONFIG="${lgc}" "${CLI}" "${CLI_ARGV[@]}" 2>&1)" || true

    list_has()   { if grep -qF "$1" <<<"${lout}"; then pass "$2"; else fail "$2 -- missing from ai-tools.projects.list output"; fi; }
    list_lacks() { if grep -qF "$1" <<<"${lout}"; then fail "$2 -- unexpectedly present in ai-tools.projects.list output"; else pass "$2"; fi; }

    list_has "Maintenance"            "ai-tools.projects.list reaches its footer past an early stale+protected entry (no set -e truncation)"
    list_has "stale entry"            "ai-tools.projects.list flags a stale allow entry"
    list_has "protected system path"  "ai-tools.projects.list flags a protected system path (/etc)"
    list_has "listed but not fully claimed" "ai-tools.projects.list flags a listed-but-unclaimed project"
    list_has "parked"                 "ai-tools.projects.list renders a '%' line as a parked project"
    list_has "re-enable: atr projects enable ${lst}/parked" "ai-tools.projects.list names the re-enable of a parked project"
    list_has "blocked"                "ai-tools.projects.list notes a listed project under a park as blocked"
    list_has "safe.dir:yes"           "ai-tools.projects.list shows safe.dir:yes for an entry present in git safe.directory"
    list_has "${lst}/eol-comment"     "ai-tools.projects.list renders an entry carrying an end-of-line comment"
    list_has "${lst}/quoted dir"      "ai-tools.projects.list renders a quoted entry"
    # Only the gone exclusion is reconciled as stale; the live one is left alone.
    n_stale_excl="$(grep -cF 'stale carve-out' <<<"${lout}" || true)"
    if [[ "${n_stale_excl}" -eq 1 ]] && grep -qF "!${lst}/excluded-stale-gone" <<<"${lout}"; then
        pass "ai-tools.projects.list reconciles only the stale ! exclusion, leaving the live one alone"
    else
        fail "stale-exclusion count is ${n_stale_excl}, expected exactly 1 (the gone path)"
    fi

    # The removal command a stale line takes is one shell word per argument: a line carrying a quote, and one whose
    # comment carries one, each print a `sed` that `bash -n` accepts and that, run over a copy of the registry, deletes
    # that line alone; a plain stale path is the control.
    lal_q="${TESTDIR}/list-allowlist-quotes"
    printf '%s\n' "${REG_MARKER}" "${lst}/partial" "${lst}/O'Reilly" "${lst}/gone   # it's old" "${lst}/plain-gone" \
        > "${lal_q}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lal_q}"
    qout="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${lal_q}" \
            AI_TOOLS_GITCONFIG="${lgc}" "${CLI}" "${CLI_ARGV[@]}" 2>&1)" || true
    mapfile -t q_commands < <(grep -E '^[[:space:]]+sed -i ' <<<"${qout}" | sed 's/^[[:space:]]*//')
    q_deleted=()
    for q_command in "${q_commands[@]}"; do
        if ! bash -n <<<"${q_command}" 2>/dev/null; then
            fail "the removal command does not parse: ${q_command}"; continue
        fi
        q_words=(); eval "q_words=( ${q_command} )"
        cp -- "${lal_q}" "${TESTDIR}/list-allowlist-copy"
        sed -i "${q_words[2]}" "${TESTDIR}/list-allowlist-copy"
        mapfile -t q_gone < <(diff "${lal_q}" "${TESTDIR}/list-allowlist-copy" | sed -n 's/^< //p')
        if [[ "${q_words[3]}" == "${lal_q}" && ${#q_gone[@]} -eq 1 \
                && $(( $(wc -l < "${lal_q}") - 1 )) -eq $(wc -l < "${TESTDIR}/list-allowlist-copy") ]]; then
            q_deleted+=("${q_gone[0]}")
        else
            fail "the removal command '${q_command}' deleted ${#q_gone[@]} line(s) from ${q_words[3]:-?}"
        fi
    done
    q_want="${lst}/O'Reilly"$'\n'"${lst}/gone   # it's old"$'\n'"${lst}/plain-gone"
    if [[ "$(printf '%s\n' "${q_deleted[@]}" | sort)" == "$(sort <<<"${q_want}")" ]]; then
        pass "each stale line's removal command parses and deletes that line alone, a quote or a comment in it included"
    else
        fail "the removal commands deleted: $(printf '%s~' "${q_deleted[@]}") from ${#q_commands[@]} command(s)"
    fi

    # A glob on an allow line is a line the grammar refuses, so the listing refuses the whole file and names the line,
    # where it once listed the line as unusable.
    lal_glob="${TESTDIR}/list-allowlist-glob"
    printf '%s\n' "${REG_MARKER}" "${lst}/partial" "${lst}/glob-parent/*" > "${lal_glob}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lal_glob}"
    rc=0
    gout="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${lal_glob}" \
            AI_TOOLS_GITCONFIG="${lgc}" "${CLI}" "${CLI_ARGV[@]}" 2>&1)" || rc=$?
    if [[ "${rc}" -eq 1 ]] && grep -qF "glob-on-allow" <<<"${gout}"; then
        pass "ai-tools.projects.list refuses a registry with a glob on an allow line, naming the reason"
    else
        fail "ai-tools.projects.list over a glob allow line: rc ${rc}: $(brief "${gout}")"
    fi
    assert_msg MSG-B8U2 "${gout}" "the library's line names the refused line"
    assert_msg MSG-Y7K5 "${gout}" "and the CLI's refusal follows it"

    # Reverse reconciliation: exactly one orphaned safe.directory -- the listed entry (partial) and the control-plane
    # entry (/opt/ai-tools, a protected path) must NOT be flagged.
    list_has "git safe.directory with no allowlist entry" "ai-tools.projects.list flags an orphaned safe.directory"
    list_has "${lst}/orphan"          "ai-tools.projects.list names the orphaned safedir path"
    list_lacks "/opt/ai-tools"        "ai-tools.projects.list skips the control-plane safe.directory (protected, registered deliberately)"
    n_orphan="$(grep -cF 'git safe.directory with no allowlist entry' <<<"${lout}" || true)"
    if [[ "${n_orphan}" -eq 1 ]]; then
        pass "exactly one orphaned safedir (a listed entry and the control-plane entry are not flagged)"
    else
        fail "orphaned-safedir count is ${n_orphan}, expected 1"
    fi

    # (8) ai-tools.projects.handback and ai-tools.projects.lockdown refuse a path outside every claimed project,
    # up front (before the sudo prompt / any change) -- covered_by_project. ${lone} is not in the fixture allowlist.
    for key in ai-tools.projects.handback ai-tools.projects.lockdown; do
        spell "${key}"
        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" \
                setsid "${CLI}" "${CLI_ARGV[@]}" "${lone}" 2>&1)" && rc=0 || rc=$?
        refused "${key} refuses a path outside every claimed project" MSG-J3K5
    done

    # (9) One removal verb decides its kind from the path, so the clone-area root itself and a path outside the clone
    # area are the in-place kind and meet the registry gate (not a claimed project) BEFORE any `rm -rf`; a clone is
    # a direct child of the area, which neither is. A destructive verb is never aimed at the REAL clone area, even
    # to assert a refusal: the rows run against a fixture clone area through the AI_TOOLS_SANDBOX_ROOT override,
    # and skip on an installed CLI that predates it. The empty fixture registry keeps the operator's real one out
    # of the run, which the gate would refuse on its own while it is unmigrated.
    if ! grep -q 'AI_TOOLS_SANDBOX_ROOT' "${CLI}"; then
        skip "ai-tools.projects.remove.clone guards" "the installed ${CLI} predates the AI_TOOLS_SANDBOX_ROOT override; deploy the checkout first"
    else
        sroot="${TESTDIR}/sandbox-projects"; mkdir -p "${sroot}"
        chown "${PROJECTS_USER}:${PROJECTS_USER}" "${sroot}"
        spell ai-tools.projects.remove.clone
        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" AI_TOOLS_SANDBOX_ROOT="${sroot}" \
                setsid "${CLI}" "${CLI_ARGV[@]}" "${sroot}" 2>&1)" && rc=0 || rc=$?
        assert_msg MSG-P8Y8 "${out}" "the clone-area root is not a registered project, so its removal is refused"
        if [[ ${rc} -ne 0 ]] && [[ -d "${sroot}" ]]; then
            pass "the refused clone-area root is left in place"
        else
            fail "the clone-area root was not refused (rc=${rc}): ${out}"
        fi

        out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" AI_TOOLS_SANDBOX_ROOT="${sroot}" \
                setsid "${CLI}" "${CLI_ARGV[@]}" "${lone}" 2>&1)" && rc=0 || rc=$?
        refused "a path outside the clone area is not a registered project, so its removal is refused" MSG-P8Y8
    fi
fi

# ai-tools.stop: the CLI half only -- the option grammar and the two forms not being combinable. Both refusals land
# in the argument loop, BEFORE the sudo that reaches the root helper, so neither reaches a password prompt or signals
# anything. The helper's own enumeration and kill are covered in tests/unit/stop.sh and tests/integration/stop.sh;
# what this asserts is that the verb is dispatched at all and that a mistyped one is refused rather than passed through.
#
# THE EXACT CODE IS ASSERTED, not merely non-zero. cmd_stop propagates the helper's exit status, so these codes are
# a published contract (ai-tools(1), docs/sessions/stop.md): 2 is usage, and 1 already means "a process survived
# SIGKILL" -- a caller told 1 for a typo reads it as a failed kill. A `-ne 0` assertion cannot see that difference,
# and did not: the CLI refused through its own die (1) against a documented 2, and only the live drill, which pins
# the code, caught it.
if command -v runuser >/dev/null 2>&1; then
    section "ai-tools.stop (argument grammar)"
    spell ai-tools.stop
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" setsid \
            "${CLI}" "${CLI_ARGV[@]}" --bogus 2>&1)" && rc=0 || rc=$?
    refused "ai-tools.stop refuses an unknown option with the documented usage code (2)" MSG-B7K4 2
    # A path is refused BY THE CLI, before sudo. Accepting it would invert the operator's intent in the destructive
    # direction -- they typed a path to narrow the command, which terminates every session -- and the refusal must name
    # the alternative rather than dead-end them.
    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" setsid \
            "${CLI}" "${CLI_ARGV[@]}" /some/project 2>&1)" && rc=0 || rc=$?
    assert_msg MSG-A3M9 "${out}" "ai-tools.stop refuses a path"
    if [[ ${rc} -eq 2 ]] && grep -q '/exit' <<<"${out}"; then
        pass "ai-tools.stop refuses a path (rc=2) and names /exit as the way to end one session"
    else
        fail "ai-tools.stop accepted a path, or refused it without rc=2/guidance (rc=${rc}): ${out}"
    fi

    out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" setsid \
            "${CLI}" "${CLI_ARGV[@]}" "$(cli_flag all)" /some/project 2>&1)" && rc=0 || rc=$?
    refused "--all does not change which refusal a path gets (rc=2)" MSG-A3M9 2
fi

# --for <operator>: acting on another enrolled operator's registry. Every refusal here precedes the root helper
# entirely, so none of these reach a sudo prompt. The helper's own gates are asserted in tests/unit/allowlist-helper.sh;
# what this covers is the CLI deciding, up front, that a run must not proceed at all.
if command -v runuser >/dev/null 2>&1; then
    section "CLI --for (acting for another operator)"
    mktestdir
    chmod 755 "${TESTDIR}"
    fconf="${TESTDIR}/operator.conf"
    mk_operator_conf "${fconf}" "${PROJECTS_USER}"
    fproj="${TESTDIR}/forproj"; mkdir -p "${fproj}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${fproj}"
    fal="${TESTDIR}/for-allowlist"; printf '%s\n' "${REG_MARKER}" > "${fal}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${fal}"

    # setsid: every assertion in this section expects a refusal, and each must land BEFORE the gate's snapshot step,
    # which is a --for run's only sudo. Without a controlling terminal sudo cannot open /dev/tty to prompt (a stdin
    # redirect does not stop it) and fails at once, so a regression that let a refusal fall past the snapshot FAILS here
    # instead of hanging on a developer's password prompt -- the asymmetry being that a container with no tty would fail
    # while an interactive run stalls indefinitely. -w because setsid FORKS when it is already a process-group leader,
    # and the bare form then returns 0 rather than the command's status, which would quietly pass every rc-based
    # assertion in it. run_for <key> <args...>: the command the key names, as the operator, against the fixture
    # registry.
    run_for() {
        local -a argv
        cli_cmd "$1" || exit 2
        argv=("${CLI_ARGV[@]}"); shift
        runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${fconf}" AI_TOOLS_ALLOWLIST="${fal}" \
            setsid -w "${CLI}" "${argv[@]}" "$@" 2>&1
    }

    # (1) An unenrolled target is refused, naming the enrolment command. No entry may be written for a name
    # the ownership helpers cannot later resolve to an owner.
    out="$(run_for ai-tools.projects.claim --for definitely-not-an-operator "${fproj}")" && rc=0 || rc=$?
    # By code: the --for TARGET's enrolment gate (MSG-E3D2), not the invoker's (MSG-X6U2).
    refused "--for refuses an unenrolled target operator" MSG-E3D2
    if grep -q '^[^#]' "${fal}"; then
        fail "refused --for run still wrote to a registry: $(cat "${fal}")"
    else
        pass "refused --for run wrote no registry state"
    fi

    # (2) The sandbox account can never be a --for target: it would be the agent owning projects.
    out="$(run_for ai-tools.projects.claim --for "${SANDBOX_USER}" "${fproj}")" && rc=0 || rc=$?
    refused "--for refuses the sandbox account as the target, naming it" MSG-M3Z3

    # (3) Refused, not ignored, on a verb it does not apply to -- a clone that silently ran as the invoker would leave
    # the tree owned by the wrong operator with no output to show.
    out="$(run_for ai-tools.projects.clone --for "${PROJECTS_USER}" "${fproj}")" && rc=0 || rc=$?
    refused "--for is refused on a verb that does not accept it (not silently ignored)" MSG-U7R7

    # (4) --force binds an unlisted tree to the INVOKING uid inside ai-tools-unclaim, so honouring --for there would
    # have the CLI name one operator while the helper acted as another.
    out="$(run_for ai-tools.projects.unclaim --force --for "${PROJECTS_USER}" "${fproj}")" && rc=0 || rc=$?
    # By code: --for's own --force refusal (MSG-B5K3), not --keep-entry's (MSG-R3G9).
    refused "--for refuses to combine with ai-tools.projects.unclaim --force" MSG-B5K3

    # (5) A bare --for with no name is a parse error, not an empty operator silently meaning "me".
    out="$(run_for ai-tools.projects.claim --for)" && rc=0 || rc=$?
    refused "--for with no operator name is refused, ahead of every gate" MSG-B4G2
fi

# ── ai-tools.projects.disable / ai-tools.projects.enable: parking a project in place ─────────
# The pair edits ONE line of the operator's own allowlist and does not reach a root helper, so the whole lifecycle is
# drivable here as the projects user over the fixture registry. What is asserted is what the flat-file model rests
# on (the entry states, in cli.rule.md): the line is edited IN PLACE, a parked project is not an unlisted one,
# and neither verb ever invents an entry or lifts a '!' carve-out -- since lifting one hands the agent a subtree its
# operator withheld.
section "ai-tools.projects.disable / ai-tools.projects.enable"

if ! command -v runuser >/dev/null 2>&1; then
    skip "ai-tools.projects.disable / ai-tools.projects.enable" "runuser unavailable"
else
    mktestdir
    chmod 755 "${TESTDIR}"
    pd_conf="${TESTDIR}/op.conf"
    pd_al="${TESTDIR}/project-registry"
    pd_proj="${TESTDIR}/api"; pd_other="${TESTDIR}/web"
    pd_nested="${pd_proj}/service-a"; pd_carve="${pd_proj}/secrets"
    mkdir -p "${pd_proj}" "${pd_other}" "${pd_nested}" "${pd_carve}"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${TESTDIR}"
    # Written after the chown, so the fixture stays root's and the gate honours its AI_TOOLS_AGENTS line.
    mk_operator_conf "${pd_conf}" "${PROJECTS_USER}"

    # pd_cli <key> <args...> : run the command the key names as the operator against the fixture registry, under setsid
    # so every prompt takes its non-interactive default (the re-enable confirm defaults NO).
    pd_cli() {
        local -a argv
        cli_cmd "$1" || exit 2
        argv=("${CLI_ARGV[@]}"); shift
        runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${pd_conf}" AI_TOOLS_ALLOWLIST="${pd_al}" \
            setsid "${CLI}" "${argv[@]}" "$@" 2>&1
    }
    pd_seed() { printf '%s\n' "${REG_MARKER}" "$@" > "${pd_al}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${pd_al}"; }

    # (1) Park a listed project: the line keeps its position, indentation and comment. That is the whole reason these
    # verbs exist rather than being an unclaim/claim pair -- an operator whose registry is an ordered, commented
    # document gets it back unchanged.
    pd_seed "# projects" "  ${pd_proj}   # payments, dev stage" "${pd_other}"
    pd_before="$(cat "${pd_al}")"
    out="$(pd_cli ai-tools.projects.disable "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && [[ "$(sed -n '3p' "${pd_al}")" == "  %${pd_proj}   # payments, dev stage" ]]; then
        pass "ai-tools.projects.disable parks the entry in place, keeping position and comment"
    else
        fail "ai-tools.projects.disable did not park the entry (rc=${rc}): $(brief "${out}")"
    fi
    if grep -qi 'handback' <<<"${out}"; then
        pass "the disable states the consequence an operator has to know (the handback stops)"
    else
        fail "the disable did not mention the ownership handback: $(brief "${out}")"
    fi

    # (2) A parked project is NOT an unlisted one. The claim must not append a second, positive line that the '%' would
    # go on winning over -- it offers the re-enable, which with no terminal takes its default NO, and refuses.
    out="$(pd_cli ai-tools.projects.claim "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'disabled' <<<"${out}"; then
        pass "ai-tools.projects.claim over a parked project refuses instead of claiming"
    else
        fail "ai-tools.projects.claim did not refuse over a parked project (rc=${rc}): $(brief "${out}")"
    fi
    if [[ "$(grep -cF "${pd_proj}" "${pd_al}")" == 1 ]]; then
        pass "the refused claim appended no duplicate line"
    else
        fail "the refused claim duplicated the entry:"$'\n'"$(cat "${pd_al}")"
    fi

    # (3) ai-tools.projects.list calls it what it is, and names the verb that restores it.
    out="$(pd_cli ai-tools.projects.list)" || true
    if grep -qE "parked[[:space:]]+${pd_proj}" <<<"${out}" \
            && grep -qF -- "$(cli_cmd_text ai-tools.projects.enable) ${pd_proj}" <<<"${out}"; then
        pass "ai-tools.projects.list reports a parked project as parked, with the re-enable command"
    else
        fail "ai-tools.projects.list did not report the parked project: $(brief "${out}" 'parked|exclude')"
    fi

    # (4) Restore it: the file comes back byte-identical to before the park.
    out="$(pd_cli ai-tools.projects.enable "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && [[ "$(cat "${pd_al}")" == "${pd_before}" ]]; then
        pass "ai-tools.projects.enable restores the file byte-identically (a lossless round trip)"
    else
        fail "ai-tools.projects.enable did not restore the file (rc=${rc}): $(brief "${out}")"$'\n'"$(cat "${pd_al}")"
    fi

    # (5) Neither verb invents an entry. Registering a project is a claim -- it scans for secrets before granting access
    # -- so a path the file does not name is refused by both, pointing there. The path does not hold a registered
    # project, since an ancestor of one is refused naming its projects rather than the claim.
    pd_lone="${TESTDIR}/unlisted"; mkdir -p "${pd_lone}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${pd_lone}"
    for key in ai-tools.projects.disable ai-tools.projects.enable; do
        out="$(pd_cli "${key}" "${pd_lone}")" && rc=0 || rc=$?
        assert_msg MSG-T4A8 "${out}" "${key} refuses through the pair's shared no-entry refusal"
        if [[ ${rc} -ne 0 ]] && grep -qF -- "$(cli_cmd_text ai-tools.projects.claim)" <<<"${out}"; then
            pass "${key} refuses an unregistered path and names the claim"
        else
            fail "${key} did not refuse an unregistered path (rc=${rc}): $(brief "${out}")"
        fi
    done
    if [[ "$(cat "${pd_al}")" == "${pd_before}" ]]; then
        pass "both refusals left the registry untouched"
    else
        fail "a refusal wrote to the registry:"$'\n'"$(cat "${pd_al}")"
    fi

    # (6) A CARVE-OUT is not a parked project, and lifting one would WIDEN what the agent reaches -- a subtree its
    # operator withheld from a claimed project. It is refused, and the refusal names the line.
    pd_seed "# projects" "${pd_proj}" "!${pd_carve}"
    out="$(pd_cli ai-tools.projects.enable "${pd_carve}")" && rc=0 || rc=$?
    # By code: the carve-out refusal (MSG-W4S7), not the no-entry one (MSG-T4A8).
    refused "ai-tools.projects.enable refuses a carve-out rather than handing over the subtree" MSG-W4S7
    if grep -qF "!${pd_carve}" "${pd_al}"; then
        pass "the carve-out line survived the refusal"
    else
        fail "the refused enable deleted the carve-out:"$'\n'"$(cat "${pd_al}")"
    fi

    # (7) A NESTED project parks like any other: the kind is in the line, so its '%' cannot be read as a carve-out.
    pd_seed "# projects" "${pd_proj}" "${pd_nested}"
    out="$(pd_cli ai-tools.projects.disable "${pd_nested}")" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && grep -qxF "%${pd_nested}" "${pd_al}" && grep -qxF "${pd_proj}" "${pd_al}"; then
        pass "ai-tools.projects.disable parks a project nested inside another, the enclosing one listed"
    else
        fail "ai-tools.projects.disable did not park the nested project (rc=${rc}): $(brief "${out}")"$'\n'"$(cat "${pd_al}")"
    fi

    # (8) The per-project verbs must not call a parked project unclaimed: on an excluded path the root helpers resolve
    # no owner and act on NO PATH, so a run that got that far would report steps it never applied. (A host may also
    # refuse earlier for a missing sudo grant -- that is a different, correct refusal; what must not appear is "not
    # a claimed project".)
    pd_seed "# projects" "%${pd_proj}"
    for key in ai-tools.projects.handback ai-tools.projects.lockdown ai-tools.projects.unclaim; do
        out="$(pd_cli "${key}" "${pd_proj}")" && rc=0 || rc=$?
        if [[ ${rc} -ne 0 ]] && ! grep -qi 'not a claimed project' <<<"${out}"; then
            pass "${key} over a parked project does not report it as unclaimed"
        else
            fail "${key} called a parked project unclaimed (rc=${rc}): $(brief "${out}")"
        fi
    done

    # (9) ai-tools.projects.remove.inplace's AUTHORIZATION is the exact entry, and a parked one counts: the '%' records
    # "not right now", not "not mine", and making the operator re-enable a tree they mean to delete would make it
    # launchable on the way out. So the verb must get past classification -- reaching its own disabled confirm -- rather
    # than refusing as unregistered. It must also delete NO PATH here: with no terminal the confirm and the typed-name
    # challenge both decline, which is the property that keeps a destructive verb out of an unattended run.
    out="$(pd_cli ai-tools.projects.remove.inplace "${pd_proj}")" && rc=0 || rc=$?
    if grep -qi 'not a claimed project' <<<"${out}"; then
        fail "ai-tools.projects.remove.inplace refused a parked project as unregistered: $(brief "${out}")"
    elif grep -qxE 'MSG-R4J2|MSG-Z6Q6' <<<"${out}"; then
        # A host whose operator does not hold a general sudo grant refuses ahead of classification. That is a different,
        # correct refusal, and it is not what this case is about.
        skip "ai-tools.projects.remove.inplace over a parked project" "no sudo grant for the removal helper here"
    elif [[ ${rc} -ne 0 ]] && grep -qi 'disabled' <<<"${out}"; then
        pass "ai-tools.projects.remove.inplace accepts a parked entry as authorization and names the parked state"
    else
        fail "ai-tools.projects.remove.inplace did not recognise the parked entry (rc=${rc}): $(brief "${out}")"
    fi
    if [[ -d "${pd_proj}" ]]; then
        pass "the declined removal deleted nothing (no terminal answers both prompts NO)"
    else
        fail "ai-tools.projects.remove.inplace deleted a project with no terminal to confirm at"
    fi

    # (10) --keep-entry is about what becomes of an ENTRY, so it is refused where there is none to keep: --force is
    # the mode that reaches a tree the allowlist does not name. Refused rather than ignored, since a flag that silently
    # skips its work is how an operator learns the wrong model.
    out="$(pd_cli ai-tools.projects.unclaim "$(cli_flag keep-entry)" "$(cli_flag force)" "${pd_proj}")" && rc=0 || rc=$?
    if grep -qxE 'MSG-R4J2|MSG-Z6Q6' <<<"${out}"; then
        # Either no-sudo-grant refusal: an environment fact, reached before the parse check.
        skip "--keep-entry with --force" "no sudo grant for the unclaim helper here"
    elif (( rc != 0 )); then
        # By code: --keep-entry's own --force refusal (MSG-R3G9), not --for's (MSG-B5K3).
        assert_msg MSG-R3G9 "${out}" "--keep-entry with --force is refused (there is no entry to keep)"
    else
        fail "--keep-entry --force was not refused (rc=${rc}): $(brief "${out}")"
    fi

    # (10b) --keep-entry belongs to the unclaim ALONE. A removal deletes the tree, so an entry kept for it would park
    # a path that no longer exists -- and the flag reads as though it might spare something, which is the worst thing
    # a flag can suggest on a destructive verb. Refused as an unknown option rather than silently ignored.
    out="$(pd_cli ai-tools.projects.remove.inplace "$(cli_flag keep-entry)" "${pd_proj}")" && rc=0 || rc=$?
    # By code: the unknown-option refusal (MSG-M3Y5), not a --keep-entry special case.
    refused "ai-tools.projects.remove.inplace refuses --keep-entry (it belongs to the unclaim)" MSG-M3Y5
    if [[ -d "${pd_proj}" ]]; then
        pass "the refused option deleted nothing"
    else
        fail "ai-tools.projects.remove.inplace deleted the project while refusing an option"
    fi

    # (11) An entry can be clean and the project still unreachable, because a carve-out, a park or a glob covers it
    # from an ancestor. Entry state and reachability are different questions, and reporting the first as though it
    # answered the second sends an operator hunting through their own file for a refusal the CLI already knew about.
    pd_seed "# projects" "${pd_proj}" "!${TESTDIR}"
    out="$(pd_cli ai-tools.projects.enable "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && grep -qi 'already enabled' <<<"${out}" \
            && grep -qF "!${TESTDIR}" <<<"${out}"; then
        pass "ai-tools.projects.enable reports the OTHER line that still covers a listed project"
    else
        fail "ai-tools.projects.enable did not name the blocking ancestor exclusion (rc=${rc}): $(brief "${out}" 'enabled|exclusion')"
    fi
fi

# ── ai-tools.audit: the reader for the refusal trails ────────────────────────────────────────
# Driven against the deployed helper directly rather than through ai-tools.audit, because the CLI reaches it via sudo
# with no NOPASSWD rule and would prompt for a password. The helper is where every decision lives (the CLI is
# a pass-through that propagates its exit status), and AI_TOOLS_LOG_DIR -- the same root-only hook the harness already
# uses -- points it at a seeded throwaway trail instead of the production one. Root-only, so this needs the suite's
# root.
section "ai-tools.audit reads the refusal trails"
audit_bin=/usr/local/libexec/ai-tools/ai-tools-audit
if [[ ! -x "${audit_bin}" ]]; then
    skip "ai-tools.audit" "${audit_bin} not installed"
else
    audit_dir="${TESTDIR}/audit-trail"
    mkdir -p "${audit_dir}"
    audit_now="$(date -Is)"
    audit_old="$(date -Is -d '30 days ago')"
    # One finding per level that counts, one INFO that must not, and one line older than any window this test asks for.
    {
        printf '%s INFO    [1] restored ownership of /tmp/x (routine, must NOT be reported)\n' "${audit_now}"
        printf '%s NOTICE  [1] NOTICE: secret-named file written by agent considered breached: /p/.env\n' "${audit_now}"
        printf '%s ERROR   [1] AUDIT-OLD-MARKER outside every window under test\n' "${audit_old}"
    } > "${audit_dir}/chown.log"
    printf '%s WARNING [2] rejected peer uid=1234 (not the sandbox account)\n' "${audit_now}" \
        > "${audit_dir}/handback.log"

    # (1) Findings present -> reported, at exit 4, the code ai-tools-records(5) gives a report that read every
    #     source and found something, so cron and /etc/profile.d act on it without parsing the output. This run
    #     reads the host's real journal and audit log beside the seeded trail, so a 5 here is one of those sources
    #     failing to read on this host -- a finding about the host, reported as such.
    out="$(AI_TOOLS_LOG_DIR="${audit_dir}" "${audit_bin}" --since '2 days ago' 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -eq 4 ]] && grep -q 'breached' <<<"${out}" && grep -q 'rejected peer' <<<"${out}"; then
        pass "ai-tools.audit reports findings from every root-only log and exits 4"
    else
        fail "ai-tools.audit did not report the seeded findings at exit 4 (rc=${rc}): ${out}"
    fi

    # (2) Severity is the selector, so routine INFO churn must not surface. An audit command
    #     that reports every ownership restore is one an operator stops reading.
    if grep -q 'must NOT be reported' <<<"${out}"; then
        fail "ai-tools.audit reported an INFO line -- the severity floor is not being applied"
    else
        pass "ai-tools.audit reports NOTICE and above only (routine INFO churn stays out)"
    fi

    # (3) The window is honoured: a finding older than --since is out of scope.
    if grep -q 'AUDIT-OLD-MARKER' <<<"${out}"; then
        fail "ai-tools.audit reported a finding older than --since -- the window is not applied"
    else
        pass "ai-tools.audit honours --since (an older finding is out of the window)"
    fi

    # (3b) Repeats collapse, and severity leads. This is what makes the command usable rather
    #      than merely correct: a recurring condition writes one line per occurrence -- the
    #      handback daemon's refusals run to hundreds over a week on a host that exercises them
    #      -- and an uncollapsed report buries the one ERROR that needs acting on. Seed a
    #      recurring warning that differs only in its pid, alongside a single ERROR, and assert
    #      the report folds the first and leads with the second.
    for audit_pid in 111 222 333 444; do
        printf '%s WARNING [%d] rejected malformed arg for CHOWN (pid %d)\n' \
            "${audit_now}" "${audit_pid}" "${audit_pid}" >> "${audit_dir}/handback.log"
    done
    printf '%s ERROR   [9] AUDIT-REAL-FINDING that must not be buried\n' "${audit_now}" \
        > "${audit_dir}/relabel.log"
    out="$(AI_TOOLS_LOG_DIR="${audit_dir}" "${audit_bin}" --since '2 days ago' 2>&1)" || true

    if [[ "$(grep -c 'rejected malformed arg' <<<"${out}")" == 1 ]] \
            && grep -qE '4x +rejected malformed arg' <<<"${out}"; then
        pass "ai-tools.audit collapses a repeated finding into one line carrying its count"
    else
        fail "ai-tools.audit did not collapse the four repeats of one finding: ${out}"
    fi

    # The ERROR must be the first finding printed -- an operator reads the top of a report.
    if [[ "$(grep -E '^\s+(ERROR|WARNING|NOTICE)\s' <<<"${out}" | head -1)" == *AUDIT-REAL-FINDING* ]]; then
        pass "ai-tools.audit leads with the most severe finding, ahead of recurring noise"
    else
        fail "ai-tools.audit did not lead with the ERROR: $(grep -E '^\s+(ERROR|WARNING|NOTICE)\s' <<<"${out}" | head -3)"
    fi

    # (4) A clean window exits zero, so a healthy host does not alarm every night. This is also where the host's own
    #     journalctl answers a query with no matching entry: the helper reads a non-zero exit there as a source it could
    #     not read (exit 5), so a 5 on a healthy host is the documented rule failing on this host's systemd.
    out="$(AI_TOOLS_LOG_DIR="${audit_dir}" "${audit_bin}" --since '+1 hour' 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && grep -qi 'nothing refused' <<<"${out}"; then
        pass "ai-tools.audit exits zero and says so when the window holds no findings"
    else
        fail "ai-tools.audit did not report a clean window (rc=${rc}): ${out}"
    fi

    # (4b) A log directory that does not exist is a reading the helper could not make: exit 5 and the directory named,
    #      and no clean headline. Driven on the deployed helper as root, where the unexpanded glob once read
    #      as an empty trail.
    out="$(AI_TOOLS_LOG_DIR="${audit_dir}/absent" "${audit_bin}" --since '2 days ago' 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -eq 5 ]] && grep -q 'does not exist' <<<"${out}" && ! grep -qi 'nothing refused' <<<"${out}"; then
        pass "ai-tools.audit exits 5 and names a log directory it could not read"
    else
        fail "ai-tools.audit over a missing log directory (rc=${rc}): ${out}"
    fi

    # (5) An unparseable --since is REFUSED, never widened to "everything": a typo that silently
    #     reported all of history would read as a catastrophe, and one that silently reported
    #     an empty result would read as all-clear. Both are worse than an error.
    out="$(AI_TOOLS_LOG_DIR="${audit_dir}" "${audit_bin}" --since 'not a date' 2>&1)" && rc=0 || rc=$?
    refused "ai-tools.audit refuses a --since value date(1) cannot parse" MSG-Y3M7
    #     The convenience emitters bake their descriptor in, so a descriptor passed as the
    #     first argument would print as a bare digit on the line ABOVE the refusal.
    if grep -qxE '[0-9]' <<<"${out}"; then
        fail "ai-tools.audit printed a bare digit line above its refusal: $(head -2 <<<"${out}")"
    else
        pass "ai-tools.audit's refusal is not preceded by a stray descriptor line"
    fi

    # (6) The DEPLOYED CLI reaches the helper. (1)-(5) drive the helper directly, so no case so
    #     far would notice a verb that was never wired into the dispatch. Asserted through the
    #     help text rather than by running the verb, which sudo-prompts (no NOPASSWD rule).
    #     The usage()/man-page pairing itself is covered from source in unit/man.sh; what this
    #     adds is that the copy actually installed on this host carries it -- which is why it
    #     SKIPS rather than fails when the deployed CLI predates the verb. That is the normal
    #     state between building this branch and installing it, and it is not a defect. The help
    #     is read AS the projects user: the CLI refuses root before it prints anything, so a root
    #     read would report every deployed copy as predating the verb.
    if [[ ! -x "${CLI}" ]]; then
        skip "ai-tools.audit is wired into the CLI" "not installed at ${CLI}"
    elif ! command -v runuser >/dev/null 2>&1; then
        skip "ai-tools.audit is wired into the CLI" "runuser unavailable to read the help as ${PROJECTS_USER}"
    elif spell ai-tools.help && runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" "${CLI}" "${CLI_ARGV[@]}" 2>&1 \
            | grep -qF -- "$(cli_cmd_text ai-tools.audit)"; then
        pass "the deployed CLI dispatches ai-tools.audit"
    else
        skip "ai-tools.audit is wired into the CLI" "the deployed ${CLI} predates the verb (install this version to cover it)"
    fi
fi

finish

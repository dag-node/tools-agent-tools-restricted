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
        # An operator's help request is rendered by atr from the installed help library, with no sudo call.
        printf '0\n' > "${shim_dir}/status"
        rm -f "${shim_dir}/argv"
        rc=0
        out="$(runuser -u "${PROJECTS_USER}" -- env -i HOME="${PROJECTS_HOME}" PATH="${shim_dir}:/usr/bin:/bin" \
            "${ATR}" admin --help 2>/dev/null)" || rc=$?
        if [[ "${rc}" == 0 && "${out}" == *"Agent Tools Restricted -- host administration (ai-tools-admin)"* \
              && ! -e "${shim_dir}/argv" ]]; then
            pass "the installed atr admin --help prints the admin help as ${PROJECTS_USER} with no sudo call"
        else
            fail "the installed atr admin --help: rc=${rc} sudo called=$([[ -e "${shim_dir}/argv" ]] && echo yes || echo no) stdout=[${out}]"
        fi
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
    # Every registry write renames a whole file into the registry's own directory, so the fixture's directory is
    # the operator's, as ~/.config/ai-tools is.
    emptyal_dir="${TESTDIR}/empty-registry"; mkdir -p "${emptyal_dir}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${emptyal_dir}"
    emptyal="${emptyal_dir}/project-registry"; printf '%s\n' "${REG_MARKER}" > "${emptyal}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${emptyal}"

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
    if grep -qF 'Agent Tools Restricted -- operator commands (ai-tools)' <<<"${out}"; then
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
    refused "ai-tools.projects.create refuses to run without a path" MSG-A7D3 2

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
    if grep -qxF "@ ${newproj}" "${emptyal}"; then
        pass "ai-tools.projects.create registers the new project in the project registry"
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
    # Matched on the refusal's codes, not on the phrase "owner-only": the create prints that phrase itself when it
    # explains the modes it set on a umask-077 host, so a looser grep asserts the opposite of what it means on exactly
    # the hosts this case exists for.
    if ! grep -qxE 'MSG-(H6J3|B5D2)' <<<"${out}"; then
        pass "the claim does not refuse the new project as owner-only"
    else
        fail "the created project was refused as owner-only: $(brief "${out}" 'owner-only')"
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
    printf '%s\n' "${REG_MARKER}" "@ ${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
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
    printf '%s\n' "${REG_MARKER}" "@ ${rmproj}" "@ ${rmnested}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
    out="$(remove_cli "${rmproj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && [[ -d "${rmnested}" ]] && grep -qF "${rmnested}" <<<"${out}"; then
        pass "ai-tools.projects.remove.inplace refuses a project containing another claimed project, naming it"
    else
        fail "ai-tools.projects.remove.inplace did not refuse a project with a nested claim (rc=${rc}): $(brief "${out}")"
    fi
    assert_msg MSG-Q3R9 "${out}" "the refusal is the registered-entry-contains-projects one"

    # There is no --force: the flag that reaches an unregistered tree on unclaim must not become a way to delete one
    # here.
    printf '%s\n' "${REG_MARKER}" "@ ${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
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
            printf '%s\n' "${REG_MARKER}" "@ ${rmrepo}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
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
        printf '%s\n' "${REG_MARKER}" "@ ${rmblocked}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
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
    printf '%s\n' "${REG_MARKER}" "@ ${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
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
        printf '%s\n' "${REG_MARKER}" "@ ${_bad}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
        out="$(remove_cli -y "${_bad}")" && rc=0 || rc=$?
        if [[ ${rc} -eq 3 ]] && [[ -d "${_bad}" ]]; then
            pass "ai-tools.projects.remove.inplace refuses the protected path ${_bad} (exit 3) even when listed"
        else
            fail "ai-tools.projects.remove.inplace did not refuse protected ${_bad} with exit 3 (rc=${rc}): $(brief "${out}")"
        fi
    done

    # -y must not bypass the classification. The scripted-removal mistake is a -y run pointed at a path that is not
    # a claimed project; the flag pre-answers the two prompts alone.
    printf '%s\n' "${REG_MARKER}" "@ ${rmproj}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
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
    printf '%s\n' "${REG_MARKER}" "@ ${rmpar}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
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
    printf '%s\n' "${REG_MARKER}" "@ ${rmstuck}" > "${stuckal}"; chown "${PROJECTS_USER}" "${stuckal}"
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
    # The registry step precedes the safe.directory step, so the refused run does not report a safe.directory line.
    if grep -qF "safe.directory" <<<"${out}"; then
        fail "ai-tools.projects.remove.inplace reached the safe.directory step ahead of the refused registry step: $(brief "${out}" 'safe.directory')"
    else
        pass "ai-tools.projects.remove.inplace refuses at the registry step before the safe.directory step"
    fi

    # Teardown order: registries before the tree. Driven with -y, which is the one path that reaches the deletion
    # without a terminal, over a project that IS fully deletable. Both halves are asserted -- the tree is gone
    # AND the allowlist entry with it -- because the ordering guarantee is only meaningful if the deletion actually ran.
    rmgo="${rmwork}/rm-go"; mkdir -p "${rmgo}/sub"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmgo}"
    printf '%s\n' "${REG_MARKER}" "@ ${rmgo}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
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

    # A deletion that does not complete reports what the run verified and no more: the entry is removed, a session
    # already running keeps its access, and the files left keep their group grant, which the removal did not hand
    # back. `rm` is a stub first on the CLI's PATH, in a directory where a 0755 file is executable, that fails
    # the deletion of the one path its target file names and runs the real `rm` for every other call. The path carries
    # a space, so the printed remedy is the quoted one.
    rmstub=""
    mk_fixture_dir rmstub "${PROJECTS_HOME}" rm-stub 2>/dev/null || rmstub=""
    if [[ -z "${rmstub}" ]]; then
        skip_required "ai-tools.projects.remove over a deletion that fails" "no fixture directory beside ${PROJECTS_HOME}"
    else
        cat > "${rmstub}/rm" <<EOF
#!/bin/bash
[[ "\$1" == -rf && "\$2" == -- && "\$3" == "\$(< "${rmstub}/target")" ]] && exit 1
exec $(type -P rm) "\$@"
EOF
        chmod 0755 "${rmstub}" "${rmstub}/rm"
        # remove_left <path> <registry> [<env>...] : the removal of <path> with the failing `rm`; sets out and rc.
        remove_left() {
            local p="$1" reg="$2"; shift 2
            printf '%s' "${p}" > "${rmstub}/target"; chmod 0644 "${rmstub}/target"
            out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                    PATH="${rmstub}:/usr/local/bin:/usr/bin:/bin" \
                    AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${reg}" "$@" \
                    setsid "${CLI}" "${CLI_ARGV[@]}" -y "${p}" 2>&1)" && rc=0 || rc=$?
        }
        # left_reported <key> <path> <registry> : the assertions a failed deletion owes, for either kind.
        left_reported() {
            local key="$1" p="$2" reg="$3"
            if [[ ${rc} -eq 1 && -d "${p}" ]] && ! grep -qF -- "${p}" "${reg}"; then
                pass "${key} whose deletion fails exits 1 with the tree on disk and the entry removed"
            else
                fail "${key} over a failed deletion: rc=${rc}, on disk $([[ -d "${p}" ]] && echo yes || echo no): $(brief "${out}")"
            fi
            if grep -qF "registry entry is removed" <<<"${out}" && grep -qF "keep their group grant, which a removal does not hand back" <<<"${out}" \
                    && ! grep -qF "out of the agent's reach" <<<"${out}"; then
                pass "${key} reports the entry removed and the access left, and does not claim the tree is out of reach"
            else
                fail "${key}'s failed-deletion report: $(brief "${out}" 'deletion|reach')"
            fi
            # The report names the label step's outcome where the step ran. A clone has none; an in-place project's
            # runs where getenforce is on the removal's PATH, which leaves /usr/sbin out, and does not report Disabled,
            # which a usr-merged host meets. Its outcome there depends on the host's sudo, so the row asserts that one
            # outcome is named where the step ran and none elsewhere; cli-flags.sh drives each outcome.
            local label_step=no label_outcomes_named
            if [[ "${key}" == *.inplace ]] && ( PATH="${rmstub}:/usr/local/bin:/usr/bin:/bin"
                    command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != Disabled ]] ); then
                label_step=yes
            fi
            label_outcomes_named="$(grep -cE -- 'SELinux label step (did not )?complete' <<<"${out}" || true)"
            if [[ "${label_step}" == yes && "${label_outcomes_named}" == 1 ]] \
                    || [[ "${label_step}" == no && "${label_outcomes_named}" == 0 ]]; then
                pass "${key} names the label step's outcome only where the step ran (${label_step})"
            else
                fail "${key} names ${label_outcomes_named} label outcome(s), label step ${label_step}: $(brief "${out}" 'label')"
            fi
            if grep -qF -- "rm -rf $(printf '%q' "${p}")" <<<"${out}"; then
                pass "${key} prints the deletion to finish with the path quoted"
            else
                fail "${key} does not print the quoted deletion: $(brief "${out}" 'rm -rf')"
            fi
        }
        rmleft="${rmwork}/rm left"; mkdir -p "${rmleft}/sub"
        chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rmleft}"
        printf '%s\n' "${REG_MARKER}" "@ ${rmleft}" > "${rmal}"; chown "${PROJECTS_USER}" "${rmal}"
        spell ai-tools.projects.remove.inplace
        remove_left "${rmleft}" "${rmal}"
        left_reported ai-tools.projects.remove.inplace "${rmleft}" "${rmal}"
        rm -rf "${rmleft}"
    fi

    # (7) ai-tools.projects.list renders the reconciliation view deterministically over a FIXTURE allowlist + gitconfig
    # (AI_TOOLS_ALLOWLIST / AI_TOOLS_GITCONFIG), so it never reads the operator's real registry. Every entry class
    # and every Suggested-cleanup class is asserted. The stale and protected entries sit EARLY, so a passing
    # Maintenance/orphan assertion also proves the reconcile loop no longer aborts mid-list under set -e when a trailing
    # conditional returns 1.
    lst="${TESTDIR}/list"; mkdir -p \
        "${lst}/partial" "${lst}/eol-comment" "${lst}/quoted dir" \
        "${lst}/glob-parent" "${lst}/excluded-live" "${lst}/orphan" "${lst}/disabled-proj/child"
    # A git entry may name a listed project through a symlink or a `..`, so it is classified by its real path.
    ln -s "${lst}/partial" "${lst}/alias"
    chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${lst}"
    # mkdir takes the invoker's umask, and a 0700 root is annotated as owner-only in place of the row's own state.
    chmod 0755 "${lst}" "${lst}/partial" "${lst}/eol-comment" "${lst}/quoted dir" "${lst}/glob-parent" \
        "${lst}/excluded-live" "${lst}/orphan" "${lst}/disabled-proj" "${lst}/disabled-proj/child"
    # The reverse scan attributes an uncovered safe.directory before it offers a removal: a tree another account holds
    # (other-op, root's) and one under a directory the projects user cannot enter (sealed, 0700 root) are counted
    # and not listed; a tree the sandbox account holds (foreign) is named with a removal to run only if the tree is
    # the reader's, since a claim accepts that owner for any operator; a path that is gone (stale-safedir, and one
    # carrying a space) is stale; a trust rule (*, and wild/* with no such directory), a path git expands (~/expanded)
    # and a relative value are each named by its form with no removal. A listed entry under the sealed directory is
    # reported as unreadable rather than stale.
    # The two held trees are made enterable by the projects user: the suite runs under the invoker's umask, and a 0700
    # directory would be read as one the walk cannot enter, and counted, before its owner is read.
    mkdir -p "${lst}/foreign" "${lst}/other-op" "${lst}/sealed/inner" "${lst}/sealed/listed"
    chown "${SANDBOX_USER}:${SANDBOX_USER}" "${lst}/foreign"; chmod 0755 "${lst}/foreign"
    chown root:root "${lst}/other-op"; chmod 0755 "${lst}/other-op"
    chown root:root "${lst}/sealed"; chmod 0700 "${lst}/sealed"
    lal="${TESTDIR}/list-allowlist"
    cat > "${lal}" <<EOF
${REG_MARKER}
@ ${lst}/stale-gone
@ /etc
@ ${lst}/partial
@ ${lst}/eol-comment    # main repo
@ "${lst}/quoted dir"
! ${lst}/excluded-live
! ${lst}/excluded-stale-gone
% ${lst}/disabled-proj
@ ${lst}/disabled-proj/child
@ ${lst}/sealed/listed
% ${lst}/disabled-stale-entry
% ${lst}/disabled-stale-bare
EOF
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lal}"
    lgc="${TESTDIR}/list-gitconfig"
    cat > "${lgc}" <<EOF
[safe]
	directory = ${lst}/partial
	directory = ${lst}/orphan
	directory = ${lst}/disabled-proj
	directory = ${lst}/disabled-stale-entry
	directory = ${lst}/alias
	directory = ${lst}/orphan/../partial
	directory = /opt/ai-tools
	directory = ${lst}/foreign
	directory = ${lst}/other-op
	directory = ${lst}/sealed/inner
	directory = ${lst}/stale-safedir
	directory = ${lst}/stale with space
	directory = *
	directory = ${lst}/wild/*
	directory = ~/expanded
	directory = relative/repo
EOF
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lgc}"

    spell ai-tools.projects.list
    lout="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${lal}" \
            AI_TOOLS_GITCONFIG="${lgc}" "${CLI}" "${CLI_ARGV[@]}" 2>&1)" || true

    # `--` ends grep's options, so a needle opening with `--remove` is matched rather than refused as an option, which
    # list_lacks would read as absent.
    list_has()   { if grep -qF -- "$1" <<<"${lout}"; then pass "$2"; else fail "$2 -- missing from ai-tools.projects.list output"; fi; }
    list_lacks() { if grep -qF -- "$1" <<<"${lout}"; then fail "$2 -- unexpectedly present in ai-tools.projects.list output"; else pass "$2"; fi; }

    list_has "Maintenance"            "ai-tools.projects.list reaches its footer past an early stale+protected entry (no set -e truncation)"
    # Every Maintenance row's description starts at one column: the first character after the run of spaces that ends
    # the command, a command being words joined by single spaces.
    lmaint_columns="$(sed -n '/^Maintenance$/,$p' <<<"${lout}" | awk '/^  atr / {
            rest = substr($0, 3); gap = index(rest, "  "); if (gap == 0) { print "none"; next }
            col = gap + 2; while (substr(rest, col, 1) == " ") col++; print col }' | sort -u)"
    if [[ -n "${lmaint_columns}" && "$(wc -l <<<"${lmaint_columns}")" -eq 1 && "${lmaint_columns}" != none ]]; then
        pass "every Maintenance row's description starts at one column"
    else
        fail "the Maintenance rows' descriptions start at columns: $(tr '\n' ' ' <<<"${lmaint_columns:-none read}")"
    fi
    list_has "stale entry"            "ai-tools.projects.list flags a stale allow entry"
    list_has "protected system path"  "ai-tools.projects.list flags a protected system path (/etc)"
    list_has "listed but not fully claimed" "ai-tools.projects.list flags a listed-but-unclaimed project"
    list_has "disabled ${lst}/disabled-proj" "ai-tools.projects.list renders a '%' line as a disabled project"
    list_has "re-enable: atr projects enable ${lst}/disabled-proj" "ai-tools.projects.list names the re-enable of a disabled project"
    list_has "blocked"                "ai-tools.projects.list notes a listed project under a '%' line as blocked"
    list_has "safe.dir:yes"           "ai-tools.projects.list shows safe.dir:yes for an entry present in git safe.directory"
    list_has "${lst}/eol-comment"     "ai-tools.projects.list renders an entry carrying an end-of-line comment"
    list_has "${lst}/quoted dir"      "ai-tools.projects.list renders a quoted entry"
    # A stale disabled line takes the safe.directory removal the enabled arm prints, where git safe.directory holds its
    # path; a stale disabled line without an entry is the control.
    list_has "stale disabled project" "ai-tools.projects.list flags a stale disabled line"
    list_has "ai-tools-safedir --remove ${lst}/disabled-stale-entry" \
        "and names the safe.directory removal for a stale disabled line git safe.directory holds"
    list_lacks "ai-tools-safedir --remove ${lst}/disabled-stale-bare" \
        "control: a stale disabled line git safe.directory does not hold takes no safe.directory removal"
    # Only the gone exclusion is reconciled as stale; the live one is left alone.
    n_stale_excl="$(grep -cF 'stale excluded path' <<<"${lout}" || true)"
    if [[ "${n_stale_excl}" -eq 1 ]] && grep -qF "! ${lst}/excluded-stale-gone" <<<"${lout}"; then
        pass "ai-tools.projects.list reconciles only the stale ! exclusion, leaving the live one alone"
    else
        fail "stale-exclusion count is ${n_stale_excl}, expected exactly 1 (the gone path)"
    fi

    # The removal command a stale line takes is one shell word per argument: a line carrying a quote, and one whose
    # comment carries one, each print a `sed` that `bash -n` accepts and that, run over a copy of the registry, deletes
    # that line alone; a plain stale path is the control.
    lal_q="${TESTDIR}/list-allowlist-quotes"
    printf '%s\n' "${REG_MARKER}" "@ ${lst}/partial" "@ ${lst}/O'Reilly" "@ ${lst}/gone   # it's old" "@ ${lst}/plain-gone" \
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
    q_want="@ ${lst}/O'Reilly"$'\n'"@ ${lst}/gone   # it's old"$'\n'"@ ${lst}/plain-gone"
    if [[ "$(printf '%s\n' "${q_deleted[@]}" | sort)" == "$(sort <<<"${q_want}")" ]]; then
        pass "each stale line's removal command parses and deletes that line alone, a quote or a comment in it included"
    else
        fail "the removal commands deleted: $(printf '%s~' "${q_deleted[@]}") from ${#q_commands[@]} command(s)"
    fi

    # A glob on an allow line is a line the grammar refuses, so the listing refuses the whole file and names the line,
    # where it once listed the line as unusable.
    lal_glob="${TESTDIR}/list-allowlist-glob"
    printf '%s\n' "${REG_MARKER}" "@ ${lst}/partial" "@ ${lst}/glob-parent/*" > "${lal_glob}"
    chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lal_glob}"
    rc=0
    gout="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${lal_glob}" \
            AI_TOOLS_GITCONFIG="${lgc}" "${CLI}" "${CLI_ARGV[@]}" 2>&1)" || rc=$?
    if [[ "${rc}" -eq 1 ]] && grep -qF "glob-on-project" <<<"${gout}"; then
        pass "ai-tools.projects.list refuses a registry with a glob on an allow line, naming the reason"
    else
        fail "ai-tools.projects.list over a glob allow line: rc ${rc}: $(brief "${gout}")"
    fi
    assert_msg MSG-B8U2 "${gout}" "the library's line names the refused line"
    assert_msg MSG-Y7K5 "${gout}" "and the CLI's refusal follows it"

    # Reverse reconciliation: exactly one orphaned safe.directory -- the listed entry (partial), the same entry spelled
    # through a symlink (alias) and through a `..`, the disabled one (disabled-proj) and the control-plane entry
    # (/opt/ai-tools, a protected path) must NOT be flagged.
    list_has "git safe.directory with no allowlist entry" "ai-tools.projects.list flags an orphaned safe.directory"
    list_has "${lst}/orphan"          "ai-tools.projects.list names the orphaned safedir path"
    list_lacks "/opt/ai-tools"        "ai-tools.projects.list skips the control-plane safe.directory (protected, registered deliberately)"
    n_orphan="$(grep -cF 'git safe.directory with no allowlist entry' <<<"${lout}" || true)"
    if [[ "${n_orphan}" -eq 1 ]]; then
        pass "exactly one orphaned safedir (a listed entry and the control-plane entry are not flagged)"
    else
        fail "orphaned-safedir count is ${n_orphan}, expected 1"
    fi
    lcleanup="$(sed -n '/Suggested cleanup/,$p' <<<"${lout}")"
    if grep -qxF "  ${lst}/disabled-proj" <<<"${lcleanup}" || grep -qE -- "--remove ${lst}/disabled-proj\$" <<<"${lcleanup}"; then
        fail "ai-tools.projects.list offers the safe.directory of ${lst}/disabled-proj, a registered path, for removal"
    else
        pass "ai-tools.projects.list counts the safe.directory of the disabled path as registered"
    fi
    for lalias in "${lst}/alias" "${lst}/orphan/../partial"; do
        if grep -qF -- "${lalias}" <<<"${lcleanup}"; then
            fail "ai-tools.projects.list offers the safe.directory ${lalias}, a listed project's other spelling, for removal"
        else
            pass "ai-tools.projects.list classifies the safe.directory ${lalias} by its real path, a listed project"
        fi
    done
    # Attribution: the orphan count stays at the one tree the projects user holds. A tree another account holds
    # and one under a directory the projects user cannot enter are named nowhere and counted in one closing line;
    # a tree the sandbox account holds is named with a removal to run only if the tree is the reader's.
    list_lacks "${lst}/other-op"      "ai-tools.projects.list does not name a safe.directory in another account's tree"
    list_lacks "${lst}/sealed/inner"  "ai-tools.projects.list does not name a safe.directory under a directory it cannot enter"
    list_has "2 git safe.directory entries are in trees" "ai-tools.projects.list counts the two entries it cannot attribute"
    list_has "held by the sandbox account" "ai-tools.projects.list names a safe.directory in a tree the sandbox account holds as such"
    list_has "ai-tools-safedir --remove ${lst}/foreign" "and offers its removal under the condition the line states"
    list_has "stale git safe.directory" "ai-tools.projects.list reports a safe.directory whose path is gone as stale"
    list_has "ai-tools-safedir --remove ${lst}/stale-safedir" "and names its safe.directory removal"
    list_has "ai-tools-safedir --remove ${lst}/stale"'\ with\ space' "and prints a stale path carrying a space as one word"
    list_lacks "ai-tools-relabel --remove ${lst}/stale-safedir" "and no label removal, there being no tree to read a label from"
    # git exits 128 when its working directory was deleted, where a shell stands after `atr projects remove .`,
    # so the listing reads the list from /: the same run from a deleted directory reports the same stale entry. A list
    # git cannot read is named as such, and its rows read `?`, beside `lout`, the listing over the readable list,
    # which reads them `yes`. The projects user removes the directory it stands in, which takes write on the parent,
    # and TESTDIR is root's.
    lgone_parent="${TESTDIR}/list-cwd"
    lgone="${lgone_parent}/gone"
    mkdir -p "${lgone}"; chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${lgone_parent}"
    gone_rc=0
    # shellcheck disable=SC2016  # the $N are for the inner `bash -c`, not this shell -- do not expand here
    gone_out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${lal}" AI_TOOLS_GITCONFIG="${lgc}" bash -c \
        'dir="$1"; shift; cd "${dir}" && rmdir "${dir}" || exit 97
         git config --file "${AI_TOOLS_GITCONFIG}" --get-all safe.directory >/dev/null 2>&1 && exit 98
         "$@"' _ "${lgone}" "${CLI}" "${CLI_ARGV[@]}" 2>&1)" || gone_rc=$?
    if [[ "${gone_rc}" -eq 97 || "${gone_rc}" -eq 98 ]]; then
        fail "fixture: the run did not stand in a deleted directory git's plain read fails in (status ${gone_rc}) -- $(brief "${gone_out}")"
    elif grep -qF "ai-tools-safedir --remove ${lst}/stale-safedir" <<<"${gone_out}"; then
        pass "ai-tools.projects.list run from a deleted directory reports the stale safe.directory"
    else
        fail "ai-tools.projects.list run from a deleted directory: $(brief "${gone_out}")"
    fi
    lgc_bad="${TESTDIR}/list-gitconfig-unreadable"
    printf '[safe\n' > "${lgc_bad}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${lgc_bad}"
    bad_out="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${lal}" \
            AI_TOOLS_GITCONFIG="${lgc_bad}" "${CLI}" "${CLI_ARGV[@]}" 2>&1)" || true
    if grep -qF "safe.dir:?" <<<"${bad_out}" && ! grep -qE 'safe\.dir:(yes|NO)' <<<"${bad_out}" \
            && grep -qF "could not be read" <<<"${bad_out}"; then
        pass "ai-tools.projects.list over a safe.directory list git cannot read names the file and reads no row yes or NO"
    else
        fail "ai-tools.projects.list over an unreadable safe.directory list: $(brief "${bad_out}")"
    fi
    # A value ai-tools-safedir does not write is named by its form with the command that lists the file, and does not
    # take a removal: the exact-value removal of a trust rule deletes the rule, and git does not read an expanded path
    # as the directory this listing would read it as.
    list_has "trusts every repository on this host" "ai-tools.projects.list names the * safe.directory value as a trust rule"
    list_lacks "--remove *" "and offers no removal for it"
    list_has "trusts every repository under ${lst}/wild" "ai-tools.projects.list names a <dir>/* safe.directory value as a trust rule over that directory"
    list_lacks "--remove ${lst}/wild" "and does not report it stale or offer its removal, though no such directory exists"
    list_has "expands the leading ~" "ai-tools.projects.list names a ~/ safe.directory value as a path git expands"
    list_lacks "--remove ~/expanded" "and offers no removal for it"
    lexpanded="$(grep -A1 -xF -- "  ~/expanded" <<<"${lout}" || true)"
    if [[ "$(wc -l <<<"${lexpanded}")" -ne 2 ]]; then
        fail "ai-tools.projects.list does not print the ~/expanded block with its description line: $(brief "${lexpanded}")"
    elif grep -qiF "pattern" <<<"${lexpanded}"; then
        fail "ai-tools.projects.list calls the expanded path ~/expanded a pattern"
    else
        pass "and does not call it a pattern"
    fi
    list_has "not an absolute path" "ai-tools.projects.list names a relative safe.directory value as such"
    list_lacks "--remove relative/repo" "and offers no removal for it"
    list_has "git -C / config --file ${lgc} --get-all safe.directory" "each names the command that lists the file"
    # The disabled row carries the safe.dir column the project rows carry, and stays out of the cleanup.
    if grep -qE "disabled +${lst}/disabled-proj +safe\.dir:yes" <<<"${lout}"; then
        pass "ai-tools.projects.list shows safe.dir:yes on a disabled row whose path is in git safe.directory"
    else
        fail "the disabled row lacks its safe.dir column: $(brief "${lout}" 'disabled')"
    fi
    # The forward direction: a listed entry under a directory the projects user cannot enter is unreadable, not stale,
    # and does not take a removal.
    list_has "cannot be read as ${PROJECTS_USER}" "ai-tools.projects.list reports a listed entry it cannot read as unreadable"
    if grep -A1 -F "  ${lst}/sealed/listed" <<<"${lcleanup}" | grep -qE 'sed -i|--remove|no longer exists'; then
        fail "ai-tools.projects.list offers a removal for an entry it cannot read: $(brief "${lcleanup}" 'sealed')"
    else
        pass "ai-tools.projects.list offers no removal for an entry it cannot read"
    fi
    # An absent registry is the listing's body, and the safe.directory reconciliation runs over an empty entry set,
    # so a registry removed by hand leaves its entries reported: the stale one with its removal, the sandbox account's
    # named as such, and the two it cannot attribute counted. `lout`, over the fixture registry, is the control.
    lal_absent="${TESTDIR}/list-allowlist-absent"
    [[ ! -e "${lal_absent}" ]] || fail "fixture: ${lal_absent} exists, so the absent-registry run reads a registry"
    rc=0
    aout="$(runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
            AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${lal_absent}" \
            AI_TOOLS_GITCONFIG="${lgc}" "${CLI}" "${CLI_ARGV[@]}" 2>&1)" || rc=$?
    if [[ "${rc}" -eq 0 ]] && grep -qF "no registry at ${lal_absent}" <<<"${aout}" \
            && grep -qF "ai-tools-safedir --remove ${lst}/stale-safedir" <<<"${aout}" \
            && grep -qF "held by the sandbox account" <<<"${aout}" \
            && grep -qF "2 git safe.directory entries are in trees" <<<"${aout}" \
            && grep -qF "Maintenance" <<<"${aout}"; then
        pass "ai-tools.projects.list without a registry names it and still reports the stale, foreign and unattributed safe.directory entries"
    else
        fail "ai-tools.projects.list without a registry (rc ${rc}): $(brief "${aout}")"
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

        # The clone kind de-lists before it deletes, so a de-list that does not apply leaves the clone on disk
        # and registered, refused under MSG-K8S2: the registry sits in a directory the projects user cannot write,
        # where the editor cannot make its temporary file. The de-list is the first step, so the clone keeps its
        # safe.directory entry too: the fixture gitconfig names it, and the refused run does not reach the safedir step.
        # The same removal over a writable directory is the control.
        rclone="${sroot}/clone-kept"; mkdir -p "${rclone}"; git init -q "${rclone}"
        chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rclone}"
        creg_dir="${TESTDIR}/clone-registry"; mkdir -p "${creg_dir}"; chown root:root "${creg_dir}"; chmod 0755 "${creg_dir}"
        creg="${creg_dir}/project-registry"; printf '%s\n' "${REG_MARKER}" "@ ${rclone}" > "${creg}"
        chown "${PROJECTS_USER}:${PROJECTS_USER}" "${creg}"; chmod 0644 "${creg}"
        cgc="${TESTDIR}/clone-gitconfig"; : > "${cgc}"; git config --file "${cgc}" --add safe.directory "${rclone}"
        chown "${PROJECTS_USER}:${PROJECTS_USER}" "${cgc}"
        creg_before="$(sha256sum < "${creg}")"; cgc_before="$(sha256sum < "${cgc}")"
        remove_clone_run() {
            runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${creg}" AI_TOOLS_SANDBOX_ROOT="${sroot}" \
                AI_TOOLS_GITCONFIG="${cgc}" setsid "${CLI}" "${CLI_ARGV[@]}" -y "${rclone}" 2>&1
        }
        out="$(remove_clone_run)" && rc=0 || rc=$?
        refused "ai-tools.projects.remove.clone whose de-list does not apply is refused" MSG-K8S2 1
        if [[ -d "${rclone}/.git" && "$(sha256sum < "${creg}")" == "${creg_before}" ]]; then
            pass "the clone whose de-list did not apply is still on disk and still registered"
        else
            fail "the refused clone removal: on disk $([[ -d "${rclone}" ]] && echo yes || echo no), registry $([[ "$(sha256sum < "${creg}")" == "${creg_before}" ]] && echo same || echo changed)"
        fi
        if [[ "$(sha256sum < "${cgc}")" == "${cgc_before}" ]] && ! grep -qF "safe.directory" <<<"${out}"; then
            pass "the refused clone removal reaches no safe.directory step and leaves the gitconfig as it was"
        else
            fail "the refused clone removal touched the trust entry: $(brief "${out}" 'safe.directory')"
        fi
        chown "${PROJECTS_USER}:${PROJECTS_USER}" "${creg_dir}"
        out="$(remove_clone_run)" && rc=0 || rc=$?
        if [[ ${rc} -eq 0 && ! -e "${rclone}" ]] && ! grep -qF "${rclone}" "${creg}"; then
            pass "control: the same removal over a writable registry directory drops the line and deletes the clone"
        else
            fail "the control clone removal (rc=${rc}, on disk $([[ -e "${rclone}" ]] && echo yes || echo no)): $(brief "${out}")"
        fi
        # The clone kind reads .git as data and does not run git over the tree: a partial clone whose HEAD object is
        # gone and whose core.sshCommand writes a marker, the in-place kind's fixture, is accepted as a clone
        # and removed, and the marker stays absent. The control is a direct rev-list as the projects user, which runs
        # the transport. The stub and its marker sit in a directory the projects user owns, outside the clone area,
        # since the transport runs as that user and the testdir is root's.
        rpart="${sroot}/clone-partial"; rpart_work="${TESTDIR}/clone-partial-work"
        mkdir -p "${rpart_work}"; chown "${PROJECTS_USER}:${PROJECTS_USER}" "${rpart_work}"
        rpart_marker="${rpart_work}/git-ran"
        printf 'touch %s\nexit 1\n' "${rpart_marker}" > "${rpart_work}/ssh-stub"
        if git -C "${sroot}" init -q clone-partial 2>/dev/null \
                && git -C "${rpart}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one 2>/dev/null; then
            rpart_head="$(git -C "${rpart}" rev-parse HEAD)"
            git -C "${rpart}" update-ref refs/remotes/origin/main "${rpart_head}"
            git -C "${rpart}" config remote.origin.url ssh://nowhere.invalid/up
            git -C "${rpart}" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
            git -C "${rpart}" config remote.origin.promisor true
            git -C "${rpart}" config remote.origin.partialclonefilter blob:none
            git -C "${rpart}" config extensions.partialClone origin
            git -C "${rpart}" config core.sshCommand "bash ${rpart_work}/ssh-stub"
            git -C "${rpart}" branch --set-upstream-to=origin/main >/dev/null 2>&1
            rm -f "${rpart}/.git/objects/${rpart_head:0:2}/${rpart_head:2}"
            chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rpart}" "${rpart_work}/ssh-stub"
            runuser -u "${PROJECTS_USER}" -- git -C "${rpart}" rev-list --count '@{u}..HEAD' >/dev/null 2>&1 || true
            if [[ -e "${rpart_marker}" ]]; then
                pass "control: a rev-list over the armed clone runs the configured transport"
                rm -f "${rpart_marker}"
                printf '%s\n' "${REG_MARKER}" "@ ${rpart}" > "${creg}"
                rclone="${rpart}"; out="$(remove_clone_run)" && rc=0 || rc=$?
                if [[ ${rc} -eq 0 && ! -e "${rpart}" && ! -e "${rpart_marker}" ]]; then
                    pass "ai-tools.projects.remove.clone removes the armed clone and runs no git over it"
                else
                    fail "ai-tools.projects.remove.clone over the armed clone (rc=${rc}, on disk $([[ -e "${rpart}" ]] && echo yes || echo no), marker $([[ -e "${rpart_marker}" ]] && echo yes || echo no)): $(brief "${out}")"
                fi
            else
                fail "control: the armed clone did not run the configured transport, so the case proves nothing"
            fi
        else
            skip "ai-tools.projects.remove.clone runs no git over the tree" "git unavailable"
        fi
        rm -rf "${rpart}" "${rpart_work}"
        # The push counts the commits ahead of the upstream before it lists or pushes them: a clone whose upstream
        # resolves and whose walk git cannot make, the upstream ref naming an object the store does not hold, is refused
        # under MSG-H6R3 and not reported up to date. The same clone with its upstream at HEAD, the control, has nothing
        # to push. The remote's URL does not resolve, so a push that ran anyway would fail on the host.
        rpush="${sroot}/clone-push"
        if git -C "${sroot}" init -q clone-push 2>/dev/null \
                && git -C "${rpush}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m one 2>/dev/null; then
            git -C "${rpush}" config remote.origin.url ssh://nowhere.invalid/up
            git -C "${rpush}" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
            git -C "${rpush}" update-ref refs/remotes/origin/main HEAD
            git -C "${rpush}" branch -q --set-upstream-to=origin/main
            chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rpush}"
            spell ai-tools.projects.push
            push_run() {
                runuser -u "${PROJECTS_USER}" -- env HOME="${PROJECTS_HOME}" \
                    AI_TOOLS_OPERATOR_CONF="${oconf}" AI_TOOLS_ALLOWLIST="${emptyal}" AI_TOOLS_SANDBOX_ROOT="${sroot}" \
                    setsid "${CLI}" "${CLI_ARGV[@]}" "${rpush}" 2>&1
            }
            out="$(push_run)" && rc=0 || rc=$?
            if [[ ${rc} -eq 0 ]] && grep -qF "nothing to push" <<<"${out}"; then
                pass "control: ai-tools.projects.push over a clone with its upstream at HEAD has nothing to push"
            else
                fail "control: ai-tools.projects.push over the clone at its upstream (rc=${rc}): $(brief "${out}")"
            fi
            printf '%040d\n' 1 > "${rpush}/.git/refs/remotes/origin/main"
            out="$(push_run)" && rc=0 || rc=$?
            refused "ai-tools.projects.push whose commit count git cannot make is refused" MSG-H6R3 1
            if grep -qF "nothing to push" <<<"${out}"; then
                fail "the refused push still reports the clone up to date: $(brief "${out}")"
            else
                pass "the refused push does not report the clone up to date"
            fi
        else
            skip "ai-tools.projects.push refuses a count it cannot make" "git unavailable"
        fi
        rm -rf "${rpush}"
        if [[ -n "${rmstub}" ]]; then
            rleft="${sroot}/clone left"; mkdir -p "${rleft}"; git init -q "${rleft}"
            chown -R "${PROJECTS_USER}:${PROJECTS_USER}" "${rleft}"
            printf '%s\n' "${REG_MARKER}" "@ ${rleft}" > "${creg}"
            spell ai-tools.projects.remove.clone
            remove_left "${rleft}" "${creg}" AI_TOOLS_SANDBOX_ROOT="${sroot}" AI_TOOLS_GITCONFIG="${cgc}"
            left_reported ai-tools.projects.remove.clone "${rleft}" "${creg}"
            rm -rf "${rleft}"
        fi
        rm -rf "${rclone}" "${creg_dir}" "${cgc}"
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

    # setsid: every assertion in this section expects a refusal, and each must land BEFORE the target's registry
    # snapshot, which is a --for run's only sudo. Without a controlling terminal sudo cannot open /dev/tty to prompt
    # (a stdin redirect does not stop it) and fails at once, so a regression that let a refusal fall past the snapshot
    # FAILS here instead of hanging on a developer's password prompt -- the asymmetry being that a container with no tty
    # would fail while an interactive run stalls indefinitely. -w because setsid FORKS when it is already
    # a process-group leader, and the bare form then returns 0 rather than the command's status, which would quietly
    # pass every rc-based assertion in it. run_for <key> <args...>: the command the key names, as the operator, against
    # the fixture registry.
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
    # By code: --for's own --force refusal (MSG-B5K3), raised by the unclaim ahead of the target's registry snapshot.
    refused "--for refuses to combine with ai-tools.projects.unclaim --force" MSG-B5K3

    # (5) A bare --for with no name is a parse error, not an empty operator silently meaning "me".
    out="$(run_for ai-tools.projects.claim --for)" && rc=0 || rc=$?
    refused "--for with no operator name is refused, ahead of every gate" MSG-B4G2
fi

# ── ai-tools.projects.disable / ai-tools.projects.enable: disabling a project ───────────────
# The pair changes the sign of ONE line of the operator's own registry and does not reach a root helper, so the whole
# lifecycle is drivable here as the projects user over the fixture registry. What is asserted is what the flat-file
# model rests on (the entry states, in cli.rule.md): the write is the whole file in canonical form with that line's sign
# changed and its comment kept, a disabled project is not an unlisted one, and neither verb ever invents an entry or
# lifts a '!' line -- since lifting one lets a session start in a subtree its operator excluded.
section "ai-tools.projects.disable / ai-tools.projects.enable"

if ! command -v runuser >/dev/null 2>&1; then
    skip "ai-tools.projects.disable / ai-tools.projects.enable" "runuser unavailable"
else
    mktestdir
    chmod 755 "${TESTDIR}"
    pd_conf="${TESTDIR}/op.conf"
    pd_al="${TESTDIR}/project-registry"
    pd_proj="${TESTDIR}/api"; pd_other="${TESTDIR}/web"
    pd_nested="${pd_proj}/service-a"; pd_excluded="${pd_proj}/secrets"
    mkdir -p "${pd_proj}" "${pd_other}" "${pd_nested}" "${pd_excluded}"
    # mkdir takes the invoker's umask, and the claim refuses a 0700 root (MSG-B5D2) ahead of its disabled-line refusal.
    chmod 0755 "${pd_proj}" "${pd_other}" "${pd_nested}" "${pd_excluded}"
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

    # (1) Disable a listed project: the write is the whole file in canonical form, so a hand-indented line takes its
    # place in the forest and its comment is kept after the entry. That comment surviving is the whole reason these
    # verbs exist rather than being an unclaim/claim pair -- an operator's commented registry keeps its notes.
    pd_seed "  @ ${pd_proj}   # payments, dev stage" "@ ${pd_other}"
    out="$(pd_cli ai-tools.projects.disable "${pd_proj}")" && rc=0 || rc=$?
    pd_disabled_line="$(sed -n '2p' "${pd_al}")"
    if [[ ${rc} -eq 0 && "$(wc -l < "${pd_al}")" -eq 3 && "${pd_disabled_line}" == "% ${pd_proj} "*"# payments, dev stage" \
            && "$(sed -n '3p' "${pd_al}")" == "@ ${pd_other}" ]]; then
        pass "ai-tools.projects.disable writes '%' on the entry in canonical form, keeping its comment"
    else
        fail "ai-tools.projects.disable did not disable the entry (rc=${rc}): $(brief "${out}")"$'\n'"$(cat "${pd_al}")"
    fi
    # A file in canonical form differs between the two states by the sign alone, so the enable has one file to restore.
    pd_before="$(sed '2s/^% /@ /' "${pd_al}")"
    if grep -qi 'handback' <<<"${out}"; then
        pass "the disable states the consequence an operator has to know (the handback stops)"
    else
        fail "the disable did not mention the ownership handback: $(brief "${out}")"
    fi

    # (2) A disabled project is NOT an unlisted one. The claim must not append a second, positive line that the '%'
    # would go on winning over -- it offers the re-enable, which with no terminal takes its default NO, and refuses.
    out="$(pd_cli ai-tools.projects.claim "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 ]] && grep -qi 'disabled' <<<"${out}"; then
        pass "ai-tools.projects.claim over a disabled project refuses instead of claiming"
    else
        fail "ai-tools.projects.claim did not refuse over a disabled project (rc=${rc}): $(brief "${out}")"
    fi
    if [[ "$(grep -cF "${pd_proj}" "${pd_al}")" == 1 ]]; then
        pass "the refused claim appended no duplicate line"
    else
        fail "the refused claim duplicated the entry:"$'\n'"$(cat "${pd_al}")"
    fi
    # (2b) The owner-only refusal precedes the re-enable offer: over the same disabled project with its root at 0700,
    # the claim refuses under the listed-project code and leaves the registry as it was.
    pd_held="$(cat "${pd_al}")"
    chmod 0700 "${pd_proj}"
    if [[ "$(stat -c '%a %U' "${pd_proj}")" == "700 ${PROJECTS_USER}" ]]; then
        pass "control: the disabled project's root is mode 700, held by ${PROJECTS_USER}"
    else
        fail "control: the disabled project's root reads '$(stat -c '%a %U' "${pd_proj}")', expected '700 ${PROJECTS_USER}'"
    fi
    out="$(pd_cli ai-tools.projects.claim "${pd_proj}")" && rc=0 || rc=$?
    chmod 0755 "${pd_proj}"
    refused "ai-tools.projects.claim over a disabled project at mode 700 refuses it as owner-only" MSG-B5D2 1
    if [[ "$(cat "${pd_al}")" == "${pd_held}" ]]; then
        pass "the owner-only refusal kept the disabled line and left the registry as it was"
    else
        fail "the owner-only refusal changed the registry:"$'\n'"$(cat "${pd_al}")"
    fi

    # (3) ai-tools.projects.list calls it what it is, and names the verb that restores it.
    out="$(pd_cli ai-tools.projects.list)" || true
    if grep -qE "disabled[[:space:]]+${pd_proj}" <<<"${out}" \
            && grep -qF -- "$(cli_cmd_text ai-tools.projects.enable) ${pd_proj}" <<<"${out}"; then
        pass "ai-tools.projects.list reports a disabled project as disabled, with the re-enable command"
    else
        fail "ai-tools.projects.list did not report the disabled project: $(brief "${out}" 'disabled|exclude')"
    fi

    # (4) Restore it: over a file in canonical form, the enable changes the sign back and leaves every other byte.
    out="$(pd_cli ai-tools.projects.enable "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && [[ "$(cat "${pd_al}")" == "${pd_before}" ]]; then
        pass "ai-tools.projects.enable restores the canonical file byte-identically, the sign alone changed"
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

    # (6) An EXCLUDED path is not a disabled project, and lifting its '!' would WIDEN where a session starts and what
    # the hand-back and claim walks reach -- a subtree its operator excluded from a claimed project. It is refused, and
    # the refusal names the line.
    pd_seed "@ ${pd_proj}" "! ${pd_excluded}"
    out="$(pd_cli ai-tools.projects.enable "${pd_excluded}")" && rc=0 || rc=$?
    # By code: the excluded-path refusal (MSG-W4S7), not the no-entry one (MSG-T4A8).
    refused "ai-tools.projects.enable refuses an excluded path rather than lifting its '!'" MSG-W4S7
    if grep -qF "! ${pd_excluded}" "${pd_al}"; then
        pass "the '!' line survived the refusal"
    else
        fail "the refused enable deleted the '!' line:"$'\n'"$(cat "${pd_al}")"
    fi

    # (7) A NESTED project is disabled like any other: the kind is in the line, so its '%' cannot be read as a '!', and
    # the canonical write indents it under the project enclosing it.
    pd_seed "@ ${pd_proj}" "@ ${pd_nested}"
    out="$(pd_cli ai-tools.projects.disable "${pd_nested}")" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && grep -qxF "  % ${pd_nested}" "${pd_al}" && grep -qxF "@ ${pd_proj}" "${pd_al}"; then
        pass "ai-tools.projects.disable writes '%' on a project nested inside another, the enclosing one listed"
    else
        fail "ai-tools.projects.disable did not disable the nested project (rc=${rc}): $(brief "${out}")"$'\n'"$(cat "${pd_al}")"
    fi

    # (8) The per-project verbs must not call a disabled project unclaimed: on an excluded path the root helpers resolve
    # no owner and act on NO PATH, so a run that got that far would report steps it never applied. (A host may also
    # refuse earlier for a missing sudo grant -- that is a different, correct refusal; what must not appear is "not
    # a claimed project".)
    pd_seed "% ${pd_proj}"
    for key in ai-tools.projects.handback ai-tools.projects.lockdown ai-tools.projects.unclaim; do
        out="$(pd_cli "${key}" "${pd_proj}")" && rc=0 || rc=$?
        if [[ ${rc} -ne 0 ]] && ! grep -qi 'not a claimed project' <<<"${out}"; then
            pass "${key} over a disabled project does not report it as unclaimed"
        else
            fail "${key} called a disabled project unclaimed (rc=${rc}): $(brief "${out}")"
        fi
    done

    # (9) ai-tools.projects.remove.inplace's AUTHORIZATION is the exact entry, and a disabled one counts: the '%'
    # records "not right now", not "not mine", and making the operator re-enable a tree they mean to delete would make
    # it launchable on the way out. So the verb must get past classification -- reaching its own disabled confirm --
    # rather than refusing as unregistered. It must also delete NO PATH here: with no terminal the confirm and
    # the typed-name challenge both decline, which is the property that keeps a destructive verb out of an unattended
    # run.
    out="$(pd_cli ai-tools.projects.remove.inplace "${pd_proj}")" && rc=0 || rc=$?
    if grep -qi 'not a claimed project' <<<"${out}"; then
        fail "ai-tools.projects.remove.inplace refused a disabled project as unregistered: $(brief "${out}")"
    elif grep -qxE 'MSG-R4J2|MSG-Z6Q6' <<<"${out}"; then
        # A host whose operator does not hold a general sudo grant refuses ahead of classification. That is a different,
        # correct refusal, and it is not what this case is about.
        skip "ai-tools.projects.remove.inplace over a disabled project" "no sudo grant for the removal helper here"
    elif [[ ${rc} -ne 0 ]] && grep -qi 'disabled' <<<"${out}"; then
        pass "ai-tools.projects.remove.inplace accepts a disabled entry as authorization and names the disabled state"
    else
        fail "ai-tools.projects.remove.inplace did not recognise the disabled entry (rc=${rc}): $(brief "${out}")"
    fi
    if [[ -d "${pd_proj}" ]]; then
        pass "the declined removal deleted nothing (no terminal answers both prompts NO)"
    else
        fail "ai-tools.projects.remove.inplace deleted a project with no terminal to confirm at"
    fi

    # (10) What becomes of an entry when an unclaim's hand-back does not run is the unclaim's own decision (it disables
    # the line), so no option chooses it, and the removal deletes the entry with the tree: `--keep-entry` is an unknown
    # option to both, refused rather than ignored, since a flag that silently skips its work is how an operator learns
    # the wrong model. Written as typed, since neither command has the option to spell.
    pd_before="$(cat "${pd_al}")"
    out="$(pd_cli ai-tools.projects.unclaim --keep-entry "${pd_proj}")" && rc=0 || rc=$?
    if grep -qxE 'MSG-R4J2|MSG-Z6Q6' <<<"${out}"; then
        # Either no-sudo-grant refusal: an environment fact, reached before the parse check.
        skip "ai-tools.projects.unclaim --keep-entry" "no sudo grant for the unclaim helper here"
    else
        # By code: the unclaim's unknown-option refusal (MSG-F7J9), at the usage status.
        refused "ai-tools.projects.unclaim refuses --keep-entry as an unknown option" MSG-F7J9 2
    fi
    out="$(pd_cli ai-tools.projects.remove.inplace --keep-entry "${pd_proj}")" && rc=0 || rc=$?
    # By code: the removal's unknown-option refusal (MSG-M3Y5), at the usage status.
    refused "ai-tools.projects.remove.inplace refuses --keep-entry as an unknown option" MSG-M3Y5 2
    if [[ -d "${pd_proj}" && "$(cat "${pd_al}")" == "${pd_before}" ]]; then
        pass "the refused options deleted nothing and left the registry as it was"
    else
        fail "a refused option changed the project or the registry:"$'\n'"$(cat "${pd_al}")"
    fi

    # (11) An entry can be clean and the project still unreachable, because a '!', a '%' or a glob line covers it
    # from an ancestor. Entry state and reachability are different questions, and reporting the first as though it
    # answered the second sends an operator hunting through their own file for a refusal the CLI already knew about.
    pd_seed "@ ${pd_proj}" "! ${TESTDIR}"
    out="$(pd_cli ai-tools.projects.enable "${pd_proj}")" && rc=0 || rc=$?
    if [[ ${rc} -eq 0 ]] && grep -qi 'already enabled' <<<"${out}" \
            && grep -qF "! ${TESTDIR}" <<<"${out}"; then
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

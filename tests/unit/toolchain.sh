#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/toolchain.sh
# Unit test for toolchain.lib.sh: the two residue readers and the one package removal behind the launch refusal every
# wrapper and ai-tools-run make while an installed, not enabled agent's package is still in the sandbox toolchain.
#
# What gives it teeth is the direction each function must fail in. A reader that listed an enabled agent's package would
# have the provisioners remove what they maintain; one that passed a disabled agent's package as clean would have every
# launch start beside an entrypoint a session can exec at its real path. So residue is asserted to be EXACTLY
# the installed-not-enabled-present set: an enabled agent's package does not appear in it, a manifest the trust
# predicate refuses does not (the resolver skips it, and its launcher is refused on its own), a manifest without
# an npm_package does not, and a version directory outside the semver shape is not read. The writer is driven with npm
# stubbed in the fixture version's own bin: it refuses an enabled agent's package under its code and does not call npm,
# defers a package a live process executes from (the collector stubbed to say so), issues exactly one uninstall
# for a removal and reports the state directory the removal leaves, and reports an uninstall that left the directory
# in place. The erase form removes an enabled agent's package too, since it runs while the manifest is being erased.
#
# Fixtures are a synthetic manifest set (the acme/beta pair unit/providers.sh uses) read through the resolver's two
# root-only hooks, so no shipped agent is named; they are root-owned 0644 in 0755 directories, which the trust predicate
# admits, so this runs as root via sudo (suite contract). The npm stub must be executable where it sits, so the tree is
# built where the executable bit is visible (the testdir, or a directory beside the operator's home on a noexec /tmp --
# the fallback unit/launcher-target.sh takes). It closes with the order the updater runs the removal in, read as source
# order like the re-link's: the removal precedes install_packages, so npm's allow-scripts rescan sees the smaller tree.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root
umask 022

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="/usr/local/lib/ai-tools/toolchain.lib.sh"
[[ -r "${LIB}" ]] || LIB="${REPO_ROOT}/src/usr/local/lib/ai-tools/toolchain.lib.sh"

section "toolchain: residue readers and the package removal (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "toolchain residue" "library not found at ${LIB}"; finish; exit
fi

# x_bit_visible <dir>: succeed when a 0755 file created there reads as executable (a noexec mount hides the bit,
# and bash's PATH search then passes the stub over for the real npm).
x_bit_visible() {
    local probe="$1/.x-probe.$$" ok=1
    printf '' > "${probe}" 2>/dev/null || return 1
    chmod 0755 "${probe}" 2>/dev/null || { rm -f "${probe}"; return 1; }
    [[ -x "${probe}" ]] && ok=0
    rm -f "${probe}"
    return "${ok}"
}

mktestdir
FIXTURE_ROOT="${TESTDIR}"
if ! x_bit_visible "${FIXTURE_ROOT}"; then
    mk_fixture_dir FIXTURE_ROOT "${PROJECTS_HOME}" toolchain 2>/dev/null || FIXTURE_ROOT=""
    [[ -n "${FIXTURE_ROOT}" ]] && chmod 0755 "${FIXTURE_ROOT}"
fi
if [[ -z "${FIXTURE_ROOT}" ]] || ! x_bit_visible "${FIXTURE_ROOT}"; then
    skip "toolchain residue" "no directory here reports a 0755 file as executable (a noexec mount)"
    finish; exit
fi

AGENTS_DIR="${FIXTURE_ROOT}/agents.d"; CONF="${FIXTURE_ROOT}/operator.conf"
NVM="${FIXTURE_ROOT}/nvm"; LINKS="${FIXTURE_ROOT}/bin"
mkdir -m 0755 "${AGENTS_DIR}" "${LINKS}"
export AI_TOOLS_AGENTS_DIR="${AGENTS_DIR}" AI_TOOLS_OPERATOR_CONF="${CONF}"

# manifest <name> <package> <launcher> [<extra line>...] : one agent manifest, root-owned 0644.
manifest() {
    local name="$1" package="$2" launcher="$3"; shift 3
    { printf 'npm_package=%s\nlauncher=%s\ndefault_enable=no\n' "${package}" "${launcher}"
      [[ $# -gt 0 ]] && printf '%s\n' "$@"; } > "${AGENTS_DIR}/${name}.conf"
    chmod 0644 "${AGENTS_DIR}/${name}.conf"
}
manifest acme  @acme/experimental acme
manifest beta  @acme/beta         beta  config_dir=.beta
manifest gamma @acme/gamma        gamma
printf 'launcher=nopkg\ndefault_enable=no\n' > "${AGENTS_DIR}/nopkg.conf"; chmod 0644 "${AGENTS_DIR}/nopkg.conf"
chmod 0666 "${AGENTS_DIR}/gamma.conf"      # untrusted: not an agent, so never residue
printf 'AI_TOOLS_AGENTS="acme"\n' > "${CONF}"; chmod 0644 "${CONF}"

# package <version> <package> : the package directory npm leaves, with a marker file inside.
package() {
    mkdir -p "${NVM}/versions/node/$1/lib/node_modules/$2"
    printf '{}\n' > "${NVM}/versions/node/$1/lib/node_modules/$2/package.json"
}
package v1.2.3 @acme/experimental
package v1.2.3 @acme/beta
package v2.0.0 @acme/beta
package v1.2.3 @acme/gamma
package notaversion @acme/beta
ln -s /nonexistent/acme  "${LINKS}/acme"
ln -s /nonexistent/beta  "${LINKS}/beta"
ln -s /nonexistent/gamma "${LINKS}/gamma"

# shellcheck source=../../src/usr/local/lib/ai-tools/toolchain.lib.sh
if ! source "${LIB}" 2>/dev/null \
        || ! declare -F ai_tools_agent_residue >/dev/null 2>&1 \
        || ! declare -F ai_tools_agent_package_remove >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the residue functions"; finish; exit
fi

# The fixture is asserted before any reader reads it: a manifest set the resolver refuses would make every "not residue"
# case in this file pass for the wrong reason.
installed="$(ai_tools_installed_agents 2>/dev/null | cut -f1 | tr '\n' ' ')"
[[ "${installed}" == "acme beta " ]] \
    && pass "the fixture manifests read back through the resolver (installed: acme beta)" \
    || { fail "fixture manifests read back as '${installed}', expected 'acme beta ' -- the cases below cannot be trusted"; finish; exit; }

# ── The installed-not-enabled set ───────────────────────────────────────────────────────────────
not_enabled="$(ai_tools_installed_not_enabled_agents 2>/dev/null | cut -f1 | tr '\n' ' ')"
[[ "${not_enabled}" == "beta " ]] \
    && pass "installed-not-enabled is exactly the trusted manifests the enabled set does not name" \
    || fail "installed-not-enabled: got '${not_enabled}', expected 'beta '"
not_enabled_err="$(ai_tools_installed_not_enabled_agents 2>&1 >/dev/null)"
assert_msg MSG-M3A5 "${not_enabled_err}" "the untrusted manifest is reported, through the resolver's own code"

# ── ai_tools_agent_residue: the tree read ───────────────────────────────────────────────────────
residue="$(ai_tools_agent_residue "${NVM}" 2>/dev/null)"
expected=$'beta\t@acme/beta\t'"${NVM}/versions/node/v1.2.3"$'\n'$'beta\t@acme/beta\t'"${NVM}/versions/node/v2.0.0"
if [[ "${residue}" == "${expected}" ]]; then
    pass "residue is the disabled agent's package in each semver version directory holding it"
else
    fail "residue read: got '$(tr '\n' '|' <<<"${residue}")' expected '$(tr '\n' '|' <<<"${expected}")'"
fi
grep -q 'experimental' <<<"${residue}" && fail "an ENABLED agent's package was read as residue" \
                                       || pass "an enabled agent's package is never residue"
grep -q 'gamma' <<<"${residue}" && fail "an untrusted manifest's package was read as residue" \
                                 || pass "an untrusted manifest's package is not residue (it is not an agent)"
grep -q 'notaversion' <<<"${residue}" && fail "a non-semver version directory was read" \
                                       || pass "a version directory outside the semver shape is not read"
[[ -z "$(ai_tools_agent_residue "${FIXTURE_ROOT}/no-such-nvm" 2>/dev/null)" ]] \
    && pass "an absent toolchain holds no residue" || fail "an absent toolchain printed residue"

# The same tree with beta enabled too: no residue, whatever the tree holds.
printf 'AI_TOOLS_AGENTS="acme beta"\n' > "${CONF}"
[[ -z "$(ai_tools_agent_residue "${NVM}" 2>/dev/null)" ]] \
    && pass "a package is residue only while its agent is not enabled" \
    || fail "residue reported with every installed agent enabled"
printf 'AI_TOOLS_AGENTS="acme"\n' > "${CONF}"

# ── ai_tools_agent_residue_links: the operator's read ──────────────────────────────────────────
links="$(ai_tools_agent_residue_links "${LINKS}" 2>/dev/null)"
[[ "${links}" == $'beta\tbeta' ]] \
    && pass "the link reader names the disabled agent whose stable link exists, and no other" \
    || fail "residue links: got '$(tr '\n' '|' <<<"${links}")' expected 'beta<TAB>beta'"
rm -f "${LINKS}/beta"
[[ -z "$(ai_tools_agent_residue_links "${LINKS}" 2>/dev/null)" ]] \
    && pass "no link, no residue from the operator's vantage" || fail "residue links reported with the link gone"
ln -s /nonexistent/beta "${LINKS}/beta"

# ── ai_tools_path_in_use: the pure predicate ───────────────────────────────────────────────────
ai_tools_path_in_use /x/pkg /usr/bin/bash /x/pkg/bin/node \
    && pass "an executable under the directory is in use" || fail "an executable under the directory read as not in use"
ai_tools_path_in_use /x/pkg /x/pkg \
    && pass "the directory itself counts" || fail "the directory itself did not count"
ai_tools_path_in_use /x/pkg /x/pkg2/bin/node /x/pk \
    && fail "a sibling sharing the name prefix read as in use" || pass "a sibling sharing the name prefix is not in use"
ai_tools_path_in_use /x/pkg \
    && fail "an empty process list read as in use" || pass "an empty process list is not in use"
ai_tools_path_in_use '' /x \
    && fail "an empty directory matched" || pass "an empty directory matches nothing"
# The live collector, with a control this shell proves: the directory this bash executes from is in use.
own_exe_dir="$(dirname "$(readlink "/proc/$$/exe")")"
ai_tools_agent_package_in_use "${own_exe_dir}" \
    && pass "the live collector sees this shell's own executable (${own_exe_dir})" \
    || fail "the live collector did not see this shell's own executable under ${own_exe_dir}"

# ── ai_tools_agent_package_remove: the one write ───────────────────────────────────────────────
# npm stubbed in the fixture version's own bin, where the writer puts it first on PATH: it records its arguments
# and removes the last argument's package directory, as npm does. The arguments it records are what show the real npm
# was not run.
for ver in v1.2.3 v2.0.0; do
    mkdir -p "${NVM}/versions/node/${ver}/bin"
    cat > "${NVM}/versions/node/${ver}/bin/npm" <<EOF
#!/usr/bin/bash
printf '%s\n' "\$*" >> "${FIXTURE_ROOT}/npm-calls"
[[ "\${NPM_STUB_KEEP:-}" == 1 ]] && exit 0
rm -rf -- "${NVM}/versions/node/${ver}/lib/node_modules/\${@: -1}"
EOF
    chmod 0755 "${NVM}/versions/node/${ver}/bin/npm"
done
[[ -x "${NVM}/versions/node/v1.2.3/bin/npm" ]] || { fail "the npm stub is not executable where it sits"; finish; exit; }
calls() { cat "${FIXTURE_ROOT}/npm-calls" 2>/dev/null || true; }
reset_calls() { rm -f "${FIXTURE_ROOT}/npm-calls"; }

# (a) An enabled agent's package is refused, with no npm call and the directory intact.
reset_calls; rc=0
out="$(ai_tools_agent_package_remove "${NVM}/versions/node/v1.2.3" @acme/experimental 2>"${FIXTURE_ROOT}/err")" || rc=$?
if (( rc != 0 )) && [[ -z "${out}" && -d "${NVM}/versions/node/v1.2.3/lib/node_modules/@acme/experimental" && -z "$(calls)" ]]; then
    pass "an enabled agent's package is refused: non-zero, nothing printed, no npm call, directory intact"
else
    fail "enabled package: rc ${rc}, out '${out}', calls '$(calls)'"
fi
assert_msg MSG-X7Z9 "$(<"${FIXTURE_ROOT}/err")" "the refusal carries its code"

# (b) A package that is not there.
reset_calls
out="$(ai_tools_agent_package_remove "${NVM}/versions/node/v1.2.3" @acme/nothere 2>/dev/null)" && rc=0 || rc=$?
[[ "${rc}" -eq 0 && "${out}" == absent && -z "$(calls)" ]] \
    && pass "an absent package prints absent and calls no npm" || fail "absent package: rc ${rc}, out '${out}'"

# (c) A package a live process executes from is deferred: the collector stubbed to name a path under it.
reset_calls
_ai_tools_toolchain_exe_targets() { printf '%s\n' "${NVM}/versions/node/v1.2.3/lib/node_modules/@acme/beta/bin/x"; }
out="$(ai_tools_agent_package_remove "${NVM}/versions/node/v1.2.3" @acme/beta 2>"${FIXTURE_ROOT}/err")" && rc=0 || rc=$?
if [[ "${rc}" -eq 0 && "${out}" == deferred && -d "${NVM}/versions/node/v1.2.3/lib/node_modules/@acme/beta" && -z "$(calls)" ]]; then
    pass "a package in use is deferred: exit 0, no npm call, directory intact"
else
    fail "deferred: rc ${rc}, out '${out}', calls '$(calls)'"
fi
assert_msg MSG-X2B7 "$(<"${FIXTURE_ROOT}/err")" "the deferral carries its code"
_ai_tools_toolchain_exe_targets() { :; }

# (d) A removal: one uninstall under that version's npm with the version directory as the prefix, the directory gone,
# and the state-directory notice naming the manifest's config_dir.
reset_calls
out="$(ai_tools_agent_package_remove "${NVM}/versions/node/v1.2.3" @acme/beta 2>"${FIXTURE_ROOT}/err")" && rc=0 || rc=$?
if [[ "${rc}" -eq 0 && "${out}" == removed && ! -e "${NVM}/versions/node/v1.2.3/lib/node_modules/@acme/beta" ]]; then
    pass "a removal prints removed and the package directory is gone"
else
    fail "removed: rc ${rc}, out '${out}', dir $(test -e "${NVM}/versions/node/v1.2.3/lib/node_modules/@acme/beta" && echo present || echo gone)"
fi
[[ "$(calls)" == "uninstall -g --prefix ${NVM}/versions/node/v1.2.3 @acme/beta" ]] \
    && pass "exactly one npm uninstall, global, with the version directory as the prefix" \
    || fail "npm calls: '$(calls)'"
assert_msg MSG-G4M8 "$(<"${FIXTURE_ROOT}/err")" "the removal says what it left: the state directory"
grep -q '/opt/ai-tools/.beta' "${FIXTURE_ROOT}/err" \
    && pass "the notice names the agent's config_dir from its manifest" \
    || fail "the notice does not name /opt/ai-tools/.beta: $(tr '\n' '|' <"${FIXTURE_ROOT}/err")"

# (e) An uninstall that leaves the directory in place is a failure, reported.
package v1.2.3 @acme/beta; reset_calls
export NPM_STUB_KEEP=1
out="$(ai_tools_agent_package_remove "${NVM}/versions/node/v1.2.3" @acme/beta 2>"${FIXTURE_ROOT}/err")" && rc=0 || rc=$?
unset NPM_STUB_KEEP
[[ "${rc}" -ne 0 && -z "${out}" ]] \
    && pass "an uninstall that left the directory returns non-zero and prints nothing" || fail "kept dir: rc ${rc}, out '${out}'"
assert_msg MSG-X8F9 "$(<"${FIXTURE_ROOT}/err")" "the failed removal carries its code"

# (f) A name outside npm's package-name charset is refused before it becomes a path.
out="$(ai_tools_agent_package_remove "${NVM}/versions/node/v1.2.3" '../../etc' 2>"${FIXTURE_ROOT}/err")" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && -z "${out}" ]] && pass "a traversal is not an npm package name" || fail "traversal: rc ${rc}, out '${out}'"
assert_msg MSG-J5W4 "$(<"${FIXTURE_ROOT}/err")" "and is refused under the writer's argument code"

# (g) The erase form removes an enabled agent's package: the manifest is being erased with it.
reset_calls
out="$(ai_tools_agent_package_remove "${NVM}/versions/node/v1.2.3" @acme/experimental erase 2>/dev/null)" && rc=0 || rc=$?
[[ "${rc}" -eq 0 && "${out}" == removed && ! -e "${NVM}/versions/node/v1.2.3/lib/node_modules/@acme/experimental" ]] \
    && pass "the erase form removes an enabled agent's package" || fail "erase: rc ${rc}, out '${out}'"

# (h) ai_tools_agent_package_erase: every version directory holding the agent's package, from the manifest.
package v1.2.3 @acme/beta; reset_calls
out="$(ai_tools_agent_package_erase "${NVM}" beta 2>/dev/null)" && rc=0 || rc=$?
expected="${NVM}/versions/node/v1.2.3"$'\tremoved\n'"${NVM}/versions/node/v2.0.0"$'\tremoved'
[[ "${rc}" -eq 0 && "${out}" == "${expected}" ]] \
    && pass "the erase form over an agent removes its package from every version directory" \
    || fail "erase over beta: rc ${rc}, out '$(tr '\n' '|' <<<"${out}")'"
[[ "$(calls | wc -l)" -eq 2 ]] && pass "one uninstall per version directory" || fail "npm calls: '$(calls | tr '\n' '|')'"
[[ -z "$(ai_tools_agent_package_erase "${NVM}" nopkg 2>/dev/null)" ]] \
    && pass "an agent naming no package erases nothing" || fail "erase printed lines for a manifest naming no package"

# ── The order the updater runs the removal in ─────────────────────────────────────────────────
# The removal precedes install_packages: npm re-scans the whole global tree for install scripts on every call,
# so the rescan sees the tree without the package. Source order, read like the re-link's in unit/launcher-target.sh;
# outside a checkout there is no script to read and the case skips.
updater="${REPO_ROOT}/src/opt/ai-tools/bin/nvm-update.sh"
if [[ ! -d "${REPO_ROOT}/.git" || ! -r "${updater}" ]]; then
    skip "the removal precedes install_packages" "not a checkout, so the updater cannot be read from the repository"
else
    remove_line="$(grep -n -m1 -E '^[[:space:]]+remove_residue "\$\{nvm_dir\}"' "${updater}" | cut -d: -f1)"
    install_line="$(grep -n -m1 -E '^[[:space:]]+install_packages "\$\{allow_csv\}"' "${updater}" | cut -d: -f1)"
    if [[ -z "${remove_line}" || -z "${install_line}" ]]; then
        fail "the updater's removal or install call is no longer where this reads it (removal -> ${remove_line:-none}, install -> ${install_line:-none})"
    elif (( remove_line < install_line )); then
        pass "the updater removes residue before it installs packages"
    else
        fail "the updater installs packages at line ${install_line}, ahead of the removal at ${remove_line}"
    fi
fi

unset AI_TOOLS_AGENTS_DIR AI_TOOLS_OPERATOR_CONF
finish

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/launch-wrapper.sh
# Unit test for the launch gate library (launch-wrapper.lib.sh), the gates every agent's /usr/local/bin/<launcher>
# wrapper runs as the invoking operator before dropping to the sandbox account. Each gate is driven on its own, in its
# fail direction, against fixtures the test owns: the required libraries (a copy of the library repointed at a missing
# safe-paths or conf library refuses at init), the operator gate (the sandbox account and a non-operator are each
# refused with their own code), the residue gate (a stable link for an agent the fixture manifests install
# and the fixture operator.conf does not enable refuses before the executable resolves, naming the agent
# and the provisioning run; no link, or that agent enabled, passes; a copy repointed at a missing toolchain library
# refuses), the launcher resolution (a missing link, a target outside the versioned shape, and one carrying
# a parent-directory component are refused; the versioned shape resolves), the CWD gate (no allowlist, an unapproved
# directory, a sibling sharing a name prefix, a '!'-carved subdirectory and a path under it, a parked project,
# and an allowlisted protected directory are refused, each with its own code; an approved directory passes, reached
# through a symlink too, since the CWD is canonicalized first), the claim guard (an approved directory the sandbox group
# does not own is refused without a terminal), and the exec (refused when the gates did not run). It closes
# with the order: the gate runner answers a non-operator before it reads the allowlist.
#
# The library reads the allowlist off ${HOME} and the stable launcher symlink under AI_TOOLS_LAUNCHER_DIR, so each is
# pointed at the testdir; every run is as the account the case is about, through runuser, and detached with setsid so no
# /dev/tty prompt can fire -- a menu or a confirm then takes its no-terminal outcome, which is the one under test.
# The deployed library is driven, not a copy, except where a case breaks a load path on purpose. Run as root via sudo
# (suite contract); no agent package needs to be installed.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
# The remedies a refusal names are read back by key through the spelling table.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/cli-spelling.sh"
require_root
umask 022

readonly LIB="/usr/local/lib/ai-tools/launch-wrapper.lib.sh"
section "launch-wrapper.lib.sh: the gates every wrapper runs (unit)"

if [[ ! -r "${LIB}" ]]; then skip "launch gates" "library not installed at ${LIB}"; finish; exit; fi
if ! command -v runuser >/dev/null 2>&1; then skip "launch gates" "runuser unavailable"; finish; exit; fi
if ! command -v setsid >/dev/null 2>&1; then skip "launch gates" "setsid unavailable"; finish; exit; fi

mktestdir
chmod 755 "${TESTDIR}"
home="${TESTDIR}/home"
allowlist="${home}/.config/ai-tools/allowed-projects"
links="${TESTDIR}/bin"
approved="${TESTDIR}/approved"
excluded="${approved}/secret"
sibling="${TESTDIR}/approved2"
parked="${TESTDIR}/parked"
unapproved="${TESTDIR}/unapproved"
mkdir -p "${home}/.config/ai-tools" "${links}" "${excluded}/deeper" "${sibling}" "${parked}" "${unapproved}"
ln -s "${approved}" "${TESTDIR}/via-symlink"
chmod -R 0755 "${home}" "${approved}" "${sibling}" "${parked}" "${unapproved}"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${home}" "${approved}" "${sibling}" "${parked}" "${unapproved}"

# allowlist <line>... : the fixture allowlist, one entry per argument; no argument removes it.
allowlist() {
    if [[ $# -eq 0 ]]; then rm -f "${allowlist}"; return; fi
    printf '%s\n' "$@" > "${allowlist}"
    chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${allowlist}"
}
# link <target> : the stable launcher symlink for `claude`, dangling on purpose (the gate reads it with -L
# and readlink).
link() { rm -f "${links}/claude"; ln -s "$1" "${links}/claude"; }

# run <lib> <user> <cwd> <function> [<arg>...] : source <lib> as <user> from <cwd> with the hooks set, initialise it
# for the launcher FIXTURE_LAUNCHER (default `claude`), call <function> with the arguments, then print the three values
# the gates publish. Both
# streams land in OUT and the status in RC. AI_TOOLS_MSG_PLAIN keeps a refusal's code on its own line; the strict mode
# and IFS are the wrapper's, so the library runs as it does in one. A case that drives a gate downstream of the CWD gate
# seeds the project directory that gate would have published through FIXTURE_PROJECT_DIR; the residue cases point
# the resolver's two hooks at fixture manifests through FIXTURE_AGENTS_DIR and FIXTURE_OPERATOR_CONF (empty, each hook
# takes its deployed default); a locale case sets FIXTURE_LC_ALL, and the launch-hook cases drive a copy of the library
# whose hook directory is repointed at a fixture.
run() {
    local lib="$1" user="$2" cwd="$3"; shift 3
    RC=0
    # shellcheck disable=SC2016  # the $1.. are for the inner `bash -c`, not this shell -- do not expand here
    OUT="$(setsid runuser -u "${user}" -- env HOME="${home}" AI_TOOLS_LAUNCHER_DIR="${links}" AI_TOOLS_MSG_PLAIN=1 \
        FIXTURE_PROJECT_DIR="${FIXTURE_PROJECT_DIR:-}" FIXTURE_LAUNCHER="${FIXTURE_LAUNCHER:-claude}" \
        AI_TOOLS_AGENTS_DIR="${FIXTURE_AGENTS_DIR:-}" AI_TOOLS_OPERATOR_CONF="${FIXTURE_OPERATOR_CONF:-}" \
        LC_ALL="${FIXTURE_LC_ALL:-}" \
        bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'; cd "$1" || exit 98; source "$2" || exit 99
                 ai_tools_launch_init "${FIXTURE_LAUNCHER}"; AI_TOOLS_LAUNCH_PROJECT_DIR="${FIXTURE_PROJECT_DIR}"
                 shift 2; "$@"
                 printf "EXEC=%s\nPROJECT=%s\nAGENT=%s\n" "${AI_TOOLS_LAUNCH_EXEC}" "${AI_TOOLS_LAUNCH_PROJECT_DIR}" \
                     "${AI_TOOLS_LAUNCH_AGENT}"' \
        _ "${cwd}" "${lib}" "$@" < /dev/null 2>&1)" || RC=$?
}
# refused <what> <code> : the last run refused with <code> AND a non-zero status -- a refusal printed at exit 0 is one
# a wrapper would launch through.
refused() {
    if [[ "${RC}" -eq 0 ]]; then fail "$1: exit 0 (the gate passed): $(head -c 200 <<<"${OUT}" | tr '\n' '|')"
    else assert_msg "$2" "${OUT}" "$1"; fi
}
# passed <what> : the last run exited 0.
passed() {
    if [[ "${RC}" -eq 0 ]]; then pass "$1"; else fail "$1: rc ${RC}: $(head -c 300 <<<"${OUT}" | tr '\n' '|')"; fi
}
# says <what> <pattern> : the last run's output carries the content a refusal or a report owes the reader.
says() {
    if grep -qF -- "$2" <<<"${OUT}"; then pass "$1"; else fail "$1: '$2' absent: $(head -c 300 <<<"${OUT}" | tr '\n' '|')"; fi
}
# silent <what> <code-regex> : none of the codes fired -- the negative half of an ordering assertion.
silent() {
    if grep -qxE "$2" <<<"${OUT}"; then fail "$1: $(grep -xE "$2" <<<"${OUT}" | head -1) fired"; else pass "$1"; fi
}

link "/opt/ai-tools/.nvm/versions/node/v1.2.3/bin/claude"
allowlist "${approved}" "!${excluded}" "!${parked}"

# ── (0) Required libraries: init refuses when one will not load ────────────────
# A copy of the library with one load path repointed at a missing file; the copy is what breaks, the deployed libraries
# it goes on to load are real.
broken_safe="${TESTDIR}/launch-nosafe.lib.sh"
sed 's#^readonly SAFE_PATHS_LIB=.*#readonly SAFE_PATHS_LIB="/nonexistent/ai-tools/safe-paths.lib.sh"#' \
    "${LIB}" > "${broken_safe}"
broken_conf="${TESTDIR}/launch-noconf.lib.sh"
sed 's#^readonly CONF_LIB=.*#readonly CONF_LIB="/nonexistent/ai-tools/conf.lib.sh"#' "${LIB}" > "${broken_conf}"
chmod 644 "${broken_safe}" "${broken_conf}"
run "${broken_safe}" "${PROJECTS_USER}" "${approved}" true
refused "init refuses when safe-paths.lib.sh will not load (fail closed)" MSG-U6A9
run "${broken_conf}" "${PROJECTS_USER}" "${approved}" true
refused "init refuses when conf.lib.sh will not load (fail closed)" MSG-C2M7
run "${LIB}" "${PROJECTS_USER}" "${approved}" true
passed "init loads the three required libraries on the deployed library"

# ── (0b) Init admits the launcher name only in a launcher's charset ────────────
# The name is the command line's argv0, so a shape that could carry shell syntax or a path is refused before it names
# a path or prefixes a message. The match is made in the C locale: in a UTF-8 locale a bracket range takes in letters
# outside ASCII, which the control run shows.
FIXTURE_LAUNCHER='cl;id' run "${LIB}" "${PROJECTS_USER}" "${approved}" true
refused "a launcher name carrying shell syntax is refused at init" MSG-Z6F8
FIXTURE_LAUNCHER='../claude' run "${LIB}" "${PROJECTS_USER}" "${approved}" true
refused "a launcher name carrying a path is refused at init" MSG-Z6F8
utf8_locale="$(locale -a 2>/dev/null | grep -ixE 'en_US\.utf-?8|C\.utf-?8' | head -n 1 || true)"
if [[ -n "${utf8_locale}" ]] && LC_ALL="${utf8_locale}" bash -c '[[ "é" =~ ^[A-Za-z]+$ ]]'; then
    FIXTURE_LAUNCHER='clé' FIXTURE_LC_ALL="${utf8_locale}" run "${LIB}" "${PROJECTS_USER}" "${approved}" true
    refused "a non-ASCII letter is refused under ${utf8_locale}, where a bracket range admits it" MSG-Z6F8
else
    skip "non-ASCII launcher name" "no installed UTF-8 locale whose [A-Za-z] admits a non-ASCII letter"
fi

# ── (1) Operator gate ───────────────────────────────────────────────────────────
run "${LIB}" "${SANDBOX_USER}" "${approved}" ai_tools_launch_gate_operator
refused "the sandbox account is refused with its own code" MSG-N8Q4
if id -u nobody >/dev/null 2>&1 && ! id -nG nobody | tr ' ' '\n' | grep -qx ai-ops; then
    run "${LIB}" nobody "${approved}" ai_tools_launch_gate_operator
    refused "a non-operator is refused, naming the enrolment" MSG-C7C9
    says "and the refusal names the enrolment command" "ai-tools-admin operators add nobody"
else
    skip "non-operator refusal" "no 'nobody' account outside ai-ops on this host"
fi
if id -nG "${PROJECTS_USER}" | tr ' ' '\n' | grep -qx ai-ops; then
    run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_operator
    passed "an ai-ops member passes the operator gate"
else
    skip "operator passes the gate" "${PROJECTS_USER} is not in ai-ops here"
fi

# ── (1b) The residue gate: a disabled agent's launcher link refuses every launch ── Fixture manifests (a synthetic
# pair, no shipped agent named) and an operator.conf enabling one of them, root-owned so the resolver admits them.
# The other agent's stable link in the launcher directory is the operator-side evidence its package is still
# in the toolchain; the gate refuses on it before the executable resolves, naming the agent and the provisioning run.
# Without the link, and with that agent enabled too, the gate passes.
fixture_agents="${TESTDIR}/agents.d"; fixture_conf="${TESTDIR}/operator.conf"
mkdir -m 0755 "${fixture_agents}"
printf 'npm_package=@acme/experimental\nlauncher=claude\ndefault_enable=no\n' > "${fixture_agents}/acme.conf"
printf 'npm_package=@acme/beta\nlauncher=beta\ndefault_enable=no\n'         > "${fixture_agents}/beta.conf"
printf 'AI_TOOLS_AGENTS="agent-acme"\n' > "${fixture_conf}"
chmod 0644 "${fixture_agents}"/*.conf "${fixture_conf}"
ln -s "/opt/ai-tools/.nvm/versions/node/v1.2.3/bin/beta" "${links}/beta"
FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
    run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_residue
refused "a disabled agent's launcher link refuses the launch" MSG-H4E2
says "and the refusal names the agent" "beta"
says "and the refusal names the provisioning run" "sudo ai-tools-admin system bootstrap"
silent "and the executable is not resolved first" 'MSG-S4B3|MSG-S3K2'
rm -f "${links}/beta"
FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
    run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_residue
passed "no link for the disabled agent, no refusal"
ln -s "/opt/ai-tools/.nvm/versions/node/v1.2.3/bin/beta" "${links}/beta"
printf 'AI_TOOLS_AGENTS="agent-acme agent-beta"\n' > "${fixture_conf}"
FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
    run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_residue
passed "a link for an agent that is enabled is not residue"
rm -f "${links}/beta"
# The gate is fail-closed on its library: a copy of the wrapper library repointed at a missing toolchain library
# refuses, since a toolchain it could not read is reported as unreadable and not as clean.
broken_toolchain="${TESTDIR}/launch-notoolchain.lib.sh"
sed 's#^readonly TOOLCHAIN_LIB=.*#readonly TOOLCHAIN_LIB="/nonexistent/ai-tools/toolchain.lib.sh"#' \
    "${LIB}" > "${broken_toolchain}"
chmod 644 "${broken_toolchain}"
run "${broken_toolchain}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_residue
refused "the residue gate refuses when toolchain.lib.sh will not load (fail closed)" MSG-U9K8

# ── (1c) The provider-list gate: a name an earlier release wrote bare refuses every launch ── The list reader reads
# such a list as empty, so without this gate an unmigrated AI_TOOLS_AGENTS would be refused as "no agent is enabled"
# and an unmigrated AI_TOOLS_FILTERS would start a session with filtering off. The gate names each item and the command
# that rewrites it; a migrated file is the control.
printf 'AI_TOOLS_AGENTS=[acme]\nAI_TOOLS_FILTERS=[core, filter-dotnet]\n' > "${fixture_conf}"
FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
    run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_lists
refused "a provider name written without its kind prefix refuses the launch" MSG-V3Q5
says "and the refusal names each bare item" "AI_TOOLS_AGENTS acme, AI_TOOLS_FILTERS core"
says "and the refusal names the command that rewrites them" "sudo ai-tools-admin system post-upgrade"
printf 'AI_TOOLS_AGENTS=[agent-acme]\nAI_TOOLS_FILTERS=[filter-base, filter-dotnet]\n' > "${fixture_conf}"
FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
    run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_lists
passed "prefixed provider lists pass the gate"
printf 'AI_TOOLS_AGENTS="agent-acme"\n' > "${fixture_conf}"

# ── (1d) The launcher gate: the name must be an enabled agent's launcher ──────── Every launcher is one program, so
# the name decides the agent. The fixture enables acme (launcher claude) and installs beta (launcher beta) disabled.
FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
    run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_launcher
passed "an enabled agent's launcher passes the gate"
says "and the gate records the agent that claims it" "AGENT=acme"
FIXTURE_LAUNCHER=beta FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
    run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_launcher
refused "an installed but disabled agent's launcher is refused" MSG-F8N3
says "and the refusal names the enabled launchers" "enabled: claude"
FIXTURE_LAUNCHER=ai-tools-launch FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
    run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_launcher
refused "the launcher program invoked by its own name is refused" MSG-F8N3
chmod 0664 "${fixture_agents}/acme.conf"
FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
    run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_launcher
refused "a launcher whose manifest is group-writable is refused (the resolver does not admit it)" MSG-F8N3
chmod 0644 "${fixture_agents}/acme.conf"
broken_providers="${TESTDIR}/launch-noproviders.lib.sh"
sed 's#^readonly PROVIDERS_LIB=.*#readonly PROVIDERS_LIB="/nonexistent/ai-tools/providers.lib.sh"#' \
    "${LIB}" > "${broken_providers}"
chmod 644 "${broken_providers}"
FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
    run "${broken_providers}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_launcher
refused "the launcher gate refuses when providers.lib.sh will not load (fail closed)" MSG-C2C9

# ── (2) Launcher resolution: one hop, validated as the versioned shape ──────────
rm -f "${links}/claude"
run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_resolve_executable
refused "a missing launcher symlink is refused, naming the bootstrap" MSG-S4B3
says "and the refusal names the provisioning command" "sudo ai-tools-admin system bootstrap"
link "/usr/bin/claude"
run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_resolve_executable
refused "a target outside the versioned toolchain shape is refused" MSG-S3K2
link "/opt/ai-tools/.nvm/versions/node/v1.2.3/bin/codex"
run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_resolve_executable
refused "a target naming another launcher is refused" MSG-S3K2
link "/opt/ai-tools/.nvm/versions/node/v1.2.3/../v9.9.9/bin/claude"
run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_resolve_executable
refused "a target carrying a parent-directory component is refused" MSG-G8R4
link "/opt/ai-tools/.nvm/versions/node/v1.2.3/bin/claude"
run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_resolve_executable
passed "the versioned shape resolves (one hop, the target need not be reachable)"
says "and the resolved path is the link's target, unresolved further" \
    "EXEC=/opt/ai-tools/.nvm/versions/node/v1.2.3/bin/claude"

# ── (3) The CWD gate: backstop, then the allowlist ─────────────────────────────
allowlist
run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_project
refused "no allowlist file: refused, naming the file to create" MSG-C9S6
says "and the refusal names the allowlist path" "${allowlist}"
allowlist "${approved}" "!${excluded}" "!${parked}"

run "${LIB}" "${PROJECTS_USER}" "${unapproved}" ai_tools_launch_gate_project
refused "an unapproved directory is refused without a terminal (Cancel, decided by the have_tty branch)" MSG-N2Z7
says "and the refusal names the clone" "$(cli_cmd_text ai-tools.projects.clone)"
says "and the refusal names the claim" "$(cli_cmd_text ai-tools.projects.claim)"

run "${LIB}" "${PROJECTS_USER}" "${sibling}" ai_tools_launch_gate_project
refused "a sibling sharing the approved directory's name as a prefix is refused (exact-or-slash-prefixed)" MSG-N2Z7

run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_gate_project
passed "an approved directory passes the gate"
says "and the project directory published is the canonical path" "PROJECT=${approved}"
run "${LIB}" "${PROJECTS_USER}" "${TESTDIR}/via-symlink" ai_tools_launch_gate_project
passed "an approved directory reached through a symlink passes (the CWD is canonicalized first)"
says "and the project directory published is the real path, not the symlink" "PROJECT=${approved}"

run "${LIB}" "${PROJECTS_USER}" "${excluded}" ai_tools_launch_gate_project
refused "a '!'-carved subdirectory of an approved project is refused as carved out" MSG-K8K2
run "${LIB}" "${PROJECTS_USER}" "${excluded}/deeper" ai_tools_launch_gate_project
refused "a path under a '!'-carved subdirectory is refused by the ancestor entry" MSG-W2P3
run "${LIB}" "${PROJECTS_USER}" "${parked}" ai_tools_launch_gate_project
refused "a parked project ('!' on its own path, no approved parent) is refused as disabled" MSG-R2V6
says "and the refusal names the re-enable" "$(cli_cmd_text ai-tools.projects.enable)"

allowlist "/etc"
run "${LIB}" "${PROJECTS_USER}" /etc ai_tools_launch_gate_project
refused "an allowlisted protected directory is refused by the backstop before the allowlist" MSG-Q6H3
allowlist "${approved}" "!${excluded}" "!${parked}"

# ── (4) The claim guard: detects, offers, and without a terminal refuses ────────
# The approved directory is owned by the projects user and its group, not the sandbox group, so the ownership gap is
# open; with no terminal the default-NO confirm declines and the launch is refused.
FIXTURE_PROJECT_DIR="${approved}" run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_claim_guard
refused "an approved directory the sandbox group does not own is refused without a terminal" MSG-W4X4
says "and the screen names the clone" "$(cli_cmd_text ai-tools.projects.clone)"

# ── (5) The exec refuses when the gates did not run ───────────────────────────
run "${LIB}" "${PROJECTS_USER}" "${approved}" ai_tools_launch_session --version
refused "the session exec refuses with no resolved executable and project directory" MSG-B6G2

# ── (5b) The agent's launch hook: read only when declared, refused in every other state ── A copy of the library
# with the hook directory repointed at a fixture, root-owned like the real one; the manifest's launch_hook key is
# rewritten per case. The probe runs the launcher gate (which records the agent) and then the hook loader, and prints
# the arguments the hook appended.
hooks="${TESTDIR}/launch.d"
mkdir -m 0755 "${hooks}"
hook_lib="${TESTDIR}/launch-hookdir.lib.sh"
sed "s#^readonly LAUNCH_HOOK_DIR=.*#readonly LAUNCH_HOOK_DIR=\"${hooks}\"#" "${LIB}" > "${hook_lib}"
chmod 644 "${hook_lib}"
# manifest_hook <value|-> : the acme manifest with launch_hook=<value>, or without the key for -.
manifest_hook() {
    printf 'npm_package=@acme/experimental\nlauncher=claude\ndefault_enable=no\n' > "${fixture_agents}/acme.conf"
    [[ "$1" == - ]] || printf 'launch_hook=%s\n' "$1" >> "${fixture_agents}/acme.conf"
    chmod 0644 "${fixture_agents}/acme.conf"
}
# hook_file <body> : the acme hook, root-owned 0644.
hook_file() { printf '%s\n' "$1" > "${hooks}/acme.sh"; chmod 0644 "${hooks}/acme.sh"; }
readonly hook_probe='ai_tools_launch_gate_launcher; declare -a probe=(); ai_tools_launch_agent_args probe --typed; printf "ARGS=%s\n" "${probe[*]-}"'
hook_run() {
    FIXTURE_AGENTS_DIR="${fixture_agents}" FIXTURE_OPERATOR_CONF="${fixture_conf}" \
        run "${hook_lib}" "${PROJECTS_USER}" "${approved}" eval "${hook_probe}"
}
appends='ai_tools_launch_hook_args() { local -n _fixture_out="$1"; shift; _fixture_out+=("--hooked"); }'
hook_file "${appends}"

manifest_hook -
hook_run
passed "an agent that does not declare a hook launches"
if grep -qF -- "--hooked" <<<"${OUT}"; then fail "an undeclared hook was sourced"; else pass "and its launch.d file is not read, though present"; fi
manifest_hook no
hook_run
passed "launch_hook=no reads no hook either"
manifest_hook yes
hook_run
passed "a declared, root-owned hook runs"
says "and the arguments it appends reach the launch" "--hooked"
manifest_hook maybe
hook_run
refused "a launch_hook value other than yes or no refuses the launch" MSG-G9H2
manifest_hook yes
rm -f "${hooks}/acme.sh"
hook_run
refused "a declared hook whose file is missing refuses the launch" MSG-G9H2
hook_file "${appends}"; chmod 0664 "${hooks}/acme.sh"
hook_run
refused "a group-writable hook file refuses the launch" MSG-G9H2
chmod 0644 "${hooks}/acme.sh"; chmod 0775 "${hooks}"
hook_run
refused "a group-writable hook directory refuses the launch" MSG-G9H2
chmod 0755 "${hooks}"
hook_file '# defines no hook function'
hook_run
refused "a hook that does not define ai_tools_launch_hook_args refuses the launch" MSG-G9H2
hook_file 'ai_tools_launch_hook_args() { return 1; }'
hook_run
refused "a hook that returns non-zero refuses the launch" MSG-G5V4
manifest_hook -

# ── (6) Order: the operator gate answers before the allowlist is read ───────────
# Driven from the unapproved directory with an argument pair that would keep the CWD gates in the path: a non-operator
# is refused with the operator code and none of the CWD gate's codes fires.
run "${LIB}" "${SANDBOX_USER}" "${unapproved}" ai_tools_launch_gates --version --gate-probe
refused "the gate runner refuses the sandbox account first" MSG-N8Q4
silent "and does not reach the CWD gate as a non-operator" 'MSG-N2Z7|MSG-C9S6|MSG-K8K2|MSG-R2V6|MSG-W2P3'
FIXTURE_LAUNCHER=ai-tools-launch run "${LIB}" "${SANDBOX_USER}" "${unapproved}" ai_tools_launch_gates
refused "a name no agent claims is answered by the operator gate first for a non-operator" MSG-N8Q4
silent "and the launcher gate does not run ahead of it" 'MSG-F8N3'

# ── (7) ai-tools-launch: the startup hardening, measured ───────────────────────
# The launcher runs in the operator's environment, so bash must not source $BASH_ENV or import an exported function
# before the first line runs. A copy with the gate library repointed at a missing file drives the refusal path, which
# calls `logger`; an exported `logger` function and a BASH_ENV file each leave a marker if they take effect. The control
# is the same run without -p, which must leave both markers -- otherwise the run proves nothing about -p. The copy is
# read by bash rather than executed, so a noexec /tmp does not matter, and it is reached through a symlink named claude,
# as a launcher is.
launcher_src=/usr/local/bin/ai-tools-launch
[[ -r "${launcher_src}" ]] || launcher_src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/usr/local/bin/ai-tools-launch.sh"
if [[ ! -r "${launcher_src}" ]]; then
    skip "ai-tools-launch hardening" "launcher not found at ${launcher_src}"
else
    if [[ "$(head -n 1 "${launcher_src}")" == '#!/usr/bin/bash -p' ]]; then
        pass "the launcher names its interpreter by absolute path, in privileged mode"
    else
        fail "the launcher's shebang is $(head -n 1 "${launcher_src}"), not #!/usr/bin/bash -p"
    fi
    if grep -qxF 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin' "${launcher_src}"; then
        pass "the launcher pins PATH to the root-owned system directories"
    else
        fail "the launcher does not pin PATH"
    fi
    wdir="${TESTDIR}/launcher"
    mkdir -m 0755 "${wdir}"
    sed 's#^readonly LAUNCH_LIB=.*#readonly LAUNCH_LIB="/nonexistent/ai-tools/launch-wrapper.lib.sh"#' \
        "${launcher_src}" > "${wdir}/ai-tools-launch"
    ln -s ai-tools-launch "${wdir}/claude"
    printf ': > "%s/bash_env.marker"\n' "${wdir}" > "${wdir}/bash_env"
    chmod 0644 "${wdir}/ai-tools-launch" "${wdir}/bash_env"
    chown "${PROJECTS_USER}" "${wdir}"
    # launch_env <interpreter-flags...> : run the copy as the projects user with the two injections set.
    launch_env() {
        rm -f "${wdir}"/*.marker
        RC=0
        OUT="$(setsid runuser -u "${PROJECTS_USER}" -- env BASH_ENV="${wdir}/bash_env" \
            "BASH_FUNC_logger%%=() { : > ${wdir}/func.marker; }" /usr/bin/bash "$@" "${wdir}/claude" < /dev/null 2>&1)" \
            || RC=$?
    }
    launch_env
    if [[ -e "${wdir}/bash_env.marker" && -e "${wdir}/func.marker" ]]; then
        pass "control: without -p, bash sources BASH_ENV and runs an imported function"
        launch_env -p
        refused "the launcher refuses when its gate library will not load (fail closed)" MSG-R3Q4
        says "and the refusal names the launcher program" "ai-tools-launch: cannot load the launch gate library"
        if [[ -e "${wdir}/bash_env.marker" || -e "${wdir}/func.marker" ]]; then
            fail "with -p, the environment's code still ran ($(cd "${wdir}" && ls -- *.marker | tr '\n' ' '))"
        else
            pass "with -p, neither BASH_ENV nor an exported function takes effect"
        fi
    else
        fail "control run did not take the injected code, so the -p run would prove nothing (markers: $(cd "${wdir}" && ls -- *.marker 2>/dev/null | tr '\n' ' '))"
    fi
fi

finish

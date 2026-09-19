#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/launch-wrapper.lib.sh
# The launch gates every agent's /usr/local/bin/<launcher> wrapper runs, in one library (644 root:root, owned
# by ai-tools-base, sandbox-account tokens substituted at install). A wrapper sources it fail-closed, then calls
# ai_tools_launch_init <launcher>, ai_tools_launch_gates "$@", resolves whatever agent-specific launch inputs it
# carries, and ends in ai_tools_launch_session, which execs the shared confinement shim /opt/ai-tools/bin/ai-tools-run
# as the sandbox account via sudo. Everything here runs as the invoking operator, before the drop, and every refusal
# moves to less access: a library that will not load, a caller outside ai-ops, a launcher symlink that does not resolve
# to the versioned shape, a CWD outside the allowlist or inside a protected directory, and an incompletely claimed
# project each stop the launch through ai_tools_launch_die. The gate order, what each refusal distinguishes, and the two
# variables the exec carries through sudo are in launch.rule.md; the wrapper contract each agent package holds to is
# stated there too.
#
# The library reads the operator's allowlist off ${HOME} and the stable launcher symlink
# under ${AI_TOOLS_LAUNCHER_DIR:-/opt/ai-tools/bin}, the hook ai-tools.sh and relabel.lib.sh already read for the same
# directory; neither moves an access decision, since the resolved path must still match the versioned shape here
# and ai-tools-run re-validates it against the enabled manifests after the drop. The unit test drives each gate
# through them against fixtures.

[[ -n "${_AI_TOOLS_LAUNCH_LIB_LOADED:-}" ]] && return 0
readonly _AI_TOOLS_LAUNCH_LIB_LOADED=1

readonly AI_TOOLS_NVM_DIR="/opt/ai-tools/.nvm"
readonly AI_TOOLS_RUN="/opt/ai-tools/bin/ai-tools-run"
readonly AI_TOOLS_CLI="/usr/local/bin/ai-tools"
readonly OPERATORS_GROUP="ai-ops"
readonly SANDBOX_USER="@SANDBOX_USER@"
readonly SANDBOX_GROUP="@SANDBOX_GROUP@"
# shellcheck disable=SC2034  # read by a wrapper's own launch-input resolvers (claude.sh's custom system prompt)
readonly OPERATOR_CONF="/etc/ai-tools/operator.conf"
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
readonly CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"
# The claim guard's read-only inputs: the sandbox account's gitconfig (root-owned 644, so the safe.directory gap is read
# here as the operator) and the root helper that writes an entry into it (the same one the CLI's reg_safedir uses; see
# ai-tools-safedir's header for the model).
readonly GITCONFIG="/opt/ai-tools/.gitconfig"
readonly SAFEDIR_BIN="/usr/local/libexec/ai-tools/ai-tools-safedir"

# Set by ai_tools_launch_init: the launcher name the wrapper was invoked as, which prefixes every message and names
# the stable symlink. Set by the gates: the resolved versioned executable and the canonicalized project directory,
# the two values ai_tools_launch_session exports across sudo.
AI_TOOLS_LAUNCH_NAME=""
AI_TOOLS_LAUNCH_EXEC=""
AI_TOOLS_LAUNCH_PROJECT_DIR=""

# ai_tools_launch_have_tty -- 0 only when a controlling terminal can be opened. `[[ -r /dev/tty ]]` is NOT
# a controlling-tty test: the /dev/tty node is mode crw-rw-rw-, so the permission bits read true even with no
# controlling terminal (e.g. under setsid). Opening it is the only honest probe: with no controlling tty the open fails
# ENXIO and this returns non-zero, so the prompt guards skip cleanly instead of writing to /dev/tty and aborting.
ai_tools_launch_have_tty() { { : > /dev/tty; } 2>/dev/null; }

# ai_tools_launch_pause_if_tty -- wait for Enter when stdin is a tty, so a refusal is read before the window closes.
# A bare terminal: the user reads the error and presses Enter to dismiss. An IDE console (Rider, etc.) that closes
# on exit: the pause keeps it open. A script/pipe: stdin is not a tty, so the read is skipped.
ai_tools_launch_pause_if_tty() {
    if [[ -t 0 ]]; then
        read -r -p "Press Enter to close..." < /dev/tty 2>/dev/null || true
    fi
}

# _ai_tools_launch_error [<code>] <line>... -- frame the lines on stderr through ai_tools_msg_error, the first one
# prefixed with the launcher name. The prefix belongs to the emitter, so a message text does not carry one of its own:
# the code identifies the situation and the prefix names the wrapper that raised it (a line after the first names it
# where it reads as a second sentence of the same voice).
_ai_tools_launch_error() {
    local code=""
    if ai_tools_msg_is_code "${1-}"; then code="$1"; shift; fi
    local first="${AI_TOOLS_LAUNCH_NAME}: $1"; shift
    ai_tools_msg_error ${code:+"${code}"} "${first}" "$@"
}

# ai_tools_launch_die [<code>] <line>... -- _ai_tools_launch_error, pause on a tty, and exit 1.
ai_tools_launch_die() {
    _ai_tools_launch_error "$@"
    ai_tools_launch_pause_if_tty
    exit 1
}

# ai_tools_launch_init <launcher> -- record the launcher name and load the three required libraries, fail-closed.
# msg.lib.sh carries the yes/no decisions and the framed refusal every later gate emits, so with it missing the refusal
# is printed plain and the launch stops; safe-paths.lib.sh is the launch path's front-line guard, verified once die is
# available; conf.lib.sh reads the allowlist, and without ai_tools_conf_path_entry every line parses as no entry,
# which refuses every launch -- fail-closed, but indistinguishable from "you have no projects", so refusing here names
# the missing component. Each failure is logged to journald (via logger: the wrapper does not source log.lib, and it may
# share the broken directory).
ai_tools_launch_init() {
    AI_TOOLS_LAUNCH_NAME="$1"
    local name="${AI_TOOLS_LAUNCH_NAME}"
    # shellcheck source=SCRIPTDIR/msg.lib.sh
    if ! source "${MSG_LIB}" 2>/dev/null; then
        command -v logger >/dev/null 2>&1 \
            && logger -t "${name}-wrapper" -p user.err \
                "required library ${MSG_LIB} unavailable -- launch refused (fail closed)"
        printf '%s: cannot load required library %s\n' "${name}" "${MSG_LIB}" >&2
        printf '  the install is incomplete or /usr/local/lib/ai-tools is not traversable;\n' >&2
        printf '  refusing to launch (fail closed) -- reinstall ai-tools, then retry.\n' >&2
        exit 1
    fi
    # One fixed 80-column frame for every box the wrapper shows, so the guidance screens and refusals of a launch align
    # instead of each sizing to its own text.
    export AI_TOOLS_MSG_FULLWIDTH=1
    # How the ai-tools CLI is named in the guidance screens: the bare command where PATH resolves it (both binaries are
    # on an operator's PATH, so the absolute path reads as a second, unrelated tool), the absolute path on a host
    # whose PATH does not.
    CLI_CMD="$(ai_tools_cmd_display "${AI_TOOLS_CLI}")"
    readonly CLI_CMD

    # A silent no-op stub would start the wrapper with the protected-path guard OFF -- the quiet degradation that lets
    # a broken or mis-permissioned install (e.g. a lib dir an operator cannot traverse) pass unnoticed. Source it, then
    # require its guard functions to exist; refuse otherwise, naming the likely cause. Every safe-paths consumer fails
    # closed the same way (no fail-open stub anywhere); see safe-paths.rule.md.
    # shellcheck source=SCRIPTDIR/safe-paths.lib.sh
    if ! source "${SAFE_PATHS_LIB}" 2>/dev/null \
            || ! declare -F ai_tools_assert_safe_target  >/dev/null 2>&1 \
            || ! declare -F ai_tools_protected_path_match >/dev/null 2>&1; then
        command -v logger >/dev/null 2>&1 \
            && logger -t "${name}" -p user.err \
                "required safety library ${SAFE_PATHS_LIB} unavailable for $(id -un 2>/dev/null) -- launch refused (fail closed)"
        ai_tools_launch_die MSG-U6A9 "cannot load the launch safety library -- refusing to start" \
            "       ${SAFE_PATHS_LIB}" \
            "       A critical ai-tools component is missing or unreadable, so the protected-path" \
            "       guard cannot run. Check that /usr/local/lib/ai-tools is traversable and its" \
            "       libraries are present, then reinstall the package if needed."
    fi

    # shellcheck source=SCRIPTDIR/conf.lib.sh
    if ! source "${CONF_LIB}" 2>/dev/null \
            || ! declare -F ai_tools_conf_path_entry >/dev/null 2>&1; then
        command -v logger >/dev/null 2>&1 \
            && logger -t "${name}" -p user.err \
                "required config library ${CONF_LIB} unavailable for $(id -un 2>/dev/null) -- launch refused (fail closed)"
        ai_tools_launch_die MSG-C2M7 "cannot load the config library -- refusing to start" \
            "       ${CONF_LIB}" \
            "       Without it the approved-projects list cannot be read, so no project would" \
            "       resolve as allowed. Check that /usr/local/lib/ai-tools is traversable and its" \
            "       libraries are present, then reinstall the package if needed."
    fi
}

# ai_tools_launch_gate_operator -- refuse a caller outside the ai-ops operators group. The sudoers grant is a %ai-ops
# group rule, so a non-operator fails at sudo regardless -- this gate turns that raw denial into a framed refusal
# that names the right next step. `id -nG` (no user argument) lists THIS shell's live credential set, the same set sudo
# enforces against; the space-padding makes the match exact so a group whose name merely contains "ai-ops" cannot
# satisfy it. When the live check fails the refusal distinguishes three cases, because the fix differs in each:
# the sandbox account (which must never be an operator), an operator whose shell predates the grant (a stale session --
# re-login), and a genuine non-operator.
ai_tools_launch_gate_operator() {
    local name="${AI_TOOLS_LAUNCH_NAME}" user
    user="$(id -un)"
    if [[ " $(id -nG 2>/dev/null) " != *" ${OPERATORS_GROUP} "* ]]; then
        if [[ "${user}" == "${SANDBOX_USER}" ]]; then
            # The sandbox account itself (e.g. `sudo -u ai-tools claude`). It is deliberately kept out of ai-ops --
            # a member could drive a session as an operator -- so "add it to the group" is the wrong advice. An operator
            # launches the wrapper from their own login and the wrapper drops to the sandbox account on its own.
            ai_tools_launch_die MSG-N8Q4 "this is the sandbox account ${SANDBOX_USER}, which is not an ai-tools operator" \
                "       the sandbox account must never be one -- launch ${name} from your operator login;" \
                "       the wrapper drops to ${SANDBOX_USER} for you"
        elif id -nG "${user}" 2>/dev/null | tr ' ' '\n' | grep -qx "${OPERATORS_GROUP}"; then
            # In ai-ops per the group database (`id -nG <user>` reads it) but absent from this shell's live credentials
            # -- a session started before the grant took effect. A fresh login rebuilds the credential set; newgrp
            # adopts the group in the current shell.
            ai_tools_launch_die MSG-R7Z3 "this shell started before the grant -- ${user} is an ai-tools operator per the group database" \
                "       start a fresh login session to pick up the ${OPERATORS_GROUP} group --" \
                "       log out and back in, or adopt it in this shell with:" \
                "         newgrp ${OPERATORS_GROUP}"
        else
            ai_tools_launch_die MSG-C7C9 "not an ai-tools operator -- ${user} is not a member of the ${OPERATORS_GROUP} group" \
                "       an administrator can grant access with:" \
                "         sudo ai-tools-admin operators add ${user}"
        fi
    fi
}

# ai_tools_launch_resolve_executable -- resolve the stable launcher symlink one hop into AI_TOOLS_LAUNCH_EXEC. Tests
# the symlink itself with `-L`, NOT `-e`: `-e` dereferences the full chain (bin/<launcher> -> versioned bin/<launcher>
# -> the package's own executable), and the package directory is mode 700 owned by the sandbox account. The invoking
# user cannot stat the final target (EACCES), so `-e` would report "not found" on a perfectly valid link. `-L` checks
# link existence without traversing past the first hop; the readlink + string validation handle correctness,
# and the binary is only ever reached via sudo as the sandbox account.
#
# One hop, never realpath (or `readlink -f`): the versioned bin/<launcher> is itself an npm symlink into the package.
# Following it fully would require traversing the package directory, which the invoking user cannot enter -- realpath
# would fail with EACCES and, under `set -e`, abort the wrapper with no message. The target must be an absolute, ..-free
# path under the sandbox toolchain matching the versioned shape ai-tools-run accepts; this is an integrity check
# on the link (only root writes /opt/ai-tools/bin), made with string checks alone so no filesystem traversal beyond
# the symlink itself is required.
ai_tools_launch_resolve_executable() {
    local name="${AI_TOOLS_LAUNCH_NAME}"
    local launcher_link="${AI_TOOLS_LAUNCHER_DIR:-/opt/ai-tools/bin}/${name}"
    if [[ ! -L "${launcher_link}" ]]; then
        ai_tools_launch_die MSG-S4B3 "launcher symlink not found at ${launcher_link}" \
            "       the sandbox toolchain is not provisioned yet -- provision it with:" \
            "         sudo ai-tools-admin system bootstrap"
    fi
    AI_TOOLS_LAUNCH_EXEC="$(readlink -- "${launcher_link}")" \
        || ai_tools_launch_die MSG-S5Y9 "cannot read the launcher symlink ${launcher_link} -- reinstall or run nvm-update.sh"
    case "${AI_TOOLS_LAUNCH_EXEC}" in
        "${AI_TOOLS_NVM_DIR}/versions/node/"*"/bin/${name}") ;;
        *) ai_tools_launch_die MSG-S3K2 "resolved path '${AI_TOOLS_LAUNCH_EXEC}' is not an approved ai-tools binary" ;;
    esac
    if [[ "${AI_TOOLS_LAUNCH_EXEC}" == *"/../"* ]]; then
        ai_tools_launch_die MSG-G8R4 "resolved path '${AI_TOOLS_LAUNCH_EXEC}' contains parent-directory references"
    fi
}

# ai_tools_launch_print_and_exit "$@" -- exec the confined session for a sole `--version`/`--help`; return otherwise.
# Print-and-exit invocations carry no project surface: the binary prints and exits without touching a working tree,
# so no allowlist, backstop, or claim gate applies to the CWD. The session still runs confined as the sandbox account --
# the same validated binary under the same unit properties -- with the sandbox home as its WorkingDirectory (always
# present, no project grant implied).
ai_tools_launch_print_and_exit() {
    [[ $# -eq 1 ]] || return 0
    case "$1" in
        --version|-v|--help|-h)
            export AI_TOOLS_AGENT_EXEC="${AI_TOOLS_LAUNCH_EXEC}"
            export AI_TOOLS_PROJECT_DIR="/opt/ai-tools"
            exec sudo -u "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -- "${AI_TOOLS_RUN}" "$@"
            ;;
    esac
}

# ai_tools_launch_gate_project -- canonicalize the CWD into AI_TOOLS_LAUNCH_PROJECT_DIR and refuse it unless approved.
# The protected-paths backstop runs before the allowlist is consulted, so a mis-entered allowlist cannot start a session
# where the ownership handback would then act. The allowlist is ~/.config/ai-tools/allowed-projects (one path per line,
# through the shared grammar); lines beginning with ! are exclusions and override allows -- exactly
# as in ai-tools-chown, so ! means the same thing in the launch gate as it does in the ownership hand-back:
# a subdirectory under an approved parent can be carved back out, and the agent refuses to start there. A CWD that is
# not approved draws the setup menu (create a sandbox clone, claim here, cancel) on a terminal, and is refused without
# one.
ai_tools_launch_gate_project() {
    local name="${AI_TOOLS_LAUNCH_NAME}" cwd allowlist entry dir pat sel
    allowlist="${HOME}/.config/ai-tools/allowed-projects"
    if [[ ! -f "${allowlist}" ]]; then
        ai_tools_launch_die MSG-C9S6 "approved-projects allowlist not found" \
            "${name}: create ${allowlist} and add project directories"
    fi
    cwd="$(realpath -e "${PWD}" 2>/dev/null)" \
        || ai_tools_launch_die MSG-S8D9 "cannot resolve working directory"

    ai_tools_assert_safe_target "${cwd}" "launch" || exit 1

    local -a allowed=()
    local -a excluded=()
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        # One shared grammar (conf.lib.sh): whole-line and end-of-line comments, and quotes for a path carrying a space
        # or a literal `#`. A line that does not yield an entry (blank, or a comment) is skipped.
        ai_tools_conf_path_entry "${entry}" || continue
        entry="${_ai_tools_conf_value}"
        if [[ "${entry}" == '!'* ]]; then
            excluded+=("${entry:1}")              # strip leading !, keep raw (may contain glob)
        else
            dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
            allowed+=("${dir}")
        fi
    done < "${allowlist}"

    # Exclusions are checked first and override allows (mirrors ai-tools-chown). Two shapes reach this, and they are
    # DIFFERENT situations for the operator standing here, so they are reported apart: a line naming this very directory
    # is a project someone PARKED -- `ai-tools projects disable`, or the same edit by hand -- and the way back is one
    # command, while a line covering it from an ancestor (a parent, or a glob) is a subtree deliberately withheld
    # from a project, where the remedy is to edit that line rather than to re-enable anything. Telling an operator their
    # parked project is merely "excluded" leaves them to work out which of the two they are in.
    if [[ "${#excluded[@]}" -gt 0 ]]; then
        for pat in "${excluded[@]}"; do
            pat="${pat%/}"                         # normalise: strip trailing slash
            if [[ "${cwd}" == ${pat} ]]; then
                # A line naming this very directory is one of two things, and the same test the CLI applies separates
                # them: an approved project STRICTLY ENCLOSING makes this a subtree withheld from it, while none makes
                # it a project that was parked. Exact-match alone cannot tell them apart -- a carve-out names its own
                # path too. Guarded on the count, not written as "${allowed[@]:-}": an EMPTY array expands that way
                # to one empty element, and "${dir}/"* is then the pattern /* -- which matches every absolute path,
                # so a parked project with no approved entries at all would report as carved out of an empty set.
                if [[ "${#allowed[@]}" -gt 0 ]]; then
                    for dir in "${allowed[@]}"; do
                        [[ "${cwd}" == "${dir}/"* ]] || continue
                        ai_tools_launch_die MSG-K8K2 "excluded by '!' rule in approved projects list: $(pwd)" \
                            "${name}: it is carved out of the approved project ${dir}; edit ${allowlist} to change that"
                    done
                fi
                ai_tools_launch_die MSG-R2V6 "this project is disabled in your approved projects list: $(pwd)" \
                    "${name}: no session starts here until it is re-enabled -- its files, group and label are untouched" \
                    "${name}: re-enable it with:  ${CLI_CMD} projects enable"
            fi
            # For plain paths (no glob), also exclude directory contents
            if [[ "${pat}" != *'*'* && "${cwd}" == "${pat}/"* ]]; then
                ai_tools_launch_die MSG-W2P3 "excluded by '!' rule in approved projects list: $(pwd)" \
                    "${name}: an entry above this directory carves it out; edit ${allowlist} to change that"
            fi
        done
    fi

    local approved=false
    if [[ "${#allowed[@]}" -gt 0 ]]; then
        for dir in "${allowed[@]}"; do
            if [[ "${cwd}" == "${dir}" || "${cwd}" == "${dir}/"* ]]; then
                approved=true
                break
            fi
        done
    fi
    if [[ "${approved}" != true ]]; then
        # The block says what the screen is about; the MENU states the options, once (each with the consequence
        # that distinguishes it -- option 1 does not start a session here).
        ai_tools_msg_block "Set up this project for the sandboxed agent" \
            "The agent has no access here yet. Choose how it should work on this project."
        # No terminal: take Cancel and refuse to launch, without asking. The menu itself has no default (it re-asks,
        # then gives up), so the safe outcome of an unattended or piped run is decided HERE, by the have_tty branch,
        # rather than by a default index.
        sel=3
        if ai_tools_launch_have_tty; then
            sel="$(ai_tools_msg_pick none \
                "Create sandbox"$'\t'"work in an isolated copy; the session runs there, not here" \
                "Claim here"$'\t'"work in this directory; its group becomes ${SANDBOX_GROUP}" \
                "Cancel"$'\t'"change nothing")" || sel=3
        fi
        case "${sel}" in
            1)
                # Create sandbox -- an isolated shallow clone under the sandbox-projects area. The agent runs
                # IN the clone, so the wrapper points the user there and stops; it does not launch in this directory.
                if "${AI_TOOLS_CLI}" projects clone "${cwd}"; then
                    ai_tools_msg_notice "${name}: sandbox ready -- cd into the clone path shown above, then start your agent there"
                    ai_tools_launch_pause_if_tty
                    exit 0
                fi
                ai_tools_launch_die "sandbox creation did not complete -- see the output above"
                ;;
            2)
                # Claim in place. `--yes` pre-answers only the CLI's proceed prompt (you chose claiming here);
                # the secret-lockdown prompt, the .git history grant, and the traverse grant stay explicit.
                # `ai-tools projects claim` is idempotent and registers a brand-new path from scratch.
                "${AI_TOOLS_CLI}" projects claim --yes "${cwd}" || true
                # Confirm the claim registered the path before falling through to the claim guard, which re-verifies
                # ownership/label (both just applied) and then launches. Match through the shared grammar so an entry
                # the claim wrote with a comment or quotes is not read as "claim did not complete" (conf.lib.sh).
                ai_tools_conf_allowlist_has_entry "${allowlist}" "${cwd}" 2>/dev/null \
                    || ai_tools_launch_die "${cwd}: still not accessible -- the claim did not complete"
                ;;
            *)
                # Cancel -- also the no-terminal path and an unanswered menu. The menu screen does not carry
                # the commands, so the cancel path names them itself: PLAIN and under the frame, since a wrapping
                # emitter would break a command across lines (messaging.rule.md).
                _ai_tools_launch_error MSG-N2Z7 "no session started -- ${cwd} is not set up for the agent."
                printf '\n' >&2
                printf '  %-30s %s\n' \
                    "${CLI_CMD} projects clone" "isolated copy under the sandbox area" \
                    "${CLI_CMD} projects claim"  "claim this directory in place" >&2
                printf '\nRun one of these, then start your agent again.\n' >&2
                ai_tools_launch_pause_if_tty
                exit 1
                ;;
        esac
    fi
    AI_TOOLS_LAUNCH_PROJECT_DIR="${cwd}"
}

# _ai_tools_launch_project_labelled <dir> -- 0 when SELinux is NOT enforcing (no label needed) or <dir> already carries
# ai_tools_project_t. Read-only, no privilege; the authoritative relabel lives in `ai-tools projects claim` (->
# ai-tools-relabel), never duplicated here.
_ai_tools_launch_project_labelled() {
    command -v getenforce >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] || return 0
    ls -Zd "$1" 2>/dev/null | grep -q ':ai_tools_project_t:'
}

# ai_tools_launch_claim_guard -- refuse an approved CWD whose claim is incomplete; offer the claim, never perform it.
# The cwd passed the allowlist, but a registered path can still be incompletely "claimed". Three independent gaps, all
# detected read-only here; the fix is always delegated to `ai-tools projects claim` (idempotent) -- this library never
# performs a chgrp or a relabel itself, it only detects, offers, and (on consent) calls the CLI:
#   ownership  -- group not the sandbox group, or no group-execute. The sandbox user runs with this dir as its cwd,
#                 and Node's posix_spawn then fails EACCES on every child (hooks, the Bash tool): the session starts
#                 but cannot spawn a child. FATAL. Closing it grants the agent recursive group access to this real
#                 tree (a chgrp) -- the heavy LAST-RESORT path; the clean alternative is an isolated sandbox clone,
#                 recommended first.
#   label      -- under SELinux enforcing, the tree must carry ai_tools_project_t or the agent (ai_tools_t) cannot
#                 read/write it: again the session starts but every file op is denied. FATAL. The relabel needs root,
#                 so the claim runs it via sudo. It relabels in place, so no clone is needed.
#   safe.dir   -- cwd absent from the sandbox account's git safe.directory. git refuses to operate ("dubious
#                 ownership"). Non-fatal; only git, no ownership/label change.
ai_tools_launch_claim_guard() {
    local name="${AI_TOOLS_LAUNCH_NAME}" cwd="${AI_TOOLS_LAUNCH_PROJECT_DIR}"
    local own_gap=false label_gap=false safe_gap=false cwd_gid cwd_mode claim_default claim_ok
    cwd_gid="$(stat -c '%G' "${cwd}" 2>/dev/null || true)"
    cwd_mode="$(stat -c '%a' "${cwd}" 2>/dev/null || true)"
    if [[ "${cwd_gid}" != "${SANDBOX_GROUP}" ]] || (( (0${cwd_mode:-0} & 010) == 0 )); then
        own_gap=true
    fi
    _ai_tools_launch_project_labelled "${cwd}" || label_gap=true
    if ! git config --file "${GITCONFIG}" --get-all safe.directory 2>/dev/null \
            | grep -qxF "${cwd}"; then
        safe_gap=true
    fi

    if ${own_gap} || ${label_gap}; then
        # Severity-based default: the in-place ownership grant is heavy (recursive chgrp), so it defaults NO
        # and recommends the clone; a label-only gap is cheap and required, so it defaults YES.
        claim_default='n'
        ${own_gap} || claim_default='y'
        local -a blk2=()
        ${own_gap}   && blk2+=( "- group is '${cwd_gid:-?}', not '${SANDBOX_GROUP}' -- sessions cannot spawn children here" )
        ${label_gap} && blk2+=( "- missing SELinux label ai_tools_project_t -- the agent cannot read/write here" )
        ${safe_gap}  && blk2+=( "- also not in git safe.directory" )
        blk2+=( "" )
        if ${own_gap}; then
            blk2+=(
                "Recommended -- an isolated shallow branch copy in sandbox-projects:"
                "       ${CLI_CMD} projects clone"
                "Allow access -- claim this directory in place (give access to ${SANDBOX_USER}; needs sudo):"
                "       ${CLI_CMD} projects claim"
            )
        else
            blk2+=(
                "Claim it -- applies the SELinux label; needs sudo for the relabel:"
                "       ${CLI_CMD} projects claim"
            )
        fi
        blk2+=( "" "Both default to the current directory. See '${CLI_CMD} --help' for what each does." )
        ai_tools_msg_block "Finish setting up this project for the agent" "${blk2[@]}"
        claim_ok=false
        ai_tools_msg_confirm "Claim it in place now?" "${claim_default}" && claim_ok=true
        if ${claim_ok}; then
            # Delegate the claim. `--yes` pre-answers only the CLI's proceed prompt (you answered it here); its
            # secret-lockdown prompt, the .git history grant, and the traverse grant stay explicit.
            # `ai-tools projects claim` is idempotent and closes whichever gaps apply.
            "${AI_TOOLS_CLI}" projects claim --yes "${cwd}" || true
            # Re-verify the FATAL gaps closed before launching.
            cwd_gid="$(stat -c '%G' "${cwd}" 2>/dev/null || true)"
            cwd_mode="$(stat -c '%a' "${cwd}" 2>/dev/null || true)"
            if [[ "${cwd_gid}" != "${SANDBOX_GROUP}" ]] || (( (0${cwd_mode:-0} & 010) == 0 )); then
                ai_tools_launch_die "${cwd}: still not accessible -- the claim did not complete"
            fi
            if ! _ai_tools_launch_project_labelled "${cwd}"; then
                # The relabel is the one claim step that needs root; the CLI runs it as `sudo ai-tools-relabel`
                # and prompts for your password. Re-running the claim (NOT `sudo ai-tools` -- the CLI refuses to run
                # as root) re-attempts it.
                ai_tools_launch_die "${cwd}: SELinux label still missing -- the claim did not complete" \
                    "       re-run: ${CLI_CMD} projects claim ${cwd}" \
                    "       (enter your password when it prompts for the SELinux relabel)"
            fi
        else
            ai_tools_launch_die MSG-W4X4 "refusing to launch -- ${cwd} is not fully claimed for the sandbox" \
                "       run one of the commands above, then start your agent again"
        fi
    elif ${safe_gap}; then
        # Ownership and label hold; the git safe.directory entry is the one piece missing. Offer to register it
        # via the SAFEDIR_BIN sudo helper -- the path reg_safedir uses (see ai-tools-safedir for the 644/sudo model).
        # Defaults YES (an additive change -- one entry in git's trust list -- on a tree already approved to launch
        # in); a non-interactive launch prints the command instead.
        ai_tools_msg_notice \
            "${name}: ${cwd} is not in git safe.directory; git will report \"dubious ownership\" here until it is registered."
        if ai_tools_launch_have_tty; then
            if ai_tools_msg_confirm "Register it now (needs sudo)?" y; then
                if sudo "${SAFEDIR_BIN}" "${cwd}"; then
                    printf '%s: registered %s in git safe.directory.\n' "${name}" "${cwd}" >&2
                else
                    ai_tools_msg_notice "${name}: could not register ${cwd} -- add it with:"
                    printf '  sudo %q %q\n' "${SAFEDIR_BIN}" "${cwd}" >&2
                fi
            fi
        else
            printf '  register it with: sudo %q %q\n' "${SAFEDIR_BIN}" "${cwd}" >&2
        fi
    fi
}

# ai_tools_launch_gates "$@" -- run the gates in the order the security model rests on. The operator gate answers
# before any other read, the launcher is resolved before the print-and-exit short-circuit can exec it, and the CWD gates
# run only for a real project launch. A wrapper calls this once with its arguments and does not reorder or omit a gate.
ai_tools_launch_gates() {
    ai_tools_launch_gate_operator
    ai_tools_launch_resolve_executable
    ai_tools_launch_print_and_exit "$@"
    ai_tools_launch_gate_project
    ai_tools_launch_claim_guard
}

# _ai_tools_launch_notices -- the informational, best-effort pre-launch reports; neither is a security gate, so neither
# ever fails the launch closed: a missing lib skips the report.
#
# Service health: warn the operator about a down system service the wrapper owns -- currently the relabel watcher.
# The handback socket has its own dedicated NOTICE in ai-tools-run (services.lib marks it preflight=shim), so it is NOT
# repeated here. The print-and-exit path exec'd earlier, so this reaches only a real project launch, and it stays silent
# on a healthy host. Each down service names its consequence (framed) and its exact remedy (plain, under the box
# so the command stays copy-pasteable -- see messaging.rule.md).
#
# Secret-pattern drift, journald only: the operator's own file REPLACES the shipped baseline rather than extending it,
# so a copy written once keeps this host on that set and silently drops every pattern added upstream since. Nobody is
# placed to notice: the agent cannot read the file, and the log records the quarantines that happened rather than
# the patterns that would have caused one. This is the one point per session where the file is both readable (the
# wrapper runs as the operator, before the drop) and attributable to a launch, so the difference is recorded here --
# to the journal, never to the terminal, since it is not a launch decision and the operator did not ask a question.
# A missing lib, an unreadable file, or an absent `logger` skips it; an empty or missing file means the baseline is
# in force, which is no difference and stays silent.
_ai_tools_launch_notices() {
    local name="${AI_TOOLS_LAUNCH_NAME}" svc drift
    # shellcheck source=SCRIPTDIR/services.lib.sh
    if source /usr/local/lib/ai-tools/services.lib.sh 2>/dev/null \
            && declare -F ai_tools_services_scan >/dev/null 2>&1 \
            && ai_tools_services_scan wrapper; then
        for svc in "${AI_TOOLS_SERVICES_DOWN[@]}"; do
            ai_tools_msg_warn \
                "${name}: $(ai_tools_service_field "${svc}" 1) is not running -- $(ai_tools_service_field "${svc}" 5)."
            printf '       remedy: %s\n' "$(ai_tools_service_field "${svc}" 6)" >&2
        done
    fi

    # shellcheck source=SCRIPTDIR/secret-patterns.lib.sh
    if command -v logger >/dev/null 2>&1 \
            && source /usr/local/lib/ai-tools/secret-patterns.lib.sh 2>/dev/null \
            && declare -F ai_tools_secret_patterns_drift >/dev/null 2>&1; then
        # The loader resolves the config under PROJECTS_HOME; the wrapper runs as the operator, so their own ${HOME} is
        # the operator whose set this launch will be classified against.
        PROJECTS_HOME="${HOME}"
        drift="$(ai_tools_secret_patterns_drift 2>/dev/null)" || drift=""
        # A plain `[[ ]] && cmd` as the block's last command would exit the wrapper under `set -e` whenever the test is
        # false -- which is the healthy host, every launch.
        if [[ -n "${drift}" ]]; then
            logger -t "${name}" -p user.notice -- "${drift}"
        fi
    fi
}

# ai_tools_launch_session <arg>... -- emit the pre-launch notices, then exec the confined session with the arguments.
# Refuses when the gates have not run: the two exports this function makes are the whole wrapper contract, and a wrapper
# that reaches the exec without them would hand the shim no executable and no project directory to validate.
# The validated versioned path passes through sudo's env_keep as AI_TOOLS_AGENT_EXEC; ai-tools-run re-validates it,
# and derives WHICH agent this is from the launcher name in the path, so no agent identity crosses sudo as a separate
# variable. AI_TOOLS_PROJECT_DIR is the realpath'd PWD that already cleared the allowlist + claim gates, so it is
# the trustworthy value -- a systemd transient unit does NOT inherit the caller's cwd (it defaults to /),
# so ai-tools-run hands this to systemd-run as the unit's WorkingDirectory. The launch banner is emitted
# by ai-tools-run, not here: it runs as the sandbox account and can read the toolchain the operator cannot (the 700
# package tree).
ai_tools_launch_session() {
    local name="${AI_TOOLS_LAUNCH_NAME}"
    if [[ -z "${AI_TOOLS_LAUNCH_EXEC}" || -z "${AI_TOOLS_LAUNCH_PROJECT_DIR}" ]]; then
        ai_tools_launch_die MSG-B6G2 "the launch gates did not run -- refusing to start" \
            "       the wrapper reached the launch without a resolved executable and project directory;" \
            "       reinstall ai-tools, then retry"
    fi
    _ai_tools_launch_notices
    export AI_TOOLS_AGENT_EXEC="${AI_TOOLS_LAUNCH_EXEC}"
    export AI_TOOLS_PROJECT_DIR="${AI_TOOLS_LAUNCH_PROJECT_DIR}"
    exec sudo -u "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -- "${AI_TOOLS_RUN}" "$@"
}

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-admin
# Host administration for the ai-tools sandbox. A root helper (run via sudo), not an ai-tools CLI verb: it edits host
# config (the OPERATORS list, the ai-ops group, the sandbox account's linger; the loaded optional SELinux policy groups)
# while the ai-tools CLI is unprivileged and refuses to run as root.
#
#   sudo ai-tools-admin operators                          # list (the zero-argument default)
#   sudo ai-tools-admin operators add [user]               # default: $SUDO_USER
#   sudo ai-tools-admin operators remove <user>
#   ```bash
#   sudo ai-tools-admin selinux groups                     # show core + optional group state
#   sudo ai-tools-admin selinux groups enable <name>...    # load prebuilt (stable) groups
#   sudo ai-tools-admin selinux groups disable <name>      # unload one
#   sudo ai-tools-admin system bootstrap                   # provision the sandbox account's toolchain
#   sudo ai-tools-admin system bootstrap --scope full      # ... and every enabled integration
#   sudo ai-tools-admin system bootstrap --agents codex    # ... enabling the named agent, unattended
#   sudo ai-tools-admin system entrypoints relabel         # verify + relabel the agent entrypoints
#   sudo ai-tools-admin system post-upgrade                # reconcile the .rpmnew files upgrades leave
#   sudo ai-tools-admin status                             # the host's health, read as root
#   sudo ai-tools-admin dotnet bootstrap                   # a domain a provider package contributes
#   ```
#
# The spelling is the project's command grammar (cli-grammar.rule.md): a bare-word command, a plural collection,
# the verb after the noun, `list` as the zero-argument default, and a singular domain (`selinux`, `system`) where one is
# needed. `--` introduces an option and never a command, which here is `--help`/`-h` and `--version`.
#
# An operator is a login user (a human or a rootless service account) that drives the sandbox through the shared
# ai-tools account. `add` is accumulating and idempotent: it seeds the user's config in `~/.config/ai-tools` (asking
# before it creates a missing `.config`), appends the name to OPERATORS in /etc/ai-tools/operator.conf, adds the user
# to the ai-ops group (the sudoers grant and the launch wrapper gate on membership), ensures the sandbox account's
# linger, and offers to wire the PATH ordering line. The seed comes first so that an account enrolled here holds
# the `allowed-projects` every later command resolves it through; a first enrolment that cannot write one is refused
# with the host unchanged. `remove` reverses the host-side membership (drops the name from OPERATORS and ai-ops),
# leaving the user's own allowlist and config. `list` prints the current operators.
#
# `selinux groups` toggles the optional policy groups, all off by default. It loads the COMPILED ai_tools_<group>.pp
# that ai-tools-selinux (or a checkout's install-selinux.sh build) staged under AI_TOOLS_SELINUX_PACKAGE_DIR
# via semodule -- no source tree or selinux-policy-devel needed on the host. The group set, descriptions, and per-group
# stability are single-sourced from selinux-groups.lib.sh, shared with selinux/install-selinux.sh (the source-tree
# authoring tool that instead COMPILES a group; this operator helper only loads a shipped one). Only STABLE groups are
# on the shipped set; `groups enable` of an EXPERIMENTAL (unaudited) group is refused with a pointer to the source
# compile-and-verify workflow (install-selinux.sh + the avc bring-up loop), since this tool will not load an unaudited
# module. `groups disable` works for any loaded group, stable or not.
#
# `system bootstrap` provisions the sandbox account and the Node toolchain the enabled agents run on, through the root
# helper ai-tools-bootstrap. It is the first command an administrator runs on a new host, and the one that installs
# software over the network, which is why it is a command rather than an RPM scriptlet: a scriptlet must succeed offline
# and inside a build chroot. Idempotent -- an existing account, nvm install or Node version is reused -- so it is also
# the re-run after enabling an agent in operator.conf. No agent is enabled until an operator names one:
# with AI_TOOLS_AGENTS absent the helper asks which ONE installed agent to enable and writes that line, and `--agents`
# is the unattended form of the same choice, passed through to the helper, which checks the names against the installed
# manifests before writing. The bare form does the minimal provision; `--scope full` then runs each ENABLED
# integration's own `bootstrap` through the admin-commands seam, so a host is provisioned end to end in one command
# without base naming an integration.
#
# Beyond those, the command set is EXTENSIBLE rather than enumerated: this tool ships in ai-tools-base, which is
# installed before anyone knows which provider packages a host will add, so a provider contributes a domain of its own
# as an executable fragment at /usr/local/lib/ai-tools/admin-commands.d/<name> and this tool discovers it. The basename
# is the domain token -- the same name the provider takes in agents.d/integrations.d and in operator.conf. Dispatch is
# an exec, not a source, so a fragment keeps its own `set -euo pipefail`, root guard and logging. A fragment is honored
# only while it passes the same trust predicate as every other provider input (root-owned, not group/other-writable,
# and so is its directory), and one claiming a name base owns is refused rather than merged; both refusals are reported.
# INSTALLATION, not enablement, decides whether a command exists -- what a command reports still names the enablement
# state, and `system bootstrap --scope full` reads the enabled set instead.
#
# `system entrypoints relabel` reconciles each enabled agent's entrypoint after a toolchain change, through the root
# helper ai-tools-relabel-agent: it verifies the binary against the checksum its vendor signed and records the result
# in that agent's pin, then restores ai_tools_exec_t so the domain transition fires and ai-tools-run stops fail-closing
# on the launch. It clears AI_TOOLS_ENTRYPOINT_PIN_REUSE before the exec, so this route always re-fetches the vendor's
# signed manifest: the unattended callers (ai-tools-relabel.service, the agent package's %post) may answer
# from an unchanged pin, and an administrator asking for a reconcile is asking for the fetch.
#
# `status` reports this host's health as root: the same resource `ai-tools status` reports to an operator, completed
# with the three readings that vantage point prints as `?` -- the sandbox account's own `systemd --user units`,
# whose bus root reaches over the machine transport; the entrypoint pin, in a state directory a non-operator has no
# traverse bit on; and the SELinux type each agent path carries right now, inside a 0750 toolchain. Every verdict comes
# from the same services.lib.sh registry both reports and the launch wrapper's pre-launch warning read, so the two
# commands differ in what each is allowed to see and agree on what they both see.
#
# `system post-upgrade` reconciles the `<file>.rpmnew` copies an upgrade leaves beside the %config(noreplace) files this
# stack owns. rpm keeps what the host edited and parks the new version alongside it; choosing between the two is
# a judgement about the operator's own configuration, so it happens here, when the operator asks, and never
# in a scriptlet. Each file gets the treatment its content deserves -- merge, report, or show only, per the post-upgrade
# registry -- and every treatment shows what it would change, confirms, backs the file up before writing, and names each
# path it touched. The copy itself is never removed: each block names the one to delete, once the operator has merged
# what they want from it. The from-source installer reaches the same end through its own keep-or-reset prompts and dated
# .bak/.shipped sidecars; this is the RPM-side equivalent.
#
# Its domain rules are cli.rule.md (what each command does) and cli-grammar.rule.md (how it is spelled).

set -euo pipefail

readonly SANDBOX_USER="@SANDBOX_USER@"
readonly OPERATORS_GROUP="ai-ops"
readonly OPERATOR_CONF="/etc/ai-tools/operator.conf"
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
readonly SELINUX_GROUPS_LIB="/usr/local/lib/ai-tools/selinux-groups.lib.sh"
readonly CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"
readonly SETTINGS_MERGE_LIB="/usr/local/lib/ai-tools/settings-merge.lib.sh"
readonly PROVIDERS_LIB="/usr/local/lib/ai-tools/providers.lib.sh"
readonly PATH_ORDER_LIB="/usr/local/lib/ai-tools/path-order.lib.sh"
# Where a provider package drops the command fragment carrying its own domain. The environment override is a test hook
# of the same standing as AI_TOOLS_POSTUPGRADE_ROOT: sudo strips the name, so tests/unit/admin-commands.sh drives
# the dispatch against a fixture tree. `--help` lists the domains through it ahead of the root check, so a non-root
# caller can point the LISTING at another root-owned directory; the dispatch still needs root and each fragment still
# needs root ownership, so the reach does not add a command. Unset in production.
readonly ADMIN_COMMANDS_DIR="${AI_TOOLS_ADMIN_COMMANDS_DIR:-/usr/local/lib/ai-tools/admin-commands.d}"
# The names base owns. A contributed fragment claiming one is refused, so no installed package can shadow a command
# an administrator relies on. `status` is reserved before it is implemented: a name a provider could take first is not
# a name base can take back.
readonly -a BASE_COMMANDS=(operators selinux system status)
# What an administrator does about a contributed command that is not root's alone. Stated once and shared by every
# message that reports one, so the dispatch, the full-scope bootstrap and the help give one answer. It is deliberately
# NOT "chmod it": a packaged command installs root-owned and unwritable by anyone else, so a file in that state is
# either one installed by hand or a change somebody made to this host -- and a mode fixed in place would re-bless
# content that whoever could write the file may already have rewritten.
readonly ADMIN_COMMANDS_TAMPER_REMEDY="a packaged command installs root-owned and unwritable by anyone else, so reinstall the package owning it -- 'rpm -qf <path>' names it -- and look into how the file came to be writable; a command installed by hand is yours to correct"
# Root-only helpers, 750 root:root, reached directly rather than through sudo: this tool already refuses a non-root
# caller. Both ship in ai-tools-integration-nodejs, which the metapackage pulls in weakly, so each command checks
# for its helper and names that package when it is absent. The ai-tools-relabel.path watcher, ai-tools-bootstrap
# and the agent package's %post run the relabel helper as root themselves.
readonly RELABEL_ENTRYPOINT_BIN="/usr/local/libexec/ai-tools/ai-tools-relabel-agent"
readonly BOOTSTRAP_BIN="/usr/local/libexec/ai-tools/ai-tools-bootstrap"

# Substituted at deploy time (install.sh install_subst from packaging/VERSION; the RPM from %{version}), and left
# as the literal token in the checkout -- which `--version` reports as `dev`, the same value and the same fallback
# the CLI uses.
AI_TOOLS_VERSION="@AI_TOOLS_VERSION@"
[[ "${AI_TOOLS_VERSION}" == @*@ ]] && AI_TOOLS_VERSION="dev"
readonly AI_TOOLS_VERSION

# A leading message code (msg.lib.sh states the form) is printed on its own line ahead of the message, the shape
# tests/lib/harness.sh's assert_msg reads. Matched inline, since these helpers report before the library is loaded.
die() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-admin: error: %s\n' "$*" >&2; exit 1
}
log()  { printf 'ai-tools-admin: %s\n' "$*"; }
# warn: a refusal that narrows what this tool will do -- a contributed command skipped, an integration that would not
# provision. stderr, so the domain list on stdout stays data-only.
warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-admin: warning: %s\n' "$*" >&2
}

# reject <message>: the command line was rejected. Exit 2 separates a command nobody can type correctly
# from an operation that ran and failed (`die`, exit 1), which is the split ai-tools-admin(8) documents and the one
# ai-tools(1) already uses.
reject() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-admin: %s\n' "$*" >&2
    printf "try 'ai-tools-admin --help'\n" >&2
    exit 2
}

# reject_with_usage <message>: the refusal the LAST dispatch arm takes, at reject's own exit 2. It prints the command
# surface rather than a pointer at `--help`, because a name that matched no base command and no contributed domain is
# answered by the domain list this host actually has, which only usage() knows. Defined here so that surface
# and the code naming the situation stay together.
reject_with_usage() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-admin: %s\n\n' "$*" >&2
    usage >&2
    exit 2
}

# die_unsourced <lib>: one situation for every library this tool requires, the library named as its argument -- called
# after the `source` line so each keeps its own shellcheck source directive.
die_unsourced() { die MSG-V6F4 "cannot source ${1}"; }

# coded_refusal <code> <text>: a refusal carried as a VALUE -- the code on the first line, the text on the second.
# admin_command_check's branches define their codes through it, so each of its situations keeps a code of its own while
# the two sites that emit the value need not know which branch produced it.
coded_refusal() { printf '%s\n' "$1" "$2"; }
# emit_coded <emitter> <value> [prefix]: hand a coded_refusal value to warn or die as the two arguments they read,
# with <prefix> naming who the refusal is about ahead of the text.
emit_coded() { "$1" "${2%%$'\n'*}" "${3-}${2#*$'\n'}"; }

# usage: the command surface, grouped by domain. Orientation rather than reference -- every option, exit code
# and example is in ai-tools-admin(8), and tests/unit/man.sh holds the two in agreement on the command set.
#
# Two heredocs with the contributed domains between them, by design: the FIRST one is the base command set, and it is
# exactly what man.sh reads (it stops at the first EOF). The block between them is whatever this host installed,
# so the page documents the seam rather than any one domain -- a domain a package contributes cannot be documented
# by the package that does not ship it.
usage() {
    cat <<EOF
ai-tools-admin -- administer the ai-tools host: operators, SELinux groups, the toolchain, upgrades

  Operators
    operators                        the enrolled operators
    operators add [user]             enrol an operator (default: \$SUDO_USER)
    operators remove <user>          withdraw an operator's enrolment
  SELinux
    selinux groups                   the core module and the optional groups
    selinux groups enable <name>...  load prebuilt optional groups
    selinux groups disable <name>    unload a loaded group
  System
    system bootstrap [--scope full]  provision the sandbox account and its toolchain
      --agents NAME[,NAME...]        enable the named agents instead of asking which one
    system entrypoints relabel       verify and relabel the agent entrypoints
    system post-upgrade              reconcile the .rpmnew files an upgrade leaves
  Health
    status                           this host's services, entrypoints and live labels
EOF
    usage_domains
    cat <<'EOT'
    --version                        the installed version
    --help                           this summary

  Run every command through sudo: each one administers the host and refuses a
  non-root caller. The project lifecycle is the unprivileged ai-tools CLI, which
  you run as yourself.

  Every command, exit code and example:  man ai-tools-admin
EOT
}

# usage_domains: the domain line each installed provider contributes, so the help an administrator reads
# and the commands that dispatch cannot disagree -- both read admin_domains. The summary is the provider manifest's
# admin_summary key (data, parsed not sourced), rather than each fragment being executed to ask it what it is;
# a provider that declares none still gets its line.
usage_domains() {
    admin_domains
    printf '\n'
    [[ "${#ADMIN_DOMAINS[@]}" -gt 0 ]] || return 0
    printf '  Providers\n'
    local domain summary
    for domain in "${ADMIN_DOMAINS[@]}"; do
        summary=""
        declare -F ai_tools_provider_manifest_field >/dev/null 2>&1 \
            && summary="$(ai_tools_provider_manifest_field "${domain}" admin_summary || true)"
        printf '    %-32s %s\n' "${domain} <command>" "${summary}"
    done
    # What the help shows and what runs stay one answer: while the set-wide gate holds these back, the listing says
    # so rather than offering a command that refuses.
    admin_commands_trusted \
        || printf "    (refused: a file in that directory is not root's alone -- see the warning above)\n"
    printf '\n'
}

# ── contributed command domains ──────────────────────────────────────────────────────────────
# The seam that lets a provider package add a domain to this tool. Base cannot enumerate the integrations it ships
# without, so the domain list is DISCOVERED -- and every way that discovery can fail leaves the command surface smaller,
# never wider.

# is_base_command <name>: succeed when base owns <name>.
is_base_command() {
    local candidate="$1" reserved
    for reserved in "${BASE_COMMANDS[@]}"; do
        [[ "${candidate}" == "${reserved}" ]] && return 0
    done
    return 1
}

# admin_domains: resolve the contributed domains this host has into ADMIN_DOMAINS, in filename order, and record
# in ADMIN_COMMANDS_TAMPERED whether any entry failed the trust predicate. Both results are globals rather than stdout
# because the caller must see the second one, and a $(...) capture would leave it behind in a subshell. Every refusal
# goes to stderr.
#
# A fragment is honored only while ai_tools_conf_is_trusted holds for it AND for the directory holding it --
# a group-writable directory lets a non-root writer unlink a root-owned file and put its own in that name, which here
# would be a command root then executes. A name base owns is refused rather than merged, and a basename that is not
# a bare lower-case word is skipped before it is ever joined to a path, so a separator or a traversal cannot address
# a file outside the directory. The dispatch and `--help` both read this one function, so what an administrator is told
# and what runs cannot disagree.
#
# The two rejections are different findings and are counted apart. A name this seam does not recognize (a README,
# a backup, a base name) is a file that is not a command, and the set around it is unaffected. A file that group
# or other may write is a broken assumption about the directory itself -- that only root decides what is run from it --
# and it is what ADMIN_COMMANDS_TAMPERED carries to the conformance gate.
ADMIN_DOMAINS=()
ADMIN_COMMANDS_TAMPERED=0
admin_domains() {
    ADMIN_DOMAINS=()
    ADMIN_COMMANDS_TAMPERED=0
    [[ -d "${ADMIN_COMMANDS_DIR}" ]] || return 0
    if ! ai_tools_conf_is_trusted "${ADMIN_COMMANDS_DIR}"; then
        warn MSG-V5S5 "ignoring every contributed command: ${ADMIN_COMMANDS_DIR} is a symlink, is not root-owned, or is writable by group/other"
        ADMIN_COMMANDS_TAMPERED=1
        return 0
    fi
    local fragment domain
    for fragment in "${ADMIN_COMMANDS_DIR}"/*; do
        [[ -f "${fragment}" ]] || continue
        domain="${fragment##*/}"
        if [[ ! "${domain}" =~ ^[a-z][a-z0-9-]*$ ]]; then
            warn MSG-H6J9 "skipping $(printf '%q' "${fragment}"): a contributed command is named for its provider, in bare lower-case"
            continue
        fi
        if is_base_command "${domain}"; then
            warn MSG-U6P9 "refusing ${fragment}: '${domain}' is a command ai-tools-admin owns and no package may replace it"
            continue
        fi
        if ! ai_tools_conf_is_trusted "${fragment}"; then
            warn MSG-D3P6 "refusing ${fragment}: it is a symlink, is not root-owned, or is writable by group/other, so what it runs is not root's decision alone"
            ADMIN_COMMANDS_TAMPERED=1
            continue
        fi
        ADMIN_DOMAINS+=( "${domain}" )
    done
}

# admin_commands_trusted: the SET-WIDE gate, applied before any contributed command is run.
#
# Per-file skipping already keeps a mis-permissioned fragment from being executed, and this refuses its neighbours
# as well. The reason is what the failure means rather than what it reaches: only root may write this directory,
# so a fragment inside it that group or other may write is a file the sandbox account can rewrite between one run
# and the next, sitting where root looks for commands. Running the entries that still pass would leave that file
# in place and the administrator with no reason to act. Base's own commands are untouched by this, so the host stays
# administrable while the finding is dealt with (ADMIN_COMMANDS_TAMPER_REMEDY).
admin_commands_trusted() {
    (( ADMIN_COMMANDS_TAMPERED == 0 ))
}

# admin_command_check <domain>: succeed when the fragment carrying <domain> conforms to the interface this tool
# dispatches, publishing its declared verbs in ADMIN_COMMAND_VERBS; otherwise set _admin_command_reason to what is
# wrong, as a coded_refusal value. A reason rather than a message, so the two callers can act differently on it --
# an administrator's own command stops, while `system bootstrap --scope full` names it and carries on to the next
# integration. Each branch defines its own message code, since neither emit site knows which of them it holds.
#
# Where the trust checks decide WHO wrote the file, this decides whether the file is a command of this seam at all. It
# is a conformance contract, not a security boundary: what stops a file the agent wrote is the trust predicate,
# and what this stops is a file that was never meant to be run this way. It is declarative and static -- a fragment is
# read, never executed, to find out what it is, so a report is built by reading alone, without forking or running
# the fragment.
#
# A conforming fragment is a script (`#!`) carrying three declarations in its first 20 lines. The whole block is
# the interface: a third-party integration writes it once, and every check here reads it rather than running anything.
#
#   # ai-tools-admin-command: <domain>              the domain it is installed as
#   # ai-tools-admin-api-min-version: <maj>.<min>   the least this tool must implement for it to run
#   # ai-tools-admin-verbs: <verb> ...              the top-level verbs it answers (this project's
#                                                   list grammar: commas and whitespace separate)
#
# Each earns its place:
#   * the COMMAND line makes the fragment self-identifying, so a root-owned executable that merely
#     ends up in this directory -- a stray tool, an editor's backup, one provider's command copied
#     under another provider's name -- does not claim to be a command here and is not run as one.
#   * the API-MIN-VERSION line is version skew made visible, and it is a FLOOR rather than a
#     stamp of what the fragment was written on. A fragment ships in a package that upgrades
#     independently of base, and a third party does not re-declare it for every release of this
#     project, so what it states is what it NEEDS: `1.0` means "any ai-tools-admin implementing 1.0
#     or later can run me", and it keeps being true as this tool moves forward.
#   * the VERBS line is a capability list base READS rather than probes. `system bootstrap --scope
#     full` asks whether a provider has a `bootstrap` before running anything, so an integration
#     that contributes other commands is reported as having no provisioning to do rather than as
#     having failed. It is NOT argument validation -- what a verb accepts is the fragment's own
#     dispatch to answer, and a base that second-guessed it would drift out of agreement with it.
#
# There is no date and no "written against" version in the block: the package that installs the fragment carries both,
# and a hand-maintained copy of either would drift from it.
#
# ADMIN_COMMAND_API is what this tool implements, and it is the only version base holds. A fragment runs when its
# declared floor is one this tool satisfies -- the same comparison Apache httpd makes between a module's Module Magic
# Number and its own (AP_MODULE_MAGIC_AT_LEAST), and the same shape as every plugin host that takes a floor from its
# plugins (Chrome's minimum_chrome_version, Jenkins' jenkins.version baseline, a VS Code extension's engines.vscode):
#
#   the MAJOR must match      a different major is a different contract, and neither side can guess
#                             at the other's, so the refusal names both versions
#   the MINOR must be at      a minor revision only ADDS, so a fragment that needs 1.0 runs on 1.7;
#   least the declared one    one that needs 1.7 does not run here until base catches up
#
# That leaves one number to maintain and puts retirement in the major digit, where a reader already expects it, rather
# than in a second constant saying the same thing. It is also what lets a third party declare a floor once and leave it
# alone: everything valid at 1.0 keeps dispatching however far the minor advances.
#
# How the version moves, since that is the question every later change to this seam asks:
#   * base learns to CALL something new -- a `reset` or `update` verb invoked the way `system
#     bootstrap --scope full` invokes `bootstrap` -- is ADDITIVE. A fragment that does not declare
#     the verb is skipped, exactly as one without `bootstrap` is, so this takes a MINOR bump.
#   * base changes what it REQUIRES -- a new mandatory declaration, a different invocation -- is
#     still a MINOR bump while base keeps honouring the old shape (the new key optional, the old
#     invocation still answered). It is a MAJOR bump only when base drops that compatibility path,
#     which is the single change that refuses a working third-party command.
#   * a provider adding a verb TO ITSELF moves neither digit. `dotnet reset` is typed directly and
#     asks base for no behaviour, so the interface grows only when base starts invoking something.
readonly ADMIN_COMMAND_API="1.0"
_admin_command_reason=""
ADMIN_COMMAND_VERBS=()
admin_command_check() {
    local domain="$1"
    local fragment="${ADMIN_COMMANDS_DIR}/${domain}"
    local head_bytes header declared_floor declared_major declared_minor declared_verbs verb
    local base_major="${ADMIN_COMMAND_API%%.*}" base_minor="${ADMIN_COMMAND_API##*.}"
    _admin_command_reason=""
    ADMIN_COMMAND_VERBS=()
    if [[ ! -x "${fragment}" ]]; then
        _admin_command_reason="$(coded_refusal MSG-F4Z5 "not executable: ${fragment} -- reinstall the package that ships it")"
        return 1
    fi
    head_bytes="$(head -c 2 "${fragment}" 2>/dev/null || true)"
    if [[ "${head_bytes}" != '#!' ]]; then
        _admin_command_reason="$(coded_refusal MSG-D9F7 "not a script: ${fragment} -- a contributed command is an interpreted file")"
        return 1
    fi
    # Captured before matching, never piped into `grep`/`head`: an early-exiting reader leaves the writer to die
    # of SIGPIPE, which pipefail reports as a failed probe (see ai_tools_selinux_group_loaded). Every read works on this
    # one string.
    header="$(head -n 20 "${fragment}" 2>/dev/null || true)"
    if ! grep -qxF -- "# ai-tools-admin-command: ${domain}" <<<"${header}"; then
        _admin_command_reason="$(coded_refusal MSG-H5F8 "no domain declaration: ${fragment} does not declare '# ai-tools-admin-command: ${domain}' in its first 20 lines -- reinstall the package that ships it")"
        return 1
    fi

    declared_floor="$(_admin_command_field "${header}" api-min-version)"
    if [[ -z "${declared_floor}" ]]; then
        _admin_command_reason="$(coded_refusal MSG-U6U6 "no interface floor: ${fragment} declares no '# ai-tools-admin-api-min-version: <major>.<minor>' -- reinstall the package that ships it")"
        return 1
    fi
    if [[ ! "${declared_floor}" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        _admin_command_reason="$(coded_refusal MSG-B5K9 "a malformed interface floor: ${fragment} declares $(printf '%q' "${declared_floor}"), which is not <major>.<minor>")"
        return 1
    fi
    declared_major="${BASH_REMATCH[1]}"; declared_minor="${BASH_REMATCH[2]}"
    if (( declared_major != base_major )); then
        _admin_command_reason="$(coded_refusal MSG-W3T9 "an incompatible contract: ${fragment} needs contributed-command interface ${declared_floor}, and this ai-tools-admin implements ${ADMIN_COMMAND_API} -- a different major is a different contract, so upgrade whichever of the two is behind")"
        return 1
    fi
    if (( declared_minor > base_minor )); then
        _admin_command_reason="$(coded_refusal MSG-M3D7 "an interface newer than this one: ${fragment} needs contributed-command interface ${declared_floor}, and this ai-tools-admin implements ${ADMIN_COMMAND_API} -- upgrade ai-tools-base")"
        return 1
    fi

    declared_verbs="$(_admin_command_field "${header}" verbs)"
    # One list grammar across this project: commas and whitespace both separate (conf.lib.sh).
    ai_tools_conf_split ADMIN_COMMAND_VERBS "${declared_verbs}"
    if [[ "${#ADMIN_COMMAND_VERBS[@]}" -eq 0 ]]; then
        _admin_command_reason="$(coded_refusal MSG-V5Q3 "no verb list: ${fragment} declares no '# ai-tools-admin-verbs: <verb> ...' -- a command that answers nothing is not one")"
        return 1
    fi
    for verb in "${ADMIN_COMMAND_VERBS[@]}"; do
        [[ "${verb}" =~ ^[a-z][a-z0-9-]*$ ]] && continue
        _admin_command_reason="$(coded_refusal MSG-E3G7 "a verb outside the command charset: ${fragment} declares $(printf '%q' "${verb}") among its verbs, and a verb is a bare lower-case word")"
        return 1
    done
    return 0
}

# _admin_command_field <header> <key>: the value of one `# ai-tools-admin-<key>: ` line, empty when absent. First
# occurrence wins, so a later line cannot quietly override the declaration a reader saw first. Works on the captured
# header string, so no read reaches the file again.
_admin_command_field() {
    local values
    values="$(sed -n "s/^# ai-tools-admin-$2:[[:space:]]*\\(.*[^[:space:]]\\)[[:space:]]*\$/\\1/p" <<<"$1")"
    printf '%s' "${values%%$'\n'*}"
}

# admin_command_has_verb <verb>: succeed when the verb list published by the last admin_command_check holds <verb>. Read
# after that call, never instead of it.
admin_command_has_verb() {
    local wanted="$1" verb
    for verb in "${ADMIN_COMMAND_VERBS[@]}"; do
        [[ "${verb}" == "${wanted}" ]] && return 0
    done
    return 1
}

# contributed_dispatch <name> [args...]: exec the fragment carrying <name>, with the remaining arguments. An exec rather
# than a source: the fragment keeps its own `set -euo pipefail`, its own root guard and its own logging, and cannot
# collide with this tool's function names.
#
# Membership of ADMIN_DOMAINS is the gate, so <name> is never interpolated into a path before it has matched
# a discovered domain. Reached only from the top-level default arm, which is what makes a base name unreachable here
# twice over: its own arm matched first, and admin_domains refuses a fragment claiming one.
contributed_dispatch() {
    local domain="$1"; shift
    admin_domains
    local known found=no
    for known in "${ADMIN_DOMAINS[@]}"; do
        [[ "${known}" == "${domain}" ]] && { found=yes; break; }
    done
    if [[ "${found}" != yes ]]; then
        reject_with_usage MSG-N2A5 "unknown command: ${domain}"
    fi
    admin_commands_trusted \
        || die MSG-A3P2 "refusing every contributed command while ${ADMIN_COMMANDS_DIR} holds a file that is not root's alone (named above) -- ${ADMIN_COMMANDS_TAMPER_REMEDY}"
    admin_command_check "${domain}" || emit_coded die "${_admin_command_reason}"
    exec "${ADMIN_COMMANDS_DIR}/${domain}" "$@"
}

# The shared config grammar and sidecar handling that `system post-upgrade` drives, and the trust predicate every
# contributed command is vetted with. Required, not optional: a reconcile that silently skipped its merge would leave
# a shipped hook uninvoked while reporting success, and a dispatch that could not tell a trusted fragment from a planted
# one would exec whatever it found. Loaded BEFORE the other libraries, unlike them, because `--help` lists this host's
# contributed domains and that list is drawn through this predicate.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/conf.lib.sh
. "${CONF_LIB}" || die_unsourced "${CONF_LIB}"
# The hook-declaration merge `system post-upgrade` applies to a kept settings.json. Required for the same reason.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/settings-merge.lib.sh
. "${SETTINGS_MERGE_LIB}" || die_unsourced "${SETTINGS_MERGE_LIB}"

# Provider resolver: the manifest key behind each domain's summary line, and the enabled-integration list
# `system bootstrap --scope full` iterates. Optional at load and gated at each use -- without it every installed
# fragment still dispatches (its own presence is what decides that), a domain is listed without its summary,
# and full-scope bootstrap REFUSES rather than guessing which integrations this host runs.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/providers.lib.sh
source "${PROVIDERS_LIB}" 2>/dev/null || true

# Where an operator's shell finds an agent launcher, and the guard line that settles it. Required, like the operator
# lib: enrolment asks about that line and then writes it, so a missing library is a broken install rather than
# a question this tool can ask a different way. It reads the enabled agents through providers.lib.sh, so a host
# that could not load that resolver gets the `unknown` verdict and is asked with the stake unnamed.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/path-order.lib.sh
. "${PATH_ORDER_LIB}" || die_unsourced "${PATH_ORDER_LIB}"

# Executed, this administers a host and needs root. Sourced -- by tests/unit/admin-operator-add.sh, which drives one
# function with sudo stubbed -- it does not assert anything about the host and only defines, stopping at the matching
# guard that precedes the dispatch. Everything between the two is definitions, so the executed path still refuses
# a non-root caller before any action.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # `--help` and `--version` read no host state and leave the host as it is, so they answer any caller and are handled
    # here, ahead of the root check: an operator meeting the tool gets the command surface rather than a refusal naming
    # sudo without saying what to run under it. Both ignore any further argument.
    case "${1:-}" in
        --help|-h) usage; exit 0 ;;
        --version) printf 'ai-tools-admin %s\n' "${AI_TOOLS_VERSION}"; exit 0 ;;
    esac
    [[ "${EUID}" -eq 0 ]] || die MSG-D7D4 "run as root (sudo)"
fi

# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
. "${OPERATOR_LIB}" || die_unsourced "${OPERATOR_LIB}"

# Optional SELinux policy-group registry + predicates, shared with install-selinux.sh.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/selinux-groups.lib.sh
. "${SELINUX_GROUPS_LIB}" || die_unsourced "${SELINUX_GROUPS_LIB}"

# Shared yes/no prompt (ai_tools_msg_confirm; see msg.lib.sh). REQUIRED like the operator lib: a valid install ships it,
# so there is no fallback. Include-guarded, so a re-source is a no-op.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh || die_unsourced /usr/local/lib/ai-tools/msg.lib.sh
# Fixed 80-column frame for any box this tool renders, aligned with the CLI's.
export AI_TOOLS_MSG_FULLWIDTH=1

# write_operators <name>...: set the OPERATORS list in operator.conf (root:root 644). Edits ONLY the OPERATORS line
# in an existing file, through the shared writer (ai_tools_conf_set_key, conf.lib.sh -- the grammar's owner, so the line
# replaced is the one every reader of the file matches), preserving every other setting the operator maintains there;
# seeds a minimal file when absent. 644: world-readable (the agent hooks and the root helpers both read it; it is free
# of secrets) and root-write-only, so the agent cannot rewrite the identity root hands files back to.
write_operators() {
    install -d -o root -g root -m 755 /etc/ai-tools
    if [[ ! -f "${OPERATOR_CONF}" ]]; then
        local tmp; tmp="$(mktemp)"
        printf '%s\n' "# ai-tools host configuration -- full reference: man 5 ai-tools-operator.conf" > "${tmp}"
        install -o root -g root -m 644 "${tmp}" "${OPERATOR_CONF}"
        rm -f "${tmp}"
    fi
    ai_tools_conf_set_key "${OPERATOR_CONF}" OPERATORS "$*" \
        || die MSG-N4H9 "could not write OPERATORS into ${OPERATOR_CONF} -- the enrolment is incomplete; check the file and re-run"
}

# in_list <name>: succeed when <name> is already in AI_TOOLS_OPERATORS.
in_list() {
    local n; for n in "${AI_TOOLS_OPERATORS[@]:-}"; do [[ "${n}" == "$1" ]] && return 0; done
    return 1
}

# seed_config_file <user> <group> <path> <seed-function>: place <path> from what <seed-function> prints, owned
# by the operator at 600. An existing file holds that operator's own edits and is left as it stands, so enrolment is
# idempotent. Returns non-zero when the file is not there afterwards, so a failed write reaches the caller
# as the refusal it makes rather than as a step that logged `seeding` and stopped.
seed_config_file() {
    local user="$1" group="$2" file="$3" seed="$4" tmp status=0
    [[ -f "${file}" ]] && return 0
    log "seeding ${file}"
    tmp="$(mktemp)"
    "${seed}" > "${tmp}" && install -o "${user}" -g "${group}" -m 600 "${tmp}" "${file}" || status=$?
    rm -f "${tmp}"
    (( status == 0 )) || warn MSG-P5C5 "could not seed ${file}"
    return "${status}"
}

# ensure_config_home <user> <group> <home>: make sure `<home>/.config` exists, since `~/.config/ai-tools` is seeded
# inside it and an account that has never logged in has no config home yet.
#
# An existing one is left as it stands: other applications keep their config there, and its mode is not this command's
# to decide. A missing one is created with `mkdir`, so the HOST's umask decides the mode -- the compliance answer
# for a directory this command only has to traverse, and a permissive umask leaves the access boundary where it already
# is, on the `700` `~/.config/ai-tools` inside it. Creating it asks first, default YES: the write lands in an account's
# home, and a run with no terminal takes the yes, which is what seeds an operator during an unattended install.
# `restorecon` gives it `config_home_t`, which root creating it inside the home does not.
#
# Returns non-zero when `.config` is absent afterwards, so the caller refuses the enrolment rather than reporting a seed
# that did not happen.
ensure_config_home() {
    local user="$1" group="$2" cfg_home="$3/.config"
    [[ -d "${cfg_home}" ]] && return 0
    if [[ -e "${cfg_home}" ]]; then
        warn MSG-Z6V4 "not a directory: ${cfg_home} -- ${user}'s ai-tools config cannot be seeded inside it"
        return 1
    fi
    log "${user} has no ${cfg_home}, which is where its ai-tools config directory goes"
    if ! ai_tools_msg_confirm "Create ${cfg_home}, owned by ${user}?" y; then
        warn MSG-B6P3 "declined: ${cfg_home} was not created, so ${user}'s ai-tools config cannot be seeded"
        return 1
    fi
    if ! mkdir "${cfg_home}"; then
        warn MSG-S9G3 "could not create ${cfg_home} as ${user}:${group}"
        return 1
    fi
    # A directory root owns is one the operator cannot write, so an ownership this could not set takes the empty
    # directory with it and the enrolment refuses on a home it did not change.
    if ! chown "${user}:${group}" "${cfg_home}"; then
        rmdir "${cfg_home}" 2>/dev/null || true
        warn MSG-U8E9 "could not give ${cfg_home} to ${user}:${group}; removed the directory again"
        return 1
    fi
    if command -v restorecon >/dev/null 2>&1; then restorecon "${cfg_home}" 2>/dev/null || true; fi
    log "created ${cfg_home} $(stat -c '%a %U:%G' "${cfg_home}" 2>/dev/null)"
}

# seed_operator_config <user>: create the config an operator keeps in ~/.config/ai-tools -- allowed-projects (the launch
# gate) and secret-patterns (which basenames are credentials) -- at 600 inside a 700 directory, so the sandbox account,
# neither owner nor group member and unable to enter the directory, reads neither while the root helpers read both
# on the operator's behalf. This is the one place either file is created for an operator, and both headers come
# from conf.lib.sh, so an account enrolled on a packaged host gets what a from-source install writes.
#
# Each way it can come up short is reported where it happens and returns non-zero, so `op_add` decides what an enrolment
# missing its `allowed-projects` becomes.
seed_operator_config() {
    local user="$1" home group cfg status=0
    home="$(getent passwd "${user}" | cut -d: -f6)"
    group="$(id -gn "${user}")"
    if [[ -z "${home}" || ! -d "${home}" ]]; then
        warn MSG-R7U6 "no home directory on this host for ${user}; skipping the config seed"
        warn "    create the home, then re-run: sudo ai-tools-admin operators add ${user}"
        return 1
    fi
    ensure_config_home "${user}" "${group}" "${home}" || return 1
    cfg="${home}/.config/ai-tools"
    if [[ ! -d "${cfg}" ]] && ! install -d -o "${user}" -g "${group}" -m 700 "${cfg}"; then
        warn MSG-N2J8 "could not create ${cfg} at 700 ${user}:${group}"
        return 1
    fi
    seed_config_file "${user}" "${group}" "${cfg}/allowed-projects"  ai_tools_conf_allowlist_seed       || status=1
    seed_config_file "${user}" "${group}" "${cfg}/secret-patterns"   ai_tools_conf_secret_patterns_seed || status=1
    return "${status}"
}

# label_operator_config <user>: give that operator's ~/.config/ai-tools the ai_tools_conf_t SELinux type,
# through relabel.lib.sh. There is one rule per operator and enrolment is where this host learns an account is one,
# so the rule is registered here; what the type buys is in .claude/rules/confinement.rule.md. A re-run re-asserts it,
# which repairs an account whose rule a concurrent semanage transaction refused.
#
# BEST-EFFORT, and the two ways it declines are different facts. On a host with no SELinux layer there is no such type
# to apply -- the intended DAC-only deployment -- so the run stays silent. A host that has one and could not apply it is
# WARNED with the command that repairs it, and the enrolment still stands: the two facts that make an operator are
# already written, so a refusal here would leave an account in OPERATORS and in the group with no way to finish.
label_operator_config() {
    local user="$1" home cfg status=0
    home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6)"
    cfg="${home}/.config/ai-tools"
    [[ -n "${home}" && -d "${cfg}" ]] || return 0
    # shellcheck source=SCRIPTDIR/../../lib/ai-tools/relabel.lib.sh
    if ! source "${RELABEL_LIB}" 2>/dev/null \
            || ! declare -F ai_tools_label_operator_conf >/dev/null 2>&1; then
        warn MSG-H5N2 "cannot label ${cfg}: ${RELABEL_LIB} did not load -- reinstall ai-tools-base"
        return 0
    fi
    # Taken in this shell, not a subshell: the lock is an open descriptor (see relabel.lib.sh). It serializes this write
    # against the other helpers that write the same policy store.
    ai_tools_relabel_lock
    if [[ -n "${AI_TOOLS_RELABEL_LOCK_NOTE}" ]]; then
        warn MSG-G2C6 "proceeding without the relabel lock: ${AI_TOOLS_RELABEL_LOCK_NOTE}"
    fi
    ai_tools_label_operator_conf "${cfg}" || status=$?
    case "${status}" in
        0) log "labelled ${cfg} ${AI_TOOLS_OPERATOR_CONF_TYPE}" ;;
        2) : ;;   # no SELinux layer on this host -- nothing to label, and not a fault
        *) warn MSG-N3T7 "could not label ${cfg} ${AI_TOOLS_OPERATOR_CONF_TYPE}${AI_TOOLS_FCONTEXT_ERROR:+ -- ${AI_TOOLS_FCONTEXT_ERROR}}"
           warn "    until it carries that type the ownership handback no-ops for ${user}'s projects"
           warn "    repair: sudo ai-tools-admin operators add ${user}" ;;
    esac
    return 0
}

# wire_init_file <file> <user> <group> [login-chain] : add the guard line to one bash init file, creating it owned
# by the account when it is absent. Idempotent -- a file already naming the fragment is left as it is. `login-chain`
# seeds a created file with the `. ~/.bashrc` block EL's skel carries, which the caller passes for ~/.bash_profile
# alone: bash reads that file by itself at login, so one holding only the guard line would leave a login shell without
# the account's own .bashrc, its nvm init among it. Top-level so tests/unit/admin-operator-add.sh drives it against its
# own fixture files, apart from the prompt in wire_dedup.
wire_init_file() {
    local f="$1" user="$2" group="$3" seed="${4-}"
    if [[ ! -e "${f}" ]]; then
        install -o "${user}" -g "${group}" -m 644 /dev/null "${f}" || return 1
        [[ "${seed}" == login-chain ]] && printf '%s\n' \
            "# Created by ai-tools-admin: read this account's .bashrc at login." \
            'if [ -f ~/.bashrc ]; then' '    . ~/.bashrc' 'fi' >> "${f}"
    fi
    if [[ "$(ai_tools_path_order_guard_present "${f}")" == yes ]]; then
        log "PATH ordering already wired in ${f}"; return 0
    fi
    grep -qF 'NVM_DIR' "${f}" \
        || log "note: NVM_DIR not found in ${f} -- the line still works, but it is meant to follow your nvm init"
    printf '\n# Added by ai-tools-admin: rank /usr/local/bin (the ai-tools wrappers) first on PATH.\n# Keep this AFTER anything that prepends to PATH, the nvm init included.\n%s\n' \
        "${AI_TOOLS_PATH_ORDER_GUARD}" >> "${f}"
    log "wired PATH ordering into ${f}"
}

# path_order_explain <user> <state> <launcher> <winner> The framed block that precedes the question, written
# for the state the account is in. Its whole job is to put the stake in front of the decision: what the answer settles
# is whether typing an agent's name reaches the sandbox at all, so the block names the binary that wins today
# and what running it would mean. A question that reads as shell-config housekeeping collects a no from the operator it
# protects. The renderer is ai_tools_msg_block, so the paths inside it stay copy-pasteable.
path_order_explain() {
    local user="$1" state="$2" launcher="$3" winner="$4"
    case "${state}" in
    shadowed)
        ai_tools_msg_block "PATH ordering: /usr/local/bin has to win" \
            "Typing ${launcher} in ${user}'s shell starts:" \
            "" \
            "    ${winner}" \
            "" \
            "That is an UNCONFINED agent: it runs as ${user}, with ${user}'s credentials and home, outside the project allowlist, the SELinux confinement and the ownership handback. The sandbox is reached only through the wrapper in ${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}, so that directory has to come first on the PATH." \
            "" \
            "ai-tools ships one line that deduplicates the PATH and ranks the root-owned directories ahead of the nvm shims. It is appended after the nvm init, changes nothing else about the shell, and is undone by deleting it." ;;
    clear)
        ai_tools_msg_block "PATH ordering" \
            "Typing ${launcher} in ${user}'s shell reaches ${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}/${launcher} -- the sandbox wrapper -- so the ordering is right as it stands." \
            "" \
            "The line below is what keeps it right. Without it, an agent installed under ${user}'s own nvm, an nvm init, or anything else that prepends to PATH puts an unconfined agent ahead of the wrapper, and nothing says so: the agent simply starts outside the sandbox." ;;
    *)
        ai_tools_msg_block "PATH ordering" \
            "This host cannot read where ${user}'s shell finds an agent launcher, so it cannot say whether typing one reaches the sandbox wrapper in ${AI_TOOLS_PATH_ORDER_WRAPPER_DIR} or an agent installed somewhere else on that PATH -- which would run unconfined, as ${user}." \
            "" \
            "The line below settles it either way: it deduplicates the PATH and ranks the root-owned directories first." ;;
    esac
}

# path_order_decline <user> <state> <launcher> <winner> <bashrc> <bashprof> What is said when the line is not written --
# declined, or a run with no terminal. On a SHADOWED account this is the last place the consequence can be stated, so it
# is a warning naming the binary that wins rather than a line reporting the step as skipped; on an account that already
# reaches the wrapper it is a note, since that account's sessions are sandboxed today. Either way it prints the line,
# to be added by hand.
path_order_decline() {
    local user="$1" state="$2" launcher="$3" winner="$4" bashrc="$5" bashprof="$6"
    if [[ "${state}" == shadowed ]]; then
        warn MSG-W7J6 "typing ${launcher} in ${user}'s shell runs ${winner}, not ${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}/${launcher} -- that agent runs unconfined, as ${user}"
        warn "    add this line after the nvm init in ${bashrc} and ${bashprof}, or re-run: sudo ai-tools-admin operators add ${user}"
        warn "    ${AI_TOOLS_PATH_ORDER_GUARD}"
        return 0
    fi
    log "PATH ordering not wired; add this line after the nvm init in ${bashrc} and ${bashprof}:"
    log "  ${AI_TOOLS_PATH_ORDER_GUARD}"
}

# wire_dedup <user> Settle where ${user}'s shell finds an agent launcher. It reads the account's ordering first
# (path-order.lib.sh), states what that reading means, and only then offers to source the PATH fragment from ~/.bashrc
# and ~/.bash_profile after their nvm init. That order carries the meaning: the question decides whether typing
# an agent's name reaches the sandbox wrapper or an agent of the same name elsewhere on the PATH, which runs unconfined
# as the operator -- so it is asked with the account's own state named, and declining it on a shadowed account warns
# instead of passing in silence.
#
# This wiring is the fragment's only delivery: it lives in the ai-tools lib dir rather than /etc/profile.d,
# so an unwired account keeps its stock PATH. The two files it names are what bash reads; an account that logs
# in through another shell is told where its own ordering stands. It edits the operator's home, so it asks first
# and never rewrites one in a run with no terminal, the `[[ -t 0 && -e /dev/tty ]]` branch deciding which.
# ai_tools_path_order_repoint is the one exception, and it follows a file this package moved rather than making a choice
# of its own.
wire_dedup() {
    local user="$1" home group login_shell bashrc bashprof
    local state launcher winner pair
    home="$(getent passwd "${user}" | cut -d: -f6)"
    login_shell="$(getent passwd "${user}" | cut -d: -f7)"
    group="$(id -gn "${user}")"
    [[ -n "${home}" && -d "${home}" ]] || return 0
    bashrc="${home}/.bashrc"; bashprof="${home}/.bash_profile"

    # A host upgraded from a release that shipped the fragment under its former name carries a guard line naming a file
    # this package moved, and that line succeeds without applying the ordering. Repoint before reading, so the state
    # this command reports and asks about is the repaired one.
    local repointed
    while IFS= read -r repointed; do
        [[ -n "${repointed}" ]] && log "repointed the PATH ordering line in ${repointed} to ${AI_TOOLS_PATH_ORDER_FRAGMENT}"
    done < <(ai_tools_path_order_repoint_user "${user}")

    ai_tools_path_order_read_user "${user}" || true
    state="${AI_TOOLS_PATH_ORDER_STATE:-unknown}"
    winner="${AI_TOOLS_PATH_ORDER_SHADOW:-}"
    # The launcher a message names is the shadowed one where there is one, and otherwise the first this host enables --
    # so the message is about a command the operator types.
    launcher=""
    for pair in "${AI_TOOLS_PATH_ORDER_WINNERS[@]+"${AI_TOOLS_PATH_ORDER_WINNERS[@]}"}"; do
        [[ -z "${launcher}" ]] && launcher="${pair%%=*}"
        [[ -n "${winner}" && "${pair#*=}" == "${winner}" ]] && { launcher="${pair%%=*}"; break; }
    done
    launcher="${launcher:-the agent}"

    # The two files it names govern bash. Another login shell reads its own, so the operator hears which ordering their
    # sessions actually get, at the moment the wiring is offered.
    case "${login_shell}" in
        */bash|'') ;;
        *) log "note: ${user}'s login shell is ${login_shell}, which reads its own init files rather than ${bashrc} or ${bashprof}."
           log "      rank ${AI_TOOLS_PATH_ORDER_WRAPPER_DIR} ahead of the nvm shims there too, so that typing ${launcher} reaches the ai-tools wrapper in that shell" ;;
    esac

    # Already wired and still shadowed: appending the line again edits the file and leaves the ordering as it was,
    # because what stands between this account and the wrapper is a later line that prepends to PATH. Report
    # that diagnosis instead of asking a question whose yes does not change the ordering.
    if [[ "${state}" == shadowed && "${AI_TOOLS_PATH_ORDER_WIRED:-no}" == yes ]]; then
        warn MSG-M2N9 "the PATH ordering line is already in ${user}'s shell init, and typing ${launcher} still runs ${winner}"
        warn "    something after that line prepends to PATH -- move it to the END of ${bashrc}, after the nvm init and anything else that touches PATH"
        return 0
    fi
    if [[ "${state}" == wired ]]; then
        log "PATH ordering: ${bashrc} already sources ${AI_TOOLS_PATH_ORDER_FRAGMENT}, and ${launcher} reaches the wrapper"
        return 0
    fi

    path_order_explain "${user}" "${state}" "${launcher}" "${winner}"
    if [[ -t 0 && -e /dev/tty ]]; then
        if ai_tools_msg_confirm \
            "Add the PATH ordering line to ${bashrc} and ${bashprof}?" y; then
            wire_init_file "${bashrc}"   "${user}" "${group}"
            wire_init_file "${bashprof}" "${user}" "${group}" login-chain
        else
            path_order_decline "${user}" "${state}" "${launcher}" "${winner}" "${bashrc}" "${bashprof}"
        fi
    else
        log "non-interactive: not editing shell init"
        path_order_decline "${user}" "${state}" "${launcher}" "${winner}" "${bashrc}" "${bashprof}"
    fi
}

# report_operator_role <user> -- say which of the two operator shapes this enrolment produced, where the decision is
# being made rather than where it first fails.
#
# This command writes both facts that make an operator (ai-ops membership, a name in OPERATORS) and CANNOT write
# the third thing a claim needs: a general sudo grant, which the host's own sudoers decides. Group membership cannot
# imply a sudoers rule, so the only way to know is to ask sudo -- and running as root, it can ask on the enrolled
# account's behalf without a password. The probe names ai-tools-lockdown because the secret gate is a claim's first
# sudo, so it answers the question the administrator actually has: can this account claim a project?
#
# An account without the grant is a supported shape, not a misconfiguration, so this reports and never refuses: it names
# the `--for` command that claims on the account's behalf.
#
# A non-zero answer is a refusal only while sudo is answering at all -- for a command no rule matches, `sudo -l` exits
# non-zero with EMPTY output, so there is no message separating that from a sudo which failed for its own reasons (an
# unreachable sudoers backend, a host that refuses `-l`). It is separated by a second probe, the same way the CLI's
# sudo_grant_missing does it: listing the account's whole rule set, which succeeds for anyone this command has just
# enrolled, since the %ai-ops rules apply to the membership written moments earlier (sudo reads the group database, not
# a cached credential). Only a first probe refused while the second answers is read as "no grant"; anything else is
# reported as undetermined, because a wrong verdict here is acted on immediately.
report_operator_role() {
    local user="$1"
    local claim_helper="/usr/local/libexec/ai-tools/ai-tools-lockdown"
    if ! command -v sudo >/dev/null 2>&1; then
        log "${user}: no sudo on this host, so no project can be claimed by anyone -- ${user} can still launch agent sessions"
        return 0
    fi
    if LC_ALL=C sudo -l -U "${user}" "${claim_helper}" >/dev/null 2>&1; then
        log "${user} holds a general sudo grant: it can claim projects as well as launch sessions"
        return 0
    fi
    if ! LC_ALL=C sudo -l -U "${user}" >/dev/null 2>&1; then
        log "${user}: sudo did not answer, so whether ${user} holds a general sudo grant is undetermined -- check with: sudo -l -U ${user}"
        return 0
    fi
    log "${user} holds no general sudo grant: it can launch agent sessions and read the reports, and cannot claim a project"
    log "${user}: claim on its behalf from an operator that holds one -- ai-tools projects claim --for ${user} <path>"
}

op_add() {
    local user="${1:-${SUDO_USER:-}}"
    [[ -n "${user}" ]] || reject MSG-H2P9 "operators add: name a user, or run it through sudo so SUDO_USER is set"
    [[ "${user}" != "${SANDBOX_USER}" ]] || die MSG-C9C4 "an operator must not be the sandbox account ${SANDBOX_USER}"
    [[ "${user}" != "root" ]]            || die MSG-H3M6 "an operator must be a normal login user, not root"
    id "${user}" &>/dev/null || die MSG-U8T8 "no such user: ${user}"

    ai_tools_load_operators || true   # tolerate an unenrolled host (empty list)
    local enrolled=0
    if in_list "${user}"; then
        enrolled=1
        log "${user} is already an operator; reconciling group, config, and sandbox linger"
    fi

    # The config is seeded BEFORE either fact that makes an operator, so an enrolment either completes or leaves
    # the host as it found it. An account in `OPERATORS` and in `ai-ops` whose `allowed-projects` does not exist is
    # refused at every launch, and does not resolve an owner in any root helper, while the enrolment reports success --
    # so the refusal belongs here, ahead of the first write, where a re-run then enrols the account in full.
    #
    # A RECONCILING re-run carries on instead: the record already stands, this run did not write it, and withdrawing
    # an operator is `operators remove`'s decision. It repairs what it can, reports what it could not, and exits
    # non-zero at the close.
    local seeded=0
    seed_operator_config "${user}" || seeded=1
    if (( seeded && ! enrolled )); then
        die MSG-T4X9 "not enrolled: ${user}'s config in ~/.config/ai-tools could not be seeded, and without allowed-projects it cannot start a session or claim a project -- clear the reason above and re-run"
    fi

    if (( ! enrolled )); then
        local newlist=()
        [[ "${#AI_TOOLS_OPERATORS[@]}" -gt 0 ]] && newlist=( "${AI_TOOLS_OPERATORS[@]}" )
        newlist+=( "${user}" )
        write_operators "${newlist[@]}"
        log "added ${user} to OPERATORS"
    fi

    # ai-ops membership: the sudoers grant and the launch wrapper gate on it. The sandbox account is never a member (it
    # must not be able to drive itself as an operator). Add -- and log -- only when the user is not already a member,
    # so a reconciling re-run does not report a change it did not make.
    if id -nG "${user}" 2>/dev/null | tr ' ' '\n' | grep -qx "${OPERATORS_GROUP}"; then
        log "${user} is already in group ${OPERATORS_GROUP}"
    else
        usermod -aG "${OPERATORS_GROUP}" "${user}" || die MSG-C4A8 "failed to add ${user} to ${OPERATORS_GROUP}"
        log "added ${user} to group ${OPERATORS_GROUP}"
    fi

    label_operator_config "${user}"

    # The sandbox account needs a `systemd --user instance` without an interactive login: its nvm-update timer and each
    # ai-tools-run session unit run there, and it has no login shell, so only linger keeps that instance alive.
    # An operator runs claude from its own active login, so it does not need linger here; enabling operator linger
    # for other reasons is host policy.
    log "enabling linger for ${SANDBOX_USER}"
    loginctl enable-linger "${SANDBOX_USER}"  2>/dev/null \
        || warn MSG-Q4K4 "could not enable linger for ${SANDBOX_USER}"

    wire_dedup "${user}"
    log "operator ${user} added"
    report_operator_role "${user}"
    # ai-ops membership applies to NEW login sessions; an already-open shell keeps the credential set it had at login,
    # and the launch wrapper gates on that live set. Name the activation step so the operator's first claude launch does
    # not hit the stale-session refusal.
    log "${user}: start a new login session (or run 'newgrp ${OPERATORS_GROUP}') before launching claude -- ${OPERATORS_GROUP} membership does not apply to already-open shells"
    # Only a reconciling re-run reaches this: a first enrolment already refused. Said last because the reason was
    # reported several steps and one prompt back, and non-zero so an unattended caller reads it without parsing
    # the output.
    if (( seeded )); then
        warn MSG-P9K2 "config not seeded for ${user}, which stays enrolled -- without allowed-projects in ~/.config/ai-tools it cannot start a session or claim a project"
        warn "    re-run once the reason above is cleared: sudo ai-tools-admin operators add ${user}"
        exit 1
    fi
}

op_remove() {
    local user="${1:-}"
    [[ -n "${user}" ]] || reject MSG-S3E9 "operators remove: name the user to withdraw"
    ai_tools_load_operators || true
    if ! in_list "${user}"; then
        log "${user} is not an operator; nothing to remove"
        return 0
    fi
    local kept=() n
    for n in "${AI_TOOLS_OPERATORS[@]}"; do [[ "${n}" == "${user}" ]] || kept+=("${n}"); done
    write_operators "${kept[@]}"
    log "removed ${user} from OPERATORS"
    # Drop ai-ops membership; leave the account's own allowlist and secret patterns (their data).
    gpasswd -d "${user}" "${OPERATORS_GROUP}" >/dev/null 2>&1 \
        || warn MSG-J9F9 "could not remove ${user} from ${OPERATORS_GROUP}"
    log "removed ${user} from group ${OPERATORS_GROUP}"
}

op_list() {
    if ai_tools_load_operators; then
        printf '%s\n' "${AI_TOOLS_OPERATORS[@]}"
    else
        log "no operators configured"
    fi
}

# ── selinux groups: optional policy-group management ─────────────────────────────────
# These load/unload the COMPILED ai_tools_<group>.pp staged in the package directory; the group set and text come
# from selinux-groups.lib.sh. Distinct from selinux/install-selinux.sh, which compiles a group from source in a repo
# checkout -- this runs on any installed host.

# require_selinux: guard shared by every selinux command. Returns 1 (caller exits 0 -- no policy to manage) when SELinux
# is disabled; dies when semodule is absent (a real gap).
require_selinux() {
    if [[ "$(getenforce 2>/dev/null)" == "Disabled" ]]; then
        log "SELinux is disabled on this host -- no policy groups to manage"
        return 1
    fi
    command -v semodule >/dev/null 2>&1 || die MSG-A8Z7 "semodule not found -- install policycoreutils"
    return 0
}

# _sel_require_known_group <name>: refuse a name the registry does not carry, showing what this host does know. One
# situation for both verbs -- a name that is not a group is the same refusal whether it was to be loaded or unloaded,
# so the two arms share it rather than each writing it.
_sel_require_known_group() {
    ai_tools_selinux_group_valid "$1" && return 0
    log "unknown group '$1'. Available groups:"; _selinux_usage_groups
    die MSG-D7Y7 "no such policy group: $1"
}

# _selinux_usage_groups: list the known groups (name + description) to stderr.
_selinux_usage_groups() {
    local entry
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        printf '    %-10s %s\n' \
            "$(ai_tools_selinux_group_name "${entry}")" \
            "$(ai_tools_selinux_group_desc "${entry}")" >&2
    done
}

# sel_enable <name>...: load each named group in turn. Several names are accepted because a toolchain declares the set
# it needs (selinux_groups in its manifest, ai-tools-providers(5)) and the status nudge prints that set as one command;
# each name is validated before any is loaded, so a typo refuses the whole command rather than loading half of it.
sel_enable() {
    [[ $# -ge 1 ]] || reject MSG-H7J4 "selinux groups enable: name the group(s) to load"
    require_selinux || return 0
    local name
    for name in "$@"; do
        [[ -n "${name}" && "${name}" != -* ]] || reject MSG-Q3Z5 "selinux groups enable: '${name}' is not a group name"
        _sel_require_known_group "${name}"
    done
    for name in "$@"; do _sel_enable_one "${name}"; done
}

_sel_enable_one() {
    local name="$1"
    if ai_tools_selinux_group_loaded "${name}"; then
        log "group '${name}' is already loaded -- nothing to do"
        return 0
    fi
    # Experimental groups are unaudited drafts and are NOT on the shipped set. This tool loads only shipped, stable
    # modules; an experimental group must be compiled and verified against a real workload from a source checkout first
    # (install-selinux.sh does both), because it widens the sandbox domain's access beyond the repo-only core. Point
    # the operator there rather than loading an unaudited module.
    if ai_tools_selinux_group_is_experimental "${name}"; then
        ai_tools_msg_warn MSG-C4F5 \
            "The '${name}' SELinux policy group is an EXPERIMENTAL, unaudited draft. It is not shipped prebuilt and cannot be enabled from here -- it widens the sandbox domain's access beyond the repo-only core and must be compiled and verified against a real workload from a source checkout first."
        log "compile, audit under permissive, and load it from a repo checkout:"
        log "    sudo selinux/install-selinux.sh enable-group ${name}"
        log "    (then re-run the bring-up loop in selinux/avc/ before relying on it)"
        log "docs: selinux/README.md, \"Optional policy groups\""
        die "'${name}' is experimental -- verify and enable it from source (see above)"
    fi
    local pp="${AI_TOOLS_SELINUX_PACKAGE_DIR}/ai_tools_${name}.pp"
    [[ -f "${pp}" ]] || die MSG-S5P4 "compiled module ${pp} not found -- reinstall ai-tools-selinux, or from a checkout: sudo selinux/install-selinux.sh build"
    # A former module still loaded from before this group was renamed or split out of it goes in the same transaction,
    # together with every OTHER current group that former module's rules became, so the host never holds both rule sets,
    # never loses a capability the old module carried, and a failed load leaves the old module in place.
    local former sibling
    local -a swap_args=( -i "${pp}" )
    if former="$(ai_tools_selinux_group_former_module "${name}" 2>/dev/null)" \
            && ai_tools_selinux_module_loaded "${former}"; then
        while IFS= read -r sibling; do
            [[ -n "${sibling}" && "${sibling}" != "${name}" ]] || continue
            [[ -f "${AI_TOOLS_SELINUX_PACKAGE_DIR}/ai_tools_${sibling}.pp" ]] || continue
            swap_args+=( -i "${AI_TOOLS_SELINUX_PACKAGE_DIR}/ai_tools_${sibling}.pp" )
        done < <(ai_tools_selinux_groups_from_former_module "${former}")
        log "replacing the loaded '${former}' module with the group(s) its rules became"
        semodule -r "${former}" "${swap_args[@]}" || die MSG-M8X2 "semodule failed to replace ${former}"
    else
        log "loading group: ai_tools_${name}"
        semodule "${swap_args[@]}" || die MSG-W7T4 "semodule failed to load ${pp}"
    fi
    _restore_group_static_labels
    log "group '${name}' enabled"
    log "re-run the SELinux bring-up loop (selinux/avc/) to catch any new denials from the"
    log "expanded surface before relying on it under enforcing."
}

sel_disable() {
    local name="${1:-}"
    [[ $# -le 1 ]] || reject MSG-W8A7 "selinux groups disable: one group name at a time"
    [[ -n "${name}" && "${name}" != -* ]] || reject MSG-P2T5 "selinux groups disable: name the group to unload"
    require_selinux || return 0
    _sel_require_known_group "${name}"
    if ai_tools_selinux_group_loaded "${name}"; then
        semodule -r "ai_tools_${name}" || die MSG-Q6F4 "semodule failed to remove ai_tools_${name}"
        _restore_group_static_labels
        log "group '${name}' disabled"
    else
        log "group '${name}' is not loaded -- nothing to do"
    fi
}

# _restore_group_static_labels: after a group is loaded or unloaded, restore the labels its static file contexts decide.
# The one tree a group's .fc names is the sandbox-clone area (the dotnet group maps a clone's build output
# to ai_tools_project_build_t), so that is what is restored; a claimed project's build rule is a per-project local rule
# written at claim time and is not the group's.
_restore_group_static_labels() {
    local clones=/var/opt/ai-tools/sandbox-projects
    [[ -d "${clones}" ]] && command -v restorecon >/dev/null 2>&1 || return 0
    restorecon -FR "${clones}" >/dev/null 2>&1 \
        || warn MSG-C9W9 "could not restore labels under ${clones}; run: sudo restorecon -FR ${clones}"
    return 0
}

# sel_list is a read-only REPORT, not operational output, so it renders as a plain section (like the CLI's
# `providers`/`projects list`) instead of `log`'s per-line `ai-tools-admin:` prefix. The core module uses the same
# bracketed [LOADED]/[disabled] state column as the group rows for one legend.
sel_list() {
    require_selinux || return 0
    local core_state='[disabled]' modules
    # Captured, not piped into `grep -q`: an early-exiting reader makes semodule die of SIGPIPE and pipefail then
    # reports the probe failed -- see ai_tools_selinux_group_loaded.
    modules="$(semodule -l 2>/dev/null || true)"
    grep -qx 'ai_tools' <<<"${modules}" && core_state='[LOADED]  '
    printf '\nSELinux policy groups\n\n'
    printf '  %s core module (ai_tools) -- the confinement domain; DAC-only when disabled\n\n' "${core_state}"
    printf '  optional groups (all default: disabled)\n'
    local entry name desc stability state
    for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
        name="$(ai_tools_selinux_group_name "${entry}")"
        desc="$(ai_tools_selinux_group_desc "${entry}")"
        stability="$(ai_tools_selinux_group_stability "${entry}")"
        if ai_tools_selinux_group_loaded "${name}"; then state='[LOADED]  '; else state='[disabled]'; fi
        printf '    %s %-9s %-15s %s\n' "${state}" "${name}" "(${stability})" "${desc}"
    done
    printf '\n  toggle       : sudo ai-tools-admin selinux groups enable <name> | disable <name>\n'
    printf '  experimental : not shipped prebuilt -- enable from a source checkout with\n'
    printf '                 sudo selinux/install-selinux.sh enable-group <name>\n'
}

# ── system bootstrap: provision the sandbox account and its toolchain ────────────────────────
# Execs the provisioning helper, which creates the @SANDBOX_USER@ account and its /opt/ai-tools home if they are absent,
# installs nvm and Node as that account, then installs each enabled agent's npm package and points its launcher
# at the result. The helper keeps its own name, path and output; what this command changes is how an administrator
# reaches it.
#
# The provisioning logic stays a separate file rather than moving in here: it is long, runs unattended
# from the container selftest, and reaches the network, none of which this dispatcher
# does.
#
# Scope defaults to the MINIMUM that works, and a bare run takes that default: the toolchain and the enabled agents,
# which is what a first host needs. `--scope full` also reaches every enabled integration, through each one's own
# contributed `bootstrap` -- which is why full scope needed the admin-commands seam before it could exist. It is spelled
# as a switch rather than a positional word because every other verb here takes a resource identifier in that slot.
system_bootstrap() {
    local scope=minimal
    local -a helper_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scope)
                [[ $# -ge 2 ]] || reject MSG-V5J3 "system bootstrap: --scope takes a value (minimal|full)"
                scope="$2"; shift 2 ;;
            # The unattended form of the agent choice the helper otherwise asks for; the helper checks each name
            # against the installed manifests before it writes anything, so the value passes through as typed.
            --agents)
                [[ $# -ge 2 ]] || reject MSG-X8K6 "system bootstrap: --agents takes a value (NAME[,NAME...])"
                helper_args+=(--agents "$2"); shift 2 ;;
            *)  reject MSG-H5Z4 "system bootstrap: unknown argument '$1' (--scope minimal|full, --agents NAME[,NAME...])" ;;
        esac
    done
    case "${scope}" in
        minimal|full) ;;
        *) reject MSG-A8G5 "system bootstrap: unknown scope '${scope}' (minimal|full)" ;;
    esac
    [[ -x "${BOOTSTRAP_BIN}" ]] \
        || die MSG-D9W6 "the provisioning helper is not installed: ${BOOTSTRAP_BIN} -- install ai-tools-integration-nodejs"
    # Minimal scope has no step after the helper, so it hands the process over rather than wrapping it: the helper's
    # exit status is this command's, unmediated.
    [[ "${scope}" == full ]] || exec "${BOOTSTRAP_BIN}" "${helper_args[@]+"${helper_args[@]}"}"
    "${BOOTSTRAP_BIN}" "${helper_args[@]+"${helper_args[@]}"}" || die MSG-Y6F3 "the toolchain bootstrap failed -- no integration was reached"
    bootstrap_integrations
}

# bootstrap_integrations: run the `bootstrap` of each ENABLED integration that contributes one. Enablement, not
# installation, is what "everything this host runs" means, so this reads the enabled set where the dispatch reads
# the installed one.
#
# Every integration is attempted and each failure named before the command exits non-zero: an administrator provisioning
# a host wants every outcome, not the first one that went wrong. An enabled integration that does not contribute
# a command fragment is reported and skipped -- base cannot assume any particular package is installed.
bootstrap_integrations() {
    declare -F ai_tools_enabled_integrations >/dev/null 2>&1 \
        || die MSG-Z4D6 "the provider resolver is unavailable, so the enabled integrations cannot be resolved -- the toolchain itself is provisioned; re-run without --scope to confirm"
    local -a enabled=()
    mapfile -t enabled < <(ai_tools_enabled_integrations)
    if [[ "${#enabled[@]}" -eq 0 ]]; then
        log "no integration is enabled in ${OPERATOR_CONF} -- nothing further to provision"
        return 0
    fi
    admin_domains
    admin_commands_trusted \
        || die MSG-D9U7 "refusing every contributed command while ${ADMIN_COMMANDS_DIR} holds a file that is not root's alone (named above); the toolchain itself is provisioned -- ${ADMIN_COMMANDS_TAMPER_REMEDY}"
    local integration known known_domain failed=0
    for integration in "${enabled[@]}"; do
        known=no
        for known_domain in "${ADMIN_DOMAINS[@]}"; do
            [[ "${known_domain}" == "${integration}" ]] && { known=yes; break; }
        done
        if [[ "${known}" != yes ]]; then
            log "${integration}: contributes no command -- nothing to provision"
            continue
        fi
        # The same gates an administrator's own `ai-tools-admin <domain> bootstrap` passes, so a fragment reached
        # from here is vetted exactly as one that is typed.
        if ! admin_command_check "${integration}"; then
            emit_coded warn "${_admin_command_reason}" "${integration}: "
            failed=1
            continue
        fi
        # Read from the declaration rather than learned by running it: an integration whose commands are something other
        # than provisioning has no work here, and running its fragment to find that out would report a rejected command
        # line as a failed provision.
        if ! admin_command_has_verb bootstrap; then
            log "${integration}: declares no bootstrap verb -- nothing to provision"
            continue
        fi
        log "provisioning the ${integration} integration"
        if ! "${ADMIN_COMMANDS_DIR}/${integration}" bootstrap; then
            warn MSG-J2Y8 "provisioning failed -- ${integration}: its bootstrap failed, with the cause above and in its own log"
            failed=1
        fi
    done
    (( failed == 0 )) || die MSG-V8V7 "one or more integrations did not provision"
}

# ── system entrypoints relabel: reconcile each enabled agent's entrypoint ─────────────────────
# Two steps in the helper, in this order: VERIFY the binary against the checksum its vendor signed and record it
# in that agent's pin, which ai-tools-run compares the binary against at launch; then RELABEL it to ai_tools_exec_t,
# which an nvm-update leaves as bin_t so the domain transition stops firing. Takes no path -- the helper resolves
# the entrypoints from the agent manifests.
entrypoints_relabel() {
    [[ $# -eq 0 ]] || reject MSG-A4J6 "system entrypoints relabel: takes no arguments"
    [[ -x "${RELABEL_ENTRYPOINT_BIN}" ]] \
        || die MSG-F5R8 "the entrypoint relabel helper is not installed: ${RELABEL_ENTRYPOINT_BIN} -- install ai-tools-integration-nodejs"
    log "reconciling the agent entrypoints (verify, then relabel)"
    # Cleared, not merely left unset: the guarantee that this command re-fetches the vendor's signed manifest holds
    # however it was invoked, rather than resting on sudo scrubbing the environment (updater.rule.md). The unattended
    # callers set it themselves.
    unset AI_TOOLS_ENTRYPOINT_PIN_REUSE
    exec "${RELABEL_ENTRYPOINT_BIN}"
}

# ── system post-upgrade: reconcile the .rpmnew files an upgrade leaves ─────────────────────── rpm keeps
# an operator-modified %config(noreplace) file and parks the package's copy beside it as <file>.rpmnew. Choosing
# between the two is a judgement call about the operator's own configuration, so no scriptlet makes it: this is
# the explicit, interactive command that does, and it is what the install output points at. Every treatment confirms
# first, backs the file up before writing, and names each path it touched. A .rpmnew survives the run, whichever
# treatment it got: each one leaves part of the reconciliation to the operator, and the copy is the baseline that edit
# is made from, so each block closes by naming the file to remove once the merge is done.
#
# The treatment follows the file's CONTENT, rather than one generic merge covering all three:
#   json    hook DECLARATIONS merge additively -- they are control plane, and a declaration the
#           file lacks means a shipped hook installs but no event invokes it. The permission arrays
#           are the host's and stay exactly as written (claude-settings.rule.md).
#   keyval  reported, never rewritten. An absent key already means its default, so a stale file
#           costs knowledge rather than behaviour, and its layout is the operator's own prose.
#   review  shown only. A tool does not merge the sudo grant.
readonly -a POSTUPGRADE_FILES=(
    "/opt/ai-tools/.claude/settings.json|json|Claude Code settings"
    "/etc/ai-tools/operator.conf|keyval|host options"
    "/etc/sudoers.d/ai-tools|review|sudoers grant"
)

# AI_TOOLS_POSTUPGRADE_ROOT prefixes every path in that registry, so the test suite drives this command against fixtures
# in its own /tmp testdir instead of the live host's control plane. It is a ROOT-ONLY test hook of the same shape
# and standing as AI_TOOLS_ALLOWLIST: sudo strips the environment (env_reset, and this name is not in env_keep)
# and the helper is reachable only as root, so neither an operator nor the agent can set it, and a caller who could is
# one that may already edit these files outright. Unset in production, where the registry paths are absolute.

# _pu_diff <deployed> <rpmnew>: show what the package would change, indented. Colourized through colordiff when the host
# has it AND stdout is a terminal: colordiff is an EPEL package on RHEL, so it is used where present and never depended
# on, and the terminal test keeps escape sequences out of a redirected run, the way every other message this project
# prints degrades when piped. diff(1) is optional too -- without it the report continues and only the difference itself
# is missing.
_pu_diff() {
    local differ=diff
    command -v diff >/dev/null 2>&1 \
        || { warn MSG-Q4S8 "diff is not installed, so the difference is not shown here -- install diffutils"; return 0; }
    [[ -t 1 ]] && command -v colordiff >/dev/null 2>&1 && differ=colordiff
    "${differ}" -u "$1" "$2" 2>/dev/null | sed 's/^/    /' || true
}

# _pu_leave <rpmnew> [merged]: close a file's block by naming what is left to do with the copy. This function prints,
# and is the only thing any treatment does about the .rpmnew, so the copy survives every run. Each treatment leaves part
# of the reconciliation to the operator -- the permission rules here, the whole edit for a KEY=value file, the adoption
# of a sudo grant -- and the copy is the only record of what the package shipped, so deleting it would take away
# the baseline that edit is made from. It is the operator's file to remove, once the merge they wanted is in place.
# `merged` says the deployed file now matches the copy byte for byte, so the removal is all that remains.
_pu_leave() {
    local rpmnew="$1"
    if [[ "${2:-}" == merged ]]; then
        log "  nothing is left to carry over -- remove ${rpmnew} when you are ready"
    else
        log "  merge new config changes by hand, then remove ${rpmnew}"
    fi
}

# _pu_json <deployed> <rpmnew>: merge the hook declarations the deployed file does not carry. The addition list comes
# from running the merge on a THROWAWAY COPY first, so what the operator confirms is the exact set the real merge adds
# rather than a promise of one, and a merge that would fail says so before the real file is touched.
_pu_json() {
    local deployed="$1" rpmnew="$2" scratch status=0
    ai_tools_conf_require_jq \
        || { warn MSG-A5Z7 "jq is missing, so this file's JSON cannot be read -- merge it by hand"; return 0; }

    scratch="$(mktemp -d)" || return 0
    cp -p "${deployed}" "${scratch}/probe" 2>/dev/null || { rm -rf "${scratch}"; return 0; }
    ai_tools_conf_merge_hook_declarations "${scratch}/probe" "${rpmnew}" || status=$?
    rm -rf "${scratch}"

    case "${status}" in
    1)  log "  hook declarations are already current -- nothing to merge"
        log "  the difference left is in the permission rules, which are yours to tune:"
        _pu_diff "${deployed}" "${rpmnew}"
        _pu_leave "${rpmnew}"
        return 0 ;;
    2)  warn MSG-Q4F6 "cannot merge the hook declarations: ${_ai_tools_conf_merge_reason}"
        warn "    ${deployed} is unchanged -- copy the \"hooks\" block from ${rpmnew} by hand"
        return 0 ;;
    esac

    local line
    if (( ${#_ai_tools_conf_merge_added[@]} > 0 )); then
        log "  hook declarations this version adds:"
        for line in "${_ai_tools_conf_merge_added[@]}"; do log "    + ${line}"; done
    fi
    if (( ${#_ai_tools_conf_merge_removed[@]} > 0 )); then
        log "  hook declarations declared twice, of which the merge keeps the first:"
        for line in "${_ai_tools_conf_merge_removed[@]}"; do log "    - ${line}"; done
    fi
    log "  nothing else changes -- your permission rules stay as written"
    ai_tools_msg_confirm "  Merge these into ${deployed}?" y || { log "  skipped -- ${deployed} unchanged"; return 0; }

    status=0
    ai_tools_conf_merge_hook_declarations "${deployed}" "${rpmnew}" || status=$?
    if (( status >= 2 )); then
        warn MSG-X9F8 "the merge failed: ${_ai_tools_conf_merge_reason} -- ${deployed} is unchanged"
        return 0
    fi
    log "  merged -- the previous file is saved as ${_ai_tools_conf_merge_backup}"

    # Close against what is left. Once the permission rules match too, the .rpmnew has no difference left to report,
    # so the operator is told the removal is all that remains.
    if command -v diff >/dev/null 2>&1 && diff -q "${deployed}" "${rpmnew}" >/dev/null 2>&1; then
        log "  ${deployed} now matches the shipped file exactly"
        _pu_leave "${rpmnew}" merged
    else
        log "  the permission rules still differ -- review them before you remove the copy:"
        _pu_diff "${deployed}" "${rpmnew}"
        _pu_leave "${rpmnew}"
    fi
}

# _pu_keyval <deployed> <rpmnew>: report and never write. A KEY=value config is mostly prose -- commented option blocks
# whose layout is the operator's -- and merging prose would need a convention an operator has to learn before they can
# predict it. Name the options the new version documents that this file does not mention, show the difference, and leave
# the edit to them.
_pu_keyval() {
    local deployed="$1" rpmnew="$2" key
    local -a new_keys=()
    if ai_tools_conf_new_keys new_keys "${deployed}" "${rpmnew}"; then
        log "  options this version documents that ${deployed} does not mention:"
        for key in "${new_keys[@]}"; do log "    ${key}"; done
        log "  each one is optional and an unmentioned key keeps its default, so leaving them out"
        log "  breaks nothing -- copy the blocks you want; see ai-tools-operator.conf(5)"
    else
        log "  every option this version documents is already mentioned in ${deployed}"
    fi
    log "  the full difference:"
    _pu_diff "${deployed}" "${rpmnew}"
    _pu_leave "${rpmnew}"
}

# _pu_review <deployed> <rpmnew>: show and stop. This file is the sudo grant itself.
_pu_review() {
    local deployed="$1" rpmnew="$2"
    ai_tools_msg_warn MSG-H8A2 \
        "This file defines the sudo grant that lets an operator launch the sandbox. It is shown, never merged: check any change yourself with visudo -c before adopting it."
    _pu_diff "${deployed}" "${rpmnew}"
    log "  adopt the packaged version with:  sudo visudo -c -f ${rpmnew} && sudo cp ${rpmnew} ${deployed}"
    _pu_leave "${rpmnew}"
}

postupgrade() {
    [[ $# -eq 0 ]] || reject MSG-S9M6 "system post-upgrade: takes no arguments"
    local entry file kind label found=0
    local root="${AI_TOOLS_POSTUPGRADE_ROOT:-}"

    for entry in "${POSTUPGRADE_FILES[@]}"; do
        IFS='|' read -r file kind label <<< "${entry}"
        file="${root}${file}"
        [[ -f "${file}.rpmnew" && -f "${file}" ]] || continue
        found=1
        ai_tools_msg_headline "${label}: ${file}" 1
        case "${kind}" in
            json)   _pu_json   "${file}" "${file}.rpmnew" ;;
            keyval) _pu_keyval "${file}" "${file}.rpmnew" ;;
            review) _pu_review "${file}" "${file}.rpmnew" ;;
        esac
    done

    if (( found == 0 )); then
        log "no .rpmnew files are waiting -- every config file this stack owns is reconciled"
        return 0
    fi
    log "done -- this command is idempotent, re-run it at any time"
}

# ── status ───────────────────────────────────────────────────────────────────────────────────
# `ai-tools status` read from root's vantage -- one resource reported twice, not a second report. Which readings root
# adds and why the two agree is .claude/rules/cli.rule.md; what this file contributes is the rendering, in the plain
# bracket-token idiom the rest of this tool uses. The verdicts come from services.lib.sh and relabel.lib.sh, which emit
# data and leave every consumer to format it.
readonly SERVICES_LIB="/usr/local/lib/ai-tools/services.lib.sh"
readonly RELABEL_LIB="/usr/local/lib/ai-tools/relabel.lib.sh"
readonly ENTRYPOINT_VERIFY_LIB="/usr/local/lib/ai-tools/entrypoint-verify.lib.sh"
readonly LAUNCHER_LINK_DIR="/opt/ai-tools/bin"

# st <state> <text>: one report line, state in a bracket token so a scan down the left column finds what needs
# attention. The vocabulary is the CLI's -- OK, DOWN, FAILED, STALE, SKIPPED, n/a, ? -- because an administrator reads
# both reports about one host and a second set of words for the same states would read as a second set of facts.
st()      { printf '    %-13s %s\n' "[$1]" "$2"; }
detail()  { printf '                  %s\n' "$*"; }
heading() { printf '\n  %s\n\n' "$*"; }

# status_services: every unit in the shared registry, with its consequence and remedy where one needs attention. Renders
# to stdout and counts the units needing attention in STATUS_PROBLEMS.
STATUS_PROBLEMS=0
status_services() {
    heading "Services"
    local rec unit scope stamp mode state age when exit_code reason remedy uid
    while IFS= read -r rec; do
        unit="$(ai_tools_service_field "${rec}" 1)"
        scope="$(ai_tools_service_field "${rec}" 2)"
        stamp="$(ai_tools_service_field "${rec}" 7)"
        mode="$(ai_tools_service_field "${rec}" 8)"
        state="$(ai_tools_service_state_of "${rec}")"
        age=""; when=""
        if [[ -n "${stamp}" ]]; then
            age="$(ai_tools_service_fmt_age "$(ai_tools_service_stamp_age "${stamp}")")"
            [[ -n "${age}" ]] && when="last run ${age}"
        fi
        case "${state}" in
            active)  st OK "${unit}${when:+  ${when}}" ;;
            down)    st DOWN "${unit}" ;;
            skipped) reason="$(ai_tools_service_stamp_field "${stamp}" REASON)"
                     st SKIPPED "${unit}  ${when:-last run at an unknown time}${reason:+, ${reason}} -- nothing was changed" ;;
            failed)  if [[ -n "${stamp}" ]]; then
                         exit_code="$(ai_tools_service_stamp_field "${stamp}" EXIT_CODE)"
                         st FAILED "${unit}  ${when:-last run at an unknown time}, exit ${exit_code:-?}"
                     else
                         exit_code="$(ai_tools_service_unit_property "${unit}" ExecMainStatus "${scope}")"
                         st FAILED "${unit}  its last run exited ${exit_code:-non-zero}"
                     fi ;;
            stale)   st STALE "${unit}  ${when:-last run long ago}" ;;
            absent)  st "n/a" "${unit}  not installed" ;;
            # Not a fault report -- it says only that even this vantage point could not tell, and is not counted,
            # the same rule the operator view follows. The two scopes fail for different reasons and say so: a system
            # unit is unreadable only where there is no systemctl at all, while a sandbox-user one means root reached
            # neither that account's manager (no machine transport, no timeout(1), or no answer inside the probe's
            # window) nor a last-run stamp.
            *)       if [[ "${scope}" == system ]]; then
                         st "?" "${unit}  systemctl is unavailable here"
                     else
                         st "?" "${unit}  neither its manager nor a last-run stamp could be read"
                     fi ;;
        esac
        ai_tools_service_needs_attention "${state}" || continue
        STATUS_PROBLEMS=$(( STATUS_PROBLEMS + 1 ))
        detail "$(ai_tools_service_field "${rec}" 5)"
        # A sandbox-user unit's commands name the sandbox ACCOUNT, and services.lib.sh is deployed with no
        # @SANDBOX_USER@ substitution, so they are composed here -- the same split the CLI makes, and the reason
        # the registry's remedy field is empty for those units.
        if [[ "${scope}" != system ]]; then
            detail "sudo systemctl --user -M ${SANDBOX_USER}@.host status ${unit}"
            uid="$(id -u "${SANDBOX_USER}" 2>/dev/null || true)"
            [[ -n "${uid}" ]] \
                && detail "sudo journalctl _SYSTEMD_USER_UNIT=${unit} _UID=${uid} -n 50 --no-pager"
            detail "sudo systemctl --user -M ${SANDBOX_USER}@.host restart ${unit}"
        fi
        remedy="$(ai_tools_service_field "${rec}" 6)"
        [[ -n "${remedy}" ]] && detail "${remedy}"
    done < <(ai_tools_service_records)
    return 0
}

# status_managed_files: per enabled agent, each managed file its manifest names (managed_files, ai-tools-providers(5))
# whose live copy is not the shipped one -- the same reading `ai-tools status` makes, rendered in this tool's table.
# The package never overwrites such a file, so this line is where an operator learns it differs. An edited file is
# a supported state and is not counted; a missing one is, since the package is then broken. Prints no line for a file
# matching the shipped copy.
status_managed_files() {
    declare -F ai_tools_enabled_agents >/dev/null 2>&1 || return 0
    declare -F ai_tools_agent_managed_files >/dev/null 2>&1 || return 0
    local agent live reference state
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        while IFS=$'\t' read -r live reference; do
            [[ -n "${live}" ]] || continue
            state="$(ai_tools_managed_file_state "${live}" "${reference}")"
            case "${state}" in
                shipped) ;;
                edited)  st edited "${agent}  ${live} differs from the shipped copy"
                         detail "${agent} reads the live file alone: a key this release adds is not in it, and what it declares is the host's"
                         detail "shipped copy: ${reference}" ;;
                missing) st MISSING "${agent}  ${live} is missing -- reinstall the ${agent} package"
                         STATUS_PROBLEMS=$(( STATUS_PROBLEMS + 1 )) ;;
                *)       st "?" "${agent}  ${live} cannot be compared with the shipped copy ${reference}" ;;
            esac
        done < <(ai_tools_agent_managed_files "${agent}")
    done < <(ai_tools_enabled_agents 2>/dev/null)
    return 0
}

# status_entrypoints: per enabled agent, the two halves of the entrypoint reconciliation -- the pin
# ai_tools_entrypoint_pin_write leaves, and the type its paths carry now. Reported together because they fail
# independently: verification can succeed while labelling does not, leaving a green pin written by the very run
# whose labelling failed.
#
# Only two states here count toward the exit status, and both stop the next launch: an unpinned entrypoint
# where AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY is set, and a mislabelled path. Unpinned without that setting is a supported
# state -- an air-gapped host, a release published without a manifest -- so it is reported and left uncounted.
status_entrypoints() {
    heading "Entrypoints"
    # Three libraries answer this section between them, and a partial load must report that rather than reach
    # an undefined function -- which under `set -e` would abort the whole report over the section it could not give.
    if ! declare -F ai_tools_enabled_agents      >/dev/null 2>&1 \
            || ! declare -F ai_tools_agent_manifest_field  >/dev/null 2>&1 \
            || ! declare -F ai_tools_entrypoint_pin_path   >/dev/null 2>&1; then
        st "?" "the provider or entrypoint libraries are unavailable -- no agent could be resolved"
        return 0
    fi

    local agent pin version age live strict=no seen=0
    declare -F ai_tools_entrypoint_verify_required >/dev/null 2>&1 \
        && ai_tools_entrypoint_verify_required && strict=yes
    while IFS=$'\t' read -r agent _ _; do
        [[ -n "${agent}" ]] || continue
        seen=1
        # Verification compares the binary against the checksum in the vendor's signed release manifest,
        # which an agent's package names in release_manifest_url. An agent whose package omits that key is reported
        # as such rather than as perpetually unverified.
        pin="$(ai_tools_entrypoint_pin_path "${agent}" 2>/dev/null || true)"
        if [[ -z "$(ai_tools_agent_manifest_field "${agent}" release_manifest_url 2>/dev/null || true)" \
              && ! -e "${pin}" ]]; then
            st "n/a" "${agent}  its package declares no signed release manifest, and root has recorded no pin yet"
            continue
        fi
        version="$(ai_tools_service_stamp_field "${pin}" VERSION)"
        # The reading this vantage adds: root can traverse the toolchain, so it hashes the entrypoint and compares it
        # against the pin instead of reporting what the last reconciliation recorded. A binary that changed since is
        # therefore named here even where no reconciliation has run over it yet -- the pin's own fields cannot say
        # so, and the operator's report can only read them.
        live="$(entrypoint_live_verdict "${agent}")"
        if [[ "${live}" == mismatch ]]; then
            st MISMATCH "${agent}  the installed entrypoint does not match its pin${version:+ (${version})} -- its sessions refuse to start"
            detail "sudo ai-tools-admin system entrypoints relabel   (re-reads the entrypoint and prints how to replace it)"
            STATUS_PROBLEMS=$(( STATUS_PROBLEMS + 1 ))
        elif entrypoint_stale_mark "${agent}"; then
            STATUS_PROBLEMS=$(( STATUS_PROBLEMS + 1 ))
        elif [[ -n "${version}" && "$(ai_tools_entrypoint_pin_kind "${agent}" 2>/dev/null || true)" == observed ]]; then
            # Recorded as installed: a change to the binary refuses at every setting, and no vendor signature stands
            # behind the value. UNCHANGED is what the comparison proves; it does not say the binary was sound when root
            # first recorded it. It is a pin, so it satisfies the strictness switch and is not a problem.
            age="$(ai_tools_service_fmt_age "$(ai_tools_service_stamp_age "${pin}" VERIFIED)")"
            st UNCHANGED "${agent}  ${version}${age:+, ${age}}, as installed -- its vendor publishes no signed manifest"
        elif [[ -n "${version}" ]]; then
            age="$(ai_tools_service_fmt_age "$(ai_tools_service_stamp_age "${pin}" VERIFIED)")"
            st VERIFIED "${agent}  ${version}${age:+, ${age}}"
        elif [[ -e "${pin}" ]]; then
            st unverified "${agent}  its pin is present and carries no version this reader accepts"
            detail "sudo ai-tools-admin system entrypoints relabel   (rewrites the pin)"
        elif [[ "${strict}" == yes ]]; then
            st UNVERIFIED "${agent}  this host requires verification, so its sessions will not launch"
            detail "sudo ai-tools-admin system entrypoints relabel   (fetches the vendor's signed manifest)"
            STATUS_PROBLEMS=$(( STATUS_PROBLEMS + 1 ))
        else
            st unverified "${agent}  no pin -- launches are not blocked"
        fi
    done < <(ai_tools_enabled_agents 2>/dev/null)
    [[ "${seen}" -eq 1 ]] || st "n/a" "no agent is enabled in ${OPERATOR_CONF}"
    status_labels
}

# entrypoint_live_verdict <agent>: print what the agent's installed entrypoint hashes to against its pin RIGHT NOW --
# `ok`, `mismatch`, `unpinned`, `unreadable` -- or an empty string where the reading cannot be made. The third root-only
# reading of this report, beside the live SELinux type: the toolchain is 0750 and sandbox-owned, so no operator-side
# command can hash that file, and a pin records only what the last reconciliation found. Read-only, and it does not
# reach the network: it is the comparison the launch shim makes on every launch.
entrypoint_live_verdict() {
    local agent="$1" entrypoint
    declare -F ai_tools_entrypoint_check      >/dev/null 2>&1 || return 0
    declare -F ai_tools_agent_entrypoint_path >/dev/null 2>&1 || return 0
    entrypoint="$(ai_tools_agent_entrypoint_path "${agent}" 2>/dev/null || true)"
    [[ -n "${entrypoint}" ]] || return 0
    ai_tools_entrypoint_check "${agent}" "${entrypoint}" 2>/dev/null || true
}

# entrypoint_stale_mark <agent>: report, and return 0, when the last reconciliation REFUSED to re-record this agent's
# pin. The refusal leaves the pin standing -- that staleness is what makes the next launch refuse -- so without this
# the pin's own fields render as a verification that succeeded. Returns non-zero when there is no mark, which is
# the ordinary state.
entrypoint_stale_mark() {
    local agent="$1" record reason version age
    declare -F ai_tools_entrypoint_stale_path >/dev/null 2>&1 || return 1
    record="$(ai_tools_entrypoint_stale_path "${agent}" 2>/dev/null || true)"
    [[ -n "${record}" && -e "${record}" ]] || return 1
    [[ "$(ai_tools_service_stamp_field "${record}" STATE)" == stale ]] || return 1
    reason="$(ai_tools_service_stamp_field "${record}" REASON)"
    version="$(ai_tools_service_stamp_field "${record}" VERSION)"
    age="$(ai_tools_service_fmt_age "$(ai_tools_service_stamp_age "${record}" DETECTED)")"
    st "PIN STALE" "${agent}  a reconciliation refused to re-record this pin (${reason:-refused}${version:+, ${version}})${age:+, ${age}} -- its sessions refuse to start"
    detail "sudo ai-tools-admin system entrypoints relabel   (re-reads the entrypoint and prints how to replace it)"
    return 0
}

# status_labels: render ai_tools_agent_label_report -- the live SELinux type of each enabled agent's own paths,
# which that function's header specifies. It closes status_entrypoints rather than opening a section of its own, so each
# agent's pin and its labels read together.
status_labels() {
    # Base ships this library beside this tool, so a missing report means a broken or half-upgraded install rather than
    # an optional piece -- said as a reading that could not be made, since that is what it is from the reader's side.
    if ! declare -F ai_tools_agent_label_report >/dev/null 2>&1; then
        st "?" "live labels: ${RELABEL_LIB} did not load its report -- reinstall ai-tools-base"
        return 0
    fi
    local report verdict agent what path actual wanted rc=0
    report="$(ai_tools_agent_label_report)" || rc=$?
    if [[ "${rc}" -eq 2 ]]; then
        st "n/a" "SELinux confinement is inactive here -- there is no agent label to carry"
        return 0
    fi
    [[ -n "${report}" ]] || return 0
    while read -r verdict agent what path actual wanted; do
        case "${verdict}" in
            ok)   st labelled "${agent}  its ${what} is ${actual} -- ${path}" ;;
            bad)  st "NOT LABELLED" "${agent}  its ${what} is '${actual}', NOT ${wanted} -- ${path}"
                  detail "its next session refuses to launch rather than run unconfined"
                  detail "sudo ai-tools-admin system entrypoints relabel"
                  STATUS_PROBLEMS=$(( STATUS_PROBLEMS + 1 )) ;;
            none) st "n/a" "${agent}  its ${what} is not installed -- nothing to label" ;;
        esac
    done <<< "${report}"
    return 0
}

# status: the host report. Exits non-zero when something is broken, so it is usable from a monitor or a cron check
# without parsing this output -- the same contract `ai-tools status` offers, and the reason `?` and `n/a` are never
# counted: a reading this vantage point could not make must not make a healthy host alarm every night.
status() {
    [[ $# -eq 0 ]] || reject MSG-T6S6 "status: takes no arguments"
    STATUS_PROBLEMS=0
    # Ahead of the library load, so a report that cannot be given still says what was asked for: the refusal then reads
    # as this command failing rather than as an unattributed error.
    printf '\nai-tools host status\n'

    # Loaded here rather than beside the other libraries: each is read by one command, and relabel.lib.sh pulls
    # in the provider and control-plane libraries behind it. `operators add` loads that one the same way, inside
    # the command that needs it. Each is best-effort and its section reports what it could not read, EXCEPT the service
    # registry -- without it there is no report to give, and a clean bill this tool cannot support is worse than
    # a refusal.
    # shellcheck source=SCRIPTDIR/../../lib/ai-tools/services.lib.sh
    source "${SERVICES_LIB}" 2>/dev/null || true
    # shellcheck source=SCRIPTDIR/../../lib/ai-tools/relabel.lib.sh
    source "${RELABEL_LIB}" 2>/dev/null || true
    # shellcheck source=SCRIPTDIR/../../lib/ai-tools/entrypoint-verify.lib.sh
    source "${ENTRYPOINT_VERIFY_LIB}" 2>/dev/null || true
    if ! declare -F ai_tools_service_records   >/dev/null 2>&1 \
            || ! declare -F ai_tools_service_state_of >/dev/null 2>&1 \
            || ! declare -F ai_tools_service_fmt_age  >/dev/null 2>&1; then
        die MSG-V6N9 "the service registry (${SERVICES_LIB}) is unavailable -- reinstall ai-tools-base"
    fi
    # Root reaching the sandbox account's own manager is what this report adds over the operator's.
    ai_tools_service_sandbox_account "${SANDBOX_USER}"

    heading "Version"
    printf '    %-13s %s\n' "ai-tools" "${AI_TOOLS_VERSION}"
    # Node's version comes from whichever registry record publishes one, so the loop reads the registry rather than
    # a unit name, and a host whose updater has not run yet omits the line.
    local rec node_ver=""
    while IFS= read -r rec; do
        node_ver="$(ai_tools_service_stamp_field "$(ai_tools_service_field "${rec}" 7)" NODE)"
        [[ -n "${node_ver}" && "${node_ver}" != unknown ]] && break
        node_ver=""
    done < <(ai_tools_service_records)
    [[ -n "${node_ver}" ]] \
        && printf '    %-13s %s\n' "node" "${node_ver} (as of the last toolchain update)"

    heading "Provisioning"
    # The launcher directory holding a link is bootstrap's last artifact, and the same sentinel the CLI's own gate keys
    # on, so both answer this question the same way.
    if compgen -G "${LAUNCHER_LINK_DIR}/*" >/dev/null 2>&1; then
        st OK "the toolchain is provisioned"
    else
        st MISSING "no launcher in ${LAUNCHER_LINK_DIR} -- the toolchain is not provisioned"
        detail "sudo ai-tools-admin system bootstrap"
        STATUS_PROBLEMS=$(( STATUS_PROBLEMS + 1 ))
    fi
    status_managed_files

    status_services
    status_entrypoints

    # Pointers, not duplication: the reports that own the detail this one deliberately does not.
    heading "More"
    printf '    %s\n' \
        "ai-tools status          the same host, read from an operator's vantage" \
        "ai-tools providers       installed agents and integrations, and which are enabled" \
        "sudo ai-tools-admin selinux groups   the core module and the optional groups" \
        "sudo ai-tools-admin --help           every command this host has"
    printf '\n'

    [[ "${STATUS_PROBLEMS}" -eq 0 ]]
}

# ── dispatch ─────────────────────────────────────────────────────────────────────────────────
# One arm per name in the grammar's two shapes: `<collection> [verb]`, where the absent verb is `list`,
# and `<domain> <collection|verb>`. A bare collection lists; a bare domain prints its own commands, since a domain has
# no reading that a default could safely take and every verb under one of these mutates the host.

operators_dispatch() {
    local verb="${1:-list}"; [[ $# -eq 0 ]] || shift
    case "${verb}" in
        list)   op_list   "$@" ;;
        add)    op_add    "$@" ;;
        remove) op_remove "$@" ;;
        *)      reject MSG-H6J5 "unknown command 'operators ${verb}' (list|add|remove)" ;;
    esac
}

selinux_groups_dispatch() {
    local verb="${1:-list}"; [[ $# -eq 0 ]] || shift
    case "${verb}" in
        list)    sel_list ;;
        enable)  sel_enable  "$@" ;;
        disable) sel_disable "$@" ;;
        *)       reject MSG-H3F8 "unknown command 'selinux groups ${verb}' (list|enable|disable)" ;;
    esac
}

selinux_dispatch() {
    [[ $# -ge 1 ]] || reject MSG-D6K9 "selinux owns one collection: 'selinux groups [list|enable|disable]'"
    local resource="$1"; shift
    case "${resource}" in
        groups) selinux_groups_dispatch "$@" ;;
        *)      reject MSG-V9Z4 "unknown command 'selinux ${resource}' (groups)" ;;
    esac
}

system_entrypoints_dispatch() {
    # No `list` yet, so a bare `system entrypoints` names its verb rather than running one: relabel re-fetches a signed
    # manifest and rewrites a pin, which is not a reading a default may take.
    [[ $# -ge 1 ]] || reject MSG-U8G3 "system entrypoints takes a verb: 'system entrypoints relabel'"
    local verb="$1"; shift
    case "${verb}" in
        relabel) entrypoints_relabel "$@" ;;
        *)       reject MSG-T7N9 "unknown command 'system entrypoints ${verb}' (relabel)" ;;
    esac
}

system_dispatch() {
    [[ $# -ge 1 ]] || reject MSG-C7S7 "system takes a resource or a verb: 'system bootstrap', 'system entrypoints relabel', 'system post-upgrade'"
    local name="$1"; shift
    case "${name}" in
        bootstrap)    system_bootstrap "$@" ;;
        entrypoints)  system_entrypoints_dispatch "$@" ;;
        post-upgrade) postupgrade "$@" ;;
        *)            reject MSG-Q2X5 "unknown command 'system ${name}' (bootstrap|entrypoints|post-upgrade)" ;;
    esac
}

# Sourced rather than executed (see the note at the root check): stop here with every function defined and no command
# dispatched, so the caller's arguments are not read as a command.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

# `--help`/`-h` and `--version` are answered ahead of the root check.
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
case "$1" in
    operators) shift; operators_dispatch "$@" ;;
    selinux)   shift; selinux_dispatch   "$@" ;;
    system)    shift; system_dispatch    "$@" ;;
    status)    shift; status             "$@" ;;
    # Anything else is either a domain a provider package contributed or an unknown command, and only the discovered set
    # tells the two apart. Base names are matched first, so a fragment cannot shadow one however it is named.
    *) contributed_dispatch "$@" ;;
esac

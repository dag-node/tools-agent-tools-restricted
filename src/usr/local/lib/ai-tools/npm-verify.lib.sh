#!/usr/bin/env bash
# /usr/local/lib/ai-tools/npm-verify.lib.sh
# Verify npm registry signatures (and SLSA provenance where published) for the globally
# installed sandbox toolchain, so a compromised registry or mirror serving a TAMPERED
# package is detected before the new toolchain is activated. `npm install` already checks
# each tarball's integrity hash, but the hash proves only that the download matches what the
# registry advertised -- a hostile registry can advertise a matching hash for a malicious
# tarball. The registry SIGNATURE (an ECDSA signature over `<pkg>@<ver>:<integrity>` by a key
# the client pins from the registry keys endpoint) is what the signature check adds.
# See updater.rule.md.
#
# ── Runs as the sandbox account, never root ──────────────────────────────────
# The verifier operates over the sandbox account's global npm tree -- data the agent (which
# runs as that account) can write. It MUST run as the sandbox account, the same principal that
# owns the tree: as root it would resolve ROOT's global npm (not the sandbox's, so it could
# report a false "verified" over the wrong tree) and would turn npm/node execution over
# agent-controlled files into a root surface. Both callers already invoke it as the sandbox
# account (nvm-update.sh runs as it directly; ai-tools-bootstrap calls it inside a `sudo -u`
# sandbox-account step), and ai_tools_verify_npm_signatures refuses to run as root as a
# fail-closed backstop. This library carries no @-tokens: it is deployed unsubstituted, and it
# discovers the account's global tree at runtime (`npm root -g`) rather than naming it.
#
# ── Split: pure verdict + impure probe (mirrors confinement.lib.sh) ──────────
# ai_tools_npm_verdict <audit-json>   -- PURE decision: no npm, no filesystem, no privilege,
#   no side effects. Given `npm audit signatures --json` output it echoes a verdict token and
#   returns the status below. Unit-tested over a truth table with no registry and no root risk,
#   so the impure probe never has to run as root to exercise the logic.
# ai_tools_verify_npm_signatures      -- the impure probe: refuses root, discovers the global
#   tree, runs `npm audit signatures` against it (see below), and dispatches the pure verdict.
#
# ── Why the throwaway project ────────────────────────────────────────────────
# npm's own `npm audit signatures` is the verifier, but it REFUSES a global install
# (EAUDITGLOBAL). So the probe runs it against a throwaway project whose node_modules is a
# SYMLINK to the global tree (`npm root -g`) and whose package.json lists the global top-level
# packages: npm's arborist reads the real installed tree through the symlink and audits it in
# full -- including transitive dependencies -- with NO reinstall and no network beyond the
# registry key/attestation fetch. The throwaway dir is removed on return.
#
# ── Status contract (both functions) ─────────────────────────────────────────
#   0  every audited package has a verified registry signature
#   1  at least one signature is INVALID -- treat as tamper; the caller MUST fail closed
#      (do NOT repoint the stable launcher symlink / do NOT activate the new toolchain)
#   2  unable to verify (not root-eligible, npm too old, offline, no global packages, or an
#      unsigned-registry package) -- not a tamper signal; the caller WARNS and continues,
#      matching the best-effort posture of the rest of the updater
# Detail (which package failed) goes to stderr, which both callers route to the journal. The
# functions print no secret and take no agent-supplied argument.

[[ -n "${_AI_TOOLS_NPM_VERIFY_LIB_LOADED:-}" ]] && return 0
readonly _AI_TOOLS_NPM_VERIFY_LIB_LOADED=1

# ai_tools_npm_verdict <audit-json>: pure decision over `npm audit signatures --json` output.
# Echoes a verdict token (OK|INVALID|MISSING|EMPTY|UNKNOWN) and returns the status contract
# above. node parses the JSON (node is the toolchain's own runtime; jq is not assumed) and is
# used read-only on the passed string -- no filesystem, no npm, no privilege. A parse failure
# or empty input yields a non-OK verdict, so a format change never reads as a false OK.
ai_tools_npm_verdict() {
    local audit_json="${1:-}"
    [[ -n "${audit_json}" ]] || { printf 'EMPTY'; return 2; }
    command -v node >/dev/null 2>&1 || { printf 'UNKNOWN'; return 2; }

    local token
    token="$(printf '%s' "${audit_json}" | node -e '
        const fs = require("fs");
        let inv = [], mis = [];
        try {
            const j = JSON.parse(fs.readFileSync(0, "utf8"));
            inv = j.invalid || []; mis = j.missing || [];
        } catch (_) { process.stdout.write("PARSEFAIL"); process.exit(0); }
        const name = x => (x && x.name) ? (x.name + "@" + (x.version || "?")) : String(x);
        if (inv.length) process.stderr.write("npm-verify: invalid signature: "   + inv.map(name).join(", ") + "\n");
        if (mis.length) process.stderr.write("npm-verify: unsigned (no registry signature): " + mis.map(name).join(", ") + "\n");
        process.stdout.write(inv.length ? "INVALID" : (mis.length ? "MISSING" : "OK"));
    ')" || token="PARSEFAIL"

    case "${token}" in
        OK)       printf 'OK';      return 0 ;;
        INVALID)  printf 'INVALID'; return 1 ;;
        MISSING)  printf 'MISSING'; return 2 ;;
        *)        printf 'UNKNOWN'; return 2 ;;
    esac
}

# ai_tools_verify_npm_signatures: verify every globally installed npm package's registry
# signature. Self-contained -- discovers the global tree (`npm root -g`) and the top-level
# package set (`npm ls -g`) itself; takes no arguments. Returns the status contract above.
ai_tools_verify_npm_signatures() {
    local _p='npm-verify:'

    # Fail-closed identity backstop: this must run as the sandbox account (the owner of the
    # tree it audits), never root -- as root `npm root -g` is root's global prefix, so a run
    # would verify the wrong tree and could report a false OK. Refuse rather than mislead.
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        printf '%s refusing to run as root -- must run as the sandbox account\n' "${_p}" >&2
        return 2
    fi
    command -v npm  >/dev/null 2>&1 || { printf '%s npm not found -- cannot verify signatures\n'  "${_p}" >&2; return 2; }
    command -v node >/dev/null 2>&1 || { printf '%s node not found -- cannot verify signatures\n' "${_p}" >&2; return 2; }

    local global_nm
    global_nm="$(npm root -g 2>/dev/null)" || true
    [[ -n "${global_nm}" && -d "${global_nm}" ]] \
        || { printf '%s global node_modules not found -- nothing to verify\n' "${_p}" >&2; return 2; }

    # Top-level global packages at their installed versions, as a JSON deps object, from
    # `npm ls -g --json`. A parse miss yields an empty object, handled as "nothing to verify".
    local deps_json
    deps_json="$(npm ls -g --depth=0 --json 2>/dev/null | node -e '
        const fs = require("fs");
        let out = {};
        try {
            const j = JSON.parse(fs.readFileSync(0, "utf8"));
            for (const [name, info] of Object.entries(j.dependencies || {}))
                if (info && info.version) out[name] = info.version;
        } catch (_) { /* leave out empty */ }
        process.stdout.write(JSON.stringify(out));
    ' 2>/dev/null)" || true
    [[ -n "${deps_json}" && "${deps_json}" != "{}" ]] \
        || { printf '%s no global packages to verify\n' "${_p}" >&2; return 2; }

    local workdir
    workdir="$(mktemp -d 2>/dev/null)" || { printf '%s could not create a work directory\n' "${_p}" >&2; return 2; }
    # RETURN trap removes the throwaway project however the function exits.
    # shellcheck disable=SC2064
    trap "rm -rf -- '${workdir}'" RETURN

    printf '{"name":"ai-tools-sig-verify","version":"1.0.0","private":true,"dependencies":%s}\n' \
        "${deps_json}" > "${workdir}/package.json" || return 2
    # Symlink the real installed tree in; npm audits through it without a reinstall.
    ln -s "${global_nm}" "${workdir}/node_modules" || return 2

    local audit_json
    audit_json="$(cd "${workdir}" && npm audit signatures --json 2>/dev/null)" || true

    # Dispatch the pure verdict. It emits the per-package detail to stderr; we log the outcome.
    local token rc
    token="$(ai_tools_npm_verdict "${audit_json}")" && rc=0 || rc=$?
    case "${token}" in
        OK)      printf '%s all global package signatures verified\n' "${_p}" >&2 ;;
        INVALID) printf '%s INVALID signature detected -- treating as tamper (fail closed)\n' "${_p}" >&2 ;;
        MISSING) printf '%s an unsigned package is present -- could not fully verify\n' "${_p}" >&2 ;;
        EMPTY)   printf '%s audit produced no output -- unable to verify (offline?)\n' "${_p}" >&2 ;;
        *)       printf '%s could not read audit output -- unable to verify\n' "${_p}" >&2 ;;
    esac
    return "${rc}"
}

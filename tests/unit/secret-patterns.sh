#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/secret-patterns.sh
# Unit test for the shared secret-name classifier (secret-patterns.lib.sh), the single
# matcher ai-tools-chown and ai-tools-lockdown both source. Pins the SHIPPED default pattern
# set's behaviour hermetically: it sources the deployed library and forces the built-in
# defaults (independent of the operator's live secret-patterns config), then asserts the
# security-critical properties -- credential names match, matching is case-insensitive, and
# environment/name-anchored .NET configs match while plain configs and build artifacts the
# toolchain must read do NOT (a false positive quarantines a build input and breaks the
# build). Run as root via sudo (the suite contract); does not need privilege of its own.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"
section "secret classifier: shared matcher defaults (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "secret classifier" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}"; then
    skip "secret classifier" "could not source ${LIB}"; finish; exit
fi

# Force the SHIPPED defaults so the test is independent of the operator's secret-patterns
# config: copy the built-in list and mark patterns loaded, so ai_tools_is_secret_basename
# skips the config-file read.
AI_TOOLS_SECRET_PATTERNS=("${_AI_TOOLS_DEFAULT_SECRET_PATTERNS[@]}")
_AI_TOOLS_PATTERNS_LOADED=1

# (1) Credential names are classified as secrets.
secret_ok=true
for n in .env .env.local id_rsa id_ed25519 authorized_keys server.key cert.pem backup.p12 \
         store.jks kubeconfig .pgpass .npmrc .netrc .git-credentials secrets credentials; do
    ai_tools_is_secret_basename "${n}" || { fail "should classify as secret: ${n}"; secret_ok=false; }
done
${secret_ok} && pass "credential names are classified as secrets"

# (2) Matching is case-insensitive (a single stem covers its case variants).
case_ok=true
for n in .ENV ID_RSA Server.KEY CERT.PEM KubeConfig; do
    ai_tools_is_secret_basename "${n}" || { fail "should match case-insensitively: ${n}"; case_ok=false; }
done
${case_ok} && pass "matching is case-insensitive"

# (3) Environment/name-anchored .NET configs ARE secrets.
dotnet_ok=true
for n in appsettings.Production.json appsettings.Development.json web.Release.config \
         App.Staging.config connectionstrings.dev.json CommonSettings.PROD.json; do
    ai_tools_is_secret_basename "${n}" || { fail "anchored .NET secret should match: ${n}"; dotnet_ok=false; }
done
${dotnet_ok} && pass "environment/name-anchored .NET configs are classified as secrets"

# (4) Plain configs and build artifacts the toolchain must read are NOT secrets. The default
#     set is deliberately anchored, not a broad *.*.json / *.*.config catch-all, so these
#     stay readable; a false positive here breaks builds.
build_ok=true
for n in appsettings.json web.config MyApp.deps.json MyApp.runtimeconfig.json \
         project.assets.json MyApp.dll.config package.json tsconfig.json README.md Makefile; do
    if ai_tools_is_secret_basename "${n}"; then
        fail "build artifact / innocuous file wrongly quarantined: ${n}"; build_ok=false
    fi
done
${build_ok} && pass "plain configs and build artifacts are NOT quarantined"

# (5) The seeded config file leaves classification unchanged. `ai-tools-admin operators add`
# writes that file at enrolment, before the operator has decided anything, so what it writes must
# parse to an empty set and leave the built-in baseline in force -- a seed that parsed to even one
# pattern would REPLACE the baseline and silently stop quarantining every name it dropped.
CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"
if [[ -r "${CONF_LIB}" ]]; then
    # shellcheck source=/dev/null
    source "${CONF_LIB}"
fi
if declare -F ai_tools_conf_secret_patterns_seed >/dev/null 2>&1; then
    seed_file="$(mktemp)"
    ai_tools_conf_secret_patterns_seed > "${seed_file}"
    AI_TOOLS_SECRET_PATTERNS_FILE="${seed_file}" ai_tools_load_secret_patterns
    if [[ "${#AI_TOOLS_SECRET_PATTERNS[@]}" -eq "${#_AI_TOOLS_DEFAULT_SECRET_PATTERNS[@]}" ]] \
            && ai_tools_is_secret_basename .env; then
        pass "the seeded config parses to no pattern, so the baseline stays in force"
    else
        fail "the seeded config changed the loaded pattern set (${#AI_TOOLS_SECRET_PATTERNS[@]} patterns)"
    fi
    # The one claim the seeded header must always carry, asserted by the grep below: an
    # operator's pattern REPLACES the baseline rather than adding to it, so a file holding one
    # name classifies on that name alone.
    if grep -qi 'REPLACES the built-in baseline' "${seed_file}"; then
        pass "the seeded header states that a pattern replaces the baseline"
    else
        fail "the seeded header does not state the replace rule: $(cat "${seed_file}")"
    fi
    rm -f "${seed_file}"
    # Restore the shipped defaults for the case below, which the load above overwrote.
    AI_TOOLS_SECRET_PATTERNS=("${_AI_TOOLS_DEFAULT_SECRET_PATTERNS[@]}")
    _AI_TOOLS_PATTERNS_LOADED=1
else
    skip "seeded secret-patterns config" "conf.lib.sh defines no seed function"
fi

# (6) The classifier restores the caller's nocasematch setting (it flips it on internally).
shopt -u nocasematch
ai_tools_is_secret_basename .env >/dev/null || true
if ! shopt -q nocasematch; then
    pass "classifier restores the caller's nocasematch state"
else
    fail "classifier left nocasematch enabled -- leaks case-insensitive matching to the caller"
fi

finish

#!/usr/bin/env bash
# tests/unit/secret-patterns.sh
# Unit test for the shared secret-name classifier (secret-patterns.lib.sh), the single
# matcher ai-tools-chown and ai-tools-lockdown both source. Pins the SHIPPED default pattern
# set's behaviour hermetically: it sources the deployed library and forces the built-in
# defaults (independent of the operator's live secret-patterns config), then asserts the
# security-critical properties -- credential names match, matching is case-insensitive, and
# environment/name-anchored .NET configs match while plain configs and build artifacts the
# toolchain must read do NOT (a false positive quarantines a build input and breaks the
# build). Run as root via sudo (the suite contract); needs no privilege of its own.

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

# (5) The classifier restores the caller's nocasematch setting (it flips it on internally).
shopt -u nocasematch
ai_tools_is_secret_basename .env >/dev/null || true
if ! shopt -q nocasematch; then
    pass "classifier restores the caller's nocasematch state"
else
    fail "classifier left nocasematch enabled -- leaks case-insensitive matching to the caller"
fi

finish

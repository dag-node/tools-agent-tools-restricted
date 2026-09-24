---
paths:
  - "src/usr/local/lib/ai-tools/integrations.d/typesafe.conf"
  - "src/usr/local/lib/ai-tools/session-env.d/typesafe.env.sh"
  - "src/etc/ai-tools/endpoints/typesafe.conf"
  - "src/usr/local/lib/ai-tools/typesafe/**"
  - "src/usr/local/share/man/man5/ai-tools-typesafe.conf.5"
  - "src/usr/share/ai-tools/skills/ai-tools-decide/**"
  - "tests/unit/typesafe.sh"
  - "tools/generators/typesafe-client.sh"
  - "tools/generators/typesafe-client.pin"
  - "tests/boundary/typesafe.sh"
---

# The typesafe integration

`typesafe` (`ai-tools-integration-typesafe`) lets a session hand a long listing — a grep, a `git log`, a checker's
findings — to TypeSafe's bounded classifier and get back the lines that bear on the task it states in one sentence.
The session runs the **decide command**,
`node /usr/local/lib/ai-tools/typesafe/decide.mjs filter --task "…" --config "$AI_TOOLS_TYPESAFE_CONF" --usage-log "$AI_TOOLS_TYPESAFE_USAGE_LOG"`,
with the listing on stdin; the command prints the kept lines in full and one summary line naming the rest by id,
and exits non-zero with one stderr line and no result on any failure, so the listing the session already holds is always
the fallback. It is an **integration on the provider seam** ([providers](providers.rule.md)): a manifest, a session-env
fragment, and the `default_enable=no` that keeps it off until an operator names `typesafe` in `AI_TOOLS_INTEGRATIONS`,
because a call sends listing lines off the host. The shipped `ai-tools-decide` skill is what tells an agent
when the command is worth running and what it does not replace.

## The call path

The fragment `session-env.d/typesafe.env.sh` self-gates on the credential file's presence and appends two `--setenv=`
entries, both paths: `AI_TOOLS_TYPESAFE_CONF=/etc/ai-tools/endpoints/typesafe.conf`
and `AI_TOOLS_TYPESAFE_USAGE_LOG=/opt/ai-tools/integrations/typesafe/usage.log`. It does not add a PATH tail, does not
export a variable, and does not take either of the seam's fragment exceptions; `tests/unit/typesafe.sh` holds it
to that shape. The command itself does not read any environment variable: the skill passes the two values as `--config`
and `--usage-log`, so in a session the integration is not enabled for, `--config` is empty and the command exits 3.
The credential reaches the process at **call time**: `config.mjs` reads the file `--config` names, as the sandbox
account, and every option the transport uses is pinned from it, so the key is in no session's environment and in no
child process's. The read refuses a symlink, a file readable or writable by other, an empty or placeholder key, a base
URL other than an https origin, and a base URL whose host differs from the one `TYPESAFE_ENDPOINT_HOST` names — the key
is sent only to a host the file names twice. The group bits are not read: on a file under a claimed project the group
class shows the ACL mask, and the group is the sandbox account, which reads the key in any case.

`/etc/ai-tools/endpoints/typesafe.conf` ships `0640 root:ai-tools`, `%config(noreplace)`, with `TYPESAFE_API_KEY`
commented and `TYPESAFE_MODEL` set to the alias `jev-latest`: installing and enabling the integration does not make
a request until an operator sets the key with `sudo`. The vendor moves the alias to each stable release and states
that an answer's shape is stable across releases and its probabilities are not; `transport.mjs` records the `model`
the response names, so the summary line and the usage log carry the version that answered, and a versioned id is
the operator's choice where a threshold is measured against one release. The keep threshold, the uncertain band
and the per-attempt timeout ship commented at the client's defaults; they are keys in this file because an operator's
copy survives an upgrade that replaces the command, and `config.mjs` refuses a value outside its form rather than
falling back to the default, so a mistyped threshold does not change what is kept without a line saying so.
`ai-tools-typesafe.conf(5)` states each option; the template stays a pointer and `tests/unit/man.sh` holds the two
in lockstep. The model that answered is on every summary line and in the usage log, so a template edit or a model change
is visible in both.

The one path a call writes is the file `--usage-log` names, `usage.log` in the state root: one JSON line per invocation
(counts, template version, the model, tokens, elapsed time, outcome class, request ids) with no task text, no listing
line, and no key; without the flag the command does not write a file. The root is `2770 root:ai-tools`, agent-writable,
so the log is cost accounting and not an audit trail; a log the session cannot write costs the line and not the result.
The exit statuses and the refusal classes are declared in `decide.mjs`'s header and frozen by the client repository's
suite.

## What a call discloses, and what it does not change

What leaves the host is the task sentence and the listing lines the agent piped. The skill's first rule is
that a listing is piped and a file's contents are not, and a quarantined secret-named file is `600` to the operator,
so a session cannot read it to pipe it; the vendor's terms and whether a given project's lines may leave the host are
the operator's decision, which is why enabling is per host and by name. claude-code puts every call to the operator
first: its shipped `settings.json` carries `Bash(node /usr/local/lib/ai-tools/typesafe/decide.mjs *)` under `ask`,
which prompts in every permission mode and which no `allow` in another settings layer overrides
([claude-settings](claude-settings.rule.md)). Codex does not ask, since its shipped requirements mark no rule `prompt`
([agent-codex](agent-codex.rule.md)). Enablement is where the operator consents to the disclosure, and the usage log is
the per-call record, as counts without content.

Two things the integration does not change. Any process of the sandbox account can read the credential file, which is
the shared-account trust unit `CLAUDE.md` states and this integration inherits. And `--config <file>` lets a caller name
another credential file: a session that writes one of its own sends its own key to a host of its own choosing,
which HTTPS egress already permits and which does not reach the root-owned key. The guarantees are the ones
`tests/boundary/typesafe.sh` probes as the agent — the shipped file is readable by the sandbox account and not writable
by it or readable by other, neither the command nor the transport that decides where a request goes is writable,
the state root is — and their runtime halves are the refusals the client repository's suite drives.
`tests/integration/typesafe.sh` drives the installed command: the installed files against the pin, each refusal class
as the sandbox account against a host that does not resolve, and, with `AI_TOOLS_TEST_TYPESAFE_LIVE=1`, live calls
over synthetic listings. No SELinux policy is added: HTTPS egress, the read of `/etc/ai-tools`, and writes
under the integration state root are granted to the base domain.

## No runtime dependency: the shipped JavaScript is a pinned, signed release

`src/usr/local/lib/ai-tools/typesafe/*.mjs` is what the package installs and what a host runs: the `dist/` modules
of a release of `dag-node/typesafe-client-js` (MIT), vendored unmodified with the `LICENSE` and `CHANGELOG.md`
the release tarball carries beside them; the package's `%license` is that `LICENSE`. Each module imports its siblings
and the Node builtins alone, so the integration does not put a third-party dependency in the agent's execution path,
and the RPM build and a host need `node` alone. The client repository's CI runs the command's suite, with the one
request injected; this repository holds the vendored files to the release (see [Which release is vendored,
and how that is checked](#which-release-is-vendored-and-how-that-is-checked)).

`transport.mjs` is that one request: `POST <base>/v1/systemone` with a bearer token, at most one retry,
under a per-attempt timeout, with the invocation's total budget carried on an abort signal. A redirect is not followed:
it is refused as the provider's answer, so neither the key nor the listing reaches the host it names. `core.mjs` reads
its projected result.

**A response is untrusted input, and the gates run before the parser.** The status, then the content type, then a hard
byte cap on the read — so a body that is not a small JSON result is refused with the stream cancelled rather than handed
to `JSON.parse`. What survives the parse is not returned either: the projection rebuilds the documented shape
on null-prototype objects, reading **own** properties only and walking the ids the process asked for, so an id the body
offers and no chunk requested is dropped without being enumerated. The projection **drops and never coerces** — a field
failing its predicate is left out rather than clamped — so `contractProblems` still reports it and a malformed answer
cannot be repaired into a valid-looking one. A request id reaches the usage log, so it is admitted only in a bounded
charset.

## Written against the provider's published types, shipped without them

The TypeScript the modules are compiled from lives in `dag-node/typesafe-client-js`, whose strict `nodenext` `tsc` build
is the whole of `dist/`. It keeps `@typesafe-ai/sdk` at `^0.6.0` as a **devDependency**: the provider publishes its wire
contract as TypeScript declarations, and `transport.mts`, `core.mts` and `templates.mts` bind to them
through `import type` — the request body to `SystemOneRequestPayload`, the question builders to `NoulQuestion`
and `ChoiceQuestion`, and a `DriftCheck` tuple to each answer and usage field `contractProblems` validates. A release
that renames or retypes one of those fails the client's next build, which is what the caret range is for. `import type`
is erased on emit, so the shipped `.mjs` does not import them: the declarations are a build-time contract rather than
a runtime dependency.

The validation is written against the documented shapes rather than the types, so a wire change the declarations do not
describe is still caught at runtime: a declaration does not check a body.

## Which release is vendored, and how that is checked

`tools/generators/typesafe-client.pin` names the release — the tag, the commit the tag names, the release tarball's
sha256, and each vendored file's sha256 — and `tools/generators/typesafe-client.sh generate <tag>` is the one writer
of both the pin and the vendored files. A release is accepted only when the tarball carries the notices beside its
modules, when the tarball matches the checksum the release publishes, its detached signature is by the DagNode
package-signing key, and the tag is an annotated tag signed by the client's release key. The trust anchors are the two
keys' **primary fingerprints**, held in the generator; each key is fetched over HTTPS for the one call, so the URL is
transport, a key served from a compromised account does not match, and a rotated signing subkey leaves the pin
unchanged. The client's release job verifies the tag before it signs the tarball; the generator checks the tag again
against its author's key, so the pinned commit does not rest on the org key alone. Signatures are checked with `gpgv`,
which verifies without reading a secret key or an agent.

Two checks hold the tree to the pin, and they answer different questions. `stale` is offline and runs
in `tests/unit/typesafe.sh`: a vendored file edited, added or removed fails it. It cannot tell a file edited together
with the pin line that lists it; `verify` can, because it downloads the pinned release, repeats every signature check,
and re-derives each hash. The CI job `typesafe-client` runs `verify`, and the release job needs it, so a release is
built only from modules a signed release carries. A change to the command is therefore made and released in the client
repository and arrives here as `generate` on its tag.

## The skill this package ships

`ai-tools-decide` lives in the shared pristine root with the base's skills, since the seeder reads one root,
and `ai-tools-integration-typesafe` owns its directory (base `%exclude`s it). The package's `%post` seeds it and links
it into every enabled agent's skills directory itself — base's and the agents' scriptlets run before this package's
files are on disk on a first install — and its `%postun` on final erase withdraws the live copy
with `ai_tools_withdraw_asset` and re-runs the linker, which drops each agent's link to a target that is gone.
The placement chain and the marker gate are [shipped-assets](shipped-assets.rule.md). A from-source install copies
the whole pristine root, so `install.sh` seeds it with the rest.

## Templates, measurement, and what is deferred

`filter` is the one template dispatched. The question is one bounded judgment per listing item -- whether that item
satisfies the task the caller stated -- asked in chunks under the limits `core.mts` declares, with one retry
and a per-invocation deadline; a rate limit or an outage costs one invocation. The two `criteria` strings carry
that judgment: for a noul they are what the model answers against, so a criterion naming a fixed notion of relevance
answers that notion whatever the task says, and the shipped pair defers to the task instead. `TEMPLATE_VERSION` is
recorded with every usage line, so a criteria edit is visible beside the model that answered.

Every request bound sits in one frozen `LIMITS` block at the top of `core.mjs`, with the reason for each beside it:
what stdin may hold, what one item and one request may carry, the longest line a pattern runs over, and the total
deadline. They are chosen against each other and change with a client release, not with an edit here, which `stale`
refuses; the values an operator tunes per host are the credential file's keys.

Three input formats. `lines` makes an item of each non-empty line, taking a `path:line` prefix as the id
where that prefix is an id `core.mts` would accept, so a log line carrying a clock time falls back to `L<n>` rather than
failing the listing. `prose-check` reads the checker's two-line records. `msbuild` is a pre-filter: it keeps a build
log's diagnostics, collapses the repeat MSBuild prints in its summary, and reports how many lines it set aside --
a `dotnet build -v n` log carries its compiler invocations in the same stream, and one of those lines alone runs to tens
of kilobytes. A listing is untrusted input in every format, so `parse` first holds stdin to text within the size bound
and refuses a stream carrying a NUL or a run of undecodable bytes, which is what keeps a binary file from reaching
the provider. An item carrying a Unicode tag character is refused, since the model reads it; zero-width characters
and bidi controls are counted on the summary line and sent unchanged, since they mislead a reader of the output rather
than the model.

A `triage` template (a verdict per checker finding) is written but not dispatched: in the live measurement its precision
on the accepted class did not reach the criterion set for it, so asking for it exits with the input status
and the reason. The verification script that measured both, and its recorded runs, live in the companion wip repository
under `typesafe/verify/`; the criterion that decides whether `filter` stays is the plan's evaluation on real listings
from this repository's own sessions.

No cache (inputs rarely repeat, and a cache keyed on project content would be shared state across every operator's
sessions under one account), no `ai-tools-admin` domain (the two root-side steps are scriptlet-sized,
and `ai-tools providers` already reports enablement), and requests run one at a time.

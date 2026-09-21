---
paths:
  - "src/usr/local/lib/ai-tools/integrations.d/typesafe.conf"
  - "src/usr/local/lib/ai-tools/session-env.d/typesafe.env.sh"
  - "src/etc/ai-tools/endpoints/typesafe.conf"
  - "src/usr/local/lib/ai-tools/typesafe/**"
  - "src/usr/local/share/man/man5/ai-tools-typesafe.conf.5"
  - "src/usr/share/ai-tools/skills/ai-tools-decide/**"
  - "tests/unit/typesafe.sh"
  - "tests/unit/typesafe-client.sh"
  - "tests/boundary/typesafe.sh"
---

# The typesafe integration

`typesafe` (`ai-tools-integration-typesafe`) lets a session hand a long listing — a grep, a `git log`, a checker's
findings — to TypeSafe's bounded classifier and get back the lines that bear on the task it states in one sentence.
The session runs the **decide command**, `node /usr/local/lib/ai-tools/typesafe/decide.mjs filter --task "…"`,
with the listing on stdin; the command prints the kept lines in full and one summary line naming the rest by id,
and exits non-zero with one stderr line and no result on any failure, so the listing the session already holds is always
the fallback. It is an **integration on the provider seam** ([providers](providers.rule.md)): a manifest, a session-env
fragment, and the `default_enable=no` that keeps it off until an operator names `typesafe` in `AI_TOOLS_INTEGRATIONS`,
because a call sends listing lines off the host. The shipped `ai-tools-decide` skill is what tells an agent
when the command is worth running and what it does not replace.

## The call path

The fragment `session-env.d/typesafe.env.sh` self-gates on the credential file's presence and appends two `--setenv=`
entries, both paths: `AI_TOOLS_TYPESAFE_CONF=/etc/ai-tools/endpoints/typesafe.conf`
and `AI_TOOLS_TYPESAFE_STATE=/opt/ai-tools/integrations/typesafe`. It does not add a PATH tail, does not export
a variable, and does not take either of the seam's fragment exceptions; `tests/unit/typesafe.sh` holds it to that shape.
The credential reaches the process at **call time**: `config.mjs` reads the file the variable names, as the sandbox
account, and every option the transport uses is pinned from it, so no `TYPESAFE_*` environment value is read and the key
is in no session's environment and in no child process's. The read refuses a symlink, a file readable or writable
by other, an empty or placeholder key, a base URL other than an https origin, and a base URL whose host differs
from the one `TYPESAFE_ENDPOINT_HOST` names — the key is sent only to a host the file names twice. The group bits are
not read: on a file under a claimed project the group class shows the ACL mask, and the group is the sandbox account,
which reads the key in any case.

`/etc/ai-tools/endpoints/typesafe.conf` ships `0640 root:ai-tools`, `%config(noreplace)`, with `TYPESAFE_API_KEY`
commented and `TYPESAFE_MODEL` set to a versioned id: installing and enabling the integration does not make a request
until an operator sets the key with `sudo`, and the alias `jev-latest` is not used because the vendor moves it
on a release. `ai-tools-typesafe.conf(5)` states each option; the template stays a pointer and `tests/unit/man.sh` holds
the two in lockstep. The model that answered is on every summary line and in the usage log, so a template edit
or a model change is visible in both.

The one path a call writes is the state root's `usage.log`: one JSON line per invocation (counts, template version,
the model, tokens, elapsed time, outcome class, request ids) with no task text, no listing line, and no key. The root is
`2770 root:ai-tools`, agent-writable, so the log is cost accounting and not an audit trail; a root the session cannot
write costs the line and not the result. The exit statuses and the refusal classes are declared in `decide.mts`'s header
and asserted by `tests/unit/typesafe-client.sh`.

## What a call discloses, and what it does not change

What leaves the host is the task sentence and the listing lines the agent piped. The skill's first rule is
that a listing is piped and a file's contents are not, and a quarantined secret-named file is `600` to the operator,
so a session cannot read it to pipe it; the vendor's terms and whether a given project's lines may leave the host are
the operator's decision, which is why enabling is per host and by name. The command is **unlisted** in each agent's
shipped `settings.json`, so Claude Code asks before running it: the prompt is the operator's visibility
of the disclosure. An operator who accepts it may add `Bash(node /usr/local/lib/ai-tools/typesafe/decide.mjs *)`
to their own settings.

Two things the integration does not change. Any process of the sandbox account can read the credential file, which is
the shared-account trust unit `CLAUDE.md` states and this integration inherits. And `--config <file>` lets a caller name
another credential file: a session that writes one of its own sends its own key to a host of its own choosing,
which HTTPS egress already permits and which does not reach the root-owned key. The guarantees are the ones
`tests/boundary/typesafe.sh` probes as the agent — the shipped file is readable by the sandbox account and not writable
by it or readable by other, neither the command nor the transport that decides where a request goes is writable,
the state root is — and their runtime halves are the refusals `tests/unit/typesafe-client.sh` drives. No SELinux policy
is added: HTTPS egress, the read of `/etc/ai-tools`, and writes under the integration state root are granted to the base
domain.

## No runtime dependency: the shipped JavaScript is the reviewed JavaScript

`src/usr/local/lib/ai-tools/typesafe/*.mjs` is what the package installs and what a host runs. Each module imports its
siblings and the Node builtins alone, so the code the sandbox account executes on a call is code this repository ships
and reviews, and the integration does not put a third-party dependency in the agent's execution path. The RPM build
and a host need `node` alone, and `tests/unit/typesafe-client.sh` drives the shipped files offline with the one request
injected.

`transport.mjs` is that one request: `POST <base>/v1/systemone` with a bearer token, at most one retry,
under a per-attempt timeout, with the invocation's total budget carried on an abort signal. `core.mjs` reads its
projected result.

**A response is untrusted input, and the gates run before the parser.** The status, then the content type, then a hard
byte cap on the read — so a body that is not a small JSON result is refused with the stream cancelled rather than handed
to `JSON.parse`. What survives the parse is not returned either: the projection rebuilds the documented shape
on null-prototype objects, reading **own** properties only and walking the ids the process asked for, so an id the body
offers and no chunk requested is dropped without being enumerated. The projection **drops and never coerces** — a field
failing its predicate is left out rather than clamped — so `contractProblems` still reports it and a malformed answer
cannot be repaired into a valid-looking one. A request id reaches the usage log, so it is admitted only in a bounded
charset.

## Written against the provider's published types, shipped without them

The TypeScript the `.mjs` is emitted from lives in the companion wip repository (`typesafe/client/`), which holds
the strict `nodenext` configuration and whose `tsc` emits into this tree. It keeps `@typesafe-ai/sdk` at `^0.6.0`
as a **devDependency**: the provider publishes its wire contract as TypeScript declarations, and `transport.mts`,
`core.mts` and `templates.mts` bind to them through `import type` — the request body to `SystemOneRequestPayload`,
the question builders to `NoulQuestion` and `ChoiceQuestion`, and a `DriftCheck` tuple to each answer and usage field
`contractProblems` validates. A release that renames or retypes one of those fails the next build there, which is
what the caret range is for. `import type` is erased on emit, so the shipped `.mjs` does not import them:
the declarations are a build-time contract rather than a runtime dependency.

The validation is written against the documented shapes rather than the types, so a wire change the declarations do not
describe is still caught at runtime: a declaration does not check a body.

**The committed `.mjs` is the artifact of record, and this repository does not check it against that source.**
What stands in place of such a check is that the shipped file is reviewed as source: it is the one a reader opens,
the one `tests/unit/typesafe-client.sh` drives, and the one the package installs. An edit made here and not carried back
to the `.mts` is a divergence a reviewer catches or nobody does. Bringing the source back into this repository,
or pinning the emitted files against a signed release of it, is what would close that.

## The skill this package ships

`ai-tools-decide` lives in the shared pristine root with the base's skills, since the seeder reads one root,
and `ai-tools-integration-typesafe` owns its directory (base `%exclude`s it). The package's `%post` seeds it and links
it into every enabled agent's skills directory itself — base's and the agents' scriptlets run before this package's
files are on disk on a first install — and its `%postun` on final erase withdraws the live copy
with `ai_tools_withdraw_asset` and re-runs the linker, which drops each agent's link to a target that is gone.
The placement chain and the marker gate are [shipped-assets](shipped-assets.rule.md). A from-source install copies
the whole pristine root, so `install.sh` seeds it with the rest.

## Templates, measurement, and what is deferred

`filter` is the one template dispatched. The question is one bounded relevance judgment per listing line, asked
in chunks under the limits `core.mts` declares, with one retry and a per-invocation deadline; a rate limit or an outage
costs one invocation. A `triage` template (a verdict per checker finding) is written but not dispatched: in the live
measurement its precision on the accepted class did not reach the criterion set for it, so asking for it exits
with the input status and the reason. The verification script that measured both, and its recorded runs, live
in the companion wip repository under `typesafe/verify/`; the criterion that decides whether `filter` stays is
the plan's evaluation on real listings from this repository's own sessions.

No cache (inputs rarely repeat, and a cache keyed on project content would be shared state across every operator's
sessions under one account), no `ai-tools-admin` domain (the two root-side steps are scriptlet-sized,
and `ai-tools providers` already reports enablement), and requests run one at a time.

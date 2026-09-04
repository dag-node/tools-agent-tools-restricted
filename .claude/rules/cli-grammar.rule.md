---
paths:
  - "src/usr/local/bin/ai-tools.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-dotnet.sh"
  - "src/usr/local/share/man/man1/ai-tools.1"
  - "src/usr/local/share/man/man8/ai-tools-admin.8"
---

# Command grammar

The shape every command in this project takes: `ai-tools`, `ai-tools-admin`, `ai-tools-dotnet`,
`ai-tools(1)` and `ai-tools-admin(8)`. What each command *does* is in the rule for its component —
[cli](cli.rule.md) for the project lifecycle, [confinement](confinement.rule.md) for the SELinux
group verbs, [dotnet](dotnet.rule.md) for the .NET integration. This rule covers only how a
command is spelled and how it projects onto an HTTP surface.

The surface is **resource-oriented and isomorphic to a REST API**, so an HTTP layer can be mapped
onto it without renaming anything. That constraint is what fixes the rules below; each one is a
CLI spelling with an unambiguous URI on the other side.

## The rules

| Rule | Form |
|---|---|
| A command is a **bare word**; `--` introduces an option and never a command | `operators add`, not `--operator-add` |
| A collection takes the **plural** noun | `operators`, `groups`, `entrypoints` |
| The **verb comes after** the noun, and is never hyphenated into it | `groups enable <name>`, not `enable-group <name>` |
| `list` is the **zero-argument default** on a collection | `ai-tools-admin operators` lists them |
| A bare noun with no `list` yet prints its verbs | it MUST NOT default to a **mutating** verb |
| A global, one-shot or infrastructure-level action goes top-level or under `system` | `system post-upgrade`, `system bootstrap` |
| Switches are **descriptive and long** | `--dry-run`, not `-n`; new surface does not add short flags |
| `--help` and `--version` stay options | both `-h` and `--help` print the full help and ignore other arguments |

Verb-noun ordering is a **convention rather than a rule with one correct answer**: clig.dev
declines to prescribe either order, PatternFly recommends the opposite, and the .NET CLI mixes
both. Every guide does agree on internal consistency, so the value is in holding one order rather
than in which order it is. `noun verb` is the one held here, and this project's existing names
already encode it — `--project-claim` and `--sandbox-create` are noun-verb pairs carrying a hyphen
where a space belongs.

## Singular domains, plural collections

A name in the command slot is either a collection or a domain, and its grammatical number tells a
reader which:

| Form | Names | Examples |
|---|---|---|
| **plural** | a collection whose instances are managed | `operators`, `groups`, `entrypoints`, `projects` |
| **singular** | a domain or subsystem that *contains* resources | `selinux`, `system` |

The shape is **`<domain> <resource> <verb>`** — singular, plural, imperative — with the domain
omitted where the resource name is already unique on that binary. So `operators add` carries none
and `selinux groups enable` does: `selinux` is the administration area that owns `groups`.

That asymmetry survives into the REST projection. AIP-122 requires a collection identifier to be
the plural form of its resource noun, while REST guides reserve the singular for **singleton
resources** (`/health`, `/settings`). A domain maps to a **path prefix** — `/selinux/groups/...` —
and the CLI notion of a command group is what carries it.

**A domain takes verbs of its own** where the action is about the whole domain rather than about
instances of something it owns. `dotnet tools install <pkg>` acts on instances and takes the
collection; `dotnet bootstrap` and `dotnet status` act on the integration itself and take the verb
directly. The token after a singular noun is what tells a reader which: a plural means a
collection follows, a verb means the domain is the subject. Such a verb projects as a custom
method on the domain path (`POST /dotnet:bootstrap`), and a domain carrying state of its own is
addressable there as a singleton (`GET /dotnet`).

### `bootstrap` and `provision` are different verbs

They name different work and are not interchangeable:

| Verb | Work | Example |
|---|---|---|
| `bootstrap` | initial configuration — first-run setup, core binaries, the state a component needs before it can be used | `system bootstrap`, `dotnet bootstrap` |
| `provision` | creating or allocating an entity, and managing it thereafter | reserved; no command takes it |

Every provider's first-run setup takes `<provider> bootstrap`, so an operator meets one verb
across the whole surface rather than a per-integration synonym (`setup`, `init`, `prepare`).

**A `bootstrap` verb MUST be idempotent, and MUST NOT reset.** A re-run reuses what is already in
place — an existing account, an installed Node version, a labelled directory — and leaves
configuration the operator has since changed alone, so the command is safe to run again after a
partial failure, after enabling a provider, or from a script that cannot know the host's state.
Returning a component to its defaults is destructive and belongs to a separate verb, which no
command takes yet. `ai-tools-bootstrap` and `ai-tools-dotnet setup` already hold this contract;
the name is what obligates it.

**Scope defaults to the minimum that works.** A bare `bootstrap` does the recommended minimal
setup, so an operator running it for the first time does not choose a scope. Widening it — `system
bootstrap` reaching every enabled integration rather than the toolchain alone — is an explicit
opt-in, projecting as a request field (`{"scope": "full"}`) rather than a second command. The
switch spelling is open; `--scope full` follows the descriptive-long-switch rule, while a bare
positional `full` would collide with the resource identifiers every other verb takes there.

## Which binary a command lives on

**The binary is the privilege boundary**, and it is where the whole surface expresses it — the URI
carries no `/admin` prefix (below). There are two typed commands:

| Binary | Caller | Holds |
|---|---|---|
| `ai-tools` | the invoking operator, unprivileged; refuses the sandbox account | project lifecycle and the reports |
| `ai-tools-admin` | root, enforced by `EUID -eq 0` before any command dispatches | host administration |

`--help` and `--version` are answered ahead of that root check, since they read no host state and
leave the host as it is, so the first thing an operator meets is the command surface rather than a refusal.

A command requiring root belongs on `ai-tools-admin` rather than in a binary of its own, so an
administrator learns one name and one grammar. Each additional top-level name costs a
`%{_sbindir}` symlink, an entry in `install.sh`'s uninstall list, and a place in the packaging
`%files` — for a command that is already a verb under an existing domain.

### A provider package owns a domain

`ai-tools-admin` ships in `ai-tools-base`, which is installed without knowing which
`ai-tools-agents-*` or `ai-tools-integration-*` packages a host will add, so it **MUST discover
the domains it dispatches rather than enumerate them**. Base owns four names — `operators`,
`selinux`, `system`, `status` — and a provider package contributes one domain named for the
provider, the same token it takes in `agents.d`/`integrations.d` and in `operator.conf`. The
dotnet integration owns `dotnet`, so `dotnet bootstrap` and `dotnet tools install <pkg>` are
`ai-tools-admin` commands on a host that installed it and absent on one that did not.

Four rules bind that surface:

- **A base name wins.** A provider contributing `system` or `status` MUST be refused rather than
  merged, so no installed package can shadow a command an administrator relies on.
- **A contributed command MUST pass the same trust predicate as every other provider input** —
  root-owned, not group- or other-writable, in a directory holding the same
  ([providers](providers.rule.md)). Here it stops the sandbox account planting a command root
  would run.
- **Installation, not enablement, decides whether the command exists.** `AI_TOOLS_INTEGRATIONS`
  gates what a confined **session** receives; an administrator configuring a provider is a
  different question, and a command that vanished until the provider was enabled would make
  bootstrap-then-enable and enable-then-bootstrap differ. What the command *reports* still names
  the enablement state. `system bootstrap` at full scope reads the **enabled** set instead, since
  "everything this host runs" is what enablement means.
- **`--help` lists what this host has.** The domain list is the installed, trusted set, so the help
  an administrator reads and the commands that dispatch cannot disagree.

**The root helpers under `/usr/local/libexec/ai-tools/` are outside this grammar.**
`ai-tools-chown`, `ai-tools-setfacl`, `ai-tools-unclaim` and the rest are invoked by the CLI over
`sudo` at a fixed path, never typed by a person, and their argument forms are pinned by the
sudoers drop-in ([launch](launch.rule.md)). They are an internal calling convention, and renaming
one changes a security contract rather than a user surface.

## When a resource takes the `system` domain

`ai-tools-admin` refuses a non-root caller, which already tells the reader the surface is
privileged, so `system` does not mark privilege and most resources do without it. A resource takes the
prefix when either test holds:

- its name **collides** with a resource a public API would plausibly expose, or
- it is **internal plumbing** — labels, cgroup paths, SELinux contexts, entrypoints — rather than
  something an operator manages deliberately.

`entrypoints` takes it on the first test. `selinux groups` takes neither: an operator enables a
group to make a workload run (`tmpmap` for a .NET restore, `apphost` for `dotnet run`), which is a
first-class administration concern owned by the SELinux domain.

**Being admin-only is not a test, and neither is returning more detail.** `operators` and the
anticipated `proxies`, `mcps` and `services` are all admin-managed and all stay flat, since their
names are unambiguous on their own. A richer response for a privileged caller is a **view**, never a
prefix.

Depth is the second reason not to over-prefix: Azure caps a URI at collection/item/collection and
Zalando limits nesting to one level. A custom method does not add a level against that budget, so
`selinux groups enable <name>` projects to `/selinux/groups/{name}:enable` — a prefix, one
collection, one item. Adding `system` on top would deepen the **path** for a command an operator
types to unblock a build.

In one line: acts on instances of a named resource → `[domain] <resource> <verb>`; global,
one-shot or infrastructure-level → `system <verb>`.

## The REST projection

Most of this surface is **actions** rather than CRUD — `claim`, `unclaim`, `relabel`, `lockdown`,
`reclaim`, `enable`, `disable`. Standard CRUD takes the ordinary HTTP methods; everything else
takes AIP-136's **custom method**, a verb after a colon, because a CLI verb maps onto it
one-for-one with no renaming.

The examples below are spelled in this grammar; *Where the surface stands* reconciles each binary's
own spelling against it.

```
ai-tools-admin operators                      →  GET  /operators
ai-tools-admin operators add <user>           →  POST /operators
ai-tools-admin selinux groups enable tmpmap   →  POST /selinux/groups/tmpmap:enable
ai-tools-admin system entrypoints relabel     →  POST /system/entrypoints:relabel
```

AIP-136's rules carry over: the method name is a verb followed by a noun with no prepositions; it
is not one of the standard five (Get, List, Create, Update, Delete), which take standard methods
instead; the fragment after `:` matches the method name; and the HTTP method is `POST` unless the
action is side-effect free, in which case `GET`.

**The colon is what keeps the hierarchy unambiguous**, and a slash would undo it:

| Form | Reads as |
|---|---|
| `/system/entrypoints:relabel` | a custom method on the **collection** — the action does not take an identifier |
| `/system/entrypoints/{agent}:relabel` | a custom method on **one instance** |
| `/system/entrypoints/relabel` | a sub-resource *named* `relabel`, which corrupts the hierarchy |

**A read takes a standard method.** AIP-121 prefers a standard method wherever one expresses the
intent, so anything that only reports is a `GET` on a resource, and a report with no collection
behind it is a **singleton** — singular noun, no id. A `status` command therefore projects as
`GET /status`, never `:status`.

**The two surfaces map 1:1 without sharing structure.** After the colon AIP-136 requires
**camelCase**, the fragment being an RPC method name rather than a path segment (`:relabel`,
`:validateManifest`); the CLI keeps **kebab-case** for readability. Either side may also omit a
prefix the other carries: a bare `status` command maps to `GET /status` while
`system entrypoints relabel` keeps its domain in the URI. Method names stay concise: `:relabel`,
not `:performRelabelOnAllEntrypoints`.

## No `/admin` namespace

The two binaries split by privilege, and that split does **not** project into the URL. A role is a
property of the **caller**: prefixing by role gives one entity two URIs, forks caching and client
code, and turns a change in authorization policy into a breaking change in the contract. The test
is direct — if removing `/admin` leaves a URL that collides with an existing one, there was only
ever one resource. `/admin/status` and `/status` collide exactly.

A privileged caller seeing more is a **view**, in either of two forms that leave the URI alone:
field-level shaping by privilege, or an explicit `view` parameter with `BASIC` and `FULL`
(AIP-157). The CLI already does the first with no privilege check in it: `ai-tools --status`
prints `?` where it *cannot read* — the root-owned pin directory it cannot traverse, the sandbox
account's `systemd --user` manager it cannot query — and the same command as root completes those
reads ([cli](cli.rule.md)). One resource, degrading by privilege.

An audience prefix is warranted where the surfaces are separate products with separate
authentication on separate deployments. This host runs one auth model — Unix identity plus `sudo`
— so the binary expresses the boundary on the CLI side and authorization middleware expresses it
on the HTTP side. Neither needs a path segment.

## Where the surface stands

`ai-tools-admin` conforms: `operators [list|add|remove]`, `selinux groups [list|enable|disable]`,
`system post-upgrade`, `--help`/`-h`, `--version`. `ai-tools-admin(8)` documents that surface and
`tests/unit/man.sh` holds the page, the helper's `usage()` and its dispatch arms in agreement, so a
command renamed in one of the three fails the suite rather than going stale in the others.

Two commands still diverge. Four names carry a `%{_sbindir}` symlink so `sudo <name>` resolves
through `secure_path` — `ai-tools`, `ai-tools-admin`, `ai-tools-bootstrap` and `ai-tools-dotnet` —
and three of the four are root-only, so the last two fold into `ai-tools-admin` as verbs:

| Its spelling | Under this grammar |
|---|---|
| `sudo ai-tools-bootstrap` | `system bootstrap` |
| `sudo ai-tools-dotnet setup` | `dotnet bootstrap` |
| `sudo ai-tools-dotnet install-tools <pkg...>` | `dotnet tools install <pkg...>` |
| `sudo ai-tools-dotnet status` | `dotnet status` |
| `ai-tools --project-claim`, `--sandbox-create`, `--status`, … | blocked on the domain model below |

`ai-tools-bootstrap` and `ai-tools-dotnet` lose their standalone names and their `%{_sbindir}`
symlinks with the move, in both `install.sh` and the RPM. `ai-tools-admin` ships in
`ai-tools-base` and runs on an unprovisioned host, so a host reaches `system bootstrap` before
the toolchain it installs exists. `system bootstrap` belongs to base and `dotnet bootstrap` to the
integration package that owns the domain.

`ai-tools-admin` dispatches a fixed `case` over its own commands, so the discovery seam that
lets a provider package contribute `dotnet` is the work that carries that domain in, and the
`--scope full` opt-in on `system bootstrap` depends on it: base can only run each enabled
integration's `bootstrap` once there is a seam to find one through.

**The `ai-tools` conversion needs a domain model this project does not yet state.** Naming
`projects` and `sandboxes` as collections is a claim the code does not make: `allowed-projects` is
a **single registry** with one entry format, every claimed directory is a line in it, and the kind
is **derived from the path prefix** rather than stored (`ai-tools.sh` computes `kind="sandbox"`
for a path under `SANDBOX_ROOT`, and `require_sandbox_clone` agrees). Three questions decide the
nouns, and each changes them: whether a project is one claimed directory or a group of them;
whether a sandbox is a kind of project (`GET /projects?kind=sandbox`) or its own collection; and
where `--list`'s cross-cutting *Suggested cleanup* findings live if the listing splits. Until they
are answered `ai-tools` keeps its `--verb` commands, which are pinned by `ai-tools(1)`,
`tests/unit/man.sh`, `tests/unit/cli-verbs.sh` and `tests/integration/cli.sh`, and printed as
remedies at roughly 60 runtime sites.

**The grammar and the hierarchy are separable.** Two costs the option-spelling imposes are
namespace collisions that exist whatever a project turns out to be: `BOOTSTRAP_EXEMPT_VERBS`
carries `-h`, `-V` and `""` only because verbs and options share one namespace and a bare
invocation has to be spelled as an empty verb, and `tests/unit/man.sh` tells a verb from an option
by **indentation** in the `usage()` heredoc — four spaces against two. Dropping the dashes while
keeping every name (`ai-tools project-claim`) settles both and commits to no hierarchy.

## Why not

- **A deprecation alias beside a renamed command.** The repo does not carry migration shims: the code
  reflects the final state and dev hosts are cleaned by hand. A renamed command is renamed.
- **`--` as a marker for an unsettled surface.** It reads as an option, which is the collision
  itself. Projects gating an unstable surface use an explicit namespace instead — `kubectl alpha`,
  `gh preview`, `cargo -Z` — which graduates by dropping the prefix.
- **An `:postUpgrade` projection for `system post-upgrade`.** The name states a lifecycle *moment*
  rather than a verb acting on a noun, so it has no clean AIP-136 form. What it does is reconcile
  the `.rpmnew` config files, which states as `POST /system/configs:reconcile`. The CLI name is
  settled; the projection is the one to revisit if an HTTP layer is built.

## References

- [clig.dev](https://clig.dev/) — subcommand ordering, cross-subcommand consistency, full-length
  flags, `-h`/`--help` printing full help.
- [POSIX Ch. 12, Utility Conventions](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html)
  — the leading hyphen marks an option; bare `--` is the end-of-options delimiter.
- [PatternFly CLI handbook](https://www.patternfly.org/content-design/writing-guides/cli-handbook/)
  — the dissenting verb-noun recommendation.
- [AIP-122](https://google.aip.dev/122) — plural collection identifiers.
- [AIP-136](https://google.aip.dev/136) — custom methods: the `:verb` form, verb-noun method names,
  camelCase after the colon, `POST` unless side-effect free.
- [AIP-121](https://google.aip.dev/121) — prefer standard methods; custom methods only where a
  standard one cannot express the intent.
- [AIP-157](https://google.aip.dev/157) — the `view` pattern (`BASIC` / `FULL`) for one resource
  returning different depths.
- [Azure API design](https://learn.microsoft.com/en-us/azure/architecture/best-practices/api-design)
  and [Zalando RESTful API Guidelines](https://opensource.zalando.com/restful-api-guidelines/) —
  plural collection URIs, nesting depth, singular reserved for singletons.
